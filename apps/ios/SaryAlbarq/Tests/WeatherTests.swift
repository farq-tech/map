import XCTest
@testable import SaryAlbarq

/// Fixtures in Tests/Fixtures: real Open-Meteo responses recorded for Riyadh
/// (24.7, 46.7) on 2026-11-04 — a real dust event (≈3000 µg/m³) — and a rain
/// variant derived from the same forecast (hours 3…8 rainy and gusty, one null).
private enum Fixture {
    static func data(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: WeatherParsingTests.self).url(forResource: name, withExtension: "json"))
        return try Data(contentsOf: url)
    }
    static let hour0 = Date(timeIntervalSince1970: 1_793_793_600)
    static let currentAt = Date(timeIntervalSince1970: 1_793_794_500)
    static let area = WeatherArea(around: 24.71, lng: 46.68)

    static func report(rain: Bool = false, air: Bool = true, fetchedAt: Date = currentAt) throws -> WeatherReport {
        try OpenMeteo.parse(forecast: data(rain ? "openmeteo-forecast-rain-derived" : "openmeteo-forecast-riyadh"),
                            air: air ? data("openmeteo-air-riyadh") : nil, area: area, fetchedAt: fetchedAt)
    }
}

private func hour(_ i: Int, from: Date = Fixture.hour0, _ f: (inout WeatherHour) -> Void = { _ in }) -> WeatherHour {
    var h = WeatherHour(time: from.addingTimeInterval(Double(i) * 3600), temperatureC: 25, precipitationMm: 0, precipitationProbability: 0,
                        weatherCode: 0, windKmh: 10, gustKmh: 15, windFromDeg: 0, visibilityM: 20_000, dust: 20, pm10: 30)
    f(&h)
    return h
}

private func report(_ hours: [WeatherHour], fetchedAt: Date = Fixture.hour0, air: Bool = true) -> WeatherReport {
    WeatherReport(area: Fixture.area, fetchedAt: fetchedAt, current: nil, hours: hours, airAvailable: air)
}

private func calm(_ n: Int = 48, _ f: (Int, inout WeatherHour) -> Void = { _, _ in }) -> [WeatherHour] {
    (0..<n).map { i in hour(i) { f(i, &$0) } }
}

// MARK: - Parsing

final class WeatherParsingTests: XCTestCase {
    func testParsesRecordedForecastAndAirQuality() throws {
        let r = try Fixture.report()
        XCTAssertEqual(r.hours.count, 48)
        XCTAssertTrue(r.airAvailable)
        let c = try XCTUnwrap(r.current)
        XCTAssertEqual(c.time, Fixture.currentAt)
        XCTAssertEqual(c.temperatureC, 32.9)
        XCTAssertEqual(c.windKmh, 6.9)
        XCTAssertEqual(c.gustKmh, 23.0)
        XCTAssertEqual(c.windFromDeg, 157)
        XCTAssertEqual(c.weatherCode, 0)
        XCTAssertEqual(c.visibilityM, 20_080)
        XCTAssertEqual(c.dust, 2973)
        XCTAssertEqual(c.pm10, 1616.8)
        XCTAssertEqual(r.hours[0].time, Fixture.hour0)
        XCTAssertEqual(r.hours[1].dust, 3118, "dust merged into the forecast hour with the same timestamp")
        XCTAssertEqual(r.hours[0].precipitationProbability, 0)
        XCTAssertEqual(zip(r.hours, r.hours.dropFirst()).allSatisfy { $0.time < $1.time }, true)
    }

    func testNullsStayUnknownAndAirFailureIsNotNoDust() throws {
        let r = try Fixture.report(rain: true, air: false)
        XCTAssertNil(r.hours[10].temperatureC)
        XCTAssertFalse(r.airAvailable)
        XCTAssertNil(r.hours[0].dust)
        let ui = WeatherPresenter.card(title: "", report: r, refreshing: false, failed: false, now: Fixture.currentAt)
        XCTAssertNil(ui.dust)
        XCTAssertEqual(ui.dustText, "الغبار غير متاح")
    }

