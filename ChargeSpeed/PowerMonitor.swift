import Foundation
import Combine

@MainActor
final class PowerMonitor: ObservableObject {
    @Published private(set) var snapshot: PowerSnapshot?
    @Published private(set) var errorMessage: String?
    /// Last ~2 minutes of the headline watts, one sample per refresh.
    @Published private(set) var history: [Double] = []
    /// Charge power estimated from how fast the percentage moves. Fallback for
    /// devices where neither the IOKit registry nor the HID sensors give current.
    @Published private(set) var estimate: RateEstimate?
    /// Optimized Battery Charging / charge limit / clean energy settings from PowerUI.
    @Published private(set) var smartCharge: SmartChargeStatus?
    /// IOReturn from the last `IOPSCopyChargeStatus` call; nonzero means powerd refused.
    @Published private(set) var chargeStatusError: Int32 = 0
    /// Darwin notification state for smart-charge status changes; -1 when unavailable.
    @Published private(set) var smartChargeNotifyState: Int64 = -1
    /// Most recent observed charging hold, persisted across launches.
    @Published private(set) var lastHold: HoldObservation?

    struct HoldObservation: Codable {
        let percent: Int
        let start: Date
        var end: Date?
    }

    /// iOS's own thermal verdict; `.serious` and `.critical` mean the system is throttling.
    @Published private(set) var thermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
    var isThrottling: Bool { thermalState == .serious || thermalState == .critical }

    /// iPhone 18 Pro only: set while the second wired charge path is engaged. That path has no
    /// sensors, so input and battery readings are about half the true value.
    @Published private(set) var unmeteredPathEngaged = false
    private var halfContractSince: Date?

    /// Highest charger input power seen since the last reset, persisted across launches.
    @Published private(set) var peak: PeakRecord?
    /// Identity of the current charging session, persisted so a relaunch mid-session keeps the peak.
    /// A session starts at plug-in and survives reaching full and topping off; it ends at unplug.
    struct ChargingSession: Codable {
        var start: Date
        var adapterIdentity: String?
        var lastSeenPluggedIn: Bool
        var lastSeenPercent: Int?
    }
    private var session: ChargingSession?
    private var lastPluggedIn: Bool?
    private static let sessionKey = "chargingSession"

    struct PeakRecord: Codable {
        let watts: Double
        let date: Date
        let adapter: String?
        /// Which measurement this was, e.g. "from charger (USB-C)" or "into battery (MagSafe)".
        var label: String?
    }

    /// Last two headline samples, for the median-of-three glitch filter.
    private var recentSamples: [Double] = []
    private static let peakKey = "peakRecord"

    private var currentHold: HoldObservation?
    private var holdCandidateSince: Date?
    private var lastExternalConnected: Bool?
    private var externalChangedAt: Date = .distantPast
    /// A hold must persist this long before it counts; plug-in transitions look like a hold for a second or two.
    private static let holdDebounce: TimeInterval = 45
    private static let holdKey = "lastHoldObservation"

    struct RateEstimate {
        let watts: Double
        let steps: Int
        let window: TimeInterval
    }

    /// Usable battery energy used to convert %/h into watts, by model identifier.
    /// iPhone 17 Pro Max: 19.77 Wh (5088 mAh). iPhone 18 Pro Max: 21.75 Wh (5567 mAh, iFixit).
    let batteryWattHours: Double = {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.machine", &buffer, &size, nil, 0)
        switch String(cString: buffer) {
        case "iPhone19,3", "iPhone19,7": return 21.75
        default: return 19.7
        }
    }()

