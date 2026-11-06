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
