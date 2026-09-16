#!/usr/bin/env swift
// Generates the menubar icons: a raven's head in profile, beak closed (idle) and
// beak open (recording).
//
//     swift scripts/generate-status-bar-icons.swift
//
// Writes StatusBarIcon{,Open}{,@2x}.png into macOS/Resources — template images,
// black on transparent, 24×18 pt.
//
// The outline is measured off a canonical raven profile silhouette (508×382),
// point by point, in that image's pixel coordinates with y down; the icon crops
// it to x 32…448, y 70…382, keeping its 4:3 frame with the neck running off the
// bottom and the right edge. A square frame would leave either a tiny head or a
// neck two thirds of the icon tall.
//
// Head and eye are the same shapes in both states. Only the beak differs: the
// upper mandible stays where it is — the skull does not move — and the lower jaw
// drops about the corner of the mouth.

import AppKit

let crop = CGRect(x: 32, y: 70, width: 416, height: 312)
let outputSize = CGSize(width: 24, height: 18)

func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

/// A closed Catmull-Rom spline through the points. A point listed twice keeps a
/// corner there instead of a curve swinging past it.
func spline(_ points: [CGPoint]) -> CGMutablePath {
    let path = CGMutablePath()
    let count = points.count
    path.move(to: points[0])
    for index in 0..<count {
        let p0 = points[(index - 1 + count) % count]
        let p1 = points[index]
        let p2 = points[(index + 1) % count]
        let p3 = points[(index + 2) % count]
        if p1 == p2 { continue }
        let tangentIn = p0 == p1 ? .zero : CGPoint(x: (p2.x - p0.x) / 6, y: (p2.y - p0.y) / 6)
        let tangentOut = p2 == p3 ? .zero : CGPoint(x: (p3.x - p1.x) / 6, y: (p3.y - p1.y) / 6)
        path.addCurve(to: p2,
                      control1: CGPoint(x: p1.x + tangentIn.x, y: p1.y + tangentIn.y),
                      control2: CGPoint(x: p2.x - tangentOut.x, y: p2.y - tangentOut.y))
    }
    path.closeSubpath()
    return path
}

// MARK: - Head

/// Forehead, crown and the long slope of the back of the neck, carried on past
/// the frame so the crop does the cutting.
let crownAndBack = [
    p(220, 91), p(240, 84), p(260, 80), p(280, 78), p(300, 78), p(320, 80), p(340, 85),
    p(360, 94), p(380, 109), p(400, 130), p(420, 154), p(440, 182), p(460, 212),
    p(480, 239), p(500, 263), p(540, 305),
]

/// The front of the neck, from below the frame up to the chin. It widens all the
/// way down: a raven's neck is thick and runs into chest and shoulders.
let neckFront = [
    p(252, 420), p(247, 370), p(242, 340), p(237, 310), p(232, 280), p(228, 265),
    p(220, 235), p(212, 220), p(198, 205),
]

/// The head's edge under the bill sits well inside the bill, which is drawn over
/// it, so the two never meet on an edge antialiasing would leave a seam along.
let head = spline(
    [p(190, 106), p(200, 101)]
        + crownAndBack
        + [p(560, 330), p(560, 330), p(560, 440), p(560, 440), p(252, 440), p(252, 440)]
        + neckFront
        + [p(190, 199), p(190, 199), p(190, 106)]
)

/// A raven's eye is about a quarter of the head's depth where it sits; smaller
/// and it is gone at 18 pt.
let eye = CGPath(ellipseIn: CGRect(x: 254 - 16, y: 124 - 16, width: 32, height: 32), transform: nil)

// MARK: - Beak

/// Upper edge of the bill, base to tip: a long shallow rise, turning down at the
/// tip.
let ridge = [
    p(214, 100), p(200, 101), p(180, 106), p(160, 112), p(140, 118), p(120, 123), p(100, 129),
    p(80, 139), p(60, 153), p(40, 179),
]
/// Lower edge, tip back to the chin, running on into the head.
let underside = [
    p(60, 184), p(80, 185), p(100, 186), p(120, 186), p(140, 190), p(160, 193), p(180, 196),
    p(205, 206), p(232, 214), p(232, 214),
]
/// Where the mandibles meet, tip back to the corner of the mouth.
let gape = [p(60, 175), p(100, 172), p(140, 172), p(180, 174), p(214, 178), p(214, 178)]
let hinge = p(214, 178)
let tip = ridge[ridge.count - 1]

// The base of the ridge is doubled in both shapes: without a corner there, the
// spline closing the shape swings up past the ridge and nicks the forehead.
let closedBeak = spline([ridge[0]] + ridge + [tip] + underside)

let openBeak: CGPath = {
    let beak = spline([ridge[0]] + ridge + [tip] + gape)
    let angle = -22 * CGFloat.pi / 180
    let jaw = ([hinge, hinge] + gape.reversed().dropFirst(2) + [p(44, 180), p(44, 180)] + underside)
        .map { point -> CGPoint in
            let dx = point.x - hinge.x
            let dy = point.y - hinge.y
            return p(hinge.x + dx * cos(angle) - dy * sin(angle),
                     hinge.y + dx * sin(angle) + dy * cos(angle))
        }
    beak.addPath(spline(jaw))
    return beak
}()

// MARK: - Output

func render(open: Bool, scale: Int) -> Data {
    let width = Int(outputSize.width) * scale
    let height = Int(outputSize.height) * scale
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // The crop onto the canvas, y flipped.
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: CGFloat(width) / crop.width, y: -CGFloat(height) / crop.height)
    context.translateBy(x: -crop.minX, y: -crop.minY)

    context.setFillColor(NSColor.black.cgColor)
    // One shape at a time: overlapping shapes drawn in opposite directions
    // cancel out under a single winding fill.
    for shape in [head, open ? openBeak : closedBeak] {
        context.addPath(shape)
        context.fillPath()
    }
    context.setBlendMode(.clear)
    context.addPath(eye)
    context.fillPath()

    let rep = NSBitmapImageRep(cgImage: context.makeImage()!)
    rep.size = outputSize
    return rep.representation(using: .png, properties: [:])!
}

let resources = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("macOS/Resources")

for open in [false, true] {
    for scale in [1, 2] {
        let name = "StatusBarIcon\(open ? "Open" : "")\(scale == 2 ? "@2x" : "").png"
        try! render(open: open, scale: scale).write(to: resources.appendingPathComponent(name))
        print("wrote macOS/Resources/\(name)")
    }
}
