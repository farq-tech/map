import XCTest
@testable import SaryAlbarq

/// «بريف المكان». Fixtures: real Open-Meteo forecast + air quality recorded for a desert
/// point north-east of Riyadh (25.19, 46.92) on 2026-11-05, during a real dust event
/// (≈1800 µg/m³), with apparent temperature, humidity and UV.
private enum Desert {
    static func data(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: PlaceBriefRulesTests.self).url(forResource: name, withExtension: "json"))
        return try Data(contentsOf: url)
    }
    static let hour0 = Date(timeIntervalSince1970: 1_793_865_600)
    static let currentAt = Date(timeIntervalSince1970: 1_793_866_500)
    static let point = LngLat(lng: 46.92, lat: 25.19)
    static let area = WeatherArea(cell: 25.19, lng: 46.92)
    static func report(air: Bool = true, fetchedAt: Date = currentAt) throws -> WeatherReport {
        try OpenMeteo.parse(forecast: data("openmeteo-forecast-desert-brief"), air: air ? data("openmeteo-air-desert-brief") : nil, area: area, fetchedAt: fetchedAt)
    }
}

private func hr(_ i: Int, _ f: (inout WeatherHour) -> Void = { _ in }) -> WeatherHour {
    var h = WeatherHour(time: Desert.hour0.addingTimeInterval(Double(i) * 3600), temperatureC: 26, precipitationMm: 0, precipitationProbability: 0,
                        weatherCode: 0, windKmh: 12, gustKmh: 20, windFromDeg: 315, visibilityM: 20_000, dust: 20, pm10: 30,
                        apparentC: 25, humidity: 30, uvIndex: 3)
    f(&h)
    return h
}

private func rep(_ f: (Int, inout WeatherHour) -> Void = { _, _ in }, fetchedAt: Date = Desert.hour0, air: Bool = true) -> WeatherReport {
    let hours = (0..<48).map { i in hr(i) { f(i, &$0) } }
    return WeatherReport(area: Desert.area, fetchedAt: fetchedAt, current: nil, hours: hours, airAvailable: air)
}

/// 10:30 on the fixture day (data fetched at 10:00 → fresh).
private let at = Desert.hour0.addingTimeInterval(30 * 60)

final class PlaceBriefRulesTests: XCTestCase {
    // MARK: request / cache cell

    func testTappedSpotIsRoundedToTheOneKilometreCell() {
        let a = WeatherArea(cell: 25.19347, lng: 46.92381)
        XCTAssertEqual(a.latText, "25.19")
        XCTAssertEqual(a.lngText, "46.92")
        XCTAssertEqual(a, WeatherArea(cell: 25.1949, lng: 46.9249), "taps within the same 0.01° cell share one request")
        XCTAssertNotEqual(a, WeatherArea(cell: 25.21, lng: 46.92))
        XCTAssertNotEqual(a.key, WeatherArea(point: 25.19, lng: 46.92).key, "the cell cache never collides with the destination cache")
        let url = OpenMeteo.forecastURL(a).absoluteString
        XCTAssertTrue(url.contains("latitude=25.19&"))
        XCTAssertFalse(url.contains("25.193"))
        XCTAssertTrue(url.contains("apparent_temperature") && url.contains("relative_humidity_2m") && url.contains("uv_index"))
    }

    func testDesertFixtureParsesTheBriefFields() throws {
        let r = try Desert.report()
        let c = try XCTUnwrap(r.current)
        XCTAssertEqual(c.temperatureC, 30.1)
        XCTAssertEqual(c.apparentC, 26.7)
        XCTAssertEqual(c.humidity, 20)
        XCTAssertEqual(c.uvIndex, 5.8, "current UV comes from the hour that contains now")
        XCTAssertEqual(c.dust, 1829)
        XCTAssertEqual(r.hours.count, 48)
        XCTAssertNotNil(r.hours[3].uvIndex)
    }

    func testPaidOpenMeteoHostAndKey() {
        let u = OpenMeteoProvider.keyed(OpenMeteo.forecastURL(Desert.area), "K")
        XCTAssertEqual(u.host, "customer-api.open-meteo.com")
        XCTAssertTrue(u.absoluteString.contains("apikey=K"))
        XCTAssertEqual(OpenMeteoProvider.keyed(OpenMeteo.forecastURL(Desert.area), nil).host, "api.open-meteo.com")
    }

