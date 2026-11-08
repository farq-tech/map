import Foundation

/// «تفاصيل الرمال»: a "detail map" for the open desert, the classic terrain-rendering technique.
/// Up close the satellite mosaic goes soft (z16+ is up-sampled over most of the Kingdom), so a
/// faint, high-frequency *natural* micro-relief is laid over it: wind ripples, the soft
/// undulation of a sand sheet and gravel grain. It is drawn as a translucent light / shade
/// overlay (never an opaque colour), lit from the real sun (`SunPosition`, the same light as the
/// DEM hillshade), so it reads as relief *of* the photo and keeps the `SandGrade` orange.
///
/// What it never does, by construction:
/// - no shapes, objects, paths, tracks or edges: only band-limited noise and short, sinuous,
///   broken ripple crests (`LineGuard` checks that in the unit tests);
/// - no geometry: the satellite photo and the DEM hillshade under it are untouched, the
///   overlay moves nothing and averages to ~0 brightness change;
/// - no network and no AI: pure functions of the tile's ground coordinates (works offline,
///   deterministic, seamless across tiles and zooms). So it carries no «مُحسّنة» badge,
///   like `SandGrade`.
///
/// Region-aware: zero over a city (`UrbanAreas`, per pixel, smooth at the edge) and faded in
/// with the zoom (none at z14, full from z17), where the imagery itself stops resolving sand.
/// Pure and unit-tested (`SandDetailTests`); the map side is `SandDetailLayer`.
enum SandDetail {
    static let tileSize = 512
    /// The custom source's zoom range (nothing is drawn shallower).
    static let minZoom = 14
    static let maxZoom = 22

    /// Strongest light / shade the overlay ever adds (alpha of the warm white / burnt umber).
    static let maxAlpha: Float = 0.24

    /// Under full SR the detail drops to a quarter (texture is the model's; ripples would double it).
    static let srDim: Float = 0.25
    static func strength(underSR: Bool) -> Float { underSR ? srDim : 1 }

    /// The layer's opacity by map zoom: none at z14.2, full from z17 (×`scale`, e.g. driving).
    static func opacityExpression(scale: Double) -> [Any] {
        ["interpolate", ["linear"], ["zoom"], 14.2, 0.0, 15.5, 0.45 * scale, 17, 1 * scale]
    }

    /// How the micro-relief is lit. Quantised so the tiles are re-made at most every ~20° of sun.
    struct Light: Equatable {
        /// Towards the light, degrees clockwise from north (map-anchored, like the hillshade).
        var azimuthDeg: Double
        /// 0…1: a low sun throws long, strong relief; noon a faint one; night a faint, neutral one.
        var strength: Double
        var night: Bool
        /// «صور عالية الوضوح» runs full SR («قوي») on this map: the model draws the real sand
        /// texture, so the procedural one is kept very faint (`srDim`).
        var underSR = false

        static let step = 20.0

        static func from(_ sun: SunPosition?, night forcedNight: Bool = false) -> Light {
            guard let sun, !forcedNight, sun.altitudeDeg > -6 else {
                return Light(azimuthDeg: HillshadeLight.nightDirection, strength: 0.45, night: true)
            }
            let low = 1 - Smooth.step(0, 70, sun.altitudeDeg)
            let s = ((0.62 + 0.38 * low) * 10).rounded() / 10
            var az = (sun.azimuthDeg / step).rounded() * step
            if az >= 360 { az -= 360 }
            return Light(azimuthDeg: az, strength: s, night: false)
        }
    }

    // MARK: - wind

    /// Where the prevailing wind comes *from* (degrees clockwise from north), by latitude: the
    /// north-westerlies over the Nafud, the Shamal turning through north over the Dahna and
    /// north-north-east over the Empty Quarter. Ripple crests run across it. A smooth
    /// approximation of the regional regime: it only orients a texture.
    static func windFrom(lat: Double, lng: Double) -> Double {
        let north = 300.0, central = 345.0, south = 380.0
        let t1 = Smooth.step(24.5, 27.5, lat)
        let t2 = Smooth.step(20.5, 23.5, lat)
        let deg = Smooth.lerp(Smooth.lerp(south, central, t2), north, t1)
        return deg.truncatingRemainder(dividingBy: 360)
    }

