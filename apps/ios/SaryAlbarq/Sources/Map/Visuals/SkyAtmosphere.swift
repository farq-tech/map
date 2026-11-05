import Foundation

/// The weather that shapes the map's sky, read from the weather layer's own cached
/// report (`WeatherCache` / `WeatherStore`): never fetched for the visuals, never invented.
/// Every field may be missing (the model or the dust service had no value).
struct SkyWeather: Equatable {
    var visibilityM: Double?
    /// Surface dust, µg/m³ (CAMS).
    var dust: Double?
    var pm10: Double?
    /// WMO weather code.
    var weatherCode: Int?
    var precipitationMm: Double?
    /// When the weather layer received it (for the source line's age).
    var fetchedAt: Date

    /// Data older than this does not drive the sky (the 48 h forecast still might, hour by hour).
    static let maxAgeS: TimeInterval = 6 * 3600

    /// The value for `now`: the model's «now» if it is within 90 minutes, else the forecast hour
    /// that contains `now`; nil when the report is too old or has nothing for now.
    static func from(_ r: WeatherReport?, now: Date) -> SkyWeather? {
        guard let r, now.timeIntervalSince(r.fetchedAt) <= maxAgeS else { return nil }
        let h: WeatherHour?
        if let c = r.current, abs(now.timeIntervalSince(c.time)) <= 90 * 60 {
            h = c
        } else {
            h = r.hours.last { $0.time <= now && now.timeIntervalSince($0.time) < 3600 }
        }
        guard let h else { return nil }
        return SkyWeather(visibilityM: h.visibilityM, dust: r.airAvailable ? h.dust : nil, pm10: r.airAvailable ? h.pm10 : nil,
                          weatherCode: h.weatherCode, precipitationMm: h.precipitationMm, fetchedAt: r.fetchedAt)
    }

    /// 0…1: how much airborne dust / sand there is. From the dust and PM10 values when the air
    /// service answered; from a low visibility without rain or fog otherwise.
    var dustiness: Double {
        var d = 0.0
        if let dust { d = max(d, Smooth.step(120, 1_200, dust)) }
        if let pm10 { d = max(d, Smooth.step(250, 1_600, pm10) * 0.9) }
        if let v = visibilityM, !wet, !foggy, (dust ?? 0) > 60 || (pm10 ?? 0) > 150 || (dust == nil && pm10 == nil) {
            d = max(d, (1 - Smooth.step(1_000, 10_000, v)) * (dust == nil && pm10 == nil ? 0.6 : 1))
        }
        return min(1, d)
    }

    /// 0…1: clouds / rain / fog greying the horizon.
    var greyness: Double {
        guard let c = weatherCode else { return 0 }
        switch c {
        case 0, 1: return 0
        case 2: return 0.3
        case 3: return 0.55
        case 45, 48: return 0.9
        case 51...57: return 0.6
        case 61...67, 80...82: return 0.75
        case 71...77, 85, 86: return 0.7
        case 95...99: return 0.85
        default: return 0.2
        }
    }

    var wet: Bool { (precipitationMm ?? 0) > 0.05 || [51, 53, 55, 56, 57, 61, 63, 65, 66, 67, 80, 81, 82, 95, 96, 99].contains(weatherCode ?? -1) }
    var foggy: Bool { weatherCode == 45 || weatherCode == 48 }
}

/// What the map's fog / atmosphere is set to (Mapbox `fog`), plus the one line that says why.
struct SkyAtmosphere: Equatable {
    var range: [Double]
    var color: RGBA
    var highColor: RGBA
    var spaceColor: RGBA
    var horizonBlend: Double
    var starIntensity: Double
    /// «الأجواء من الطقس: …» when weather changed the look; nil when it is the sun alone.
    var sourceLine: String?
    /// The weather changed the look (dust, rain, clouds, fog, low visibility).
    var weatherDriven: Bool

    /// The sky for the real sun altitude alone (keyframes, blended smoothly between).
    static func sky(sunAltitude a: Double) -> SkyAtmosphere {
        struct K { var alt: Double; var color: RGBA; var high: RGBA; var space: RGBA; var blend: Double; var stars: Double; var end: Double }
        let keys: [K] = [
            K(alt: -18, color: RGBA(11, 16, 30), high: RGBA(8, 18, 48), space: RGBA(1, 3, 10), blend: 0.03, stars: 0.8, end: 9),
            K(alt: -10, color: RGBA(22, 28, 50), high: RGBA(18, 32, 78), space: RGBA(4, 8, 26), blend: 0.05, stars: 0.6, end: 9),
            K(alt: -4, color: RGBA(70, 58, 92), high: RGBA(52, 66, 140), space: RGBA(14, 20, 60), blend: 0.09, stars: 0.2, end: 10),
            K(alt: -2, color: RGBA(156, 112, 112), high: RGBA(68, 84, 158), space: RGBA(22, 30, 80), blend: 0.11, stars: 0.06, end: 10.5),
            K(alt: 0, color: RGBA(242, 170, 130), high: RGBA(84, 104, 176), space: RGBA(30, 42, 100), blend: 0.13, stars: 0.0, end: 11),
            K(alt: 6, color: RGBA(255, 214, 168), high: RGBA(108, 152, 224), space: RGBA(70, 116, 200), blend: 0.1, stars: 0, end: 12),
            K(alt: 20, color: RGBA(232, 240, 250), high: RGBA(52, 118, 228), space: RGBA(150, 192, 244), blend: 0.06, stars: 0, end: 12),
        ]
        let lo = keys.last { $0.alt <= a } ?? keys[0]
        let hi = keys.first { $0.alt > a } ?? keys[keys.count - 1]
        /* Linear between keyframes: the sky moves at the pace of the sun, with no sudden swing. */
        let t = hi.alt == lo.alt ? 0 : min(1, max(0, (a - lo.alt) / (hi.alt - lo.alt)))
        return SkyAtmosphere(range: [0.8, Smooth.lerp(lo.end, hi.end, t)], color: lo.color.mix(hi.color, t), highColor: lo.high.mix(hi.high, t),
                             spaceColor: lo.space.mix(hi.space, t), horizonBlend: Smooth.lerp(lo.blend, hi.blend, t),
                             starIntensity: Smooth.lerp(lo.stars, hi.stars, t), sourceLine: nil, weatherDriven: false)
    }