    /// Build 36 item 12: when the numbers came, and where the forecast is really for.
    func testCardSaysWhenAndWhereTheForecastIsFor() throws {
        let r = try Fixture.report()
        XCTAssertEqual(r.modelLat, 24.710016, "Open-Meteo answers with the grid cell it used")
        XCTAssertEqual(r.modelLng, 46.688103)
        XCTAssertEqual(r.forecastPoint.lat, 24.710016)
        let riyadh = TimeZone(identifier: "Asia/Riyadh")!
        XCTAssertEqual(WeatherProvenance.updated(Fixture.currentAt, now: Fixture.currentAt.addingTimeInterval(180), timeZone: riyadh),
                       "آخر تحديث ٣:١٥ م (قبل ٣ د)")
        let me = WeatherReference(point: Geo.LatLng(lat: 24.73, lng: 46.70), label: "منك")
        XCTAssertEqual(WeatherProvenance.point(r, reference: me), "نقطة التوقع على بعد ٢٫٥ كم منك · منطقة تقريبية",
                       "the outing area is rounded for privacy, and says so")
        let here = WeatherReference(point: Geo.LatLng(lat: 24.7101, lng: 46.6882), label: "من الوجهة")
        XCTAssertEqual(WeatherProvenance.point(r, reference: here), "نقطة التوقع على بعد أقل من ١ كم من الوجهة · منطقة تقريبية")
        XCTAssertNil(WeatherProvenance.point(r, reference: nil))
        let ui = WeatherPresenter.card(title: "", report: r, refreshing: false, failed: false, now: Fixture.currentAt, reference: me)
        XCTAssertTrue(ui.updated.hasPrefix("آخر تحديث "), ui.updated)
        XCTAssertEqual(ui.forecastPoint, "نقطة التوقع على بعد ٢٫٥ كم منك · منطقة تقريبية")
        /* No grid cell from the provider (Apple Weather, an old cache): the point we asked for. */
        var asked = r
        asked.modelLat = nil
        XCTAssertEqual(asked.forecastPoint, r.area.coordinate)
    }

    func testBrokenJSONThrows() {
        XCTAssertThrowsError(try OpenMeteo.parse(forecast: Data("{\"hourly\":{\"time\":[]}}".utf8), air: nil, area: Fixture.area, fetchedAt: Date()))
        XCTAssertThrowsError(try OpenMeteo.parse(forecast: Data("<html>".utf8), air: nil, area: Fixture.area, fetchedAt: Date()))
    }

    func testRecordedDustEventRaisesHeavyDustOnly() throws {
        let r = try Fixture.report()
        let a = WeatherAlerts.evaluate(r, now: Fixture.currentAt.addingTimeInterval(60), wadi: WadiContext(distanceM: 200, name: nil))
        XCTAssertEqual(a.map(\.kind), [.dust])
        XCTAssertEqual(a.first?.level, 2)
        XCTAssertEqual(a.first?.title, "غبار كثيف يحجب الرؤية")
    }

    func testDerivedRainFixtureRaisesWindRainAndFloodNearWadi() throws {
        let r = try Fixture.report(rain: true)
        /* 90 min after the recorded hour: the gusty, rainy hours (3…8) are inside the windows. */
        let now = Fixture.hour0.addingTimeInterval(5_400)
        XCTAssertTrue(WeatherRules.floodRain(r, now: now))
        let kinds = WeatherAlerts.evaluate(r, now: now, wadi: WadiContext(distanceM: 400, name: nil)).map(\.kind)
        XCTAssertEqual(Set(kinds), [.wind, .dust, .rain, .flood])
        let far = WeatherAlerts.evaluate(r, now: now, wadi: WadiContext(distanceM: 4_000, name: nil)).map(\.kind)
        XCTAssertFalse(far.contains(.flood))
        XCTAssertFalse(WeatherAlerts.evaluate(r, now: now, wadi: nil).map(\.kind).contains(.flood))
    }
}

// MARK: - Privacy (what leaves the phone)