    // MARK: - tiles

    /// One detail tile: premultiplied RGBA8, `size`×`size`, row 0 at the north edge.
    struct Tile {
        var size: Int
        var rgba: [UInt8]
        /// Signed brightness change per pixel (−1…1 × alpha), for the tests and `LineGuard`.
        var delta: [Float]
    }

    /// Ground metres per degree-free unit: Web Mercator scaled by one fixed cosine (25° N, the
    /// Kingdom's middle), so ground coordinates are continuous across every tile (a per-tile
    /// cosine would tear the texture at tile edges). The scale error (≤ 12 %) is only the
    /// texture's apparent size.
    static let refCos = cos(25.0 * .pi / 180)
    static let earth = 40_075_016.686

    static func metresPerPixel(z: Int, size: Int = tileSize) -> Double {
        earth * refCos / (Double(size) * pow(2, Double(z)))
    }

    /// The tile, or nil when nothing would be drawn (too far out, or wholly in a city).
    static func render(z: Int, x: Int, y: Int, light: Light, size: Int = tileSize) -> Tile? {
        guard z >= minZoom, z <= 30 else { return nil }
        let n = pow(2.0, Double(z))
        func lat(_ py: Double) -> Double { atan(sinh(.pi * (1 - 2 * py / n))) * 180 / .pi }
        func lng(_ px: Double) -> Double { px / n * 360 - 180 }
        let fx = Double(x), fy = Double(y)
        /* Open desert weight at the four corners (1 − city), bilinear inside: smooth at a city's edge. */
        let w00 = 1 - UrbanAreas.weight(lat: lat(fy), lng: lng(fx))
        let w10 = 1 - UrbanAreas.weight(lat: lat(fy), lng: lng(fx + 1))
        let w01 = 1 - UrbanAreas.weight(lat: lat(fy + 1), lng: lng(fx))
        let w11 = 1 - UrbanAreas.weight(lat: lat(fy + 1), lng: lng(fx + 1))
        guard max(w00, w10, w01, w11) > 0.001 else { return nil }

        let c = (lat: lat(fy + 0.5), lng: lng(fx + 0.5))
        let wind = windFrom(lat: c.lat, lng: c.lng) * .pi / 180
        /* Ripples migrate downwind: their crest normal is the wind's direction, in tile space (x east, y south). */
        let wx = -sin(wind), wy = cos(wind)
        let mpp = metresPerPixel(z: z, size: size)
        let worldPx = earth * refCos / n           // metres across this tile
        let u0 = fx * worldPx, v0 = fy * worldPx
        let field = Field(mpp: mpp, wx: wx, wy: wy)

        /* Heights with a 1 px border (the shading's neighbours), in metres. */
        let s2 = size + 2
        var h = [Float](repeating: 0, count: s2 * s2)
        var g = [Float](repeating: 0, count: size * size)
        h.withUnsafeMutableBufferPointer { hp in
            g.withUnsafeMutableBufferPointer { gp in
                let hb = hp.baseAddress!, gb = gp.baseAddress!
                DispatchQueue.concurrentPerform(iterations: s2) { row in
                    let v = v0 + (Double(row) - 0.5) * mpp
                    for col in 0..<s2 {
                        let u = u0 + (Double(col) - 0.5) * mpp
                        let (hh, gg) = field.sample(u, v)
                        hb[row * s2 + col] = hh
                        if row > 0, row <= size, col > 0, col <= size { gb[(row - 1) * size + col - 1] = gg }
                    }
                }
            }
        }

        /* Lambert-style relief from the height gradient, towards the light. */
        let az = light.azimuthDeg * .pi / 180
        let lx = Float(sin(az)), ly = Float(-cos(az))
        /* A slope of ~0.04 (a real ripple's stoss side) gives a full-strength shade. */
        let gain = Float(1 / (0.04 * 2 * mpp))
        let strength = Float(light.strength)
        var rgba = [UInt8](repeating: 0, count: size * size * 4)
        var delta = [Float](repeating: 0, count: size * size)
        let hiR: Float = light.night ? 206 : 255, hiG: Float = light.night ? 204 : 242, hiB: Float = light.night ? 214 : 216
        let loR: Float = light.night ? 14 : 66, loG: Float = light.night ? 12 : 30, loB: Float = light.night ? 18 : 10
        let fs = Float(size)
        let maxAlpha = Self.maxAlpha * Self.strength(underSR: light.underSR)
        h.withUnsafeBufferPointer { hp in
            g.withUnsafeBufferPointer { gp in
                rgba.withUnsafeMutableBufferPointer { rp in
                    delta.withUnsafeMutableBufferPointer { dp in
                        let hb = hp.baseAddress!, gb = gp.baseAddress!, rb = rp.baseAddress!, db = dp.baseAddress!
                        DispatchQueue.concurrentPerform(iterations: size) { row in
                            let ty = (Float(row) + 0.5) / fs
                            let wl = Float(w00) + (Float(w01) - Float(w00)) * ty
                            let wr = Float(w10) + (Float(w11) - Float(w10)) * ty
                            for col in 0..<size {
                                let tx = (Float(col) + 0.5) / fs
                                let open = wl + (wr - wl) * tx
                                let i = (row + 1) * s2 + col + 1
                                let dx = (hb[i + 1] - hb[i - 1]) * gain
                                let dy = (hb[i + s2] - hb[i - s2]) * gain
                                var d = -(dx * lx + dy * ly) * strength + gb[row * size + col]
                                d = max(-1, min(1, d)) * open
                                let a = abs(d) * maxAlpha
                                let o = (row * size + col) * 4
                                db[row * size + col] = d * maxAlpha
                                if a < 0.002 { continue }
                                let (r, gg, b) = d > 0 ? (hiR, hiG, hiB) : (loR, loG, loB)
                                rb[o] = UInt8(min(255, r * a + 0.5))
                                rb[o + 1] = UInt8(min(255, gg * a + 0.5))
                                rb[o + 2] = UInt8(min(255, b * a + 0.5))
                                rb[o + 3] = UInt8(min(255, a * 255 + 0.5))
                            }
                        }
                    }
                }
            }
        }
        return Tile(size: size, rgba: rgba, delta: delta)
    }

