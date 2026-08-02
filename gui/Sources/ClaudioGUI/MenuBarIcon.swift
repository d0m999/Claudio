import AppKit

/// The menu-bar status-item glyph — claudi0's selected C / Signal mark: an open C contains
/// one pulse and an offset signal dot. The same geometry is used by the SVG and `.icns`
/// assets under `assets/branding`, with stroke widths tuned here for a true 16pt canvas.
///
/// A template `NSImage` built with `NSBezierPath`, not a bitmap asset: `gui/` is an SPM
/// target (no `Assets.xcassets`), and drawing the template mark directly keeps it crisp at
/// 1x/2x while letting macOS apply the correct light/dark menu-bar color automatically.
enum MenuBarIcon {
    /// DESIGN.md「App Icon」: "单色模板菜单栏字形（16×16pt，纯 alpha，自动亮/暗）" — the
    /// canvas size comes from that line, not from convention.
    private static let canvasSize: CGFloat = 16

    static func make() -> NSImage {
        let image = NSImage(
            size: NSSize(width: canvasSize, height: canvasSize),
            flipped: false
        ) { _ in
            let center = NSPoint(x: canvasSize / 2, y: canvasSize / 2)
            drawSignalMark(center: center)
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func drawSignalMark(center: NSPoint) {
        // Exact outer geometry of `M91 28a45 45 0 1 0 0 72`, scaled from 128 to 16.
        let cPath = NSBezierPath()
        cPath.appendArc(
            withCenter: center,
            radius: 5.625,
            startAngle: 53.130102,
            endAngle: 306.869898,
            clockwise: false)
        cPath.lineWidth = 1.125
        cPath.lineCapStyle = .round
        NSColor.black.setStroke()
        cPath.stroke()

        // `M48 64h9l6-18 9 36 8-21h10`, with SVG's downward y-axis flipped for AppKit.
        let pulse = NSBezierPath()
        pulse.move(to: NSPoint(x: 6, y: 8))
        pulse.line(to: NSPoint(x: 7.125, y: 8))
        pulse.line(to: NSPoint(x: 7.875, y: 10.25))
        pulse.line(to: NSPoint(x: 9, y: 5.75))
        pulse.line(to: NSPoint(x: 10, y: 8.375))
        pulse.line(to: NSPoint(x: 11.25, y: 8.375))
        pulse.lineWidth = 0.75
        pulse.lineCapStyle = .round
        pulse.lineJoinStyle = .round
        pulse.stroke()

        let dot = NSBezierPath(ovalIn: NSRect(x: 11.75, y: 7.375, width: 1.25, height: 1.25))
        NSColor.black.setFill()
        dot.fill()
    }
}
