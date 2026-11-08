// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

// Generates all icon assets for the unofficial Intel fork (VorsIntel):
// - the app iconset and .icns with a distinct processor/telemetry design
// - the menu bar template glyph and BrandMark
// Distinct from official Vorssaint branding in compliance with TRADEMARKS.md.
import AppKit

// Current macOS misreads PNG payloads in the legacy small chunks. It downsamples
// ic07 for 1x and uses the explicit ic11/ic12 representations on Retina displays.
let iconSizes: [(name: String, px: Int, icnsType: String?)] = [
    ("icon_16x16", 16, nil), ("icon_16x16@2x", 32, "ic11"),
    ("icon_32x32", 32, nil), ("icon_32x32@2x", 64, "ic12"),
    ("icon_128x128", 128, "ic07"), ("icon_128x128@2x", 256, "ic13"),
    ("icon_256x256", 256, "ic08"), ("icon_256x256@2x", 512, "ic14"),
    ("icon_512x512", 512, "ic09"), ("icon_512x512@2x", 1024, "ic10"),
]

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"

func bitmapCanvas(_ px: Int, _ py: Int) -> NSBitmapImageRep? {
    NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: py,
                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                     isPlanar: false, colorSpaceName: .deviceRGB,
                     bytesPerRow: 0, bitsPerPixel: 0)
}

/// Draws the fork's distinct CPU/telemetry mark inside `target`, keeping clear
/// margins from the canvas edges so `SelfTest` never sees clipped ink.
func drawMark(into target: CGRect, color: NSColor = .black) {
    let side = min(target.width, target.height) * 0.68
    let center = CGPoint(x: target.midX, y: target.midY)
    let bodyRect = CGRect(x: center.x - side / 2,
                          y: center.y - side / 2,
                          width: side,
                          height: side)
    let stroke = max(1.2, side * 0.11)
    color.setStroke()
    color.setFill()

    // Outer CPU package frame
    let corner = side * 0.22
    let framePath = NSBezierPath(roundedRect: bodyRect, xRadius: corner, yRadius: corner)
    framePath.lineWidth = stroke
    framePath.stroke()

    // Inner silicon die
    let dieSide = side * 0.42
    let dieRect = CGRect(x: center.x - dieSide / 2,
                         y: center.y - dieSide / 2,
                         width: dieSide,
                         height: dieSide)
    let diePath = NSBezierPath(roundedRect: dieRect, xRadius: dieSide * 0.18, yRadius: dieSide * 0.18)
    diePath.fill()

    // Processor pins on each side
    let pinLength = side * 0.16
    let offsets: [CGFloat] = [-0.22, 0.22]
    for offset in offsets {
        let delta = side * offset
        let pins = NSBezierPath()
        pins.lineWidth = stroke * 0.85
        pins.lineCapStyle = .round
        // Top & bottom pins
        pins.move(to: CGPoint(x: center.x + delta, y: bodyRect.maxY))
        pins.line(to: CGPoint(x: center.x + delta, y: bodyRect.maxY + pinLength))
        pins.move(to: CGPoint(x: center.x + delta, y: bodyRect.minY))
        pins.line(to: CGPoint(x: center.x + delta, y: bodyRect.minY - pinLength))
        // Left & right pins
        pins.move(to: CGPoint(x: bodyRect.minX, y: center.y + delta))
        pins.line(to: CGPoint(x: bodyRect.minX - pinLength, y: center.y + delta))
        pins.move(to: CGPoint(x: bodyRect.maxX, y: center.y + delta))
        pins.line(to: CGPoint(x: bodyRect.maxX + pinLength, y: center.y + delta))
        pins.stroke()
    }
}

// MARK: - App icon

