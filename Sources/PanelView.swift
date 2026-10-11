import AppKit
import Charts
import SwiftUI

struct PanelView: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let r = model.reading {
                header(r)
                chartSection
                Divider()
                breakdownSection
                Divider()
                appsSection
                if !model.blockers.isEmpty {
                    Divider()
                    blockersSection
                }
                Divider()
                footer(r)
            } else {
                Text("Battery unavailable").foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 340)
        .background(VisualEffect().clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.primary.opacity(0.08)))
    }

    // MARK: Header

    private func header(_ r: BatteryReading) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(primaryPower(r))
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    if LowPowerMode.isActive {
                        Text("Low Power")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(.yellow.opacity(0.25)))
                            .foregroundStyle(.yellow)
                    }
                }
                Text(powerSubtitle(r)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(String(format: "%.1f Wh", r.remainingWh))
                    .font(.system(size: 20, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .padding(.top, 5)
                Text(energySubtitle(r)).font(.caption).foregroundStyle(.secondary)
                if let m = model.minutesLeftWithoutAccessories {
                    Text("\(hm(m)) without USB-C").font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func primaryPower(_ r: BatteryReading) -> String {
        if !r.externalConnected { return String(format: "%.1f W", r.watts) }
        let w = -r.watts
        return r.isCharging && w > 0.5 ? String(format: "+%.0f W", w) : "On power"
    }

    private func powerSubtitle(_ r: BatteryReading) -> String {
        if r.externalConnected {
            var parts = [r.isCharging ? "Charging" : "Not charging"]
            if let mac = r.macWatts { parts.append(String(format: "Mac %.1f W", mac)) }
            if let a = r.adapterWatts { parts.append("\(a) W adapter") }
            if r.accessoryWatts >= 0.5 { parts.append(String(format: "USB-C %.1f W", r.accessoryWatts)) }
            return parts.joined(separator: " · ")
        }
        if r.accessoryWatts >= 0.5 {
            return String(format: "Mac %.1f W · USB-C %.1f W", r.macWatts ?? 0, r.accessoryWatts)
        }
        return "Drawing from battery"
    }

    private func energySubtitle(_ r: BatteryReading) -> String {
        var s = String(format: "of %.1f Wh", r.fullWh)
        if let m = model.minutesLeft { s += " · \(hm(m)) left" }
        return s
    }

    // MARK: Chart

    private var chartSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: $model.range) {
                ForEach(ChartRange.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Group {
                if model.range == .week { weekChart } else { lineChart(model.range) }
            }
            .frame(height: 100)

            Text(chartSummary).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func lineChart(_ range: ChartRange) -> some View {
        let (points, bands) = model.chartSeries(for: range)
        let peak = points.map(\.watts).max() ?? 0
        let threshold = model.alertThreshold
        let showRule = threshold > 0 && threshold <= max(peak, 1) * 1.5
        let top = max(peak, showRule ? threshold : 0, 5) * 1.15
        let accent = Color.accentColor
        let domain = model.chartDomain(for: range)
        let span = domain.upperBound.timeIntervalSince(domain.lowerBound)

        return Chart {
            ForEach(bands) { b in
                RectangleMark(xStart: .value("Start", b.start), xEnd: .value("End", b.end))
                    .foregroundStyle(.green.opacity(0.12))
            }
            ForEach(points) { p in
                AreaMark(x: .value("Time", p.date), yStart: .value("W", 0), yEnd: .value("W", p.watts),
                         series: .value("Segment", p.segment))
                    .foregroundStyle(LinearGradient(colors: [accent.opacity(0.35), accent.opacity(0.02)],
                                                    startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", p.date), y: .value("W", p.watts), series: .value("Segment", p.segment))
                    .foregroundStyle(accent)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)
            }
            if showRule {
                RuleMark(y: .value("Alert", threshold))
                    .foregroundStyle(.secondary.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        .chartXScale(domain: domain)
        .chartYScale(domain: 0...top)
        .chartXAxis {
            // Ticks at the quarter points, so labels never sit on (and get clipped at) the edges.
            AxisMarks(values: (1...3).map { domain.lowerBound.addingTimeInterval(span * Double($0) / 4) }) { _ in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel(format: .dateTime.hour().minute())
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { v in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel { if let w = v.as(Double.self) { Text("\(Int(w)) W") } }
            }
        }
        .overlay {
            if points.isEmpty && bands.isEmpty { emptyChart }
        }
    }

    private var weekChart: some View {
        let days = model.history.days(7)
        return Chart {
            ForEach(days) { d in
                BarMark(x: .value("Day", d.date, unit: .day), y: .value("Wh", d.macWh))
                    .foregroundStyle(by: .value("Use", "Mac"))
                    .cornerRadius(2)
                BarMark(x: .value("Day", d.date, unit: .day), y: .value("Wh", d.accessoryWh))
                    .foregroundStyle(by: .value("Use", "USB-C devices"))
                    .cornerRadius(2)
            }
        }
        .chartForegroundStyleScale(["Mac": Color.accentColor, "USB-C devices": Palette.color(.usb)])
        .chartLegend(days.contains { $0.accessoryWh > 0.05 } ? .visible : .hidden)
        .chartXAxis {
            AxisMarks(values: .stride(by: .day)) { _ in
                AxisValueLabel(format: .dateTime.weekday(.narrow), centered: true)
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { v in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel { if let wh = v.as(Double.self) { Text("\(Int(wh)) Wh") } }
            }
        }
        .overlay {
            if days.allSatisfy({ $0.totalWh < 0.05 }) { emptyChart }
        }
    }

    private var emptyChart: some View {
        Text("History builds up as you use your Mac on battery.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var chartSummary: String {
        switch model.range {
        case .live:
            let watts = model.live.samples.compactMap(\.watts)
            guard !watts.isEmpty else { return "On power for the last 10 minutes" }
            var s = "Peak " + String(format: "%.1f W", watts.max()!)
            if let a = model.averageWatts { s = String(format: "Average %.1f W · ", a) + s }
            return s
        case .day:
            let mins = model.history.minutes(since: Date().addingTimeInterval(-86400)).filter { !$0.onAC }
            guard !mins.isEmpty else { return "No time on battery in the last 24 hours" }
            let total = mins.reduce(0) { $0 + max($1.batteryWatts, 0) } / 60
            let usb = mins.reduce(0) { $0 + $1.accessoryWatts } / 60
            var s = String(format: "%.1f Wh used over %@ on battery · avg %.1f W",
                           total, duration(Double(mins.count) * 60), total / (Double(mins.count) / 60))
            if usb >= 0.1 { s += String(format: " · %.1f Wh to USB-C", usb) }
            return s
        case .week:
            let days = model.history.days(7).filter { $0.batteryHours > 0 }
            guard !days.isEmpty else { return "No time on battery this week yet" }
            let wh = days.map(\.totalWh).reduce(0, +) / Double(days.count)
            let hours = days.map(\.batteryHours).reduce(0, +) / Double(days.count)
            return String(format: "Avg %.0f Wh/day · %@ unplugged per day", wh, duration(hours * 3600))
        }
    }

    // MARK: Breakdown

    /// Caption saying what period and unit the breakdown and apps cover; follows the chart's range.
    private var rangeCaption: String {
        switch model.range {
        case .live: "avg, last \(model.liveMinutes) min"
        case .day: "used, last 24 h"
        case .week: "used, last 7 days"
        }
    }

    private var breakdownSection: some View {
        let slices = model.breakdown(for: model.range) ?? []
        let measure = model.measure(for: model.range)
        let total = slices.map(\.value).reduce(0, +)
        let gap: CGFloat = 2
        return VStack(alignment: .leading, spacing: 9) {
            HStack {
                sectionTitle("Where it's going")
                Spacer()
                Text(rangeCaption).font(.caption2).foregroundStyle(.tertiary)
            }
            if slices.isEmpty {
                Text("Builds up as PowerBar records.").font(.callout).foregroundStyle(.secondary)
            } else {
                // Part-to-whole bar with a 2 pt surface gap between segments.
                GeometryReader { geo in
                    let available = geo.size.width - gap * CGFloat(slices.count - 1)
                    HStack(spacing: gap) {
                        ForEach(slices) { slice in
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(Palette.color(slice.kind))
                                .frame(width: max(available * slice.value / total, 1))
                        }
                    }
                }
                .frame(height: 10)
                // Legend doubles as the labels: every segment's value is written out.
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 18, alignment: .leading),
                                    GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 5) {
                    ForEach(slices) { slice in
                        HStack(spacing: 6) {
                            Circle().fill(Palette.color(slice.kind)).frame(width: 7, height: 7)
                            Text(slice.kind.rawValue).foregroundStyle(.secondary)
                            Spacer(minLength: 4)
                            Text(measure.format(slice.value)).monospacedDigit()
                        }
                        .font(.caption)
                    }
                }
            }
        }
        .help("Chip power from IOReport; “Display & rest” is the rest of the Mac's total from the SMC — backlight, SSD, Wi-Fi, and power conversion.")
    }

    // MARK: Apps

    private var appsSection: some View {
        let apps = model.apps(for: model.range)
        let measure = model.measure(for: model.range)
        func cell(_ v: Double) -> String { v >= 0.005 ? measure.format(v) : "–" }
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                sectionTitle("Apps")
                Spacer()
                Text("CPU").frame(width: 60, alignment: .trailing)
                Text("GPU").frame(width: 60, alignment: .trailing)
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)

            if apps.isEmpty {
                Text(model.range == .live ? "Nothing using notable CPU or GPU" : "Builds up as PowerBar records.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(apps) { app in
                HStack(spacing: 8) {
                    appIcon(app)
                    Text(app.name).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 8)
                    Text(cell(app.cpu)).frame(width: 60, alignment: .trailing)
                    Text(cell(app.gpu)).frame(width: 60, alignment: .trailing)
                }
                .font(.callout)
                .monospacedDigit()
            }
        }
    }

    @ViewBuilder private func appIcon(_ app: AppRow) -> some View {
        if let path = app.bundlePath {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 16, height: 16)
        } else {
            Image(systemName: "gearshape").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 16, height: 16)
        }
    }

    // MARK: Sleep blockers

    private var blockersSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            sectionTitle("Keeping awake").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(model.blockers) { b in
                HStack(spacing: 8) {
                    Image(systemName: b.blocksDisplay ? "display" : "moon.zzz")
                        .font(.system(size: 11))
                        .foregroundStyle(b.blocksDisplay ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        .frame(width: 16)
                    Text(b.app).lineLimit(1)
                    Text(b.blocksDisplay ? "keeps display on" : b.reason)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .font(.callout)
            }
        }
    }

    // MARK: Footer

    private func footer(_ r: BatteryReading) -> some View {
        HStack(alignment: .center) {
            Text(String(format: "Health %d%% · %.0f of %.0f Wh · %d cycles · %.0f°C",
                        r.healthPercent, r.fullWh, r.designWh, r.cycles, r.tempC))
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("Full-charge capacity today vs. when new")
            Spacer()
            settingsMenu
        }
    }

    private var settingsMenu: some View {
        Menu {
            Picker("Low Power Mode", selection: Binding(
                get: { model.lowPower },
                set: { if let m = $0 { model.setLowPower(m) } }
            )) {
                ForEach(LowPowerMode.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
            }
            Menu("Drain Alerts") {
                Picker("Alert when", selection: $model.alertThreshold) {
                    Text("Off").tag(0.0)
                    ForEach(DrainAlerts.thresholdOptions, id: \.self) { Text("Above \(Int($0)) W").tag($0) }
                }
                .pickerStyle(.inline)
                Picker("Sustained for", selection: $model.alertMinutes) {
                    ForEach(DrainAlerts.durationOptions, id: \.self) { Text("\($0) min").tag($0) }
                }
                .pickerStyle(.inline)
                .disabled(model.alertThreshold == 0)
            }
            Toggle("Show Wh in Menu Bar", isOn: $model.showWh)
            Toggle("Launch at Login", isOn: $model.launchAtLogin)
            Divider()
            if let update = model.updates.available {
                Button("Update Available: \(update.version)…") { NSWorkspace.shared.open(update.url) }
            }
            Button("About PowerBar \(UpdateCheck.currentVersion)") {
                NSWorkspace.shared.open(URL(string: "https://github.com/josephvitko/powerbar")!)
            }
            Button("Open Activity Monitor") {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
            }
            Button("Quit PowerBar") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "gearshape")
                .overlay(alignment: .topTrailing) {
                    if model.updates.available != nil {
                        Circle().fill(Color.accentColor).frame(width: 6, height: 6).offset(x: 2, y: -2)
                    }
                }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    // MARK: Helpers

    private func sectionTitle(_ s: String) -> Text {
        Text(s.uppercased()).font(.caption2.weight(.semibold)).foregroundColor(.secondary)
    }

    private func hm(_ minutes: Int) -> String { String(format: "%d:%02d", minutes / 60, minutes % 60) }

    private func duration(_ seconds: Double) -> String {
        let m = Int(seconds / 60)
        return m < 60 ? "\(m) min" : String(format: "%.1f h", Double(m) / 60)
    }
}

/// Categorical colors for the breakdown, in fixed slot order (validated for colorblind
/// separation in light and dark). "Display & rest" is the remainder, so it's neutral gray.
enum Palette {
    static func color(_ kind: PowerSlice.Kind) -> Color {
        switch kind {
        case .cpu: dynamic(light: 0x2A78D6, dark: 0x3987E5)
        case .gpu: dynamic(light: 0xEB6834, dark: 0xD95926)
        case .memory: dynamic(light: 0x1BAF7A, dark: 0x199E70)
        case .otherChip: dynamic(light: 0xEDA100, dark: 0xC98500)
        case .usb: dynamic(light: 0xE87BA4, dark: 0xD55181)
        case .rest: dynamic(light: 0x9A9993, dark: 0x6B6A66)
        }
    }

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        func ns(_ hex: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? ns(dark) : ns(light)
        })
    }
}

/// Native translucent background, matching menus and Control Center.
struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .popover
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
