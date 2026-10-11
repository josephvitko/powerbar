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
            if let a = r.adapterWatts { parts.append("\(a) W adapter") }
            if r.accessoryWatts >= 0.5 { parts.append(String(format: "USB-C %.1f W", r.accessoryWatts)) }
            return parts.joined(separator: " · ")
        }
        if r.accessoryWatts >= 0.5 {
            return String(format: "Mac %.1f W · USB-C %.1f W", max(r.watts - r.accessoryWatts, 0), r.accessoryWatts)
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
                BarMark(x: .value("Day", d.date, unit: .day), y: .value("Wh", d.accessoryWh))
                    .foregroundStyle(by: .value("Use", "USB-C devices"))
            }
        }
        .chartForegroundStyleScale(["Mac": Color.accentColor, "USB-C devices": Color.orange.opacity(0.8)])
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

    // MARK: Apps

    private var appsSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                sectionTitle("Apps")
                Spacer()
                Text("CPU").frame(width: 60, alignment: .trailing)
                Text("GPU").frame(width: 44, alignment: .trailing)
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)

            if model.apps.isEmpty {
                Text("Nothing using notable CPU or GPU").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(model.apps) { app in
                HStack(spacing: 8) {
                    appIcon(app)
                    Text(app.name).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 8)
                    Text(app.cpuWatts.flatMap { $0 >= 0.005 ? String(format: "%.2f W", $0) : nil } ?? "–")
                        .frame(width: 60, alignment: .trailing)
                    Text(app.gpuPercent >= 0.5 ? String(format: "%.0f%%", app.gpuPercent) : "–")
                        .frame(width: 44, alignment: .trailing)
                }
                .font(.callout)
                .monospacedDigit()
            }
        }
    }

    @ViewBuilder private func appIcon(_ app: EnergyMonitor.AppUsage) -> some View {
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
            Button("Open Activity Monitor") {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
            }
            Button("Quit PowerBar") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "gearshape")
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
