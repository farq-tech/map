import XCTest
@testable import SaryAlbarq

/// The Live Activity's content: what is decided in the app (builder, throttle)
/// and what the widget lays out (display).
final class OutingActivityTests: XCTestCase {
    private let now = ISODate.parse("2026-11-04T12:00:00.000Z")!
    private func iso(_ agoS: Double) -> String { ISODate.string(now.addingTimeInterval(-agoS)) }

    private func member(_ id: String, _ name: String, role: String = "member", sharing: Bool = true, joined: Int, sos: SosInfo? = nil) -> Member {
        Member(user_id: id, display_name: name, avatar: nil, phone: nil, role: role, sharing: sharing, joined_at: "2026-11-04T10:0\(joined):00.000Z",
               online: true, away: false, last_seen_at: iso(2), gps: .ok, note: nil, co_leader: nil, battery: nil, sos: sos)
    }

    private func pos(_ id: String, lat: Double, ago: Double, speed: Double = 10) -> Position {
        Position(user_id: id, lat: lat, lng: 46.70, accuracy: 5, heading: 0, speed: speed, mode: .balanced, recorded_at: iso(ago))
    }

    /// Me + «فهد» live 1.1 km north, «سعد» live 3.3 km north, «ريم» 4 min old 5.5 km north.
    private func view(sos: [String: SosInfo] = [:], status: OutingStatus = .active) -> OutingView {
        OutingView(OutingSnapshot(
            outing: OutingInfo(id: "o", name: "طلعة", status: status, owner_id: "me"),
            me: SnapshotMe(user_id: "me", role: "owner", sharing: true),
            members: [member("me", "أنا", role: "owner", joined: 0, sos: sos["me"]), member("a", "فهد", joined: 1, sos: sos["a"]),
                      member("b", "سعد", joined: 2, sos: sos["b"]), member("c", "ريم", joined: 3)],
            positions: [pos("a", lat: 24.71, ago: 3), pos("b", lat: 24.73, ago: 5), pos("c", lat: 24.75, ago: 240)],
            invite: nil, server_now: ISODate.string(now)
        ), deviceNow: now)
    }

    private func input(_ v: OutingView, fixAgeS: Double = 1, gps: GpsState = .ok, link: LiveChannel.State = .live, sharing: Bool = true) -> LivePresenterInput {
        var i = LivePresenterInput()
        i.view = v
        i.myFix = DeviceFix(lat: 24.70, lng: 46.70, accuracy: 5, heading: nil, speed: 0, atMs: (now.timeIntervalSince1970 - fixAgeS) * 1000)
        i.gpsState = gps
        i.locationAuthorized = true
        i.link = link
        i.wantsToShare = sharing
        i.isSharingNow = sharing
        i.now = now
        return i
    }

    // MARK: builder

    func testCountsOnlyLiveMembersAndFarthestIsNeverStale() throws {
        let s = try XCTUnwrap(OutingActivityBuilder.state(input(view()), backMeters: 6_100))
        XCTAssertEqual(s.memberCount, 4)
        XCTAssertEqual(s.liveCount, 3, "me (sharing, fresh fix) + فهد + سعد; ريم's 4 min old fix is not live")
        XCTAssertEqual(s.farthestName, "سعد", "ريم is farther but stale: never shown as current")
        XCTAssertEqual(try XCTUnwrap(s.farthestMeters), 3_336, accuracy: 15)
        XCTAssertEqual(s.backMeters, 6_100)
        XCTAssertTrue(s.gpsOK)
        XCTAssertTrue(s.online)
        XCTAssertNil(s.alert)
        XCTAssertEqual(s.updatedAt, now)
    }

    func testOldOwnFixHidesEveryDistance() throws {
        let s = try XCTUnwrap(OutingActivityBuilder.state(input(view(), fixAgeS: 150), backMeters: 6_100))
        XCTAssertFalse(s.gpsOK)
        XCTAssertNil(s.backMeters, "distance back needs a fresh fix of mine")
        XCTAssertNil(s.farthestName)
        XCTAssertNil(s.farthestMeters)
        XCTAssertEqual(s.liveCount, 2, "my own 150 s old fix is not live")
    }