final class WeatherAreaTests: XCTestCase {
    func testOutingAreaIsRoundedToATenthOfADegree() {
        let a = WeatherArea(around: 24.71284, lng: 46.67395)
        XCTAssertEqual(a.latText, "24.7")
        XCTAssertEqual(a.lngText, "46.7")
        XCTAssertEqual(WeatherArea(around: 24.749, lng: 46.651), WeatherArea(around: 24.71, lng: 46.70), "same 0.1° cell, same request")
        let q = URLComponents(url: OpenMeteo.forecastURL(a), resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(q.first { $0.name == "latitude" }?.value, "24.7")
        XCTAssertEqual(q.first { $0.name == "longitude" }?.value, "46.7")
        let url = OpenMeteo.forecastURL(a).absoluteString + OpenMeteo.airURL(a).absoluteString
        XCTAssertFalse(url.contains("24.71"))
        XCTAssertFalse(url.contains("46.67"))
        XCTAssertTrue(OpenMeteo.forecastURL(a).absoluteString.contains("forecast_hours=48"))
        XCTAssertTrue(OpenMeteo.airURL(a).absoluteString.contains("dust"))
        XCTAssertFalse(url.contains("apikey"))
    }

    func testChosenPointKeepsItsCoordinates() {
        let p = WeatherArea(point: 25.771234, lng: 45.104321)
        XCTAssertEqual(p.latText, "25.7712")
        XCTAssertEqual(p.lngText, "45.1043")
        XCTAssertNotEqual(p.key, WeatherArea(around: 25.77, lng: 45.10).key)
    }
}

// MARK: - Thresholds

final class WeatherThresholdTests: XCTestCase {
    let now = Fixture.hour0.addingTimeInterval(600)

    func testDustLevels() {
        XCTAssertNil(DustLevel.of(nil))
        XCTAssertEqual(DustLevel.of(99), .clear)
        XCTAssertEqual(DustLevel.of(100), .light)
        XCTAssertEqual(DustLevel.of(299), .light)
        XCTAssertEqual(DustLevel.of(300), .moderate)
        XCTAssertEqual(DustLevel.of(999), .moderate)
        XCTAssertEqual(DustLevel.of(1000), .heavy)
        XCTAssertEqual(DustLevel.light.label, "غبار خفيف")
        XCTAssertEqual(DustLevel.moderate.label, "غبار متوسط")
        XCTAssertEqual(DustLevel.heavy.label, "غبار كثيف")
    }

    func testWindLevels() {
        XCTAssertEqual(WeatherRules.windLevel(hour(0) { $0.windKmh = 39; $0.gustKmh = 59 }), 0)
        XCTAssertEqual(WeatherRules.windLevel(hour(0) { $0.windKmh = 40; $0.gustKmh = 45 }), 1)
        XCTAssertEqual(WeatherRules.windLevel(hour(0) { $0.windKmh = 20; $0.gustKmh = 60 }), 1)
        XCTAssertEqual(WeatherRules.windLevel(hour(0) { $0.windKmh = 60 }), 2)
        XCTAssertEqual(WeatherRules.windLevel(hour(0) { $0.gustKmh = 80 }), 2)
    }

    func testCalmDayRaisesNothing() {
        XCTAssertEqual(WeatherAlerts.evaluate(report(calm()), now: now, wadi: WadiContext(distanceM: 50, name: nil)), [])
    }

    func testStrongWindOnlyInsideTheNextThreeHours() {
        let later = report(calm { i, h in if i == 6 { h.gustKmh = 70 } })
        XCTAssertEqual(WeatherAlerts.evaluate(later, now: now, wadi: nil), [])
        let soon = report(calm { i, h in if i == 2 { h.gustKmh = 70 } })
        let a = WeatherAlerts.evaluate(soon, now: now, wadi: nil)
        XCTAssertEqual(a.map(\.kind), [.wind])
        XCTAssertEqual(a[0].title, "رياح قوية")
        XCTAssertTrue(a[0].detail.contains("٧٠ كم/س"))
        XCTAssertTrue(a[0].detail.contains("خلال ٢ س"))
        let severe = WeatherAlerts.evaluate(report(calm { i, h in if i == 0 { h.windKmh = 62 } }), now: now, wadi: nil)
        XCTAssertEqual(severe.first?.title, "رياح شديدة")
        XCTAssertEqual(severe.first?.level, 2)
    }

    func testDustAlertNeedsModerateOrLightWithLowVisibility() {
        XCTAssertEqual(WeatherAlerts.evaluate(report(calm { _, h in h.dust = 150 }), now: now, wadi: nil), [])
        let lowVis = WeatherAlerts.evaluate(report(calm { _, h in h.dust = 150; h.visibilityM = 3_000 }), now: now, wadi: nil)
        XCTAssertEqual(lowVis.map(\.kind), [.dust])
        XCTAssertEqual(lowVis.first?.title, "غبار خفيف يقلل الرؤية")
        XCTAssertEqual(WeatherAlerts.evaluate(report(calm { _, h in h.dust = 400 }), now: now, wadi: nil).first?.title, "غبار متوسط يقلل الرؤية")
    }

