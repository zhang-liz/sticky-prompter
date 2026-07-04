// Generates the app icon: a tilted yellow sticky note with script lines
// (top one highlighted) and a microphone. Run: swift make-icon.swift out.png
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
let S: CGFloat = 1024

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

let brown = NSColor(calibratedRed: 0.30, green: 0.24, blue: 0.05, alpha: 1)
let orange = NSColor(calibratedRed: 1.00, green: 0.45, blue: 0.13, alpha: 1)

// tilt the whole note slightly
ctx.saveGState()
ctx.translateBy(x: S / 2, y: S / 2)
ctx.rotate(by: -4 * .pi / 180)
ctx.translateBy(x: -S / 2, y: -S / 2)

let note = CGRect(x: 120, y: 130, width: 784, height: 784)
let notePath = CGPath(roundedRect: note, cornerWidth: 42, cornerHeight: 42, transform: nil)

// drop shadow + base fill
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -16), blur: 56,
              color: NSColor.black.withAlphaComponent(0.35).cgColor)
ctx.addPath(notePath)
ctx.setFillColor(NSColor(calibratedRed: 0.95, green: 0.76, blue: 0.24, alpha: 1).cgColor)
ctx.fillPath()
ctx.restoreGState()

// paper gradient
ctx.saveGState()
ctx.addPath(notePath)
ctx.clip()
let grad = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [
        NSColor(calibratedRed: 1.00, green: 0.93, blue: 0.52, alpha: 1).cgColor,
        NSColor(calibratedRed: 0.95, green: 0.76, blue: 0.24, alpha: 1).cgColor,
    ] as CFArray,
    locations: [0, 1])!
ctx.drawLinearGradient(grad,
    start: CGPoint(x: S / 2, y: note.maxY),
    end: CGPoint(x: S / 2, y: note.minY), options: [])

// folded corner (bottom-right)
ctx.move(to: CGPoint(x: note.maxX, y: note.minY + 155))
ctx.addLine(to: CGPoint(x: note.maxX - 155, y: note.minY))
ctx.addLine(to: CGPoint(x: note.maxX, y: note.minY))
ctx.closePath()
ctx.setFillColor(NSColor(calibratedRed: 0.72, green: 0.55, blue: 0.13, alpha: 0.55).cgColor)
ctx.fillPath()
ctx.restoreGState()

// script lines — the top one is the "current sentence" highlight
func bar(_ y: CGFloat, _ w: CGFloat, _ color: NSColor) {
    let r = CGRect(x: 215, y: y, width: w, height: 56)
    ctx.addPath(CGPath(roundedRect: r, cornerWidth: 28, cornerHeight: 28, transform: nil))
    ctx.setFillColor(color.cgColor)
    ctx.fillPath()
}
bar(786, 520, orange)
bar(696, 440, brown.withAlphaComponent(0.50))
bar(606, 360, brown.withAlphaComponent(0.32))

// microphone
ctx.setFillColor(brown.cgColor)
let capsule = CGRect(x: 512 - 75, y: 300, width: 150, height: 244)
ctx.addPath(CGPath(roundedRect: capsule, cornerWidth: 75, cornerHeight: 75, transform: nil))
ctx.fillPath()

ctx.setStrokeColor(brown.cgColor)
ctx.setLineWidth(34)
ctx.setLineCap(.round)
// U-shaped holder
ctx.addArc(center: CGPoint(x: 512, y: 400), radius: 137,
           startAngle: .pi, endAngle: 0, clockwise: false)
ctx.strokePath()
// stem + base
ctx.move(to: CGPoint(x: 512, y: 263))
ctx.addLine(to: CGPoint(x: 512, y: 210))
ctx.strokePath()
ctx.move(to: CGPoint(x: 424, y: 210))
ctx.addLine(to: CGPoint(x: 600, y: 210))
ctx.strokePath()

ctx.restoreGState() // un-tilt
NSGraphicsContext.restoreGraphicsState()

let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
