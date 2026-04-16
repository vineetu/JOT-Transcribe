#!/usr/bin/env swift
import AppKit
import CoreGraphics
import Foundation

// Procedural app icon generator for Jot.
// Draws a black squircle (Apple-approximate) with a white mic.fill SF Symbol centered.
// Emits the ten PNG sizes required by macOS AppIcon.appiconset.

struct IconSpec {
    let filename: String
    let pixels: Int
}

let specs: [IconSpec] = [
    .init(filename: "icon_16x16.png", pixels: 16),
    .init(filename: "icon_16x16@2x.png", pixels: 32),
    .init(filename: "icon_32x32.png", pixels: 32),
    .init(filename: "icon_32x32@2x.png", pixels: 64),
    .init(filename: "icon_128x128.png", pixels: 128),
    .init(filename: "icon_128x128@2x.png", pixels: 256),
    .init(filename: "icon_256x256.png", pixels: 256),
    .init(filename: "icon_256x256@2x.png", pixels: 512),
    .init(filename: "icon_512x512.png", pixels: 512),
    .init(filename: "icon_512x512@2x.png", pixels: 1024),
]

let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let repoRoot = scriptURL.deletingLastPathComponent()
let outputDir = repoRoot
    .appendingPathComponent("Resources")
    .appendingPathComponent("Assets.xcassets")
    .appendingPathComponent("AppIcon.appiconset")

try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

// Apple's macOS squircle corner-radius ratio is ~0.2237 of the canvas.
let cornerRadiusRatio: CGFloat = 0.2237
// Glyph occupies ~52% of the canvas.
let glyphRatio: CGFloat = 0.52

func renderIcon(pixels: Int) -> Data? {
    let size = CGFloat(pixels)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil,
        width: pixels,
        height: pixels,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        return nil
    }

    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    let radius = size * cornerRadiusRatio
    let squirclePath = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // Black squircle fill.
    ctx.addPath(squirclePath)
    ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    ctx.fillPath()

    // White mic.fill glyph, centered.
    let glyphPointSize = size * glyphRatio
    let config = NSImage.SymbolConfiguration(pointSize: glyphPointSize, weight: .regular)
    guard let symbol = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) else {
        return nil
    }

    // Tint to white by drawing through a mask.
    let glyphSize = symbol.size
    let glyphRect = CGRect(
        x: (size - glyphSize.width) / 2.0,
        y: (size - glyphSize.height) / 2.0,
        width: glyphSize.width,
        height: glyphSize.height
    )

    var proposedRect = glyphRect
    guard let cgGlyph = symbol.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else {
        return nil
    }

    ctx.saveGState()
    ctx.clip(to: proposedRect, mask: cgGlyph)
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(proposedRect)
    ctx.restoreGState()

    guard let image = ctx.makeImage() else { return nil }
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: pixels, height: pixels)
    return rep.representation(using: .png, properties: [:])
}

var failed = false
for spec in specs {
    guard let data = renderIcon(pixels: spec.pixels) else {
        FileHandle.standardError.write("Failed to render \(spec.filename)\n".data(using: .utf8)!)
        failed = true
        continue
    }
    let url = outputDir.appendingPathComponent(spec.filename)
    do {
        try data.write(to: url)
        print("Wrote \(spec.filename) (\(spec.pixels)x\(spec.pixels), \(data.count) bytes)")
    } catch {
        FileHandle.standardError.write("Failed to write \(spec.filename): \(error)\n".data(using: .utf8)!)
        failed = true
    }
}

if failed { exit(1) }
