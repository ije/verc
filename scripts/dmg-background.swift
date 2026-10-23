import AppKit

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let size = NSSize(width: 680, height: 340)
var representations: [NSBitmapImageRep] = []

for scale in 1...2 {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 680 * scale, pixelsHigh: 340 * scale,
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    bitmap.size = size
    let graphics = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    let context = graphics.cgContext
    NSColor(srgbRed: 0.98, green: 0.98, blue: 0.985, alpha: 1).setFill()
    NSRect(origin: .zero, size: size).fill()

    let glows: [(CGFloat, CGFloat, CGFloat, CGFloat, NSColor)] = [
        (10, 350, 180, 105, NSColor(srgbRed: 0.35, green: 0.88, blue: 1, alpha: 0.65)),
        (180, 370, 180, 95, NSColor(srgbRed: 0.40, green: 0.70, blue: 1, alpha: 0.48)),
        (670, 350, 180, 105, NSColor(srgbRed: 1, green: 0.63, blue: 0.91, alpha: 0.65)),
        (500, 370, 180, 95, NSColor(srgbRed: 1, green: 0.85, blue: 0.40, alpha: 0.48)),
        (340, -115, 580, 220, NSColor(srgbRed: 0.40, green: 0.76, blue: 1, alpha: 0.65))
    ]
    for (x, y, width, height, color) in glows {
        context.saveGState()
        context.translateBy(x: x, y: y)
        context.scaleBy(x: width, y: height)
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                  colors: [color.cgColor, color.withAlphaComponent(0).cgColor] as CFArray,
                                  locations: [0, 1])!
        context.drawRadialGradient(gradient, startCenter: .zero, startRadius: 0,
                                   endCenter: .zero, endRadius: 1, options: [])
        context.restoreGState()
    }

    let instruction = NSMutableAttributedString(string: "To install, drag Verc to Applications", attributes: [
        .font: NSFont.systemFont(ofSize: 14),
        .foregroundColor: NSColor(srgbRed: 0.30, green: 0.30, blue: 0.32, alpha: 1)
    ])
    for word in ["Verc", "Applications"] {
        instruction.addAttributes([
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: NSColor(srgbRed: 0.12, green: 0.12, blue: 0.14, alpha: 1)
        ], range: (instruction.string as NSString).range(of: word))
    }
    instruction.draw(at: NSPoint(x: (size.width - instruction.size().width) / 2, y: 282))

    for index in 0..<3 {
        NSColor(white: 0.18, alpha: 0.22 + CGFloat(index) * 0.30).setStroke()
        let path = NSBezierPath()
        let x = 322 + CGFloat(index) * 14
        path.move(to: NSPoint(x: x, y: 154))
        path.line(to: NSPoint(x: x + 6, y: 162))
        path.line(to: NSPoint(x: x, y: 170))
        path.lineWidth = 3
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
    }
    NSGraphicsContext.restoreGraphicsState()
    representations.append(bitmap)
}

try NSBitmapImageRep.representationOfImageReps(in: representations, using: .tiff, properties: [.compressionMethod: 5])!
    .write(to: directory.appendingPathComponent("background.tiff"))
try representations[1].representation(using: .png, properties: [:])!
    .write(to: directory.appendingPathComponent("background.png"))
