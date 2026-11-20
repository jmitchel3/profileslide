// Renders animated ProfileSlide icons (APNG, GIF, SVG):
// A spinning Chrome-style 3-blade logo whose colors shift through profile themes
// while the center hub morphs between the Chrome core and common profile emojis.
//
// Usage: swift scripts/make-animated-icon.swift  (run from the repo root)

import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - Color & Easing Helpers

struct RGB {
    var r: CGFloat
    var g: CGFloat
    var b: CGFloat

    init(_ hex: UInt32) {
        r = CGFloat((hex >> 16) & 0xFF) / 255.0
        g = CGFloat((hex >> 8) & 0xFF) / 255.0
        b = CGFloat(hex & 0xFF) / 255.0
    }

    init(r: CGFloat, g: CGFloat, b: CGFloat) {
        self.r = r; self.g = g; self.b = b
    }

    var cgColor: CGColor {
        CGColor(srgbRed: r, green: g, blue: b, alpha: 1.0)
    }

    func cgColor(alpha: CGFloat) -> CGColor {
        CGColor(srgbRed: r, green: g, blue: b, alpha: alpha)
    }

    var hexString: String {
        String(format: "#%02X%02X%02X", Int(round(r * 255)), Int(round(g * 255)), Int(round(b * 255)))
    }

    func toHSB() -> (h: CGFloat, s: CGFloat, b: CGFloat) {
        let maxV = max(r, max(g, b))
        let minV = min(r, min(g, b))
        let d = maxV - minV
        var h: CGFloat = 0
        let s: CGFloat = maxV == 0 ? 0 : d / maxV
        if d != 0 {
            if maxV == r {
                h = ((g - b) / d).truncatingRemainder(dividingBy: 6)
            } else if maxV == g {
                h = (b - r) / d + 2
            } else {
                h = (r - g) / d + 4
            }
            h /= 6
            if h < 0 { h += 1 }
        }
        return (h, s, maxV)
    }

    static func fromHSB(h: CGFloat, s: CGFloat, b: CGFloat) -> RGB {
        let hh = ((h.truncatingRemainder(dividingBy: 1)) + 1).truncatingRemainder(dividingBy: 1) * 6
        let c = b * s
        let x = c * (1 - abs(hh.truncatingRemainder(dividingBy: 2) - 1))
        let m = b - c
        let (r1, g1, b1): (CGFloat, CGFloat, CGFloat)
        switch Int(hh) {
        case 0: (r1, g1, b1) = (c, x, 0)
        case 1: (r1, g1, b1) = (x, c, 0)
        case 2: (r1, g1, b1) = (0, c, x)
        case 3: (r1, g1, b1) = (0, x, c)
        case 4: (r1, g1, b1) = (x, 0, c)
        default: (r1, g1, b1) = (c, 0, x)
        }
        return RGB(r: r1 + m, g: g1 + m, b: b1 + m)
    }

    /// Vibrant shortest-arc HSB interpolation so transitional colors stay bright.
    static func lerpVibrant(_ a: RGB, _ b: RGB, _ t: CGFloat) -> RGB {
        let ha = a.toHSB()
        let hb = b.toHSB()
        var dh = hb.h - ha.h
        if dh > 0.5 { dh -= 1 }
        if dh < -0.5 { dh += 1 }
        let h = ha.h + dh * t
        let s = ha.s + (hb.s - ha.s) * t
        let v = ha.b + (hb.b - ha.b) * t
        return RGB.fromHSB(h: h, s: s, b: v)
    }

    static func lerpRGB(_ a: RGB, _ b: RGB, _ t: CGFloat) -> RGB {
        RGB(r: a.r + (b.r - a.r) * t, g: a.g + (b.g - a.g) * t, b: a.b + (b.b - a.b) * t)
    }

    func darkened(_ amount: CGFloat) -> RGB {
        RGB(r: max(0, r * (1 - amount)), g: max(0, g * (1 - amount)), b: max(0, b * (1 - amount)))
    }

    func lightened(_ amount: CGFloat) -> RGB {
        RGB(r: min(1, r + (1 - r) * amount), g: min(1, g + (1 - g) * amount), b: min(1, b + (1 - b) * amount))
    }
}