    func testRainExpectedWithinTwelveHours() {
        XCTAssertEqual(WeatherAlerts.evaluate(report(calm { i, h in if i == 13 { h.precipitationProbability = 90 } }), now: now, wadi: nil), [])
        let a = WeatherAlerts.evaluate(report(calm { i, h in if i == 5 { h.precipitationProbability = 60 } }), now: now, wadi: nil)
        XCTAssertEqual(a.map(\.kind), [.rain])
        XCTAssertTrue(a[0].detail.contains("٦٠٪"))
        XCTAssertTrue(WeatherRules.rainExpected(hour(0) { $0.precipitationMm = 0.5 }))
        XCTAssertFalse(WeatherRules.rainExpected(hour(0) { $0.precipitationMm = 0.4; $0.precipitationProbability = 49 }))
    }

    func testFloodNeedsHeavyEnoughRainAndAWadiNearby() {
        let light = report(calm { i, h in if i < 4 { h.precipitationMm = 1; h.precipitationProbability = 80 } }) // 4 mm, no hour ≥ 2
        XCTAssertFalse(WeatherRules.floodRain(light, now: now))
        XCTAssertFalse(WeatherAlerts.evaluate(light, now: now, wadi: WadiContext(distanceM: 100, name: nil)).map(\.kind).contains(.flood))
        let total = report(calm { i, h in if i < 5 { h.precipitationMm = 1 } }) // 5 mm in 24 h
        XCTAssertTrue(WeatherRules.floodRain(total, now: now))
        let burst = report(calm { i, h in if i == 20 { h.precipitationMm = 2 } })
        XCTAssertTrue(WeatherRules.floodRain(burst, now: now))
        let beyond = report(calm { i, h in if i == 30 { h.precipitationMm = 20 } })
        XCTAssertFalse(WeatherRules.floodRain(beyond, now: now), "only the next 24 h")

        let near = WeatherAlerts.evaluate(total, now: now, wadi: WadiContext(distanceM: 1_000, name: nil))
        let flood = try? XCTUnwrap(near.first { $0.kind == .flood })
        XCTAssertEqual(flood?.title, "انتبهوا من السيول في الشعبان والأودية")
        XCTAssertEqual(flood?.level, 1)
        XCTAssertTrue(flood?.detail.contains("تقدير، تابع تحذيرات المركز الوطني للأرصاد") == true)
        XCTAssertFalse(WeatherAlerts.evaluate(total, now: now, wadi: WadiContext(distanceM: 1_001, name: nil)).map(\.kind).contains(.flood))
        let inside = WeatherAlerts.evaluate(total, now: now, wadi: WadiContext(distanceM: 120, name: nil)).first { $0.kind == .flood }
        XCTAssertEqual(inside?.level, 2)
        XCTAssertTrue(inside?.detail.hasPrefix("أنتم في مجرى وادٍ") == true)
    }

    func testOldDataRaisesNoAlerts() {
        let windy = calm { _, h in h.gustKmh = 90 }
        XCTAssertFalse(WeatherAlerts.evaluate(report(windy, fetchedAt: now.addingTimeInterval(-2 * 3600)), now: now, wadi: nil).isEmpty)
        XCTAssertEqual(WeatherAlerts.evaluate(report(windy, fetchedAt: now.addingTimeInterval(-3 * 3600 - 1)), now: now, wadi: nil), [])
    }

    func testDestinationAlertsAreLabelled() {
        let a = WeatherAlerts.evaluate(report(calm { _, h in h.gustKmh = 65 }), now: now, wadi: nil, forDestination: true)
        XCTAssertEqual(a.first?.title, "في الوجهة: رياح قوية")
        XCTAssertEqual(a.first?.id, "weather-dest:wind")
    }

