import UIKit
import XCTest
@testable import SaryAlbarq

// MARK: - Pure logic

final class ReturnTimerLogicTests: XCTestCase {
    let now = ISODate.parse("2026-11-04T12:00:00.000Z")!
    func wire(_ due: Date, _ st: ReturnTimerState = .armed) -> ReturnTimerWire {
        ReturnTimerWire(id: "t1", due_at: ISODate.string(due), contact_name: "أم فهد", state: st)
    }

    func testPhases() {
        let due = now.addingTimeInterval(3600)
        XCTAssertEqual(ReturnTimerLogic.phase(nil, availability: .unknown, now: now), .loading)
        XCTAssertEqual(ReturnTimerLogic.phase(nil, availability: .available, now: now), .none)
        XCTAssertEqual(ReturnTimerLogic.phase(wire(due), availability: .notDeployed, now: now), .unavailable, "404 wins: never pretend")
        XCTAssertEqual(ReturnTimerLogic.phase(wire(due), availability: .available, now: now), .armed(due: due, contact: "أم فهد"))
        XCTAssertEqual(ReturnTimerLogic.phase(wire(due), availability: .available, now: due.addingTimeInterval(1)), .overdue(due: due, contact: "أم فهد"),
                       "the clock passed the due time: overdue before the server's sweeper")
        XCTAssertEqual(ReturnTimerLogic.phase(wire(due, .overdue), availability: .available, now: now), .overdue(due: due, contact: "أم فهد"))
        XCTAssertEqual(ReturnTimerLogic.phase(wire(due, .arrived), availability: .available, now: due.addingTimeInterval(99)), .arrived(contact: "أم فهد"))
        XCTAssertEqual(ReturnTimerLogic.phase(wire(due, .cancelled), availability: .available, now: now), .none)
    }

    func testRemindersThirtyAndTenMinutesBeforeAndAtTheTime() {
        let due = now.addingTimeInterval(2 * 3600)
        let r = ReturnTimerLogic.reminders(outingId: "o1", due: due, contact: "أم فهد", now: now)
        XCTAssertEqual(r.map(\.id), ["rt-o1-30", "rt-o1-10", "rt-o1-0"])
        XCTAssertEqual(r.map(\.fireAt), [due.addingTimeInterval(-1800), due.addingTimeInterval(-600), due])
        XCTAssertTrue(r[0].body.contains("٣٠ دقيقة"), r[0].body)
        XCTAssertTrue(r[1].body.contains("١٠ دقائق"), r[1].body)
        XCTAssertTrue(r[0].body.contains("أم فهد"))
        XCTAssertEqual(Set(ReturnTimerLogic.reminderIds("o1")), Set(r.map(\.id)), "cancel removes every id it can schedule")
    }

    func testOnlyFutureRemindersAreScheduled() {
        let r = ReturnTimerLogic.reminders(outingId: "o1", due: now.addingTimeInterval(20 * 60), contact: "س", now: now)
        XCTAssertEqual(r.map(\.id), ["rt-o1-10", "rt-o1-0"], "set 20 min ahead: no 30-minute reminder")
        XCTAssertTrue(ReturnTimerLogic.reminders(outingId: "o1", due: now.addingTimeInterval(-60), contact: "س", now: now).isEmpty)
    }

    func testValidationAndClamp() {
        XCTAssertEqual(ReturnTimerLogic.validate(due: now.addingTimeInterval(3600), contact: "  ", now: now), .noContact)
        XCTAssertEqual(ReturnTimerLogic.validate(due: now.addingTimeInterval(120), contact: "أم فهد", now: now), .tooSoon)
        XCTAssertEqual(ReturnTimerLogic.validate(due: now.addingTimeInterval(30 * 3600), contact: "أم فهد", now: now), .tooLate)
        XCTAssertNil(ReturnTimerLogic.validate(due: now.addingTimeInterval(3600), contact: "أم فهد", now: now))
        XCTAssertEqual(ReturnTimerLogic.cleanContact(String(repeating: "ب", count: 60))?.count, 40)
        XCTAssertEqual(ReturnTimerLogic.clampDue(now, now: now), now.addingTimeInterval(600))
        let s = ReturnTimerLogic.suggestedDue(now: now.addingTimeInterval(7 * 60))
        XCTAssertEqual(s.timeIntervalSince1970.truncatingRemainder(dividingBy: 900), 0, "a quarter hour")
        XCTAssertGreaterThanOrEqual(s, now.addingTimeInterval(3 * 3600 + 7 * 60))
    }

    func testExtendFromTheDueTimeOrFromNow() {
        let ahead = now.addingTimeInterval(600)
        XCTAssertEqual(ReturnTimerLogic.extended(due: ahead, byMinutes: 30, now: now), ahead.addingTimeInterval(1800))
        let past = now.addingTimeInterval(-900)
        XCTAssertEqual(ReturnTimerLogic.extended(due: past, byMinutes: 60, now: now), now.addingTimeInterval(3600), "overdue: an hour from now, not from the missed time")
    }