func easeInOutCubic(_ x: CGFloat) -> CGFloat {
    let t = max(0, min(1, x))
    return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
}

func easeOutBack(_ x: CGFloat) -> CGFloat {
    let t = max(0, min(1, x))
    let c1: CGFloat = 1.70158
    let c3 = c1 + 1
    return 1 + c3 * pow(t - 1, 3) + c1 * pow(t - 1, 2)
}

func easeInCubic(_ x: CGFloat) -> CGFloat {
    let t = max(0, min(1, x))
    return t * t * t
}

// MARK: - Themes / Stages

struct Stage {
    let name: String
    let emoji: String? // nil = Classic Chrome blue hub
    let blades: [RGB]  // 3 blades: [top, right, left] at angle 0
    let hubTop: RGB
    let hubBottom: RGB
}

let stages: [Stage] = [
    Stage(
        name: "Chrome",
        emoji: nil,
        blades: [RGB(0xEA4335), RGB(0xFBBC05), RGB(0x34A853)],
        hubTop: RGB(0x4285F4),
        hubBottom: RGB(0x1A73E8)
    ),
    Stage(
        name: "Work",
        emoji: "💼",
        blades: [RGB(0x3B82F6), RGB(0x06B6D4), RGB(0x6366F1)],
        hubTop: RGB(0xFFFFFF),
        hubBottom: RGB(0xE8F1FF)
    ),
    Stage(
        name: "Gaming",
        emoji: "🎮",
        blades: [RGB(0xA855F7), RGB(0xEC4899), RGB(0x14B8A6)],
        hubTop: RGB(0xFFFFFF),
        hubBottom: RGB(0xF5E8FF)
    ),
    Stage(
        name: "Launch",
        emoji: "🚀",
        blades: [RGB(0xF97316), RGB(0xFACC15), RGB(0xF43F5E)],
        hubTop: RGB(0xFFFFFF),
        hubBottom: RGB(0xFFF1E6)
    ),
    Stage(
        name: "Creative",
        emoji: "🎨",
        blades: [RGB(0x10B981), RGB(0x84CC16), RGB(0x0EA5E9)],
        hubTop: RGB(0xFFFFFF),
        hubBottom: RGB(0xE8FBF2)
    ),
    Stage(
        name: "Music",
        emoji: "🎧",
        blades: [RGB(0xE11D48), RGB(0x8B5CF6), RGB(0xF59E0B)],
        hubTop: RGB(0xFFFFFF),
        hubBottom: RGB(0xFCEAF0)
    )
]

// MARK: - Emoji Rendering Cache

var emojiCache: [String: CGImage] = [:]

