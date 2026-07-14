import AppKit

/// The menu-bar status-item glyph — DESIGN.md App Icon 方案 B「单线括弧 / Monoline
/// Bracket」: one bold arc carries the whole shape, with a faint half-opacity echo arc
/// nested inside it. Chosen over the placeholder SF Symbol it replaces because the
/// concept review's real-16px legibility pass found B (with E) was one of only two
/// concepts whose open-gap direction still read at true menu-bar size — most of the
/// others fused into a solid ring.
///
/// A template `NSImage` built with `NSBezierPath`, not a bitmap asset: `gui/` is an SPM
/// target (no `Assets.xcassets`), and the shape is simple enough that drawing it directly
/// is both resolution-independent (crisp at 1x/2x for free, no @2x file to keep in sync)
/// and avoids standing up an asset pipeline for a single 16pt glyph.
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
            drawArc(center: center, radius: 4.8, lineWidth: 1.92, gapDegrees: 68, alpha: 1)
            drawArc(center: center, radius: 2.4, lineWidth: 0.56, gapDegrees: 92, alpha: 0.5)
            return true
        }
        image.isTemplate = true
        return image
    }

    /// One arc with its gap centered on the east/3-o'clock axis — same idea as the SVG
    /// concept's `pathLength`-normalized dasharray (`dashoffset = 360 - gapSpan/2`), just
    /// expressed as `NSBezierPath` start/end angles instead of a dasharray.
    private static func drawArc(
        center: NSPoint, radius: CGFloat, lineWidth: CGFloat, gapDegrees: CGFloat, alpha: CGFloat
    ) {
        let halfGap = gapDegrees / 2
        let path = NSBezierPath()
        path.appendArc(
            withCenter: center, radius: radius,
            startAngle: halfGap, endAngle: 360 - halfGap, clockwise: false
        )
        path.lineWidth = lineWidth
        path.lineCapStyle = .round
        NSColor.black.withAlphaComponent(alpha).setStroke()
        path.stroke()
    }
}
