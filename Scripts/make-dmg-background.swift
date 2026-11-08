import AppKit
import CoreGraphics
import ImageIO
import Foundation
import UniformTypeIdentifiers

// Renders the DMG background with a cute HALF-SIZE drag prompt:
//   dmg-background.png       800x470  (1x, used as .background/background.png)
//   dmg-background@2x.png    1600x940 (2x, installed as background@2x.png)
// All geometry below is in 1x WINDOW points (origin top-left, y down);
// render() converts to CG space (origin bottom-left, y up) and multiplies by
// the retina scale.

let args = CommandLine.arguments
var write2x = args.contains("--2x")

let navy = CGColor(srgbRed: 0.09, green: 0.20, blue: 0.35, alpha: 1)
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

// Window geometry: app icon center (200,280), Applications (600,280), each
// 128px wide (y 216..344). The arrow arcs across the gap between them, with a
// shallow half-height dip just below the icon centers.
let arcStart   = CGPoint(x: 268, y: 300) // window pts (inside the icon gap)
let arcEnd     = CGPoint(x: 532, y: 300)
let arcControl = CGPoint(x: 400, y: 322)
let arcDepth: CGFloat = 16   // visual dip below the endpoints

func render(_ out: String, _ s: CGFloat) {
    let W: CGFloat = 800 * s, H: CGFloat = 470 * s
    let ctx = CGContext(
        data: nil, width: Int(W), height: Int(H),
        bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Window pt -> CG
    let C = { (x: CGFloat, _ y: CGFloat) -> CGPoint in CGPoint(x: x * s, y: H - y * s) }

    // Airy light-blue gradient so black Finder labels stay readable
    let base = CGGradient(
        colorsSpace: srgb,
        colors: [
            CGColor(srgbRed: 0.973, green: 0.984, blue: 0.996, alpha: 1),
            CGColor(srgbRed: 0.894, green: 0.937, blue: 0.976, alpha: 1),
            CGColor(srgbRed: 0.851, green: 0.918, blue: 0.969, alpha: 1),
        ] as CFArray,
        locations: [0, 0.6, 1])!
    ctx.drawLinearGradient(base, start: CGPoint(x: 0, y: H), end: CGPoint(x: W, y: 0), options: [])
    let glows: [(CGColor, CGFloat, CGPoint)] = [
        (CGColor(srgbRed: 0.235, green: 0.631, blue: 0.827, alpha: 0.10), 250 * s, CGPoint(x: W * 0.82, y: H)),
        (CGColor(srgbRed: 0.20, green: 0.60, blue: 0.90, alpha: 0.08), 280 * s, CGPoint(x: W * 0.12, y: H)),
    ]
    for (color, radius, center) in glows {
        let grad = CGGradient(colorsSpace: srgb, colors: [color, color.copy(alpha: 0)!] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(grad, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
    }

    // Dotted arrow, ctrl point below the endpoints for a shallow dip
    let start = C(arcStart.x, arcStart.y)
    let end = C(arcEnd.x, arcEnd.y)
    let ctrl = C(arcControl.x, arcControl.y)
    var ux = end.x - ctrl.x, uy = end.y - ctrl.y
    let tl = sqrt(ux * ux + uy * uy)
    ux /= tl; uy /= tl
    let tip = CGPoint(x: end.x + ux * 7 * s, y: end.y + uy * 7 * s)
    let headS: CGFloat = 9 * s

    ctx.saveGState()
    ctx.setStrokeColor(navy.copy(alpha: 0.55)!)
    ctx.setLineWidth(1.6 * s)
    ctx.setLineCap(.round)
    ctx.setLineDash(phase: 0, lengths: [0.1, 11 * s])
    let arc = CGMutablePath()
    arc.move(to: start)
    arc.addQuadCurve(to: end, control: ctrl)
    ctx.addPath(arc)
    ctx.strokePath()
    let w1 = CGPoint(x: tip.x - ux * headS - uy * headS * 0.55, y: tip.y - uy * headS + ux * headS * 0.55)
    let w2 = CGPoint(x: tip.x - ux * headS + uy * headS * 0.55, y: tip.y - uy * headS - ux * headS * 0.55)
    let head = CGMutablePath()
    head.move(to: tip)
    head.addLine(to: w1)
    head.addLine(to: w2)
    head.closeSubpath()
    ctx.setFillColor(navy.copy(alpha: 0.6)!)
    ctx.addPath(head)
    ctx.fillPath()
    ctx.restoreGState()

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)

    // "drag", small, riding the arc's left descending segment;
    // window-space: point on curve at t plus 12pt up-normal offset
    let font = NSFont.systemFont(ofSize: 20 * s, weight: .semibold)
    let line = NSAttributedString(string: "drag", attributes: [
        .font: font,
        .foregroundColor: NSColor(cgColor: navy)!,
    ])
    let t: CGFloat = 0.25
    let wx = (1 - t) * (1 - t) * arcStart.x + 2 * t * (1 - t) * arcControl.x + t * t * arcEnd.x
    let wy = (1 - t) * (1 - t) * arcStart.y + 2 * t * (1 - t) * arcControl.y + t * t * arcEnd.y
    var dx = 2 * (1 - t) * (arcControl.x - arcStart.x) + 2 * t * (arcEnd.x - arcControl.x)
    var dy = 2 * (1 - t) * (arcControl.y - arcStart.y) + 2 * t * (arcEnd.y - arcControl.y)
    let dlen = sqrt(dx * dx + dy * dy)
    dx /= dlen; dy /= dlen
    // normal pointing "up" in window space is (-dy, +dx)? dy>0 means the curve
    // descends; up-normal in window space = (dy, -dx) rotated... take the one
    // with negative window-y component:
    let nwx = dy, nwy = -dx
    let sign: CGFloat = nwy < 0 ? 1 : -1
    let tx = wx + sign * nwx / sqrt(nwx * nwx + nwy * nwy) * 12
    let ty = wy + sign * nwy / sqrt(nwx * nwx + nwy * nwy) * 12
    let size = line.size()
    ctx.saveGState()
    ctx.translateBy(x: tx * s, y: H - ty * s)
    ctx.rotate(by: -atan2(-sign * -dy, dx))   // visual slope of the segment
    line.draw(at: CGPoint(x: -size.width / 2, y: -size.height * 0.32))
    ctx.restoreGState()

    // tiny whale bobbing near the arrowhead
    let whale = NSAttributedString(string: "🐳", attributes: [.font: NSFont.systemFont(ofSize: 18 * s)])
    let wsize = whale.size()
    whale.draw(at: CGPoint(x: 520 * s - wsize.width / 2, y: H - 328 * s - wsize.height / 2))

    // a couple of tiny sparkles
    func star(_ x: CGFloat, _ y: CGFloat, _ r1: CGFloat, _ alpha: CGFloat) {
        let c = C(x, y), r = r1 * s
        let p = CGMutablePath()
        p.move(to: CGPoint(x: c.x, y: c.y + r))
        p.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y), control: CGPoint(x: c.x + r * 0.12, y: c.y + r * 0.12))
        p.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r), control: CGPoint(x: c.x + r * 0.12, y: c.y - r * 0.12))
        p.addQuadCurve(to: CGPoint(x: c.x - r, y: c.y), control: CGPoint(x: c.x - r * 0.12, y: c.y - r * 0.12))
        p.addQuadCurve(to: CGPoint(x: c.x, y: c.y + r), control: CGPoint(x: c.x - r * 0.12, y: c.y + r * 0.12))
        ctx.addPath(p)
        ctx.setFillColor(navy.copy(alpha: alpha)!)
        ctx.fillPath()
    }
    star(150, 152, 7, 0.28)
    star(660, 145, 6, 0.24)

    NSGraphicsContext.restoreGraphicsState()

    let dest = CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: out) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
    print("rendered \(out) \(Int(W))x\(Int(H))")
}

render("dmg-background.png", 1)
if write2x { render("dmg-background@2x.png", 2) }
