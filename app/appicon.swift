// appicon.swift <out.iconset>: draws the Mac mini VPN app icon at every size macOS asks for.
//
// The same picture as the menu-bar glyph (main.swift, "icon"): a Mac mini seen from the front, with
// its one lamp at 77 % of the width, lit green. Here it is a filled aluminium box on a graphite
// tile, so it reads as an app in Finder, Spotlight and launchers.
//
// TILE: Apple's macOS app-icon grid, a 1024 canvas with an 824 squircle centred (100 margin) and a
// soft drop shadow. The squircle is a superellipse (n = 5), close to Apple's continuous corners.
// Every size is drawn from the vector, not scaled from 1024, so small sizes stay sharp.
//
// Build: swiftc -O app/appicon.swift -o /tmp/appicon && /tmp/appicon /tmp/AppIcon.iconset
//        iconutil -c icns /tmp/AppIcon.iconset -o app/AppIcon.icns
import AppKit

func squircle(_ r: CGRect, n: CGFloat = 5) -> CGPath {
    let p = CGMutablePath()
    let a = r.width / 2, b = r.height / 2, cx = r.midX, cy = r.midY
    for i in 0...720 {
        let t = CGFloat(i) / 720 * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = cx + a * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n)
        let y = cy + b * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n)
        i == 0 ? p.move(to: CGPoint(x: x, y: y)) : p.addLine(to: CGPoint(x: x, y: y))
    }
    p.closeSubpath()
    return p
}

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: a)
}

func linear(_ ctx: CGContext, _ colors: [CGColor], from: CGPoint, to: CGPoint) {
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)!
    ctx.drawLinearGradient(g, start: from, end: to, options: [])
}

/// Draws the icon in a 1024-unit space; the context is already scaled to the target size.
func draw(_ ctx: CGContext) {
    // Tile with its shadow.
    let tile = squircle(CGRect(x: 100, y: 100, width: 824, height: 824))
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: rgb(0x000000, 0.35))
    ctx.addPath(tile); ctx.setFillColor(rgb(0x202328)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(tile); ctx.clip()
    linear(ctx, [rgb(0x3B4048), rgb(0x1B1D21)], from: CGPoint(x: 512, y: 924), to: CGPoint(x: 512, y: 100))
    // A faint light from above, so the tile is not flat.
    let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                          colors: [rgb(0xFFFFFF, 0.10), rgb(0xFFFFFF, 0)] as CFArray, locations: nil)!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 980), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 980), endRadius: 620, options: [])
    ctx.restoreGState()

    // The Mac mini, front view: 2024 proportions (127 x 50 mm, about 2.5 : 1).
    let body = CGRect(x: 512 - 290, y: 512 - 100, width: 580, height: 230)
    let radius: CGFloat = 44
    // Its shadow on the desk.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -26), blur: 40, color: rgb(0x000000, 0.55))
    ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 30, dy: 0), cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.setFillColor(rgb(0x000000)); ctx.fillPath()
    ctx.restoreGState()
    // The recessed foot under the box: it makes the box read as a machine on a desk, not a button.
    ctx.addPath(CGPath(roundedRect: CGRect(x: body.minX + 46, y: body.minY - 16, width: body.width - 92, height: 40),
                       cornerWidth: 14, cornerHeight: 14, transform: nil))
    ctx.setFillColor(rgb(0x0E0F11)); ctx.fillPath()
    // Aluminium.
    let shell = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.saveGState()
    ctx.addPath(shell); ctx.clip()
    linear(ctx, [rgb(0xF2F3F5), rgb(0xD5D8DC), rgb(0xA9AEB5)], from: CGPoint(x: 512, y: body.maxY), to: CGPoint(x: 512, y: body.minY))
    // The top edge catches the light.
    ctx.addPath(CGPath(roundedRect: CGRect(x: body.minX, y: body.maxY - 10, width: body.width, height: 30),
                       cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.setFillColor(rgb(0xFFFFFF, 0.55)); ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(shell); ctx.setStrokeColor(rgb(0x6E737A, 0.9)); ctx.setLineWidth(3); ctx.strokePath()

    // The lamp at 77 % of the width (as in the menu bar), lit green with a soft glow.
    let lamp = CGPoint(x: body.minX + body.width * 0.77, y: body.midY)
    let halo = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                          colors: [rgb(0x34C759, 0.55), rgb(0x34C759, 0)] as CFArray, locations: nil)!
    ctx.saveGState()
    ctx.addPath(shell); ctx.clip()
    ctx.drawRadialGradient(halo, startCenter: lamp, startRadius: 0, endCenter: lamp, endRadius: 64, options: [])
    ctx.restoreGState()
    let d: CGFloat = 34
    ctx.addEllipse(in: CGRect(x: lamp.x - d / 2, y: lamp.y - d / 2, width: d, height: d))
    ctx.setFillColor(rgb(0x30D158)); ctx.fillPath()
    ctx.addEllipse(in: CGRect(x: lamp.x - d / 2, y: lamp.y - d / 2, width: d, height: d))
    ctx.setStrokeColor(rgb(0x1E9E43)); ctx.setLineWidth(2.5); ctx.strokePath()
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
for (pt, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let px = pt * scale
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: CGFloat(px) / 1024, y: CGFloat(px) / 1024)
    draw(ctx)
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    let name = "icon_\(pt)x\(pt)\(scale == 2 ? "@2x" : "").png"
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/\(name)"))
}
print("ok \(out)")