    // MARK: formatting

    func testHeatIndex() throws {
        /* NWS table: 95 °F at 50 % → 105 °F (40.6 °C). */
        XCTAssertEqual(try XCTUnwrap(PlaceBriefRules.heatIndex(tempC: 35, humidity: 50)), 40.6, accuracy: 0.6)
        XCTAssertNil(PlaceBriefRules.heatIndex(tempC: 24, humidity: 80), "cool air: no heat index")
        XCTAssertNil(PlaceBriefRules.heatIndex(tempC: 40, humidity: 15), "dry desert air: no heat index")
        XCTAssertEqual(PlaceBriefRules.feelsLike(hr(0) { $0.apparentC = 44 }), 44, "the model's apparent temperature wins")
        XCTAssertNil(PlaceBriefRules.feelsLike(hr(0) { $0.apparentC = nil; $0.temperatureC = 30; $0.humidity = 10 }), "never the air temperature dressed up")
    }

    func testUVBandsAndText() {
        XCTAssertEqual(PlaceBriefRules.uvBand(1), "منخفض")
        XCTAssertEqual(PlaceBriefRules.uvBand(5.9), "متوسط")
        XCTAssertEqual(PlaceBriefRules.uvBand(7), "عالٍ")
        XCTAssertEqual(PlaceBriefRules.uvBand(9), "عالٍ جدًا")
        XCTAssertEqual(PlaceBriefRules.uvBand(11), "شديد")
        XCTAssertEqual(PlaceBriefRules.uvText(9.4), "٩ · عالٍ جدًا")
        XCTAssertEqual(PlaceBriefRules.uvText(nil), "غير متاح")
    }

    func testTerrainTextAndSlope() {
        XCTAssertEqual(PlaceBriefRules.elevationText(.unavailable), "الارتفاع غير متاح")
        XCTAssertEqual(PlaceBriefRules.elevationText(TerrainSample(elevationM: 702.4, slopeDeg: nil)), "الارتفاع ٧٠٢ م")
        XCTAssertNil(PlaceBriefRules.slopeText(TerrainSample(elevationM: 700, slopeDeg: nil)))
        XCTAssertEqual(PlaceBriefRules.slopeDeg(center: 700, east: 700, west: 700, north: 700, south: 700, spacingM: 60), 0)
        XCTAssertEqual(try XCTUnwrap(PlaceBriefRules.slopeDeg(center: 700, east: 706, west: 694, north: 700, south: 700, spacingM: 60)), 5.71, accuracy: 0.01)
        XCTAssertNil(PlaceBriefRules.slopeDeg(center: 700, east: nil, west: 694, north: 700, south: 700, spacingM: 60), "a missing DEM sample: no slope")
        XCTAssertEqual(PlaceBriefRules.slopeLabel(1), "مستوٍ تقريبًا")
        XCTAssertEqual(PlaceBriefRules.slopeLabel(14), "منحدر شديد")
        XCTAssertEqual(PlaceBriefRules.slopeText(TerrainSample(elevationM: 700, slopeDeg: 4.4)), "الميل نحو ٤° · ميل خفيف")
    }

    func testDistanceAndBearingFromMe() {
        XCTAssertNil(PlaceBriefRules.distanceText(from: nil, to: Desert.point))
        XCTAssertEqual(PlaceBriefRules.distanceText(from: Desert.point, to: LngLat(lng: 46.9201, lat: 25.1901)), "عند موقعك")
        let s = PlaceBriefRules.distanceText(from: LngLat(lng: 46.92, lat: 25.10), to: Desert.point)
        XCTAssertEqual(s, "على بعد \(SaryFormat.distance(meters: PlanGeo.meters(LngLat(lng: 46.92, lat: 25.10), Desert.point))) · شمال منك")
    }

