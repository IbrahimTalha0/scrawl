// Renders Resources/AppIcon.icns.  Usage: swift scripts/make-icon.swift
import AppKit

let cs = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

func render(_ px: Int) -> Data {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let s = CGFloat(px) / 1024
    ctx.scaleBy(x: s, y: s)

    // macOS icon grid: 824pt body, 100pt margins.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0, 0, 0, 0.35))
    ctx.addPath(bodyPath)
    ctx.setFillColor(color(0.1, 0.1, 0.16))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    let bg = CGGradient(colorsSpace: cs, colors: [color(0.20, 0.22, 0.38), color(0.07, 0.07, 0.14)] as CFArray,
                        locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)

    // Highlighter swash
    ctx.setStrokeColor(color(1.0, 0.84, 0.04, 0.55))
    ctx.setLineWidth(96)
    ctx.move(to: CGPoint(x: 245, y: 330))
    ctx.addLine(to: CGPoint(x: 780, y: 350))
    ctx.strokePath()

    // Red scribble
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 230, y: 520))
    p.addCurve(to: CGPoint(x: 400, y: 700), control1: CGPoint(x: 250, y: 640), control2: CGPoint(x: 320, y: 720))
    p.addCurve(to: CGPoint(x: 450, y: 520), control1: CGPoint(x: 480, y: 680), control2: CGPoint(x: 470, y: 560))
    p.addCurve(to: CGPoint(x: 600, y: 640), control1: CGPoint(x: 420, y: 470), control2: CGPoint(x: 540, y: 470))
    p.addCurve(to: CGPoint(x: 800, y: 680), control1: CGPoint(x: 650, y: 760), control2: CGPoint(x: 740, y: 760))
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: color(0, 0, 0, 0.35))
    ctx.setStrokeColor(color(1.0, 0.27, 0.23))
    ctx.setLineWidth(48)
    ctx.addPath(p)
    ctx.strokePath()
    ctx.restoreGState()

    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try render(256).write(to: URL(fileURLWithPath: "docs/icon.png"))

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try task.run()
task.waitUntilExit()
print(task.terminationStatus == 0 ? "✓ Resources/AppIcon.icns" : "iconutil failed")
