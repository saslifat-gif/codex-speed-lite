import CoreGraphics
import ImageIO
import Foundation

// A single graphite gauge on a quiet silver tile; no text, gradients, or decoration.
let root = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
for size in [16, 32, 64, 128, 256, 512, 1024] {
    let space = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                            bytesPerRow: size * 4, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let scale = CGFloat(size) / 1024
    context.scaleBy(x: scale, y: scale)
    context.setFillColor(CGColor(red: 0.94, green: 0.945, blue: 0.95, alpha: 1))
    context.addPath(CGPath(roundedRect: CGRect(x: 72, y: 72, width: 880, height: 880),
                          cornerWidth: 196, cornerHeight: 196, transform: nil))
    context.fillPath()
    let ink = CGColor(red: 0.15, green: 0.16, blue: 0.18, alpha: 1)
    context.setStrokeColor(ink)
    context.setFillColor(ink)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    let center = CGPoint(x: 512, y: 474)
    context.setLineWidth(42)
    context.addArc(center: center, radius: 248, startAngle: .pi * 7 / 6,
                   endAngle: -.pi / 6, clockwise: true)
    context.strokePath()
    context.setLineWidth(24)
    for angle in [CGFloat.pi / 6, .pi / 2, .pi * 5 / 6] {
        context.move(to: CGPoint(x: center.x + cos(angle) * 176, y: center.y + sin(angle) * 176))
        context.addLine(to: CGPoint(x: center.x + cos(angle) * 200, y: center.y + sin(angle) * 200))
        context.strokePath()
    }
    context.setLineWidth(34)
    context.move(to: center)
    context.addLine(to: CGPoint(x: 642, y: 612))
    context.strokePath()
    context.fillEllipse(in: CGRect(x: center.x - 29, y: center.y - 29, width: 58, height: 58))
    let image = context.makeImage()!
    func write(_ name: String) {
        let destination = CGImageDestinationCreateWithURL(root.appendingPathComponent(name) as CFURL,
                                                          "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        precondition(CGImageDestinationFinalize(destination))
    }
    if [16, 32, 128, 256, 512].contains(size) { write("icon_\(size)x\(size).png") }
    if [32, 64, 256, 512, 1024].contains(size) { write("icon_\(size / 2)x\(size / 2)@2x.png") }
}