    func testParkedWithScreenLockedKeepsDistances() throws {
        /* 90 s without a new fix (15 m filter, parked): still placed, but not counted live. */
        let s = try XCTUnwrap(OutingActivityBuilder.state(input(view(), fixAgeS: 90), backMeters: 6_100))
        XCTAssertTrue(s.gpsOK)
        XCTAssertEqual(s.backMeters, 6_100)
        XCTAssertEqual(s.liveCount, 2)
    }

    func testDeniedGpsAndOfflineLink() throws {
        let s = try XCTUnwrap(OutingActivityBuilder.state(input(view(), gps: .denied, link: .offline), backMeters: 100))
        XCTAssertFalse(s.gpsOK)
        XCTAssertFalse(s.online)
        XCTAssertNil(s.backMeters)
        let polling = try XCTUnwrap(OutingActivityBuilder.state(input(view(), link: .polling), backMeters: nil))
        XCTAssertTrue(polling.online, "polling still reaches the server")
    }

    func testNotSharingMeansIAmNotLive() throws {
        let s = try XCTUnwrap(OutingActivityBuilder.state(input(view(), sharing: false), backMeters: nil))
        XCTAssertEqual(s.liveCount, 2)
    }

    func testNoViewNoState() {
        var i = input(view())
        i.view = nil
        XCTAssertNil(OutingActivityBuilder.state(i, backMeters: 1))
    }

    // MARK: alert priority

    func testFriendSOSBeatsMineAndStuckNewestFirst() throws {
        let v = view(sos: ["a": SosInfo(at: iso(300)), "b": SosInfo(at: iso(30)), "me": SosInfo(at: iso(10))])
        let stuck = [StuckMark(userId: "c", at: now.addingTimeInterval(-5))]
        let a = try XCTUnwrap(OutingActivityBuilder.state(input(v), backMeters: nil, stuck: stuck)?.alert)
        XCTAssertEqual(a.kind, .sos)
        XCTAssertEqual(a.name, "سعد", "newest friend SOS first")
        XCTAssertFalse(a.isMe)
        XCTAssertEqual(a.more, 3, "فهد's SOS, mine, ريم stuck")
    }

    func testMySOSBeatsStuck() throws {
        let v = view(sos: ["me": SosInfo(at: iso(10))])
        let a = try XCTUnwrap(OutingActivityBuilder.state(input(v), backMeters: nil, stuck: [StuckMark(userId: "a", at: now)])?.alert)
        XCTAssertEqual(a.kind, .sos)
        XCTAssertTrue(a.isMe)
        XCTAssertEqual(a.more, 1)
    }

    func testFriendStuckBeforeMineAndStrangersIgnored() throws {
        let stuck = [StuckMark(userId: "me", at: now), StuckMark(userId: "a", at: now.addingTimeInterval(-60)), StuckMark(userId: "zz", at: now)]
        let a = try XCTUnwrap(OutingActivityBuilder.state(input(view()), backMeters: nil, stuck: stuck)?.alert)
        XCTAssertEqual(a.kind, .stuck)
        XCTAssertEqual(a.name, "فهد")
        XCTAssertEqual(a.more, 1, "mine counts; a non-member never does")
    }

    // MARK: display

    private func state(_ f: (inout OutingActivityState) -> Void = { _ in }) -> OutingActivityState {
        var s = OutingActivityState(liveCount: 3, memberCount: 4, farthestName: "سعد", farthestMeters: 2_440, backMeters: 6_130,
                                    alert: nil, gpsOK: true, online: true, updatedAt: now)
        f(&s)
        return s
    }

    func testDisplayFormatsInArabicIndicDigits() {
        let d = OutingActivityDisplay.make(state(), now: now)
        XCTAssertEqual(d.liveLine, "٣ من ٤ مباشر")
        XCTAssertEqual(d.farthestLine, "سعد — ٢٫٤ كم")
        XCTAssertEqual(d.backText, "٦٫١ كم")
        XCTAssertEqual(d.backShort, "٦٫١ كم")
        XCTAssertEqual(d.minimalText, "٦٫١ كم")
        XCTAssertFalse(d.showAlertDot)
        XCTAssertNil(d.banner)
        XCTAssertFalse(d.isStale)
    }

