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

    /// Model identifier, e.g. "iPhone19,3".
    static let modelIdentifier: String = {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.machine", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }()

    /// iPhone 18 Pro generation (iPhone19,x). On the 18 Pro Max, wired input above about 30 W
    /// reads about half of what a USB-C meter shows (measured here and by two MiniWatts users).
    static let readsHalfAboveThirtyWatts = modelIdentifier.hasPrefix("iPhone19,")

    /// True when the half reading can apply: an 18 Pro generation phone on a wired adapter whose
    /// negotiated profile can supply more than 30 W. The app cannot tell from its sensors when the
    /// phone is in that mode, so this is a caution, not a detection.
    var mayReadHalf: Bool {
        guard Self.readsHalfAboveThirtyWatts, externalConnected, !isWirelessInput, !adapterIsWireless,
              let contract = adapterNegotiated else { return false }
        return contract.voltage_mV * contract.current_mA > 30_000_000
    }

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

    /// Value of one SMC key. iOS 27 publishes each key through two services that read it a few
    /// milliseconds apart, so the copies are averaged, never summed. Falls back to the product
    /// name when a service has no LocationID.
    func sensor(key: String, name: String) -> Double? {
        var matches = sensors.filter { $0.key == key }
        if matches.isEmpty { matches = sensors.filter { $0.key.isEmpty && $0.name == name } }
        guard !matches.isEmpty else { return nil }
        return matches.map(\.value).reduce(0, +) / Double(matches.count)
    }

    var usbInputVoltage: Double? { sensor(key: "VQ0u", name: "Charger VQ0u") }
    var usbInputCurrent: Double? { sensor(key: "IQ0u", name: "Charger IQ0u") }
    var wirelessInputVoltage: Double? { sensor(key: "VQ1u", name: "Charger VQ1u") }
    var isWirelessInput: Bool { (wirelessInputVoltage ?? 0) > 1 && (usbInputVoltage ?? 0) < 1 }
    /// iOS describes MagSafe pucks as "magsafe chg" and plain Qi pads as "baseline arcas".
    var isMagSafe: Bool { (adapterDescription ?? adapterName ?? "").lowercased().contains("magsafe") }
    var wirelessKind: String { isMagSafe ? "MagSafe" : "wireless" }

    /// Charge current into the battery. IQ0B reads 0 on battery power and no readable sensor
    /// reports discharge current, so it is only meaningful while external power is connected.
    var sensorBatteryCurrent: Double? {
        guard externalConnected else { return nil }
        return sensor(key: "IQ0B", name: "Charger IQ0B")
    }
    var sensorBatteryVoltage: Double? {
        sensor(key: "VQ0l", name: "Charger VQ0l") ?? sensor(key: "VP0u", name: "PMU VP0u")
    }
    var sensorBatteryWatts: Double? {
        guard let i = sensorBatteryCurrent, let v = sensorBatteryVoltage else { return nil }
        return i * v
    }

    /// The four "gas gauge battery" temperatures (SMC keys TG0B, TG0C, TG0H, TG0V), coolest first.
    private var gasGaugeReadings: [HIDSensors.Reading] {
        let all = sensors.filter { $0.usage == 5 && $0.name == "gas gauge battery" }
        // One reading per key; iOS 27 may publish a key twice.
        var byKey: [String: HIDSensors.Reading] = [:]
        var unkeyed: [HIDSensors.Reading] = []
        for r in all { if r.key.isEmpty { unkeyed.append(r) } else if byKey[r.key] == nil { byKey[r.key] = r } }
        return (Array(byKey.values) + unkeyed).sorted { $0.value < $1.value }
    }

    /// Median of the gas-gauge temperatures. On both test phones three of the four agree within
    /// 0.1 °C and the fourth (TG0B on the 18 Pro Max) reads 1 to 13 °C above them while charging.
    /// Apple does not document what each key measures; the median follows the three that agree.
    var sensorBatteryTemperatureC: Double? {
        let values = gasGaugeReadings.map(\.value)
        guard !values.isEmpty else { return nil }
        let mid = values.count / 2
        return values.count.isMultiple(of: 2) ? (values[mid - 1] + values[mid]) / 2 : values[mid]
    }

    /// The hottest gas-gauge key and its value, when it reads more than 1.5 °C above the median.
    var batteryHotspot: (key: String, celsius: Double)? {
        guard let median = sensorBatteryTemperatureC, let hottest = gasGaugeReadings.last,
              hottest.value > median + 1.5 else { return nil }
        return (hottest.key.isEmpty ? "?" : hottest.key, hottest.value)
    }
    /// Apple's sensor "Charger", SMC key TQ0j.
    var chargerTemperatureC: Double? { sensor(key: "TQ0j", name: "Charger TQ0j") }
    /// Hottest of the sensors Apple names "PMU tdie…" (SMC keys TP…b and TP…l). These belong to the
    /// power-management unit; the phone exposes no sensor named for the CPU or SoC.
    var pmuDieMaxTemperatureC: Double? {
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

    /// The headline number: charger input while plugged in. On battery only the macOS registry
    /// reports drain; iOS has no discharge sensor, so the headline is empty there.
    var primaryWatts: (value: Double, label: String)? {
        if externalConnected, let w = chargerInputWatts {
            return (w, isWirelessInput ? "from charger (MagSafe)" : "from charger (USB-C)")
        }
        if let w = batteryWatts {
            if externalConnected { return (w, isWirelessInput ? "into battery (\(wirelessKind))" : "into battery") }
            return (w, "from battery")
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
        if let active = adapterActiveProfile,
           let p = adapterProfiles.first(where: { $0.index == active && $0.isReported }) {
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

    struct AdapterProfile {
        let index: Int
        let voltage_mV: Int
        let current_mA: Int
        /// iOS fills entries it does not decode with 65535 mV / 65535 mA. A fixed USB PD profile
        /// cannot encode either (limits are 51.15 V and 10.23 A), so these carry no values.
        var isReported: Bool { voltage_mV != 0xFFFF && current_mA != 0xFFFF }
    }

    /// USB PD / HVC power profiles the adapter advertised.
    var adapterProfiles: [AdapterProfile] {
        guard let menu = adapter?["UsbHvcMenu"] as? [[String: Any]] else { return [] }
        return menu.compactMap { entry in
            guard let v = signedInt("MaxVoltage", in: entry), let c = signedInt("MaxCurrent", in: entry) else { return nil }
            return AdapterProfile(index: signedInt("Index", in: entry) ?? 0, voltage_mV: v, current_mA: c)
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