    func testSunriseSunsetAndDaylight() throws {
        let riyadh = TimeZone(identifier: "Asia/Riyadh")!
        /* 2026-11-05 12:00 +03 at the desert point. */
        let noon = Date(timeIntervalSince1970: 1_793_869_200)
        let s = PlaceBriefRules.sun(now: noon, lat: 25.19, lng: 46.92)
        XCTAssertTrue(s.isDay)
        let rise = try XCTUnwrap(s.sunrise), set = try XCTUnwrap(s.sunset)
        XCTAssertLessThan(rise, noon)
        XCTAssertGreaterThan(set, noon)
        /* Solar noon there is ≈ 11:36 (+03, equation of time ≈ +16 min); day ≈ 11 h 07 min. */
        XCTAssertEqual(set.timeIntervalSince(rise) / 60, 667, accuracy: 4)
        XCTAssertEqual(WeatherFormat.clock(rise, timeZone: riyadh), "٦:٠٢ ص")
        XCTAssertEqual(WeatherFormat.clock(set, timeZone: riyadh), "٥:٠٩ م")
        XCTAssertTrue(PlaceBriefRules.daylightText(s, now: noon, timeZone: riyadh).hasPrefix("باقي ٥ س"))
        let night = PlaceBriefRules.sun(now: noon.addingTimeInterval(10 * 3600), lat: 25.19, lng: 46.92)
        XCTAssertFalse(night.isDay)
        XCTAssertEqual(PlaceBriefRules.daylightText(night, now: noon.addingTimeInterval(10 * 3600), timeZone: riyadh), "الشمس غاربة · الشروق ٦:٠٢ ص")
    }

    // MARK: camping / outing assessment

    func testCalmDayIsGoodAndSaysWhatWasChecked() {
        let a = PlaceBriefRules.assessment(rep(), now: at)
        XCTAssertEqual(a.level, .good)
        XCTAssertEqual(a.title, "مناسب للتخييم والطلعة")
        XCTAssertEqual(a.reasons, ["رياح ١٢ كم/س", "حرارة ٢٦°", "بلا غبار يُذكر", "لا مطر متوقع خلال ١٢ س"])
        XCTAssertNil(a.note)
    }

    func testStrongWindAbove35IsPoorWithTheNumber() {
        let a = PlaceBriefRules.assessment(rep { i, h in if i == 1 { h.windKmh = 38; h.gustKmh = 52 } }, now: at)
        XCTAssertEqual(a.level, .poor)
        XCTAssertEqual(a.reasons.first, "رياح قوية ٣٨ كم/س (هبّات ٥٢ كم/س) خلال ٣ س — فوق ٣٥ كم/س")
        let gusty = PlaceBriefRules.assessment(rep { _, h in h.windKmh = 20; h.gustKmh = 45 }, now: at)
        XCTAssertEqual(gusty.level, .caution)
        XCTAssertEqual(gusty.reasons.first, "رياح نشطة ٢٠ كم/س (هبّات ٤٥ كم/س)")
        let edge = PlaceBriefRules.assessment(rep { _, h in h.windKmh = 35; h.gustKmh = 39 }, now: at)
        XCTAssertNotEqual(edge.level, .poor, "the rule is «more than 35»")
    }

    func testHeatUsesFeelsLike() {
        let a = PlaceBriefRules.assessment(rep { _, h in h.temperatureC = 38; h.apparentC = 42 }, now: at)
        XCTAssertEqual(a.level, .poor)
        XCTAssertEqual(a.reasons.first, "حر شديد: يُحس كأنها ٤٢° — ٤٠° فأكثر")
        let warm = PlaceBriefRules.assessment(rep { _, h in h.temperatureC = 36; h.apparentC = nil; h.humidity = 10 }, now: at)
        XCTAssertEqual(warm.level, .caution)
        XCTAssertEqual(warm.reasons.first, "حر: الحرارة ٣٦°")
        let cold = PlaceBriefRules.assessment(rep { _, h in h.temperatureC = 3; h.apparentC = 0 }, now: at)
        XCTAssertEqual(cold.level, .caution)
        XCTAssertTrue(cold.reasons.contains("برد: ٣°"))
    }

