import XCTest
@testable import SaryAlbarq

// «طلعة جديدة» (three steps), the invite text, the always-visible weather chip,
// and the destination kept on the phone while the server has no plan endpoint.

private let t0 = Date(timeIntervalSince1970: 1_793_793_600) // 2026-11-04 12:00 UTC
private let thumama = OutingDestination(name: "روضة الثمامة", lat: 24.7590, lng: 46.7491)

final class CreateFlowStateTests: XCTestCase {
    func testStartsAtStepOneWithDepartureInAnHour() {
        let f = CreateFlowState(now: t0)
        XCTAssertEqual(f.step, .destination)
        XCTAssertEqual(f.progressText, "١ من ٣")
        XCTAssertEqual(f.departure, t0.addingTimeInterval(3600))
        XCTAssertFalse(f.canGoBack)
        let odd = CreateFlowState(now: t0.addingTimeInterval(61))
        XCTAssertEqual(odd.departure, t0.addingTimeInterval(3600 + 300), "rounded up to the next 5 minutes")
    }

    func testChoosingADestinationMovesToWeatherAndSuggestsAName() {
        var f = CreateFlowState(now: t0)
        XCTAssertTrue(f.choose(thumama))
        XCTAssertEqual(f.step, .weather)
        XCTAssertEqual(f.progressText, "٢ من ٣")
        XCTAssertEqual(f.destination, thumama)
        XCTAssertEqual(f.name, "طلعة روضة الثمامة")
        XCTAssertTrue(f.canGoBack)
    }

    func testTypedCoordinateKeepsNameEmptyAndInvalidIsRefused() {
        var f = CreateFlowState(now: t0)
        XCTAssertFalse(f.choose(OutingDestination(name: "x", lat: 120, lng: 46)))
        XCTAssertEqual(f.step, .destination)
        XCTAssertTrue(f.choose(OutingDestination(name: "نقطة على الخريطة", lat: 24.7, lng: 46.7)))
        XCTAssertEqual(f.name, "", "a bare point does not invent a name")
        var g = CreateFlowState(now: t0)
        g.name = "كشتة الخميس"
        g.choose(thumama)
        XCTAssertEqual(g.name, "كشتة الخميس", "a typed name is never replaced")
    }

    func testSkipIsAllowedAndBackReturnsToStepOneKeepingNameAndTime() {
        var f = CreateFlowState(now: t0)
        f.skipDestination()
        XCTAssertEqual(f.step, .weather)
        XCTAssertTrue(f.skippedDestination)
        XCTAssertNil(f.destination)
        f.name = "مشوار"
        f.departure = t0.addingTimeInterval(7200)
        f.back()
        XCTAssertEqual(f.step, .destination)
        XCTAssertEqual(f.name, "مشوار")
        XCTAssertEqual(f.departure, t0.addingTimeInterval(7200))
        f.choose(thumama)
        XCTAssertFalse(f.skippedDestination)
        XCTAssertEqual(f.step, .weather)
    }

    func testApproveValidatesNameAndDeparture() {
        var f = CreateFlowState(now: t0)
        f.choose(OutingDestination(name: "", lat: 24.7, lng: 46.7))
        XCTAssertEqual(f.destination?.name, "الوجهة")
        XCTAssertFalse(f.approve(now: t0))
        XCTAssertEqual(f.error, "اكتب اسم الطلعة.")
        f.name = "   "
        XCTAssertFalse(f.approve(now: t0))
        f.name = "كشتة"
        f.departure = t0.addingTimeInterval(-3600)
        XCTAssertFalse(f.approve(now: t0))
        XCTAssertEqual(f.error, CreateFlowState.Issue.departurePast.arabic)
        f.departure = t0.addingTimeInterval(15 * 86_400)
        XCTAssertFalse(f.approve(now: t0))
        XCTAssertEqual(f.error, CreateFlowState.Issue.departureTooFar.arabic)
        f.departure = t0.addingTimeInterval(-120)
        XCTAssertTrue(f.approve(now: t0), "a minute or two late still counts as now")
        XCTAssertEqual(f.departure, t0)
        XCTAssertTrue(f.creating)
        XCTAssertNil(f.error)
        XCTAssertFalse(f.canGoBack, "no going back while the outing is being created")
        XCTAssertFalse(f.approve(now: t0), "no double create")
    }