func renderEmojiImage(_ emoji: String, canvasPx: Int) -> CGImage {
    let key = "\(emoji)_\(canvasPx)"
    if let cached = emojiCache[key] { return cached }

    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: canvasPx, pixelsHigh: canvasPx,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    let nsCtx = NSGraphicsContext(bitmapImageRep: rep)!
    nsCtx.imageInterpolation = .high
    NSGraphicsContext.current = nsCtx

    let fontSize = CGFloat(canvasPx) * 0.70
    let font = NSFont.systemFont(ofSize: fontSize)
    let attrs: [NSAttributedString.Key: Any] = [.font: font]
    let str = NSAttributedString(string: emoji, attributes: attrs)
    let sz = str.size()
    str.draw(at: NSPoint(x: (CGFloat(canvasPx) - sz.width) / 2, y: (CGFloat(canvasPx) - sz.height) / 2))
    NSGraphicsContext.restoreGraphicsState()

    // Trim to actual non-transparent alpha bounding box so every emoji centers accurately.
    let raw = rep.cgImage!
    guard let data = rep.bitmapData else { return raw }
    let bpr = rep.bytesPerRow
    var minX = canvasPx, minY = canvasPx, maxX = -1, maxY = -1
    for y in 0..<canvasPx {
        let row = data.advanced(by: y * bpr)
        for x in 0..<canvasPx {
            let a = row[x * 4 + 3]
            if a > 12 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
    }
    let result: CGImage
    if maxX >= minX && maxY >= minY {
        let cropRect = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        result = raw.cropping(to: cropRect) ?? raw
    } else {
        result = raw
    }
    emojiCache[key] = result
    return result
}

// MARK: - Chrome Geometry & Frame Renderer

/// Draws a single blade bounded by leading tangent phiLead -> outer arc -> trailing tangent phiTrail.
func makeBladePath(outerR: CGFloat, whiteR: CGFloat, phiLead: CGFloat, phiTrail: CGFloat) -> CGPath {
    let alpha = acos(whiteR / outerR)
    let pLead = CGPoint(x: whiteR * cos(phiLead), y: whiteR * sin(phiLead))
    let qLead = CGPoint(x: outerR * cos(phiLead - alpha), y: outerR * sin(phiLead - alpha))
    let pTrail = CGPoint(x: whiteR * cos(phiTrail), y: whiteR * sin(phiTrail))

    let path = CGMutablePath()
    path.move(to: .zero)
    path.addLine(to: pLead)
    path.addLine(to: qLead)
    // Outer arc goes clockwise from (phiLead - alpha) to (phiTrail - alpha).
    path.addArc(center: .zero, radius: outerR, startAngle: phiLead - alpha, endAngle: phiTrail - alpha, clockwise: true)
    path.addLine(to: pTrail)
    path.addLine(to: .zero)
    path.closeSubpath()
    return path
}

func fillBlade(_ ctx: CGContext, path: CGPath, color: RGB, midAngle: CGFloat, outerR: CGFloat) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let topColor = color.lightened(0.08).cgColor
    let botColor = color.darkened(0.10).cgColor
    let cs = CGColorSpaceCreateDeviceRGB()
    let grad = CGGradient(colorsSpace: cs, colors: [topColor, color.cgColor, botColor] as CFArray, locations: [0.0, 0.48, 1.0])!
    let start = CGPoint(x: outerR * cos(midAngle + 0.55), y: outerR * sin(midAngle + 0.55))
    let end = CGPoint(x: outerR * cos(midAngle - 0.55), y: outerR * sin(midAngle - 0.55))
    ctx.drawLinearGradient(grad, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}

/// Adds a subtle origami shadow along the tangent divider line phi.
func drawTangentShadow(_ ctx: CGContext, outerR: CGFloat, whiteR: CGFloat, phi: CGFloat) {
    let alpha = acos(whiteR / outerR)
    let p = CGPoint(x: whiteR * cos(phi), y: whiteR * sin(phi))
    let q = CGPoint(x: outerR * cos(phi - alpha), y: outerR * sin(phi - alpha))
    // Inward normal pointing clockwise (into the next blade): (-cos(phi), -sin(phi)).
    let nx = -cos(phi)
    let ny = -sin(phi)
    let depth = outerR * 0.085

    let quad = CGMutablePath()
    quad.move(to: p)
    quad.addLine(to: q)
    quad.addLine(to: CGPoint(x: q.x + nx * depth, y: q.y + ny * depth))
    quad.addLine(to: CGPoint(x: p.x + nx * depth, y: p.y + ny * depth))
    quad.closeSubpath()

    ctx.saveGState()
    ctx.addPath(quad)
    ctx.clip()
    let cs = CGColorSpaceCreateDeviceRGB()
    let grad = CGGradient(
        colorsSpace: cs,
        colors: [CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.16),
                 CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.0)] as CFArray,
        locations: [0.0, 1.0]
    )!
    ctx.drawLinearGradient(
        grad,
        start: p,
        end: CGPoint(x: p.x + nx * depth, y: p.y + ny * depth),
        options: []
    )
    ctx.restoreGState()
}

