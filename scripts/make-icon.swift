import AppKit

let output = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let inset = CGFloat(pixels) * 0.055
        let rect = CGRect(x: inset, y: inset, width: CGFloat(pixels) - inset * 2, height: CGFloat(pixels) - inset * 2)
        NSColor(red: 214 / 255, green: 242 / 255, blue: 138 / 255, alpha: 1).setFill()
        NSBezierPath(roundedRect: rect, xRadius: CGFloat(pixels) * 0.22, yRadius: CGFloat(pixels) * 0.22).fill()
        if let symbol = NSImage(systemSymbolName: "rectangle.on.rectangle.angled", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: CGFloat(pixels) * 0.47, weight: .semibold)) {
            let tinted = NSImage(size: symbol.size)
            tinted.lockFocus()
            symbol.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
            NSColor(red: 16 / 255, green: 17 / 255, blue: 19 / 255, alpha: 1).setFill()
            NSRect(origin: .zero, size: symbol.size).fill(using: .sourceIn)
            tinted.unlockFocus()
            tinted.draw(in: CGRect(x: CGFloat(pixels) * 0.24, y: CGFloat(pixels) * 0.24, width: CGFloat(pixels) * 0.52, height: CGFloat(pixels) * 0.52))
        }
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(output)/icon_\(size)x\(size)\(suffix).png"))
    }
}
