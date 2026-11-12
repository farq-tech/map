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
        let l = unveiled(sun, satellite: satellite)
        return satellite ? l.overImagery : l
    }

    /// Over the satellite photo the shade is a veil on a picture that already has its own light:
    /// Build 36 painted whole sun-facing slopes cream (highlight up to 58 %) and the others
    /// brown, so neighbouring areas of the same desert read as different colours. Lighter here.
    var overImagery: HillshadeLight {
        var l = self
        l.shadow.a *= 0.75
        l.highlight.a *= 0.5
        l.accent.a *= 0.6
        return l
    }

    /// Over the satellite imagery the shade only helps from afar: the DEM (~30 m, tiles to z14,
    /// the broad pass to z11) is coarser than the photo from z13, and over-zoomed it shades flat
    /// facets and tile-shaped patches that are not on the ground. So over satellite it fades out
    /// by z15 (z13.5 for the broad pass); on the vector maps it stays as before.
    static let satelliteFadeEnd = 15.0
    static let satelliteBroadFadeEnd = 13.5

    /// `hillshade-exaggeration` of the detail pass (crisper as you come closer).
    static func detailExaggeration(_ ex: Double, satellite: Bool) -> [Any] {
        if satellite {
            return ["interpolate", ["linear"], ["zoom"], 9.0, ex * 0.6, 12.0, ex, 13.5, ex * 0.5, satelliteFadeEnd, 0.0]
        }
        return ["interpolate", ["linear"], ["zoom"], 9.0, ex * 0.6, 12.0, ex, 15.0, min(1, ex * 1.12)]
    }

    /// `hillshade-exaggeration` of the broad pass (the big dune forms).
    static func broadExaggeration(_ ex: Double, satellite: Bool) -> [Any] {
        if satellite {
            return ["interpolate", ["linear"], ["zoom"], 8.0, ex, 11.5, ex * 0.8, satelliteBroadFadeEnd, 0.0]
        }
        return ["interpolate", ["linear"], ["zoom"], 8.0, ex, 15.0, ex * 0.75]
    }

    private static func unveiled(_ sun: SunPosition, satellite: Bool) -> HillshadeLight {
        /* Imagery already carries its own shadows: keep ours a little lighter over satellite. */
        let k = satellite ? 0.9 : 1.0
        let a = sun.altitudeDeg
        if a <= -6 {
            /* Moonlight-neutral (a hint of cool, never navy: navy over red sand reads teal). */
            return HillshadeLight(direction: nightDirection, exaggeration: 0.4 * k,
                                  shadow: RGBA(10, 10, 18, 0.72), highlight: RGBA(176, 184, 206, 0.10), accent: RGBA(8, 8, 16, 0.4), fromSun: false)
        }
        /* 0° → strongest (0.92), 70°+ → still readable (0.42), smooth in between. */
        let low = 1 - Smooth.step(0, 70, a)
        let ex = (0.42 + 0.5 * low) * k
        /* Golden hour (sun under ~12°): warm highlights and burnt-amber shadows on the sand. */
        let golden = 1 - Smooth.step(0, 14, a)
        let twilight = 1 - Smooth.step(-6, 0, a)
        var shadow = RGBA(50, 28, 14, 0.8).mix(RGBA(74, 30, 8, 0.86), golden)
        var highlight = RGBA(255, 244, 220, 0.4).mix(RGBA(255, 206, 128, 0.58), golden)
        shadow = shadow.mix(RGBA(52, 28, 28, 0.72), twilight)
        highlight = highlight.mix(RGBA(255, 170, 128, 0.28), twilight)
        return HillshadeLight(direction: sun.azimuthDeg, exaggeration: ex, shadow: shadow, highlight: highlight,
                              accent: RGBA(40, 22, 10, 0.45), fromSun: true)
    }

    /// The broad pass (a coarse DEM, the big dune forms): same light, a softer, wider shade.
    var broad: HillshadeLight {
        var b = self
        b.exaggeration = min(1, exaggeration * 1.05)
        b.shadow.a *= 0.62
        b.highlight.a *= 0.55
        b.accent.a = 0
        return b
    }
}

/// The scene's 3D light (Mapbox `lights`: ambient + directional) from the real sun, so the
/// imagery, the cars and their shadows are lit the way the desert is right now: warm white by
/// day, gold at a low sun (from the sun's real azimuth), rose at twilight and a dim, nearly
/// neutral moonlight at night. Replaces Standard's preset lights, whose blue dusk / navy night
/// ambient tints red sand teal.
struct SceneLight: Equatable {
    var ambient: RGBA
    var ambientIntensity: Double
    var directional: RGBA
    var directionalIntensity: Double
    /// [azimuth from north, clockwise; polar angle from the zenith], degrees.
    var direction: [Double]
    var shadowIntensity: Double