func renderFrame(
    size: Int,
    stageIdx: Int,
    localT: CGFloat, // 0..<1 within current stage
    withShadow: Bool
) -> CGImage {
    let nextIdx = (stageIdx + 1) % stages.count
    let cur = stages[stageIdx]
    let nxt = stages[nextIdx]

    // Phase timing within each stage:
    // 0.00 .. 0.52 -> dwell (gentle drift)
    // 0.52 .. 1.00 -> spin burst + color crossfade + center morph
    let transStart: CGFloat = 0.52
    let transU: CGFloat = localT <= transStart ? 0 : (localT - transStart) / (1 - transStart)
    let easeU = easeInOutCubic(transU)

    // Rotation: 60 deg steady drift + 180 deg burst = 240 deg per stage.
    // Over 6 stages = 1440 deg = 4 exact full turns -> seamless loop!
    let baseDeg = CGFloat(stageIdx) * 240.0
    let spinDeg = baseDeg + localT * 60.0 + easeU * 180.0
    let spinRad = spinDeg * .pi / 180.0

    // Subtle tactile pulse during the spin burst.
    let pulseScale: CGFloat
    if transU <= 0 {
        pulseScale = 1.0
    } else if transU < 0.5 {
        pulseScale = 1.0 - 0.035 * sin(transU * 2 * .pi)
    } else {
        pulseScale = 1.0 + 0.018 * sin((transU - 0.5) * 2 * .pi)
    }

    // Interpolated blade colors.
    let bladeColors: [RGB] = (0..<3).map { i in
        RGB.lerpVibrant(cur.blades[i], nxt.blades[i], easeU)
    }
    let hubTop = RGB.lerpRGB(cur.hubTop, nxt.hubTop, easeU)
    let hubBottom = RGB.lerpRGB(cur.hubBottom, nxt.hubBottom, easeU)

    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    let s = CGFloat(size)
    let center = CGPoint(x: s / 2, y: s / 2)
    let outerR = s * (withShadow ? 0.425 : 0.455) * pulseScale
    let whiteR = outerR * 0.485
    let innerR = outerR * 0.41

    ctx.saveGState()
    ctx.translateBy(x: center.x, y: center.y)

    // Optional soft drop shadow (for APNG with 8-bit alpha).
    if withShadow {
        ctx.saveGState()
        ctx.setShadow(
            offset: CGSize(width: 0, height: -s * 0.016),
            blur: s * 0.045,
            color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.24)
        )
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: -outerR, y: -outerR, width: outerR * 2, height: outerR * 2))
        ctx.restoreGState()
    }

    // Clip to outer circle for the 3 blades.
    ctx.saveGState()
    let outerCircle = CGPath(ellipseIn: CGRect(x: -outerR, y: -outerR, width: outerR * 2, height: outerR * 2), transform: nil)
    ctx.addPath(outerCircle)
    ctx.clip()

    let twoPi3 = CGFloat.pi * 2 / 3
    let phi0 = CGFloat.pi / 2 - spinRad
    let phi1 = phi0 - twoPi3
    let phi2 = phi0 - 2 * twoPi3
    let pad: CGFloat = 0.10 // ~5.7 deg overlap hidden under next blade to guarantee zero anti-aliasing seam

    // Base fill: Blade 0 (top blade, between phi2 and phi0).
    fillBlade(ctx, path: outerCircle, color: bladeColors[0], midAngle: phi0 + twoPi3 / 2 - acos(whiteR / outerR), outerR: outerR)

    // Blade 1 (right blade, between phi0 and phi1, padded past phi1).
    let path1 = makeBladePath(outerR: outerR, whiteR: whiteR, phiLead: phi0, phiTrail: phi1 - pad)
    fillBlade(ctx, path: path1, color: bladeColors[1], midAngle: phi0 - twoPi3 / 2 - acos(whiteR / outerR), outerR: outerR)

    // Blade 2 (left blade, cleanly between phi1 and phi2).
    let path2 = makeBladePath(outerR: outerR, whiteR: whiteR, phiLead: phi1, phiTrail: phi2)
    fillBlade(ctx, path: path2, color: bladeColors[2], midAngle: phi1 - twoPi3 / 2 - acos(whiteR / outerR), outerR: outerR)

    // Subtle origami shadows along all 3 tangent edges.
    drawTangentShadow(ctx, outerR: outerR, whiteR: whiteR, phi: phi0)
    drawTangentShadow(ctx, outerR: outerR, whiteR: whiteR, phi: phi1)
    drawTangentShadow(ctx, outerR: outerR, whiteR: whiteR, phi: phi2)

    // Subtle top specular rim highlight inside outer circle.
    let cs = CGColorSpaceCreateDeviceRGB()
    let rimGrad = CGGradient(
        colorsSpace: cs,
        colors: [CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.14),
                 CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.0)] as CFArray,
        locations: [0.0, 0.55]
    )!
    ctx.drawLinearGradient(rimGrad, start: CGPoint(x: 0, y: outerR), end: CGPoint(x: 0, y: -outerR * 0.2), options: [])
    ctx.restoreGState()

    // Crisp white separator ring.
    ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: -whiteR, y: -whiteR, width: whiteR * 2, height: whiteR * 2))

    // Center hub background (clipped to innerR).
    ctx.saveGState()
    let hubCircle = CGPath(ellipseIn: CGRect(x: -innerR, y: -innerR, width: innerR * 2, height: innerR * 2), transform: nil)
    ctx.addPath(hubCircle)
    ctx.clip()

    let hubGrad = CGGradient(
        colorsSpace: cs,
        colors: [hubTop.cgColor, hubBottom.cgColor] as CFArray,
        locations: [0.0, 1.0]
    )!
    ctx.drawLinearGradient(hubGrad, start: CGPoint(x: 0, y: innerR), end: CGPoint(x: 0, y: -innerR), options: [])

    // Draw center emoji (morph out in first half of transition, spring in during second half).
    let drawEmoji: (String, CGFloat, CGFloat, CGFloat) -> Void = { emoji, scale, angleDeg, alpha in
        guard scale > 0.01 && alpha > 0.01 else { return }
        let img = renderEmojiImage(emoji, canvasPx: 256)
        let aspect = CGFloat(img.width) / CGFloat(img.height)
        let maxDim = innerR * 1.38 * scale
        let drawW = aspect >= 1 ? maxDim : maxDim * aspect
        let drawH = aspect >= 1 ? maxDim / aspect : maxDim

        ctx.saveGState()
        ctx.setAlpha(alpha)
        ctx.rotate(by: angleDeg * .pi / 180.0)
        ctx.draw(img, in: CGRect(x: -drawW / 2, y: -drawH / 2, width: drawW, height: drawH))
        ctx.restoreGState()
    }

    if transU == 0 {
        if let e = cur.emoji {
            drawEmoji(e, 1.0, 0.0, 1.0)
        }
    } else if transU < 0.48 {
        // Outgoing emoji shrinks & twists out.
        let p = transU / 0.48
        let ep = easeInCubic(p)
        if let e = cur.emoji {
            drawEmoji(e, 1.0 - ep * 0.92, -ep * 48.0, 1.0 - ep)
        }
    } else {
        // Incoming emoji springs in with slight overshoot.
        let p = (transU - 0.48) / 0.52
        let sc = easeOutBack(p)
        let rot = (1.0 - easeInOutCubic(p)) * 42.0
        let al = min(1.0, p * 2.4)
        if let e = nxt.emoji {
            drawEmoji(e, sc, rot, al)
        }
    }

    // Subtle glossy sheen on the Chrome Blue core (stage 0).
    let chromeFactor: CGFloat
    if stageIdx == 0 {
        chromeFactor = 1.0 - easeU
    } else if nextIdx == 0 {
        chromeFactor = easeU
    } else {
        chromeFactor = 0.0
    }
    if chromeFactor > 0.01 {
        let sheenGrad = CGGradient(
            colorsSpace: cs,
            colors: [CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.28 * chromeFactor),
                     CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.0)] as CFArray,
            locations: [0.0, 1.0]
        )!
        ctx.drawRadialGradient(
            sheenGrad,
            startCenter: CGPoint(x: -innerR * 0.28, y: innerR * 0.32),
            startRadius: 0,
            endCenter: CGPoint(x: -innerR * 0.15, y: innerR * 0.15),
            endRadius: innerR * 0.95,
            options: []
        )
    }

    ctx.restoreGState() // end hub clip

    // Subtle hair-thin inner rim around hub so white-hub emoji states still read crisply.
    ctx.setStrokeColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.06))
    ctx.setLineWidth(max(1.0, s * 0.005))
    ctx.strokeEllipse(in: CGRect(x: -innerR, y: -innerR, width: innerR * 2, height: innerR * 2))

    ctx.restoreGState()
    return rep.cgImage!
}