    func testCreatedMovesToInviteAndFailureStays() {
        var f = CreateFlowState(now: t0)
        f.choose(thumama)
        XCTAssertTrue(f.approve(now: t0))
        f.createFailed("تعذّر إنشاء الطلعة.")
        XCTAssertEqual(f.step, .weather)
        XCTAssertFalse(f.creating)
        XCTAssertEqual(f.error, "تعذّر إنشاء الطلعة.")
        XCTAssertTrue(f.approve(now: t0))
        f.created("o-1")
        XCTAssertEqual(f.step, .invite)
        XCTAssertEqual(f.outingId, "o-1")
        XCTAssertEqual(f.progressText, "٣ من ٣")
        XCTAssertFalse(f.canGoBack)
        f.back()
        XCTAssertEqual(f.step, .invite)
        f.created("o-2")
        XCTAssertEqual(f.outingId, "o-1", "created only once")
    }

    func testStepOneOnlyActionsAreIgnoredLater() {
        var f = CreateFlowState(now: t0)
        f.choose(thumama)
        XCTAssertFalse(f.choose(OutingDestination(name: "ب", lat: 25, lng: 45)))
        f.skipDestination()
        XCTAssertEqual(f.destination, thumama)
    }
}

final class InviteMessageTests: XCTestCase {
    private let link = InviteLink.url(for: "AbCdEfGhIjKlMnOpQrStUvWxYz0123456789-_abcde")

    func testMessageHasDestinationWeatherAndAWesternDigitLink() {
        let msg = InviteMessage.text(outingName: "كشتة الثمامة", destination: thumama, arrivalWeather: "٢٤° رياح خفيفة", departure: nil, link: link)
        XCTAssertTrue(msg.contains("«كشتة الثمامة»"))
        XCTAssertTrue(msg.contains("الوجهة: روضة الثمامة"))
        XCTAssertTrue(msg.contains("الجو هناك وقت وصولنا: ٢٤° رياح خفيفة"))
        XCTAssertTrue(msg.hasSuffix(link.absoluteString), "the link is last, untouched")
        XCTAssertTrue(msg.contains("https://www.google.com/maps/search/?api=1&query=24.75900,46.74910"), "map link in Western digits")
        for line in msg.split(separator: "\n") where line.contains("http") {
            XCTAssertNil(line.split(separator: " ").last?.first { ("٠"..."٩").contains($0) }, "no Arabic-Indic digits in a link: \(line)")
        }
    }

    func testWithoutDestinationNoWeatherLine() {
        let msg = InviteMessage.text(outingName: "مشوار", destination: nil, arrivalWeather: nil, departure: nil, link: link)
        XCTAssertFalse(msg.contains("الوجهة"))
        XCTAssertFalse(msg.contains("الجو هناك"))
        XCTAssertEqual(msg.split(separator: "\n").count, 3)
    }