    func testSpeedShownOnlyWhileFresh() throws {
        let fresh = SpeedModel.Snapshot(kmh: 42, atMs: (now.timeIntervalSince1970 - 3) * 1000)
        let s = try XCTUnwrap(OutingActivityBuilder.state(input(view()), backMeters: nil, speed: fresh))
        XCTAssertEqual(s.speedKmh, 42)
        XCTAssertEqual(OutingActivityDisplay.make(s, now: now).speedText, "٤٢ كم/س")
        let old = SpeedModel.Snapshot(kmh: 42, atMs: (now.timeIntervalSince1970 - 60) * 1000)
        XCTAssertNil(try XCTUnwrap(OutingActivityBuilder.state(input(view()), backMeters: nil, speed: old)).speedKmh, "an old speed is not «now»")
        XCTAssertNil(try XCTUnwrap(OutingActivityBuilder.state(input(view(), fixAgeS: 150), backMeters: nil, speed: fresh)).speedKmh, "no GPS, no speed")
        XCTAssertEqual(OutingActivityDisplay.make(state { $0.speedKmh = nil }, now: now).speedText, "—")
        XCTAssertEqual(OutingActivityDisplay.make(state { $0.speedKmh = 42 }, now: now.addingTimeInterval(200)).speedText, "—", "stale picture: «—»")
    }

    func testNoBackTrackShowsDash() {
        let d = OutingActivityDisplay.make(state { $0.backMeters = nil; $0.farthestName = nil }, now: now)
        XCTAssertNil(d.backText)
        XCTAssertEqual(d.backShort, "—")
        XCTAssertNil(d.farthestLine)
    }

    func testEmergencyBannerTakesPriorityOverConnectionProblems() {
        let sos = state { $0.alert = .init(kind: .sos, name: "نورة", isMe: false, since: now, more: 2); $0.online = false; $0.gpsOK = false }
        let d = OutingActivityDisplay.make(sos, now: now)
        XCTAssertEqual(d.banner, .init(text: "طوارئ: نورة يحتاج مساعدة +٢", tone: .emergency))
        XCTAssertTrue(d.showAlertDot)
        XCTAssertEqual(d.minimalText, "!", "the SOS mark wins the minimal island")
        XCTAssertEqual(OutingActivityDisplay.banner(state { $0.alert = .init(kind: .sos, name: "", isMe: true, since: now) })?.text, "طوارئك مفعّلة")
        XCTAssertEqual(OutingActivityDisplay.banner(state { $0.alert = .init(kind: .stuck, name: "فهد", isMe: false, since: now) })?.text, "فهد غرّز")
        XCTAssertEqual(OutingActivityDisplay.banner(state { $0.alert = .init(kind: .stuck, name: "", isMe: true, since: now) })?.tone, .emergency)
    }

    func testConnectionBanners() {
        XCTAssertEqual(OutingActivityDisplay.banner(state { $0.gpsOK = false }), .init(text: "انقطعت إشارة الموقع", tone: .warning))
        XCTAssertEqual(OutingActivityDisplay.banner(state { $0.online = false }), .init(text: "بلا اتصال بالشبكة", tone: .warning))
        XCTAssertEqual(OutingActivityDisplay.banner(state { $0.online = false; $0.gpsOK = false })?.text, "بلا اتصال ولا إشارة موقع")
    }

    func testStalenessFromAgeOrSystem() {
        let s = state()
        XCTAssertFalse(OutingActivityDisplay.make(s, now: now.addingTimeInterval(119)).isStale)
        XCTAssertTrue(OutingActivityDisplay.make(s, now: now.addingTimeInterval(121)).isStale, "older than 2 min: shown as old")
        XCTAssertTrue(OutingActivityDisplay.make(s, now: now, systemStale: true).isStale, "iOS passed the stale date")
        XCTAssertEqual(OutingActivityDisplay.make(s, now: now.addingTimeInterval(500)).updatedAt, now, "its age is counted from when it was true")
        XCTAssertEqual(OutingActivityCoordinator.content(s).staleDate, now.addingTimeInterval(OutingActivityState.staleAfter))
    }

    func testActivityFormatMatchesTheApp() {
        for m in [0.0, 4, 9.6, 95, 994, 1_000, 1_049, 6_130, 99_940, 123_456] {
            XCTAssertEqual(ActivityFormat.distance(meters: m), SaryFormat.distance(meters: m), "\(m)")
        }
        for s in [0.0, 59, 61, 3_599, 3_601, 90_000] {
            XCTAssertEqual(ActivityFormat.elapsed(since: now, now: now.addingTimeInterval(s)), SaryFormat.elapsed(since: now, now: now.addingTimeInterval(s)))
        }
    }

