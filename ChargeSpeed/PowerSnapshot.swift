import Foundation

/// One reading of everything the app can learn about power, merged from several sources:
/// - `raw`: IOKit `IOPMPowerSource` properties (complete on macOS/simulator, sandbox-filtered on iOS)
/// - `powerSource`: powerd's battery description (`IOPSCopyPowerSourcesInfo`)
/// - `adapterDetails`: powerd's adapter description (`IOPSCopyExternalPowerAdapterDetails`)
/// - `sensors`: PMU/charger sensor readings from `IOHIDEventSystemClient`
struct PowerSnapshot {
    let date: Date
    let raw: [String: Any]
    let powerSource: [String: Any]?
    let adapterDetails: [String: Any]?
    let sensors: [HIDSensors.Reading]
    /// powerd charge status (`IOPSCopyChargeStatus`), when the sandbox allows it.
    let chargeStatus: [String: Any]?

    init(date: Date,
         raw: [String: Any],
         powerSource: [String: Any]? = nil,
         adapterDetails: [String: Any]? = nil,
         sensors: [HIDSensors.Reading] = [],
         chargeStatus: [String: Any]? = nil) {
        self.date = date
        self.raw = raw
        self.powerSource = powerSource
        self.adapterDetails = adapterDetails
        self.sensors = sensors
        self.chargeStatus = chargeStatus
    }

    /// e.g. "Charging", "Charging On Hold", "Charged".
    var chargeStatusText: String? { chargeStatus?["chargeStatus"] as? String }

    /// True when powerd says so, or (sandboxed) when the phone is plugged in, below 100 %,
    /// not charging and no current is flowing into the battery. That is what Optimized
    /// Battery Charging and the charge limit look like from outside.
    var isChargingOnHold: Bool {
        if let text = chargeStatusText { return text == "Charging On Hold" }
        guard externalConnected, !isCharging, !fullyCharged, let p = percent, p >= 50, p < 100 else { return false }
        if let i = sensorBatteryCurrent { return abs(i) < 0.3 }
        return true
    }
    var holdIsInferred: Bool { chargeStatusText == nil && isChargingOnHold }

    // MARK: Charge state

    var isCharging: Bool {
        if raw["IsCharging"] != nil { return bool("IsCharging") }
        return bool("Is Charging", in: powerSource)
    }
    var externalConnected: Bool {
        if raw["ExternalConnected"] != nil { return bool("ExternalConnected") }
        if let state = powerSource?["Power Source State"] as? String { return state == "AC Power" }
        return bool("Raw External Connected", in: powerSource)
    }
    var fullyCharged: Bool {
        if raw["FullyCharged"] != nil { return bool("FullyCharged") }
        if bool("Is Charged", in: powerSource) { return true }
        return externalConnected && !isCharging && (percent ?? 0) >= 100
    }
    var isFinishingCharge: Bool { bool("Is Finishing Charge", in: powerSource) }
    var lowPowerMode: Bool { bool("LPM Active", in: powerSource) }
    var percent: Int? { signedInt("CurrentCapacity") ?? signedInt("Current Capacity", in: powerSource) }
    var cycleCount: Int? { signedInt("CycleCount") }
    var rawCurrentCapacity_mAh: Int? { signedInt("AppleRawCurrentCapacity") }
    var rawMaxCapacity_mAh: Int? { signedInt("AppleRawMaxCapacity") }
    var nominalCapacity_mAh: Int? { signedInt("NominalChargeCapacity") }
    var designCapacity_mAh: Int? { signedInt("DesignCapacity") }

    /// Minutes remaining (to full while charging, to empty otherwise).
    var timeRemainingMinutes: Int? {
        if let t = signedInt("TimeRemaining"), t >= 0, t != 65535 { return t }
        let key = isCharging ? "Time to Full Charge" : "Time to Empty"
        if let t = signedInt(key, in: powerSource), t > 0 { return t }
        return nil
    }

    var healthPercent: Double? {
        guard let max = rawMaxCapacity_mAh ?? nominalCapacity_mAh,
              let design = designCapacity_mAh, design > 0 else { return nil }
        return Double(max) / Double(design) * 100
    }

    var statusText: String {
        if isChargingOnHold { return "Charging on hold" }
        if fullyCharged && externalConnected { return "Full" }
        if isCharging { return isFinishingCharge ? "Finishing charge" : "Charging" }
        if externalConnected { return "Plugged in, not charging" }
        return "On battery"
    }

