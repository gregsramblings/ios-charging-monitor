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

    /// Usable battery energy used to convert %/h into watts.
    /// iPhone 17 Pro Max: 5088 mAh × ~3.87 V nominal ≈ 19.7 Wh. Adjust for other models.
    let batteryWattHours: Double = 19.7

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
