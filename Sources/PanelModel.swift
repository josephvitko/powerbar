import AppKit
import ServiceManagement
import SwiftUI

enum ChartRange: String, CaseIterable, Identifiable {
    case live = "10 min", day = "24 h", week = "7 days"
    var id: Self { self }
}

struct ChartPoint: Identifiable {
    let date: Date
    let watts: Double
    let segment: Int    // a new segment starts after a gap or time on AC, so lines don't bridge it
    var id: Date { date }
}

/// Live views show average watts; 24 h and 7 days show energy used.
enum Measure {
    case watts, wattHours

    func format(_ v: Double) -> String {
        switch self {
        case .watts: String(format: v < 0.995 ? "%.2f W" : "%.1f W", v)
        case .wattHours: String(format: v < 9.95 ? "%.1f Wh" : "%.0f Wh", v)
        }
    }
}

/// One part of the Mac's power use, for the breakdown bar.
struct PowerSlice: Identifiable {
    enum Kind: String { case cpu = "CPU", gpu = "GPU", memory = "Memory", otherChip = "Other chip", rest = "Display & rest", usb = "USB-C devices" }
    let kind: Kind
    let value: Double
    var id: Kind { kind }
}

struct AppRow: Identifiable {
    let name: String
    let bundlePath: String?
    let cpu: Double
    let gpu: Double
    var total: Double { cpu + gpu }
    var id: String { name }
}

struct ChartBand: Identifiable {   // a stretch of time on AC power
    let start: Date
    let end: Date
    var id: Date { start }
}

/// All state the panel shows. Sampling runs every tick; SwiftUI is only notified while
/// the panel is visible, so the app does no rendering work in the background.
final class PanelModel: ObservableObject {
    private(set) var reading: BatteryReading?
    private(set) var blockers: [SleepBlocker] = []
    private(set) var live = PowerHistory(span: 10 * 60)        // total battery draw, 5 s samples
    private var macLive = PowerHistory(span: 10 * 60)          // excluding power sent to USB-C devices; nil on AC
    private var systemLive = PowerHistory(span: 10 * 60)       // the Mac's own power, on battery or AC
    private var accessoryLive = PowerHistory(span: 10 * 60)    // power sent to USB-C devices
    let appHistory = AppHistory()
    /// Power use for the live chart (see `chartSeries`), 5 s samples for 10 minutes.
    private(set) var chartLive: [(date: Date, watts: Double?, onAC: Bool)] = []
    let updates = UpdateCheck()
    private(set) var lowPower: LowPowerMode?
    let history = HistoryStore()
    let alerts = DrainAlerts()
    private let energy = EnergyMonitor()
    private let soc = SoCPower()

    @Published var range: ChartRange = .live

    /// Called when the menu bar title should be redrawn.
    var onTitleChange: (() -> Void)?
    /// Called before an admin password prompt, so the panel can get out of the way.
    var onBeforeAdminPrompt: (() -> Void)?

    var isVisible = false {
        didSet { if isVisible { lowPower = LowPowerMode.current(); objectWillChange.send() } }
    }

    func tick() {
        updates.checkIfDue()
        soc.sample()
        if let delta = energy.sample(gpuWatts: soc.latest?.gpu) {
            appHistory.add(seconds: delta.seconds, apps: delta.apps)
        }
        blockers = SleepBlocker.current()
        reading = BatteryReading.read()
        if let r = reading {
            live.append(r.externalConnected ? nil : max(r.watts, 0))
            macLive.append(r.externalConnected ? nil : r.macWatts)
            systemLive.append(r.macWatts)
            accessoryLive.append(r.accessoryWatts)
            let now = Date()
            let use = r.macWatts.map { $0 + r.accessoryWatts } ?? (r.externalConnected ? nil : max(r.watts, 0))
            chartLive.append((now, use, r.externalConnected))
            chartLive.removeAll { now.timeIntervalSince($0.date) > 600 }
            history.record(r, chip: soc.latest)
        }
        // Alert on the Mac's own draw, so charging a phone doesn't trigger it.
        alerts.evaluate(history: macLive, culprit: apps(for: .live).first)
        if isVisible { objectWillChange.send() }
    }