    func testDustAndMissingAir() throws {
        let dusty = PlaceBriefRules.assessment(rep { _, h in h.dust = 420; h.pm10 = 600 }, now: at)
        XCTAssertEqual(dusty.level, .poor)
        XCTAssertTrue(dusty.reasons.contains("غبار متوسط (PM10 ٦٠٠)"))
        let coming = PlaceBriefRules.assessment(rep { i, h in if i == 2 { h.dust = 420; h.pm10 = 500 } }, now: at)
        XCTAssertTrue(coming.reasons.contains("غبار متوسط (PM10 ٥٠٠) خلال ٣ س"), "the worst hour's own PM10, and when: \(coming.reasons)")
        let noAir = PlaceBriefRules.assessment(rep(air: false), now: at)
        XCTAssertEqual(noAir.level, .good)
        XCTAssertEqual(noAir.reasons.last, "غير متاح: الغبار", "unknown dust is said, never «no dust»")
        let real = PlaceBriefRules.assessment(try Desert.report(), now: Desert.currentAt)
        XCTAssertEqual(real.level, .poor)
        XCTAssertTrue(real.reasons.contains { $0.hasPrefix("غبار كثيف") }, "\(real.reasons)")
    }

    func testRainStormsAndFloods() {
        let rain = PlaceBriefRules.assessment(rep { i, h in if i == 4 { h.precipitationProbability = 60 } }, now: at)
        XCTAssertEqual(rain.level, .caution)
        XCTAssertEqual(rain.reasons.first, "مطر متوقع خلال ٤ س · احتمال ٦٠٪")
        let flood = PlaceBriefRules.assessment(rep { i, h in if (3...6).contains(i) { h.precipitationMm = 2.5; h.precipitationProbability = 90 } }, now: at)
        XCTAssertEqual(flood.level, .poor)
        XCTAssertTrue(flood.reasons.contains { $0.hasPrefix("مطر قد يجري الأودية: ١٠ مم") }, "\(flood.reasons)")
        let storm = PlaceBriefRules.assessment(rep { i, h in if i == 8 { h.weatherCode = 95 } }, now: at)
        XCTAssertEqual(storm.level, .poor)
        XCTAssertTrue(storm.reasons.contains("عواصف رعدية متوقعة خلال ١٢ س"))
    }

    func testUVAndShortDaylightAreCautions() {
        let uv = PlaceBriefRules.assessment(rep { _, h in h.uvIndex = 9 }, now: at)
        XCTAssertEqual(uv.level, .caution)
        XCTAssertEqual(uv.reasons, ["أشعة شمس قوية (UV ٩) — ظل وماء"])
        let dusk = PlaceBriefRules.SunDay(sunrise: at.addingTimeInterval(-9 * 3600), sunset: at.addingTimeInterval(40 * 60), isDay: true)
        XCTAssertTrue(PlaceBriefRules.assessment(rep(), now: at, sun: dusk).reasons.contains("باقي أقل من ساعة على الغروب"))
    }

    func testStaleAndExpiredData() {
        let old = rep(fetchedAt: Desert.hour0.addingTimeInterval(-4 * 3600))
        let a = PlaceBriefRules.assessment(old, now: at)
        XCTAssertEqual(a.level, .good)
        XCTAssertEqual(a.note, "التقييم من توقعات قبل ٤ س — ليست قراءة حالية")
        let gone = PlaceBriefRules.assessment(old, now: Desert.hour0.addingTimeInterval(49 * 3600))
        XCTAssertEqual(gone.level, .unknown)
        XCTAssertTrue(gone.reasons.isEmpty)
    }

    // MARK: freshness / source line

    func testSourceLineNeverShowsStaleAsCurrent() {
        let w = PlaceWeather(report: rep(fetchedAt: at.addingTimeInterval(-5 * 60)), provider: .openMeteo)
        XCTAssertEqual(PlaceBriefRules.sourceLine(w, now: at, failed: nil).text, "المصدر: Open-Meteo · قبل ٥ د")
        XCTAssertFalse(PlaceBriefRules.sourceLine(w, now: at, failed: nil).stale)
        let old = PlaceWeather(report: rep(fetchedAt: at.addingTimeInterval(-3 * 3600)), provider: .openMeteo)
        let line = PlaceBriefRules.sourceLine(old, now: at, failed: .offline)
        XCTAssertTrue(line.stale)
        XCTAssertEqual(line.text, "المصدر: Open-Meteo · بيانات محفوظة قبل ٣ س — ليست حالية · بلا إنترنت")
        XCTAssertEqual(PlaceBriefRules.sourceLine(PlaceWeather(report: w.report, provider: .weatherKit), now: at, failed: nil).text, "المصدر: Apple Weather · قبل ٥ د")
    }