// MARK: - Animated SVG Generator

func writeAnimatedSVG(to url: URL) {
    // Exact Chrome geometry in SVG coordinates (+y is DOWN).
    // Center at (0, 0) inside a <g transform="translate(256, 256)">.
    let R: Double = 216.0
    let rw: Double = R * 0.485
    let ri: Double = R * 0.41
    let alpha = acos(rw / R)

    func pt(_ r: Double, _ ang: Double) -> (Double, Double) {
        // In SVG (+y down), clockwise increases angle; top is -pi/2.
        (r * cos(ang), r * sin(ang))
    }

    func fmt(_ v: Double) -> String { String(format: "%.2f", v) }

    func svgBladePath(phiLead: Double, phiTrail: Double) -> String {
        let pL = pt(rw, phiLead)
        let qL = pt(R, phiLead + alpha)
        let qT = pt(R, phiTrail + alpha)
        let pT = pt(rw, phiTrail)
        // Outer arc clockwise in SVG = sweep-flag 1.
        return "M 0 0 L \(fmt(pL.0)) \(fmt(pL.1)) L \(fmt(qL.0)) \(fmt(qL.1)) " +
               "A \(fmt(R)) \(fmt(R)) 0 0 1 \(fmt(qT.0)) \(fmt(qT.1)) " +
               "L \(fmt(pT.0)) \(fmt(pT.1)) Z"
    }

    let twoPi3 = Double.pi * 2.0 / 3.0
    let phi0 = -Double.pi / 2.0 // top
    let phi1 = phi0 + twoPi3    // lower-right
    let phi2 = phi0 + 2.0 * twoPi3 // lower-left
    let pad = 0.08

    let blade1D = svgBladePath(phiLead: phi0, phiTrail: phi1 + pad)
    let blade2D = svgBladePath(phiLead: phi1, phiTrail: phi2)

    // Keyframe stops for 6 stages (total 7.2s).
    let n = stages.count
    let dwellRatio = 0.52

    func bladeKeyframes(bladeIdx: Int) -> String {
        var lines: [String] = []
        for i in 0..<n {
            let pStart = Double(i) / Double(n) * 100.0
            let pDwell = (Double(i) + dwellRatio) / Double(n) * 100.0
            let col = stages[i].blades[bladeIdx].hexString
            lines.append(String(format: "      %.3f%%, %.3f%% { fill: %@; }", pStart, pDwell, col))
        }
        lines.append(String(format: "      100%% { fill: %@; }", stages[0].blades[bladeIdx].hexString))
        return lines.joined(separator: "\n")
    }

    func hubKeyframes() -> String {
        var lines: [String] = []
        for i in 0..<n {
            let pStart = Double(i) / Double(n) * 100.0
            let pDwell = (Double(i) + dwellRatio) / Double(n) * 100.0
            let col = i == 0 ? "#1A73E8" : stages[i].hubBottom.hexString
            lines.append(String(format: "      %.3f%%, %.3f%% { fill: %@; }", pStart, pDwell, col))
        }
        lines.append("      100% { fill: #1A73E8; }")
        return lines.joined(separator: "\n")
    }

    func spinKeyframes() -> String {
        var lines: [String] = []
        for i in 0..<n {
            let pStart = Double(i) / Double(n) * 100.0
            let pDwell = (Double(i) + dwellRatio) / Double(n) * 100.0
            let degStart = Double(i) * 240.0
            let degDwell = degStart + 60.0
            lines.append(String(format: "      %.3f%% { transform: rotate(%.1fdeg) scale(1); animation-timing-function: linear; }", pStart, degStart))
            lines.append(String(format: "      %.3f%% { transform: rotate(%.1fdeg) scale(1); animation-timing-function: cubic-bezier(0.65, 0, 0.35, 1); }", pDwell, degDwell))
        }
        lines.append("      100% { transform: rotate(1440deg) scale(1); }")
        return lines.joined(separator: "\n")
    }

    func emojiKeyframes(stageIdx: Int) -> String {
        // Appears in second half of stage (stageIdx - 1)'s transition, holds through stageIdx dwell, exits in first half of stageIdx transition.
        let prev = (stageIdx - 1 + n) % n
        let pEnter0 = (Double(prev) + dwellRatio + 0.48 * (1 - dwellRatio)) / Double(n) * 100.0
        let pEnter1 = Double(stageIdx) / Double(n) * 100.0
        let pHoldEnd = (Double(stageIdx) + dwellRatio) / Double(n) * 100.0
        let pExitEnd = (Double(stageIdx) + dwellRatio + 0.48 * (1 - dwellRatio)) / Double(n) * 100.0
        return """
              0%, \(String(format: "%.3f", pEnter0))% { opacity: 0; transform: scale(0.15) rotate(-40deg); }
              \(String(format: "%.3f", pEnter1))% { opacity: 1; transform: scale(1) rotate(0deg); }
              \(String(format: "%.3f", pHoldEnd))% { opacity: 1; transform: scale(1) rotate(0deg); }
              \(String(format: "%.3f", pExitEnd))%, 100% { opacity: 0; transform: scale(0.15) rotate(40deg); }
        """
    }

    var emojiStyles = ""
    var emojiElements = ""
    for i in 1..<n {
        guard let em = stages[i].emoji else { continue }
        emojiStyles += """
            .em-\(i) { animation: em-\(i) 7.2s infinite; }
            @keyframes em-\(i) {
        \(emojiKeyframes(stageIdx: i))
            }

        """
        emojiElements += """
              <g class="em-\(i)">
                <text x="0" y="6" text-anchor="middle" dominant-baseline="central" font-size="112" font-family="'Apple Color Emoji', 'Segoe UI Emoji', 'Noto Color Emoji', sans-serif">\(em)</text>
              </g>

        """
    }

    // Tangent divider shadow lines in SVG.
    func dividerLine(_ phi: Double) -> String {
        let p = pt(rw, phi)
        let q = pt(R, phi + alpha)
        return "<line x1=\"\(fmt(p.0))\" y1=\"\(fmt(p.1))\" x2=\"\(fmt(q.0))\" y2=\"\(fmt(q.1))\" stroke=\"rgba(0,0,0,0.12)\" stroke-width=\"3\" stroke-linecap=\"round\"/>"
    }

    let svg = """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512" width="512" height="512" role="img" aria-label="ProfileSlide animated spinning Chrome profile icon">
      <defs>
        <clipPath id="outer-clip">
          <circle cx="0" cy="0" r="\(fmt(R))"/>
        </clipPath>
        <clipPath id="hub-clip">
          <circle cx="0" cy="0" r="\(fmt(ri))"/>
        </clipPath>
        <filter id="drop-shadow" x="-20%" y="-20%" width="140%" height="140%">
          <feDropShadow dx="0" dy="8" stdDeviation="12" flood-color="#000000" flood-opacity="0.22"/>
        </filter>
        <linearGradient id="top-sheen" x1="0" y1="-1" x2="0" y2="1">
          <stop offset="0%" stop-color="#FFFFFF" stop-opacity="0.16"/>
          <stop offset="55%" stop-color="#FFFFFF" stop-opacity="0"/>
        </linearGradient>
      </defs>
      <style>
        .wheel { animation: spin 7.2s infinite; }
        .b0 { animation: col-0 7.2s infinite ease-in-out; }
        .b1 { animation: col-1 7.2s infinite ease-in-out; }
        .b2 { animation: col-2 7.2s infinite ease-in-out; }
        .hub { animation: col-hub 7.2s infinite ease-in-out; }
        @keyframes spin {
    \(spinKeyframes())
        }
        @keyframes col-0 {
    \(bladeKeyframes(bladeIdx: 0))
        }
        @keyframes col-1 {
    \(bladeKeyframes(bladeIdx: 1))
        }
        @keyframes col-2 {
    \(bladeKeyframes(bladeIdx: 2))
        }
        @keyframes col-hub {
    \(hubKeyframes())
        }
    \(emojiStyles)  </style>
      <g transform="translate(256, 256)" filter="url(#drop-shadow)">
        <g class="wheel" clip-path="url(#outer-clip)">
          <circle class="b0" cx="0" cy="0" r="\(fmt(R))"/>
          <path class="b1" d="\(blade1D)"/>
          <path class="b2" d="\(blade2D)"/>
          \(dividerLine(phi0))
          \(dividerLine(phi1))
          \(dividerLine(phi2))
          <circle cx="0" cy="0" r="\(fmt(R))" fill="url(#top-sheen)"/>
        </g>
        <circle cx="0" cy="0" r="\(fmt(rw))" fill="#FFFFFF"/>
        <g clip-path="url(#hub-clip)">
          <circle class="hub" cx="0" cy="0" r="\(fmt(ri))"/>
    \(emojiElements)    </g>
        <circle cx="0" cy="0" r="\(fmt(ri))" fill="none" stroke="rgba(0,0,0,0.06)" stroke-width="2.5"/>
      </g>
    </svg>
    """

    try! svg.write(to: url, atomically: true, encoding: .utf8)
}

