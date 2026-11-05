@testable import SaryAlbarq
import XCTest

/// «المؤثرات البصرية»: sun → light preset / hillshade, weather → fog, drone path, DEM slope, budget.
final class MapVisualsTests: XCTestCase {
    private func utc(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

    // MARK: sun

    func testSunNoonOverRiyadhAtTheSummerSolstice() {
        let s = SunPosition.at(utc("2026-06-21T08:55:00Z"), lat: 24.71, lng: 46.675)
        XCTAssertGreaterThan(s.altitudeDeg, 88, "the sun is almost overhead (90 − 24.7 + 23.4)")
        XCTAssertEqual(s.preset, .day)
    }

    func testSunAzimuthMorningEastAfternoonWest() {
        let am = SunPosition.at(utc("2026-06-21T04:00:00Z"), lat: 24.71, lng: 46.675)
        XCTAssertEqual(am.azimuthDeg, 74, accuracy: 3, "07:00 in Riyadh in June: east-north-east")
        XCTAssertTrue(am.rising)
        let pm = SunPosition.at(utc("2026-06-21T14:00:00Z"), lat: 24.71, lng: 46.675)
        XCTAssertEqual(pm.azimuthDeg, 287, accuracy: 3, "17:00: west-north-west")
        XCTAssertFalse(pm.rising)
    }

    func testPresetFollowsRealAltitudeNotTheClock() {
        /* Nafud (28.0N 41.5E), 5 Nov 2026: the sun sets around 14:25 UTC. */
        XCTAssertEqual(SunPosition.at(utc("2026-11-05T13:50:00Z"), lat: 28.0, lng: 41.5).preset, .day, "6.8° up")
        XCTAssertEqual(SunPosition.at(utc("2026-11-05T14:20:00Z"), lat: 28.0, lng: 41.5).preset, .dusk, "0.6° up and sinking")
        XCTAssertEqual(SunPosition.at(utc("2026-11-05T18:00:00Z"), lat: 28.0, lng: 41.5).preset, .night)
        /* Same wall-clock instant, 1,600 km further east: the sun is already lower there. */
        let east = SunPosition.at(utc("2026-11-05T13:50:00Z"), lat: 28.0, lng: 56.0)
        XCTAssertLessThan(east.altitudeDeg, SunPosition.at(utc("2026-11-05T13:50:00Z"), lat: 28.0, lng: 41.5).altitudeDeg)
        let dawn = SunPosition.at(utc("2026-11-05T03:10:00Z"), lat: 28.0, lng: 41.5)
        XCTAssertTrue(dawn.rising)
        if dawn.altitudeDeg > -6, dawn.altitudeDeg <= 4 { XCTAssertEqual(dawn.preset, .dawn) }
    }

    func testPresetMatchesTheExistingSunLightThresholds() {
        for h in stride(from: 0.0, to: 24, by: 0.25) {
            let d = utc("2026-11-05T00:00:00Z").addingTimeInterval(h * 3600)
            XCTAssertEqual(SunPosition.at(d, lat: 25.1, lng: 46.1).preset, SunLight.preset(d, lat: 25.1, lng: 46.1), "hour \(h)")
        }
    }

    func testHillshadeLightComesFromTheSun() {
        let low = SunPosition(altitudeDeg: 3, azimuthDeg: 251, rising: false)
        let high = SunPosition(altitudeDeg: 49, azimuthDeg: 186, rising: false)
        let a = HillshadeLight.from(low, satellite: false)
        let b = HillshadeLight.from(high, satellite: false)
        XCTAssertEqual(a.direction, 251)
        XCTAssertEqual(b.direction, 186)
        XCTAssertTrue(a.fromSun)
        XCTAssertGreaterThan(a.exaggeration, b.exaggeration, "a low sun casts long shadows: stronger relief")
        XCTAssertGreaterThan(a.highlight.r - a.highlight.b, b.highlight.r - b.highlight.b, "golden-hour highlights are warmer")
        XCTAssertLessThan(HillshadeLight.from(low, satellite: true).exaggeration, a.exaggeration, "lighter over imagery")
        let night = HillshadeLight.from(SunPosition(altitudeDeg: -30, azimuthDeg: 280, rising: false), satellite: false)
        XCTAssertFalse(night.fromSun)
        XCTAssertEqual(night.direction, HillshadeLight.nightDirection)
        XCTAssertLessThan(night.exaggeration, b.exaggeration)
    }

    // MARK: sky & weather → fog

    func testSkyIsContinuousAndStarsOnlyAtNight() {
        XCTAssertGreaterThan(SkyAtmosphere.sky(sunAltitude: -30).starIntensity, 0.5)
        XCTAssertEqual(SkyAtmosphere.sky(sunAltitude: 30).starIntensity, 0)
        var prev = SkyAtmosphere.sky(sunAltitude: -25)
        for a in stride(from: -25.0, through: 40, by: 0.5) {
            let s = SkyAtmosphere.sky(sunAltitude: a)
            XCTAssertLessThan(abs(s.color.r - prev.color.r) + abs(s.color.g - prev.color.g) + abs(s.color.b - prev.color.b), 45, "no jump at \(a)°")
            prev = s
        }
    }

    private func report(_ h: WeatherHour, fetched: Date, air: Bool = true) -> WeatherReport {
        WeatherReport(area: WeatherArea(around: 28, lng: 41.5), fetchedAt: fetched, current: h, hours: [h], airAvailable: air)
    }

    private func hour(_ t: Date, code: Int = 1, vis: Double? = 24_000, dust: Double? = 40, pm10: Double? = 60, rain: Double = 0) -> WeatherHour {
        WeatherHour(time: t, temperatureC: 25, precipitationMm: rain, precipitationProbability: nil, weatherCode: code, windKmh: 10, gustKmh: 20,
                    windFromDeg: 300, visibilityM: vis, dust: dust, pm10: pm10)
    }

    func testClearWeatherIsCrispAndUnlabelled() {
        let now = utc("2026-11-05T09:00:00Z")
        let w = SkyWeather.from(report(hour(now), fetched: now), now: now)
        let s = SkyAtmosphere.make(sunAltitude: 40, weather: w, now: now)
        XCTAssertFalse(s.weatherDriven)
        XCTAssertNil(s.sourceLine)
        XCTAssertEqual(s, SkyAtmosphere.sky(sunAltitude: 40), "clear: the sun's sky, untouched")
    }

    func testDustGivesSandyHazeAndShortRange() {
        let now = utc("2026-11-05T14:20:00Z")
        let clear = SkyAtmosphere.sky(sunAltitude: 1)
        let w = SkyWeather.from(report(hour(now, vis: 1_800, dust: 1_450, pm10: 1_900), fetched: now.addingTimeInterval(-360)), now: now)
        XCTAssertEqual(w?.dustiness ?? 0, 1, accuracy: 0.01)
        let s = SkyAtmosphere.make(sunAltitude: 1, weather: w, now: now)
        XCTAssertTrue(s.weatherDriven)
        XCTAssertLessThan(s.range[1], 2.5, "visibility 1.8 km: the haze closes in")
        XCTAssertLessThan(s.range[1], clear.range[1])
        XCTAssertGreaterThan(s.horizonBlend, clear.horizonBlend)
        XCTAssertGreaterThan(s.color.r, s.color.b + 40, "sandy, not blue")
        let line = s.sourceLine ?? ""
        XCTAssertTrue(line.contains("غبار"), line)
        XCTAssertTrue(line.contains("Open-Meteo"), line)
        XCTAssertTrue(line.contains("١٫٨ كم"), line)
        /* Dust at night hides the stars. */
        XCTAssertLessThan(SkyAtmosphere.make(sunAltitude: -30, weather: w, now: now).starIntensity, 0.05)
    }

    func testRainAndCloudsGreyTheHorizon() {
        let now = utc("2026-11-05T09:00:00Z")
        let clear = SkyAtmosphere.sky(sunAltitude: 40)
        let rain = SkyAtmosphere.make(sunAltitude: 40, weather: SkyWeather.from(report(hour(now, code: 63, vis: 6_000, rain: 1.6), fetched: now), now: now), now: now)
        XCTAssertTrue(rain.weatherDriven)
        XCTAssertLessThan(rain.range[1], clear.range[1])
        XCTAssertGreaterThan(rain.horizonBlend, clear.horizonBlend)
        XCTAssertLessThan(abs(rain.color.r - rain.color.b), abs(clear.color.r - clear.color.b) + 25, "greyer")
        XCTAssertTrue(rain.sourceLine?.contains("مطر") == true)
        let overcast = SkyAtmosphere.make(sunAltitude: 40, weather: SkyWeather.from(report(hour(now, code: 3), fetched: now), now: now), now: now)
        XCTAssertTrue(overcast.sourceLine?.contains("غيوم") == true)
        let fog = SkyAtmosphere.make(sunAltitude: 40, weather: SkyWeather.from(report(hour(now, code: 45, vis: 400), fetched: now), now: now), now: now)
        XCTAssertLessThan(fog.range[1], rain.range[1])
        XCTAssertLessThan(fog.range[0], fog.range[1])
    }

    func testStaleOrMissingWeatherNeverDrivesTheSky() {
        let now = utc("2026-11-05T09:00:00Z")
        XCTAssertNil(SkyWeather.from(report(hour(now, vis: 1_000, dust: 2_000), fetched: now.addingTimeInterval(-7 * 3600)), now: now))
        XCTAssertNil(SkyWeather.from(nil, now: now))
        /* Air service down: dust unknown, not "no dust" — a low visibility alone still hazes, more gently. */
        let w = SkyWeather.from(report(hour(now, vis: 2_000, dust: 900, pm10: 900), fetched: now, air: false), now: now)
        XCTAssertNil(w?.dust)
        XCTAssertGreaterThan(w?.dustiness ?? 0, 0.3)
        XCTAssertLessThan(w?.dustiness ?? 1, 0.7)
    }

    func testAgeIsSaidOnceOverAnHour() {
        let now = utc("2026-11-05T09:00:00Z")
        let w = SkyWeather(visibilityM: 3_000, dust: 800, pm10: nil, weatherCode: 1, precipitationMm: 0, fetchedAt: now.addingTimeInterval(-2.5 * 3600))
        XCTAssertTrue(SkyAtmosphere.sourceLine(w, dust: w.dustiness, grey: 0, now: now).contains("قبل ٢ س"))
    }

    func testFogPropertiesCarryTransitions() {
        let p = SkyAtmosphere.sky(sunAltitude: 10).properties(transitionMs: 1_800)
        for k in ["range", "color", "high-color", "space-color", "horizon-blend", "star-intensity"] { XCTAssertNotNil(p[k], k) }
        XCTAssertEqual((p["color-transition"] as? [String: Any])?["duration"] as? Int, 1_800)
        XCTAssertTrue((p["color"] as? String)?.hasPrefix("rgba(") == true)
    }

    // MARK: drone

    func testDroneOrbitIsOneEasedCircle() {
        let p = LngLat(lng: 41.5, lat: 28.0)
        let from = DroneOrbit.Frame(center: LngLat(lng: 41.45, lat: 27.98), zoom: 12, bearing: 30, pitch: 10)
        let o = DroneOrbit(center: p, from: from)
        XCTAssertEqual(o.duration, 24, accuracy: 0.001)
        XCTAssertEqual(o.orbitS, 22, "one full circle in 20–25 s")
        XCTAssertEqual(o.frame(at: 0), from)
        let start = o.frame(at: o.approachS)!
        XCTAssertEqual(start.center, p)
        XCTAssertEqual(start.pitch, DroneOrbit.defaultPitch)
        XCTAssertEqual(start.bearing, 30, accuracy: 0.001)
        XCTAssertEqual(o.frame(at: o.duration)!.bearing, 30, accuracy: 0.001, "back where it started: 360°")
        XCTAssertNil(o.frame(at: o.duration + 0.1))
        XCTAssertNil(o.frame(at: -1))
        /* Unwrapped, the bearing only increases and adds up to one turn; slow at the ends, fastest mid-way. */
        let path = o.path(step: 0.25).filter { $0.center == p }
        var total = 0.0
        var steps: [Double] = []
        for (a, b) in zip(path, path.dropFirst()) {
            var d = b.bearing - a.bearing
            if d < -180 { d += 360 }
            XCTAssertGreaterThanOrEqual(d, -0.0001)
            total += d
            steps.append(d)
        }
        XCTAssertEqual(total, 360, accuracy: 0.5)
        XCTAssertLessThan(steps.first!, steps[steps.count / 2] / 5, "eases in")
        XCTAssertLessThan(steps.last!, steps[steps.count / 2] / 5, "eases out")
        XCTAssertLessThan(steps.max()! / 0.25, 30, "never faster than ~26°/s")
        XCTAssertTrue(path.allSatisfy { $0.pitch == DroneOrbit.defaultPitch && $0.zoom == o.zoom })
    }

    func testDroneNeverWhileDriving() {
        XCTAssertFalse(DroneOrbit.allowed(driving: true))
        XCTAssertTrue(DroneOrbit.allowed(driving: false))
        XCTAssertFalse(VisualBudget.resolve(VisualEffectsSettings(), VisualContext(driving: true)).drone)
    }

    // MARK: slope

    /// A straight line due east, `n` samples 30 m apart, and its elevations.
    private func line(_ n: Int) -> [LngLat] {
        let dLng = 30 / (111_320 * cos(25 * Double.pi / 180))
        return (0..<n).map { LngLat(lng: 46 + Double($0) * dLng, lat: 25) }
    }

    func testResampleKeepsEvenSpacing() {
        let pts = SlopeProfile.resample([LngLat(lng: 46, lat: 25), LngLat(lng: 46.01, lat: 25)])
        XCTAssertEqual(pts.count, 35, accuracy: 2, "≈ 1 km / 30 m")
        for (a, b) in zip(pts, pts.dropFirst().dropLast()) { XCTAssertEqual(PlanGeo.meters(a, b), 30, accuracy: 0.5) }
        let long = SlopeProfile.resample([LngLat(lng: 46, lat: 25), LngLat(lng: 47, lat: 25)])
        XCTAssertLessThanOrEqual(long.count, SlopeProfile.maxSamples + 1, "bounded DEM look-ups")
    }

    func testSteepStretchIsFoundFromTheDEM() {
        let pts = line(40)
        /* Flat, then a 20 % climb over samples 12…24 (6 m per 30 m), then flat on top. */
        let elev: [Double?] = (0..<40).map { i in Double(min(max(i - 12, 0), 12)) * 6 + 600 }
        let segs = SlopeProfile.steep(samples: pts, elevations: elev)
        XCTAssertEqual(segs.count, 1)
        XCTAssertEqual(segs[0].maxGradePct, 20, accuracy: 0.5)
        XCTAssertTrue(segs[0].points.count >= 10)
        XCTAssertEqual(SlopeProfile.steep(samples: pts, elevations: (0..<40).map { Double($0) * 0.3 }).count, 0, "1 % is not steep")
        /* Downhill counts too. */
        XCTAssertEqual(SlopeProfile.steep(samples: pts, elevations: elev.reversed()).count, 1)
    }

    func testSlopeNeverBridgesMissingTiles() {
        let pts = line(40)
        var elev: [Double?] = (0..<40).map { i in Double(min(max(i - 12, 0), 12)) * 6 + 600 }
        for i in 16...20 { elev[i] = nil }
        let segs = SlopeProfile.steep(samples: pts, elevations: elev)
        for s in segs { XCTAssertFalse(s.points.contains(pts[18]), "no grade through unknown heights") }
        XCTAssertTrue(SlopeProfile.steep(samples: pts, elevations: Array(repeating: nil, count: 40)).isEmpty)
        XCTAssertTrue(SlopeProfile.steep(samples: pts, elevations: [600]).isEmpty, "mismatched input")
    }

    func testSingleDemSpikeIsNotAStretch() {
        let pts = line(40)
        var elev: [Double?] = Array(repeating: 600, count: 40)
        elev[20] = 610 // one noisy cell: 10 m over a 90 m baseline is 11 %, under the threshold
        XCTAssertTrue(SlopeProfile.steep(samples: pts, elevations: elev).isEmpty)
    }

    // MARK: budget

    func testBudgetTerrainExaggeration() {
        let s = VisualEffectsSettings()
        /* Open desert seen from afar (z11): the dune lift. */
        XCTAssertEqual(VisualBudget.resolve(s, VisualContext(driving: true, pitch: 60, zoom: 11)).exaggeration, 1.0, "true heights while driving")
        XCTAssertEqual(VisualBudget.resolve(s, VisualContext(exploring: true, pitch: 0, zoom: 11)).exaggeration, 1.15, accuracy: 0.001)
        XCTAssertEqual(VisualBudget.resolve(s, VisualContext(exploring: true, pitch: 62, zoom: 11)).exaggeration, 2.0, accuracy: 0.001)
        XCTAssertEqual(VisualBudget.resolve(s, VisualContext(pitch: 62, zoom: 11)).exaggeration, 1.8, accuracy: 0.001)
        let mid = VisualBudget.resolve(s, VisualContext(terrain3D: true, pitch: 37.5, zoom: 11)).exaggeration
        XCTAssertGreaterThan(mid, 1.15)
        XCTAssertLessThan(mid, 2.0)
        /* Smooth in pitch: no step bigger than 0.03 per degree. */
        var prev = VisualBudget.exaggeration(VisualContext(exploring: true, pitch: 0, zoom: 11))
        for p in stride(from: 0.0, through: 85, by: 1) {
            let e = VisualBudget.exaggeration(VisualContext(exploring: true, pitch: p, zoom: 11))
            XCTAssertLessThan(abs(e - prev), 0.03)
            prev = e
        }
    }

    func testExaggerationLiftsZoomedOutDunesSmoothly() {
        /* Tilted and zoomed out: more lift for the ~30 m DEM's dunes; none close up or flat. */
        let far = VisualBudget.exaggeration(VisualContext(exploring: true, pitch: 62, zoom: 12))
        let near = VisualBudget.exaggeration(VisualContext(exploring: true, pitch: 62, zoom: 16))
        XCTAssertEqual(near, 1.0, accuracy: 0.001, "close in: true heights")
        XCTAssertEqual(far, 2.0, accuracy: 0.02, "the dunes keep their lift up to z12")
        XCTAssertEqual(VisualBudget.exaggeration(VisualContext(exploring: true, pitch: 0, zoom: 11)), 1.15, accuracy: 0.001, "flat: no lift")
        XCTAssertEqual(VisualBudget.exaggeration(VisualContext(driving: true, pitch: 62, zoom: 12)), 1.0, "true heights while driving")
        var prev = VisualBudget.exaggeration(VisualContext(exploring: true, pitch: 62, zoom: 10))
        for z in stride(from: 10.0, through: 17, by: 0.1) {
            let e = VisualBudget.exaggeration(VisualContext(exploring: true, pitch: 62, zoom: z))
            /* The fade to true heights spans one zoom level (and the terrain itself glides 400 ms). */
            XCTAssertLessThan(abs(e - prev), 0.16, "smooth in zoom")
            if z >= 12 { XCTAssertLessThanOrEqual(e, prev + 1e-9, "only ever comes down towards z13") }
            prev = e
        }
    }

    func testTrueHeightsFromZ13Everywhere() {
        for p in [0.0, 30, 62, 85] {
            for z in [13.0, 14, 15.8, 18] {
                XCTAssertEqual(VisualBudget.exaggeration(VisualContext(exploring: true, terrain3D: true, flying: true, pitch: p, zoom: z)), 1.0,
                               accuracy: 1e-9, "z\(z) pitch \(p)")
            }
        }
    }

    // MARK: cities

    func testNeverExaggeratedOverACity() {
        /* Al-Masjid al-Haram, Kingdom Centre, Madinah, Jeddah, Khobar, Abha, AlUla old town. */
        let cities: [(Double, Double)] = [(21.4225, 39.8262), (24.7114, 46.6744), (24.4672, 39.6111), (21.5433, 39.1728),
                                          (26.2794, 50.2083), (18.2164, 42.5053), (26.6150, 37.9150)]
        for (lat, lng) in cities {
            let u = UrbanAreas.weight(lat: lat, lng: lng)
            XCTAssertEqual(u, 1, "\(lat),\(lng) is a city")
            for z in [9.0, 11, 12, 14, 16] {
                let e = VisualBudget.exaggeration(VisualContext(exploring: true, terrain3D: true, pitch: 62, zoom: z, urban: u))
                XCTAssertEqual(e, 1.0, accuracy: 1e-9, "true heights over \(lat),\(lng) at z\(z)")
            }
        }
    }

    func testDesertDunesKeepTheirLift() {
        /* The Nafud, the Empty Quarter, the Riyadh dunes east of the city. */
        for (lat, lng) in [(28.0, 41.5), (20.5, 50.0), (25.12, 46.12)] {
            let u = UrbanAreas.weight(lat: lat, lng: lng)
            XCTAssertEqual(u, 0, "\(lat),\(lng) is open desert")
            XCTAssertEqual(VisualBudget.exaggeration(VisualContext(exploring: true, pitch: 62, zoom: 11, urban: u)), 2.0, accuracy: 0.001)
        }
    }

    func testCityEdgeBlendsWithoutAJump() {
        /* Walking east out of Riyadh's box (east edge 47.05) into the open. */
        var prev = UrbanAreas.weight(lat: 24.7, lng: 47.0)
        XCTAssertEqual(prev, 1)
        for i in 1...120 {
            let lng = 47.0 + Double(i) * 0.001
            let u = UrbanAreas.weight(lat: 24.7, lng: lng)
            XCTAssertLessThan(abs(u - prev), 0.06, "smooth across the edge")
            XCTAssertLessThanOrEqual(u, prev + 1e-12)
            prev = u
        }
        XCTAssertEqual(prev, 0, "~3 km out: open desert")
    }

    func testCityBuildingsOnlyOnSatelliteInACityNotWhileDriving() {
        let s = VisualEffectsSettings()
        let city = VisualContext(exploring: true, layer: .satellite, pitch: 58, zoom: 15.3, urban: 1)
        XCTAssertTrue(VisualBudget.resolve(s, city).buildings)
        var c = city
        c.urban = 0
        XCTAssertFalse(VisualBudget.resolve(s, c).buildings, "not in the desert")
        c = city
        c.driving = true
        XCTAssertFalse(VisualBudget.resolve(s, c).buildings, "not while driving")
        c = city
        c.lowPower = true
        XCTAssertFalse(VisualBudget.resolve(s, c).buildings, "not in Low Power Mode")
        c = city
        c.layer = .standard
        XCTAssertFalse(VisualBudget.resolve(s, c).buildings, "Standard draws its own")
        var off = s
        off.buildings = false
        XCTAssertFalse(VisualBudget.resolve(off, city).buildings, "its own switch")
        off = s
        off.master = false
        XCTAssertFalse(VisualBudget.resolve(off, city).buildings)
        /* Looking straight down the imagery's roofs stay; tilted, the buildings stand. */
        XCTAssertEqual(VisualBudget.buildingsOpacity(pitch: 0), 0)
        XCTAssertEqual(VisualBudget.buildingsOpacity(pitch: 58), 1, accuracy: 1e-9, "solid: no ghosted photo through the walls")
        let layer = CityBuildings.layer(id: "b", source: "s", opacity: 0.5)
        XCTAssertEqual(layer["type"] as? String, "fill-extrusion")
        XCTAssertEqual(layer["source-layer"] as? String, "building")
        XCTAssertEqual((layer["paint"] as? [String: Any])?["fill-extrusion-opacity"] as? Double, 0.5)
    }

    func testRealisticOfferedOnlyWhenTiltedOverACity() {
        XCTAssertTrue(CityBuildings.offerRealistic(pitch: 58, zoom: 15.3, urban: 1))
        XCTAssertFalse(CityBuildings.offerRealistic(pitch: 20, zoom: 15.3, urban: 1), "looking down: the imagery is fine")
        XCTAssertFalse(CityBuildings.offerRealistic(pitch: 58, zoom: 15.3, urban: 0), "the desert")
        XCTAssertFalse(CityBuildings.offerRealistic(pitch: 58, zoom: 10, urban: 1), "too far out")
    }

    func testSceneLightIsWarmByDayAndNeverNavyAtNight() {
        let golden = SceneLight.from(SunPosition(altitudeDeg: 4, azimuthDeg: 250, rising: false))
        XCTAssertGreaterThan(golden.ambient.r, golden.ambient.b + 40, "golden hour: warm ambient (no blue cast on red sand)")
        XCTAssertEqual(golden.direction[0], 250, accuracy: 0.1, "lit from the real sun's azimuth")
        XCTAssertGreaterThan(golden.direction[1], 80, "a low sun: a grazing light")
        let noon = SceneLight.from(SunPosition(altitudeDeg: 50, azimuthDeg: 180, rising: false))
        XCTAssertGreaterThanOrEqual(noon.ambient.r, noon.ambient.b)
        XCTAssertEqual(noon.direction[1], 40, accuracy: 0.1)
        let night = SceneLight.from(SunPosition(altitudeDeg: -30, azimuthDeg: 280, rising: false))
        XCTAssertLessThan(night.ambient.b - night.ambient.r, 60, "moonlight, not Standard's navy")
        XCTAssertGreaterThan(night.ambient.r, 90, "deep, not black")
        XCTAssertEqual(night.direction[0], HillshadeLight.nightDirection)
        /* Continuous through the day: no jump over a 1° change. */
        var prev = SceneLight.from(SunPosition(altitudeDeg: -20, azimuthDeg: 250, rising: false))
        for a in stride(from: -20.0, through: 40, by: 1) {
            let l = SceneLight.from(SunPosition(altitudeDeg: a, azimuthDeg: 250, rising: false))
            XCTAssertLessThan(abs(l.ambientIntensity - prev.ambientIntensity), 0.08, "≈ 4 minutes of real sun per degree")
            XCTAssertLessThan(abs(l.ambient.b - prev.ambient.b), 18)
            prev = l
        }
    }

    func testHillshadeShadowsStayWarmAndBroadPassIsSofter() {
        let dusk = HillshadeLight.from(SunPosition(altitudeDeg: 3, azimuthDeg: 250, rising: false), satellite: true)
        XCTAssertGreaterThan(dusk.shadow.r, dusk.shadow.b, "amber shadows, not teal")
        XCTAssertGreaterThan(dusk.highlight.r, dusk.highlight.b)
        XCTAssertLessThan(dusk.broad.shadow.a, dusk.shadow.a)
        XCTAssertEqual(dusk.broad.accent.a, 0)
    }

    func testDustHazeKeepsTheForegroundCrisp() {
        let now = Date()
        let w = SkyWeather(visibilityM: 1_800, dust: 1_400, pm10: 2_000, weatherCode: 0, precipitationMm: 0, fetchedAt: now)
        let s = SkyAtmosphere.make(sunAltitude: 3, weather: w, now: now)
        XCTAssertGreaterThanOrEqual(s.range[0], 0, "the haze starts at the map centre, not in front of the camera")
        XCTAssertGreaterThan(s.color.r, s.color.b + 50, "warm ochre dust, not a grey veil")
    }

    func testBudgetReducesInLowPowerDrivingAndReduceMotion() {
        let s = VisualEffectsSettings()
        let lean = VisualBudget.resolve(s, VisualContext(lowPower: true))
        XCTAssertFalse(lean.hillshade)
        XCTAssertFalse(lean.glow)
        XCTAssertFalse(lean.slope)
        XCTAssertFalse(lean.stars)
        XCTAssertEqual(lean.maxFps, 30)
        XCTAssertTrue(lean.sky, "the light preset costs nothing extra")
        let drive = VisualBudget.resolve(s, VisualContext(driving: true))
        XCTAssertFalse(drive.slope)
        XCTAssertFalse(drive.drone)
        XCTAssertTrue(drive.glow, "steady glow stays (never animated)")
        let rm = VisualBudget.resolve(s, VisualContext(reduceMotion: true))
        XCTAssertEqual(rm.transitionMs, 0)
        XCTAssertFalse(rm.orbit)
        XCTAssertFalse(VisualBudget.resolve(s, VisualContext(layer: .topo)).hillshade, "Outdoors has its own hillshade")
        XCTAssertEqual(VisualBudget.reducedNote(lowPower: true, driving: false), "مخفّفة الآن: وضع توفير الطاقة")
        XCTAssertNil(VisualBudget.reducedNote(lowPower: false, driving: false))
    }

    func testMasterOffRestoresTheLegacyMap() {
        var s = VisualEffectsSettings()
        s.master = false
        let e = VisualBudget.resolve(s, VisualContext(terrain3D: true, pitch: 62))
        XCTAssertFalse(e.managed)
        XCTAssertEqual(e.exaggeration, 1.6)
        XCTAssertFalse(e.hillshade || e.glow || e.slope || e.sky || e.atmosphere)
        s = VisualEffectsSettings()
        s.terrain = false
        XCTAssertEqual(VisualBudget.resolve(s, VisualContext(exploring: true, pitch: 62)).exaggeration, 1.15, "terrain switch off: as before")
    }

    func testGlowPaintIsSteadyAndEmissive() {
        let p = MapVisualsDirector.glowPaint(colour: "#2B7BF0", gradient: nil, night: true)
        XCTAssertEqual(p["line-emissive-strength"] as? Int, 1)
        XCTAssertEqual(p["line-color"] as? String, "#2B7BF0")
        XCTAssertGreaterThan(p["line-opacity"] as? Double ?? 0, MapVisualsDirector.glowPaint(colour: nil, gradient: nil, night: false)["line-opacity"] as? Double ?? 1)
        XCTAssertNil(p["line-opacity-transition"], "nothing animates")
        let g = MapVisualsDirector.glowPaint(colour: nil, gradient: ["interpolate", ["linear"], ["line-progress"], 0, "#fff", 1, "#000"], night: false)
        XCTAssertNotNil(g["line-gradient"])
        XCTAssertNil(g["line-color"])
    }

    func testFramePacingSummary() {
        let t = (0..<121).map { Double($0) / 60 }
        let s = FramePacing.summary(t)
        XCTAssertTrue(s.contains("avg=60.0fps"), s)
        XCTAssertTrue(s.contains("hitches=0"), s)
        XCTAssertEqual(FramePacing.summary([0, 1]), "")
    }
}
