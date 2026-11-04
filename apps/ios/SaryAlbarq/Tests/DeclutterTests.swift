import XCTest
@testable import SaryAlbarq

/// Build 8 «ترتيب الشاشة» (docs/IA-REDESIGN.md): context modes, the alert queue,
/// edge-arrow selection, the trip header and the «+» catalog.
final class DeclutterTests: XCTestCase {
    // MARK: context

    func testMotionHysteresis() {
        var m = MotionHysteresis()
        m.ingest(speedMps: 3, at: 0)          // 10.8 km/h
        XCTAssertFalse(m.moving)
        m.ingest(speedMps: 5, at: 1)          // 18 km/h
        XCTAssertTrue(m.moving)
        m.ingest(speedMps: 0, at: 2)          // red light
        m.ingest(speedMps: 0, at: 15)
        XCTAssertTrue(m.moving, "a short stop does not flip the screen")
        m.ingest(speedMps: 2, at: 16)         // 7.2 km/h: crawling resets the stop
        m.ingest(speedMps: 0, at: 17)
        m.ingest(speedMps: 0, at: 36)
        XCTAssertTrue(m.moving)
        m.ingest(speedMps: 0, at: 37.5)
        XCTAssertFalse(m.moving, "stopped after 20 s at ≤ 5 km/h")
        m.ingest(speedMps: nil, at: 40)
        XCTAssertFalse(m.moving)
    }

    func testContextRule() {
        let r = LiveContextRule.resolve
        XCTAssertEqual(r(.auto, false, false, false, false), .stopped)
        XCTAssertEqual(r(.auto, true, false, false, false), .driving, "navigation")
        XCTAssertEqual(r(.auto, false, true, false, false), .driving, "moving")
        XCTAssertEqual(r(.auto, false, false, true, false), .driving, "drive mode")
        XCTAssertEqual(r(.auto, true, true, true, true), .stopped, "sheet raised: reading")
        XCTAssertEqual(r(.driving, false, false, false, false), .driving, "pinned")
        XCTAssertEqual(r(.stopped, true, true, true, false), .stopped, "pinned")
    }

    // MARK: alerts

    private func note(_ id: String) -> LiveAlertUI { .init(id: id, kind: .note(senderName: "فهد", senderColor: 0, text: "هلا")) }
    private func convoy(_ id: String) -> LiveAlertUI {
        .init(id: id, kind: .convoy(ConvoyAlertUI(kind: .behindTail, userId: "u", name: "فهد", color: 0, meters: 900)))
    }
    private func weather(_ id: String) -> LiveAlertUI {
        .init(id: id, kind: .weather(WeatherAlertUI(kind: .rain, forDestination: false, level: 1, title: "مطر", detail: "")))
    }
    private func timer(_ id: String) -> LiveAlertUI { .init(id: id, kind: .safety(.myTimerOverdue(contact: "أم فهد", due: Date()))) }
    private func stuck(_ id: String) -> LiveAlertUI {
        .init(id: id, kind: .safety(.friendStuck(StuckAlertUI(userId: "s", name: "سلطان", color: 0, note: nil, distanceMeters: nil,
                                                              bearingDegrees: nil, positionStale: false, since: Date()))))
    }
    private func silent(_ id: String) -> LiveAlertUI {
        .init(id: id, kind: .silent(SilentAlertUI(participantId: "m", name: "ماجد", color: 0, since: Date(), level: 10, hasPhone: false)))
    }
    private func toast(_ id: String) -> LiveAlertUI { .init(id: id, kind: .toast("نُسخ")) }

    func testPriorityOrder() {
        XCTAssertGreaterThan(AlertPriority.sos, .stuck)
        XCTAssertGreaterThan(AlertPriority.stuck, .silent)
        XCTAssertGreaterThan(AlertPriority.silent, .returnTimer)
        XCTAssertGreaterThan(AlertPriority.returnTimer, .convoy)
        XCTAssertGreaterThan(AlertPriority.convoy, .weather)
        XCTAssertGreaterThan(AlertPriority.weather, .note)
        XCTAssertGreaterThan(AlertPriority.note, .media)
    }

    func testQueueOrdersByPriorityThenNewest() {
        /* Newest first, as the controller keeps them. */
        let input = [note("n2"), weather("w"), convoy("c"), toast("t"), silent("s"), note("n1"), stuck("k"), timer("r")]
        XCTAssertEqual(AlertQueue.ordered(input).map(\.id), ["k", "s", "r", "c", "w", "n2", "n1"], "toasts never queue")
        XCTAssertEqual(AlertQueue.card(input, driving: false)?.id, "k")
        XCTAssertEqual(AlertQueue.bellCount(input, driving: false), 6)
        XCTAssertEqual(AlertQueue.toast(input)?.id, "t")
    }