    func testShareMessageSaysWhatTheContactSeesAndWhen() {
        let url = URL(string: "https://farq-map-investor.vercel.app/watch#" + String(repeating: "a", count: 43))!
        let m = ReturnTimerLogic.shareMessage(contact: "أم فهد", outingName: "كشتة الثمامة", due: now.addingTimeInterval(3600), url: url, now: now)
        XCTAssertTrue(m.hasPrefix("هلا أم فهد"))
        XCTAssertTrue(m.contains("«كشتة الثمامة»"))
        XCTAssertTrue(m.contains("ما تشوف مواقعنا"), "positions are not shown before overdue")
        XCTAssertTrue(m.contains("آخر موقع معروف"), "…and what happens when it is overdue")
        XCTAssertTrue(m.contains("وصلوا بالسلامة"))
        XCTAssertTrue(m.hasSuffix(url.absoluteString))
        let text = m.replacingOccurrences(of: url.absoluteString, with: "")
        XCTAssertNil(text.rangeOfCharacter(from: CharacterSet(charactersIn: "0123456789")), "Arabic-Indic digits outside the link: \(text)")
    }

    func testArabicSpansAndClock() {
        XCTAssertEqual(SafetyFormat.span(minutes: 1), "دقيقة")
        XCTAssertEqual(SafetyFormat.span(minutes: 2), "دقيقتين")
        XCTAssertEqual(SafetyFormat.span(minutes: 10), "١٠ دقائق")
        XCTAssertEqual(SafetyFormat.span(minutes: 45), "٤٥ دقيقة")
        XCTAssertEqual(SafetyFormat.span(minutes: 60), "ساعة")
        XCTAssertEqual(SafetyFormat.span(minutes: 120), "ساعتين")
        XCTAssertEqual(SafetyFormat.span(minutes: 75), "ساعة و١٥ دقيقة")
        XCTAssertEqual(SafetyFormat.span(minutes: 180), "٣ ساعات")
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Riyadh")!
        XCTAssertEqual(SafetyFormat.clock(ISODate.parse("2026-11-04T16:30:00Z")!, calendar: cal), "٧:٣٠ م")
        XCTAssertEqual(SafetyFormat.clock(ISODate.parse("2026-11-04T21:05:00Z")!, calendar: cal), "١٢:٠٥ ص")
        XCTAssertEqual(SafetyFormat.remaining(until: now.addingTimeInterval(80 * 60 - 5), now: now), "باقي ساعة و٢٠ دقيقة")
        XCTAssertEqual(SafetyFormat.remaining(until: now.addingTimeInterval(3 * 3600 + 60), now: now), "باقي ٣ ساعات", "past an hour, to 5 minutes")
        XCTAssertEqual(SafetyFormat.remaining(until: now.addingTimeInterval(7 * 60 + 10), now: now), "باقي ٨ دقائق")
        XCTAssertEqual(SafetyFormat.late(since: now.addingTimeInterval(-12 * 60), now: now), "متأخر ١٢ دقيقة")
    }

    func testWatchLinkFormatAndStore() {
        let tok = String(repeating: "Ab9_-", count: 8) + "xyz"
        XCTAssertEqual(tok.count, 43)
        XCTAssertNotNil(WatchLinkStore.valid("https://farq-map-investor.vercel.app/watch#\(tok)"))
        XCTAssertNil(WatchLinkStore.valid("http://farq-map-investor.vercel.app/watch#\(tok)"), "https only")
        XCTAssertNil(WatchLinkStore.valid("https://farq-map-investor.vercel.app/watch#short"))
        XCTAssertNil(WatchLinkStore.valid("https://farq-map-investor.vercel.app/watch?t=\(tok)"), "the token stays in the fragment, never a query")
        let d = UserDefaults(suiteName: UUID().uuidString)!
        let u = URL(string: "https://farq-map-investor.vercel.app/watch#\(tok)")!
        WatchLinkStore.save("o1", u, defaults: d)
        XCTAssertEqual(WatchLinkStore.load("o1", defaults: d), u)
        WatchLinkStore.save("o1", nil, defaults: d)
        XCTAssertNil(WatchLinkStore.load("o1", defaults: d))
    }

    func testNotDeployedIsOnlyABare404() {
        XCTAssertTrue(OutingAPIError(code: "http_404", status: 404).isNotDeployed)
        XCTAssertTrue(OutingAPIError(code: "http_405", status: 405).isNotDeployed)
        XCTAssertFalse(OutingAPIError(code: "not_a_member", status: 404).isNotDeployed, "a coded 404 is a real answer")
        XCTAssertFalse(OutingAPIError(code: "http_500", status: 500).isNotDeployed)
    }
}

final class SafetyWireTests: XCTestCase {
    func testDecodesTheFourEvents() {
        XCTAssertEqual(LiveEvent.decode(["type": "return_timer", "user_id": "u1", "state": "overdue", "due_at": "2026-11-04T12:00:00.000Z"]),
                       .safety(.returnTimer(userId: "u1", state: .overdue, dueAt: "2026-11-04T12:00:00.000Z")))
        XCTAssertEqual(LiveEvent.decode(["type": "member_stuck", "user_id": "u2", "at": "2026-11-04T12:00:00.000Z", "note": "طعس"]),
                       .safety(.stuck(userId: "u2", at: "2026-11-04T12:00:00.000Z", note: "طعس")))
        XCTAssertEqual(LiveEvent.decode(["type": "member_stuck", "user_id": "u2", "at": "x", "note": NSNull()]),
                       .safety(.stuck(userId: "u2", at: "x", note: nil)))
        XCTAssertEqual(LiveEvent.decode(["type": "stuck_reply", "user_id": "u3", "to_user_id": "u2", "kind": "have_rope"]),
                       .safety(.stuckReply(userId: "u3", toUserId: "u2", kind: .have_rope)))
        XCTAssertEqual(LiveEvent.decode(["type": "stuck_clear", "user_id": "u2"]), .safety(.stuckClear(userId: "u2")))
    }

