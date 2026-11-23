import Foundation

/// One point of a recorded charge, averaged over `ChargeHistoryStore.bucketSeconds`.
/// Short keys keep the history file small.
struct ChargeSample: Codable, Equatable {
    /// Seconds since the record started.
    var t: Double
    /// Headline watts: from the charger on USB-C, into the battery on wireless.
    var w: Double?
    /// Watts into the battery.
    var b: Double?
    /// Battery percent.
    var p: Int?
    /// Battery temperature, °C.
    var c: Double?

    var percentValue: Double? { p.map(Double.init) }
}

/// One charge, plug-in to unplug, sampled while the app was open.
struct ChargeRecord: Codable, Identifiable, Equatable {
    var id = UUID()
    var start: Date
    var end: Date?
    var adapterIdentity: String?
    var adapterName: String?
    /// What the headline measured, e.g. "from charger (USB-C)" or "into battery (MagSafe)".
    var headlineLabel: String?
    var wireless = false
    var negotiatedVolts: Double?
    var negotiatedAmps: Double?
    /// The 18 Pro Max half-reading caution applied at some point during this charge.
    var mayReadHalf = false
    /// Highest headline watts, median of three 1 s readings (the live peak's filter).
    var peak: Double?
    var note: String?
    /// Charger the user said this charge was on, a `ChargeHistoryStore` charger key. Overrides
    /// detection, which cannot tell wireless chargers apart (all report e.g. "mpp chg").
    var chargerOverride: String?
    var samples: [ChargeSample] = []

    var isOpen: Bool { end == nil }
    /// Plug-in to the last sample, including any time the app was closed.
    var recordedSpan: TimeInterval { samples.last?.t ?? 0 }
    var startPercent: Int? { samples.first { $0.p != nil }?.p }
    var endPercent: Int? { samples.last { $0.p != nil }?.p }
    var negotiatedWatts: Double? { negotiatedVolts.flatMap { v in negotiatedAmps.map { v * $0 } } }
    var headlineIsChargerInput: Bool { headlineLabel?.hasPrefix("from charger") ?? false }
    var averageWatts: Double? { Self.mean(samples.compactMap(\.w).filter { $0 > 0.05 }) }
    var averageBatteryWatts: Double? { Self.mean(samples.compactMap(\.b).filter { $0 > 0.05 }) }
    var maxBatteryTemperature: Double? { samples.compactMap(\.c).max() }

    /// Energy into the battery: battery watts integrated over time. Spans longer than
    /// `gapSeconds` (app closed) are skipped, not interpolated, so this
    /// undercounts a charge the app did not watch throughout.
    var energyIntoBatteryWh: Double? {
        var wh = 0.0, any = false
        for (a, z) in zip(samples, samples.dropFirst()) {
            guard let wa = a.b, let wz = z.b else { continue }
            let dt = z.t - a.t
            guard dt > 0, dt <= Self.gapSeconds else { continue }
            wh += (wa + wz) / 2 * dt / 3600
            any = true
        }
        return any ? wh : nil
    }

    /// Percent gained per hour, from the first and last readings. Valid across gaps:
    /// both ends are measured.
    var percentPerHour: Double? {
        guard let s = startPercent, let e = endPercent, e > s,
              let t0 = samples.first(where: { $0.p != nil })?.t,
              let t1 = samples.last(where: { $0.p != nil })?.t, t1 - t0 > 60 else { return nil }
        return Double(e - s) / ((t1 - t0) / 3600)
    }

    /// Mean headline watts within a battery-percent range. Charge power falls as the battery
    /// fills, so two charges only compare fairly over the same range.
    func averageWatts(percentRange r: ClosedRange<Int>) -> Double? {
        Self.mean(samples.filter { $0.p.map(r.contains) ?? false }.compactMap(\.w).filter { $0 > 0.05 })
    }

    static func mean(_ v: [Double]) -> Double? { v.isEmpty ? nil : v.reduce(0, +) / Double(v.count) }

    /// A jump between samples longer than this is a gap (the app was closed).
    static let gapSeconds: TimeInterval = 60
}

/// Persists every charge. Closed charges live in one file, written when the list changes; the
/// open charge has its own small file, written every 30 s, so a long charge costs little.
@MainActor
final class ChargeHistoryStore: ObservableObject {
    /// Newest first. The open record, if any, is first.
    @Published private(set) var records: [ChargeRecord] = []
    /// User names for chargers, keyed by `chargerKey`.
    @Published private(set) var nicknames: [String: String] = [:]

