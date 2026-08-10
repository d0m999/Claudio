#!/usr/bin/env swift
import CoreGraphics
import Darwin
import Foundation
import ImageIO

func fail(_ message: String) -> Never {
    fputs("FAIL: \(message)\n", stderr)
    exit(EXIT_FAILURE)
}

guard CommandLine.arguments.count == 2 else {
    fail("usage: scan-host-card-height.swift SCREENSHOT.png")
}

let imageURL = URL(fileURLWithPath: CommandLine.arguments[1])
guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
    let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
else {
    fail("could not load screenshot \(imageURL.path)")
}

let imageWidth = image.width
let imageHeight = image.height
guard imageWidth > 0, imageHeight > 80 else {
    fail("screenshot is too small to contain the host cards")
}

let bytesPerPixel = 4
let bytesPerRow = imageWidth * bytesPerPixel
let pixelCount = bytesPerRow * imageHeight
let pixels = UnsafeMutablePointer<UInt8>.allocate(capacity: pixelCount)
defer { pixels.deallocate() }

let bitmapInfo =
    CGBitmapInfo.byteOrder32Big.rawValue
    | CGImageAlphaInfo.premultipliedLast.rawValue
guard
    let context = CGContext(
        data: pixels,
        width: imageWidth,
        height: imageHeight,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: bitmapInfo)
else {
    fail("could not create an RGBA screenshot buffer")
}

// CGContext memory is bottom-up by default. Flip the draw so scan coordinates match the
// screenshot's top-left origin, which keeps the border search independent of Retina scale.
context.saveGState()
context.translateBy(x: 0, y: CGFloat(imageHeight))
context.scaleBy(x: 1, y: -1)
context.interpolationQuality = .none
context.draw(image, in: CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight))
context.restoreGState()

struct Pixel {
    let red: Int
    let green: Int
    let blue: Int
}

func pixel(atX x: Int, y: Int) -> Pixel {
    let offset = y * bytesPerRow + x * bytesPerPixel
    return Pixel(
        red: Int(pixels[offset]),
        green: Int(pixels[offset + 1]),
        blue: Int(pixels[offset + 2]))
}

// Light hairline is the normal probe appearance. The dark range keeps the scanner useful if an
// app-level appearance override is ignored or if a caller intentionally runs a dark capture.
func isNeutralHairline(_ color: Pixel) -> Bool {
    let spread =
        max(color.red, color.green, color.blue)
        - min(color.red, color.green, color.blue)
    guard spread <= 14 else { return false }
    let isLight = (195...250).contains(color.red)
    let isDark = (55...95).contains(color.red)
    return isLight || isDark
}

struct Run {
    let start: Int
    let end: Int

    var length: Int { end - start + 1 }
    var center: Double { Double(start + end) / 2 }
}

func neutralRuns(atY y: Int, minimumLength: Int) -> [Run] {
    var runs: [Run] = []
    var start: Int?
    for x in 0..<imageWidth {
        let neutral = isNeutralHairline(pixel(atX: x, y: y))
        if neutral, start == nil {
            start = x
        }
        if (!neutral || x == imageWidth - 1), let currentStart = start {
            let end = neutral && x == imageWidth - 1 ? x : x - 1
            if end - currentStart + 1 >= minimumLength {
                runs.append(Run(start: currentStart, end: end))
            }
            start = nil
        }
    }
    return runs
}

struct CandidateRow {
    let y: Int
    let runs: [Run]
}

let minimumRun = max(100, Int(Double(imageWidth) * 0.10))
var candidateGroups: [[CandidateRow]] = []
for y in 80..<imageHeight {
    let runs = neutralRuns(atY: y, minimumLength: minimumRun)
    guard runs.count >= 2 else { continue }
    if candidateGroups.isEmpty || candidateGroups[candidateGroups.count - 1].last!.y != y - 1 {
        candidateGroups.append([CandidateRow(y: y, runs: runs)])
    } else {
        candidateGroups[candidateGroups.count - 1].append(CandidateRow(y: y, runs: runs))
    }
}

guard let topGroup = candidateGroups.first else {
    fail("could not locate the two host card top borders")
}

let topRuns = Array(topGroup[0].runs.sorted { $0.length > $1.length }.prefix(2))
guard topRuns.count == 2 else {
    fail("could not separate the two host card top borders")
}
let sortedTopRuns = topRuns.sorted { $0.start < $1.start }

var cardRegions: [(left: Int, right: Int)] = []
for topRun in sortedTopRuns {
    let relatedRuns = topGroup.flatMap(\.runs).filter {
        abs($0.center - topRun.center) < Double(imageWidth) * 0.20
    }
    guard let leftRun = relatedRuns.min(by: { $0.start < $1.start }),
        let rightRun = relatedRuns.max(by: { $0.end < $1.end })
    else {
        fail("could not derive a card region from its top border")
    }
    let left = max(0, leftRun.start - 8)
    let right = min(imageWidth, rightRun.end + 9)
    guard right > left else { fail("derived an empty host card region") }
    cardRegions.append((left: left, right: right))
}

func borderRows(left: Int, right: Int) -> [[Int]] {
    let width = right - left
    let scanStart = topGroup.last!.y + 4
    let scanEnd = min(imageHeight, topGroup.last!.y + Int(Double(imageHeight) * 0.45))
    guard scanEnd > scanStart else { return [] }

    var rowHits: [Int] = []
    for y in scanStart..<scanEnd {
        var hits = 0
        for x in left..<right where isNeutralHairline(pixel(atX: x, y: y)) {
            hits += 1
        }
        if hits >= max(20, Int(Double(width) * 0.55)) {
            rowHits.append(y)
        }
    }

    var groups: [[Int]] = []
    for y in rowHits {
        if groups.isEmpty || y != groups[groups.count - 1].last! + 1 {
            groups.append([y])
        } else {
            groups[groups.count - 1].append(y)
        }
    }
    return groups
}

var cardBottoms: [Int] = []
for region in cardRegions {
    guard let bottom = borderRows(left: region.left, right: region.right).last?.last else {
        fail("could not detect a host card bottom in x=\(region.left):\(region.right)")
    }
    cardBottoms.append(bottom)
}

guard cardBottoms.count == 2 else {
    fail("could not detect both host card bottoms")
}

let claudeBottom = cardBottoms[0]
let codexBottom = cardBottoms[1]
let delta = abs(claudeBottom - codexBottom)
print(
    "Claude Code card bottom=\(claudeBottom)px, "
        + "Codex card bottom=\(codexBottom)px, delta=\(delta)px")
guard delta <= 2 else {
    fail("host card bottoms differ by \(delta)px (allowed <= 2px)")
}
print("PASS: host card bottoms are aligned within 2px")
