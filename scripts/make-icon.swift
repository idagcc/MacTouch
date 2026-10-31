import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1])
let set = output.appendingPathComponent("MacTouch.iconset")
try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let side = CGFloat(pixels)
        NSColor(calibratedRed: 0.08, green: 0.13, blue: 0.14, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: side * 0.06, y: side * 0.06, width: side * 0.88, height: side * 0.88), xRadius: side * 0.2, yRadius: side * 0.2).fill()
        if let symbol = NSImage(systemSymbolName: "hand.point.up.left.fill", accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: side * 0.57, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor(calibratedRed: 0.43, green: 0.88, blue: 0.71, alpha: 1)]))
            let rendered = symbol.withSymbolConfiguration(config) ?? symbol
            rendered.draw(in: NSRect(x: side * 0.24, y: side * 0.19, width: side * 0.52, height: side * 0.62))
        }
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: set.appendingPathComponent(name))
    }
}
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", set.path, "-o", output.appendingPathComponent("MacTouch.icns").path]
try process.run(); process.waitUntilExit()
guard process.terminationStatus == 0 else { exit(process.terminationStatus) }
try FileManager.default.removeItem(at: set)
