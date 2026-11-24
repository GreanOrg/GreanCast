// make-icon.swift — draws the GreanCast app icon and writes every size of the AppIcon set.
// Usage: swift scripts/make-icon.swift Sources/GreanCast/Assets.xcassets/AppIcon.appiconset
// Design: green gradient squircle, white iPhone outline, three "cast" waves.

import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")

func drawIcon(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024   // design on a 1024 canvas

    // macOS icon grid: 824 × 824 content, 100 pt margin, continuous-corner radius ≈ 185.
    let body = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let squircle = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)

    // Soft drop shadow.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = 24 * s
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    shadow.set()
    NSColor(calibratedRed: 0.09, green: 0.55, blue: 0.40, alpha: 1).setFill()
    squircle.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Green gradient (top: fresh green, bottom: deep teal).
    NSGradient(colors: [
        NSColor(calibratedRed: 0.30, green: 0.85, blue: 0.48, alpha: 1),
        NSColor(calibratedRed: 0.05, green: 0.52, blue: 0.45, alpha: 1),
    ])!.draw(in: squircle, angle: -90)

    // iPhone outline, slightly left of centre.
    let phone = NSRect(x: 300 * s, y: 230 * s, width: 300 * s, height: 560 * s)
    let phonePath = NSBezierPath(roundedRect: phone, xRadius: 62 * s, yRadius: 62 * s)
    NSColor.white.withAlphaComponent(0.16).setFill()
    phonePath.fill()
    NSColor.white.setStroke()
    phonePath.lineWidth = 30 * s
    phonePath.stroke()
    // Dynamic Island.
    let island = NSRect(x: phone.midX - 48 * s, y: phone.maxY - 70 * s, width: 96 * s, height: 26 * s)
    NSColor.white.setFill()
    NSBezierPath(roundedRect: island, xRadius: 13 * s, yRadius: 13 * s).fill()

    // Three cast waves radiating from the phone's top-right corner.
    let origin = NSPoint(x: phone.maxX + 10 * s, y: phone.maxY - 150 * s)
    for (i, r) in [70.0, 140.0, 210.0].enumerated() {
        let arc = NSBezierPath()
        arc.appendArc(withCenter: origin, radius: CGFloat(r) * s, startAngle: -40, endAngle: 40)
        arc.lineWidth = 30 * s
        arc.lineCapStyle = .round
        NSColor.white.withAlphaComponent(1.0 - Double(i) * 0.22).setStroke()
        arc.stroke()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

// macOS AppIcon set: 16, 32, 128, 256, 512 pt at 1x and 2x.
var images: [[String: String]] = []
for pt in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = pt * scale
        let name = "icon_\(pt)x\(pt)\(scale == 2 ? "@2x" : "").png"
        let data = drawIcon(size: CGFloat(px)).representation(using: .png, properties: [:])!
        try! data.write(to: outDir.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(pt)x\(pt)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try! json.write(to: outDir.appendingPathComponent("Contents.json"))
print("Wrote \(images.count) icon images to \(outDir.path)")