    func testRateLimitPerKindWithEscalation() {
        var g = WeatherAlertGate()
        let strong = WeatherAlertUI(kind: .wind, forDestination: false, level: 1, title: "", detail: "")
        let severe = WeatherAlertUI(kind: .wind, forDestination: false, level: 2, title: "", detail: "")
        let dust = WeatherAlertUI(kind: .dust, forDestination: false, level: 1, title: "", detail: "")
        let dest = WeatherAlertUI(kind: .wind, forDestination: true, level: 1, title: "", detail: "")
        XCTAssertTrue(g.admit(strong, now: now))
        XCTAssertFalse(g.admit(strong, now: now.addingTimeInterval(60)))
        XCTAssertTrue(g.admit(dust, now: now.addingTimeInterval(60)), "other kinds are independent")
        XCTAssertTrue(g.admit(dest, now: now.addingTimeInterval(60)), "the destination is a separate alert")
        XCTAssertTrue(g.admit(severe, now: now.addingTimeInterval(120)), "it got worse: alert again")
        XCTAssertFalse(g.admit(strong, now: now.addingTimeInterval(600)), "back to strong inside the window: quiet")
        XCTAssertFalse(g.admit(severe, now: now.addingTimeInterval(3 * 3600)))
        XCTAssertTrue(g.admit(severe, now: now.addingTimeInterval(3 * 3600 + 121)))
    }

    func testGatePersistsPerOuting() {
        let d = UserDefaults(suiteName: "weather-gate-\(UUID().uuidString)")!
        var g = WeatherAlertGate()
        _ = g.admit(WeatherAlertUI(kind: .rain, forDestination: false, level: 1, title: "", detail: ""), now: now)
        g.save(outing: "o1", defaults: d)
        XCTAssertEqual(WeatherAlertGate.load(outing: "o1", defaults: d), g)
        XCTAssertEqual(WeatherAlertGate.load(outing: "o2", defaults: d), WeatherAlertGate())
    }
}

// MARK: - Presentation

final class WeatherPresenterTests: XCTestCase {
    func testFreshDataShowsTheModelValueAsNow() throws {
        let r = try Fixture.report()
        let ui = WeatherPresenter.card(title: "t", report: r, refreshing: false, failed: false, now: Fixture.currentAt.addingTimeInterval(600))
        XCTAssertEqual(ui.phase, .ready)
        XCTAssertEqual(ui.nowLabel, "الآن")
        XCTAssertEqual(ui.temp, "٣٣°")
        XCTAssertFalse(ui.stale)
        XCTAssertEqual(ui.dust, .heavy)
        XCTAssertEqual(ui.condition, "غبار كثيف", "dust wins over «صحو»")
        XCTAssertEqual(ui.visibility, "قد تقل بسبب الغبار", "the model's 20 km visibility ignores dust")
        XCTAssertEqual(ui.wind?.name, "رياح جنوبية شرقية")
        XCTAssertEqual(ui.wind?.speed, "٧ كم/س")
        XCTAssertEqual(ui.updated, "آخر تحديث ٣:١٥ م (قبل ١٠ د)")
        XCTAssertEqual(ui.hours.first?.label, "هذه الساعة")
        XCTAssertEqual(ui.rainText, "لا مطر متوقع خلال ١٢ س")
    }

    func testOldDataIsNeverShownAsNow() throws {
        let r = try Fixture.report()
        let now = Fixture.currentAt.addingTimeInterval(3 * 3600)
        let ui = WeatherPresenter.card(title: "t", report: r, refreshing: false, failed: true, now: now)
        XCTAssertEqual(ui.nowLabel, "متوقع لهذه الساعة")
        XCTAssertTrue(ui.stale)
        XCTAssertTrue(ui.offline)
        XCTAssertEqual(ui.updated, "آخر تحديث ٣:١٥ م (قبل ٣ س)")
        let h = try XCTUnwrap(WeatherRules.hour(containing: now, in: r))
        XCTAssertEqual(ui.temp, WeatherFormat.temp(h.temperatureC), "the forecast hour, not the old «current» value")
    }

    func testExpiredDataShowsNothingCurrent() throws {
        let r = try Fixture.report()
        let ui = WeatherPresenter.card(title: "t", report: r, refreshing: false, failed: true, now: Fixture.hour0.addingTimeInterval(49 * 3600))
        guard case .unavailable = ui.phase else { return XCTFail("expired data must not look current") }
        XCTAssertEqual(WeatherFreshness.of(r, now: Fixture.hour0.addingTimeInterval(49 * 3600)), .expired)
        XCTAssertNil(WeatherRules.nowValue(r, now: Fixture.hour0.addingTimeInterval(49 * 3600)))
    }

