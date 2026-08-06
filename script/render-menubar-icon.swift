// Renders the macOS menu bar template glyph (clipboard + sync arrows) into
// mac/App/Assets.xcassets/MenuBarIcon.imageset at 18/36/54 px.
// Geometry mirrors mac/App/IconSources/MenuBarIcon.svg; keep both in sync.
//
// Usage (from the repo root):
//   swift script/render-menubar-icon.swift mac/App/Assets.xcassets/MenuBarIcon.imageset
import AppKit

let outDir = CommandLine.arguments[1]

// Geometry in the 54x54 design space (top-left origin, y down).
let boardRect = CGRect(x: 10.5, y: 8.5, width: 33, height: 40) // stroke-width 4, rx 6.5
let clipRect = CGRect(x: 19.5, y: 3.5, width: 15, height: 10)  // filled, rx 3.5
let cx = 27.0, cy = 30.5, r = 7.0
let arcStroke = 3.5
let a1: (start: Double, end: Double) = (185, 315)
let a2: (start: Double, end: Double) = (5, 135)

func point(_ deg: Double) -> CGPoint {
    let rad = deg * .pi / 180
    return CGPoint(x: cx + r * cos(rad), y: cy + r * sin(rad))
}

func tangent(_ deg: Double) -> CGPoint {
    let rad = deg * .pi / 180
    return CGPoint(x: -sin(rad), y: cos(rad))
}

func drawGlyph(in ctx: CGContext, scale: CGFloat) {
    ctx.scaleBy(x: scale, y: scale)
    ctx.setFillColor(.black)
    ctx.setStrokeColor(.black)

    // Board outline.
    ctx.setLineWidth(4)
    ctx.addPath(CGPath(roundedRect: boardRect, cornerWidth: 6.5, cornerHeight: 6.5, transform: nil))
    ctx.strokePath()

    // Clip.
    ctx.addPath(CGPath(roundedRect: clipRect, cornerWidth: 3.5, cornerHeight: 3.5, transform: nil))
    ctx.fillPath()

    // Sync arcs. CGContext with y-down coords: clockwise: false traverses increasing angle.
    ctx.setLineWidth(arcStroke)
    ctx.setLineCap(.round)
    for a in [a1, a2] {
        ctx.addArc(center: CGPoint(x: cx, y: cy), radius: r,
                   startAngle: a.start * .pi / 180, endAngle: a.end * .pi / 180,
                   clockwise: false)
        ctx.strokePath()
    }

    // Arrowheads at the arc ends, pointing along the direction of travel.
    for a in [a1, a2] {
        let e = point(a.end), t = tangent(a.end)
        let n = CGPoint(x: -t.y, y: t.x)
        let tip = CGPoint(x: e.x + t.x * 5.8, y: e.y + t.y * 5.8)
        let b1 = CGPoint(x: e.x - t.x * 0.7 + n.x * 3.4, y: e.y - t.y * 0.7 + n.y * 3.4)
        let b2 = CGPoint(x: e.x - t.x * 0.7 - n.x * 3.4, y: e.y - t.y * 0.7 - n.y * 3.4)
        ctx.move(to: tip)
        ctx.addLine(to: b1)
        ctx.addLine(to: b2)
        ctx.closePath()
        ctx.fillPath()
    }
}

for (px, name) in [(18, "menubar-icon.png"), (36, "menubar-icon@2x.png"), (54, "menubar-icon@3x.png")] {
    guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fatalError("no context")
    }
    // Flip to top-left origin, y down, then scale from the 54-unit design space.
    ctx.translateBy(x: 0, y: CGFloat(px))
    ctx.scaleBy(x: 1, y: -1)
    drawGlyph(in: ctx, scale: CGFloat(px) / 54.0)
    guard let image = ctx.makeImage() else { fatalError("no image") }
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: px, height: px)
    guard let data = rep.representation(using: .png, properties: [:]) else { fatalError("no png") }
    try! data.write(to: URL(fileURLWithPath: "\(outDir)/\(name)"))
    print("wrote \(name) \(px)x\(px)")
}
