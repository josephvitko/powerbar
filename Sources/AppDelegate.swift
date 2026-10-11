import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var history = PowerHistory(span: 10 * 60)
    private let energy = EnergyMonitor()
    private let alerts = DrainAlerts()
    private var blockers: [SleepBlocker] = []
    private let interval: TimeInterval = 5

    private let leading: CGFloat = 23
    private var menuFont: NSFont {
        .monospacedDigitSystemFont(ofSize: NSFont.menuFont(ofSize: 0).pointSize, weight: .regular)
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        menu.delegate = self
        item.menu = menu
        tick()
        Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
    }

    private func tick() {
        energy.sample()
        blockers = SleepBlocker.current()
        guard let r = BatteryReading.read() else { setTitle("—", symbol: "bolt.slash"); return }
        history.append(r.externalConnected ? nil : max(r.watts, 0))
        alerts.evaluate(history: history, culprit: energy.topApps(1).first)

        // A cup icon flags that something is keeping the display awake.
        let keepingAwake = blockers.contains { $0.blocksDisplay } ? "cup.and.saucer.fill" : nil
        if r.externalConnected {
            let w = -r.watts
            setTitle(r.isCharging && w > 0.5 ? String(format: "+%.0fW", w) : "AC", symbol: keepingAwake ?? "bolt.fill")
        } else {
            setTitle(String(format: "%.1fW", r.watts), symbol: keepingAwake)
        }
    }

    private func setTitle(_ text: String, symbol: String?) {
        guard let b = item.button else { return }
        b.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        b.title = text
        b.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        b.imagePosition = .imageLeading
    }

    // Rebuild the menu each time it opens so it's always fresh.
    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let r = BatteryReading.read() else { menu.addItem(label("Battery unavailable")); return }

        var status = "Battery \(r.percent)%"
        if let m = r.minutesLeft { status += String(format: " · %d:%02d left", m / 60, m % 60) }
        else if r.externalConnected { status += r.isCharging ? " · charging" : " · on AC" }
        if let a = r.adapterWatts, r.externalConnected { status += " · \(a)W adapter" }
        menu.addItem(label(status))

        if !r.externalConnected {
            let a1 = history.average(over: 60).map { String(format: "%.1fW", $0) } ?? "–"
            let a5 = history.average(over: 300).map { String(format: "%.1fW", $0) } ?? "–"
            menu.addItem(label("Avg 1 min \(a1) · 5 min \(a5)"))
        }
        addSparkline()
        menu.addItem(label(String(format: "Health %d%% · %d cycles · %.0f°C", r.healthPercent, r.cycles, r.tempC)))

        menu.addItem(.separator())
        menu.addItem(label("Energy by app", color: .secondaryLabelColor))
        let apps = energy.topApps(5)
        if apps.isEmpty { menu.addItem(label("Measuring…", color: .secondaryLabelColor)) }
        for app in apps {
            // Pad with figure spaces (digit-width) so the values right-align.
            let w = String(format: "%.1fW", app.watts)
            let pad = String(repeating: "\u{2007}", count: max(0, 5 - w.count))
            menu.addItem(label("\(pad)\(w)  \(app.name)"))
        }

        if !blockers.isEmpty {
            menu.addItem(.separator())
            menu.addItem(label("Preventing sleep", color: .secondaryLabelColor))
            for b in blockers {
                let what = b.blocksDisplay ? "keeping display on" : b.reason
                menu.addItem(label("\(b.blocksDisplay ? "☕︎ " : "")\(b.app) — \(what)"))
            }
        }

        menu.addItem(.separator())
        menu.addItem(alertsMenu())
        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        let am = NSMenuItem(title: "Open Activity Monitor", action: #selector(openActivityMonitor), keyEquivalent: "")
        am.target = self
        menu.addItem(am)
        menu.addItem(NSMenuItem(title: "Quit PowerBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func addSparkline() {
        let values = history.samples.map(\.watts)
        guard values.contains(where: { $0 != nil }) else { return }
        let width: CGFloat = 240, height: CGFloat = 34
        let view = NSView(frame: NSRect(x: 0, y: 0, width: width + leading + 14, height: height + 6))
        let spark = SparklineView(values: values, size: NSSize(width: width, height: height))
        spark.setFrameOrigin(NSPoint(x: leading, y: 3))
        view.addSubview(spark)
        let i = NSMenuItem()
        i.view = view
        menu.addItem(i)

        let peak = values.compactMap { $0 }.max() ?? 0
        let minutes = Int((history.samples.last!.date.timeIntervalSince(history.samples.first!.date) / 60).rounded())
        menu.addItem(label(String(format: "Last %d min · peak %.1fW", max(minutes, 1), peak), color: .secondaryLabelColor))
    }

    private func alertsMenu() -> NSMenuItem {
        let sub = NSMenu()
        sub.autoenablesItems = false
        for t in [0] + DrainAlerts.thresholdOptions.map({ Int($0) }) {
            let i = NSMenuItem(title: t == 0 ? "Off" : "Above \(t) W", action: #selector(setThreshold(_:)), keyEquivalent: "")
            i.tag = t
            i.target = self
            i.state = Double(t) == alerts.threshold ? .on : .off
            sub.addItem(i)
        }
        sub.addItem(.separator())
        for m in DrainAlerts.durationOptions {
            let i = NSMenuItem(title: "Sustained for \(m) min", action: #selector(setDuration(_:)), keyEquivalent: "")
            i.tag = m
            i.target = self
            i.state = m == alerts.minutes ? .on : .off
            i.isEnabled = alerts.threshold > 0
            sub.addItem(i)
        }
        let title = alerts.threshold > 0
            ? String(format: "Drain Alerts: >%.0fW for %d min", alerts.threshold, alerts.minutes)
            : "Drain Alerts: Off"
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        parent.submenu = sub
        return parent
    }

    // Info rows are drawn as custom views: action-less menu items always render dimmed,
    // and a view also avoids the hover highlight.
    private func label(_ s: String, color: NSColor = .labelColor) -> NSMenuItem {
        let field = NSTextField(labelWithString: s)
        field.font = menuFont
        field.textColor = color
        field.sizeToFit()
        let height: CGFloat = 22
        let view = NSView(frame: NSRect(x: 0, y: 0, width: field.frame.width + leading + 14, height: height))
        field.setFrameOrigin(NSPoint(x: leading, y: (height - field.frame.height) / 2))
        view.addSubview(field)
        let i = NSMenuItem()
        i.view = view
        return i
    }

    @objc private func setThreshold(_ sender: NSMenuItem) { alerts.threshold = Double(sender.tag) }
    @objc private func setDuration(_ sender: NSMenuItem) { alerts.minutes = sender.tag }

    @objc private func toggleLogin() {
        let svc = SMAppService.mainApp
        try? (svc.status == .enabled ? svc.unregister() : svc.register())
    }

    @objc private func openActivityMonitor() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
    }
}
