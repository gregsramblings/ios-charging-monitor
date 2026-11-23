import SwiftUI
import Charts

// MARK: History list

struct HistoryView: View {
    @ObservedObject var store: ChargeHistoryStore
    @State private var selection = Set<UUID>()
    @State private var editMode: EditMode = .inactive
    @State private var comparing: ComparePair?
    @State private var renaming: ChargerSummary?
    @State private var newName = ""

    var body: some View {
        // Selection only while choosing charges to compare: a List with a selection binding turns
        // row taps into selection, so a NavigationLink in it would not open the charge.
        List(selection: editMode.isEditing ? $selection : nil) {
            if store.records.isEmpty {
                Section {
                    Text("No charges yet. Each charge is recorded while ChargeSpeed is open.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            let chargers = ChargerSummary.make(store)
            if !chargers.isEmpty {
                Section {
                    ForEach(chargers) { chargerRow($0) }
                    if chargers.count >= 2 {
                        NavigationLink {
                            ChargerCompareView(store: store, a: chargers[0].id, b: chargers[1].id)
                        } label: {
                            Label("Compare chargers", systemImage: "chart.xyaxis.line")
                        }
                    }
                } header: {
                    Text("Chargers")
                } footer: {
                    Text("Tap a charger to name it. Chargers without a serial number are told apart by model, so two identical units show as one.")
                }
            }
            if !store.records.isEmpty {
                Section {
                    ForEach(store.records) { r in
                        NavigationLink {
                            SessionDetailView(store: store, id: r.id)
                        } label: {
                            ChargeRow(record: r, name: store.name(for: r))
                        }
                        .tag(r.id)
                        .deleteDisabled(r.isOpen)
                    }
                    .onDelete { offsets in
                        store.delete(Set(offsets.map { store.records[$0].id }))
                    }
                } header: {
                    Text("Charges")
                } footer: {
                    Text("Sampled while ChargeSpeed is open; gaps in a chart are times it was closed. Tap Select, pick two charges, then Compare.")
                }
            }
        }
        .environment(\.editMode, $editMode)
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $comparing) { CompareView(store: store, pair: $0) }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if editMode.isEditing {
                    Button("Compare") {
                        // Older charge first, so A and B read in time order.
                        let picked = store.records.filter { selection.contains($0.id) }.reversed().map(\.id)
                        comparing = ComparePair(a: picked[0], b: picked[1])
                        editMode = .inactive
                        selection.removeAll()
                    }
                    .disabled(selection.count != 2)
                    Button("Done") {
                        editMode = .inactive
                        selection.removeAll()
                    }
                } else if store.records.count >= 2 {
                    Button("Select") { editMode = .active }
                }
            }
        }
        .alert("Name this charger", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("e.g. Anker 65 W desk", text: $newName)
            Button("Save") { if let c = renaming { store.setNickname(newName, for: c.id) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Reported as: \(renaming?.reportedName ?? "")")
        }
    }

    private func chargerRow(_ c: ChargerSummary) -> some View {
        Button {
            newName = store.nicknames[c.id] ?? ""
            renaming = c
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.name).font(.callout.weight(.semibold)).lineLimit(1)
                    Text("\(c.count) charge\(c.count == 1 ? "" : "s") · \(c.wireless ? "wireless" : "wired")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("avg \(HistoryFormat.watts(c.average))").font(.callout).monospacedDigit()
                    Text("peak \(HistoryFormat.watts(c.peak))").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
        .foregroundStyle(.primary)
    }
}

struct ChargerSummary: Identifiable, Hashable {
    /// `ChargeHistoryStore.chargerKey`.
    let id: String
    let name: String
    let reportedName: String
    let count: Int
    let peak: Double?
    let average: Double?
    let wireless: Bool

    @MainActor
    static func make(_ store: ChargeHistoryStore) -> [ChargerSummary] {
        Dictionary(grouping: store.records, by: store.chargerKey)
            .map { key, rs in
                ChargerSummary(id: key, name: store.name(for: rs[0]),
                               reportedName: rs[0].adapterName ?? "unknown",
                               count: rs.count,
                               peak: rs.compactMap(\.peak).max(),
                               average: ChargeRecord.mean(rs.compactMap(\.averageWatts)),
                               wireless: rs[0].wireless)
            }
            .sorted { ($0.count, $0.name) > ($1.count, $1.name) }
    }
}

struct ChargeRow: View {
    let record: ChargeRecord
    let name: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(name).font(.callout.weight(.semibold)).lineLimit(1)
                if record.isOpen {
                    Text("NOW").font(.caption2.bold()).foregroundStyle(.green)
                }
                Spacer()
                Text("\(HistoryFormat.watts(record.averageWatts)) avg").font(.callout).monospacedDigit()
            }
            HStack {
                Text(record.start.formatted(date: .abbreviated, time: .shortened))
                Text("· \(HistoryFormat.percentRange(record)) · \(HistoryFormat.duration(record.recordedSpan))")
                Spacer()
                Text("peak \(HistoryFormat.watts(record.peak))")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            if let note = record.note {
                Text(note).font(.caption).italic().foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: One charge

struct SessionDetailView: View {
    @ObservedObject var store: ChargeHistoryStore
    let id: UUID
    @State private var note = ""
    @State private var renaming = false
    @State private var creating = false
    @State private var newName = ""
    private static let newTag = "__new__"

    var body: some View {
        if let r = store.records.first(where: { $0.id == id }) {
            List {
                Section {
                    let series = HistoryChart.series(for: r)
                    Chart {
                        ForEach(series.flatMap { r.timePoints($0.path, series: $0.name) }) { pt in
                            LineMark(x: .value("Minutes", pt.x), y: .value("Watts", pt.y),
                                     series: .value("Segment", pt.segment))
                                .foregroundStyle(by: .value("Series", pt.series))
                        }
                    }
                    .chartForegroundStyleScale(domain: series.map(\.name), range: series.map(\.color))
                    .chartXAxisLabel("minutes since plug-in")
                    .chartYAxisLabel("W")
                    .frame(height: 220)
                    if r.samples.contains(where: { $0.p != nil }) {
                        Chart(r.timePoints(\.percentValue, series: "Battery %")) { pt in
                            LineMark(x: .value("Minutes", pt.x), y: .value("Battery %", pt.y),
                                     series: .value("Segment", pt.segment))
                                .interpolationMethod(.stepEnd)
                                .foregroundStyle(.secondary)
                        }
                        .chartYScale(domain: 0...100)
                        .chartYAxisLabel("%")
                        .frame(height: 80)
                    }
                } header: {
                    Text(store.name(for: r))
                }

                Section("Summary") {
                    HistoryFormat.row("Reported as", r.adapterName ?? "unknown")
                    HistoryFormat.row("Type", r.wireless ? "Wireless" : "Wired")
                    HistoryFormat.row("Negotiated", HistoryFormat.negotiated(r))
                    HistoryFormat.row("Battery", HistoryFormat.percentRange(r))
                    HistoryFormat.row("Span", HistoryFormat.duration(r.recordedSpan) + (r.isOpen ? " so far" : ""))
                    HistoryFormat.row("Peak", HistoryFormat.watts(r.peak))
                    HistoryFormat.row("Average (\(r.headlineIsChargerInput ? "from charger" : "into battery"))", HistoryFormat.watts(r.averageWatts))
                    if r.headlineIsChargerInput {
                        HistoryFormat.row("Average into battery", HistoryFormat.watts(r.averageBatteryWatts))
                    }
                    HistoryFormat.row("Energy into battery", r.energyIntoBatteryWh.map { String(format: "%.1f Wh", $0) } ?? "—")
                    HistoryFormat.row("Charge rate", r.percentPerHour.map { String(format: "%.0f %%/h", $0) } ?? "—")
                    HistoryFormat.row("Battery temp, max", r.maxBatteryTemperature.map { String(format: "%.1f °C", $0) } ?? "—")
                    if r.mayReadHalf {
                        Label("Above ~30 W, 18 Pro Max units have read about half of a USB-C meter. See README.",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                Section("Note") {
                    TextField("e.g. Anker cable, car tray", text: $note)
                        .onSubmit { store.setNote(note, for: id) }
                }

                Section {
                    Picker("Charger used", selection: Binding(
                        get: { store.chargerKey(r) },
                        set: { key in
                            if key == Self.newTag { newName = ""; creating = true }
                            else { store.setCharger(key, for: id) }
                        })) {
                        ForEach(store.chargerChoices, id: \.self) { key in
                            Text(store.name(forKey: key) + (key == store.detectedKey(r) ? " (detected)" : "")).tag(key)
                        }
                        Text("New charger…").tag(Self.newTag)
                    }
                    .pickerStyle(.menu)
                    Button("Rename \(store.name(for: r))") {
                        newName = store.nicknames[store.chargerKey(r)] ?? ""
                        renaming = true
                    }
                } header: {
                    Text("Charger")
                } footer: {
                    Text(r.wireless
                         ? "Wireless chargers all report the same thing (\(r.adapterName ?? "unknown")), so pick which one this was."
                         : "Detected from what the charger reports. Change it if this charge was on a different one.")
                }
            }
            .navigationTitle(r.start.formatted(date: .abbreviated, time: .shortened))
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { note = r.note ?? "" }
            .onDisappear { store.setNote(note, for: id) }
            .alert("Name this charger", isPresented: $renaming) {
                TextField("e.g. Anker 65 W desk", text: $newName)
                Button("Save") { store.setNickname(newName, for: store.chargerKey(r)) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Reported as: \(r.adapterName ?? "unknown")")
            }
            .alert("New charger", isPresented: $creating) {
                TextField("e.g. MagSafe car mount", text: $newName)
                Button("Add") { if let key = store.newCharger(named: newName) { store.setCharger(key, for: id) } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This charge will be filed under it.")
            }
        } else {
            ContentUnavailableView("Charge not found", systemImage: "questionmark.circle")
        }
    }
}

// MARK: Compare two charges

struct ComparePair: Hashable, Identifiable {
    let a: UUID
    let b: UUID
    var id: String { "\(a)-\(b)" }
}

struct CompareView: View {
    @ObservedObject var store: ChargeHistoryStore
    let pair: ComparePair

    enum XAxis: String, CaseIterable, Identifiable {
        case time = "Time"
        case percent = "Battery %"
        var id: Self { self }
    }
    @State private var axis: XAxis = .percent

    var body: some View {
        if let ra = store.records.first(where: { $0.id == pair.a }),
           let rb = store.records.first(where: { $0.id == pair.b }) {
            let na = "A · \(store.name(for: ra))", nb = "B · \(store.name(for: rb))"
            List {
                Section {
                    Picker("X axis", selection: $axis) {
                        ForEach(XAxis.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Chart {
                        ForEach(points(ra, na) + points(rb, nb)) { pt in
                            LineMark(x: .value(axis.rawValue, pt.x), y: .value("Watts", pt.y),
                                     series: .value("Segment", pt.segment))
                                .foregroundStyle(by: .value("Charge", pt.series))
                            if axis == .percent {
                                PointMark(x: .value(axis.rawValue, pt.x), y: .value("Watts", pt.y))
                                    .foregroundStyle(by: .value("Charge", pt.series))
                                    .symbolSize(16)
                            }
                        }
                    }
                    .chartForegroundStyleScale(domain: [na, nb], range: [Color.blue, Color.orange])
                    .chartXAxisLabel(axis == .time ? "minutes since plug-in" : "battery %")
                    .chartYAxisLabel("W")
                    .chartLegend(position: .bottom, alignment: .leading)
                    .frame(height: 240)
                } footer: {
                    Text(axis == .percent
                         ? "Average watts at each battery level. Charging slows as the battery fills, so this lines the two charges up fairly. Some models report % in 5 % steps."
                         : "A charge that started at a higher % will look slower here; switch to Battery % to line them up.")
                }

                Section("Verdict") {
                    Text(verdict(ra, rb, na, nb)).font(.callout)
                    if ra.headlineIsChargerInput != rb.headlineIsChargerInput {
                        Label("One charge was measured from the charger and the other into the battery (wired vs wireless). Power from the charger includes conversion losses, so it reads higher for the same charging speed.",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    if ra.mayReadHalf || rb.mayReadHalf {
                        Label("Above ~30 W, 18 Pro Max units have read about half of a USB-C meter. See README.",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                Section("Side by side") {
                    compareRow("", "A", "B", bold: true)
                    compareRow("Charger", store.name(for: ra), store.name(for: rb))
                    compareRow("When", ra.start.formatted(date: .abbreviated, time: .shortened),
                               rb.start.formatted(date: .abbreviated, time: .shortened))
                    compareRow("Type", ra.wireless ? "Wireless" : "Wired", rb.wireless ? "Wireless" : "Wired")
                    compareRow("Negotiated", HistoryFormat.negotiated(ra), HistoryFormat.negotiated(rb))
                    compareRow("Battery", HistoryFormat.percentRange(ra), HistoryFormat.percentRange(rb))
                    compareRow("Span", HistoryFormat.duration(ra.recordedSpan), HistoryFormat.duration(rb.recordedSpan))
                    compareRow("Peak", HistoryFormat.watts(ra.peak), HistoryFormat.watts(rb.peak))
                    compareRow("Average", HistoryFormat.watts(ra.averageWatts), HistoryFormat.watts(rb.averageWatts))
                    compareRow("Into battery", HistoryFormat.watts(ra.averageBatteryWatts), HistoryFormat.watts(rb.averageBatteryWatts))
                    compareRow("Energy", ra.energyIntoBatteryWh.map { String(format: "%.1f Wh", $0) } ?? "—",
                               rb.energyIntoBatteryWh.map { String(format: "%.1f Wh", $0) } ?? "—")
                    compareRow("Rate", ra.percentPerHour.map { String(format: "%.0f %%/h", $0) } ?? "—",
                               rb.percentPerHour.map { String(format: "%.0f %%/h", $0) } ?? "—")
                    compareRow("Max temp", ra.maxBatteryTemperature.map { String(format: "%.1f °C", $0) } ?? "—",
                               rb.maxBatteryTemperature.map { String(format: "%.1f °C", $0) } ?? "—")
                    if ra.note != nil || rb.note != nil {
                        compareRow("Note", ra.note ?? "—", rb.note ?? "—")
                    }
                }
            }
            .navigationTitle("Compare")
            .navigationBarTitleDisplayMode(.inline)
        } else {
            ContentUnavailableView("Charge not found", systemImage: "questionmark.circle")
        }
    }

    private func points(_ r: ChargeRecord, _ name: String) -> [ChartPoint] {
        axis == .time ? r.timePoints(\.w, series: name) : r.percentPoints(series: name)
    }

    /// Compares mean watts over the battery range both charges covered; outside a shared range
    /// the averages differ mostly because of where each charge started.
    private func verdict(_ ra: ChargeRecord, _ rb: ChargeRecord, _ na: String, _ nb: String) -> String {
        if let s1 = ra.startPercent, let e1 = ra.endPercent, let s2 = rb.startPercent, let e2 = rb.endPercent {
            let lo = max(min(s1, e1), min(s2, e2)), hi = min(max(s1, e1), max(s2, e2))
            if hi > lo, let wa = ra.averageWatts(percentRange: lo...hi), let wb = rb.averageWatts(percentRange: lo...hi) {
                let (fastName, slowName, fast, slow) = wa >= wb ? (na, nb, wa, wb) : (nb, na, wb, wa)
                let ratio = slow > 0 ? fast / slow : 0
                let how = ratio >= 1.05 ? String(format: " (%.1f× as fast)", ratio) : " (about the same)"
                return "From \(lo)% to \(hi)%, the battery range both charges covered, \(fastName) averaged \(HistoryFormat.watts(fast)) and \(slowName) \(HistoryFormat.watts(slow))\(how)."
            }
        }
        guard let wa = ra.averageWatts, let wb = rb.averageWatts else {
            return "Not enough data to compare yet."
        }
        return "These charges covered different battery ranges, so their averages (\(HistoryFormat.watts(wa)) and \(HistoryFormat.watts(wb))) don't compare fairly: charging slows as the battery fills. Compare two charges that started near the same %."
    }

    private func compareRow(_ label: String, _ a: String, _ b: String, bold: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 78, alignment: .leading)
            Text(a).foregroundStyle(bold ? .blue : .primary).frame(maxWidth: .infinity, alignment: .leading)
            Text(b).foregroundStyle(bold ? .orange : .primary).frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(bold ? .callout.weight(.semibold) : .callout)
        .monospacedDigit()
        .lineLimit(2)
    }
}

// MARK: Compare two chargers

/// Pools every charge filed under each charger. Watts are averaged per battery %, so chargers
/// compare fairly however full the phone was each time.
struct ChargerCompareView: View {
    @ObservedObject var store: ChargeHistoryStore
    @State private var a: String
    @State private var b: String

    init(store: ChargeHistoryStore, a: String, b: String) {
        self.store = store
        _a = State(initialValue: a)
        _b = State(initialValue: b)
    }

    var body: some View {
        let chargers = ChargerSummary.make(store)
        let ra = store.records.filter { store.chargerKey($0) == a && !$0.samples.isEmpty }
        let rb = store.records.filter { store.chargerKey($0) == b && !$0.samples.isEmpty }
        let pa = ChargeRecord.pooled(ra), pb = ChargeRecord.pooled(rb)
        let na = "A · \(store.name(forKey: a))", nb = "B · \(store.name(forKey: b))"
        List {
            Section {
                picker("A", $a, chargers)
                picker("B", $b, chargers)
            }
            if a == b {
                Section { Text("Pick two different chargers.").foregroundStyle(.secondary) }
            } else {
                Section {
                    Chart {
                        ForEach(pa.percentPoints(series: na) + pb.percentPoints(series: nb)) { pt in
                            LineMark(x: .value("Battery %", pt.x), y: .value("Watts", pt.y),
                                     series: .value("Segment", pt.segment))
                                .foregroundStyle(by: .value("Charger", pt.series))
                            PointMark(x: .value("Battery %", pt.x), y: .value("Watts", pt.y))
                                .foregroundStyle(by: .value("Charger", pt.series))
                                .symbolSize(16)
                        }
                    }
                    .chartForegroundStyleScale(domain: [na, nb], range: [Color.blue, Color.orange])
                    .chartXAxisLabel("battery %")
                    .chartYAxisLabel("W")
                    .chartLegend(position: .bottom, alignment: .leading)
                    .frame(height: 240)
                } footer: {
                    Text("Average watts at each battery level across all of each charger's charges (\(ra.count) and \(rb.count)). More charges make a steadier line.")
                }

                Section("Verdict") {
                    Text(verdict(pa, pb, na, nb)).font(.callout)
                    if Set((ra + rb).map(\.headlineIsChargerInput)).count > 1 {
                        Label("Some charges were measured from the charger and others into the battery (wired vs wireless). Power from the charger includes conversion losses, so it reads higher for the same charging speed.",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    if pa.mayReadHalf || pb.mayReadHalf {
                        Label("Above ~30 W, 18 Pro Max units have read about half of a USB-C meter. See README.",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                Section("Side by side") {
                    row("", "A", "B", bold: true)
                    row("Charger", store.name(forKey: a), store.name(forKey: b))
                    row("Charges", "\(ra.count)", "\(rb.count)")
                    row("Type", kind(ra), kind(rb))
                    row("Last used", ra.first?.start.formatted(date: .abbreviated, time: .omitted) ?? "—",
                        rb.first?.start.formatted(date: .abbreviated, time: .omitted) ?? "—")
                    row("Battery seen", range(pa), range(pb))
                    row("Peak", HistoryFormat.watts(pa.peak), HistoryFormat.watts(pb.peak))
                    row("Average", HistoryFormat.watts(pa.averageWatts), HistoryFormat.watts(pb.averageWatts))
                    row("Into battery", HistoryFormat.watts(pa.averageBatteryWatts), HistoryFormat.watts(pb.averageBatteryWatts))
                    row("Rate", rate(ra), rate(rb))
                    row("Max temp", pa.maxBatteryTemperature.map { String(format: "%.1f °C", $0) } ?? "—",
                        pb.maxBatteryTemperature.map { String(format: "%.1f °C", $0) } ?? "—")
                }
            }
        }
        .navigationTitle("Compare chargers")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func picker(_ label: String, _ sel: Binding<String>, _ chargers: [ChargerSummary]) -> some View {
        Picker(label, selection: sel) {
            ForEach(chargers) { c in
                Text("\(c.name) (\(c.count))").tag(c.id)
            }
        }
        .pickerStyle(.menu)
    }

    private func verdict(_ pa: ChargeRecord, _ pb: ChargeRecord, _ na: String, _ nb: String) -> String {
        let psA = pa.samples.compactMap(\.p), psB = pb.samples.compactMap(\.p)
        if let a0 = psA.min(), let a1 = psA.max(), let b0 = psB.min(), let b1 = psB.max() {
            let lo = max(a0, b0), hi = min(a1, b1)
            if hi > lo, let wa = pa.averageWatts(percentRange: lo...hi), let wb = pb.averageWatts(percentRange: lo...hi) {
                let (fastName, slowName, fast, slow) = wa >= wb ? (na, nb, wa, wb) : (nb, na, wb, wa)
                let ratio = slow > 0 ? fast / slow : 0
                let how = ratio >= 1.05 ? String(format: " (%.1f× as fast)", ratio) : " (about the same)"
                return "From \(lo)% to \(hi)%, the battery range both chargers were seen in, \(fastName) averaged \(HistoryFormat.watts(fast)) and \(slowName) \(HistoryFormat.watts(slow))\(how)."
            }
        }
        return "These chargers haven't been seen at the same battery levels yet, so they can't be compared fairly. Charge each one from about the same %."
    }

    private func kind(_ rs: [ChargeRecord]) -> String {
        let w = Set(rs.map(\.wireless))
        return w.count > 1 ? "Mixed" : (w.first == true ? "Wireless" : "Wired")
    }

    private func range(_ r: ChargeRecord) -> String {
        let ps = r.samples.compactMap(\.p)
        guard let lo = ps.min(), let hi = ps.max() else { return "—" }
        return "\(lo)–\(hi)%"
    }

    private func rate(_ rs: [ChargeRecord]) -> String {
        ChargeRecord.mean(rs.compactMap(\.percentPerHour)).map { String(format: "%.0f %%/h", $0) } ?? "—"
    }

    private func row(_ label: String, _ a: String, _ b: String, bold: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 78, alignment: .leading)
            Text(a).foregroundStyle(bold ? .blue : .primary).frame(maxWidth: .infinity, alignment: .leading)
            Text(b).foregroundStyle(bold ? .orange : .primary).frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(bold ? .callout.weight(.semibold) : .callout)
        .monospacedDigit()
        .lineLimit(2)
    }
}

// MARK: Chart data

struct ChartPoint: Identifiable {
    let id = UUID()
    let x: Double
    let y: Double
    let series: String
    /// Breaks the line at gaps.
    let segment: String
}

enum HistoryChart {
    struct Series {
        let name: String
        let path: KeyPath<ChargeSample, Double?>
        let color: Color
    }

    /// On USB-C the headline is power from the charger and the battery line is drawn too; on
    /// wireless the headline already is power into the battery.
    static func series(for r: ChargeRecord) -> [Series] {
        r.headlineIsChargerInput
            ? [Series(name: "From charger", path: \.w, color: .accentColor),
               Series(name: "Into battery", path: \.b, color: .green)]
            : [Series(name: "Into battery", path: \.w, color: .green)]
    }
}

extension ChargeRecord {
    /// Values against minutes since plug-in, split into segments at gaps.
    func timePoints(_ path: KeyPath<ChargeSample, Double?>, series: String) -> [ChartPoint] {
        var segment = 0
        var previous: Double?
        return samples.compactMap { s in
            if let previous, s.t - previous > Self.gapSeconds { segment += 1 }
            previous = s.t
            guard let y = s[keyPath: path] else { return nil }
            return ChartPoint(x: s.t / 60, y: y, series: series, segment: "\(series)#\(segment)")
        }
    }

    /// All of a charger's charges as one record, for per-% and summary stats. Sample times are
    /// meaningless across charges, so only percent-based views use it.
    static func pooled(_ rs: [ChargeRecord]) -> ChargeRecord {
        var p = ChargeRecord(start: rs.map(\.start).min() ?? .now)
        p.end = .now
        p.samples = rs.flatMap(\.samples)
        p.peak = rs.compactMap(\.peak).max()
        p.headlineLabel = rs.first?.headlineLabel
        p.wireless = rs.contains { $0.wireless }
        p.mayReadHalf = rs.contains { $0.mayReadHalf }
        return p
    }

    /// Mean headline watts at each battery percent.
    func percentPoints(series: String) -> [ChartPoint] {
        Dictionary(grouping: samples.filter { $0.p != nil && $0.w != nil }) { $0.p! }
            .compactMap { p, ss in
                Self.mean(ss.compactMap(\.w)).map { ChartPoint(x: Double(p), y: $0, series: series, segment: series) }
            }
            .sorted { $0.x < $1.x }
    }
}

// MARK: Formatting

enum HistoryFormat {
    static func watts(_ w: Double?) -> String { w.map { String(format: "%.1f W", $0) } ?? "—" }

    static func duration(_ s: TimeInterval) -> String {
        let m = Int(s / 60)
        return m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m"
    }

    static func percentRange(_ r: ChargeRecord) -> String {
        switch (r.startPercent, r.endPercent) {
        case let (s?, e?): return "\(s)% → \(e)%"
        case let (s?, nil): return "from \(s)%"
        default: return "—"
        }
    }

    static func negotiated(_ r: ChargeRecord) -> String {
        guard let v = r.negotiatedVolts, let a = r.negotiatedAmps else { return "—" }
        return String(format: "%.0f V × %.2f A", v, a)
    }

    static func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundStyle(.secondary).monospacedDigit()
        }
        .font(.callout)
    }
}