    func testDrivingKeepsLowPriorityOnTheBell() {
        let low = [weather("w"), note("n")]
        XCTAssertNil(AlertQueue.card(low, driving: true))
        XCTAssertEqual(AlertQueue.bellCount(low, driving: true), 2)
        XCTAssertEqual(AlertQueue.card(low, driving: false)?.id, "w")
        XCTAssertEqual(AlertQueue.card(low + [convoy("c")], driving: true)?.id, "c", "convoy is the driving floor")
        XCTAssertEqual(AlertQueue.bellCount([convoy("c")], driving: true, media: 1), 1, "media counts on the bell")
    }

    // MARK: edge arrows

    func testEdgeArrowsMaxThreeAlertFirst() {
        let c: [(id: String, distance: Double?)] = [("a", 500), ("b", 100), ("c", 300), ("d", 50), ("e", nil), ("f", 2000)]
        XCTAssertEqual(EdgeArrows.pick(candidates: c, alerting: [], driving: false), ["d", "b", "c"])
        XCTAssertEqual(EdgeArrows.pick(candidates: c, alerting: ["f"], driving: false), ["f", "d", "b"])
        XCTAssertEqual(EdgeArrows.pick(candidates: c, alerting: ["f", "e"], driving: true), ["f", "e"], "driving: alert members only")
        XCTAssertEqual(EdgeArrows.pick(candidates: c, alerting: [], driving: true), [])
    }

    // MARK: trip header

    private func trip(_ phase: TripPanelUI.Phase, remaining: Double? = 12_000, eta: Date? = nil) -> TripPanelUI {
        TripPanelUI(phase: phase, destinationName: "روضة الثمامة", percent: 40, drivenMeters: 8000, remainingMeters: remaining,
                    remainingSource: nil, eta: eta, canEnd: false)
    }

    func testHeaderTitleAndLine() {
        let t = trip(.underway, eta: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(TripHeaderPresenter.title(outingName: "طلعة الثمامة", trip: t), "روضة الثمامة")
        XCTAssertEqual(TripHeaderPresenter.title(outingName: "طلعة الثمامة", trip: trip(.needsDestination(canSet: true))), "طلعة الثمامة")
        XCTAssertEqual(TripHeaderPresenter.title(outingName: "طلعة الثمامة", trip: nil), "طلعة الثمامة")
        let line = TripHeaderPresenter.line(status: .active, trip: t, follow: nil, connection: .connected, nearbyCars: 0) ?? ""
        XCTAssertTrue(line.hasPrefix("باقي ١٢ كم"), line)
        XCTAssertTrue(line.contains(" · نوصل "), line)
        XCTAssertEqual(TripHeaderPresenter.line(status: .active, trip: trip(.notStarted), follow: nil, connection: .connected, nearbyCars: 0), "لم تبدأ")
        XCTAssertEqual(TripHeaderPresenter.line(status: .active, trip: t, follow: "على المسار", connection: .connected, nearbyCars: 0), "على المسار")
        XCTAssertEqual(TripHeaderPresenter.line(status: .paused, trip: t, follow: nil, connection: .connected, nearbyCars: 0), "الطلعة متوقفة مؤقتًا")
        XCTAssertEqual(TripHeaderPresenter.line(status: .active, trip: nil, follow: nil, connection: .offline, nearbyCars: 0), "بلا إنترنت")
    }

    func testHeaderDotIsTheWorstSignal() {
        XCTAssertEqual(TripHeaderPresenter.level(connection: .connected, sharing: .sharing, warnings: []), .good)
        XCTAssertEqual(TripHeaderPresenter.level(connection: .connected, sharing: .paused, warnings: []), .unknown)
        XCTAssertEqual(TripHeaderPresenter.level(connection: .connecting, sharing: .sharing, warnings: []), .degraded)
        XCTAssertEqual(TripHeaderPresenter.level(connection: .connected, sharing: .sharing, warnings: [.keepScreenOn]), .degraded)
        XCTAssertEqual(TripHeaderPresenter.level(connection: .offline, sharing: .sharing, warnings: []), .bad)
    }

    // MARK: «+»

    func testActionCatalogHoldsEveryFeature() {
        let g = LiveActionCatalog.groups(.init())
        XCTAssertEqual(g.map(\.title), ["الطريق", "المجموعة", "الخدمات", "الترفيه"])
        let ids = g.flatMap(\.items).map(\.accessibilityID)
        XCTAssertEqual(Set(ids), ["outing-navigate", "outing-search", "outing-backtrack", "plan.follow", "outing-note-open", "outing-stuck",
                                  "outing-waypoint-add", "outing-copyme", "outing-nearest-open", "outing-weather", "outing-youtube"])
        XCTAssertEqual(ids.count, Set(ids).count, "no duplicate entry")
        let active = LiveActionCatalog.groups(.init(backTracking: true, following: true, hasRoute: true, stuck: true)).flatMap(\.items)
        XCTAssertEqual(active.first { $0.id == "backtrack" }?.title, "أنهِ طريق العودة")
        XCTAssertEqual(active.first { $0.id == "follow" }?.title, "أوقف اتباع الخطة")
    }

    func testThreeTabs() {
        XCTAssertEqual(LiveTabUI.allCases.map(\.label), ["الرحلة", "المجموعة", "المزيد"])
    }
}