    // MARK: - the natural micro-relief

    /// Heights (metres) and albedo grain at ground coordinates. Every frequency fades out before
    /// it gets under ~2 px, so nothing aliases into moiré (which could read as lines).
    struct Field {
        var mpp: Double
        var wx: Double
        var wy: Double

        /// Wind ripples (granule / mega-ripples visible from z16–z17 up).
        static let ripple = 3.4
        /// Sand-sheet undulation.
        static let undulation = 21.0
        static let undulationFine = 8.0
        /// Gravel and coarse-sand grain.
        static let grain = 0.55
        static let grainFine = 0.24

        /// 0 when a wavelength is under ~1.7 px, 1 from ~4 px.
        @inline(__always) func band(_ wavelength: Double) -> Double { Smooth.step(1.7, 4, wavelength / mpp) }

        @inline(__always) func sample(_ u: Double, _ v: Double) -> (Float, Float) {
            /* Ripples step aside from ~9 px a wavelength (gone by z19.5): a crest across a 35–70 m tile is too
               close to a line, so the closest zooms keep only isotropic undulation and grain. */
            let fr = band(Self.ripple) * (1 - Smooth.step(9, 22, Self.ripple / mpp))
            let fu = band(Self.undulation), fuf = band(Self.undulationFine)
            let fg = band(Self.grain), fgf = band(Self.grainFine)
            /* Where gravel lies (a lag surface: fewer ripples, more grain), in patches of ~100 m. */
            let gravel = Smooth.step(0.12, 0.62, Noise.gradient(u / 95 + 41.3, v / 95 - 13.7))
            var h = 0.0
            if fr > 0 {
                /* Sinuous crests: the phase is warped at ~3 and ~10 wavelengths, so a crest wanders
                   and forks; the amplitude breaks along it (~2 λ) and comes in patches (~25 m), so
                   no crest runs on as a line. */
                let w1 = Noise.gradient(u / 10.5 + 7.1, v / 10.5 + 3.3)
                let w2 = Noise.gradient(u / 34 - 2.9, v / 34 + 8.6)
                let w0 = Noise.gradient(u / 5.8 - 11.3, v / 5.8 + 6.1)
                let s = (u * wx + v * wy) / Self.ripple + 0.45 * w0 + 0.75 * w1 + 1.4 * w2
                let p = 2 * Double.pi * s
                /* Asymmetric: a long stoss slope, a short steep lee. */
                let rip = sin(p) + 0.32 * sin(2 * p + 1.1)
                let patch = Smooth.step(-0.4, 0.42, Noise.gradient(u / 26 + 17.3, v / 26 - 4.1))
                let broken = 0.15 + 0.85 * Smooth.step(-0.55, 0.5, Noise.gradient(u / 4.4 + 3.7, v / 4.4 + 9.2))
                h += 0.017 * rip * patch * broken * (1 - 0.85 * gravel) * fr
            }
            if fu > 0 { h += 0.2 * Noise.gradient(u / Self.undulation - 5.5, v / Self.undulation + 1.9) * fu }
            if fuf > 0 { h += 0.05 * Noise.gradient(u / Self.undulationFine + 2.2, v / Self.undulationFine - 6.4) * fuf }
            var g = 0.0
            if fg > 0 { g += (0.10 + 0.32 * gravel) * Noise.value(u / Self.grain, v / Self.grain) * fg }
            if fgf > 0 { g += (0.06 + 0.22 * gravel) * Noise.value(u / Self.grainFine + 0.5, v / Self.grainFine + 0.5) * fgf }
            return (Float(h), Float(g))
        }
    }
}

