import AppKit
import CoreGraphics
import ImageIO
import Foundation
import UniformTypeIdentifiers

// Fits an externally generated DMG background onto the DMG canvases:
//   <out>        800x470 (1x, what finder uses as .background/background.png)
//   --2x <path>  1600x940 (2x, installed as .background/background@2x.png)
// Content is scaled to the full canvas width and shifted down by --shift px
// (1x scale), padding the top with the image's own top row.

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write(Data("usage: fit-dmg-background <in.png> <out.png> [--shift N] [--2x out2x.png]\n".utf8))
    exit(1)
}
var shift: CGFloat = 0
var out2x: String?
if let i = args.firstIndex(of: "--shift"), args.count > i + 1, let n = Double(args[i + 1]) { shift = CGFloat(n) }
if let i = args.firstIndex(of: "--2x"), args.count > i + 1 { out2x = args[i + 1] }

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil)!
let img = CGImageSourceCreateImageAtIndex(src, 0, nil)!

func render(_ out: String, _ W: CGFloat, _ H: CGFloat, _ scale: CGFloat) {
    let ctx = CGContext(
        data: nil, width: Int(W), height: Int(H),
        bitsPerComponent: 8, bytesPerRow: 0,
        space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let sh = floor(CGFloat(img.height) * scale)

    // 1px strip of the source's top row stretched over the padded area
    let stripCtx = CGContext(
        data: nil, width: Int(W), height: 1,
        bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    stripCtx.interpolationQuality = .none
    stripCtx.draw(img, in: CGRect(x: 0, y: 0, width: W, height: 1))
    let strip = stripCtx.makeImage()!
    let shiftPx = shift * (W == 800 ? 1 : 2)
    ctx.draw(strip, in: CGRect(x: 0, y: H - shiftPx, width: W, height: shiftPx + 1))

    // content: scaled to full width, bottom edge at the canvas bottom
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: W, height: sh))

    let dest = CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: out) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
    print("rendered \(out) \(Int(W))x\(Int(H)) shift \(shiftPx)")
}

render(args[2], 800, 470, 800 / CGFloat(img.width))
if let out2x { render(out2x, 1600, 940, 1600 / CGFloat(img.width)) }