    func testPresenterPhases() throws {
        let offline = PlaceBriefPresenter.build(nil, loading: false, failed: .offline, point: Desert.point, now: at)
        XCTAssertEqual(offline.phase, .unavailable("الطقس غير متاح بدون إنترنت، ولا توجد قراءة محفوظة قريبة من هذه النقطة"))
        XCTAssertNotNil(offline.sunset, "sun times need no network")
        XCTAssertEqual(PlaceBriefPresenter.build(nil, loading: true, failed: nil, point: Desert.point, now: at).phase, .loading)

        let fresh = PlaceBriefPresenter.build(PlaceWeather(report: try Desert.report(), provider: .openMeteo), loading: false, failed: nil, point: Desert.point, now: Desert.currentAt)
        XCTAssertEqual(fresh.phase, .ready)
        XCTAssertEqual(fresh.nowLabel, "الآن")
        XCTAssertEqual(fresh.temp, "٣٠°")
        XCTAssertEqual(fresh.feelsLike, "يُحس كأنها ٢٧°")
        XCTAssertEqual(fresh.humidity, "الرطوبة ٢٠٪")
        XCTAssertEqual(fresh.dust, "غبار كثيف · PM10 ١٢٣٣ µg/m³")
        XCTAssertEqual(fresh.visibility, "قد تقل بسبب الغبار")
        XCTAssertEqual(fresh.hours.count, 12)
        XCTAssertEqual(fresh.hours.first?.label, "الآن")
        XCTAssertEqual(fresh.wind?.name, "رياح جنوبية")
        XCTAssertEqual(fresh.source, "المصدر: Open-Meteo · الآن")

        let stale = PlaceBriefPresenter.build(PlaceWeather(report: try Desert.report(), provider: .openMeteo), loading: false, failed: .offline,
                                              point: Desert.point, now: Desert.currentAt.addingTimeInterval(2 * 3600))
        XCTAssertEqual(stale.nowLabel, "متوقع لهذه الساعة", "older data is the forecast for this hour, never «الآن»")
        XCTAssertTrue(stale.stale)
        XCTAssertTrue(stale.offline)

        let expired = PlaceBriefPresenter.build(PlaceWeather(report: try Desert.report(), provider: .openMeteo), loading: false, failed: .offline,
                                                point: Desert.point, now: Desert.currentAt.addingTimeInterval(50 * 3600))
        if case .unavailable = expired.phase {} else { XCTFail("expired data must not be shown") }
        XCTAssertNil(expired.assessment)
    }

    func testCompactLine() throws {
        let ui = PlaceBriefPresenter.build(PlaceWeather(report: try Desert.report(), provider: .openMeteo), loading: false, failed: nil, point: Desert.point, now: Desert.currentAt)
        XCTAssertEqual(PlaceBriefPresenter.compactLine(ui), "٣٠° · رياح ٢٣ كم/س · غبار كثيف")
    }

    func testWeatherKitHasNoDustAndSaysSo() throws {
        var r = try Desert.report(air: false)
        r.airAvailable = false
        let ui = PlaceBriefPresenter.build(PlaceWeather(report: r, provider: .weatherKit), loading: false, failed: nil, point: Desert.point, now: Desert.currentAt)
        XCTAssertEqual(ui.dust, "الغبار غير متاح من Apple Weather")
        XCTAssertNil(ui.dustLevel)
    }

    // MARK: names / taps

