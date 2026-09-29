// Generates Sources/App/Assets.xcassets/AppIcon.appiconset (all macOS sizes) from vector drawing.
//   swift scripts/make-icon.swift [preview.png]
// With an argument it only writes a 1024 px preview there.
import AppKit

/// "#RRGGBB" -> CGColor
func hex(_ value: String) -> CGColor {
    var n: UInt64 = 0
    Scanner(string: value.replacingOccurrences(of: "#", with: "")).scanHexInt64(&n)
    return CGColor(red: CGFloat((n >> 16) & 255) / 255, green: CGFloat((n >> 8) & 255) / 255, blue: CGFloat(n & 255) / 255, alpha: 1)
}

// Background gradient, top to bottom. Override with ICON_TOP / ICON_BOTTOM (e.g. "#FF7A45").
let topColor = hex(ProcessInfo.processInfo.environment["ICON_TOP"] ?? "#FFA23F")
let bottomColor = hex(ProcessInfo.processInfo.environment["ICON_BOTTOM"] ?? "#E5304E")

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
    ctx.setFillColor(bottomColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: space, colors: [topColor, bottomColor] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    // Gentle top highlight.
    let sheen = CGGradient(colorsSpace: space, colors: [
        CGColor(gray: 1, alpha: 0.22), CGColor(gray: 1, alpha: 0),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 560), options: [])
    ctx.restoreGState()

    // The exact SF Symbol the menu bar item uses, so the app icon and the menu bar match.
    let symbolName = ProcessInfo.processInfo.environment["ICON_SYMBOL"] ?? "fan"
    let configuration = NSImage.SymbolConfiguration(pointSize: 600, weight: .regular)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)!.withSymbolConfiguration(configuration)!
    let width: CGFloat = 600
    let height = width * symbol.size.height / symbol.size.width
    let rect = CGRect(x: 512 - width / 2, y: 512 - height / 2, width: width, height: height)
    let previous = NSGraphicsContext.current
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: CGColor(gray: 0, alpha: 0.28))
    symbol.draw(in: rect)
    NSGraphicsContext.current = previous
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
