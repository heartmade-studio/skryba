// Renders an SVG to a square PNG using macOS's built-in SVG support.
// Usage: swift scripts/render-svg.swift in.svg out.png <size>
import AppKit

let args = CommandLine.arguments
guard args.count == 4, let size = Int(args[3]),
      let image = NSImage(contentsOf: URL(fileURLWithPath: args[1]))
else {
    FileHandle.standardError.write(Data("usage: render-svg.swift in.svg out.png size\n".utf8))
    exit(1)
}
let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
