import AppKit
import SwiftUI

/// A borderless, translucent panel that drops down from the status item, like Control Center.
final class PanelController: NSObject, NSWindowDelegate {
    private let panel: KeyPanel
    private weak var button: NSStatusBarButton?
    private var lastClosed = Date.distantPast
    var onVisibilityChange: ((Bool) -> Void)?

    init<Content: View>(rootView: Content, button: NSStatusBarButton) {
        self.button = button
        let host = NSHostingController(rootView: rootView)
        host.sizingOptions = .preferredContentSize
        panel = KeyPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: true)
        super.init()
        panel.contentViewController = host
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.close() }
        // Keep the panel pinned under the menu bar as its content grows or shrinks.
        NotificationCenter.default.addObserver(self, selector: #selector(reposition),
                                               name: NSWindow.didResizeNotification, object: panel)
    }

    func toggle() {
        if panel.isVisible {
            close()
        } else if Date().timeIntervalSince(lastClosed) > 0.3 {
            // Clicking the status item while open first closes it (resign key), then lands here.
            show()
        }
    }

    func show() {
        onVisibilityChange?(true)
        if let size = panel.contentViewController?.view.fittingSize { panel.setContentSize(size) }
        reposition()
        panel.makeKeyAndOrderFront(nil)
        button?.highlight(true)
    }

    func close() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        lastClosed = Date()
        button?.highlight(false)
        onVisibilityChange?(false)
    }

    func windowDidResignKey(_ notification: Notification) { close() }

    @objc private func reposition() {
        guard let button, let window = button.window, let screen = window.screen else { return }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        let size = panel.frame.size
        let visible = screen.visibleFrame
        let x = min(max(anchor.midX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8)
        panel.setFrameTopLeftPoint(NSPoint(x: x, y: anchor.minY - 6))
    }
}

/// Borderless panels can't become key by default; we need key status for controls and Esc.
final class KeyPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}