func renderAppIcon(px: Int) -> Data? {
    let size = CGFloat(px)
    guard let rep = bitmapCanvas(px, px), let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    rep.size = NSSize(width: size, height: size)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx

    let margin = size * 0.095
    let squircleRect = CGRect(x: margin, y: margin, width: size - margin * 2, height: size - margin * 2)
    let radius = squircleRect.width * 0.225
    let squircle = NSBezierPath(roundedRect: squircleRect, xRadius: radius, yRadius: radius)

    // Deep Intel-inspired navy/cobalt gradient background
    let topColor = NSColor(calibratedRed: 0.05, green: 0.22, blue: 0.48, alpha: 1.0)
    let bottomColor = NSColor(calibratedRed: 0.02, green: 0.08, blue: 0.20, alpha: 1.0)
    if let gradient = NSGradient(starting: topColor, ending: bottomColor) {
        gradient.draw(in: squircle, angle: -90)
    } else {
        bottomColor.setFill()
        squircle.fill()
    }

    // Subtle cyan border highlight
    NSColor(calibratedRed: 0.25, green: 0.72, blue: 0.98, alpha: 0.45).setStroke()
    squircle.lineWidth = max(1.0, size * 0.015)
    squircle.stroke()

    // Draw glowing cyan/white processor mark inside the squircle
    let glyphColor = NSColor(calibratedRed: 0.42, green: 0.86, blue: 1.0, alpha: 1.0)
    drawMark(into: squircleRect.insetBy(dx: squircleRect.width * 0.14, dy: squircleRect.height * 0.14),
             color: glyphColor)

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

// MARK: - Menu bar glyph (template)

// The mark is ~1.97:1, so fitting it into a fixed box made the width the
// limiting side and left the height unused, rendering it far shorter than the
// menu bar icons around it. Size from the height and let the width follow.
let menuBarGlyphHeight: CGFloat = 12.5
// Centered geometrically the mark reads high, since the thin ring tails carry
// the bounding box below the planet body. Drop it onto the same visual floor
// as its neighbours.
let menuBarGlyphDrop: CGFloat = 1
// Taller than the mark needs: the same canvas holds the compact Keep Awake
// symbols. Keep in sync with BlackHoleGlyph.pointSize in
// Sources/Vorssaint/App/StatusItemController.swift; `--selftest` enforces it.
let menuBarCanvas = (width: 26, height: 20)

func renderMenuBarIcon(scale: Int) -> Data? {
    let width = menuBarCanvas.width * scale, height = menuBarCanvas.height * scale
    guard let rep = bitmapCanvas(width, height), let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    rep.size = NSSize(width: menuBarCanvas.width, height: menuBarCanvas.height)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    // Height-limited target spanning the full canvas width: drawMark keeps the
    // aspect ratio and centers, landing the mark at 24.6×12.5 pt. Coordinates
    // are bottom-up, so dropping it lowers y.
    let ink = menuBarGlyphHeight * CGFloat(scale)
    let y = (CGFloat(height) - ink) / 2 - menuBarGlyphDrop * CGFloat(scale)
    drawMark(into: CGRect(x: 0, y: y, width: CGFloat(width), height: ink))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

func appendFourCC(_ value: String, to data: inout Data) {
    data.append(contentsOf: value.utf8)
}

func appendUInt32BE(_ value: Int, to data: inout Data) {
    let clamped = UInt32(value)
    data.append(UInt8((clamped >> 24) & 0xff))
    data.append(UInt8((clamped >> 16) & 0xff))
    data.append(UInt8((clamped >> 8) & 0xff))
    data.append(UInt8(clamped & 0xff))
}

func writeICNS(entries: [(type: String, data: Data)], to url: URL) throws {
    let totalLength = 8 + entries.reduce(0) { $0 + 8 + $1.data.count }
    var icns = Data()
    appendFourCC("icns", to: &icns)
    appendUInt32BE(totalLength, to: &icns)
    for entry in entries {
        appendFourCC(entry.type, to: &icns)
        appendUInt32BE(8 + entry.data.count, to: &icns)
        icns.append(entry.data)
    }
    try icns.write(to: url)
}

try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
var icnsEntries: [(type: String, data: Data)] = []
for (name, px, icnsType) in iconSizes {
    guard let data = renderAppIcon(px: px) else {
        print("failed to render \(name)")
        exit(1)
    }
    try data.write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
    if let icnsType {
        icnsEntries.append((type: icnsType, data: data))
    }
}
try writeICNS(entries: icnsEntries, to: URL(fileURLWithPath: "\(outDir)/../AppIcon.icns"))

for scale in [1, 2] {
    guard let data = renderMenuBarIcon(scale: scale) else {
        print("failed to render menu bar icon @\(scale)x")
        exit(1)
    }
    let suffix = scale == 1 ? "" : "@2x"
    try data.write(to: URL(fileURLWithPath: "\(outDir)/../MenuBarIcon\(suffix).png"))
}

// Trimmed mark for in-app use (panel header, onboarding, About).
let markWidth = 640
let markHeight = 324
if let rep = bitmapCanvas(markWidth, markHeight), let ctx = NSGraphicsContext(bitmapImageRep: rep) {
    rep.size = NSSize(width: markWidth, height: markHeight)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    drawMark(into: CGRect(x: 0, y: 0, width: CGFloat(markWidth), height: CGFloat(markHeight)))
    NSGraphicsContext.restoreGraphicsState()
    if let data = rep.representation(using: .png, properties: [:]) {
        try data.write(to: URL(fileURLWithPath: "\(outDir)/../BrandMark.png"))
    }
}
print("iconset written to \(outDir)")
