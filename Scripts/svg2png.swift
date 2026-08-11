// Rasterise an SVG at a given edge length. macOS reads SVG natively through
// NSImage (_NSSVGImageRep), so this needs no dependency beyond AppKit — which
// matters for a script that has to run on a fresh checkout.
import AppKit

let arguments = CommandLine.arguments
guard arguments.count > 3, let side = Double(arguments[3]),
      let source = NSImage(contentsOfFile: arguments[1])
else {
    FileHandle.standardError.write(Data("usage: svg2png <in.svg> <out.png> <edge>\n".utf8))
    exit(1)
}

source.size = NSSize(width: side, height: side)
let canvas = NSImage(size: NSSize(width: side, height: side))
canvas.lockFocus()
source.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
canvas.unlockFocus()

guard let tiff = canvas.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:])
else { exit(1) }
try png.write(to: URL(fileURLWithPath: arguments[2]))
