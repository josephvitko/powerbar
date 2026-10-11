import AppKit

/// Small line graph of recent battery draw. Gaps (time on AC) break the line.
final class SparklineView: NSView {
    private let values: [Double?]
    private let peak: Double

    init(values: [Double?], size: NSSize) {
        self.values = values
        self.peak = max(values.compactMap { $0 }.max() ?? 0, 1)
        super.init(frame: NSRect(origin: .zero, size: size))
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override func draw(_ dirtyRect: NSRect) {
        let inset: CGFloat = 2
        let plot = bounds.insetBy(dx: 0, dy: inset)

        NSColor.separatorColor.setStroke()
        let baseline = NSBezierPath()
        baseline.move(to: NSPoint(x: plot.minX, y: plot.minY))
        baseline.line(to: NSPoint(x: plot.maxX, y: plot.minY))
        baseline.lineWidth = 0.5
        baseline.stroke()

        guard values.count > 1 else { return }
        let step = plot.width / CGFloat(values.count - 1)
        var segments: [[NSPoint]] = [[]]
        for (i, v) in values.enumerated() {
            guard let v else { if !segments[segments.count - 1].isEmpty { segments.append([]) }; continue }
            let y = plot.minY + CGFloat(v / peak) * plot.height
            segments[segments.count - 1].append(NSPoint(x: plot.minX + CGFloat(i) * step, y: y))
        }

        for pts in segments where pts.count > 1 {
            let fill = NSBezierPath()
            fill.move(to: NSPoint(x: pts[0].x, y: plot.minY))
            pts.forEach { fill.line(to: $0) }
            fill.line(to: NSPoint(x: pts[pts.count - 1].x, y: plot.minY))
            fill.close()
            NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
            fill.fill()

            let line = NSBezierPath()
            line.move(to: pts[0])
            pts.dropFirst().forEach { line.line(to: $0) }
            line.lineWidth = 1.5
            line.lineJoinStyle = .round
            NSColor.controlAccentColor.setStroke()
            line.stroke()
        }
    }
}
