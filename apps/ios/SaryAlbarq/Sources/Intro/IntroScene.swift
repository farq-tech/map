import SwiftUI

/// The cinematic intro's night desert, drawn in code (no video, no image assets).
///
/// Everything is laid out in one fixed design space (`size`, the largest iPhone in
/// points) centred on the screen, exactly like the static launch image
/// (`IntroLaunch`, rendered from this same code by `scripts/render-intro-launch.swift`),
/// so the hand-off from the launch screen to the first animated frame is pixel-exact.
/// Pure drawing: compiles for iOS and for the macOS renderer script alike.
enum IntroScene {
    /// Design space in points (iPhone Pro Max); smaller phones crop the edges evenly.
    static let size = CGSize(width: 440, height: 956)
    static let horizonY: CGFloat = 676
    /// Where the logo settles (the arrow's centre) and the name's baseline area.
    static let logoRest = CGPoint(x: 220, y: 432)
    static let logoStart = CGPoint(x: 220, y: 700)

    // MARK: timeline (seconds from the start of the animation)

    enum T {
        static let starsIn: Double = 0.15
        static let milkyIn: Double = 0.35
        static let shootStart: Double = 1.0, shootEnd: Double = 1.7
        static let logoRise: Double = 1.05, logoRest: Double = 2.3
        /// The "star lights" moment: flare peak, matched to the score's bell + boom.
        static let reveal: Double = 2.3
        static let nameIn: Double = 2.45
        static let taglineIn: Double = 2.85
        static let fadeOut: Double = 3.75
        static let total: Double = 4.35
    }

    // MARK: palette

    static func c(_ rgb: UInt32, _ a: Double = 1) -> Color {
        Color(.sRGB, red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255, opacity: a)
    }

    static let skyTop: UInt32 = 0x04060E
    static let skyStops: [(UInt32, CGFloat)] = [(0x04060E, 0), (0x070B1A, 0.30), (0x0C1228, 0.52), (0x1A1830, 0.64), (0x33242C, 0.705), (0x3E2A26, 0.74)]
    static let gold: UInt32 = 0xF2C36B
    static let ivory: UInt32 = 0xF4EFE6

    // MARK: easing

    static func clamp(_ x: Double) -> Double { min(1, max(0, x)) }
    static func ramp(_ t: Double, _ a: Double, _ b: Double) -> Double { clamp((t - a) / (b - a)) }
    static func smooth(_ x: Double) -> Double { let v = clamp(x); return v * v * (3 - 2 * v) }
    static func easeOutCubic(_ x: Double) -> Double { 1 - pow(1 - clamp(x), 3) }

    // MARK: static sky (frame 0 == launch image)

    /// Sky gradient, the glow of a moon just under the dunes, and the faint Milky Way haze.
    /// `milky` 0…1 (0 on the launch frame).
    static func drawSky(_ ctx: GraphicsContext, milky: Double) {
        let s = size
        let stops = skyStops.map { Gradient.Stop(color: c($0.0), location: $0.1) }
        ctx.fill(Path(CGRect(origin: .zero, size: s)), with: .linearGradient(Gradient(stops: stops), startPoint: .zero, endPoint: CGPoint(x: 0, y: s.height)))
        // Moon / sky glow on the horizon, right of centre (a moon just under the dunes).
        let g = CGPoint(x: s.width * 0.66, y: horizonY + 6)
        softEllipse(ctx, g, rx: 400, ry: 270, [c(0xE7A35C, 0.30), c(0xB0704A, 0.11), c(0x6A4A5A, 0.0)])
        softEllipse(ctx, g, rx: 170, ry: 70, [c(0xFFD9A0, 0.30), c(0xFFD9A0, 0.08), c(0xFFD9A0, 0)])
        guard milky > 0.001 else { return }
        // Milky Way haze: soft blobs along a diagonal band (lower-left → upper-right).
        for b in milkyBlobs {
            softEllipse(ctx, b.p, rx: b.r * 1.5, ry: b.r * 0.7, [c(b.warm ? 0xFFE6C8 : 0xC9D4FF, b.a * milky), c(0xC9D4FF, b.a * milky * 0.35), c(0xC9D4FF, 0)],
                        angle: bandAngle)
        }
    }

