import AppKit
import Foundation
import CoreGraphics

let fileManager = FileManager.default
let appIconSet = URL(fileURLWithPath: "Murmur/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
let size = CGSize(width: 1024, height: 1024)
let image = NSImage(size: size)
image.lockFocus()
guard let ctx = NSGraphicsContext.current?.cgContext else {
    fatalError("Missing graphics context")
}

ctx.setAllowsAntialiasing(true)
ctx.setShouldAntialias(true)
ctx.clear(CGRect(origin: .zero, size: size))

let cardRect = CGRect(x: 52, y: 52, width: 920, height: 920)

NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
shadow.shadowBlurRadius = 40
shadow.shadowOffset = CGSize(width: 0, height: -14)
shadow.set()

let cardPath = NSBezierPath(roundedRect: cardRect, xRadius: 210, yRadius: 210)
let cardGradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.98, green: 0.98, blue: 0.96, alpha: 1),
    NSColor(calibratedRed: 0.90, green: 0.91, blue: 0.93, alpha: 1),
])!
cardGradient.draw(in: cardPath, angle: -90)
NSGraphicsContext.restoreGraphicsState()

NSGraphicsContext.saveGraphicsState()
let clipPath = NSBezierPath(roundedRect: cardRect, xRadius: 210, yRadius: 210)
clipPath.addClip()
let glowGradient = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [
        NSColor(calibratedRed: 0.73, green: 0.79, blue: 0.76, alpha: 0.22).cgColor,
        NSColor.clear.cgColor,
    ] as CFArray,
    locations: [0, 1]
)!
ctx.drawRadialGradient(
    glowGradient,
    startCenter: CGPoint(x: 320, y: 790),
    startRadius: 12,
    endCenter: CGPoint(x: 320, y: 790),
    endRadius: 560,
    options: .drawsAfterEndLocation
)
NSGraphicsContext.restoreGraphicsState()

func strokeArc(center: CGPoint, radius: CGFloat, start: CGFloat, end: CGFloat, width: CGFloat, color: NSColor) {
    let path = NSBezierPath()
    path.appendArc(withCenter: center, radius: radius, startAngle: start, endAngle: end, clockwise: false)
    path.lineWidth = width
    path.lineCapStyle = .round
    color.setStroke()
    path.stroke()
}

let center = CGPoint(x: 468, y: 512)
let waveColor = NSColor(calibratedRed: 0.24, green: 0.28, blue: 0.36, alpha: 1)
let accentColor = NSColor(calibratedRed: 0.96, green: 0.62, blue: 0.33, alpha: 1)

strokeArc(center: center, radius: 108, start: -58, end: 58, width: 48, color: waveColor)
strokeArc(center: center, radius: 216, start: -58, end: 58, width: 46, color: waveColor)
strokeArc(center: center, radius: 324, start: -58, end: 58, width: 43, color: waveColor)
strokeArc(center: center, radius: 432, start: -58, end: 58, width: 40, color: waveColor)
strokeArc(center: center, radius: 216, start: -30, end: 30, width: 46, color: accentColor)

image.unlockFocus()

guard
    let tiff = image.tiffRepresentation,
    let rep = NSBitmapImageRep(data: tiff),
    let png = rep.representation(using: .png, properties: [:])
else {
    fatalError("Failed to encode master icon")
}

let iconFiles: [(name: String, size: Int)] = [
    ("appicon_16.png", 16),
    ("appicon_32.png", 32),
    ("appicon_32x32@2x.png", 64),
    ("appicon_128.png", 128),
    ("appicon_128x128@2x.png", 256),
    ("appicon_256.png", 256),
    ("appicon_256x256@2x.png", 512),
    ("appicon_512.png", 512),
    ("appicon_512x512@2x.png", 1024),
]

func resizedPNG(to dimension: Int) -> Data {
    let resized = NSImage(size: CGSize(width: dimension, height: dimension))
    resized.lockFocus()
    image.draw(in: CGRect(x: 0, y: 0, width: dimension, height: dimension))
    resized.unlockFocus()

    guard
        let tiff = resized.tiffRepresentation,
        let rep = NSBitmapImageRep(data: tiff),
        let png = rep.representation(using: .png, properties: [:])
    else {
        fatalError("Failed to encode resized icon \(dimension)")
    }

    return png
}

for file in iconFiles {
    let url = appIconSet.appendingPathComponent(file.name)
    try resizedPNG(to: file.size).write(to: url)
}

print("Regenerated app icon set at \(appIconSet.path)")