    /// Sun + weather: dust → sandy haze and a short range; rain / clouds → a greyer horizon and
    /// light fog; clear → the sun's sky, crisp. Clouds and dust dim the stars.
    static func make(sunAltitude a: Double, weather w: SkyWeather?, now: Date) -> SkyAtmosphere {
        var s = sky(sunAltitude: a)
        guard let w else { return s }
        let night = 1 - Smooth.step(-8, 2, a)
        let d = w.dustiness
        let g = w.greyness
        if g > 0 {
            let grey = RGBA(184, 190, 198).mix(RGBA(40, 44, 52), night)
            s.color = s.color.mix(grey, g * 0.8)
            s.highColor = s.highColor.mix(RGBA(140, 150, 163).mix(RGBA(26, 30, 40), night), g * 0.7)
            s.spaceColor = s.spaceColor.mix(RGBA(150, 158, 170).mix(RGBA(10, 12, 18), night), g * 0.5)
            s.horizonBlend = max(s.horizonBlend, Smooth.lerp(s.horizonBlend, w.foggy ? 0.45 : 0.22, g))
            s.range = [Smooth.lerp(0.8, w.foggy ? -0.4 : 0.3, g), Smooth.lerp(s.range[1], w.foggy ? 1.5 : 5.5, g)]
            s.starIntensity *= 1 - g
        }
        if d > 0 {
            let sand = RGBA(214, 178, 132).mix(RGBA(92, 70, 46), night)
            s.color = s.color.mix(sand, 0.15 + d * 0.8)
            s.highColor = s.highColor.mix(RGBA(200, 166, 120).mix(RGBA(60, 46, 32), night), d * 0.85)
            s.spaceColor = s.spaceColor.mix(RGBA(196, 168, 128).mix(RGBA(30, 24, 18), night), d * 0.6)
            s.horizonBlend = max(s.horizonBlend, Smooth.lerp(s.horizonBlend, 0.4, d))
            s.range = [min(s.range[0], Smooth.lerp(0.8, -0.6, d)), min(s.range[1], Smooth.lerp(s.range[1], 1.4, d))]
            s.starIntensity *= 1 - d
        }
        /* A short visibility, whatever its cause, shortens the range (never lengthens it). */
        if let v = w.visibilityM, v < 10_000 {
            s.range[1] = min(s.range[1], max(1.2, v / 1_000 * 1.1))
        }
        s.range[0] = min(s.range[0], s.range[1] - 0.6)
        s.weatherDriven = d >= 0.15 || g >= 0.25 || (w.visibilityM ?? .infinity) < 8_000
        if s.weatherDriven { s.sourceLine = sourceLine(w, dust: d, grey: g, now: now) }
        return s
    }

    /// «الأجواء من الطقس: غبار · الرؤية ١٫٨ كم · Open-Meteo» (+ the data's age once it is over an hour).
    static func sourceLine(_ w: SkyWeather, dust d: Double, grey g: Double, now: Date) -> String {
        var what: [String] = []
        if d >= 0.15 { what.append(d >= 0.6 ? "غبار كثيف" : "غبار") }
        if w.foggy { what.append("ضباب") } else if w.wet { what.append("مطر") } else if g >= 0.25 { what.append("غيوم") }
        if let v = w.visibilityM, v < 10_000 { what.append("الرؤية \(SaryFormat.distance(meters: v))") }
        var line = "الأجواء من الطقس: " + (what.isEmpty ? "رؤية منخفضة" : what.joined(separator: " · ")) + " · Open-Meteo"
        let ageMin = Int(now.timeIntervalSince(w.fetchedAt) / 60)
        if ageMin >= 60 { line += " (قبل \(SaryFormat.number(ageMin / 60)) س)" }
        return line
    }

    /// Mapbox `fog` properties, with transitions so changes glide (none when Reduce Motion is on).
    func properties(transitionMs: Int) -> [String: Any] {
        let t: [String: Any] = ["duration": transitionMs, "delay": 0]
        return [
            "range": range, "color": color.css, "high-color": highColor.css, "space-color": spaceColor.css,
            "horizon-blend": horizonBlend, "star-intensity": starIntensity,
            "range-transition": t, "color-transition": t, "high-color-transition": t, "space-color-transition": t,
            "horizon-blend-transition": t, "star-intensity-transition": t,
        ]
    }
}
