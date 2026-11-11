import CoreLocation
import XCTest
@testable import SaryAlbarq

/// The mapper from real outing data to the screen contracts.
final class LivePresenterTests: XCTestCase {
    private let now = ISODate.parse("2026-11-04T12:00:00.000Z")!
    private func iso(_ agoS: Double) -> String { ISODate.string(now.addingTimeInterval(-agoS)) }

    private func member(_ id: String, _ name: String, role: String = "member", co: Bool? = nil, sharing: Bool = true, phone: String? = nil, joined: Int,
                        note: MemberNote? = nil, sos: SosInfo? = nil, battery: BatteryInfo? = nil) -> Member {
        Member(user_id: id, display_name: name, avatar: nil, phone: phone, role: role, sharing: sharing, joined_at: "2026-11-04T10:0\(joined):00.000Z",
               online: true, away: false, last_seen_at: iso(2), gps: .ok, note: note, co_leader: co, battery: battery, sos: sos)
    }

    private func view(members: [Member], positions: [Position], rally: RallyInfo? = nil, status: OutingStatus = .active, me: String = "me") -> OutingView {
        OutingView(OutingSnapshot(
            outing: OutingInfo(id: "o", name: "طلعة", status: status, owner_id: "me", rally: rally),
            me: SnapshotMe(user_id: me, role: "owner", sharing: true),
            members: members, positions: positions, invite: nil, server_now: ISODate.string(now)
        ), deviceNow: now)
    }

    private var myFix: DeviceFix { DeviceFix(lat: 24.7000, lng: 46.7000, accuracy: 5, heading: nil, speed: 0, atMs: now.timeIntervalSince1970 * 1000 - 1_000) }

    private func base(_ v: OutingView) -> LivePresenterInput {
        var i = LivePresenterInput()
        i.view = v
        i.myFix = myFix
        i.gpsState = .ok
        i.locationAuthorized = true
        i.link = .live
        i.now = now
        return i
    }

