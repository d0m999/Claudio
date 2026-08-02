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

    let markScale = CGFloat(size) / canvas * 5.4
    let markCenter = NSPoint(x: CGFloat(size) / 2, y: CGFloat(size) / 2)
    let cPath = NSBezierPath()
    cPath.appendArc(
        withCenter: markCenter,
        radius: 45 * markScale,
        startAngle: 53.130102,
        endAngle: 306.869898,
        clockwise: false)
    cPath.lineWidth = max(1, 9 * markScale)
    cPath.lineCapStyle = .round
    cream.setStroke()
    cPath.stroke()

    func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
        NSPoint(
            x: markCenter.x + (x - 64) * markScale,
            y: markCenter.y - (y - 64) * markScale)
    }

    let pulse = NSBezierPath()
    pulse.move(to: point(48, 64))
    pulse.line(to: point(57, 64))
    pulse.line(to: point(63, 46))
    pulse.line(to: point(72, 82))
    pulse.line(to: point(80, 61))
    pulse.line(to: point(90, 61))
    pulse.lineWidth = max(1, 6 * markScale)
    pulse.lineCapStyle = .round
    pulse.lineJoinStyle = .round
    cream.setStroke()
    pulse.stroke()

    let dotCenter = point(99, 64)
    let dotRadius = max(0.75, 5 * markScale)
    let dot = NSBezierPath(ovalIn: NSRect(
        x: dotCenter.x - dotRadius,
        y: dotCenter.y - dotRadius,
        width: dotRadius * 2,
        height: dotRadius * 2))
    cream.setFill()
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

print("✓ 已生成 assets/branding/claudi0-app-icon.png 与 claudi0.icns")