    func testNamesFromSavedPlacesAndGeocoder() {
        let saved = [SavedPlace(id: "1", name: "مخيمنا", icon: .pin, lat: 25.1905, lng: 46.9205, createdAt: Date()),
                     SavedPlace(id: "2", name: "بعيد", icon: .pin, lat: 25.3, lng: 46.9, createdAt: Date())]
        XCTAssertEqual(PlaceBriefModel.knownName(nil, saved: saved, at: Desert.point)?.text, "مخيمنا")
        XCTAssertEqual(PlaceBriefModel.knownName("محطة", saved: saved, at: Desert.point)?.text, "محطة")
        XCTAssertNil(PlaceBriefModel.knownName(nil, saved: [saved[1]], at: Desert.point))
        XCTAssertEqual(AppleReverseGeocoder.name(areaOfInterest: "روضة خريم", subLocality: nil, locality: "رماح", admin: "الرياض")?.display, "روضة خريم")
        XCTAssertEqual(AppleReverseGeocoder.name(areaOfInterest: nil, subLocality: nil, locality: "رماح", admin: "منطقة الرياض")?.display, "قرب رماح، منطقة الرياض")
        XCTAssertNil(AppleReverseGeocoder.name(areaOfInterest: " ", subLocality: nil, locality: nil, admin: nil))
    }

    func testTapOpensOnlyWhenStoppedAndNotTwice() {
        let now = Date()
        XCTAssertTrue(PlaceBriefTapRule.shouldOpen(moving: false, navigating: false, modalOpen: false, picking: false, lastOpen: nil, now: now))
        XCTAssertFalse(PlaceBriefTapRule.shouldOpen(moving: true, navigating: false, modalOpen: false, picking: false, lastOpen: nil, now: now), "never auto-open while moving")
        XCTAssertFalse(PlaceBriefTapRule.shouldOpen(moving: false, navigating: true, modalOpen: false, picking: false, lastOpen: nil, now: now))
        XCTAssertFalse(PlaceBriefTapRule.shouldOpen(moving: false, navigating: false, modalOpen: true, picking: false, lastOpen: nil, now: now))
        XCTAssertFalse(PlaceBriefTapRule.shouldOpen(moving: false, navigating: false, modalOpen: false, picking: true, lastOpen: nil, now: now))
        XCTAssertFalse(PlaceBriefTapRule.shouldOpen(moving: false, navigating: false, modalOpen: false, picking: false, lastOpen: now.addingTimeInterval(-0.3), now: now), "debounced")
        XCTAssertTrue(PlaceBriefTapRule.shouldOpen(moving: false, navigating: false, modalOpen: false, picking: false, lastOpen: now.addingTimeInterval(-1), now: now))
    }
}

// MARK: - Cache, debounce, offline

private final class CountingProvider: WeatherProvider, @unchecked Sendable {
    let id: WeatherProviderID
    var fail: Error?
    private let lock = NSLock()
    private var _areas: [WeatherArea] = []
    var areas: [WeatherArea] { lock.lock(); defer { lock.unlock() }; return _areas }
    init(_ id: WeatherProviderID = .openMeteo, fail: Error? = nil) { self.id = id; self.fail = fail }
    func fetch(_ a: WeatherArea, now: Date) async throws -> WeatherReport {
        lock.lock(); _areas.append(a); lock.unlock()
        if let fail { throw fail }
        var r = rep(fetchedAt: now)
        r.area = a
        return r
    }
}

private struct NoNames: PlaceNaming {
    func name(for p: LngLat) async -> PlaceName? { nil }
}