    static func from(_ sun: SunPosition) -> SceneLight {
        let a = sun.altitudeDeg
        let golden = 1 - Smooth.step(0, 16, a)
        let twilight = 1 - Smooth.step(-6, 0, a)
        let night = 1 - Smooth.step(-12, -5, a)
        /* A warm grade even at noon (desert light, and it pulls the imagery's cyan cast back to sand). */
        var amb = RGBA(255, 240, 218).mix(RGBA(255, 212, 162), golden).mix(RGBA(226, 172, 152), twilight).mix(RGBA(128, 130, 158), night)
        amb.a = 1
        var dir = RGBA(255, 242, 218).mix(RGBA(255, 186, 112), golden).mix(RGBA(255, 156, 116), twilight).mix(RGBA(170, 172, 196), night)
        dir.a = 1
        let ambI = Smooth.lerp(Smooth.lerp(Smooth.lerp(0.82, 0.76, golden), 0.62, twilight), 0.26, night)
        let dirI = Smooth.lerp(Smooth.lerp(Smooth.lerp(0.32, 0.52, golden), 0.2, twilight), 0.1, night)
        /* The sun's own direction while it is up; a high north-west moon-ish light at night. */
        let az = night > 0.5 ? HillshadeLight.nightDirection : sun.azimuthDeg
        let polar = night > 0.5 ? 60 : min(88, max(12, 90 - a))
        return SceneLight(ambient: amb, ambientIntensity: ambI, directional: dir, directionalIntensity: dirI,
                          direction: [(az * 10).rounded() / 10, (polar * 10).rounded() / 10], shadowIntensity: night > 0.5 ? 0.45 : 0.85)
    }

    /// Standard's own lights for a preset (literal values from its style), used to hand the light
    /// back when «السماء والإضاءة» is switched off.
    static func standard(_ p: SunLight.Preset) -> SceneLight {
        switch p {
        case .dawn: return SceneLight(ambient: RGBA(254, 237, 220), ambientIntensity: 0.75, directional: RGBA(252, 195, 139), directionalIntensity: 0.5, direction: [120, 50], shadowIntensity: 1)
        case .day: return SceneLight(ambient: RGBA(255, 255, 255), ambientIntensity: 0.8, directional: RGBA(255, 255, 255), directionalIntensity: 0.2, direction: [180, 20], shadowIntensity: 1)
        case .dusk: return SceneLight(ambient: RGBA(54, 60, 94), ambientIntensity: 0.8, directional: RGBA(252, 192, 135), directionalIntensity: 0.2, direction: [240, 80], shadowIntensity: 1)
        case .night: return SceneLight(ambient: RGBA(0, 24, 56), ambientIntensity: 0.5, directional: RGBA(74, 74, 74), directionalIntensity: 0.5, direction: [270, 20], shadowIntensity: 0.5)
        }
    }
}

/// Owner request (Build 45): no sun-like look on the map. Day is plain even daylight and night is night:
/// no warm dawn / dusk cast, no sun-directed light or cast shadows, no sun-lit relief (hillshade) and no
/// golden / orange horizon in the sky. The sun maths above stays (sunset times, the night switch, car
/// lights); only what the map RENDERS from it is flattened here, in one place.
/// Owner, 2026-11-12: «أزل العتمة اللي بالليل بالخريطة، خلّ كل شي واضح دائمًا». The MAP never darkens
/// at night, forced night theme or after sunset: the basemap light is always `.day`, there is no night
/// sky / stars / fog and no night-dimmed relief. The app's UI night theme (cards, sheets, chips) is a
/// separate thing and is untouched. This is the ONE switch every map surface reads (home / live map,
/// plan, track and CarPlay maps, the visuals director).
enum NightLook {
    /// false = the map stays in clear daylight at all hours. DEBUG `-SaryNightMapDark` brings the old
    /// dark night back for before/after comparison shots.
    static let mapDarkens: Bool = {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-SaryNightMapDark")
        #else
        return false
        #endif
    }()

    /// The basemap preset for a map: the night theme (`forcedNight`) and the real sun (`real`) only
    /// matter while `mapDarkens`; otherwise always day.
    static func preset(forcedNight: Bool, real: SunLight.Preset) -> SunLight.Preset {
        if mapDarkens, forcedNight { return .night }
        return SunLook.preset(real)
    }

    /// Whether map-drawn lines should be contrasted for a dark map (night theme AND a map that darkens).
    static func mapIsDark(nightTheme: Bool) -> Bool { mapDarkens && nightTheme }
}

enum SunLook {
    /// false = the owner's flat look. One switch to bring the old look back for comparison shots.
    static let enabled: Bool = {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-SaryOldSunLook")
        #else
        return false
        #endif
    }()

    /// The basemap preset actually applied: dawn and dusk are plain day (their orange cast is the sun look).
    static func preset(_ p: SunLight.Preset) -> SunLight.Preset {
        enabled ? p : (p == .night && NightLook.mapDarkens ? .night : .day)
    }

    /// The altitude the sky is drawn for: a fixed neutral noon (no golden horizon, no night sky or stars),
    /// unless the old look (`-SaryOldSunLook`) or the dark night (`-SaryNightMapDark`) is asked for.
    static func skyAltitude(_ real: Double) -> Double {
        enabled || (real <= -6 && NightLook.mapDarkens) ? real : 30
    }

    /// Cast shadows from the scene's directional light (3D buildings): off.
    static var castShadows: Bool { enabled }

    /// Terrain shading lit from the sun's azimuth: off (the 3D terrain geometry stays).
    static var sunLitRelief: Bool { enabled }
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