    func testNoDataStates() {
        XCTAssertEqual(WeatherPresenter.card(title: "t", report: nil, refreshing: true, failed: false, now: Date()).phase, .loading)
        guard case .unavailable = WeatherPresenter.card(title: "t", report: nil, refreshing: false, failed: true, now: Date()).phase else { return XCTFail() }
    }

    func testWindArrowPointsDownwindAndNamesTheSource() {
        XCTAssertEqual(WeatherRules.windArrowDeg(from: 0), 180)
        XCTAssertEqual(WeatherRules.windArrowDeg(from: 315), 135)
        XCTAssertEqual(WeatherRules.windArrowDeg(from: 200), 20)
        XCTAssertEqual(WeatherRules.windName(from: 315), "شمالية غربية")
        XCTAssertEqual(WeatherRules.windName(from: 350), "شمالية")
        XCTAssertEqual(WeatherRules.windName(from: 90), "شرقية")
        XCTAssertEqual(WeatherRules.windName(from: -45), "شمالية غربية")
    }

    func testArabicFormatting() {
        XCTAssertEqual(WeatherFormat.mm(5), "٥ مم")
        XCTAssertEqual(WeatherFormat.mm(1.44), "١٫٤ مم")
        XCTAssertEqual(WeatherFormat.visibility(20_000), "أكثر من ١٠ كم")
        XCTAssertEqual(WeatherFormat.visibility(1_800), "١٫٨ كم")
        let tz = TimeZone(identifier: "Asia/Riyadh")!
        XCTAssertEqual(WeatherFormat.hour(Date(timeIntervalSince1970: 1_793_793_600), timeZone: tz), "٣ م") // 12:00 UTC = 15:00 Riyadh
        XCTAssertEqual(WeatherFormat.clock(Date(timeIntervalSince1970: 1_793_793_600 + 1800), timeZone: tz), "٣:٣٠ م")
        XCTAssertEqual(WeatherAlerts.when(Fixture.hour0, now: Fixture.hour0), "الآن")
        XCTAssertEqual(WeatherAlerts.when(Fixture.hour0.addingTimeInterval(1800), now: Fixture.hour0), "خلال ساعة")
    }

    func testArrivalUsesRecentSpeedOrSaysItAssumed() throws {
        let from = Geo.LatLng(lat: 24.7, lng: 46.7)
        let to = Geo.LatLng(lat: 24.7 + 50_000 / 111_195, lng: 46.7) // 50 km north
        let assumed = ArrivalEstimate.estimate(from: from, to: to, recentKmh: 2, departure: Fixture.hour0)
        XCTAssertTrue(assumed.assumedSpeed)
        XCTAssertEqual(assumed.eta.timeIntervalSince(Fixture.hour0), 3600, accuracy: 30)
        let real = ArrivalEstimate.estimate(from: from, to: to, recentKmh: 100, departure: Fixture.hour0)
        XCTAssertFalse(real.assumedSpeed)
        XCTAssertEqual(real.eta.timeIntervalSince(Fixture.hour0), 1800, accuracy: 30)

        let fixes = (0...10).map { i in DeviceFix(lat: 24.7 + Double(i) * 100 / 111_195, lng: 46.7, accuracy: 5, heading: nil, speed: nil, atMs: Double(i) * 6_000) }
        XCTAssertEqual(try XCTUnwrap(ArrivalEstimate.recentSpeedKmh(fixes)), 60, accuracy: 0.5) // 1 km per minute
        XCTAssertNil(ArrivalEstimate.recentSpeedKmh(Array(fixes.prefix(3))), "under a minute of fixes")

        let r = try Fixture.report()
        let ui = WeatherPresenter.arrival(ArrivalEstimate.estimate(from: from, to: to, recentKmh: nil, departure: Fixture.currentAt), report: r, now: Fixture.currentAt)
        XCTAssertTrue(ui.basis.contains("بافتراض ٥٠ كم/س"))
        XCTAssertTrue(ui.basis.contains("٥٠ كم بخط مستقيم"))
        XCTAssertNotNil(ui.hour)
        let late = WeatherPresenter.arrival(ArrivalEstimate.estimate(from: from, to: to, recentKmh: nil, departure: Fixture.hour0.addingTimeInterval(48 * 3600)), report: r, now: Fixture.currentAt)
        XCTAssertNil(late.hour)
        XCTAssertEqual(late.condition, "وقت الوصول بعد نهاية التوقعات المتاحة")
    }
}

// MARK: - Cache / offline

private final class FakeTransport: WeatherTransport, @unchecked Sendable {
    var fail = false
    var failAir = false
    private let lock = NSLock()
    private var _calls: [URL] = []
    /* The store fetches forecast and air concurrently: record under a lock. */
    var calls: [URL] { lock.lock(); defer { lock.unlock() }; return _calls }
    let forecast: Data
    let air: Data
    init() throws {
        forecast = try Fixture.data("openmeteo-forecast-riyadh")
        air = try Fixture.data("openmeteo-air-riyadh")
    }
    func data(from url: URL) async throws -> Data {
        lock.lock(); _calls.append(url); lock.unlock()
        if fail { throw URLError(.notConnectedToInternet) }
        if url.host?.hasPrefix("air-quality") == true {
            if failAir { throw URLError(.timedOut) }
            return air
        }
        return forecast
    }
}

@MainActor
final class WeatherCacheTests: XCTestCase {
    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("weather-tests-\(UUID().uuidString)", isDirectory: true)
    }