    func testOldFixIsNeverLiveAndPausedIsPaused() {
        let v = view(members: [member("me", "أنا", role: "owner", joined: 0), member("a", "فهد", joined: 1), member("b", "سعد", joined: 2), member("c", "ريم", sharing: false, joined: 3)],
                     positions: [Position(user_id: "a", lat: 24.701, lng: 46.70, accuracy: 5, heading: 0, speed: 10, mode: .balanced, recorded_at: iso(3)),
                                 Position(user_id: "b", lat: 24.71, lng: 46.70, accuracy: 5, heading: nil, speed: 0, mode: .balanced, recorded_at: iso(240))])
        let p = LiveOutingPresenter.participants(base(v))
        XCTAssertEqual(p.first?.id, "me", "me first")
        XCTAssertEqual(p.first(where: { $0.id == "a" })?.presence, .live)
        guard case let .stale(since)? = p.first(where: { $0.id == "b" })?.presence else { return XCTFail("4 min old fix must be stale") }
        XCTAssertEqual(since.timeIntervalSince1970, now.addingTimeInterval(-240).timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(p.first(where: { $0.id == "c" })?.presence, .paused)
        XCTAssertEqual(p.first(where: { $0.id == "me" })?.presence, .paused, "I am not sharing: never shown as live to me either")
        let ids = p.map(\.id)
        XCTAssertLessThan(ids.firstIndex(of: "a")!, ids.firstIndex(of: "b")!, "nearest first")
    }

    func testNoteExpiresAfter15Minutes() {
        let v = view(members: [member("me", "أنا", role: "owner", joined: 0),
                               member("a", "فهد", joined: 1, note: MemberNote(text: "بوقف", at: iso(60))),
                               member("b", "سعد", joined: 2, note: MemberNote(text: "قديمة", at: iso(16 * 60)))], positions: [])
        let p = LiveOutingPresenter.participants(base(v))
        XCTAssertEqual(p.first(where: { $0.id == "a" })?.note, "بوقف")
        XCTAssertNil(p.first(where: { $0.id == "b" })?.note)
    }

    func testRolesPhoneBattery() {
        let v = view(members: [member("me", "أنا", role: "owner", joined: 0),
                               member("a", "فهد", co: true, phone: "+966500000001", joined: 1, battery: BatteryInfo(level: 0.64, charging: false, at: nil))], positions: [])
        let p = LiveOutingPresenter.participants(base(v))
        let a = p.first { $0.id == "a" }!
        XCTAssertEqual(a.role, .coLeader)
        XCTAssertTrue(a.hasPhone)
        XCTAssertEqual(a.batteryPercent, 64)
        XCTAssertEqual(p.first?.role, .leader)
        XCTAssertTrue(LiveOutingPresenter.state(base(v)).participantsTab.myPhoneMissing)
    }

    func testSharingAndWarnings() {
        let v = view(members: [member("me", "أنا", role: "owner", joined: 0)], positions: [])
        var i = base(v)
        XCTAssertEqual(LiveOutingPresenter.state(i).sharing, .paused)
        i.wantsToShare = true
        XCTAssertEqual(LiveOutingPresenter.state(i).sharing, .starting)
        i.isSharingNow = true
        let s = LiveOutingPresenter.state(i)
        XCTAssertEqual(s.sharing, .sharing)
        XCTAssertTrue(s.warnings.contains(.keepScreenOn), "«أثناء الاستخدام»: foreground-only sharing says so")
        i.hasAlways = true
        XCTAssertFalse(LiveOutingPresenter.state(i).warnings.contains(.keepScreenOn), "«دائمًا»: sharing keeps going with the screen locked")
        i.hasAlways = false
        i.link = .offline
        XCTAssertTrue(LiveOutingPresenter.state(i).warnings.contains(.noInternet))
        XCTAssertEqual(LiveOutingPresenter.state(i).connection, .offline)
    }

    func testIncomingSOSAndAcknowledge() {
        let sos = SosInfo(at: iso(30), fix: SosFix(lat: 24.71, lng: 46.70, accuracy: 10, recorded_at: iso(40)))
        let v = view(members: [member("me", "أنا", role: "owner", joined: 0), member("a", "فهد", phone: "+9665", joined: 1, sos: sos)], positions: [])
        var i = base(v)
        var s = LiveOutingPresenter.sos(i)
        XCTAssertEqual(s.incoming.count, 1)
        XCTAssertFalse(s.incoming[0].acknowledged, "first: full-screen")
        XCTAssertEqual(s.incoming[0].distanceMeters!, 1_112, accuracy: 15)
        i.acknowledgedSOS = [s.incoming[0].id]
        s = LiveOutingPresenter.sos(i)
        XCTAssertTrue(s.incoming[0].acknowledged, "then: the persistent strip")
        XCTAssertEqual(s.mine, .none)
        i.sosSending = true
        XCTAssertEqual(LiveOutingPresenter.sos(i).mine, .sending)
    }

    /// UI-AUDIT 0.1: the full-screen alert is the newest unacknowledged SOS, and a NEW one clears
    /// the sheets / settings over the map (the same one staying up does not, again and again).
    func testFriendSOSFullScreenAndClearsTheScreenOnce() {
        let older = SosInfo(at: iso(120), fix: nil)
        let newer = SosInfo(at: iso(30), fix: nil)
        let v = view(members: [member("me", "أنا", role: "owner", joined: 0),
                               member("a", "فهد", joined: 1, sos: older), member("b", "سعد", joined: 2, sos: newer)], positions: [])
        var i = base(v)
        let first = LiveOutingPresenter.fullScreenSOS(LiveOutingPresenter.sos(i))
        XCTAssertEqual(first?.participantId, "b", "the newest first")
        XCTAssertTrue(LiveOutingPresenter.sosClearsScreen(current: first?.id, previous: nil), "arrives: sheets close")
        XCTAssertFalse(LiveOutingPresenter.sosClearsScreen(current: first?.id, previous: first?.id), "still up: leave the screen alone")
        i.acknowledgedSOS = [first!.id]
        let second = LiveOutingPresenter.fullScreenSOS(LiveOutingPresenter.sos(i))
        XCTAssertEqual(second?.participantId, "a", "acknowledged: the next one shows")
        XCTAssertTrue(LiveOutingPresenter.sosClearsScreen(current: second?.id, previous: first?.id))
        i.acknowledgedSOS.insert(second!.id)
        XCTAssertNil(LiveOutingPresenter.fullScreenSOS(LiveOutingPresenter.sos(i)))
        XCTAssertFalse(LiveOutingPresenter.sosClearsScreen(current: nil, previous: second?.id), "none left: nothing to clear")
    }

    /// UI-AUDIT 0.2: the leader's explainer at «ابدأ الطلعة» only when iOS has not asked and ours was never shown.
    func testLeaderNotifyOfferAtStart() {
        XCTAssertTrue(LiveOutingController.offersNotifyAtStart(explained: false, undecided: true))
        XCTAssertFalse(LiveOutingController.offersNotifyAtStart(explained: true, undecided: true), "never twice")
        XCTAssertFalse(LiveOutingController.offersNotifyAtStart(explained: false, undecided: false), "iOS already asked (allowed or refused)")
    }

    func testRallyArrivedCountsOnlyLiveFixesNearby() {
        let rally = RallyInfo(lat: 24.7010, lng: 46.7000, label: "الطعس", set_at: nil, set_by: nil)
        let v = view(members: [member("me", "أنا", role: "owner", joined: 0), member("a", "فهد", joined: 1), member("b", "سعد", joined: 2)],
                     positions: [Position(user_id: "a", lat: 24.7011, lng: 46.70, accuracy: 5, heading: nil, speed: 0, mode: .balanced, recorded_at: iso(5)),
                                 Position(user_id: "b", lat: 24.7011, lng: 46.70, accuracy: 5, heading: nil, speed: 0, mode: .balanced, recorded_at: iso(600))],
                     rally: rally)
        let r = LiveOutingPresenter.rally(base(v))!
        XCTAssertEqual(r.arrivedCount, 1, "a stale fix at the rally point does not count as arrived")
        XCTAssertEqual(r.totalCount, 3)
        XCTAssertEqual(r.label, "الطعس")
        XCTAssertEqual(r.distanceMeters!, 111, accuracy: 3)
    }

    func testMapNeverDrawsAnOldFixAsLive() {
        let v = view(members: [member("me", "أنا", role: "owner", joined: 0), member("b", "سعد", joined: 2)],
                     positions: [Position(user_id: "b", lat: 24.71, lng: 46.70, accuracy: 5, heading: 90, speed: 12, mode: .balanced, recorded_at: iso(120))])
        var i = base(v)
        i.myFix = DeviceFix(lat: 24.7, lng: 46.7, accuracy: 5, heading: nil, speed: 0, atMs: now.timeIntervalSince1970 * 1000 - 120_000)
        let cars = LiveOutingPresenter.mapMembers(i, hideNotes: false)
        XCTAssertNotEqual(cars.first { $0.id == "b" }?.presence, .live)
        XCTAssertNil(cars.first { $0.id == "b" }?.heading, "no heading arrow on an old fix")
        XCTAssertNotEqual(cars.first { $0.isMe }?.presence, .live, "my own 2 min old fix is not live either")
    }

    func testRelativeBearing() {
        XCTAssertEqual(LiveOutingPresenter.relative(10, mapBearing: 30), 340)
        XCTAssertEqual(LiveOutingPresenter.relative(90, mapBearing: 0), 90)
    }
}

final class EdgeArrowTests: XCTestCase {
    private let area = CGRect(x: 0, y: 100, width: 400, height: 500)
    private let chip = CGSize(width: 100, height: 36)

