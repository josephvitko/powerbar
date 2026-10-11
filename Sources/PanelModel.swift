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

/// One part of the Mac's power use, for the breakdown bar.
struct PowerSlice: Identifiable {
    enum Kind: String { case cpu = "CPU", gpu = "GPU", memory = "Memory", otherChip = "Other chip", rest = "Display & rest", usb = "USB-C devices" }
    let kind: Kind
    let watts: Double
    var id: Kind { kind }
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
    private(set) var apps: [EnergyMonitor.AppUsage] = []
    private(set) var blockers: [SleepBlocker] = []
    private(set) var live = PowerHistory(span: 10 * 60)        // total battery draw, 5 s samples
    private var macLive = PowerHistory(span: 10 * 60)          // excluding power sent to USB-C devices; nil on AC
    private var systemLive = PowerHistory(span: 2 * 60)        // the Mac's own power, on battery or AC
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
        energy.sample()
        soc.sample()
        blockers = SleepBlocker.current()
        apps = energy.topApps(5, gpuPower: soc.average(over: 60)?.gpu)
        reading = BatteryReading.read()
        if let r = reading {
            live.append(r.externalConnected ? nil : max(r.watts, 0))
            macLive.append(r.externalConnected ? nil : r.macWatts)
            systemLive.append(r.macWatts)
            history.record(r)
        }
        // Alert on the Mac's own draw, so charging a phone doesn't trigger it.
        alerts.evaluate(history: macLive, culprit: apps.first)
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

    /// Where the Mac's power is going over the last minute: chip parts from IOReport, and
    /// the remainder of SMC system power (display backlight, SSD, Wi-Fi, power conversion…).
    var breakdown: [PowerSlice]? {
        guard let r = reading, let chip = soc.average(over: 60),
              let mac = systemLive.average(over: 60) ?? r.macWatts else { return nil }
        var slices: [PowerSlice] = [
            .init(kind: .cpu, watts: chip.cpu),
            .init(kind: .gpu, watts: chip.gpu),
            .init(kind: .memory, watts: chip.memory),
            .init(kind: .otherChip, watts: chip.otherChip),
            .init(kind: .rest, watts: max(mac - chip.total, 0)),
        ]
        if r.accessoryWatts >= 0.5 { slices.append(.init(kind: .usb, watts: r.accessoryWatts)) }
        return slices.filter { $0.watts >= 0.05 }
    }

    // MARK: - Chart data

    func chartDomain(for range: ChartRange) -> ClosedRange<Date> {
        let now = Date()
        return now.addingTimeInterval(range == .live ? -600 : -86400)...now
    }

    func chartSeries(for range: ChartRange) -> (points: [ChartPoint], bands: [ChartBand]) {
        let samples: [(date: Date, watts: Double?)]
        let step: TimeInterval
        switch range {
        case .live:
            // Live samples only exist since launch; fill the earlier part from saved minutes.
            let start = Date().addingTimeInterval(-600)
            let firstLive = live.samples.first?.date ?? Date()
            let saved = history.minutes(since: start).filter { $0.date.addingTimeInterval(60) <= firstLive }
            samples = saved.map { ($0.date.addingTimeInterval(30), $0.drawWatts) } + live.samples
            step = saved.isEmpty ? 5 : 60
        case .day, .week:
            samples = history.minutes(since: Date().addingTimeInterval(-86400)).map { ($0.date, $0.drawWatts) }
            step = 60
        }

        var points: [ChartPoint] = [], bands: [ChartBand] = []
        var segment = 0, prev: Date?, bandStart: Date?
        for s in samples {
            let gap = prev.map { s.date.timeIntervalSince($0) > step * 3 } ?? false
            if let w = s.watts {
                if let b = bandStart { bands.append(ChartBand(start: b, end: s.date)); bandStart = nil }
                if gap { segment += 1 }
                points.append(ChartPoint(date: s.date, watts: w, segment: segment))
            } else {
                if bandStart == nil { bandStart = s.date; segment += 1 }
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
        // Let the menu finish closing before the password prompt appears.
        DispatchQueue.main.async {
            mode.apply()
            self.lowPower = LowPowerMode.current()
            self.onTitleChange?()
        }
    }
}
