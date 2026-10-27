// Renders the app icon into an .iconset folder: swift scripts/make-icon.swift <out.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = CGFloat(px) / 1024
    ctx.scaleBy(x: s, y: s)

    // Rounded-square body with a warm gradient.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12 * s), blur: 28 * s, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(shape)
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [
        NSColor(srgbRed: 0.98, green: 0.36, blue: 0.45, alpha: 1).cgColor,
        NSColor(srgbRed: 0.84, green: 0.13, blue: 0.32, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 100), options: [])
    ctx.restoreGState()

    // Skitch-style tapered arrow.
    let start = CGPoint(x: 270, y: 290), end = CGPoint(x: 735, y: 735)
    let dx = end.x - start.x, dy = end.y - start.y, len = hypot(dx, dy)
    let ux = dx / len, uy = dy / len, nx = -uy, ny = ux
    func pt(_ b: CGPoint, _ along: CGFloat, _ across: CGFloat) -> CGPoint {
        CGPoint(x: b.x + ux * along + nx * across, y: b.y + uy * along + ny * across)
    }
    let head: CGFloat = 270
    let arrow = CGMutablePath()
    arrow.move(to: pt(start, 0, 14))
    arrow.addLine(to: pt(end, -head * 0.78, 52))
    arrow.addLine(to: pt(end, -head, 150))
    arrow.addLine(to: end)
    arrow.addLine(to: pt(end, -head, -150))
    arrow.addLine(to: pt(end, -head * 0.78, -52))
    arrow.addLine(to: pt(start, 0, -14))
    arrow.closeSubpath()
    ctx.setShadow(offset: CGSize(width: 0, height: -8 * s), blur: 18 * s, color: NSColor.black.withAlphaComponent(0.3).cgColor)
    ctx.addPath(arrow)
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fillPath()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try render(size).write(to: out.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(size * 2).write(to: out.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
