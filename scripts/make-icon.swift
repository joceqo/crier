#!/usr/bin/env swift
//
// Generates a macOS .iconset directory from the SF Symbol "megaphone.fill"
// drawn on a rounded orange tile, then it's the caller's job to run
// `iconutil -c icns` to package it. Sized for the standard macOS app-icon
// pyramid (16, 32, 128, 256, 512 at @1x and @2x).
//
// Usage:
//   swift scripts/make-icon.swift <output-iconset-dir>
//

import AppKit
import Foundation

let iconsetDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "Crier.iconset"

try? FileManager.default.removeItem(atPath: iconsetDir)
try FileManager.default.createDirectory(atPath: iconsetDir, withIntermediateDirectories: true)

let entries: [(name: String, size: Int)] = [
    ("icon_16x16.png",       16),
    ("icon_16x16@2x.png",    32),
    ("icon_32x32.png",       32),
    ("icon_32x32@2x.png",    64),
    ("icon_128x128.png",    128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png",    256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png",    512),
    ("icon_512x512@2x.png", 1024),
]

func renderIcon(pixelSize size: Int) -> Data? {
    let s = CGFloat(size)
    let canvas = NSImage(size: NSSize(width: s, height: s))
    canvas.lockFocus()

    // Big Sur-ish rounded tile in Anthropic-ish brand orange.
    let cornerRadius = s * 0.22
    NSColor(srgbRed: 0.85, green: 0.45, blue: 0.27, alpha: 1.0).setFill()
    NSBezierPath(
        roundedRect: NSRect(origin: .zero, size: NSSize(width: s, height: s)),
        xRadius: cornerRadius,
        yRadius: cornerRadius
    ).fill()

    // SF Symbol "megaphone.fill" sized to ~55% of the tile and tinted white.
    // We render the symbol monochrome via a template-image trick: lockFocus
    // a transparent canvas, fill white, then draw the symbol with
    // .destinationIn so the white only survives where the symbol is opaque.
    let symPoint = s * 0.55
    let cfg = NSImage.SymbolConfiguration(pointSize: symPoint, weight: .semibold)
    guard let symbol = NSImage(systemSymbolName: "megaphone.fill",
                               accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg) else {
        canvas.unlockFocus()
        return nil
    }

    let tinted = NSImage(size: symbol.size)
    tinted.lockFocus()
    NSColor.white.set()
    NSRect(origin: .zero, size: symbol.size).fill()
    symbol.draw(
        at: .zero,
        from: NSRect(origin: .zero, size: symbol.size),
        operation: .destinationIn,
        fraction: 1.0
    )
    tinted.unlockFocus()

    let symRect = NSRect(
        x: (s - tinted.size.width) / 2,
        y: (s - tinted.size.height) / 2,
        width: tinted.size.width,
        height: tinted.size.height
    )
    tinted.draw(in: symRect)

    canvas.unlockFocus()

    guard let cg = canvas.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        return nil
    }
    return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
}

for entry in entries {
    guard let data = renderIcon(pixelSize: entry.size) else {
        FileHandle.standardError.write(Data("ERROR: failed rendering \(entry.name)\n".utf8))
        exit(1)
    }
    let url = URL(fileURLWithPath: iconsetDir).appendingPathComponent(entry.name)
    try data.write(to: url)
}

print("Wrote \(entries.count) PNGs into \(iconsetDir)")
