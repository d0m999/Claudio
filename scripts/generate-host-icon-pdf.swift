#!/usr/bin/env swift

import AppKit
import CoreGraphics
import Foundation

guard CommandLine.arguments.count == 3 else {
    fputs("usage: generate-host-icon-pdf.swift INPUT.svg OUTPUT.pdf\n", stderr)
    exit(EXIT_FAILURE)
}

let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
guard let image = NSImage(contentsOf: inputURL), image.size.width > 0, image.size.height > 0 else {
    fputs("cannot load SVG: \(inputURL.path)\n", stderr)
    exit(EXIT_FAILURE)
}

var mediaBox = CGRect(x: 0, y: 0, width: 24, height: 24)
guard let context = CGContext(outputURL as CFURL, mediaBox: &mediaBox, nil) else {
    fputs("cannot create PDF: \(outputURL.path)\n", stderr)
    exit(EXIT_FAILURE)
}

context.beginPDFPage(nil)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
image.draw(
    in: NSRect(x: 0, y: 0, width: mediaBox.width, height: mediaBox.height),
    from: .zero,
    operation: .sourceOver,
    fraction: 1)
NSGraphicsContext.restoreGraphicsState()
context.endPDFPage()
context.closePDF()
