import SwiftUI

struct ContentView: View {
    @StateObject private var monitor = PowerMonitor()
    @Environment(\.scenePhase) private var scenePhase
    @State private var showProfiles = false
    @State private var showSensors = false
    @State private var showPowerd = false
    @State private var showAdapterRaw = false
    @State private var showIOKit = false
    @State private var showSmartRaw = false

    var body: some View {
        NavigationStack {
            List {
                if let error = monitor.errorMessage {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
                if let snap = monitor.snapshot {
                    heroSection(snap)
                    smartChargeSection()
                    chargingSection(snap)
                    adapterSection(snap)
                    thermalSection(snap)
                    telemetrySection(snap)
                    chargerSection(snap)
                    rawSection(snap)
                }
            }
            .listSectionSpacing(.compact)
            .environment(\.defaultMinListRowHeight, 34)
            .navigationTitle("ChargeSpeed")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        UIPasteboard.general.string = monitor.rawDump()
                    } label: {
                        Label("Copy raw", systemImage: "doc.on.doc")
                    }
                }
            }
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            monitor.start()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            monitor.stop()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { monitor.start() } else { monitor.stop() }
        }
    }

    // MARK: Hero

    @ViewBuilder
    private func heroSection(_ snap: PowerSnapshot) -> some View {
        Section {
            VStack(spacing: 6) {
                Text(snap.statusText)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(statusColor(snap))

                if let primary = snap.primaryWatts {
                    bigNumber(watts(primary.value, signed: true))
                    Text(primary.label)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if let est = monitor.estimate {
                    bigNumber(watts(est.watts, signed: true))
                    Text("estimated from % rate · \(est.steps) step\(est.steps == 1 ? "" : "s") over \(Int(est.window / 60))m \(Int(est.window) % 60)s")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    bigNumber("—")
                    Text(snap.isCharging ? "measuring… needs two 1% steps" : "no power sensors readable on this device")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 20) {
                    if snap.externalConnected, snap.chargerInputWatts != nil, let b = snap.batteryWatts {
                        stat("Into battery", watts(b, signed: true))
                    }
                    if let v = snap.usbInputVoltage, let i = snap.usbInputCurrent, v > 0.5 {
                        stat("Input", String(format: "%.2f V · %.2f A", v, i))
                    }
                    if let load = snap.systemLoad_mW {
                        stat("System load", watts(Double(load) / 1000))
                    }
                    if let loss = snap.adapterEfficiencyLoss_mW {
                        stat("Loss", watts(Double(loss) / 1000))
                    }
                    if snap.primaryWatts != nil, let est = monitor.estimate {
                        stat("% rate", watts(est.watts, signed: true))
                    } else if snap.primaryWatts == nil,
                              let implied = snap.impliedWattsFromETA(batteryWattHours: monitor.batteryWattHours) {
                        stat("Implied by ETA", watts(implied))
                    }
                }

                if monitor.history.count > 1 {
                    Sparkline(values: monitor.history)
                        .frame(height: 32)
                        .padding(.top, 2)
                }

                HStack {
                    if let p = snap.percent {
                        Label("\(p)%", systemImage: batteryIcon(p, charging: snap.isCharging))
                    }
                    if let m = snap.timeRemainingMinutes {
                        Text("· \(m / 60)h \(m % 60)m \(snap.isCharging ? "to full" : "left")")
                    }
                    if snap.lowPowerMode {
                        Text("· Low Power")
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)

                if snap.externalConnected, let adapter = snap.adapterSummary {
                    Text(adapter)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 2)
        }
    }

    private func bigNumber(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 54, weight: .bold, design: .rounded))
            .monospacedDigit()
            .contentTransition(.numericText())
    }

    // MARK: Charging intelligence (only when there is something to say)

    @ViewBuilder
    private func smartChargeSection() -> some View {
        let sc = monitor.smartCharge
        let snap = monitor.snapshot
        let hasDirectData = (sc?.available ?? false) || snap?.chargeStatus != nil
        let hasHold = (snap?.holdIsInferred ?? false) || monitor.lastHold != nil
        if hasDirectData || hasHold {
            Section("Charging intelligence") {
                if let snap, let cs = snap.chargeStatus {
                    row("Charge status (powerd)", snap.chargeStatusText ?? "?")
                    ForEach(cs.keys.sorted().filter { $0 != "chargeStatus" }, id: \.self) { key in
                        row(key, String(describing: cs[key]!))
                    }
                }
                if let snap, snap.holdIsInferred, let p = snap.percent {
                    row("Hold detected", "at \(p)% (inferred)")
                }
                if let hold = monitor.lastHold {
                    row("Last hold", "\(hold.percent)% · \(hold.start.formatted(date: .abbreviated, time: .shortened))" + (hold.end == nil ? " · ongoing" : ""))
                    Text(holdInterpretation(hold.percent))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let sc, sc.available {
                    row("Optimized Battery Charging", onOff(sc.obcEnabled) + (sc.obcEngaged == 1 ? " · holding now" : ""))
                    row("Charge limit", sc.mclEnabled == 1
                        ? "On · \(sc.mclLimit)%"
                        : onOff(sc.mclEnabled) + (sc.mclLimit > 0 ? " (last \(sc.mclLimit)%)" : ""))
                    if sc.deocSupported || sc.deocEnabled > 0 {
                        row("Clean Energy Charging (DEoC)", onOff(sc.deocEnabled))
                    }
                    row("Effective limit", sc.currentChargeLimit >= 0 ? "\(sc.currentChargeLimit)%" : nil)
                    row("Engaged limit", sc.engagedChargeLimit >= 0 && sc.engagedChargeLimit != sc.currentChargeLimit ? "\(sc.engagedChargeLimit)%" : nil)
                    row("Recommended limit", sc.recommendedChargeLimit > 0 ? "\(sc.recommendedChargeLimit)%" : nil)
                    row("Override allowed", sc.chargingOverrideAllowed >= 0 ? (sc.chargingOverrideAllowed == 1 ? "Yes" : "No") : nil)
                    row("Full charge by", sc.fullChargeDeadline.map { $0.formatted(date: .abbreviated, time: .shortened) })
                    row("UI state", sc.uiState >= 0 ? "\(sc.uiState)" : nil)
                    row("Supported", "OBC \(sc.obcSupported ? "✓" : "✗") · limit \(sc.mclSupported ? "✓" : "✗") · DEoC \(sc.deocSupported ? "✓" : "✗")")
                    if let raw = sc.rawStatus as? [String: Any], !raw.isEmpty {
                        DisclosureGroup("Smart charge status (\(raw.count))", isExpanded: $showSmartRaw) {
                            ForEach(raw.keys.sorted(), id: \.self) { key in
                                rawRow(key, raw[key]!)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Charging

    @ViewBuilder
    private func chargingSection(_ snap: PowerSnapshot) -> some View {
        if snap.batteryWatts != nil || snap.batteryVoltage != nil || snap.cycleCount != nil {
            Section("Charging") {
                row("Into battery", snap.batteryWatts.map { watts($0, signed: true) })
                row("Battery", zip(snap.batteryVoltage, snap.batteryCurrent).map { String(format: "%.3f V · %.3f A", $0, $1) })
                row("Power (average)", snap.averageBatteryWatts.map { watts($0, signed: true) })
                row("Charge", zip(snap.rawCurrentCapacity_mAh, snap.rawMaxCapacity_mAh).map { "\($0) / \($1) mAh" })
                row("Design capacity", snap.designCapacity_mAh.map { "\($0) mAh" })
                row("Health", snap.healthPercent.map { String(format: "%.1f%%", $0) })
                row("Cycle count", snap.cycleCount.map { "\($0)" })
            }
        }
    }

    // MARK: Thermals

    @ViewBuilder
    private func thermalSection(_ snap: PowerSnapshot) -> some View {
        let rows: [(String, Double?)] = [
            ("Battery", snap.batteryTemperatureC),
            ("Charger junction", snap.chargerJunctionTemperatureC),
            ("Charger die", snap.chargerDieTemperatureC),
            ("SoC (hottest die)", snap.socMaxTemperatureC),
        ]
        if rows.contains(where: { $0.1 != nil }) {
            Section("Thermals") {
                ForEach(rows, id: \.0) { label, value in
                    row(label, value.map { Formatting.temperature($0) })
                }
            }
        }
    }

    // MARK: Adapter

    @ViewBuilder
    private func adapterSection(_ snap: PowerSnapshot) -> some View {
        if snap.adapter != nil {
            Section("Adapter") {
                row("Name", snap.adapterName ?? snap.adapterDescription)
                row("Negotiated", snap.adapterNegotiated.map {
                    String(format: "%.1f V × %.2f A = %.0f W",
                           Double($0.voltage_mV) / 1000,
                           Double($0.current_mA) / 1000,
                           Double($0.voltage_mV) * Double($0.current_mA) / 1_000_000)
                } ?? snap.adapterWatts.map { "\($0) W" })
                row("Wireless", snap.adapterIsWireless ? "Yes" : nil)
                let profiles = snap.adapterProfiles
                if profiles.count > 1 {
                    DisclosureGroup("All profiles (\(profiles.count))", isExpanded: $showProfiles) {
                        ForEach(profiles, id: \.index) { p in
                            row((p.index == snap.adapterActiveProfile ? "▶ " : "") + "Profile \(p.index)",
                                String(format: "%.1f V × %.2f A = %.0f W",
                                       Double(p.voltage_mV) / 1000,
                                       Double(p.current_mA) / 1000,
                                       Double(p.voltage_mV) * Double(p.current_mA) / 1_000_000))
                        }
                    }
                }
            }
        }
    }

    // MARK: macOS-only registry sections

    @ViewBuilder
    private func chargerSection(_ snap: PowerSnapshot) -> some View {
        if snap.chargerData != nil {
            Section("Charger") {
                row("Charging current", snap.chargingCurrent_mA.map { "\($0) mA" })
                row("Charging voltage", snap.chargingVoltage_mV.map { String(format: "%.3f V", Double($0) / 1000) })
                row("Not charging reason", snap.notChargingReason.map { "\($0)" })
            }
        }
    }

    @ViewBuilder
    private func telemetrySection(_ snap: PowerSnapshot) -> some View {
        let rows = snap.telemetryRows
        if !rows.isEmpty {
            Section("Power telemetry") {
                ForEach(rows, id: \.key) { r in
                    row(r.key, formatTelemetry(key: r.key, value: r.value))
                }
            }
        }
    }

    // MARK: Raw

    @ViewBuilder
    private func rawSection(_ snap: PowerSnapshot) -> some View {
        Section("Raw data") {
            if !snap.sensors.isEmpty {
                DisclosureGroup("All sensors (\(snap.sensors.count))", isExpanded: $showSensors) {
                    ForEach(snap.sensors.sorted { $0.name < $1.name }) { r in
                        row(r.name, r.formatted)
                    }
                }
            }
            if let ps = snap.powerSource {
                DisclosureGroup("powerd (\(ps.count))", isExpanded: $showPowerd) {
                    ForEach(ps.keys.sorted(), id: \.self) { key in
                        row(key, String(describing: ps[key]!))
                    }
                }
            }
            if let ad = snap.adapter {
                DisclosureGroup("Adapter details (\(ad.count))", isExpanded: $showAdapterRaw) {
                    ForEach(ad.keys.sorted(), id: \.self) { key in
                        rawRow(key, ad[key]!)
                    }
                }
            }
            DisclosureGroup("IOKit properties (\(snap.raw.count))", isExpanded: $showIOKit) {
                ForEach(snap.raw.keys.sorted(), id: \.self) { key in
                    rawRow(key, snap.raw[key]!)
                }
            }
        }
    }

    // MARK: Small views

    private func row(_ label: String, _ value: String?) -> some View {
        Group {
            if let value {
                HStack {
                    Text(label)
                    Spacer()
                    Text(value).foregroundStyle(.secondary).monospacedDigit()
                }
                .font(.callout)
                .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
            }
        }
    }

    private func rawRow(_ key: String, _ value: Any) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(key).font(.caption.bold())
            Text(String(describing: value).prefix(400))
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(6)
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 1) {
            Text(value).font(.headline).monospacedDigit()
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: Formatting

    private func watts(_ w: Double, signed: Bool = false) -> String {
        let s = String(format: "%.2f W", abs(w))
        if signed && w < -0.005 { return "−" + s }
        return s
    }

    private func formatTelemetry(key: String, value: Int) -> String {
        let k = key.lowercased()
        if k.contains("energy") { return String(format: "%.2f Wh", Double(value) / 1000) }
        if k.contains("power") || k.contains("load") || k.contains("loss") { return String(format: "%.2f W", Double(value) / 1000) }
        if k.contains("current") { return "\(value) mA" }
        if k.contains("voltage") { return String(format: "%.3f V", Double(value) / 1000) }
        return "\(value)"
    }

    private func holdInterpretation(_ percent: Int) -> String {
        switch percent {
        case 78...82: return "80%: either the 80% charge limit or Optimized Battery Charging holding overnight."
        case 83...97: return "\(percent)%: matches a manual charge limit of \((percent + 2) / 5 * 5)%."
        default: return "Unusual hold level; could be thermal or a temporary pause."
        }
    }

    private func onOff(_ value: Int) -> String {
        switch value {
        case 0: return "Off"
        case 1: return "On"
        case -1: return "Unknown"
        default: return "State \(value)"
        }
    }

    private func statusColor(_ snap: PowerSnapshot) -> Color {
        if snap.isCharging { return .green }
        if snap.externalConnected { return .orange }
        return .secondary
    }

    private func batteryIcon(_ percent: Int, charging: Bool) -> String {
        if charging { return "battery.100percent.bolt" }
        switch percent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}

private func zip<A, B>(_ a: A?, _ b: B?) -> (A, B)? {
    guard let a, let b else { return nil }
    return (a, b)
}

/// Minimal line chart of recent samples.
struct Sparkline: View {
    let values: [Double]

    var body: some View {
        GeometryReader { geo in
            let minV = min(values.min() ?? 0, 0)
            let maxV = max(values.max() ?? 1, 0.1)
            let range = max(maxV - minV, 0.1)
            let stepX = geo.size.width / CGFloat(max(values.count - 1, 1))
            let zeroY = geo.size.height * (1 - CGFloat((0 - minV) / range))

            Path { p in
                p.move(to: CGPoint(x: 0, y: zeroY))
                p.addLine(to: CGPoint(x: geo.size.width, y: zeroY))
            }
            .stroke(Color.secondary.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

            Path { p in
                for (i, v) in values.enumerated() {
                    let pt = CGPoint(x: CGFloat(i) * stepX,
                                     y: geo.size.height * (1 - CGFloat((v - minV) / range)))
                    if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                }
            }
            .stroke(Color.accentColor, lineWidth: 2)
        }
    }
}

#Preview {
    ContentView()
}
