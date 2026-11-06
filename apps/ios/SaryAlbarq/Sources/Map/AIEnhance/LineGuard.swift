import Foundation

/// Finds long straight edges (what a track, a road, a fence or a wall looks like from above) in
/// a grey image, so that nothing we draw over the desert ever *adds* one. A navigation map
/// must not show a track that is not there: someone could drive to it.
///
/// Gradient-constrained Hough transform: Sobel edges above an adaptive threshold vote only
/// for lines along their own edge direction (±`spreadDeg`). `score` is the strongest line's
/// votes over the image side, so ≈1 is an edge running straight across the whole image and
/// a short, curved or broken crest stays small. Pure (Foundation only), unit-tested.
enum LineGuard {
    /// Above this the image has a long straight edge (a track crossing a 256 px tile ≈ 0.9+).
    static let lineScore: Float = 0.42
    /// An enhanced tile may not add more straight-line evidence than this over its source.
    static let maxAdded: Float = 0.14

    static let thetaBins = 180
    static let spreadDeg = 10

    /// Strongest straight-edge score of a `w`×`h` grey image (0…1+).
    static func score(_ gray: [Float], width w: Int, height h: Int) -> Float {
        guard w > 8, h > 8, gray.count == w * h else { return 0 }
        /* A light 3×3 blur first: thin, aliased lines then give Sobel a usable direction. */
        var gray = gray
        var tmp = gray
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let i = y * w + x
                tmp[i] = (4 * gray[i] + 2 * (gray[i - 1] + gray[i + 1] + gray[i - w] + gray[i + w])
                          + gray[i - w - 1] + gray[i - w + 1] + gray[i + w - 1] + gray[i + w + 1]) / 16
            }
        }
        gray = tmp
        /* Sobel. */
        var mag = [Float](repeating: 0, count: w * h)
        var ang = [Float](repeating: 0, count: w * h)
        var sum: Float = 0, sum2: Float = 0
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let i = y * w + x
                let a = gray[i - w - 1], b = gray[i - w], c = gray[i - w + 1]
                let d = gray[i - 1], f = gray[i + 1]
                let g = gray[i + w - 1], hh = gray[i + w], k = gray[i + w + 1]
                let gx = (c + 2 * f + k) - (a + 2 * d + g)
                let gy = (g + 2 * hh + k) - (a + 2 * b + c)
                let m = (gx * gx + gy * gy).squareRoot()
                mag[i] = m
                ang[i] = atan2(gy, gx)
                sum += m
                sum2 += m * m
            }
        }
        let n = Float((w - 2) * (h - 2))
        let mean = sum / n
        let sd = max(0, sum2 / n - mean * mean).squareRoot()
        /* Adaptive, with a floor so flat noise (or a blank tile) has no "edges" at all. */
        let threshold = max(mean + 1.5 * sd, 0.08)

        let diag = Int((Float(w * w + h * h)).squareRoot().rounded(.up))
        let rhoBins = 2 * diag + 1
        var acc = [UInt16](repeating: 0, count: thetaBins * rhoBins)
        var cosT = [Float](repeating: 0, count: thetaBins), sinT = [Float](repeating: 0, count: thetaBins)
        for t in 0..<thetaBins {
            let r = Float(t) * .pi / Float(thetaBins)
            cosT[t] = cos(r)
            sinT[t] = sin(r)
        }
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let i = y * w + x
                guard mag[i] > threshold else { continue }
                /* The line's normal is the gradient: θ in 0..<180. */
                var deg = Int((ang[i] * 180 / .pi).rounded())
                deg = ((deg % 180) + 180) % 180
                for dt in -spreadDeg...spreadDeg {
                    let t = ((deg + dt) % thetaBins + thetaBins) % thetaBins
                    let rho = Int((Float(x) * cosT[t] + Float(y) * sinT[t]).rounded()) + diag
                    let j = t * rhoBins + rho
                    if acc[j] < UInt16.max { acc[j] += 1 }
                }
            }
        }
        /* A line's edge pixels straddle two ρ bins: count the best pair of neighbours. */
        var best = 0
        for t in 0..<thetaBins {
            let row = t * rhoBins
            for r in 0..<(rhoBins - 1) {
                let v = Int(acc[row + r]) + Int(acc[row + r + 1])
                if v > best { best = v }
            }
        }
        return Float(best) / Float(max(w, h))
    }

    /// Did `enhanced` gain a straight line that `source` (the same ground) does not have?
    static func addsLine(enhanced: Float, source: Float) -> Bool {
        enhanced >= lineScore && enhanced - source > maxAdded
    }

    /// Box-downsampled grey (Rec. 709 luma, 0…1) of a premultiplied-or-opaque RGBA8 buffer.
    static func gray(rgba: [UInt8], width w: Int, height h: Int, to side: Int) -> [Float] {
        let f = max(1, w / side)
        let ow = w / f, oh = h / f
        var out = [Float](repeating: 0, count: ow * oh)
        let k = 1 / (255 * Float(f * f))
        for oy in 0..<oh {
            for ox in 0..<ow {
                var s: Float = 0
                for dy in 0..<f {
                    var o = ((oy * f + dy) * w + ox * f) * 4
                    for _ in 0..<f {
                        s += 0.2126 * Float(rgba[o]) + 0.7152 * Float(rgba[o + 1]) + 0.0722 * Float(rgba[o + 2])
                        o += 4
                    }
                }
                out[oy * ow + ox] = s * k
            }
        }
        return out
    }
}

