import AppKit

// Draws the Reclaim app icon (a ring chart on a deep gradient) to the PNG path given as argument 1.
let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

let rect = NSRect(x: 60, y: 60, width: size - 120, height: size - 120)
let bg = NSBezierPath(roundedRect: rect, xRadius: 220, yRadius: 220)
NSGradient(colors: [NSColor(red: 0.10, green: 0.14, blue: 0.30, alpha: 1), NSColor(red: 0.22, green: 0.10, blue: 0.40, alpha: 1)])!
    .draw(in: bg, angle: -60)

let center = NSPoint(x: size / 2, y: size / 2)
let radius: CGFloat = 260
let slices: [(CGFloat, NSColor)] = [
    (0.38, NSColor(red: 0.30, green: 0.80, blue: 1.0, alpha: 1)),
    (0.27, NSColor(red: 0.65, green: 0.45, blue: 1.0, alpha: 1)),
    (0.20, NSColor(red: 1.0, green: 0.62, blue: 0.25, alpha: 1)),
    (0.15, NSColor(white: 1, alpha: 0.18)),
]
var start: CGFloat = 90
for (fraction, color) in slices {
    let end = start - 360 * fraction
    let arc = NSBezierPath()
    arc.appendArc(withCenter: center, radius: radius, startAngle: start - 1.5, endAngle: end + 1.5, clockwise: true)
    arc.lineWidth = 120
    arc.lineCapStyle = .butt
    color.setStroke()
    arc.stroke()
    start = end
}
image.unlockFocus()

guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
    let png = rep.representation(using: .png, properties: [:])
else { exit(1) }
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