    // MARK: Battery electrical values (IOKit registry, macOS/simulator only)

    var voltage_mV: Int? { signedInt("Voltage") }
    /// Positive = charging, negative = discharging.
    var instantAmperage_mA: Int? { signedInt("InstantAmperage") }
    var amperage_mA: Int? { signedInt("Amperage") }
    var temperatureC: Double? { signedInt("Temperature").map { Double($0) / 100 } }

    var rawBatteryWatts: Double? {
        guard let v = voltage_mV, let a = instantAmperage_mA else { return nil }
        return Double(v) * Double(a) / 1_000_000
    }
    var averageBatteryWatts: Double? {
        guard let v = voltage_mV, let a = amperage_mA else { return nil }
        return Double(v) * Double(a) / 1_000_000
    }

    // MARK: Sensor-derived values (iOS)

    func sensor(_ name: String) -> Double? { sensors.first { $0.name == name }?.value }

    var usbInputVoltage: Double? { sensor("Charger VQ0u") }
    var usbInputCurrent: Double? { sensor("Charger IQ0u") }
    var wirelessInputVoltage: Double? { sensor("Charger VQ1u") }
    var isWirelessInput: Bool { (wirelessInputVoltage ?? 0) > 1 && (usbInputVoltage ?? 0) < 1 }

    var sensorBatteryCurrent: Double? { sensor("Charger IQ0B") }
    var sensorBatteryVoltage: Double? { sensor("Charger VQ0l") ?? sensor("PMU VP0u") }
    var sensorBatteryWatts: Double? {
        guard let i = sensorBatteryCurrent, let v = sensorBatteryVoltage else { return nil }
        return i * v
    }
    var sensorBatteryTemperatureC: Double? { sensor("gas gauge battery") }
    var chargerJunctionTemperatureC: Double? { sensor("Charger TQ0j") }
    var chargerDieTemperatureC: Double? { sensor("Charger TQ0d") }
    /// Hottest SoC die sensor (`PMU tdie1…n`).
    var socMaxTemperatureC: Double? {
        sensors.filter { $0.usage == 5 && $0.name.hasPrefix("PMU tdie") }.map(\.value).max()
    }

    // MARK: Merged values

    /// Power drawn from the adapter into the phone, in watts.
    var chargerInputWatts: Double? {
        if let v = usbInputVoltage, let i = usbInputCurrent, v > 0.5 { return v * i }
        if let mw = systemPowerIn_mW { return Double(mw) / 1000 }
        return nil
    }
    /// Power flowing into (+) or out of (-) the battery, in watts.
    var batteryWatts: Double? { rawBatteryWatts ?? sensorBatteryWatts }
    var batteryVoltage: Double? { voltage_mV.map { Double($0) / 1000 } ?? sensorBatteryVoltage }
    var batteryCurrent: Double? { instantAmperage_mA.map { Double($0) / 1000 } ?? sensorBatteryCurrent }
    var batteryTemperatureC: Double? { temperatureC ?? sensorBatteryTemperatureC }

    /// The headline number: charger input while plugged in, otherwise battery drain.
    var primaryWatts: (value: Double, label: String)? {
        if externalConnected, let w = chargerInputWatts {
            return (w, isWirelessInput ? "from charger (MagSafe)" : "from charger (USB-C)")
        }
        if let w = batteryWatts {
            return (w, externalConnected ? "into battery" : "from battery")
        }
        return nil
    }

    /// Average charge power implied by powerd's time-to-full estimate, in watts.
    func impliedWattsFromETA(batteryWattHours: Double) -> Double? {
        guard isCharging, let p = percent, let minutes = timeRemainingMinutes, minutes > 0 else { return nil }
        return Double(100 - p) / 100 * batteryWattHours / (Double(minutes) / 60)
    }

    // MARK: Adapter