    static let bucketSeconds: TimeInterval = 10
    static let maxRecords = 200
    /// 4 h at 10 s. Longer charges are thinned 2:1 so a record stays small.
    static let maxSamples = 1440

    private var bucket: [(date: Date, w: Double?, b: Double?, p: Int?, c: Double?)] = []
    private var recentHeadline: [Double] = []
    private var lastOpenSave = Date.distantPast
    private let dir: URL
    private var archiveURL: URL { dir.appendingPathComponent("charges.json") }
    private var openURL: URL { dir.appendingPathComponent("open-charge.json") }
    private static let nicknamesKey = "chargerNicknames"

    init() {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        dir = base.appendingPathComponent("ChargeHistory", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let decoder = JSONDecoder()
        var list = (try? Data(contentsOf: archiveURL)).flatMap { try? decoder.decode([ChargeRecord].self, from: $0) } ?? []
        if let data = try? Data(contentsOf: openURL),
           let open = try? decoder.decode(ChargeRecord.self, from: data), open.isOpen {
            list.insert(open, at: 0)
        }
        records = list
        nicknames = UserDefaults.standard.dictionary(forKey: Self.nicknamesKey) as? [String: String] ?? [:]
    }

    var openRecord: ChargeRecord? { records.first.flatMap { $0.isOpen ? $0 : nil } }

    /// The charger as detected: serial (or composite) identity, else the reported name.
    func detectedKey(_ r: ChargeRecord) -> String { r.adapterIdentity ?? r.adapterName ?? "unknown" }

    /// Charger grouping key: the user's choice, else the detected charger.
    func chargerKey(_ r: ChargeRecord) -> String { r.chargerOverride ?? detectedKey(r) }

    func name(for r: ChargeRecord) -> String { name(forKey: chargerKey(r)) }

    func name(forKey key: String) -> String {
        if let n = nicknames[key] { return n }
        if let r = records.first(where: { detectedKey($0) == key }) {
            return r.adapterName ?? (r.wireless ? "Wireless charger" : "Unknown charger")
        }
        return "Charger"
    }

    /// Every charger a charge can be assigned to: detected ones, ones already chosen, and ones
    /// the user created. Sorted by name.
    var chargerChoices: [String] {
        let keys = Set(records.map(detectedKey) + records.map(chargerKey)
                       + nicknames.keys.filter { $0.hasPrefix(Self.userKeyPrefix) })
        return keys.sorted { name(forKey: $0).localizedCaseInsensitiveCompare(name(forKey: $1)) == .orderedAscending }
    }

    private static let userKeyPrefix = "user:"

    /// Creates a charger that only exists by the user's say-so and returns its key.
    func newCharger(named name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let key = Self.userKeyPrefix + UUID().uuidString
        setNickname(trimmed, for: key)
        return key
    }

    /// Assigns a charge to a charger; the detected charger's key (or nil) clears the override.
    func setCharger(_ key: String?, for id: UUID) {
        guard let i = records.firstIndex(where: { $0.id == id }) else { return }
        let override = key == detectedKey(records[i]) ? nil : key
        guard records[i].chargerOverride != override else { return }
        records[i].chargerOverride = override
        if records[i].isOpen { saveOpen(force: true) } else { saveArchive() }
    }

    /// Starts a record at plug-in. A record still open (the app was closed through an unplug)
    /// is closed at its last sample first.
    func begin(at date: Date, snap: PowerSnapshot, adapterIdentity: String?) {
        closeOpen(at: nil)
        var r = ChargeRecord(start: date)
        r.adapterIdentity = adapterIdentity
        fill(&r, from: snap)
        records.insert(r, at: 0)
        bucket.removeAll()
        recentHeadline.removeAll()
        saveOpen(force: true)
    }

    /// Adds one 1 s reading to the open record.
    func record(_ snap: PowerSnapshot, adapterIdentity: String?) {
        guard var r = openRecord else { return }
        if r.adapterIdentity == nil { r.adapterIdentity = adapterIdentity }
        fill(&r, from: snap)
        let headline = snap.primaryWatts?.value
        if let headline, headline > 0 {
            recentHeadline.append(headline)
            if recentHeadline.count > 3 { recentHeadline.removeFirst(recentHeadline.count - 3) }
            if recentHeadline.count == 3 {
                let median = recentHeadline.sorted()[1]
                if median > (r.peak ?? 0) { r.peak = median }
            }
        }
        if let first = bucket.first, snap.date.timeIntervalSince(first.date) >= Self.bucketSeconds {
            appendBucket(to: &r)
        }
        bucket.append((snap.date, headline, snap.batteryWatts, snap.percent, snap.batteryTemperatureC))
        records[0] = r
        saveOpen(force: false)
    }

    /// Ends the open record at unplug. `date` nil means the unplug happened while the app was
    /// closed; the record then ends at its last sample.
    func end(at date: Date?) { closeOpen(at: date) }

    /// Writes the partial bucket and the open record, e.g. when the app goes to the background.
    func flush() {
        guard var r = openRecord else { return }
        appendBucket(to: &r)
        records[0] = r
        saveOpen(force: true)
    }

    func delete(_ ids: Set<UUID>) {
        records.removeAll { ids.contains($0.id) && !$0.isOpen }
        saveArchive()
    }

    func setNote(_ note: String, for id: UUID) {
        guard let i = records.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard records[i].note ?? "" != trimmed else { return }
        records[i].note = trimmed.isEmpty ? nil : trimmed
        if records[i].isOpen { saveOpen(force: true) } else { saveArchive() }
    }

    func setNickname(_ name: String, for key: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        nicknames[key] = trimmed.isEmpty ? nil : trimmed
        UserDefaults.standard.set(nicknames, forKey: Self.nicknamesKey)
    }

    // MARK: Private

    private func fill(_ r: inout ChargeRecord, from snap: PowerSnapshot) {
        if r.adapterName == nil { r.adapterName = snap.adapterName ?? snap.adapterDescription }
        if snap.isWirelessInput || snap.adapterIsWireless { r.wireless = true }
        if r.headlineLabel == nil, snap.externalConnected { r.headlineLabel = snap.primaryWatts?.label }
        if r.negotiatedVolts == nil, let n = snap.adapterNegotiated {
            r.negotiatedVolts = Double(n.voltage_mV) / 1000
            r.negotiatedAmps = Double(n.current_mA) / 1000
        }
        if snap.mayReadHalf { r.mayReadHalf = true }
    }

    private func appendBucket(to r: inout ChargeRecord) {
        guard let first = bucket.first, let last = bucket.last else { return }
        let mid = first.date.addingTimeInterval(last.date.timeIntervalSince(first.date) / 2)
        r.samples.append(ChargeSample(t: mid.timeIntervalSince(r.start),
                                      w: ChargeRecord.mean(bucket.compactMap(\.w)),
                                      b: ChargeRecord.mean(bucket.compactMap(\.b)),
                                      p: bucket.last { $0.p != nil }?.p,
                                      c: ChargeRecord.mean(bucket.compactMap(\.c))))
        if r.samples.count > Self.maxSamples { r.samples = Self.thin(r.samples) }
        bucket.removeAll()
    }

    /// Merges neighbouring samples 2:1, never across a gap.
    private static func thin(_ s: [ChargeSample]) -> [ChargeSample] {
        var out: [ChargeSample] = []
        var i = 0
        while i < s.count {
            if i + 1 < s.count, s[i + 1].t - s[i].t <= ChargeRecord.gapSeconds {
                let a = s[i], z = s[i + 1]
                out.append(ChargeSample(t: (a.t + z.t) / 2,
                                        w: ChargeRecord.mean([a.w, z.w].compactMap { $0 }),
                                        b: ChargeRecord.mean([a.b, z.b].compactMap { $0 }),
                                        p: z.p ?? a.p,
                                        c: ChargeRecord.mean([a.c, z.c].compactMap { $0 })))
                i += 2
            } else {
                out.append(s[i])
                i += 1
            }
        }
        return out
    }

    private func closeOpen(at date: Date?) {
        guard var r = openRecord else { return }
        appendBucket(to: &r)
        r.end = date ?? r.start.addingTimeInterval(r.samples.last?.t ?? 0)
        records.removeFirst()
        try? FileManager.default.removeItem(at: openURL)
        // Under ~30 s of data is a plug-in blip, not a charge worth keeping.
        if r.samples.count >= 3 { records.insert(r, at: 0) }
        if records.count > Self.maxRecords { records.removeLast(records.count - Self.maxRecords) }
        recentHeadline.removeAll()
        saveArchive()
    }

    private func saveOpen(force: Bool) {
        guard let r = openRecord, force || Date().timeIntervalSince(lastOpenSave) >= 30 else { return }
        lastOpenSave = Date()
        write(r, to: openURL)
    }

    private func saveArchive() { write(records.filter { !$0.isOpen }, to: archiveURL) }

    private func write<T: Encodable>(_ value: T, to url: URL) {
        if let data = try? JSONEncoder().encode(value) { try? data.write(to: url, options: .atomic) }
    }
}