    func testDepartureLineUsesArabicDigits() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Riyadh")!
        let now = Date()
        XCTAssertEqual(InviteMessage.day(now, now: now, calendar: cal), "اليوم")
        XCTAssertEqual(InviteMessage.day(now.addingTimeInterval(86_400), now: now, calendar: cal), "بكرة")
        let msg = InviteMessage.text(outingName: "م", destination: nil, arrivalWeather: nil, departure: now, link: link)
        let line = msg.split(separator: "\n").first { $0.hasPrefix("الانطلاق") }.map(String.init) ?? ""
        XCTAssertFalse(line.contains { ("0"..."9").contains($0) }, line)
    }

    func testWhatsAppLinkEncodesTheText() throws {
        let u = try XCTUnwrap(InviteMessage.whatsAppURL("تعال\n\(link.absoluteString)"))
        XCTAssertEqual(u.host, "wa.me")
        let q = URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "text" }?.value
        XCTAssertEqual(q, "تعال\n\(link.absoluteString)")
    }

    func testArrivalWeatherLine() {
        var h = WeatherHour(time: t0, temperatureC: 24.4, precipitationMm: 0, precipitationProbability: 0, weatherCode: 0,
                            windKmh: 12, gustKmh: 18, windFromDeg: 0, visibilityM: 20_000, dust: 20, pm10: 30)
        XCTAssertEqual(WeatherSummary.line(h), "٢٤° رياح خفيفة")
        h.windKmh = 45
        XCTAssertEqual(WeatherSummary.line(h), "٢٤° رياح قوية")
        h.windKmh = 25
        h.precipitationProbability = 60
        XCTAssertEqual(WeatherSummary.line(h), "٢٤° رياح معتدلة، مطر ٦٠٪")
        h.precipitationProbability = 0
        h.dust = 1500
        XCTAssertTrue(WeatherSummary.line(h).hasSuffix(DustLevel.heavy.label))
        let r = WeatherReport(area: WeatherArea(point: 24.7, lng: 46.7), fetchedAt: t0, current: nil, hours: [h], airAvailable: true)
        XCTAssertNotNil(WeatherSummary.atArrival(r, eta: t0.addingTimeInterval(1800)))
        XCTAssertNil(WeatherSummary.atArrival(r, eta: t0.addingTimeInterval(7200)), "arrival beyond the forecast: no line")
    }
}

final class WeatherChipTests: XCTestCase {
    private let me = Geo.LatLng(lat: 24.70, lng: 46.60)
    private let friend = Geo.LatLng(lat: 24.90, lng: 46.80)

    func testSourceOrderDestinationThenGroupThenMe() {
        XCTAssertEqual(WeatherChipSource.select(destination: thumama, others: [friend], me: me), .destination(thumama))
        guard case let .group(c) = WeatherChipSource.select(destination: nil, others: [friend], me: me) else { return XCTFail("group") }
        XCTAssertEqual(c.lat, 24.80, accuracy: 1e-9, "the group's centre includes me")
        XCTAssertEqual(c.lng, 46.70, accuracy: 1e-9)
        XCTAssertEqual(WeatherChipSource.select(destination: nil, others: [], me: me), .me(me))
        XCTAssertEqual(WeatherChipSource.select(destination: nil, others: [], me: nil), .none)
        XCTAssertEqual(WeatherChipSource.select(destination: OutingDestination(name: "x", lat: .nan, lng: 1), others: [], me: me), .me(me), "a broken destination is skipped")
    }

    func testSourceAreasAreRoundedExceptTheChosenDestination() {
        XCTAssertEqual(WeatherChipSource.group(Geo.LatLng(lat: 24.8123, lng: 46.7177)).area?.latText, "24.8")
        XCTAssertEqual(WeatherChipSource.destination(thumama).area?.latText, "24.7590")
        XCTAssertEqual(WeatherChipSource.group(friend).placeLabel, "منطقة الطلعة")
        XCTAssertEqual(WeatherChipSource.me(me).placeLabel, "منطقتك")
        XCTAssertEqual(WeatherChipSource.destination(thumama).placeLabel, "روضة الثمامة")
    }

    private func report(fetchedAt: Date, temp: Double = 24, wind: Double = 10) -> WeatherReport {
        let hours = (0..<48).map { i in
            WeatherHour(time: t0.addingTimeInterval(Double(i) * 3600), temperatureC: temp, precipitationMm: 0, precipitationProbability: 0, weatherCode: 0,
                        windKmh: wind, gustKmh: wind + 5, windFromDeg: 0, visibilityM: 20_000, dust: 20, pm10: 30)
        }
        return WeatherReport(area: WeatherArea(point: thumama.lat, lng: thumama.lng), fetchedAt: fetchedAt, current: hours[0], hours: hours, airAvailable: true)
    }

    func testFreshChipHasTempAndNoAge() {
        let ui = WeatherChipPresenter.chip(source: .destination(thumama), report: report(fetchedAt: t0), refreshing: false, failed: false, now: t0.addingTimeInterval(600))
        XCTAssertEqual(ui.phase, .ready)
        XCTAssertEqual(ui.temp, "٢٤°")
        XCTAssertEqual(ui.place, "روضة الثمامة")
        XCTAssertNil(ui.staleText)
        XCTAssertEqual(ui.alertLevel, 0)
    }

