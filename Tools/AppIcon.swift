import AppKit
import Foundation
let root = CommandLine.arguments[1]
let iconSet = URL(fileURLWithPath: root).appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconSet, withIntermediateDirectories: true)
func makeIcon(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(pixels) / 1024
    NSGraphicsContext.current?.imageInterpolation = .high
    let box = NSRect(x: 80*s, y: 80*s, width: 864*s, height: 864*s)
    NSColor(calibratedRed: 0.16, green: 0.36, blue: 0.29, alpha: 1).setFill()
    NSBezierPath(roundedRect: box, xRadius: 195*s, yRadius: 195*s).fill()
    NSColor(calibratedRed: 0.94, green: 0.92, blue: 0.81, alpha: 1).setStroke()
    let border = NSBezierPath(roundedRect: box.insetBy(dx: 32*s, dy: 32*s), xRadius: 170*s, yRadius: 170*s)
    border.lineWidth = 2*s; border.stroke()
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont(name: "STSongti-SC-Regular", size: 510*s) ?? NSFont.systemFont(ofSize: 500*s),
        .foregroundColor: NSColor(calibratedRed: 0.97, green: 0.96, blue: 0.90, alpha: 1)
    ]
    let word = "字" as NSString
    let size = word.size(withAttributes: attributes)
    word.draw(at: NSPoint(x: (CGFloat(pixels)-size.width)/2 - 25*s, y: (CGFloat(pixels)-size.height)/2 + 65*s), withAttributes: attributes)
    let lens = NSBezierPath(ovalIn: NSRect(x: 634*s, y: 244*s, width: 150*s, height: 150*s))
    NSColor(calibratedRed: 0.16, green: 0.36, blue: 0.29, alpha: 1).setFill()
    lens.fill()
    NSColor(calibratedRed: 0.87, green: 0.81, blue: 0.58, alpha: 1).setStroke()
    lens.lineWidth = 24*s; lens.stroke()
    let handle = NSBezierPath()
    handle.move(to: NSPoint(x: 767*s, y: 261*s))
    handle.line(to: NSPoint(x: 835*s, y: 193*s))
    handle.lineWidth = 28*s; handle.lineCapStyle = .round; handle.stroke()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        try makeIcon(size * scale).write(to: iconSet.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
print(iconSet.path)