/// Finds a *new* dark, narrow, elongated object in an enhanced tile: what a model "paints" from
/// a smudge — a pole, a post, a stake, a short wall (the round-3 single-tile test showed one).
/// Round shrubs and dark spots are fine; a long, sharp, dark sliver the photo only had as a
/// faint blur (or not at all) is not. Pure, unit-tested.
enum ObjectGuard {
    /// Darker than its surroundings by this much (0…1 grey) to count.
    static let minDepth: Float = 0.07
    static let minPixels = 8
    /// Long axis over short axis.
    static let minElongation: Float = 3.5
    /// Long axis, px of the 256 px grey image.
    static let minLength: Float = 10
    /// The photo had less than this share of the object's darkness: the model made it.
    static let newShare: Float = 0.45

    /// Local darkness (box mean radius 6 minus value, ≥ 0).
    static func depth(_ g: [Float], _ w: Int, _ h: Int, radius r: Int = 6) -> [Float] {
        var integ = [Double](repeating: 0, count: (w + 1) * (h + 1))
        for y in 0..<h {
            var row = 0.0
            for x in 0..<w {
                row += Double(g[y * w + x])
                integ[(y + 1) * (w + 1) + x + 1] = integ[y * (w + 1) + x + 1] + row
            }
        }
        var d = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            let y0 = max(0, y - r), y1 = min(h, y + r + 1)
            for x in 0..<w {
                let x0 = max(0, x - r), x1 = min(w, x + r + 1)
                let s = integ[y1 * (w + 1) + x1] - integ[y0 * (w + 1) + x1] - integ[y1 * (w + 1) + x0] + integ[y0 * (w + 1) + x0]
                let mean = Float(s / Double((x1 - x0) * (y1 - y0)))
                d[y * w + x] = max(0, mean - g[y * w + x])
            }
        }
        return d
    }

    /// Does `enhanced` (grey, w×h) have a dark elongated object that `source` (the same ground,
    /// plainly up-sampled) does not?
    static func addsObject(enhanced: [Float], source: [Float], width w: Int, height h: Int) -> Bool {
        guard enhanced.count == w * h, source.count == w * h else { return false }
        let de = depth(enhanced, w, h), ds = depth(source, w, h)
        var seen = [Bool](repeating: false, count: w * h)
        var stack: [Int] = []
        for start in 0..<(w * h) where !seen[start] && de[start] > minDepth {
            seen[start] = true
            stack.append(start)
            var px: [Int] = []
            while let i = stack.popLast() {
                px.append(i)
                let x = i % w, y = i / w
                for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] where nx >= 0 && ny >= 0 && nx < w && ny < h {
                    let j = ny * w + nx
                    if !seen[j] && de[j] > minDepth { seen[j] = true; stack.append(j) }
                }
            }
            guard px.count >= minPixels, px.count < w * h / 8 else { continue }
            /* Shape: second moments → the long and short axes. */
            var mx: Float = 0, my: Float = 0
            for i in px { mx += Float(i % w); my += Float(i / w) }
            let n = Float(px.count)
            mx /= n; my /= n
            var sxx: Float = 0, syy: Float = 0, sxy: Float = 0
            for i in px {
                let dx = Float(i % w) - mx, dy = Float(i / w) - my
                sxx += dx * dx; syy += dy * dy; sxy += dx * dy
            }
            sxx /= n; syy /= n; sxy /= n
            let tr = sxx + syy, det = sxx * syy - sxy * sxy
            let disc = max(0, tr * tr / 4 - det).squareRoot()
            let l1 = tr / 2 + disc, l2 = max(0.25, tr / 2 - disc)
            let elongation = (l1 / l2).squareRoot()
            let length = 4 * l1.squareRoot()
            guard elongation >= minElongation, length >= minLength else { continue }
            var e: Float = 0, s: Float = 0
            for i in px { e += de[i]; s += ds[i] }
            if s < newShare * e { return true }
        }
        return false
    }
}
