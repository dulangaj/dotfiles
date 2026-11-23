import AppKit
let size = 1024.0
let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { r in
    NSBezierPath(roundedRect: r.insetBy(dx: 100, dy: 100), xRadius: 185, yRadius: 185).addClip()
    NSGradient(colors: [NSColor(white: 0.08, alpha: 1), NSColor(white: 0.22, alpha: 1)])!.draw(in: r, angle: 90)
    let c = NSPoint(x: size / 2, y: size / 2)
    NSColor(white: 0.96, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: c.x - 170, y: c.y - 170, width: 340, height: 340)).fill()
    NSColor(white: 0.12, alpha: 0.6).setFill()
    NSBezierPath(rect: NSRect(x: c.x, y: c.y - 170, width: 170, height: 340)).fill()
    return true
}
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