    // MARK: - Derived values

    var averageWatts: Double? { live.average(over: 300) ?? live.average(over: 60) }
    var macAverageWatts: Double? { macLive.average(over: 300) ?? macLive.average(over: 60) }

    /// Minutes left from Wh ÷ recent average draw, falling back to macOS's estimate.
    var minutesLeft: Int? {
        guard let r = reading, !r.externalConnected else { return nil }
        return Self.minutes(r.remainingWh, averageWatts) ?? r.minutesLeft
    }

    var minutesLeftWithoutAccessories: Int? {
        guard let r = reading, !r.externalConnected, r.accessoryWatts >= 0.5 else { return nil }
        return Self.minutes(r.remainingWh, macAverageWatts)
    }

    private static func minutes(_ wh: Double, _ watts: Double?) -> Int? {
        guard let w = watts, w > 0.5 else { return nil }
        return Int(wh / w * 60)
    }

    // MARK: - Breakdown and apps per range

    func measure(for range: ChartRange) -> Measure { range == .live ? .watts : .wattHours }

    /// Minutes of live data behind the 10 min view (less right after launch).
    var liveMinutes: Int { min(max(Int((appHistory.recentWatts().seconds / 60).rounded(.up)), 1), 10) }

    /// Start of the period a range covers. 7 days matches the bar chart: today plus the 6 days before.
    func rangeStart(_ range: ChartRange) -> Date {
        switch range {
        case .live: Date().addingTimeInterval(-600)
        case .day: Date().addingTimeInterval(-86400)
        case .week: Calendar.current.date(byAdding: .day, value: -6, to: Calendar.current.startOfDay(for: Date()))!
        }
    }

    /// Where the Mac's power went: chip parts from IOReport, and the remainder of SMC system
    /// power ("Display & rest": backlight, SSD, Wi-Fi, power conversion…). Average watts for
    /// the live range; watt-hours from saved minutes for 24 h and 7 days.
    func breakdown(for range: ChartRange) -> [PowerSlice]? {
        var chip = SoCPower.Breakdown(), mac = 0.0, usb = 0.0
        if range == .live {
            guard let c = soc.average(over: 600), let m = systemLive.average(over: 600) ?? reading?.macWatts else { return nil }
            chip = c
            mac = m
            usb = accessoryLive.average(over: 600) ?? 0
        } else {
            let minutes = history.minutes(since: rangeStart(range)).filter { $0.chip != nil && $0.macWatts != nil }
            guard !minutes.isEmpty else { return nil }
            for m in minutes {
                chip = chip + m.chip! * (1.0 / 60)
                mac += m.macWatts! / 60
                usb += m.accessoryWatts / 60
            }
        }
        let slices: [PowerSlice] = [
            .init(kind: .cpu, value: chip.cpu),
            .init(kind: .gpu, value: chip.gpu),
            .init(kind: .memory, value: chip.memory),
            .init(kind: .otherChip, value: chip.otherChip),
            .init(kind: .rest, value: max(mac - chip.total, 0)),
            .init(kind: .usb, value: usb),
        ]
        return slices.filter { $0.value >= 0.05 }
    }

    /// Heaviest apps over the range: average watts (live) or watt-hours (24 h, 7 days).
    func apps(for range: ChartRange, limit: Int = 5) -> [AppRow] {
        let values: [String: AppEnergy]
        if range == .live {
            values = appHistory.recentWatts().apps
        } else {
            values = appHistory.energy(since: rangeStart(range)).mapValues { AppEnergy(cpu: $0.cpu / 3600, gpu: $0.gpu / 3600) }
        }
        return values
            .filter { $0.value.total >= (range == .live ? 0.05 : 0.01) }
            .sorted { $0.value.total > $1.value.total }
            .prefix(limit)
            .map { AppRow(name: $0.key, bundlePath: bundlePath(for: $0.key), cpu: $0.value.cpu, gpu: $0.value.gpu) }
    }