// MARK: - Main

let fps = 25 // exact 40ms (4cs) GIF frame delay, exact 7.2s loop across 6 stages
let secondsPerStage = 1.2
let framesPerStage = Int(round(Double(fps) * secondsPerStage)) // 30 frames per stage -> 180 total
let apngSize = 256
let gifSize = 256

let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let outDir = cwd.appendingPathComponent("Resources")
try! FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let tmpApngDir = URL(fileURLWithPath: "/tmp/profileslide-apng-frames")
let tmpGifDir = URL(fileURLWithPath: "/tmp/profileslide-gif-frames")
try? FileManager.default.removeItem(at: tmpApngDir)
try? FileManager.default.removeItem(at: tmpGifDir)
try! FileManager.default.createDirectory(at: tmpApngDir, withIntermediateDirectories: true)
try! FileManager.default.createDirectory(at: tmpGifDir, withIntermediateDirectories: true)

var frameNum = 0
for sIdx in 0..<stages.count {
    for f in 0..<framesPerStage {
        let localT = CGFloat(f) / CGFloat(framesPerStage)
        let apngImg = renderFrame(size: apngSize, stageIdx: sIdx, localT: localT, withShadow: true)
        let apngData = NSBitmapImageRep(cgImage: apngImg).representation(using: .png, properties: [:])!
        try! apngData.write(to: tmpApngDir.appendingPathComponent(String(format: "frame_%04d.png", frameNum)))

        // Render clean-edge (no translucent outer halo) PNG frame for transparent GIF encoding.
        let gifImg = renderFrame(size: gifSize, stageIdx: sIdx, localT: localT, withShadow: false)
        let gifData = NSBitmapImageRep(cgImage: gifImg).representation(using: .png, properties: [:])!
        try! gifData.write(to: tmpGifDir.appendingPathComponent(String(format: "frame_%04d.png", frameNum)))
        frameNum += 1
    }
}

