import AppKit
import Foundation

// Render each icon size from the same vector geometry as docs/images/hmacviewer-logo.svg.
// Coordinates below use the SVG's top-left origin on a 1024-point canvas.
let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
let white = NSColor.white.cgColor
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
        let cg = context.cgContext
        cg.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        cg.translateBy(x: 0, y: 1024); cg.scaleBy(x: 1, y: -1)
        func rounded(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> CGPath {
            CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: r, cornerHeight: r, transform: nil)
        }

        // Teal-to-indigo rounded square.
        cg.saveGState()
        cg.addPath(rounded(32, 32, 960, 960, 220)); cg.clip()
        let colors = [NSColor(red: 0.122, green: 0.820, blue: 0.788, alpha: 1).cgColor,
                      NSColor(red: 0.294, green: 0.247, blue: 0.839, alpha: 1).cgColor] as CFArray
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
        cg.drawLinearGradient(gradient, start: CGPoint(x: 32, y: 32), end: CGPoint(x: 992, y: 992), options: [])
        cg.restoreGState()

        // Monitor with a tinted screen, neck and base.
        cg.addPath(rounded(170, 230, 684, 450, 40))
        cg.setFillColor(NSColor(white: 1, alpha: 0.14).cgColor); cg.fillPath()
        cg.addPath(rounded(170, 230, 684, 450, 40))
        cg.setStrokeColor(white); cg.setLineWidth(36); cg.strokePath()
        cg.setFillColor(white)
        cg.fill(CGRect(x: 470, y: 680, width: 84, height: 84))
        cg.addPath(rounded(360, 752, 304, 40, 20)); cg.fillPath()

        // The "H".
        cg.addPath(rounded(380, 330, 72, 250, 12)); cg.fillPath()
        cg.addPath(rounded(572, 330, 72, 250, 12)); cg.fillPath()
        cg.fill(CGRect(x: 440, y: 422, width: 144, height: 64))

        // Remote-control pointer.
        let pointer = CGMutablePath()
        pointer.addLines(between: [CGPoint(x: 664, y: 500), CGPoint(x: 664, y: 668), CGPoint(x: 706, y: 628),
                                   CGPoint(x: 736, y: 698), CGPoint(x: 768, y: 684), CGPoint(x: 738, y: 616),
                                   CGPoint(x: 796, y: 616)])
        pointer.closeSubpath()
        cg.addPath(pointer)
        cg.setStrokeColor(NSColor(red: 0.231, green: 0.200, blue: 0.722, alpha: 1).cgColor)
        cg.setLineWidth(16); cg.setLineJoin(.round)
        cg.drawPath(using: .fillStroke)

        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(
            to: destination.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
