// Draws the app icon and writes an .icns file.
// Usage: swift scripts/make-icon.swift <output.icns>
import AppKit

let output = CommandLine.arguments.dropFirst().first ?? "Resources/AppIcon.icns"
let fileManager = FileManager.default
let iconset = URL(filePath: NSTemporaryDirectory()).appending(path: "Reclaim-\(UUID().uuidString).iconset")
try fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)

func drawIcon(pixels: Int) -> Data {
    let size = CGFloat(pixels)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // macOS icon grid: the rounded square fills ~80% of the canvas.
    let inset = size * 0.1
    let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = rect.width * 0.225

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowOffset = NSSize(width: 0, height: -size * 0.01)
    shadow.shadowBlurRadius = size * 0.025
    shadow.set()

    let shape = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    NSGradient(colors: [
        NSColor(calibratedRed: 0.13, green: 0.78, blue: 0.62, alpha: 1),
        NSColor(calibratedRed: 0.05, green: 0.42, blue: 0.75, alpha: 1),
    ])!.draw(in: shape, angle: -70)

    NSShadow().set()
    let config = NSImage.SymbolConfiguration(pointSize: rect.width * 0.56, weight: .semibold)
        .applying(.init(paletteColors: [.white]))
    if let symbol = NSImage(systemSymbolName: "arrow.3.trianglepath", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let symbolSize = symbol.size
        let origin = NSPoint(x: rect.midX - symbolSize.width / 2, y: rect.midY - symbolSize.height / 2)
        symbol.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        let data = drawIcon(pixels: points * scale)
        try data.write(to: iconset.appending(path: "icon_\(points)x\(points)\(suffix).png"))
    }
}

let outputURL = URL(filePath: output)
try fileManager.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
let process = Process()
process.executableURL = URL(filePath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", outputURL.path]
try process.run()
process.waitUntilExit()
try? fileManager.removeItem(at: iconset)

guard process.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed\n".utf8))
    exit(1)
}
print("Wrote \(output)")