    /// A radial glow stretched into an ellipse (fades to nothing at its edge, never clipped).
    static func softEllipse(_ ctx: GraphicsContext, _ p: CGPoint, rx: CGFloat, ry: CGFloat, _ colors: [Color], angle: Double = 0) {
        var g = ctx
        g.translateBy(x: p.x, y: p.y)
        if angle != 0 { g.rotate(by: .radians(angle)) }
        g.scaleBy(x: 1, y: ry / rx)
        g.fill(Path(ellipseIn: CGRect(x: -rx, y: -rx, width: rx * 2, height: rx * 2)),
               with: .radialGradient(Gradient(colors: colors), center: .zero, startRadius: 0, endRadius: rx))
    }

    // MARK: dunes (parallax layers)

    struct Dune { let points: [CGPoint]; let fill: UInt32; let rim: Double; let drift: CGFloat }

    static let dunes: [Dune] = [
        Dune(points: [CGPoint(x: -60, y: 676), CGPoint(x: 40, y: 650), CGPoint(x: 150, y: 668), CGPoint(x: 268, y: 628), CGPoint(x: 380, y: 660), CGPoint(x: 500, y: 640)],
             fill: 0x1C1524, rim: 0.20, drift: -5),
        Dune(points: [CGPoint(x: -60, y: 730), CGPoint(x: 70, y: 694), CGPoint(x: 200, y: 720), CGPoint(x: 330, y: 682), CGPoint(x: 500, y: 716)],
             fill: 0x120D17, rim: 0.28, drift: -10),
        Dune(points: [CGPoint(x: -60, y: 812), CGPoint(x: 60, y: 772), CGPoint(x: 160, y: 760), CGPoint(x: 300, y: 800), CGPoint(x: 420, y: 770), CGPoint(x: 500, y: 786)],
             fill: 0x09070C, rim: 0.34, drift: -18),
    ]

    /// Parallax progress 0…1 over the whole intro (a slow camera drift).
    static func drift(_ t: Double) -> Double { smooth(t / T.total) }

    static func dunePath(_ d: Dune, dx: CGFloat) -> (fill: Path, ridge: Path) {
        let pts = d.points.map { CGPoint(x: $0.x + dx, y: $0.y) }
        var ridge = Path()
        ridge.move(to: pts[0])
        for i in 1..<pts.count {
            let a = pts[i - 1], b = pts[i]
            let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            if i == 1 { ridge.addLine(to: mid) } else { ridge.addQuadCurve(to: mid, control: a) }
            if i == pts.count - 1 { ridge.addLine(to: b) }
        }
        var fill = ridge
        fill.addLine(to: CGPoint(x: pts.last!.x, y: size.height + 10))
        fill.addLine(to: CGPoint(x: pts[0].x, y: size.height + 10))
        fill.closeSubpath()
        return (fill, ridge)
    }