    func testInsideHasNoArrow() {
        XCTAssertNil(EdgeArrows.spot(id: "a", point: CGPoint(x: 200, y: 300), area: area, chip: chip))
    }

    func testOffRightPointsRight() {
        let s = EdgeArrows.spot(id: "a", point: CGPoint(x: 900, y: 350), area: area, chip: chip)!
        XCTAssertEqual(s.edge, .right)
        XCTAssertEqual(s.angle, 90, accuracy: 1)
        XCTAssertLessThanOrEqual(s.center.x + chip.width / 2, area.maxX)
    }

    func testAvoidsKeepOutRects() {
        let cluster = CGRect(x: 0, y: 300, width: 64, height: 220)
        let spots = EdgeArrows.place(points: [(id: "a", point: CGPoint(x: -500, y: 400))], area: area, chip: chip, avoid: [cluster])
        let r = CGRect(x: spots[0].center.x - 50, y: spots[0].center.y - 18, width: 100, height: 36)
        XCTAssertFalse(r.intersects(cluster), "never under the control cluster")
    }

    func testChipsOnOneEdgeDoNotOverlap() {
        let spots = EdgeArrows.place(points: [(id: "a", point: CGPoint(x: -300, y: 350)), (id: "b", point: CGPoint(x: -300, y: 352))], area: area, chip: chip, avoid: [])
        XCTAssertEqual(spots.count, 2)
        XCTAssertGreaterThanOrEqual(abs(spots[0].center.y - spots[1].center.y), chip.height)
    }
}

final class OutingEventTests: XCTestCase {
    func testNewServerEventsDecodeAndApply() {
        let sos = LiveEvent.decode(["type": "sos", "user_id": "a", "sos": ["at": "2026-11-04T12:00:00.000Z", "fix": NSNull()]])
        XCTAssertEqual(sos, .sos(userId: "a", sos: SosInfo(at: "2026-11-04T12:00:00.000Z", fix: nil), refresh: false))
        XCTAssertEqual(LiveEvent.decode(["type": "sos", "user_id": "a", "sos": NSNull()]), .sos(userId: "a", sos: nil, refresh: false))
        XCTAssertEqual(LiveEvent.decode(["type": "rally", "rally": ["lat": 24.7, "lng": 46.7, "label": "هنا"]]), .rally(RallyInfo(lat: 24.7, lng: 46.7, label: "هنا")))
        XCTAssertEqual(LiveEvent.decode(["type": "member_role", "user_id": "a", "co_leader": true]), .memberRole(userId: "a", coLeader: true))
        let clip = LiveEvent.decode(["type": "voice_clip", "clip": ["id": "c1", "user_id": "a", "mime": "audio/mp4", "duration_ms": 2300, "at": "x", "expires_at": "y", "url": "/api/outings/o/clips/c1"]])
        if case let .voiceClip(c)? = clip { XCTAssertEqual(c.duration_ms, 2300) } else { XCTFail() }
        XCTAssertEqual(LiveEvent.decode(["type": "member_link", "user_id": "a", "last_seen_at": "t", "gps": "ok", "battery": ["level": 0.5, "charging": true, "at": "t"]]),
                       .memberLink(userId: "a", lastSeenAt: "t", gps: .ok, battery: BatteryInfo(level: 0.5, charging: true, at: "t")))
    }