    func testFetchSavesAndSkipsTheNetworkWhileFresh() async throws {
        let t = try FakeTransport()
        var now = Fixture.currentAt
        let cache = WeatherCache(directory: tempDir())
        let s = WeatherStore(transport: t, cache: cache, clock: { now })
        await s.update(Fixture.area)
        XCTAssertEqual(t.calls.count, 2)
        XCTAssertEqual(s.report?.fetchedAt, Fixture.currentAt)
        XCTAssertNotNil(cache.report(Fixture.area))
        now = now.addingTimeInterval(29 * 60)
        await s.update(Fixture.area)
        XCTAssertEqual(t.calls.count, 2, "younger than 30 min: no request")
        now = now.addingTimeInterval(2 * 60)
        await s.update(Fixture.area)
        XCTAssertEqual(t.calls.count, 4)
    }

    func testOfflineKeepsTheLastReportWithItsRealAgeAndBacksOff() async throws {
        let t = try FakeTransport()
        let dir = tempDir()
        var now = Fixture.currentAt
        await WeatherStore(transport: t, cache: WeatherCache(directory: dir), clock: { now }).update(Fixture.area)

        /* App restarted in the desert, no signal, 2 h later. */
        t.fail = true
        now = now.addingTimeInterval(2 * 3600)
        let s = WeatherStore(transport: t, cache: WeatherCache(directory: dir), clock: { now })
        await s.update(Fixture.area)
        XCTAssertTrue(s.lastFailed)
        XCTAssertEqual(s.report?.fetchedAt, Fixture.currentAt, "the cached report keeps its own time")
        let ui = WeatherPresenter.card(title: "", report: s.report, refreshing: false, failed: s.lastFailed, now: now)
        XCTAssertEqual(ui.nowLabel, "متوقع لهذه الساعة")
        XCTAssertEqual(ui.updated, "آخر تحديث ٣:١٥ م (قبل ٢ س)")
        XCTAssertTrue(ui.offline)

        let calls = t.calls.count
        now = now.addingTimeInterval(60)
        await s.update(Fixture.area)
        XCTAssertEqual(t.calls.count, calls, "retry waits 5 min after a failure")
        t.fail = false
        now = now.addingTimeInterval(5 * 60)
        await s.update(Fixture.area)
        XCTAssertFalse(s.lastFailed)
        XCTAssertEqual(s.report?.fetchedAt, now)
    }

    func testAirFailureStillShowsTheForecast() async throws {
        let t = try FakeTransport()
        t.failAir = true
        let s = WeatherStore(transport: t, cache: WeatherCache(directory: tempDir()), clock: { Fixture.currentAt })
        await s.update(Fixture.area)
        XCTAssertNotNil(s.report)
        XCTAssertEqual(s.report?.airAvailable, false)
        XCTAssertFalse(s.lastFailed)
    }

