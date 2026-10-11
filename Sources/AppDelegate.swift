import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let model = PanelModel()
    private var panel: PanelController!
    private let interval: TimeInterval = 5
    private var termSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ note: Notification) {
        guard let button = item.button else { return }
        button.target = self
        button.action = #selector(togglePanel)

        panel = PanelController(rootView: PanelView(model: model), button: button)
        panel.onVisibilityChange = { [weak self] visible in self?.model.isVisible = visible }
        model.onBeforeAdminPrompt = { [weak self] in self?.panel.close() }
        model.onTitleChange = { [weak self] in self?.updateTitle() }

        // Save the partial minute of history when quit or killed (e.g. `pkill` from build.sh).
        signal(SIGTERM, SIG_IGN)
        termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        termSource?.setEventHandler { NSApp.terminate(nil) }
        termSource?.resume()

        tick()
        Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
        NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) {
            [weak self] _ in self?.updateTitle()
        }
    }

    func applicationWillTerminate(_ note: Notification) { model.history.flush() }

    @objc private func togglePanel() { panel.toggle() }

    private func tick() {
        model.tick()
        updateTitle()
    }

    private func updateTitle() {
        guard let r = model.reading else { setTitle("—", symbol: "bolt.slash"); return }
        let wh = model.showWh ? String(format: " · %.0fWh", r.remainingWh) : ""
        if r.externalConnected {
            let w = -r.watts
            setTitle((r.isCharging && w > 0.5 ? String(format: "+%.0fW", w) : "AC") + wh, symbol: "bolt.fill")
        } else {
            setTitle(String(format: "%.1fW", r.watts) + wh, symbol: nil)
        }
    }

    private func setTitle(_ text: String, symbol: String?) {
        guard let b = item.button else { return }
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        // Yellow while Low Power Mode is on, like the system battery icon.
        if LowPowerMode.isActive {
            b.attributedTitle = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.systemYellow])
        } else {
            b.font = font
            b.title = text
        }
        b.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        b.imagePosition = .imageLeading
    }
}