    static func drawDune(_ ctx: GraphicsContext, _ i: Int, t: Double) {
        let d = dunes[i]
        let p = dunePath(d, dx: d.drift * CGFloat(drift(t)))
        ctx.fill(p.fill, with: .color(c(d.fill)))
        // Moonlight catching the ridge, brightest towards the glow.
        ctx.stroke(p.ridge, with: .linearGradient(Gradient(colors: [c(0xE7A35C, d.rim * 0.25), c(0xE7A35C, d.rim), c(0xE7A35C, d.rim * 0.35)]),
                                                  startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: size.width, y: 0)),
                   lineWidth: 1.1)
        if i == dunes.count - 1 {
            // Faint wind ripples in the near sand.
            let dx = d.drift * CGFloat(drift(t))
            for k in 0..<5 {
                let y0 = CGFloat(826 + k * 22), w0 = CGFloat(120 + (k * 37) % 90), x0 = CGFloat((k * 97) % 300) - 10 + dx * 1.2
                var r = Path()
                r.move(to: CGPoint(x: x0, y: y0))
                r.addQuadCurve(to: CGPoint(x: x0 + w0, y: y0 + 4), control: CGPoint(x: x0 + w0 * 0.5, y: y0 - 7))
                ctx.stroke(r, with: .color(c(0xE7A35C, 0.07 - Double(k) * 0.008)), lineWidth: 0.8)
            }
        }
    }

    // MARK: stars

    struct Star { let p: CGPoint; let r: CGFloat; let a: Double; let tw: Double; let ph: Double; let delay: Double; let warm: Bool }
    struct Blob { let p: CGPoint; let r: CGFloat; let a: Double; let warm: Bool }

    /// Deterministic (same sky every launch): a small LCG.
    struct Rand {
        var s: UInt64
        mutating func next() -> Double { s = s &* 6364136223846793005 &+ 1442695040888963407; return Double(s >> 11) / Double(1 << 53) }
        mutating func gauss() -> Double { let u = max(next(), 1e-9), v = next(); return sqrt(-2 * log(u)) * cos(2 * .pi * v) }
    }

    /// The Milky Way's axis: a line from lower-left to upper-right of the sky.
    static let bandA = CGPoint(x: -40, y: 560), bandB = CGPoint(x: 480, y: 40)
    static let bandAngle = atan2(Double(bandB.y - bandA.y), Double(bandB.x - bandA.x))

    static let stars: [Star] = {
        var r = Rand(s: 0x5A5A_B1A2)
        var out: [Star] = []
        // Field stars.
        while out.count < 230 {
            let p = CGPoint(x: r.next() * size.width, y: pow(r.next(), 1.25) * (horizonY - 40))
            let bright = r.next()
            let rad = bright > 0.96 ? 1.5 + r.next() * 0.7 : 0.45 + pow(r.next(), 2) * 0.9
            // Fewer, dimmer stars low in the sky (haze near the horizon).
            let alt = 1 - Double(p.y / horizonY) * 0.55
            out.append(Star(p: p, r: rad, a: (0.35 + 0.65 * r.next()) * alt, tw: 1.2 + r.next() * 2.8, ph: r.next() * 6.28,
                            delay: r.next() * 1.1, warm: r.next() < 0.18))
        }
        // Dense, tiny stars along the band.
        let dx = bandB.x - bandA.x, dy = bandB.y - bandA.y, len = sqrt(dx * dx + dy * dy)
        let nx = -dy / len, ny = dx / len
        for _ in 0..<300 {
            let u = r.next(), off = r.gauss() * 34
            let p = CGPoint(x: bandA.x + dx * u + nx * off, y: bandA.y + dy * u + ny * off)
            guard p.x > 0, p.x < size.width, p.y > 0, p.y < horizonY - 30 else { continue }
            out.append(Star(p: p, r: 0.3 + r.next() * 0.45, a: 0.25 + r.next() * 0.45, tw: 2 + r.next() * 3, ph: r.next() * 6.28,
                            delay: 0.3 + r.next() * 1.2, warm: false))
        }
        return out
    }()

    static let milkyBlobs: [Blob] = {
        var r = Rand(s: 0xD0_7E5)
        let dx = bandB.x - bandA.x, dy = bandB.y - bandA.y, len = sqrt(dx * dx + dy * dy)
        let nx = -dy / len, ny = dx / len
        return (0..<26).map { i in
            let u = (Double(i) + r.next() * 0.8) / 26, off = r.gauss() * 16
            return Blob(p: CGPoint(x: bandA.x + dx * u + nx * off, y: bandA.y + dy * u + ny * off), r: 55 + r.next() * 45,
                        a: 0.035 + r.next() * 0.035, warm: r.next() < 0.3)
        }
    }()

    /// `reduceMotion`: no twinkle (constant brightness), stars simply present.
    static func drawStars(_ ctx: GraphicsContext, t: Double, reduceMotion: Bool) {
        for s in stars {
            let fade = reduceMotion ? 1 : smooth(ramp(t, T.starsIn + s.delay, T.starsIn + s.delay + 0.7))
            guard fade > 0.002 else { continue }
            let tw = reduceMotion ? 0.85 : 0.72 + 0.28 * sin(t * s.tw + s.ph)
            let a = s.a * fade * tw
            let col = c(s.warm ? 0xFFE3BE : 0xEEF2FF, a)
            ctx.fill(Path(ellipseIn: CGRect(x: s.p.x - s.r, y: s.p.y - s.r, width: s.r * 2, height: s.r * 2)), with: .color(col))
            if s.r > 1.4 {
                // Bright stars: a soft halo and a faint cross glint.
                let h = s.r * 5
                ctx.fill(Path(ellipseIn: CGRect(x: s.p.x - h, y: s.p.y - h, width: h * 2, height: h * 2)),
                         with: .radialGradient(Gradient(colors: [c(0xDDE6FF, a * 0.35), c(0xDDE6FF, 0)]), center: s.p, startRadius: 0, endRadius: h))
                var glint = Path()
                glint.move(to: CGPoint(x: s.p.x - h * 1.3, y: s.p.y)); glint.addLine(to: CGPoint(x: s.p.x + h * 1.3, y: s.p.y))
                glint.move(to: CGPoint(x: s.p.x, y: s.p.y - h * 1.3)); glint.addLine(to: CGPoint(x: s.p.x, y: s.p.y + h * 1.3))
                ctx.stroke(glint, with: .color(c(0xEEF2FF, a * 0.35)), lineWidth: 0.5)
            }
        }
    }

    // MARK: shooting star

    static func drawShootingStar(_ ctx: GraphicsContext, t: Double) {
        let u = ramp(t, T.shootStart, T.shootEnd)
        guard u > 0, u < 1 else { return }
        let a = CGPoint(x: 396, y: 92), b = CGPoint(x: 150, y: 236)
        let e = easeOutCubic(u)
        let head = CGPoint(x: a.x + (b.x - a.x) * e, y: a.y + (b.y - a.y) * e)
        let dirx = (b.x - a.x), diry = (b.y - a.y), len = sqrt(dirx * dirx + diry * diry)
        let tailLen = 95 * sin(.pi * u)
        let tail = CGPoint(x: head.x - dirx / len * tailLen, y: head.y - diry / len * tailLen)
        let alpha = sin(.pi * u)
        var p = Path(); p.move(to: tail); p.addLine(to: head)
        ctx.stroke(p, with: .linearGradient(Gradient(colors: [c(0xFFFFFF, 0), c(0xFFF4DC, 0.85 * alpha)]), startPoint: tail, endPoint: head),
                   style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
        ctx.fill(Path(ellipseIn: CGRect(x: head.x - 6, y: head.y - 6, width: 12, height: 12)),
                 with: .radialGradient(Gradient(colors: [c(0xFFF6E2, alpha), c(0xFFF6E2, 0)]), center: head, startRadius: 0, endRadius: 6))
    }

    // MARK: logo (the app's arrow mark, rising like a star)

    /// Logo centre and its light (0…1) and flare (0…1, peaks at the reveal) at time `t`.
    static func logoState(_ t: Double, reduceMotion: Bool) -> (center: CGPoint, light: Double, flare: Double, opacity: Double) {
        if reduceMotion { return (logoRest, 1, 0.35, 1) }
        let u = easeOutCubic(ramp(t, T.logoRise, T.logoRest))
        let y = logoStart.y + (logoRest.y - logoStart.y) * u
        let light = smooth(ramp(t, T.logoRise, T.reveal))
        let dt = t - T.reveal
        let flare = dt < 0 ? pow(light, 3) * 0.55 : 0.35 + 0.65 * exp(-dt / 0.45)
        return (CGPoint(x: logoRest.x, y: y), light, flare, smooth(ramp(t, T.logoRise, T.logoRise + 0.35)))
    }

    static func arrowPath(center c0: CGPoint, r: CGFloat) -> Path {
        // Same proportions as `SaryMarkDrawing`'s arrow (the app icon's heading arrow).
        var p = Path()
        p.move(to: CGPoint(x: c0.x - r * 0.95, y: c0.y + r * 0.62))
        p.addLine(to: CGPoint(x: c0.x, y: c0.y - r * 0.98))
        p.addLine(to: CGPoint(x: c0.x + r * 0.95, y: c0.y + r * 0.62))
        p.addLine(to: CGPoint(x: c0.x, y: c0.y + r * 0.16))
        p.closeSubpath()
        return p
    }

    static func drawLogo(_ ctx: GraphicsContext, t: Double, reduceMotion: Bool) {
        let s = logoState(t, reduceMotion: reduceMotion)
        guard s.opacity > 0.001 else { return }
        let c0 = s.center
        // Golden glow.
        let gr: CGFloat = 70 + 70 * CGFloat(s.light)
        ctx.fill(Path(ellipseIn: CGRect(x: c0.x - gr, y: c0.y - gr, width: gr * 2, height: gr * 2)),
                 with: .radialGradient(Gradient(colors: [c(gold, 0.55 * s.light * s.opacity), c(gold, 0.16 * s.light * s.opacity), c(gold, 0)]),
                                       center: c0, startRadius: 0, endRadius: gr))
        // Star flare: long horizontal + shorter vertical rays.
        if s.flare > 0.01 {
            let f = s.flare * s.opacity
            for (w, h, a) in [(CGFloat(190), CGFloat(1.6), 0.75), (CGFloat(60), CGFloat(3.2), 0.5)] as [(CGFloat, CGFloat, Double)] {
                let rw = w * CGFloat(0.5 + 0.5 * f)
                ctx.fill(Path(ellipseIn: CGRect(x: c0.x - rw, y: c0.y - h / 2, width: rw * 2, height: h)),
                         with: .linearGradient(Gradient(colors: [c(0xFFF1D0, 0), c(0xFFF1D0, a * f), c(0xFFF1D0, 0)]),
                                               startPoint: CGPoint(x: c0.x - rw, y: c0.y), endPoint: CGPoint(x: c0.x + rw, y: c0.y)))
                ctx.fill(Path(ellipseIn: CGRect(x: c0.x - h / 2, y: c0.y - rw * 0.55, width: h, height: rw * 1.1)),
                         with: .linearGradient(Gradient(colors: [c(0xFFF1D0, 0), c(0xFFF1D0, a * f * 0.8), c(0xFFF1D0, 0)]),
                                               startPoint: CGPoint(x: c0.x, y: c0.y - rw * 0.55), endPoint: CGPoint(x: c0.x, y: c0.y + rw * 0.55)))
            }
        }
        // The arrow: ivory-white with a warm inner shade, a soft gold halo around its edge.
        let r: CGFloat = 30
        let arrow = arrowPath(center: CGPoint(x: c0.x, y: c0.y + 2), r: r)
        var halo = ctx
        halo.addFilter(.shadow(color: c(gold, 0.9 * s.light * s.opacity), radius: 10))
        halo.fill(arrow, with: .linearGradient(Gradient(colors: [c(0xFFFFFF, s.opacity), c(ivory, s.opacity), c(0xF3D9A6, s.opacity)]),
                                               startPoint: CGPoint(x: c0.x, y: c0.y - r), endPoint: CGPoint(x: c0.x, y: c0.y + r * 0.6)))
    }

    // MARK: whole frame

    /// One frame of the intro in design space. `t` = seconds since the animation started.
    static func draw(_ ctx: GraphicsContext, t: Double, reduceMotion: Bool) {
        let milky = reduceMotion ? 1 : smooth(ramp(t, T.milkyIn, T.milkyIn + 1.6))
        drawSky(ctx, milky: milky)
        drawStars(ctx, t: t, reduceMotion: reduceMotion)
        if !reduceMotion { drawShootingStar(ctx, t: t) }
        drawDune(ctx, 0, t: reduceMotion ? 0 : t)
        // The logo rises from behind the middle dune.
        drawLogo(ctx, t: t, reduceMotion: reduceMotion)
        drawDune(ctx, 1, t: reduceMotion ? 0 : t)
        drawDune(ctx, 2, t: reduceMotion ? 0 : t)
    }

    /// The launch screen's frame: what `draw(t: 0)` shows (sky, glow, dunes; no stars yet).
    static func drawLaunchFrame(_ ctx: GraphicsContext) {
        drawSky(ctx, milky: 0)
        for i in dunes.indices { drawDune(ctx, i, t: 0) }
    }
}