@MainActor
final class PlaceBriefStoreTests: XCTestCase {
    private func cache() -> PlaceWeatherCache {
        PlaceWeatherCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent("place-brief-\(UUID().uuidString)", isDirectory: true))
    }

    private func model(_ p: CountingProvider, cache c: PlaceWeatherCache, now: @escaping () -> Date, debounceNs: UInt64 = 0) -> PlaceBriefModel {
        PlaceBriefModel(provider: FallbackWeatherProvider(providers: [p]), cache: c, limiter: PlaceWeatherLimiter(), namer: NoNames(), clock: now, debounceNs: debounceNs)
    }

    func testCacheRoundTripsOnDiskAndPrunes() {
        let c = cache()
        let w = PlaceWeather(report: rep(fetchedAt: at), provider: .openMeteo)
        c.save(w)
        let again = PlaceWeatherCache(directory: c.directory)
        XCTAssertEqual(again.load(Desert.area), w, "survives a relaunch (the desert, no signal)")
        again.prune(now: at.addingTimeInterval(4 * 86_400))
        XCTAssertNil(PlaceWeatherCache(directory: c.directory).load(Desert.area))
    }

    func testOneRequestPerCellWhileFresh() async {
        let p = CountingProvider()
        var now = at
        let m = model(p, cache: cache(), now: { now })
        m.load(Desert.point, knownName: nil)
        await m.settle()
        XCTAssertEqual(p.areas, [Desert.area])
        XCTAssertNotNil(m.weather)
        /* A nearby tap in the same ≈ 1 km cell, 10 min later: the cached answer, no request. */
        now = at.addingTimeInterval(10 * 60)
        m.load(LngLat(lng: 46.9231, lat: 25.1922), knownName: nil)
        await m.settle()
        XCTAssertEqual(p.areas.count, 1)
        /* 31 min later: refreshed. */
        now = at.addingTimeInterval(31 * 60)
        m.load(Desert.point, knownName: nil)
        await m.settle()
        XCTAssertEqual(p.areas.count, 2)
    }

    func testRapidTapsAreDebouncedToTheLastOne() async {
        let p = CountingProvider()
        let m = model(p, cache: cache(), now: { at }, debounceNs: 150_000_000)
        m.load(LngLat(lng: 46.50, lat: 25.00), knownName: nil)
        m.load(LngLat(lng: 46.60, lat: 25.00), knownName: nil)
        m.load(Desert.point, knownName: nil)
        await m.settle()
        XCTAssertEqual(p.areas, [Desert.area])
        XCTAssertEqual(m.area, Desert.area)
    }

    func testOfflineKeepsTheCachedReadingWithItsAgeAndBacksOff() async {
        let c = cache()
        c.save(PlaceWeather(report: rep(fetchedAt: at.addingTimeInterval(-2 * 3600)), provider: .openMeteo))
        let p = CountingProvider(fail: URLError(.notConnectedToInternet))
        var now = at
        let m = model(p, cache: c, now: { now })
        m.load(Desert.point, knownName: nil)
        XCTAssertNotNil(m.weather, "cached value shown at once")
        await m.settle()
        XCTAssertEqual(m.failure, .offline)
        XCTAssertEqual(m.weather?.report.fetchedAt, at.addingTimeInterval(-2 * 3600), "kept, with its real age")
        let ui = PlaceBriefPresenter.build(m.weather, loading: m.loading, failed: m.failure, point: Desert.point, now: now)
        XCTAssertEqual(ui.nowLabel, "متوقع لهذه الساعة")
        XCTAssertTrue(ui.source.contains("ليست حالية"))
        /* Retry only after 5 min. */
        now = at.addingTimeInterval(2 * 60)
        m.load(Desert.point, knownName: nil, force: false)
        await m.settle()
        XCTAssertEqual(p.areas.count, 1)
        now = at.addingTimeInterval(6 * 60)
        p.fail = nil
        m.load(Desert.point, knownName: nil)
        await m.settle()
        XCTAssertEqual(p.areas.count, 2)
        XCTAssertNil(m.failure)
        XCTAssertEqual(m.weather?.report.fetchedAt, now)
    }

    func testNoCacheOfflineSaysUnavailable() async {
        let p = CountingProvider(fail: URLError(.notConnectedToInternet))
        let m = model(p, cache: cache(), now: { at })
        m.load(Desert.point, knownName: nil)
        await m.settle()
        XCTAssertNil(m.weather)
        let ui = PlaceBriefPresenter.build(m.weather, loading: m.loading, failed: m.failure, point: Desert.point, now: at)
        XCTAssertEqual(ui.phase, .unavailable("الطقس غير متاح بدون إنترنت، ولا توجد قراءة محفوظة قريبة من هذه النقطة"))
    }

    func testFallbackProviderRecordsWhoAnswered() async throws {
        let kit = CountingProvider(.weatherKit, fail: URLError(.userAuthenticationRequired))
        let om = CountingProvider(.openMeteo)
        let w = try await FallbackWeatherProvider(providers: [kit, om]).fetch(Desert.area, now: at)
        XCTAssertEqual(w.provider, .openMeteo)
        XCTAssertEqual(kit.areas.count, 1)
        XCTAssertEqual(WeatherFetchFailure.of(URLError(.notConnectedToInternet)), .offline)
        XCTAssertEqual(WeatherFetchFailure.of(URLError(.badServerResponse)), .server)
    }
}
