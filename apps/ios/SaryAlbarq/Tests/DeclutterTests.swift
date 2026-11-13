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

    /// The automatic drive appearance has a gap between on and off: speed hovering near 25 km/h
    /// no longer flips `theme.drive` (and the live sheet's peek height) on every fix.
    func testAutoDriveHysteresis() {
        XCTAssertFalse(AutoDriveRule.next(current: false, speedMps: 6.9))
        XCTAssertTrue(AutoDriveRule.next(current: false, speedMps: 7.1), "on above 7 m/s, as before")
        XCTAssertTrue(AutoDriveRule.next(current: true, speedMps: 6.5), "a dip under 7 m/s keeps it on")
        XCTAssertTrue(AutoDriveRule.next(current: true, speedMps: 4.1))
        XCTAssertFalse(AutoDriveRule.next(current: true, speedMps: 4.0), "off at 4 m/s or less")
        XCTAssertFalse(AutoDriveRule.next(current: false, speedMps: 5.5), "between the two: unchanged")
        XCTAssertFalse(AutoDriveRule.next(current: true, speedMps: nil), "no speed: off")
        XCTAssertFalse(AutoDriveRule.next(current: true, speedMps: -1))
        /* Noise around 25 km/h: one flip, not one per fix. */
        var on = false, flips = 0
        for v in [6.8, 7.2, 6.9, 7.1, 6.6, 7.3, 6.7, 7.0] {
            let n = AutoDriveRule.next(current: on, speedMps: v)
            if n != on { flips += 1 }
            on = n
        }
        XCTAssertEqual(flips, 1)
    }

    func testContextRule() {
        let r = LiveContextRule.resolve
        XCTAssertEqual(r(.auto, false, false, false, false, false), .stopped)
        XCTAssertEqual(r(.auto, true, false, false, false, false), .driving, "navigation")
        XCTAssertEqual(r(.auto, false, true, false, false, false), .driving, "moving")
        XCTAssertEqual(r(.auto, false, false, true, false, false), .driving, "drive mode")
        XCTAssertEqual(r(.auto, true, true, true, true, false), .stopped, "sheet raised: reading")
        XCTAssertEqual(r(.driving, false, false, false, false, false), .driving, "pinned")
        XCTAssertEqual(r(.stopped, true, true, true, false, false), .stopped, "pinned")
        /* Exploration (build 9): wins over pinned modes and the raised sheet, never over real driving. */
        XCTAssertEqual(r(.auto, false, false, false, false, true), .exploring)
        XCTAssertEqual(r(.auto, false, false, false, true, true), .exploring, "sheet up: still exploring")
        XCTAssertEqual(r(.driving, false, false, true, false, true), .exploring, "the person chose it")
        XCTAssertEqual(r(.auto, true, false, false, false, true), .driving, "guidance leaves exploration")
        XCTAssertEqual(r(.auto, false, true, false, false, true), .driving, "moving leaves exploration")
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

    func testHistoryKeepsEveryAlertButToasts() {
        var h: [AlertHistoryEntry] = []
        let t0 = Date(timeIntervalSince1970: 1000)
        AlertQueue.record(weather("w"), at: t0, into: &h)
        AlertQueue.record(toast("t"), at: t0, into: &h)
        AlertQueue.record(stuck("k"), at: t0.addingTimeInterval(5), into: &h)
        AlertQueue.record(weather("w"), at: t0.addingTimeInterval(9), into: &h)
        XCTAssertEqual(h.map(\.id), ["w", "k"], "newest first, one entry per alert, no toasts")
        XCTAssertEqual(h.first?.text, "مطر")
        XCTAssertEqual(h.last?.text, "سلطان غرّز")
        for i in 0..<60 { AlertQueue.record(note("n\(i)"), at: t0, into: &h) }
        XCTAssertEqual(h.count, AlertQueue.historyLimit)
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
        /* Lovable: the outing's name on top, «إلى <الوجهة> • باقي … • نوصل …» under it. */
        XCTAssertEqual(TripHeaderPresenter.title(outingName: "طلعة الثمامة", trip: t), "طلعة الثمامة")
        XCTAssertEqual(TripHeaderPresenter.title(outingName: "طلعة الثمامة", trip: trip(.needsDestination(canSet: true))), "طلعة الثمامة")
        XCTAssertEqual(TripHeaderPresenter.title(outingName: "طلعة الثمامة", trip: nil), "طلعة الثمامة")
        let line = TripHeaderPresenter.line(status: .active, trip: t, follow: nil, connection: .connected, nearbyCars: 0) ?? ""
        XCTAssertTrue(line.hasPrefix("إلى روضة الثمامة • باقي ١٢ كم"), line)
        XCTAssertTrue(line.contains(" • نوصل "), line)
        XCTAssertEqual(TripHeaderPresenter.line(status: .active, trip: trip(.notStarted), follow: nil, connection: .connected, nearbyCars: 0), "ما بدأت")
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
        /* UX simplification: «المزيد» holds only what the quick row and other screens do not. */
        let g = LiveActionCatalog.groups(.init())
        XCTAssertEqual(g.map(\.title), ["الطريق", "الأصدقاء", "السلامة", "المكان", "الخريطة"])
        let ids = g.flatMap(\.items).map(\.accessibilityID)
        /* UI-AUDIT م3: «ملاحة» and «طريق الرجعة» are tiles (the quick row has no accent button and no
         * back-track button any more). */
        XCTAssertEqual(Set(ids), ["outing-navigate", "outing-route", "outing-search", "trail.backtrack", "outing-invite", "outing-convoy",
                                  "outing-note-open", "outing-stuck", "outing-enjad",
                                  "outing-timer", "outing-location-tools", "outing-nearest-open", "outing-weather-tools",
                                  "outing-explore", "outing-fit"])
        let nestedIDs = g.flatMap(\.items).flatMap(\.children).map(\.accessibilityID)
        XCTAssertEqual(Set(nestedIDs), ["outing-brief", "outing-save-place", "outing-waypoint-add", "outing-weather", "outing-qibla"])
        XCTAssertEqual(LiveActionCatalog.tripRouteActions(.init()).map(\.accessibilityID), ["plan.follow"])
        let allIDs = ids + nestedIDs
        XCTAssertEqual(allIDs.count, Set(allIDs).count, "no duplicate entry")
        XCTAssertTrue(Set(g.flatMap(\.items).map(\.id)).isDisjoint(with: LiveActionCatalog.inQuickRow), "nothing the quick row already has")
        let active = LiveActionCatalog.groups(.init(backTracking: true, following: true, hasRoute: true, stuck: true)).flatMap(\.items)
        XCTAssertEqual(active.first { $0.id == "stuck" }?.title, "أنا مغرّز")
        XCTAssertEqual(active.first { $0.id == "route" }?.isActive, true)
        XCTAssertEqual(LiveActionCatalog.tripRouteActions(.init(following: true)).first { $0.id == "follow" }?.title, "أوقف اتباع الخطة")
    }

    /// UI-AUDIT م3: the quick row has no accent primary any more (the CTA is the state's one primary):
    /// «ملاحة» is a tile in «المزيد» for everyone; «وجّه الكل» is offered after «ابدأ الطلعة».
    func testQuickRowHasNoPrimaryAndNavigateIsATile() {
        XCTAssertEqual(LiveScreenRules.quickRow(chat: true), ["desert", "chat", "rally", "more"])
        XCTAssertFalse(LiveScreenRules.quickRow(chat: true).contains("navigate"))
        XCTAssertFalse(LiveScreenRules.quickRow(chat: true).contains("guideAll"))
        for s in [LiveActionCatalog.State(), .init(guideAllTarget: "روضة")] {
            let items = LiveActionCatalog.groups(s).flatMap(\.items)
            XCTAssertTrue(items.contains { $0.id == "navigate" }, "«ملاحة» is in «المزيد» → «الطريق»")
            XCTAssertFalse(items.contains { $0.id == "guideAll" }, "«وجّه الكل» stays in the start choice")
        }
    }

    /// «أخفِ موقعي» moved from the quick row into «المزيد» → «الجماعة»; «طريق الرجعة» leaves «المزيد»
    /// while it runs (its panel's «إنهاء» is the one stop).
    func testHideAndBackTrackTiles() {
        let group = { (s: LiveActionCatalog.State) in LiveActionCatalog.groups(s).first { $0.title == "الأصدقاء" }?.items ?? [] }
        XCTAssertFalse(group(.init()).contains { $0.id == "hide" }, "only when I can hide")
        let hide = group(.init(canHide: true)).first { $0.id == "hide" }
        XCTAssertEqual(hide?.accessibilityID, "live.hideLocation")
        XCTAssertEqual(hide?.title, HideText.hideButton)
        XCTAssertEqual(group(.init(canHide: true, hidden: true)).first { $0.id == "hide" }?.title, HideText.shownButton)
        XCTAssertTrue(LiveActionCatalog.needsRunningTrip.contains("hide"))
        let road = { (s: LiveActionCatalog.State) in LiveActionCatalog.groups(s).first { $0.title == "الطريق" }?.items.map(\.id) ?? [] }
        XCTAssertTrue(road(.init()).contains("backtrack"))
        XCTAssertFalse(road(.init(backTracking: true)).contains("backtrack"), "no second stop while it runs")
        XCTAssertTrue(road(.init(ended: true)).contains("backtrack"), "works on the phone after the end too")
    }

    /// «الطبقات» is only the layers sheet; the tile that enters exploration says so.
    func testExploreTileIsNotCalledLayers() {
        let explore = LiveActionCatalog.groups(.init()).flatMap(\.items).first { $0.id == "explore" }
        XCTAssertEqual(explore?.title, "استكشف الخريطة")
        XCTAssertEqual(explore?.accessibilityID, "outing-explore")
    }

    /// Build 11: an ended trip kept offering «رسالة فوق سيارتي», «غرّزت»… to a group that is gone.
    func testActionCatalogOnAnEndedTrip() {
        let ids = Set(LiveActionCatalog.groups(.init(ended: true)).flatMap(\.items).map(\.id))
        XCTAssertTrue(ids.isDisjoint(with: LiveActionCatalog.needsRunningTrip), "\(ids)")
        XCTAssertTrue(ids.isSuperset(of: ["search", "navigate", "route", "explore", "nearest", "weatherTools"]))
        XCTAssertFalse(LiveActionCatalog.groups(.init(ended: true)).contains { $0.items.isEmpty }, "no empty group")
    }

    /// After the end the header names the outing, not a target («نقطة البداية» of a return trip).
    func testHeaderTitleAfterTheEnd() {
        var t = trip(.arrived(at: Date(), manual: false))
        t.destinationName = "نقطة البداية"
        XCTAssertEqual(TripHeaderPresenter.title(outingName: "العودة من روضة الثمامة", trip: t), "العودة من روضة الثمامة")
        XCTAssertEqual(TripHeaderPresenter.line(status: .active, trip: t, follow: nil, connection: .connected, nearbyCars: 0), "وصلت نقطة البداية")
        XCTAssertEqual(TripHeaderPresenter.title(outingName: "العودة من روضة الثمامة", trip: t, ended: true), "العودة من روضة الثمامة")
        t.phase = .ended
        XCTAssertEqual(TripHeaderPresenter.title(outingName: "العودة من روضة الثمامة", trip: t, ended: true), "العودة من روضة الثمامة")
    }

    /// Satellite imagery is sharp to ~z18 over the Kingdom: the live map never zooms past it.
    func testSatelliteZoomIsCappedAtTheImageryResolution() {
        XCTAssertEqual(MapLayer.satellite.maxZoom(hiRes: false), 18)
        XCTAssertEqual(MapLayer.satellite.maxZoom(hiRes: true), 19, "«صور عالية الوضوح» needs z19")
        XCTAssertEqual(MapLayer.topo.maxZoom(hiRes: true), 20)
        XCTAssertLessThanOrEqual(SatelliteLabels.trackMaxZoom, MapLayer.satellite.maxZoom)
        XCTAssertGreaterThan(MapLayer.topo.maxZoom, MapLayer.satellite.maxZoom)
    }

    /// Build 12 imagery clarity: only Mapbox raster paint properties, on the imported satellite layer, idempotent.
    func testSatelliteImageryTuning() throws {
        let inner = #"{"version":8,"sources":{},"layers":[{"id":"bg","type":"background"},{"id":"mapbox-satellite","type":"raster","source":"mapbox://mapbox.satellite","paint":{"raster-emissive-strength":0.5}}]}"#
        let style = ArabicBasemap.wrap(inner)
        let once = SatelliteImagery.tune(style)
        XCTAssertEqual(SatelliteImagery.tune(once), once, "idempotent")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(once.utf8)) as? [String: Any])
        let imp = try XCTUnwrap((root["imports"] as? [[String: Any]])?.first?["data"] as? [String: Any])
        let layers = try XCTUnwrap(imp["layers"] as? [[String: Any]])
        let paint = try XCTUnwrap(layers[1]["paint"] as? [String: Any])
        XCTAssertEqual(paint["raster-contrast"] as? Double, 0.12)
        XCTAssertEqual(paint["raster-saturation"] as? Double, 0.08)
        XCTAssertEqual(paint["raster-resampling"] as? String, "linear")
        XCTAssertEqual(paint["raster-emissive-strength"] as? Double, 0.5, "the style's own paint is kept")
        XCTAssertNil(layers[0]["paint"], "non-raster layers untouched")
        XCTAssertLessThanOrEqual(SatelliteImagery.paint["raster-saturation"] as? Double ?? 1, 0.15, "natural, not oversaturated")
        XCTAssertEqual(SatelliteImagery.tune("not json"), "not json")
    }

    /// Build 13 + the sand grade: the live map's satellite gets build 12's resampling / fade /
    /// lifted shadows and `SandGrade` (warm in the open, neutral in a city), replacing the grade
    /// an older cached copy carried; the imported style declares `sarySand`.
    func testSatelliteTuningComposesWithSandGrade() throws {
        let old = #"{"version":8,"schema":{"lightPreset":{"default":"day","type":"string"}},"sources":{},"layers":[{"id":"satellite","type":"raster","source":"mapbox://mapbox.satellite","layout":{},"paint":{"raster-emissive-strength":0.3,"raster-contrast":0.18,"raster-saturation":-0.26}}]}"#
        let out = ArabicBasemap.gradeSatellite(ArabicBasemap.wrap(ArabicBasemap.tune(old)))
        XCTAssertEqual(ArabicBasemap.gradeSatellite(out), out, "idempotent")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        let imp = try XCTUnwrap((root["imports"] as? [[String: Any]])?.first?["data"] as? [String: Any])
        let schema = try XCTUnwrap(imp["schema"] as? [String: Any])
        XCTAssertNotNil(schema["lightPreset"], "the style's own options kept")
        XCTAssertEqual((schema[SandGrade.configKey] as? [String: Any])?["default"] as? Double, 1)
        let paint = try XCTUnwrap((imp["layers"] as? [[String: Any]])?.first?["paint"] as? [String: Any])
        XCTAssertNotNil(paint["raster-saturation"] as? [Any], "the old desaturation is gone: a zoom / config expression")
        XCTAssertNotNil(paint["raster-hue-rotate"])
        XCTAssertEqual(paint["raster-emissive-strength"] as? Double, 0.3)
        XCTAssertEqual(paint["raster-resampling"] as? String, "linear")
        XCTAssertEqual(paint["raster-brightness-min"] as? Double, 0.02, "shadows lifted a little")
        XCTAssertNil(root["schema"], "the wrapper itself has no satellite layer")
    }

    /// Warm in the open desert, close to the photo in a city; never neon.
    func testSandGradeIsWarmInTheOpenAndMildInCities() {
        for look in [SandGrade.mild, SandGrade.strong] {
            for s in look.saturation {
                XCTAssertGreaterThan(s.desert, 0.1, "the desert is never desaturated")
                XCTAssertLessThanOrEqual(s.desert, 0.4, "not neon")
                XCTAssertLessThanOrEqual(s.city, 0.08, "cities stay close to the photo")
            }
            XCTAssertLessThan(look.saturation.first!.desert, look.saturation.last!.desert, "stronger close in, where the imagery is paler")
            XCTAssertEqual(look.hueRotate.first!.city, 0)
        }
        XCTAssertEqual(SandGrade.sand(urban: 0), 1)
        XCTAssertEqual(SandGrade.sand(urban: 1), 0)
        XCTAssertEqual(SandGrade.sand(urban: 0.52), 0.5, "steps of 0.05")
        let fixed = SandGrade.paint(SandGrade.strong, sand: 1)
        let e = fixed["raster-saturation"] as? [Any]
        XCTAssertEqual(e?.last as? Double, SandGrade.strong.saturation.last!.desert)
        XCTAssertEqual(SandGrade.apply("not json"), "not json")
    }

    /// Owner, Build 44 («ليه الألوان سيئة»): the default grade was neon. «طبيعي» sits between the photo and «دافئ».
    func testNaturalWarmIsBetweenThePhotoAndMild() {
        let n = SandGrade.naturalWarm
        for s in n.saturation {
            XCTAssertLessThanOrEqual(s.desert, 0.10, "no neon dunes or green patches")
            XCTAssertGreaterThan(s.desert, 0, "still a touch warmer than the photo")
            XCTAssertLessThanOrEqual(s.city, 0.04)
        }
        XCTAssertEqual(n.saturation.map(\.desert), [0.04, 0.07, 0.1])
        XCTAssertEqual(n.contrast.last?.desert ?? 0, 0.08, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(n.hueRotate[0].desert, -3)
        XCTAssertLessThanOrEqual(n.hueRotate[0].desert, 0)
        for (a, b) in zip(n.saturation, SandGrade.mild.saturation) { XCTAssertLessThan(a.desert, b.desert) }
        for (a, b) in zip(SandGrade.mild.saturation, SandGrade.strong.saturation) { XCTAssertLessThan(a.desert, b.desert) }
        XCTAssertEqual(SandGrade.strong.saturation.last?.desert, 0.29, "«قوي» is exactly the old look")
        XCTAssertEqual(SandGrade.strong.contrast.last?.desert, 0.17)
        XCTAssertEqual(SandGrade.strong.hueRotate[0].desert, -7)
        XCTAssertEqual(Set(SandGrade.looks.map(\.emissive)), [0.3], "the scene light treats every grade the same")
    }

    /// The setting: three choices, «طبيعي» by default, stored under its own key; the look in force follows it.
    func testGradeChoiceDefaultsToNaturalAndFollowsTheStoredValue() throws {
        let d = try XCTUnwrap(UserDefaults(suiteName: "sandgrade-\(UUID().uuidString)"))
        XCTAssertEqual(SandGrade.choice(d), .natural)
        XCTAssertEqual(SandGrade.defaultChoice.look, SandGrade.naturalWarm)
        for (raw, look) in [("natural", SandGrade.naturalWarm), ("warm", SandGrade.mild), ("strong", SandGrade.strong)] {
            d.set(raw, forKey: SandGrade.choiceKey)
            XCTAssertEqual(SandGrade.choice(d).look, look, raw)
        }
        d.set("garbage", forKey: SandGrade.choiceKey)
        XCTAssertEqual(SandGrade.choice(d), .natural, "unknown value falls back to the default")
        XCTAssertEqual(SandGrade.Choice.allCases.map(\.label), ["طبيعي", "دافئ", "قوي"])
    }

    /// The registry carries the setting (one group of three, one default, the key `SandGrade` reads).
    func testGradeIsRegisteredAsOneChoiceGroup() throws {
        XCTAssertEqual(MapLayerCatalogCheck.issues(MapLayerCatalog.all), [])
        let d = try XCTUnwrap(UserDefaults(suiteName: "sandgrade-reg-\(UUID().uuidString)"))
        let reg = MapLayerRegistry(defaults: d)
        let ids = SandGrade.Choice.allCases.map(MapLayerCatalog.gradeID)
        XCTAssertEqual(ids.filter(reg.isActive), [MapLayerCatalog.gradeID(.natural)])
        reg.setActive(MapLayerCatalog.gradeID(.strong))
        XCTAssertEqual(d.string(forKey: SandGrade.choiceKey), "strong")
        XCTAssertEqual(ids.filter(reg.isActive), [MapLayerCatalog.gradeID(.strong)], "exactly one chosen")
        XCTAssertEqual(SandGrade.choice(d), .strong)
        let section = try XCTUnwrap(MapLayersSheetModel.sections(registry: reg, mode: .explore).first { $0.id == "group.\(MapLayerCatalog.imageryGradeGroup)" })
        XCTAssertEqual(section.rows.map(\.title), ["طبيعي", "دافئ", "قوي"])
        XCTAssertNil(section.off, "an image grade is always one of the three")
    }

    /// The style carries every look and picks one with `saryGrade` (0 = «طبيعي»): a change of the setting is a config write.
    func testPaintHoldsEveryLookChosenByTheGradeOption() throws {
        let looks = SandGrade.looks
        XCTAssertGreaterThanOrEqual(looks.count, 3)
        XCTAssertEqual(Array(looks.prefix(3)), [SandGrade.naturalWarm, SandGrade.mild, SandGrade.strong], "index 0, 1, 2")
        let paint = SandGrade.paint(Array(looks.prefix(3)))
        let sat = try XCTUnwrap(paint["raster-saturation"] as? [Any])
        XCTAssertEqual(sat[0] as? String, "interpolate")
        XCTAssertEqual(sat[3] as? Double, 8)
        let step = try XCTUnwrap(sat[4] as? [Any])
        XCTAssertEqual(step[0] as? String, "step")
        XCTAssertEqual((step[1] as? [Any])?[1] as? String, SandGrade.gradeKey)
        XCTAssertEqual(step[3] as? Double, 1)
        XCTAssertEqual(step[5] as? Double, 2)
        let data = try JSONSerialization.data(withJSONObject: paint, options: [.sortedKeys])
        XCTAssertFalse(data.isEmpty, "the paint is valid JSON")
        /* Fixed to one look and one sand value (the high-res layer): the same numbers as the table. */
        for c in SandGrade.Choice.allCases {
            let fixed = SandGrade.paint(c.look, sand: 1)
            let e = try XCTUnwrap(fixed["raster-saturation"] as? [Any])
            XCTAssertEqual(e.last as? Double ?? 9, c.look.saturation.last!.desert, accuracy: 1e-9)
            let city = SandGrade.paint(c.look, sand: 0)
            XCTAssertEqual((city["raster-saturation"] as? [Any])?.last as? Double ?? 9, c.look.saturation.last!.city, accuracy: 1e-9)
        }
        let styled = SandGrade.apply(#"{"version":8,"sources":{},"layers":[{"id":"s","type":"raster","source":"mapbox://mapbox.satellite"}]}"#)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(styled.utf8)) as? [String: Any])
        let schema = try XCTUnwrap(root["schema"] as? [String: Any])
        XCTAssertEqual((schema[SandGrade.gradeKey] as? [String: Any])?["default"] as? Double, 0, "unset means «طبيعي»")
    }

    func testRouterNarrationIsSpokenOnlyInArabic() {
        XCTAssertFalse(NavText.isArabic("Turn left onto طريق الملك فهد."), "Valhalla's English narration")
        XCTAssertTrue(NavText.isArabic("انعطف يسارًا إلى طريق الملك فهد"))
        XCTAssertFalse(NavText.isArabic("١٢٠"))
    }

    func testThreeTabs() {
        /* Lovable: «الخريطة • الأصدقاء • الطلعة» in the sheet (the word dictionary); the settings behind the header's gear. */
        XCTAssertEqual(LiveTabUI.sheetTabs.map(\.label), ["الخريطة", "الأصدقاء", "الطلعة"])
        XCTAssertEqual(LiveTabUI.more.label, "الإعدادات")
    }
}
