import AppKit
// Renders each SVG given on the command line to a PNG of the requested size.
let args = CommandLine.arguments
let size = Int(args[1])!
for path in args.dropFirst(2) {
    let url = URL(fileURLWithPath: path)
    guard let image = NSImage(contentsOf: url) else { print("could not load \(path)"); continue }
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size), from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    let out = url.deletingPathExtension().lastPathComponent + "-\(size).png"
    try rep.representation(using: .png, properties: [:])!.write(to: url.deletingLastPathComponent().appendingPathComponent(out))
    print("wrote \(out)")
}
