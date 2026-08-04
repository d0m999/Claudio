import AppKit

/// 菜单栏使用 Orbit Zero 的 16pt 减法版本：一枚纵向 `0`、一条倾斜轨道和一个信号点。
/// 完整横向字标由 `ClaudioOrbitWordmark` 渲染；状态栏只保留在 1x/2x 下仍清楚的三层几何。
enum MenuBarIcon {
    private static let canvasSize: CGFloat = 16

    static func make() -> NSImage {
        let image = NSImage(
            size: NSSize(width: canvasSize, height: canvasSize),
            flipped: false
        ) { _ in
            drawOrbitZero()
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func drawOrbitZero() {
        NSColor.black.setStroke()
        NSColor.black.setFill()

        let zero = NSBezierPath(ovalIn: NSRect(x: 5.2, y: 2.2, width: 5.6, height: 11.6))
        zero.lineWidth = 1.3
        zero.lineCapStyle = .round
        zero.stroke()

        let orbit = NSBezierPath(ovalIn: NSRect(x: 1.6, y: 5.35, width: 12.8, height: 5.3))
        var rotation = AffineTransform()
        rotation.translate(x: canvasSize / 2, y: canvasSize / 2)
        rotation.rotate(byDegrees: 16)
        rotation.translate(x: -canvasSize / 2, y: -canvasSize / 2)
        orbit.transform(using: rotation)
        orbit.lineWidth = 0.72
        orbit.lineCapStyle = .round
        orbit.stroke()

        let dot = NSBezierPath(ovalIn: NSRect(x: 11.95, y: 11.45, width: 1.55, height: 1.55))
        dot.fill()
    }
}
