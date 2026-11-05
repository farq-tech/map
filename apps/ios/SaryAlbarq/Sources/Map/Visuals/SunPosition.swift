import Foundation

/// The real sun over a point, computed on the phone (no network): altitude above the
/// horizon and azimuth from true north, clockwise. Same low-precision solar formulas as
/// `SunLight.elevationDeg` (≈ 0.1–0.3°, far better than any light preset needs), plus the
/// azimuth that the hillshade's light direction follows.
struct SunPosition: Equatable {
    /// Degrees above the horizon (negative = below).
    var altitudeDeg: Double
    /// Degrees from true north, clockwise, 0..<360.
    var azimuthDeg: Double
    /// The sun is rising (altitude ten minutes later is higher): dawn rather than dusk.
    var rising: Bool

    static func at(_ date: Date, lat: Double, lng: Double) -> SunPosition {
        let now = raw(date, lat: lat, lng: lng)
        let later = raw(date.addingTimeInterval(600), lat: lat, lng: lng)
        return SunPosition(altitudeDeg: now.alt, azimuthDeg: now.az, rising: later.alt > now.alt)
    }

    private static func raw(_ date: Date, lat: Double, lng: Double) -> (alt: Double, az: Double) {
        let rad = Double.pi / 180
        let d = date.timeIntervalSince1970 / 86_400 + 2_440_587.5 - 2_451_545.0
        let g = (357.529 + 0.98560028 * d) * rad
        let q = 280.459 + 0.98564736 * d
        let L = (q + 1.915 * sin(g) + 0.02 * sin(2 * g)) * rad
        let e = (23.439 - 0.00000036 * d) * rad
        let ra = atan2(cos(e) * sin(L), cos(L))
        let dec = asin(sin(e) * sin(L))
        let gmst = (18.697374558 + 24.06570982441908 * d).truncatingRemainder(dividingBy: 24)
        let ha = (gmst * 15 + lng) * rad - ra
        let phi = lat * rad
        let alt = asin(sin(phi) * sin(dec) + cos(phi) * cos(dec) * cos(ha))
        /* Azimuth from north, clockwise (south-based formula + 180°). */
        let az = atan2(sin(ha), cos(ha) * sin(phi) - tan(dec) * cos(phi)) / rad + 180
        return (alt / rad, az.truncatingRemainder(dividingBy: 360))
    }

    /// Mapbox Standard's light preset from the real altitude (same thresholds as `SunLight`:
    /// day above 4°, night once the sun is 6° under, dawn / dusk by the sun's direction between).
    var preset: SunLight.Preset {
        if altitudeDeg > 4 { return .day }
        if altitudeDeg <= -6 { return .night }
        return rising ? .dawn : .dusk
    }
}

/// How the terrain is shaded from the real sun: the hillshade's light comes from the sun's
/// azimuth (anchored to the map, so it stays put while the map turns); a low sun gives long,
/// strong relief, a high noon sun a faint one. At night there is no sun to follow: a faint,
/// cool, conventional north-west light keeps the relief readable without pretending.
struct HillshadeLight: Equatable {
    /// Degrees from north, clockwise (`hillshade-illumination-direction`, anchor "map").
    var direction: Double
    /// `hillshade-exaggeration`, 0…1.
    var exaggeration: Double
    var shadow: RGBA
    var highlight: RGBA
    var accent: RGBA
    /// The light follows the real sun (false at night).
    var fromSun: Bool

    /// Conventional cartographic light (north-west), used only when the sun is down.
    static let nightDirection = 315.0

    static func from(_ sun: SunPosition, satellite: Bool) -> HillshadeLight {
        /* Imagery already carries its own shadows: keep ours lighter over satellite. */
        let k = satellite ? 0.7 : 1.0
        let a = sun.altitudeDeg
        if a <= -6 {
            return HillshadeLight(direction: nightDirection, exaggeration: 0.22 * k,
                                  shadow: RGBA(6, 10, 28, 0.55), highlight: RGBA(120, 140, 190, 0.12), accent: RGBA(8, 12, 30, 0.3), fromSun: false)
        }
        /* 0° → strongest (0.7), 70°+ → faint (0.2), smooth in between. */
        let low = 1 - Smooth.step(0, 70, a)
        let ex = (0.2 + 0.5 * low) * k
        /* Golden hour (sun under ~12°): warm highlights and amber shadows on the sand. */
        let golden = 1 - Smooth.step(0, 12, a)
        let twilight = 1 - Smooth.step(-6, 0, a)
        var shadow = RGBA(44, 30, 18, 0.5).mix(RGBA(70, 34, 14, 0.55), golden)
        var highlight = RGBA(255, 246, 228, 0.32).mix(RGBA(255, 196, 120, 0.4), golden)
        shadow = shadow.mix(RGBA(46, 26, 32, 0.55), twilight)
        highlight = highlight.mix(RGBA(255, 150, 120, 0.22), twilight)
        return HillshadeLight(direction: sun.azimuthDeg, exaggeration: ex, shadow: shadow, highlight: highlight,
                              accent: RGBA(30, 20, 10, 0.25), fromSun: true)
    }
}

/// A colour as Mapbox reads it ("rgba(r, g, b, a)"), with mixing for smooth sky changes.
struct RGBA: Equatable {
    var r: Double, g: Double, b: Double, a: Double

    init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    func mix(_ o: RGBA, _ t: Double) -> RGBA {
        let k = min(1, max(0, t))
        return RGBA(r + (o.r - r) * k, g + (o.g - g) * k, b + (o.b - b) * k, a + (o.a - a) * k)
    }

    var css: String {
        func c(_ v: Double) -> Int { Int(min(255, max(0, v)).rounded()) }
        return "rgba(\(c(r)), \(c(g)), \(c(b)), \(String(format: "%.2f", min(1, max(0, a)))))"
    }
}

enum Smooth {
    /// 0 below `a`, 1 above `b`, a smooth S between.
    static func step(_ a: Double, _ b: Double, _ x: Double) -> Double {
        guard b != a else { return x < a ? 0 : 1 }
        let t = min(1, max(0, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * min(1, max(0, t)) }
}