/// Deterministic 2D noise on an integer lattice (no state, no randomness at run time).
enum Noise {
    @inline(__always) static func hash(_ x: Int64, _ y: Int64) -> UInt64 {
        var h = UInt64(bitPattern: x) &* 0x9E37_79B9_7F4A_7C15 ^ (UInt64(bitPattern: y) &* 0xC2B2_AE3D_27D4_EB4F)
        h ^= h >> 31
        h = h &* 0xBF58_476D_1CE4_E5B9
        h ^= h >> 29
        h = h &* 0x94D0_49BB_1331_11EB
        h ^= h >> 32
        return h
    }

    @inline(__always) private static func fade(_ t: Double) -> Double { t * t * t * (t * (t * 6 - 15) + 10) }

    /// Gradient (Perlin-style) noise, about −1…1, smooth.
    static func gradient(_ x: Double, _ y: Double) -> Double {
        let xf = x.rounded(.down), yf = y.rounded(.down)
        let xi = Int64(xf), yi = Int64(yf)
        let dx = x - xf, dy = y - yf
        @inline(__always) func g(_ ix: Int64, _ iy: Int64, _ px: Double, _ py: Double) -> Double {
            let a = Double(hash(ix, iy) & 0xFFFF) / 65_536 * 2 * .pi
            return cos(a) * px + sin(a) * py
        }
        let n00 = g(xi, yi, dx, dy), n10 = g(xi + 1, yi, dx - 1, dy)
        let n01 = g(xi, yi + 1, dx, dy - 1), n11 = g(xi + 1, yi + 1, dx - 1, dy - 1)
        let u = fade(dx), v = fade(dy)
        let a = n00 + (n10 - n00) * u, b = n01 + (n11 - n01) * u
        return (a + (b - a) * v) * 1.41
    }

    /// Smooth value noise, −1…1 (grain).
    static func value(_ x: Double, _ y: Double) -> Double {
        let xf = x.rounded(.down), yf = y.rounded(.down)
        let xi = Int64(xf), yi = Int64(yf)
        @inline(__always) func r(_ ix: Int64, _ iy: Int64) -> Double { Double(hash(ix &+ 9_176, iy &- 3_319) & 0xFFFF) / 32_768 - 1 }
        let u = fade(x - xf), v = fade(y - yf)
        let a = r(xi, yi) + (r(xi + 1, yi) - r(xi, yi)) * u
        let b = r(xi, yi + 1) + (r(xi + 1, yi + 1) - r(xi, yi + 1)) * u
        return a + (b - a) * v
    }
}
