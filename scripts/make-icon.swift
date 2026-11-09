// Renders an SVG into the ten standard macOS .iconset PNGs.
// Usage: swift scripts/make-icon.swift <svg> <iconset-dir>
import AppKit
import Foundation

guard CommandLine.arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <svg> <iconset-dir>\n".utf8))
    exit(2)
}
let svg = URL(fileURLWithPath: CommandLine.arguments[1])
let outDir = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)

guard let image = NSImage(contentsOf: svg) else {
    FileHandle.standardError.write(Data("cannot render \(svg.path)\n".utf8))
    exit(1)
}
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

// The logo's viewBox is 200 units wide and its tile spans x 4...196 (192 units). Apple's icon grid
// puts the tile at 824 of 1024 points, centred, so the whole viewBox is drawn 824/192 times larger
// than the tile, with the transparent margin around it.
let viewBoxUnits = 200.0
let tileUnits = 192.0
let tileFraction = 824.0 / 1024.0

func render(pixels: Int) throws -> Data {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)
    else { throw CocoaError(.fileWriteUnknown) }
    rep.size = NSSize(width: pixels, height: pixels)
    guard let context = NSGraphicsContext(bitmapImageRep: rep) else { throw CocoaError(.fileWriteUnknown) }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    NSColor.clear.set()
    NSRect(x: 0, y: 0, width: pixels, height: pixels).fill(using: .copy)
    let side = Double(pixels) * tileFraction * viewBoxUnits / tileUnits
    let origin = (Double(pixels) - side) / 2
    image.draw(in: NSRect(x: origin, y: origin, width: side, height: side),
               from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
    return png
}

for base in [16, 32, 128, 256, 512] {
    try render(pixels: base).write(to: outDir.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(pixels: base * 2).write(to: outDir.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