    func testStaleChipStaysVisibleWithItsAge() {
        let ui = WeatherChipPresenter.chip(source: .me(me), report: report(fetchedAt: t0), refreshing: false, failed: true, now: t0.addingTimeInterval(3 * 3600 + 60))
        XCTAssertEqual(ui.phase, .ready, "old data is still shown")
        XCTAssertEqual(ui.temp, "٢٤°")
        XCTAssertEqual(ui.staleText, "آخر تحديث قبل ٣ س")
        XCTAssertTrue(ui.offline)
        XCTAssertTrue(ui.accessibility.contains("آخر تحديث قبل ٣ س"))
    }

    func testExpiredLoadingFailedAndNoSourceNeverDisappear() {
        let expired = WeatherChipPresenter.chip(source: .me(me), report: report(fetchedAt: t0), refreshing: false, failed: true, now: t0.addingTimeInterval(50 * 3600))
        XCTAssertEqual(expired.phase, .unavailable)
        XCTAssertEqual(expired.temp, "—")
        XCTAssertNotNil(expired.staleText)
        let loading = WeatherChipPresenter.chip(source: .group(friend), report: nil, refreshing: true, failed: false, now: t0)
        XCTAssertEqual(loading.phase, .loading)
        XCTAssertEqual(loading.place, "منطقة الطلعة")
        let failed = WeatherChipPresenter.chip(source: .group(friend), report: nil, refreshing: false, failed: true, now: t0)
        XCTAssertEqual(failed.phase, .unavailable)
        XCTAssertEqual(failed.staleText, "تعذّر جلب الطقس")
        let none = WeatherChipPresenter.chip(source: .none, report: nil, refreshing: false, failed: false, now: t0)
        XCTAssertEqual(none.phase, .unavailable)
        XCTAssertTrue(none.accessibility.contains(WeatherChipPresenter.noSourceText))
    }

    func testStrongWindTintsTheChip() {
        let ui = WeatherChipPresenter.chip(source: .destination(thumama), report: report(fetchedAt: t0, wind: 45), refreshing: false, failed: false, now: t0.addingTimeInterval(60))
        XCTAssertEqual(ui.alertLevel, 1)
    }

    @MainActor
    func testOutingWeatherPicksItsSourceAndNeverSpinsWithoutOne() {
        let w = OutingWeather(outingId: "chip-test", tracksMap: false)
        XCTAssertEqual(w.source, .none)
        if case .unavailable(let m) = w.areaCard(now: t0).phase { XCTAssertEqual(m, WeatherChipPresenter.noSourceText) } else { XCTFail("no endless loading") }
        w.setPositions([], me: DeviceFix(lat: me.lat, lng: me.lng, accuracy: 10, heading: nil, speed: nil, atMs: t0.timeIntervalSince1970 * 1000))
        XCTAssertEqual(w.source, .me(me))
        XCTAssertEqual(w.areaCard(now: t0).title, "الطقس في منطقتك")
        w.setPositions([friend], me: DeviceFix(lat: me.lat, lng: me.lng, accuracy: 10, heading: nil, speed: nil, atMs: t0.timeIntervalSince1970 * 1000 + 6000))
        if case .group = w.source {} else { XCTFail("group beats me") }
        w.setDestination(thumama)
        XCTAssertEqual(w.source, .destination(thumama))
        XCTAssertTrue(w.chipStore === w.destination)
        w.setDestination(nil)
        XCTAssertTrue(w.chipStore === w.area)
    }
}