func runProcess(_ path: String, _ args: [String]) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let errPipe = Pipe()
    p.standardInput = FileHandle.nullDevice
    p.standardOutput = FileHandle.nullDevice
    p.standardError = errPipe
    try! p.run()
    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    if p.terminationStatus != 0 {
        let err = String(data: errData, encoding: .utf8) ?? ""
        fatalError("\(path) failed (\(p.terminationStatus)): \(err)")
    }
}

let ffmpeg = "/opt/homebrew/bin/ffmpeg"

// Encode compressed full-alpha APNG via ffmpeg.
let apngURL = outDir.appendingPathComponent("icon-animated.png")
runProcess(ffmpeg, [
    "-nostdin", "-threads", "1", "-filter_threads", "1", "-v", "error", "-y", "-framerate", "\(fps)",
    "-i", tmpApngDir.appendingPathComponent("frame_%04d.png").path,
    "-plays", "0", "-pred", "mixed",
    "-f", "apng", apngURL.path
])
print("wrote \(apngURL.path) (\(frameNum) frames, \(apngSize)x\(apngSize))")

// Encode optimized transparent GIF via ffmpeg with per-frame 256-color palettes
// so each color theme + Apple Color Emoji stays crisp without cross-palette dithering.
let gifURL = outDir.appendingPathComponent("icon-animated.gif")
runProcess(ffmpeg, [
    "-nostdin", "-threads", "1", "-filter_threads", "1", "-v", "error", "-y", "-framerate", "\(fps)",
    "-i", tmpGifDir.appendingPathComponent("frame_%04d.png").path,
    "-lavfi", "split[s0][s1];[s0]palettegen=stats_mode=single:reserve_transparent=on:transparency_color=ffffff[p];[s1][p]paletteuse=new=1:dither=bayer:bayer_scale=3:alpha_threshold=128",
    "-loop", "0",
    gifURL.path
])
print("wrote \(gifURL.path) (\(frameNum) frames, \(gifSize)x\(gifSize))")

let svgURL = outDir.appendingPathComponent("icon-animated.svg")
writeAnimatedSVG(to: svgURL)
print("wrote \(svgURL.path)")
