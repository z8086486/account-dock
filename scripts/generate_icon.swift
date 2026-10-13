// Reproducible, original vector artwork for Account Dock. No third-party marks.
import AppKit
import Foundation

let destination = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
let navy = NSColor(srgbRed: 0.055, green: 0.14, blue: 0.20, alpha: 1)
let blue = NSColor(srgbRed: 0.65, green: 0.82, blue: 0.88, alpha: 1)
let orange = NSColor(srgbRed: 1, green: 0.40, blue: 0.13, alpha: 1)
func roundRect(_ rect: NSRect, _ radius: CGFloat, _ color: NSColor) {
    color.setFill(); NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
}
func render(_ pixels: Int) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSAffineTransform(scale: CGFloat(pixels) / 1024).concat()
    // A recessed dock holds two identity cards. The orange card is the active account.
    let shadow = NSShadow(); shadow.shadowColor = navy.withAlphaComponent(0.25)
    shadow.shadowBlurRadius = 28; shadow.shadowOffset = NSSize(width: 0, height: -12)
    NSGraphicsContext.saveGraphicsState(); shadow.set()
    roundRect(NSRect(x: 64, y: 64, width: 896, height: 896), 202, navy)
    NSGraphicsContext.restoreGraphicsState()
    roundRect(NSRect(x: 241, y: 318, width: 424, height: 445), 76, blue)
    roundRect(NSRect(x: 361, y: 224, width: 424, height: 445), 76, navy)
    roundRect(NSRect(x: 383, y: 246, width: 380, height: 401), 62, orange)
    navy.setFill()
    NSBezierPath(ovalIn: NSRect(x: 521, y: 475, width: 104, height: 104)).fill()
    roundRect(NSRect(x: 469, y: 358, width: 208, height: 79), 39, navy)
    // A wide blue landing rail completes the dock, readable at small sizes.
    roundRect(NSRect(x: 220, y: 166, width: 586, height: 38), 19, blue)
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}
extension NSAffineTransform {
    convenience init(scale: CGFloat) { self.init(); scaleX(by: scale, yBy: scale) }
}
let sizes = [(16,1),(16,2),(32,1),(32,2),(128,1),(128,2),(256,1),(256,2),(512,1),(512,2)]
for (size, scale) in sizes {
    let suffix = scale == 2 ? "@2x" : ""
    try render(size * scale).write(to: destination.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
}
