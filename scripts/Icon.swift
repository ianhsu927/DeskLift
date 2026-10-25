import AppKit
let dir = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
func render(_ pixels: Int, _ name: String) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let t = AffineTransform(scale: CGFloat(pixels) / 1024)
    (t as NSAffineTransform).concat()
    NSColor.clear.setFill(); NSRect(x: 0, y: 0, width: 1024, height: 1024).fill()
    let r = NSRect(x: 64, y: 64, width: 896, height: 896)
    let p = NSBezierPath(roundedRect: r, xRadius: 205, yRadius: 205)
    NSGradient(starting: NSColor(calibratedRed: 0.22, green: 0.53, blue: 0.96, alpha: 1), ending: NSColor(calibratedRed: 0.09, green: 0.24, blue: 0.65, alpha: 1))!.draw(in: p, angle: -70)
    NSColor.white.setFill()
    NSBezierPath(roundedRect: NSRect(x: 225, y: 490, width: 574, height: 55), xRadius: 20, yRadius: 20).fill()
    for x in [282.0, 692.0] {
        NSBezierPath(roundedRect: NSRect(x: x, y: 278, width: 42, height: 225), xRadius: 14, yRadius: 14).fill()
        NSBezierPath(roundedRect: NSRect(x: x-47, y: 260, width: 136, height: 32), xRadius: 14, yRadius: 14).fill()
    }
    let arrow = NSBezierPath(); arrow.lineWidth = 26; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round
    arrow.move(to: NSPoint(x: 512, y: 615)); arrow.line(to: NSPoint(x: 512, y: 774))
    arrow.move(to: NSPoint(x: 455, y: 717)); arrow.line(to: NSPoint(x: 512, y: 774)); arrow.line(to: NSPoint(x: 569, y: 717))
    NSColor.white.setStroke(); arrow.stroke()
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
}
for n in [16,32,128,256,512] {
    render(n, "icon_\(n)x\(n).png")
    render(n * 2, "icon_\(n)x\(n)@2x.png")
}