@MainActor
final class LocalDestinationTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        defaults = UserDefaults(suiteName: "LocalDestinationTests")
        defaults.removePersistentDomain(forName: "LocalDestinationTests")
    }

    func testNotDeployedKeepsTheDestinationOnThePhone() async {
        let b = FakePlanBackend()
        b.notDeployed = true
        let m = PlanModel(outingId: "o", backend: b, defaults: defaults)
        await m.load()
        let ok = await m.setDestination(thumama)
        XCTAssertTrue(ok, "the leader's choice is not lost")
        XCTAssertEqual(m.plan.destination, thumama)
        XCTAssertTrue(m.destinationLocalOnly)
        XCTAssertNil(m.errorText)
        XCTAssertEqual(LocalDestinationStore.load("o", defaults: defaults)?.destination, thumama)
        /* The app is closed and opened again: still there. */
        let again = PlanModel(outingId: "o", backend: b, defaults: defaults)
        XCTAssertEqual(again.plan.destination, thumama)
        XCTAssertTrue(again.destinationLocalOnly)
        await again.load()
        XCTAssertEqual(again.plan.destination, thumama, "a 404 load does not wipe it")
    }

    func testSyncsOnceTheEndpointAnswers() async {
        let b = FakePlanBackend()
        b.notDeployed = true
        let m = PlanModel(outingId: "o", backend: b, defaults: defaults)
        _ = await m.setDestination(thumama)
        b.notDeployed = false
        await m.loadPlan()
        XCTAssertEqual(b.puts.last?.destination, thumama, "sent to the server")
        XCTAssertEqual(m.plan.destination, thumama)
        XCTAssertFalse(m.destinationLocalOnly)
        XCTAssertNil(LocalDestinationStore.load("o", defaults: defaults))
        await m.loadPlan()
        XCTAssertEqual(b.puts.count, 1, "sent once")
    }

    func testServerDestinationWinsOverAStaleLocalOne() async {
        let b = FakePlanBackend()
        LocalDestinationStore.save("o", .init(destination: thumama, pending: true, savedAt: t0), defaults: defaults)
        let other = OutingDestination(name: "العارض", lat: 24.9, lng: 46.2)
        b.plan = TripPlan(route: nil, notes: "", destination: other, updated_at: nil)
        let m = PlanModel(outingId: "o", backend: b, defaults: defaults)
        await m.loadPlan()
        XCTAssertEqual(m.plan.destination, other)
        XCTAssertTrue(b.puts.isEmpty)
        XCTAssertFalse(m.destinationLocalOnly)
        XCTAssertNil(LocalDestinationStore.load("o", defaults: defaults))
    }

    func testDeployedServerSavesDirectlyAndRealErrorsStayErrors() async {
        let b = FakePlanBackend()
        let m = PlanModel(outingId: "o", backend: b, defaults: defaults)
        let ok = await m.setDestination(thumama)
        XCTAssertTrue(ok)
        XCTAssertFalse(m.destinationLocalOnly)
        XCTAssertNil(LocalDestinationStore.load("o", defaults: defaults))
        b.failNext = OutingAPIError(code: "leader_only", status: 403)
        let refused = await m.setDestination(OutingDestination(name: "ب", lat: 25, lng: 45))
        XCTAssertFalse(refused, "a refusal is not hidden behind the local copy")
        XCTAssertEqual(m.plan.destination, thumama)
        XCTAssertNil(LocalDestinationStore.load("o", defaults: defaults))
    }

    func testClearingWhileLocalForgetsIt() async {
        let b = FakePlanBackend()
        b.notDeployed = true
        let m = PlanModel(outingId: "o", backend: b, defaults: defaults)
        await m.load()
        _ = await m.setDestination(thumama)
        _ = await m.setDestination(nil)
        XCTAssertNil(m.plan.destination)
        XCTAssertFalse(m.destinationLocalOnly)
        XCTAssertNil(LocalDestinationStore.load("o", defaults: defaults))
    }

    func testRecentPlacesNewestFirstWithoutDuplicates() {
        RecentPlaces.add(thumama, defaults: defaults)
        RecentPlaces.add(OutingDestination(name: "العارض", lat: 24.9, lng: 46.2), defaults: defaults)
        RecentPlaces.add(OutingDestination(name: "الثمامة مرة ثانية", lat: 24.7591, lng: 46.7491), defaults: defaults)
        let all = RecentPlaces.load(defaults: defaults)
        XCTAssertEqual(all.map(\.name), ["الثمامة مرة ثانية", "العارض"])
        for i in 0..<10 { RecentPlaces.add(OutingDestination(name: "\(i)", lat: 20 + Double(i), lng: 45), defaults: defaults) }
        XCTAssertEqual(RecentPlaces.load(defaults: defaults).count, RecentPlaces.max)
    }
}