    func testEndClearsRallySosNotes() {
        var v = OutingView(OutingSnapshot(
            outing: OutingInfo(id: "o", name: "x", status: .active, owner_id: "me", rally: RallyInfo(lat: 1, lng: 1)),
            me: SnapshotMe(user_id: "me", role: "owner", sharing: true),
            members: [Member(user_id: "a", display_name: "a", role: "member", sharing: true, joined_at: "t", note: MemberNote(text: "n", at: "t"), sos: SosInfo(at: "t"))],
            positions: [], invite: nil, server_now: "2026-11-04T12:00:00.000Z"))
        v.apply(.outingStatus(.ended))
        XCTAssertNil(v.snapshot.outing.rally)
        XCTAssertNil(v.members["a"]?.sos)
        XCTAssertNil(v.members["a"]?.note)
    }
}

final class ScreenProjectionTests: XCTestCase {
    func testNorthEastIsUpRightAndBearingRotates() {
        let c = CLLocationCoordinate2D(latitude: 24.71, longitude: 46.67)
        let ne = CLLocationCoordinate2D(latitude: 24.78, longitude: 46.73)
        let p = ScreenProjection.point(ne, center: c, centerPoint: CGPoint(x: 200, y: 400), zoom: 14, bearing: 0)
        XCTAssertGreaterThan(p.x, 200)
        XCTAssertLessThan(p.y, 400)
        /* Map rotated 90° (east up): a point due east is straight up. */
        let e = CLLocationCoordinate2D(latitude: 24.71, longitude: 46.75)
        let q = ScreenProjection.point(e, center: c, centerPoint: CGPoint(x: 200, y: 400), zoom: 14, bearing: 90)
        XCTAssertEqual(q.x, 200, accuracy: 1)
        XCTAssertLessThan(q.y, 400)
    }
}