    func testCacheIsPerAreaAndPrunesOldEntries() async throws {
        let dir = tempDir()
        let cache = WeatherCache(directory: dir)
        let t = try FakeTransport()
        let other = WeatherArea(around: 25.9, lng: 45.3)
        await WeatherStore(transport: t, cache: cache, clock: { Fixture.currentAt }).update(Fixture.area)
        XCTAssertNil(cache.report(other))
        cache.prune(now: Fixture.currentAt.addingTimeInterval(2 * 86_400))
        XCTAssertNotNil(cache.report(Fixture.area))
        cache.prune(now: Fixture.currentAt.addingTimeInterval(3 * 86_400 + 1))
        XCTAssertNil(cache.report(Fixture.area))
    }
}

// MARK: - Wadi proximity

final class WadiProximityTests: XCTestCase {
    let p = Geo.LatLng(lat: 24.66, lng: 46.62)
    private func north(_ m: Double, east e: Double = 0) -> Geo.LatLng {
        Geo.LatLng(lat: p.lat + m / 111_195, lng: p.lng + e / (111_195 * cos(p.lat * .pi / 180)))
    }

    func testPerpendicularDistanceToASegment() {
        /* An east–west line 500 m north of p. */
        let d = WadiProximity.distance(p, toSegment: north(500, east: -2_000), north(500, east: 2_000))
        XCTAssertEqual(d, 500, accuracy: 1)
    }

    func testEndpointDistanceMatchesHaversine() {
        let a = north(300, east: 400), b = north(2_000, east: 3_000)
        XCTAssertEqual(WadiProximity.distance(p, toSegment: a, b), Geo.haversineMeters(p, a), accuracy: Geo.haversineMeters(p, a) * 0.002)
        XCTAssertEqual(WadiProximity.distance(p, toSegment: a, a), Geo.haversineMeters(p, a), accuracy: 1, "zero-length segment")
    }

    func testNearestAcrossLinesAndPointsOnlyWatercourses() {
        let wadi = WaterwayLine(cls: "stream_intermittent", name: "وادي حنيفة", coords: [north(-1_000, east: 800), north(1_000, east: 800)])
        let canal = WaterwayLine(cls: "canal", name: nil, coords: [north(-1_000, east: -1_500), north(1_000, east: -1_500)])
        let notWater = WaterwayLine(cls: "dam", name: nil, coords: [north(0, east: 10), north(10, east: 10)])
        let got = WadiProximity.nearest(to: [p, north(0, east: -1_200)], lines: [wadi, canal, notWater])
        XCTAssertEqual(got?.distanceM ?? 0, 300, accuracy: 2, "the second point is 300 m from the canal")
        XCTAssertNil(got?.name)
        XCTAssertEqual(WadiProximity.nearest(to: [p], lines: [wadi])?.name, "وادي حنيفة")
        XCTAssertEqual(WadiProximity.nearest(to: [p], lines: [wadi])?.distanceM ?? 0, 800, accuracy: 2)
        XCTAssertNil(WadiProximity.nearest(to: [p], lines: [notWater]))
        XCTAssertNil(WadiProximity.nearest(to: [p], lines: []))
        XCTAssertNil(WadiProximity.nearest(to: [], lines: [wadi]))
    }

    func testClassesMatchTheRequest() {
        for c in ["river", "stream", "stream_intermittent", "wadi", "drain", "canal"] { XCTAssertTrue(WadiProximity.isWatercourse(c), c) }
        XCTAssertFalse(WadiProximity.isWatercourse("dam"))
        XCTAssertFalse(WadiProximity.isWatercourse("waterfall"))
    }

    func testRouteIsSampledSoAWadiCrossingMidSegmentIsFound() {
        let route = [north(-5_000), north(5_000)]
        let dense = WadiProximity.densify(route, step: 200)
        XCTAssertGreaterThanOrEqual(dense.count, 51)
        for (a, b) in zip(dense, dense.dropFirst()) { XCTAssertLessThanOrEqual(Geo.haversineMeters(a, b), 201) }
        XCTAssertEqual(dense.first, route.first)
        XCTAssertEqual(dense.last, route.last)
        let crossing = WaterwayLine(cls: "stream", name: nil, coords: [north(30, east: -500), north(30, east: 500)])
        XCTAssertNil(WadiProximity.nearest(to: route, lines: [crossing]).flatMap { $0.distanceM < 1_000 ? $0 : nil }, "the two ends alone are 5 km away")
        XCTAssertEqual(WadiProximity.nearest(to: dense, lines: [crossing])?.distanceM ?? .infinity, 0, accuracy: 110)
    }
}