    private func bundlePath(for app: String) -> String? {
        if let p = energy.bundlePaths[app] { return p }
        // Apps seen only in saved history: look in the usual places.
        return ["/Applications", "/System/Applications", "/System/Applications/Utilities", NSHomeDirectory() + "/Applications"]
            .map { "\($0)/\(app).app" }
            .first { FileManager.default.fileExists(atPath: $0) }
    }

    // MARK: - Chart data

    func chartDomain(for range: ChartRange) -> ClosedRange<Date> {
        let now = Date()
        return now.addingTimeInterval(range == .live ? -600 : -86400)...now
    }

    /// Power use over time — the Mac plus any USB-C devices, on battery or AC (on battery this
    /// equals battery draw). Time on AC comes back as bands for shading.
    func chartSeries(for range: ChartRange) -> (points: [ChartPoint], bands: [ChartBand]) {
        typealias Sample = (date: Date, watts: Double?, onAC: Bool)
        func usage(_ m: HistoryStore.Minute) -> Sample {
            (m.date.addingTimeInterval(30), m.macWatts.map { $0 + m.accessoryWatts } ?? m.drawWatts, m.onAC)
        }
        let samples: [Sample]
        let step: TimeInterval
        switch range {
        case .live:
            // Live samples only exist since launch; fill the earlier part from saved minutes.
            let firstLive = chartLive.first?.date ?? Date()
            let saved = history.minutes(since: Date().addingTimeInterval(-600)).filter { $0.date.addingTimeInterval(60) <= firstLive }
            samples = saved.map(usage) + chartLive
            step = saved.isEmpty ? 5 : 60
        case .day, .week:
            samples = history.minutes(since: Date().addingTimeInterval(-86400)).map(usage)
            step = 60
        }

        var points: [ChartPoint] = [], bands: [ChartBand] = []
        var segment = 0, prev: Date?, bandStart: Date?
        for s in samples {
            if let p = prev, s.date.timeIntervalSince(p) > step * 3 {
                segment += 1   // asleep or not running: break the line and any band
                if let b = bandStart { bands.append(ChartBand(start: b, end: p.addingTimeInterval(step))); bandStart = nil }
            }
            if s.onAC, bandStart == nil { bandStart = s.date }
            if !s.onAC, let b = bandStart { bands.append(ChartBand(start: b, end: s.date)); bandStart = nil }
            if let w = s.watts {
                points.append(ChartPoint(date: s.date, watts: w, segment: segment))
            } else {
                segment += 1
            }
            prev = s.date
        }
        if let b = bandStart, let last = prev { bands.append(ChartBand(start: b, end: last.addingTimeInterval(step))) }
        return (points, bands)
    }

    // MARK: - Settings

    var showWh: Bool {
        get { UserDefaults.standard.object(forKey: "showWh") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "showWh"); objectWillChange.send(); onTitleChange?() }
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            try? (newValue ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister())
            objectWillChange.send()
        }
    }

    var alertThreshold: Double {
        get { alerts.threshold }
        set { alerts.threshold = newValue; objectWillChange.send() }
    }

    var alertMinutes: Int {
        get { alerts.minutes }
        set { alerts.minutes = newValue; objectWillChange.send() }
    }

    func setLowPower(_ mode: LowPowerMode) {
        onBeforeAdminPrompt?()
        // Off the main thread: the password prompt blocks until answered.
        DispatchQueue.global(qos: .userInitiated).async {
            mode.apply()
            let current = LowPowerMode.current()
            DispatchQueue.main.async {
                self.lowPower = current
                self.onTitleChange?()
            }
        }
    }
}