    private let reader = IOKitBattery()
    private let sensors = HIDSensors()
    private let smartChargeReader = SmartChargeReader()
    private var smartChargeInFlight = false
    private var task: Task<Void, Never>?
    private let interval: Duration = .seconds(1)
    private let historyLimit = 120
    private var refreshCount = 0
    private var percentLog: [(date: Date, percent: Int)] = []
    private var lastCharging: Bool?

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.holdKey),
           let hold = try? JSONDecoder().decode(HoldObservation.self, from: data) {
            // Drop blips recorded before debouncing existed.
            if let end = hold.end, end.timeIntervalSince(hold.start) < Self.holdDebounce {
                UserDefaults.standard.removeObject(forKey: Self.holdKey)
            } else {
                lastHold = hold
            }
        }
        if let data = UserDefaults.standard.data(forKey: Self.peakKey),
           let record = try? JSONDecoder().decode(PeakRecord.self, from: data) {
            peak = record
        }
        if let data = UserDefaults.standard.data(forKey: Self.sessionKey),
           let saved = try? JSONDecoder().decode(ChargingSession.self, from: data) {
            session = saved
        }
    }

    func resetPeak() {
        peak = nil
        recentSamples.removeAll()
        UserDefaults.standard.removeObject(forKey: Self.peakKey)
    }

    func start() {
        task?.cancel()
        task = Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                try? await Task.sleep(for: self?.interval ?? .seconds(1))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    func refresh() {
        guard let reader else {
            errorMessage = "IOKit could not be loaded on this device."
            return
        }
        guard let props = reader.readProperties() else {
            errorMessage = "No IOPMPowerSource service found."
            return
        }
        errorMessage = nil
        refreshCount += 1

        let sources = reader.readPowerSources()
        let internalBattery = sources.first { ($0["Type"] as? String) == "InternalBattery" } ?? sources.first
        if refreshCount % 30 == 1 { sensors?.rescan() }
        let snap = PowerSnapshot(date: .now,
                                 raw: props,
                                 powerSource: internalBattery,
                                 adapterDetails: reader.readAdapterDetails(),
                                 sensors: sensors?.read() ?? [],
                                 chargeStatus: reader.readChargeStatus())
        chargeStatusError = reader.chargeStatusError
        snapshot = snap
        updateEstimate(snap)
        updateHold(snap)
        updateSession(snap)
        updatePeak(snap)
        updateUnmeteredPath(snap)
        let state = ProcessInfo.processInfo.thermalState
        if state != thermalState { thermalState = state }
        let notifyState = SmartChargeNotificationState()
        if notifyState != smartChargeNotifyState {
            #if DEBUG
            print("SMARTCHARGE notify state \(smartChargeNotifyState) -> \(notifyState)")
            #endif
            smartChargeNotifyState = notifyState
        }
        if refreshCount % 10 == 1 { refreshSmartCharge() }

        let sample = snap.primaryWatts?.value ?? estimate?.watts
        if let sample {
            history.append(sample)
            if history.count > historyLimit { history.removeFirst(history.count - historyLimit) }
        }

        #if DEBUG
        if refreshCount == 1 || refreshCount % 15 == 0 {
            let readings = snap.sensors.map { "\($0.name)=\($0.formatted)" }.joined(separator: ", ")
            print("CHARGESTATUS kr=0x\(String(UInt32(bitPattern: reader.chargeStatusError), radix: 16)) dict=\(String(describing: snap.chargeStatus))")
            print("TICK \(refreshCount) status=\(snap.statusText) primary=\(String(describing: snap.primaryWatts)) battery=\(String(describing: snap.batteryWatts)) sensors=[\(readings)]")
        }
        #endif
    }

    /// PowerUI calls go over XPC synchronously, so they run off the main actor.
    private func refreshSmartCharge() {
        guard let reader = smartChargeReader, !smartChargeInFlight else {
            if smartChargeReader == nil, smartCharge == nil {
                let status = SmartChargeStatus()
                status.available = false
                status.errorMessage = "PowerUI framework unavailable"
                smartCharge = status
            }
            return
        }
        smartChargeInFlight = true
        Task.detached(priority: .utility) { [weak self] in
            let status = reader.read()
            await MainActor.run {
                guard let self else { return }
                self.smartCharge = status
                self.smartChargeInFlight = false
                #if DEBUG
                if self.refreshCount <= 1 {
                    print("SMARTCHARGE available=\(status.available) obc=\(status.obcEnabled) mcl=\(status.mclEnabled) limit=\(status.mclLimit) deoc=\(status.deocEnabled) current=\(status.currentChargeLimit) recommended=\(status.recommendedChargeLimit) engaged=\(status.obcEngaged) engagedLimit=\(status.engagedChargeLimit) override=\(status.chargingOverrideAllowed) ui=\(status.uiState) supported=\(status.obcSupported)/\(status.mclSupported)/\(status.deocSupported) deadline=\(String(describing: status.fullChargeDeadline)) errors=\(status.callErrors)")
                    print("SMARTCHARGE status=\(String(describing: status.rawStatus))")
                }
                #endif
            }
        }
    }

    func rawDump() -> String {
        guard let snap = snapshot else { return "" }
        var text = "IOPMPowerSource:\n" + dump(snap.raw)
        if let cs = snap.chargeStatus { text += "\n\nChargeStatus:\n" + dump(cs) }
        if let sc = smartCharge {
            text += "\n\nSmartCharge: obc=\(sc.obcEnabled) mcl=\(sc.mclEnabled) limit=\(sc.mclLimit) deoc=\(sc.deocEnabled) engaged=\(sc.obcEngaged) engagedLimit=\(sc.engagedChargeLimit) ui=\(sc.uiState) errors=\(sc.callErrors)"
            if let raw = sc.rawStatus as? [String: Any] { text += "\n" + dump(raw) }
        }
        if let ps = snap.powerSource { text += "\n\nIOPS:\n" + dump(ps) }
        if let ad = snap.adapterDetails { text += "\n\nAdapter:\n" + dump(ad) }
        if !snap.sensors.isEmpty {
            text += "\n\nSensors:\n" + snap.sensors.map { "\($0.name) = \($0.formatted)" }.joined(separator: "\n")
        }
        return text
    }

    private func dump(_ dict: [String: Any]) -> String {
        dict.keys.sorted().map { "\($0) = \(String(describing: dict[$0]!))" }.joined(separator: "\n")
    }

    /// Records when the phone sits on a charging hold and at what level, so the limit
    /// (80/85/90/95 % or Optimized Battery Charging's 80 %) can be read off later.
    private func updateHold(_ snap: PowerSnapshot) {
        if lastExternalConnected != snap.externalConnected {
            lastExternalConnected = snap.externalConnected
            externalChangedAt = snap.date
        }
        let settled = snap.date.timeIntervalSince(externalChangedAt) >= Self.holdDebounce
        if snap.isChargingOnHold, settled, let p = snap.percent {
            if holdCandidateSince == nil { holdCandidateSince = snap.date }
            if currentHold == nil, let since = holdCandidateSince,
               snap.date.timeIntervalSince(since) >= Self.holdDebounce {
                currentHold = HoldObservation(percent: p, start: since, end: nil)
                lastHold = currentHold
                persistHold()
            }
        } else {
            holdCandidateSince = nil
            if currentHold != nil {
                currentHold?.end = snap.date
                lastHold = currentHold
                persistHold()
                currentHold = nil
            }
        }
    }

    /// Latches when the metered path sits at half the negotiated PD current for 10 s: a single
    /// path draws what it needs up to the contract, while the split pins each path at exactly half.
    /// Unlatches on unplug or whenever the metered path exceeds 58 % of the contract, which the
    /// split can never do. Verified against a display charger on an iPhone 18 Pro Max: 43.8 W
    /// true, 21.9 W read, sensor pinned at 1.50 A of a 3.00 A contract.
    private func updateUnmeteredPath(_ snap: PowerSnapshot) {
        guard PowerSnapshot.hasUnmeteredChargePath, snap.externalConnected, !snap.isWirelessInput,
              let current = snap.usbInputCurrent, let contract = snap.contractCurrentA, contract > 0 else {
            unmeteredPathEngaged = false
            halfContractSince = nil
            return
        }
        if current > contract * 0.58 {
            unmeteredPathEngaged = false
            halfContractSince = nil
            return
        }
        if abs(current - contract / 2) <= contract * 0.05 {
            if halfContractSince == nil { halfContractSince = snap.date }
            if !unmeteredPathEngaged, let since = halfContractSince, snap.date.timeIntervalSince(since) >= 10 {
                unmeteredPathEngaged = true
            }
        } else {
            halfContractSince = nil
        }
    }

    /// Adapter serial where available, otherwise a composite of the adapter's static fields.
    private func adapterIdentity(_ snap: PowerSnapshot) -> String? {
        guard let a = snap.adapter else { return nil }
        if let serial = a["SerialString"] as? String, !serial.isEmpty { return serial }
        return ["Name", "Description", "Model", "AdapterID"].compactMap { a[$0].map { String(describing: $0) } }.joined(separator: "|")
    }

    /// Detects plug-in events and resets the peak at the start of each charging session.
    /// While running, any unplugged → plugged transition is a new session. On the first tick after
    /// launch, the persisted session is continued only if the phone was still plugged in when last
    /// seen, the adapter is the same, and the level has not dropped (i.e. no unplug happened while
    /// the app was closed).
    private func updateSession(_ snap: PowerSnapshot) {
        let pluggedIn = snap.externalConnected
        defer { lastPluggedIn = pluggedIn }

        if pluggedIn {
            var isNew = false
            if lastPluggedIn == false {
                isNew = true
            } else if lastPluggedIn == nil {
                if let saved = session, saved.lastSeenPluggedIn,
                   saved.adapterIdentity == adapterIdentity(snap),
                   (snap.percent ?? 0) >= (saved.lastSeenPercent ?? 0) - 1 {
                    isNew = false
                } else {
                    isNew = true
                }
            }
            if isNew {
                peak = nil
                recentSamples.removeAll()
                history.removeAll()
                UserDefaults.standard.removeObject(forKey: Self.peakKey)
                session = ChargingSession(start: snap.date, adapterIdentity: adapterIdentity(snap),
                                          lastSeenPluggedIn: true, lastSeenPercent: snap.percent)
                persistSession()
            } else if var current = session {
                if current.adapterIdentity == nil { current.adapterIdentity = adapterIdentity(snap) }
                if !current.lastSeenPluggedIn || current.lastSeenPercent != snap.percent {
                    current.lastSeenPluggedIn = true
                    current.lastSeenPercent = snap.percent
                    session = current
                    persistSession()
                } else {
                    session = current
                }
            } else {
                session = ChargingSession(start: snap.date, adapterIdentity: adapterIdentity(snap),
                                          lastSeenPluggedIn: true, lastSeenPercent: snap.percent)
                persistSession()
            }
        } else if var current = session, current.lastSeenPluggedIn {
            current.lastSeenPluggedIn = false
            current.lastSeenPercent = snap.percent
            session = current
            persistSession()
        }
    }

    private func persistSession() {
        if let session, let data = try? JSONEncoder().encode(session) {
            UserDefaults.standard.set(data, forKey: Self.sessionKey)
        }
    }

    /// Records the peak of the headline number (charger input on USB-C, battery input on
    /// MagSafe where no input current sensor exists) for the current charging session. Uses the
    /// median of the last three samples so a single glitchy reading cannot set it.
    private func updatePeak(_ snap: PowerSnapshot) {
        guard snap.externalConnected, let primary = snap.primaryWatts, primary.value > 0 else {
            recentSamples.removeAll()
            return
        }
        recentSamples.append(primary.value)
        if recentSamples.count > 3 { recentSamples.removeFirst(recentSamples.count - 3) }
        guard recentSamples.count == 3 else { return }
        let candidate = recentSamples.sorted()[1]
        if candidate > (peak?.watts ?? 0) {
            peak = PeakRecord(watts: candidate, date: snap.date,
                              adapter: snap.adapterName ?? snap.adapterDescription,
                              label: primary.label)
            if let data = try? JSONEncoder().encode(peak) {
                UserDefaults.standard.set(data, forKey: Self.peakKey)
            }
        }
    }

    private func persistHold() {
        if let hold = lastHold, let data = try? JSONEncoder().encode(hold) {
            UserDefaults.standard.set(data, forKey: Self.holdKey)
        }
    }

    /// Tracks 1% transitions and converts the slope into watts.
    /// The first logged sample is mid-percent, so at least two transitions are needed.
    private func updateEstimate(_ snap: PowerSnapshot) {
        guard let percent = snap.percent else { estimate = nil; return }
        if lastCharging != snap.isCharging {
            lastCharging = snap.isCharging
            percentLog.removeAll()
            estimate = nil
        }
        if percentLog.last?.percent != percent {
            percentLog.append((snap.date, percent))
            if percentLog.count > 7 { percentLog.removeFirst(percentLog.count - 7) }
        }
        let transitions = percentLog.dropFirst()
        guard transitions.count >= 2, let first = transitions.first, let last = transitions.last else { return }
        let hours = last.date.timeIntervalSince(first.date) / 3600
        guard hours > 0 else { return }
        let deltaPercent = Double(last.percent - first.percent)
        estimate = RateEstimate(watts: deltaPercent / 100 * batteryWattHours / hours,
                                steps: transitions.count - 1,
                                window: last.date.timeIntervalSince(first.date))
    }
}