    func testIgnoresMalformedFrames() {
        XCTAssertNil(LiveEvent.decode(["type": "stuck_reply", "user_id": "u3", "to_user_id": "u2", "kind": "maybe"]))
        XCTAssertNil(LiveEvent.decode(["type": "return_timer", "user_id": "u1", "state": "exploded"]))
        XCTAssertNil(LiveEvent.decode(["type": "member_stuck"]))
        XCTAssertNil(LiveEvent.decode(["type": "something_new", "user_id": "u1"]))
    }

    func testSnapshotCarriesStuckAndTimerBoxDecodesLoosely() throws {
        let snap = DemoData.view().snapshot
        var obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(snap)) as! [String: Any]
        obj["stuck"] = [["user_id": "u2", "at": "2026-11-04T12:00:00.000Z", "note": NSNull(), "replies": [["user_id": "u3", "kind": "coming"]]]]
        let s = try JSONDecoder().decode(OutingSnapshot.self, from: JSONSerialization.data(withJSONObject: obj))
        XCTAssertEqual(s.stuck, [StuckWire(user_id: "u2", at: "2026-11-04T12:00:00.000Z", note: nil, replies: [StuckReplyWire(user_id: "u3", kind: .coming)])])
        XCTAssertNil(try JSONDecoder().decode(OutingSnapshot.self, from: JSONEncoder().encode(snap)).stuck, "an older server: nil, not empty")
        XCTAssertEqual(try JSONDecoder().decode(ReturnTimerBox.self, from: Data(#"{"ok":true,"timer":null}"#.utf8)), ReturnTimerBox(timer: nil, watch_url: nil))
        XCTAssertEqual(try JSONDecoder().decode(ReturnTimerBox.self, from: Data(#"{"ok":true}"#.utf8)), ReturnTimerBox())
    }
}

final class StuckLogicTests: XCTestCase {
    let now = ISODate.parse("2026-11-04T12:00:00.000Z")!

    func testReportReplyChangeOfMindAndClear() {
        var r: [String: StuckReport] = [:]
        StuckLogic.apply(.stuck(userId: "s", at: "2026-11-04T11:59:00.000Z", note: nil), to: &r, clockOffsetMs: 0, now: now)
        StuckLogic.apply(.stuckReply(userId: "a", toUserId: "s", kind: .cant), to: &r, clockOffsetMs: 0, now: now)
        StuckLogic.apply(.stuckReply(userId: "b", toUserId: "s", kind: .coming), to: &r, clockOffsetMs: 0, now: now)
        StuckLogic.apply(.stuckReply(userId: "a", toUserId: "s", kind: .have_rope), to: &r, clockOffsetMs: 0, now: now)
        XCTAssertEqual(r["s"]?.replies, ["a": .have_rope, "b": .coming], "the latest answer per friend")
        StuckLogic.apply(.stuckReply(userId: "a", toUserId: "nobody", kind: .coming), to: &r, clockOffsetMs: 0, now: now)
        XCTAssertNil(r["nobody"], "a reply to someone not stuck creates nothing")
        StuckLogic.apply(.stuckReply(userId: "s", toUserId: "s", kind: .coming), to: &r, clockOffsetMs: 0, now: now)
        XCTAssertNil(r["s"]?.replies["s"], "no answering yourself")
        StuckLogic.apply(.stuck(userId: "s", at: "2026-11-04T12:00:00.000Z", note: "ثاني"), to: &r, clockOffsetMs: 0, now: now)
        XCTAssertEqual(r["s"]?.replies, [:], "stuck again is a fresh report")
        StuckLogic.apply(.stuckClear(userId: "s"), to: &r, clockOffsetMs: 0, now: now)
        XCTAssertTrue(r.isEmpty)
    }

    func testSummaryAndOrder() {
        var rep = StuckReport(userId: "s", at: now)
        XCTAssertEqual(StuckLogic.summary(rep), "ما رد أحد بعد")
        XCTAssertFalse(StuckLogic.helpComing(rep))
        rep.replies = ["c": .cant, "a": .coming, "b": .coming, "d": .have_rope]
        XCTAssertEqual(StuckLogic.summary(rep), "٢ جايين • ١ معه حبل • ١ ما يقدر")
        XCTAssertTrue(StuckLogic.helpComing(rep))
        let names = ["a": "سعد", "b": "أبو فهد", "c": "نورة", "d": "سلطان"]
        let lines = StuckLogic.replyLines(rep, name: { names[$0] }, color: { _ in 0 })
        XCTAssertEqual(lines.map(\.kind), [.coming, .coming, .have_rope, .cant], "helpful first")
        XCTAssertEqual(lines.map(\.name), ["أبو فهد", "سعد", "سلطان", "نورة"])
    }

    func testSnapshotPruneAndExpiry() {
        let wire = [StuckWire(user_id: "s", at: "2026-11-04T11:00:00.000Z", note: "", replies: [.init(user_id: "a", kind: .coming), .init(user_id: "s", kind: .coming)]),
                    StuckWire(user_id: "old", at: "2026-11-04T08:00:00.000Z", note: nil, replies: nil)]
        var r = StuckLogic.fromSnapshot(wire, clockOffsetMs: 0, now: now)
        XCTAssertEqual(Set(r.keys), ["s"], "3 h old is gone, like the server")
        XCTAssertNil(r["s"]?.note, "empty note is no note")
        XCTAssertEqual(r["s"]?.replies, ["a": .coming])
        StuckLogic.prune(&r, members: ["s"], now: now)
        XCTAssertEqual(r["s"]?.replies, [:], "a friend who left no longer answers")
        StuckLogic.prune(&r, members: [], now: now)
        XCTAssertTrue(r.isEmpty)
    }
}

final class SunsetWayBackTests: XCTestCase {
    func testRiyadhSunsetMatchesTheAlmanac() throws {
        /* Riyadh 4 Nov 2026: sunset ≈ 17:12 AST (14:12 UTC). */
        let noon = ISODate.parse("2026-11-04T09:00:00.000Z")!
        let s = try XCTUnwrap(SunTimes.sunset(near: noon, lat: 24.7136, lng: 46.6753))
        let expected = ISODate.parse("2026-11-04T14:12:00.000Z")!
        XCTAssertEqual(s.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 4 * 60, "\(s)")
        XCTAssertEqual(SunLight.elevationDeg(s, lat: 24.7136, lng: 46.6753), SunTimes.horizonDeg, accuracy: 0.05)
    }

    func testJustAfterSunsetStillReturnsIt_andPolarNightHasNone() throws {
        let noon = ISODate.parse("2026-11-04T09:00:00.000Z")!
        let s = try XCTUnwrap(SunTimes.sunset(near: noon, lat: 24.7136, lng: 46.6753))
        XCTAssertEqual(SunTimes.sunset(near: s.addingTimeInterval(20 * 60), lat: 24.7136, lng: 46.6753)!.timeIntervalSince1970, s.timeIntervalSince1970, accuracy: 2)
        XCTAssertNil(SunTimes.sunset(near: ISODate.parse("2026-12-21T12:00:00.000Z")!, lat: 85, lng: 0), "no sunset in polar night")
    }

    func testMovingSpeedIgnoresIdleAndNeedsEnoughDriving() {
        var m = MovingSpeed()
        let t0 = 1_800_000_000_000.0
        for i in 0..<10 { m.add(speed: 0.5, accuracy: 5, atMs: t0 + Double(i) * 5000) }
        XCTAssertNil(m.average(nowMs: t0 + 60_000), "parked: no driving speed")
        for i in 0..<5 { m.add(speed: 10, accuracy: 5, atMs: t0 + 100_000 + Double(i) * 5000) }
        XCTAssertNil(m.average(nowMs: t0 + 130_000), "five readings is not enough")
        m.add(speed: 16, accuracy: 5, atMs: t0 + 130_000)
        m.add(speed: 90, accuracy: 5, atMs: t0 + 135_000)
        m.add(speed: 12, accuracy: 200, atMs: t0 + 140_000)
        XCTAssertEqual(m.average(nowMs: t0 + 140_000)!, 11, accuracy: 0.001, "noise and bad accuracy are dropped")
        XCTAssertNil(m.average(nowMs: t0 + 140_000 + 21 * 60_000), "only the last 20 minutes count")
    }

    func testWayBackBounds() {
        XCTAssertNil(WayBack.seconds(remainingM: nil, averageMps: 10), "no trail: no estimate")
        XCTAssertNil(WayBack.seconds(remainingM: 300, averageMps: 10), "already there")
        XCTAssertEqual(WayBack.seconds(remainingM: 30_000, averageMps: 10)!, 3000, accuracy: 0.1)
        XCTAssertEqual(WayBack.seconds(remainingM: 30_000, averageMps: 1)!, 30_000 / (10 / 3.6), accuracy: 0.1, "never slower than 10 km/h")
        XCTAssertEqual(WayBack.seconds(remainingM: 30_000, averageMps: 60)!, 30_000 / (80 / 3.6), accuracy: 0.1, "never faster than 80 km/h")
        XCTAssertEqual(WayBack.seconds(remainingM: 30_000, averageMps: nil)!, 3600, accuracy: 0.1, "no driving yet: 30 km/h")
    }

    func testWarningThresholdsOncePerStep() {
        let now = ISODate.parse("2026-11-04T13:12:00.000Z")!
        let sunset = now.addingTimeInterval(60 * 60)
        /* Way back 45 min ≥ 60 − 30: warn. */
        let w = SunsetWarning.evaluate(now: now, sunset: sunset, wayBackS: 45 * 60, warned: [])
        XCTAssertEqual(w?.step, 60)
        XCTAssertEqual(w?.title, "باقي ساعة على المغرب وطريق الرجعة ٤٥ دقيقة تقريبًا")
        XCTAssertNil(SunsetWarning.evaluate(now: now, sunset: sunset, wayBackS: 45 * 60, warned: [60]), "once per step")
        XCTAssertNil(SunsetWarning.evaluate(now: now, sunset: sunset, wayBackS: 20 * 60, warned: []), "20 min back with an hour left: no need")
        XCTAssertNil(SunsetWarning.evaluate(now: now, sunset: sunset, wayBackS: nil, warned: []), "no trail: silent")
        /* Later, the next step warns again. */
        let later = now.addingTimeInterval(20 * 60)
        XCTAssertEqual(SunsetWarning.evaluate(now: later, sunset: sunset, wayBackS: 45 * 60, warned: [60])?.step, 45)
        /* After sunset: once, then quiet after 45 min. */
        XCTAssertEqual(SunsetWarning.evaluate(now: sunset.addingTimeInterval(600), sunset: sunset, wayBackS: 45 * 60, warned: [60, 45, 30, 15])?.title,
                       "غابت الشمس وطريق الرجعة ٤٥ دقيقة تقريبًا")
        XCTAssertNil(SunsetWarning.evaluate(now: sunset.addingTimeInterval(50 * 60), sunset: sunset, wayBackS: 45 * 60, warned: []))
        XCTAssertEqual(SunsetWarning.step(minutesToSunset: 100), 120)
        XCTAssertEqual(SunsetWarning.step(minutesToSunset: 59.5), 60)
        XCTAssertEqual(SunsetWarning.step(minutesToSunset: 3), 15)
        XCTAssertNil(SunsetWarning.step(minutesToSunset: 300), "far from sunset: no step")
    }

    func testSymbolsExist() {
        for s in SafetyIcon.all { XCTAssertNotNil(UIImage(systemName: s), s) }
    }
}

// MARK: - Fake-API flows

final class FakeSafetyBackend: SafetyBackend {
    var calls: [String] = []
    var error: OutingAPIError?
    var timer: ReturnTimerWire?
    var nextLink = "https://farq-map-investor.vercel.app/watch#" + String(repeating: "A", count: 43)

    private func check(_ c: String) throws {
        calls.append(c)
        if let error { throw error }
    }

    func returnTimer(_ outingId: String) async throws -> ReturnTimerBox {
        try check("GET return-timer")
        return ReturnTimerBox(timer: timer, watch_url: nil)
    }
    func setReturnTimer(_ outingId: String, dueAt: Date, contactName: String) async throws -> ReturnTimerBox {
        try check("POST return-timer \(ISODate.string(dueAt)) \(contactName)")
        timer = ReturnTimerWire(id: "t", due_at: ISODate.string(dueAt), contact_name: contactName, state: .armed)
        return ReturnTimerBox(timer: timer, watch_url: nextLink)
    }
    func returnTimerArrived(_ outingId: String) async throws -> ReturnTimerBox {
        try check("POST arrived")
        timer?.state = .arrived
        return ReturnTimerBox(timer: timer, watch_url: nil)
    }
    func cancelReturnTimer(_ outingId: String) async throws { try check("DELETE return-timer"); timer = nil }
    func reportStuck(_ outingId: String, note: String?) async throws { try check("POST stuck \(note ?? "-")") }
    func replyStuck(_ outingId: String, to userId: String, kind: StuckReplyKind) async throws { try check("POST reply \(userId) \(kind.rawValue)") }
    func clearStuck(_ outingId: String) async throws { try check("DELETE stuck") }
}

final class FakeReminders: ReminderScheduling {
    var scheduled: [String: ReturnTimerLogic.Reminder] = [:]
    var allowed = true
    func replace(_ reminders: [ReturnTimerLogic.Reminder], removing ids: [String], outingId: String) {
        for id in ids { scheduled[id] = nil }
        for r in reminders { scheduled[r.id] = r }
    }
    func authorized() async -> Bool { allowed }
}

@MainActor
final class SafetyControllerTests: XCTestCase {
    var api: FakeSafetyBackend!
    var reminders: FakeReminders!
    var safety: SafetyController!
    var clock = ISODate.parse("2026-11-04T12:00:00.000Z")!
    var alerts: [String: LiveAlertUI] = [:]
    var toasts: [String] = []
    var demo: OutingView!
    var fix: DeviceFix?

    let me = DemoData.meId
    let abuFahd = "00000000-0000-4000-8000-000000000002"
    let sultan = "00000000-0000-4000-8000-000000000003"

    override func setUp() {
        api = FakeSafetyBackend()
        reminders = FakeReminders()
        alerts = [:]
        toasts = []
        demo = DemoData.view(now: clock)
        fix = DeviceFix(lat: 24.7100, lng: 46.6700, accuracy: 5, heading: nil, speed: 0, atMs: clock.timeIntervalSince1970 * 1000)
        safety = SafetyController(outingId: DemoData.outingId, myId: me, backend: api, scheduler: reminders, defaults: UserDefaults(suiteName: UUID().uuidString)!)
        safety.now = { [unowned self] in clock }
        safety.view = { [unowned self] in demo }
        safety.myFix = { [unowned self] in fix }
        safety.upsertAlert = { [unowned self] a, _ in alerts[a.id] = a }
        safety.removeAlert = { [unowned self] id in alerts[id] = nil }
        safety.toast = { [unowned self] t in toasts.append(t) }
    }

    func testNotDeployedSaysSoHonestly() async {
        api.error = OutingAPIError(code: "http_404", status: 404)
        await safety.load()
        XCTAssertEqual(safety.timerPhase, .unavailable)
        safety.askStuck()
        XCTAssertTrue(safety.confirmStuck, "stuck is not known missing until tried")
        await safety.reportStuck()
        XCTAssertEqual(safety.stuckAvailability, .notDeployed)
        XCTAssertNil(safety.myStuck, "never shown as sent")
        XCTAssertEqual(toasts.last, "«غرّزت» غير متاح بعد")
        safety.askStuck()
        XCTAssertFalse(safety.confirmStuck, "then the button just says so")
    }

    func testArmSharesTheLinkSchedulesRemindersThenArrived() async {
        await safety.load()
        XCTAssertEqual(safety.timerPhase, .none)
        safety.editorOpen = true
        let due = clock.addingTimeInterval(3 * 3600)
        await safety.arm(due: due, contact: "  أم   فهد ")
        XCTAssertEqual(api.calls.last, "POST return-timer \(ISODate.string(due)) أم فهد")
        XCTAssertEqual(safety.timerPhase, .armed(due: due, contact: "أم فهد"))
        XCTAssertFalse(safety.editorOpen)
        XCTAssertEqual(safety.watchURL?.absoluteString, api.nextLink)
        XCTAssertTrue(safety.shareText?.hasSuffix(api.nextLink) == true, "the share sheet opens with the message and the link")
        XCTAssertEqual(Set(reminders.scheduled.keys), Set(ReturnTimerLogic.reminderIds(DemoData.outingId)))
        XCTAssertEqual(reminders.scheduled["rt-\(DemoData.outingId)-30"]?.fireAt, due.addingTimeInterval(-1800))

        await safety.arrived()
        XCTAssertEqual(api.calls.last, "POST arrived")
        XCTAssertEqual(safety.timerPhase, .arrived(contact: "أم فهد"))
        XCTAssertTrue(reminders.scheduled.isEmpty, "no reminders after «وصلت»")
        XCTAssertNil(safety.watchURL, "the link is forgotten on this phone")
        XCTAssertTrue(toasts.last?.contains("أم فهد") == true)
    }

    func testOverdueEventPromptsThenExtendRearms() async {
        await safety.load()
        await safety.arm(due: clock.addingTimeInterval(3600), contact: "أم فهد")
        safety.overduePrompt = false
        clock = clock.addingTimeInterval(3700)
        safety.handle(.returnTimer(userId: me, state: .overdue, dueAt: api.timer!.due_at))
        XCTAssertTrue(safety.overduePrompt, "«مدّد / وصلت»")
        XCTAssertNotNil(alerts["safety:overdue:me"])
        XCTAssertTrue(reminders.scheduled.isEmpty, "overdue: the reminders are spent")

        api.nextLink = "https://farq-map-investor.vercel.app/watch#" + String(repeating: "B", count: 43)
        await safety.extend(minutes: 60)
        XCTAssertEqual(api.calls.last, "POST return-timer \(ISODate.string(clock.addingTimeInterval(3600))) أم فهد", "an hour from now")
        XCTAssertEqual(safety.timerPhase, .armed(due: clock.addingTimeInterval(3600), contact: "أم فهد"))
        XCTAssertNil(alerts["safety:overdue:me"])
        XCTAssertFalse(safety.overduePrompt)
        XCTAssertEqual(safety.watchURL?.absoluteString, api.nextLink, "re-arm with the same contact: the old link keeps working, the new one is kept too")
        XCTAssertTrue(toasts.last?.contains("يبقى شغال") == true, toasts.last ?? "")
        XCTAssertEqual(reminders.scheduled.count, 3)
    }

    func testLocalClockMakesItOverdueWithoutTheServer() async {
        await safety.load()
        await safety.arm(due: clock.addingTimeInterval(1200), contact: "أم فهد")
        clock = clock.addingTimeInterval(1260)
        safety.tick()
        XCTAssertTrue(safety.overduePrompt)
        XCTAssertNotNil(alerts["safety:overdue:me"])
    }

    func testOpeningAnOverdueTimerPrompts() async {
        api.timer = ReturnTimerWire(id: "t", due_at: ISODate.string(clock.addingTimeInterval(-600)), contact_name: "أم فهد", state: .overdue)
        await safety.load()
        XCTAssertTrue(safety.overduePrompt, "the overdue push opens the outing; the prompt follows from the timer itself")
    }

    func testServerSaysNoTimerOrNotStuck() async {
        await safety.load()
        await safety.arm(due: clock.addingTimeInterval(3600), contact: "أم فهد")
        api.error = OutingAPIError(code: "no_timer", status: 404)
        await safety.arrived()
        XCTAssertEqual(safety.timerPhase, .none, "a coded 404 is a real answer: the timer is gone, not «غير متاح بعد»")
        XCTAssertNil(safety.errorText)
        XCTAssertTrue(reminders.scheduled.isEmpty)

        api.error = nil
        safety.handle(.stuck(userId: sultan, at: ISODate.string(clock), note: nil))
        api.error = OutingAPIError(code: "not_stuck", status: 404)
        await safety.reply(to: sultan, .coming)
        XCTAssertFalse(safety.isStuck(sultan))
        XCTAssertNil(alerts["safety:stuck:\(sultan)"])
        XCTAssertEqual(safety.stuckAvailability, .available)

        api.error = OutingAPIError(code: "outing_ended", status: 409)
        await safety.reportStuck()
        XCTAssertEqual(safety.errorText, "انتهت هذه الطلعة.")
        XCTAssertNil(safety.myStuck)
        XCTAssertEqual(OutingAPIError(code: "invalid_due_at", status: 400).safetyArabic, "اختر وقت رجوع بعد دقيقة على الأقل، وخلال ٧ أيام.")
    }

    func testCancel() async {
        await safety.load()
        await safety.arm(due: clock.addingTimeInterval(3600), contact: "أم فهد")
        await safety.cancelTimer()
        XCTAssertEqual(api.calls.last, "DELETE return-timer")
        XCTAssertEqual(safety.timerPhase, .none)
        XCTAssertTrue(reminders.scheduled.isEmpty)
    }

    func testFriendStuckCardRepliesAndClear() async {
        safety.handle(.stuck(userId: sultan, at: ISODate.string(clock), note: "طعس"))
        guard case let .safety(.friendStuck(card))? = alerts["safety:stuck:\(sultan)"]?.kind else { return XCTFail("no card") }
        XCTAssertEqual(card.name, "سلطان")
        XCTAssertEqual(card.note, "طعس")
        XCTAssertNotNil(card.distanceMeters, "distance from my fix to their last real fix")
        XCTAssertTrue(card.positionStale, "سلطان's fix is 95 s old in the demo: said, never shown as live")
        XCTAssertNil(card.myReply)

        safety.handle(.stuckReply(userId: abuFahd, toUserId: sultan, kind: .coming))
        await safety.reply(to: sultan, .have_rope)
        XCTAssertEqual(api.calls.last, "POST reply \(sultan) have_rope")
        guard case let .safety(.friendStuck(after))? = alerts["safety:stuck:\(sultan)"]?.kind else { return XCTFail("no card") }
        XCTAssertEqual(after.myReply, .have_rope)
        XCTAssertEqual(after.others, "١ جاي", "the others' answers, not mine")

        safety.handle(.stuckClear(userId: sultan))
        XCTAssertNil(alerts["safety:stuck:\(sultan)"], "«طلعت» removes the card")
        XCTAssertFalse(safety.isStuck(sultan))
    }

    func testIAmStuckAndSeeReplies() async {
        safety.isSharingNow = { false }
        await safety.reportStuck(note: "  بنشر ")
        XCTAssertEqual(api.calls.last, "POST stuck بنشر")
        XCTAssertNotNil(safety.myStuck)
        XCTAssertTrue(toasts.last?.contains("موقعك غير مُشارَك") == true, "honest: friends do not see where I am")
        safety.handle(.stuckReply(userId: abuFahd, toUserId: me, kind: .coming))
        XCTAssertEqual(safety.myStuck?.replies[abuFahd], .coming)
        XCTAssertEqual(toasts.last, "أبو فهد جاي")
        XCTAssertNil(alerts["safety:stuck:\(me)"], "no card about myself")
        await safety.clearStuck()
        XCTAssertEqual(api.calls.last, "DELETE stuck")
        XCTAssertNil(safety.myStuck)
    }

    func testSnapshotReplacesTheStuckPicture() {
        demo.snapshot.stuck = [StuckWire(user_id: sultan, at: ISODate.string(clock), note: nil, replies: [.init(user_id: me, kind: .coming)])]
        demo.snapshot.server_now = ISODate.string(clock.addingTimeInterval(1))
        safety.syncView()
        XCTAssertTrue(safety.isStuck(sultan))
        guard case let .safety(.friendStuck(card))? = alerts["safety:stuck:\(sultan)"]?.kind else { return XCTFail("no card") }
        XCTAssertEqual(card.myReply, .coming)
        demo.snapshot.stuck = []
        demo.snapshot.server_now = ISODate.string(clock.addingTimeInterval(2))
        safety.syncView()
        XCTAssertFalse(safety.isStuck(sultan))
        XCTAssertNil(alerts["safety:stuck:\(sultan)"])
    }

    func testFriendTimerOverdueCard() {
        safety.handle(.returnTimer(userId: abuFahd, state: .overdue, dueAt: nil))
        XCTAssertNotNil(alerts["safety:overdue:\(abuFahd)"])
        safety.handle(.returnTimer(userId: abuFahd, state: .arrived, dueAt: nil))
        XCTAssertNil(alerts["safety:overdue:\(abuFahd)"])
        XCTAssertFalse(safety.overduePrompt, "a friend's timer never prompts me")
    }

    func testSunsetWarningOncePerStepFromTheController() {
        /* Riyadh, 70 min before sunset, 25 km back along the trail at a measured ~30 km/h. */
        clock = ISODate.parse("2026-11-04T13:02:00.000Z")!
        safety.wayBackDistanceM = { 25_000 }
        for i in 0..<8 {
            fix = DeviceFix(lat: 24.71, lng: 46.67, accuracy: 5, heading: nil, speed: 8.4, atMs: clock.timeIntervalSince1970 * 1000 - Double(8 - i) * 10_000)
            safety.locationChanged()
        }
        guard case let .safety(.sunset(title, _))? = alerts["safety:sunset"]?.kind else { return XCTFail("no warning: \(String(describing: safety.wayBackS)) \(String(describing: safety.sunset))") }
        XCTAssertTrue(title.contains("على المغرب"), title)
        XCTAssertTrue(title.contains("طريق الرجعة ٥٠ دقيقة"), title)
        alerts = [:]
        safety.tick()
        XCTAssertNil(alerts["safety:sunset"], "once per step")
        XCTAssertNotNil(safety.sunsetLine)
    }

    func testNoSunsetWarningWithoutATrail() {
        clock = ISODate.parse("2026-11-04T13:30:00.000Z")!
        safety.locationChanged()
        XCTAssertNil(alerts["safety:sunset"])
        XCTAssertNotNil(safety.sunset)
        XCTAssertNil(safety.wayBackS)
    }
}

// MARK: - End to end against a real server (opt-in)

/// Runs only with `TEST_RUNNER_SARY_E2E_BASE=http://127.0.0.1:<port>` pointing at a LOCAL
/// API from feat/outing-features-api (throwaway Postgres). Never production.
@MainActor
final class SafetyEndToEndTests: XCTestCase {
    func base() throws -> URL {
        guard let s = ProcessInfo.processInfo.environment["SARY_E2E_BASE"], let u = URL(string: s),
              u.host == "127.0.0.1" || u.host == "localhost" else { throw XCTSkip("set SARY_E2E_BASE to a local API") }
        return u
    }

    func client(_ base: URL, _ name: String) async throws -> (OutingsAPI, Identity) {
        var token: String?
        let api = OutingsAPI(base: base, tokenProvider: { token })
        let id = try await api.createIdentity(name: name)
        token = id.token
        return (api, id)
    }

    func controller(_ api: OutingsAPI, outing: String, me: String) -> SafetyController {
        let s = SafetyController(outingId: outing, myId: me, backend: api, scheduler: FakeReminders(), defaults: UserDefaults(suiteName: UUID().uuidString)!)
        s.toast = { _ in }
        return s
    }

    func testReturnTimerAndStuckAgainstTheRealServer() async throws {
        let b = try base()
        let (apiA, a) = try await client(b, "أمير الطلعة")
        let (apiB, bId) = try await client(b, "أبو فهد")
        let created = try await apiA.create(name: "طلعة اختبار", personal: false)
        let oid = created.outing_id
        _ = try await apiA.setStatus(oid, action: "start")
        _ = try await apiB.join(token: try XCTUnwrap(created.invite).token)

        // Return timer: arm, extend (same contact, same timer, old link still valid), arrived.
        let sa = controller(apiA, outing: oid, me: a.user.id)
        await sa.load()
        XCTAssertEqual(sa.timerPhase, .none)
        await sa.arm(due: Date().addingTimeInterval(2 * 3600), contact: "أم فهد")
        XCTAssertNil(sa.errorText)
        let link1 = try XCTUnwrap(sa.watchURL, "the server's watch_url passes our format check")
        let timerId = sa.timer?.id
        await sa.extend(minutes: 60)
        XCTAssertNil(sa.errorText)
        XCTAssertEqual(sa.timer?.id, timerId, "«مدّد» keeps the same timer")
        let status1 = try await watchStatus(b, link1)
        XCTAssertEqual(status1["state"] as? String, "armed", "the first link still works after extending")
        XCTAssertNil(status1["last_known"], "no positions before overdue")
        await sa.arrived()
        XCTAssertEqual(sa.timerPhase, .arrived(contact: "أم فهد"))
        let status2 = try await watchStatus(b, link1)
        XCTAssertEqual(status2["state"] as? String, "arrived")
        let after = try await apiA.returnTimer(oid)
        XCTAssertNil(after.timer, "GET shows only armed/overdue")

        // Stuck: A reports, B sees it in /live and answers, A sees the answer, A clears.
        await sa.reportStuck(note: "طعس")
        XCTAssertNil(sa.errorText)
        let sb = controller(apiB, outing: oid, me: bId.user.id)
        var viewB = OutingView(try await apiB.poll(oid))
        sb.view = { viewB }
        sb.syncView()
        XCTAssertTrue(sb.isStuck(a.user.id), "the /live snapshot carries `stuck`")
        await sb.reply(to: a.user.id, .coming)
        XCTAssertNil(sb.errorText)
        let snapA = try await apiA.poll(oid)
        XCTAssertEqual(snapA.stuck?.first?.replies, [StuckReplyWire(user_id: bId.user.id, kind: .coming)])
        await sa.clearStuck()
        XCTAssertNil(sa.myStuck)
        viewB = OutingView(try await apiB.poll(oid))
        XCTAssertEqual(viewB.snapshot.stuck ?? [], [])
        await sb.reply(to: a.user.id, .coming)
        XCTAssertFalse(sb.isStuck(a.user.id), "404 not_stuck: the report is gone")
        XCTAssertNil(sb.errorText)
    }

    private func watchStatus(_ base: URL, _ link: URL) async throws -> [String: Any] {
        var req = URLRequest(url: base.appendingPathComponent("api/outings/watch/status"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["token": link.fragment ?? ""])
        let (d, _) = try await URLSession.shared.data(for: req)
        return (try JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
    }
}
