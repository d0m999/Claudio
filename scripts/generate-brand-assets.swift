#!/usr/bin/env swift

import AppKit
import Foundation

private let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
private let outputDirectory = repositoryRoot.appendingPathComponent("assets/branding", isDirectory: true)
private let fileManager = FileManager.default

private let canvas: CGFloat = 1024
private let background = NSColor(srgbRed: 43 / 255, green: 38 / 255, blue: 32 / 255, alpha: 1)
private let cream = NSColor(srgbRed: 241 / 255, green: 233 / 255, blue: 223 / 255, alpha: 1)
private let clay = NSColor(srgbRed: 196 / 255, green: 99 / 255, blue: 60 / 255, alpha: 1)

private func scaled(_ value: CGFloat, for size: Int) -> CGFloat {
    value * CGFloat(size) / canvas
}

private func makeIcon(size: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw NSError(domain: "claudi0.branding", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "无法创建 \(size)×\(size) 位图"
        ])
    }

    bitmap.size = NSSize(width: size, height: size)
    let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphicsContext
    defer { NSGraphicsContext.restoreGraphicsState() }

    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: size, height: size).fill()

    let backgroundRect = NSRect(
        x: scaled(72, for: size),
        y: scaled(72, for: size),
        width: scaled(880, for: size),
        height: scaled(880, for: size))
    let backgroundPath = NSBezierPath(
        roundedRect: backgroundRect,
        xRadius: scaled(210, for: size),
        yRadius: scaled(210, for: size))
    background.setFill()
    backgroundPath.fill()

    if size >= 64 {
        let insetRect = backgroundRect.insetBy(dx: scaled(5, for: size), dy: scaled(5, for: size))
        let insetPath = NSBezierPath(
            roundedRect: insetRect,
            xRadius: scaled(205, for: size),
            yRadius: scaled(205, for: size))
        NSColor.white.withAlphaComponent(0.07).setStroke()
        insetPath.lineWidth = max(1, scaled(10, for: size))
        insetPath.stroke()
    }

    func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
        NSPoint(x: scaled(x, for: size), y: CGFloat(size) - scaled(y, for: size))
    }

    func drawEllipse(
        centerX: CGFloat, centerY: CGFloat,
        radiusX: CGFloat, radiusY: CGFloat,
        color: NSColor, opacity: CGFloat,
        lineWidth: CGFloat, rotationDegrees: CGFloat = 0
    ) {
        let center = point(centerX, centerY)
        let path = NSBezierPath(ovalIn: NSRect(
            x: center.x - scaled(radiusX, for: size),
            y: center.y - scaled(radiusY, for: size),
            width: scaled(radiusX * 2, for: size),
            height: scaled(radiusY * 2, for: size)))
        if rotationDegrees != 0 {
            var rotation = AffineTransform()
            rotation.translate(x: center.x, y: center.y)
            rotation.rotate(byDegrees: rotationDegrees)
            rotation.translate(x: -center.x, y: -center.y)
            path.transform(using: rotation)
        }
        path.lineWidth = max(1, scaled(lineWidth, for: size))
        color.withAlphaComponent(opacity).setStroke()
        path.stroke()
    }

    // Orbit Zero：大尺寸保留两层暖色光晕，小尺寸只画核心 0 与轨道。
    if size >= 64 {
        drawEllipse(
            centerX: 512, centerY: 512, radiusX: 236, radiusY: 340,
            color: clay, opacity: 0.10, lineWidth: 54)
        drawEllipse(
            centerX: 512, centerY: 512, radiusX: 194, radiusY: 320,
            color: clay, opacity: 0.18, lineWidth: 34)
    }
    drawEllipse(
        centerX: 512, centerY: 512, radiusX: 170, radiusY: 300,
        color: clay, opacity: 1, lineWidth: 66)
    drawEllipse(
        centerX: 512, centerY: 512, radiusX: 356, radiusY: 128,
        color: cream, opacity: 0.74, lineWidth: 20, rotationDegrees: 16)

    let dotCenter = point(755, 303)
    let dotRadius = max(0.75, scaled(22, for: size))
    let dot = NSBezierPath(ovalIn: NSRect(
        x: dotCenter.x - dotRadius,
        y: dotCenter.y - dotRadius,
        width: dotRadius * 2,
        height: dotRadius * 2))
    clay.setFill()
    dot.fill()

    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "claudi0.branding", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "无法编码 \(size)×\(size) PNG"
        ])
    }
    return png
}

private func writeIcon(_ size: Int, to destination: URL) throws {
    try makeIcon(size: size).write(to: destination, options: .atomic)
}

try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
try writeIcon(1024, to: outputDirectory.appendingPathComponent("claudi0-app-icon.png"))

let temporaryRoot = fileManager.temporaryDirectory
    .appendingPathComponent("claudi0-branding-\(UUID().uuidString)", isDirectory: true)
let iconset = temporaryRoot.appendingPathComponent("claudi0.iconset", isDirectory: true)
try fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? fileManager.removeItem(at: temporaryRoot) }

let iconsetFiles: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]
for (filename, size) in iconsetFiles {
    try writeIcon(size, to: iconset.appendingPathComponent(filename))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = [
    "--convert", "icns",
    iconset.path,
    "--output", outputDirectory.appendingPathComponent("claudi0.icns").path,
]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    throw NSError(domain: "claudi0.branding", code: Int(iconutil.terminationStatus), userInfo: [
        NSLocalizedDescriptionKey: "iconutil 生成 claudi0.icns 失败"
    ])
}

print("✓ 已生成 Orbit Zero assets/branding/claudi0-app-icon.png 与 claudi0.icns")
