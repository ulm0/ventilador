// Generates Sources/App/Assets.xcassets/AppIcon.appiconset (all macOS sizes) from vector drawing.
//   swift scripts/make-icon.swift [preview.png]
// With an argument it only writes a 1024 px preview there.
import AppKit

func draw(into ctx: CGContext, size: CGFloat) {
    let s = size / 1024
    ctx.scaleBy(x: s, y: s)
    let canvas = CGRect(x: 0, y: 0, width: 1024, height: 1024)
    let body = canvas.insetBy(dx: 100, dy: 100)              // Apple's macOS icon grid: 824 pt body
    let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    let space = CGColorSpaceCreateDeviceRGB()

    // Body with a soft drop shadow.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(shape)
    ctx.setFillColor(CGColor(red: 0.08, green: 0.32, blue: 0.84, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: space, colors: [
        CGColor(red: 0.30, green: 0.80, blue: 0.95, alpha: 1),
        CGColor(red: 0.06, green: 0.30, blue: 0.83, alpha: 1),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    // Gentle top highlight.
    let sheen = CGGradient(colorsSpace: space, colors: [
        CGColor(gray: 1, alpha: 0.22), CGColor(gray: 1, alpha: 0),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 560), options: [])
    ctx.restoreGState()

    // Fan.
    let center = CGPoint(x: 512, y: 512)
    let radius: CGFloat = 312
    ctx.saveGState()
    ctx.translateBy(x: center.x, y: center.y)

    // Housing ring.
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.32))
    ctx.setLineWidth(16)
    ctx.strokeEllipse(in: CGRect(x: -radius - 34, y: -radius - 34, width: 2 * (radius + 34), height: 2 * (radius + 34)))

    let bladeCount = 4                                       // same as the SF Symbol "fan" used in the menu bar
    let blade = CGMutablePath()
    blade.move(to: CGPoint(x: 46, y: -20))
    blade.addCurve(to: CGPoint(x: radius * 0.97, y: -radius * 0.20),
                   control1: CGPoint(x: radius * 0.30, y: -radius * 0.42), control2: CGPoint(x: radius * 0.70, y: -radius * 0.46))
    blade.addCurve(to: CGPoint(x: radius * 0.84, y: radius * 0.16),
                   control1: CGPoint(x: radius * 1.07, y: -radius * 0.04), control2: CGPoint(x: radius * 1.02, y: radius * 0.14))
    blade.addCurve(to: CGPoint(x: 46, y: 30),
                   control1: CGPoint(x: radius * 0.56, y: radius * 0.22), control2: CGPoint(x: radius * 0.26, y: radius * 0.30))
    blade.closeSubpath()

    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: CGColor(gray: 0, alpha: 0.22))
    for index in 0..<bladeCount {
        ctx.saveGState()
        ctx.rotate(by: CGFloat(index) * 2 * .pi / CGFloat(bladeCount) + .pi / 8)
        ctx.addPath(blade)
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.97))
        ctx.fillPath()
        ctx.restoreGState()
    }
    ctx.setShadow(offset: .zero, blur: 0)

    // Hub.
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: -54, y: -54, width: 108, height: 108))
    ctx.setFillColor(CGColor(red: 0.10, green: 0.38, blue: 0.86, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: -26, y: -26, width: 52, height: 52))
    ctx.restoreGState()
}

func png(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    context.cgContext.interpolationQuality = .high
    draw(into: context.cgContext, size: CGFloat(size))
    return rep.representation(using: .png, properties: [:])!
}

if let preview = CommandLine.arguments.dropFirst().first {
    try png(size: 1024).write(to: URL(fileURLWithPath: preview))
    exit(0)
}

let set = URL(fileURLWithPath: "Sources/App/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
var images: [[String: String]] = []
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(base)x\(base)@\(scale)x.png"
        try png(size: base * scale).write(to: set.appendingPathComponent(name))
        images.append(["size": "\(base)x\(base)", "idiom": "mac", "filename": name, "scale": "\(scale)x"])
    }
}
let contents: [String: Any] = ["images": images, "info": ["version": 1, "author": "xcode"]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]).write(to: set.appendingPathComponent("Contents.json"))
try JSONSerialization.data(withJSONObject: ["info": ["version": 1, "author": "xcode"]], options: [.prettyPrinted])
    .write(to: set.deletingLastPathComponent().appendingPathComponent("Contents.json"))
print("wrote \(images.count) icons to \(set.path)")
