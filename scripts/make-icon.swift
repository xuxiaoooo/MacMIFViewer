import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let colors: [NSColor] = [
    .init(srgbRed: 0.28, green: 0.49, blue: 0.99, alpha: 1),
    .init(srgbRed: 0.28, green: 0.88, blue: 0.64, alpha: 1),
    .init(srgbRed: 0.99, green: 0.34, blue: 0.39, alpha: 1),
    .init(srgbRed: 0.94, green: 0.35, blue: 0.84, alpha: 1),
    .init(srgbRed: 0.99, green: 0.77, blue: 0.29, alpha: 1),
    .init(srgbRed: 0.22, green: 0.85, blue: 0.95, alpha: 1),
]
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let size = points * scale
        let pixels = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: pixels)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
        let base = NSBezierPath(roundedRect: CGRect(x: 80, y: 80, width: 864, height: 864),
                                xRadius: 184, yRadius: 184)
        NSColor(srgbRed: 0.058, green: 0.085, blue: 0.129, alpha: 1).setFill()
        base.fill()
        let inset = NSBezierPath(roundedRect: CGRect(x: 200, y: 245, width: 624, height: 534),
                                 xRadius: 86, yRadius: 86)
        NSColor(srgbRed: 0.47, green: 0.82, blue: 0.82, alpha: 0.32).setStroke()
        inset.lineWidth = 16
        inset.stroke()
        for (index, color) in colors.enumerated() {
            let x = 267 + index % 3 * 184, y = 521 - index / 3 * 177
            let mark = NSBezierPath(ovalIn: CGRect(x: x, y: y, width: 122, height: 122))
            color.setFill()
            mark.fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 1 ? "" : "@2x"
        let name = "icon_\(points)x\(points)\(suffix).png"
        try pixels.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
    }
}
