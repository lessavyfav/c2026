// Turns square artwork into a macOS app icon master (1024×1024): the art clipped to Apple's
// rounded-square body (824×824 at 100,100, corner radius ≈185) with the standard soft shadow.
// Usage: swift scripts/make-icon.swift <art.png> <out-1024.png>
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let a = CommandLine.arguments
guard a.count == 3, let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: a[1]) as CFURL, nil),
      let art = CGImageSourceCreateImageAtIndex(src, 0, nil) else { fatalError("usage: make-icon <art.png> <out.png>") }
let side = min(art.width, art.height)
let square = art.cropping(to: CGRect(x: (art.width - side) / 2, y: (art.height - side) / 2, width: side, height: side))!

let size = 1024, inset: CGFloat = 100, body: CGFloat = 824, radius: CGFloat = 185
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.interpolationQuality = .high
let rect = CGRect(x: inset, y: inset, width: body, height: body)
let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
// Shadow under the body (Apple template: ~10 px down, ~20 px blur, 30% black).
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 20, color: CGColor(gray: 0, alpha: 0.3))
ctx.addPath(path); ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fillPath()
ctx.restoreGState()
ctx.addPath(path); ctx.clip()
ctx.draw(square, in: rect)
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: a[2]) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil); CGImageDestinationFinalize(dest)
print("wrote \(a[2])")