    // MARK: throttle

    func testThrottle() {
        let a = state()
        XCTAssertTrue(OutingActivityThrottle.shouldPush(a, last: nil, lastAt: nil, now: now), "first picture")
        let t5 = now.addingTimeInterval(5), t16 = now.addingTimeInterval(16), t61 = now.addingTimeInterval(61)
        XCTAssertFalse(OutingActivityThrottle.shouldPush(state { $0.backMeters = 5_000 }, last: a, lastAt: now, now: t5), "inside 15 s")
        XCTAssertTrue(OutingActivityThrottle.shouldPush(state { $0.backMeters = 5_000 }, last: a, lastAt: now, now: t16), "big change after 15 s")
        XCTAssertFalse(OutingActivityThrottle.shouldPush(state { $0.backMeters = 6_100 }, last: a, lastAt: now, now: t16), "30 m is not meaningful at 6 km")
        XCTAssertTrue(OutingActivityThrottle.shouldPush(state { $0.backMeters = nil }, last: a, lastAt: now, now: t16), "lost the distance")
        XCTAssertTrue(OutingActivityThrottle.shouldPush(state { $0.farthestName = "فهد" }, last: a, lastAt: now, now: t16))
        XCTAssertTrue(OutingActivityThrottle.shouldPush(a, last: a, lastAt: now, now: t61), "refresh so a true picture is not shown as old")
        XCTAssertFalse(OutingActivityThrottle.shouldPush(a, last: a, lastAt: now, now: t16))
        /* Urgent: at once, even 1 s later. */
        let t1 = now.addingTimeInterval(1)
        XCTAssertTrue(OutingActivityThrottle.shouldPush(state { $0.alert = .init(kind: .sos, name: "ريم", isMe: false, since: now) }, last: a, lastAt: now, now: t1))
        XCTAssertTrue(OutingActivityThrottle.shouldPush(state { $0.gpsOK = false }, last: a, lastAt: now, now: t1))
        XCTAssertTrue(OutingActivityThrottle.shouldPush(state { $0.online = false }, last: a, lastAt: now, now: t1))
        XCTAssertTrue(OutingActivityThrottle.shouldPush(state { $0.liveCount = 2 }, last: a, lastAt: now, now: t1))
        XCTAssertTrue(OutingActivityThrottle.moved(100, 160))
        XCTAssertFalse(OutingActivityThrottle.moved(100, 140))
        XCTAssertFalse(OutingActivityThrottle.moved(nil, nil))
    }

    // MARK: lifecycle + tap

    func testRunsOnlyWhileSharingAnOpenOuting() {
        XCTAssertTrue(OutingActivityCoordinator.shouldRun(wantsToShare: true, status: .active, closed: false))
        XCTAssertFalse(OutingActivityCoordinator.shouldRun(wantsToShare: false, status: .active, closed: false), "stopped sharing")
        XCTAssertFalse(OutingActivityCoordinator.shouldRun(wantsToShare: true, status: .ended, closed: false), "ended")
        XCTAssertFalse(OutingActivityCoordinator.shouldRun(wantsToShare: true, status: .active, closed: true), "left / removed")
        XCTAssertFalse(OutingActivityCoordinator.shouldRun(wantsToShare: true, status: nil, closed: false))
    }

    func testTapURLRoundTripsAndRejectsJunk() {
        let id = "00000000-0000-4000-8000-0000000000aa"
        let u = OutingActivityState.url(outingId: id)
        XCTAssertEqual(u.absoluteString, "saryalbarq://outing/\(id)")
        XCTAssertEqual(OutingActivityState.outingId(from: u), id)
        XCTAssertNil(OutingActivityState.outingId(from: URL(string: "saryalbarq://outing/../x")!))
        XCTAssertNil(OutingActivityState.outingId(from: URL(string: "https://evil.example/outing/\(id)")!))
        XCTAssertNil(OutingActivityState.outingId(from: URL(string: "saryalbarq://join#abc")!))
        XCTAssertNil(InviteLink.token(from: u), "never mistaken for an invite")
    }
}