    var adapter: [String: Any]? {
        (raw["AdapterDetails"] as? [String: Any])
            ?? (raw["AppleRawAdapterDetails"] as? [String: Any])
            ?? adapterDetails
    }
    var adapterWatts: Int? {
        if let w = signedInt("Watts", in: adapter) { return w }
        if let v = adapterVoltage_mV, let c = adapterCurrent_mA { return v * c / 1_000_000 }
        return nil
    }
    var adapterVoltage_mV: Int? { signedInt("Voltage", in: adapter) ?? signedInt("AdapterVoltage", in: adapter) }
    var adapterCurrent_mA: Int? { signedInt("Current", in: adapter) }
    var adapterName: String? { adapter?["Name"] as? String }
    var adapterDescription: String? { adapter?["Description"] as? String }
    var adapterManufacturer: String? { adapter?["Manufacturer"] as? String }
    var adapterModel: String? { adapter?["Model"].map { String(describing: $0) } }
    var adapterPowerTier: Int? { signedInt("AdapterPowerTier", in: adapter) }
    var adapterActiveProfile: Int? { signedInt("UsbHvcHvcIndex", in: adapter) }
    var adapterIsWireless: Bool { bool("IsWireless", in: adapter) }

    /// The PD profile currently in use, or the adapter's reported voltage/current.
    var adapterNegotiated: (voltage_mV: Int, current_mA: Int)? {
        if let active = adapterActiveProfile, let p = adapterProfiles.first(where: { $0.index == active }) {
            return (p.voltage_mV, p.current_mA)
        }
        if let v = adapterVoltage_mV, let c = adapterCurrent_mA { return (v, c) }
        return nil
    }

    /// One-line adapter description for the hero card, e.g. "61W USB-C Power Adapter · 15.0 V × 3.00 A".
    var adapterSummary: String? {
        guard let name = adapterName ?? adapterDescription else { return nil }
        var text = name
        if let n = adapterNegotiated {
            text += String(format: " · %.1f V × %.2f A", Double(n.voltage_mV) / 1000, Double(n.current_mA) / 1000)
        } else if let w = adapterWatts {
            text += " · \(w) W"
        }
        if adapterIsWireless { text += " · wireless" }
        return text
    }

    /// USB PD / HVC power profiles the adapter advertised.
    var adapterProfiles: [(index: Int, voltage_mV: Int, current_mA: Int)] {
        guard let menu = adapter?["UsbHvcMenu"] as? [[String: Any]] else { return [] }
        return menu.compactMap { entry in
            guard let v = signedInt("MaxVoltage", in: entry), let c = signedInt("MaxCurrent", in: entry) else { return nil }
            return (signedInt("Index", in: entry) ?? 0, v, c)
        }
    }

    // MARK: Charger / telemetry (IOKit registry, macOS only)

    var chargerData: [String: Any]? { raw["ChargerData"] as? [String: Any] }
    var chargingCurrent_mA: Int? { signedInt("ChargingCurrent", in: chargerData) }
    var chargingVoltage_mV: Int? { signedInt("ChargingVoltage", in: chargerData) }
    var notChargingReason: Int? { signedInt("NotChargingReason", in: chargerData) }

    var telemetry: [String: Any]? { raw["PowerTelemetryData"] as? [String: Any] }
    var systemPowerIn_mW: Int? { signedInt("SystemPowerIn", in: telemetry) }
    var systemLoad_mW: Int? { signedInt("SystemLoad", in: telemetry) }
    var adapterEfficiencyLoss_mW: Int? { signedInt("AdapterEfficiencyLoss", in: telemetry) }
    var telemetryRows: [(key: String, value: Int)] {
        guard let t = telemetry else { return [] }
        return t.keys.sorted().compactMap { key in signedInt(key, in: t).map { (key, $0) } }
    }

    // MARK: Helpers

    /// IOKit reports some 32-bit signed values as wrapped unsigned 32/64-bit numbers
    /// (e.g. a discharge current of -658 mA shows up as 18446744073709550958).
    static func signed(_ number: NSNumber) -> Int {
        let value = number.int64Value
        if value > Int64(Int32.max) || value < Int64(Int32.min) {
            return Int(Int32(truncatingIfNeeded: value))
        }
        return Int(value)
    }

    private func signedInt(_ key: String) -> Int? { signedInt(key, in: raw) }

    private func signedInt(_ key: String, in dict: [String: Any]?) -> Int? {
        guard let dict, let number = dict[key] as? NSNumber else { return nil }
        return Self.signed(number)
    }

    private func bool(_ key: String) -> Bool { bool(key, in: raw) }

    private func bool(_ key: String, in dict: [String: Any]?) -> Bool {
        guard let dict else { return false }
        if let b = dict[key] as? Bool { return b }
        if let n = dict[key] as? NSNumber { return n.boolValue }
        return false
    }
}
