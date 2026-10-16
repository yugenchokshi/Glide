// Renders the NotchBuddy app icon (iridescent orb under a notch) into an .iconset.
import AppKit
let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let inset = s * 0.1
    let body = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = CGPath(roundedRect: body, cornerWidth: s * 0.2, cornerHeight: s * 0.2, transform: nil)
    ctx.addPath(path); ctx.clip()
    let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [CGColor(red: 0.09, green: 0.09, blue: 0.12, alpha: 1), CGColor(red: 0.02, green: 0.02, blue: 0.03, alpha: 1)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: 0), options: [])
    // Notch
    let nw = body.width * 0.46, nh = body.height * 0.14
    let notch = CGPath(roundedRect: CGRect(x: s / 2 - nw / 2, y: body.maxY - nh, width: nw, height: nh + s * 0.05), cornerWidth: nh * 0.6, cornerHeight: nh * 0.6, transform: nil)
    ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.addPath(notch); ctx.fillPath()
    // Orb
    let r = body.width * 0.25
    let c = CGPoint(x: s / 2, y: body.midY - body.height * 0.05)
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)); ctx.clip()
    let colors = [CGColor(red: 0.55, green: 0.42, blue: 1, alpha: 1), CGColor(red: 0.25, green: 0.62, blue: 1, alpha: 1), CGColor(red: 0.2, green: 0.9, blue: 0.85, alpha: 1), CGColor(red: 1, green: 0.45, blue: 0.75, alpha: 1)]
    let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 0.4, 0.7, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: c.x - r, y: c.y + r), end: CGPoint(x: c.x + r, y: c.y - r), options: [])
    let hi = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [CGColor(gray: 1, alpha: 0.75), CGColor(gray: 1, alpha: 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(hi, startCenter: CGPoint(x: c.x - r * 0.35, y: c.y + r * 0.4), startRadius: 0, endCenter: CGPoint(x: c.x - r * 0.35, y: c.y + r * 0.4), endRadius: r * 0.9, options: [])
    ctx.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
for size in [16, 32, 128, 256, 512] {
    try! render(size).write(to: URL(fileURLWithPath: "\(out)/icon_\(size)x\(size).png"))
    try! render(size * 2).write(to: URL(fileURLWithPath: "\(out)/icon_\(size)x\(size)@2x.png"))
}
