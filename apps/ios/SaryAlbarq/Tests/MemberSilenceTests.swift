import XCTest
@testable import SaryAlbarq

/// «انقطع الإرسال»: decoding the two frames and the snapshot field, the reducer,
/// the presenter (badge, card, never live) and the push → outing link.
final class MemberSilenceTests: XCTestCase {
    private let t0 = ISODate.parse("2026-11-04T10:00:00.000Z")!

    private func snap(status: OutingStatus = .active, positions: [Position] = [], silent: [SilentInfo]? = nil, phone: String? = "+966500000009") -> OutingSnapshot {
        var s = OutingSnapshot(
            outing: OutingInfo(id: "o", name: "طلعة", status: status, owner_id: "a"),
            me: SnapshotMe(user_id: "a", role: "owner", sharing: true),
            members: [
                Member(user_id: "a", display_name: "أنا", role: "owner", sharing: true, joined_at: "2026-11-04T09:00:00Z"),
                Member(user_id: "b", display_name: "فهد", phone: phone, role: "member", sharing: true, joined_at: "2026-11-04T09:01:00Z"),
                Member(user_id: "c", display_name: "سعد", role: "member", sharing: true, joined_at: "2026-11-04T09:02:00Z"),
            ],
            positions: positions, invite: nil, server_now: "2026-11-04T10:00:00.000Z"
        )
        s.silent = silent
        return s
    }

    private func pos(_ uid: String, _ at: String, lat: Double = 24.7) -> Position {
        Position(user_id: uid, lat: lat, lng: 46.7, accuracy: 5, heading: 90, speed: 10, mode: .balanced, recorded_at: at)
    }

    private let bLastAt = "2026-11-04T09:50:00.000Z"
    private var bSilent: SilentInfo {
        SilentInfo(user_id: "b", since: "2026-11-04T09:50:01.000Z", level: 10, last: .init(lat: 24.7, lng: 46.7, at: bLastAt))
    }

    // MARK: decoding

    func testDecodesMemberSilent() {
        let e = LiveEvent.decode([
            "type": "member_silent", "user_id": "b", "since": "2026-11-04T09:50:01.000Z", "level": 30,
            "last": ["lat": 24.7, "lng": 46.7, "at": bLastAt],
        ])
        XCTAssertEqual(e, .memberSilent(SilentInfo(user_id: "b", since: "2026-11-04T09:50:01.000Z", level: 30, last: .init(lat: 24.7, lng: 46.7, at: bLastAt))))
    }

    func testDecodesMemberSilentWithoutLastAndFromRealJSON() throws {
        let json = #"{"type":"member_silent","user_id":"b","since":"2026-11-04T09:50:01.000Z","last":null,"level":10}"#
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(LiveEvent.decode(obj), .memberSilent(SilentInfo(user_id: "b", since: "2026-11-04T09:50:01.000Z", level: 10, last: nil)))
        XCTAssertNil(LiveEvent.decode(["type": "member_silent", "user_id": "b"]), "no since")
        XCTAssertNil(LiveEvent.decode(["type": "member_silent", "since": "x"]), "no user")
    }

    func testDecodesMemberResumed() {
        XCTAssertEqual(LiveEvent.decode(["type": "member_resumed", "user_id": "b"]), .memberResumed(userId: "b", reason: nil))
        XCTAssertEqual(LiveEvent.decode(["type": "member_resumed", "user_id": "b", "reason": "left"]), .memberResumed(userId: "b", reason: "left"))
        XCTAssertNil(LiveEvent.decode(["type": "member_resumed"]))
        XCTAssertNil(LiveEvent.decode(["type": "member_going_offline", "user_id": "b", "until": "x"]), "known but not an event the map needs")
    }

    func testSnapshotCarriesSilentList() throws {
        let json = #"""
        {"outing":{"id":"o","name":"طلعة","status":"active","owner_id":"a"},"me":{"user_id":"a","role":"owner","sharing":true},
         "members":[],"positions":[],"invite":null,"server_now":"2026-11-04T10:00:00.000Z",
         "silent":[{"user_id":"b","since":"2026-11-04T09:50:01.000Z","level":10,"last":{"lat":24.7,"lng":46.7,"at":"2026-11-04T09:50:00.000Z"}}]}
        """#
        let s = try JSONDecoder().decode(OutingSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(s.silent, [bSilent])
        let old = try JSONDecoder().decode(OutingSnapshot.self, from: Data(#"{"outing":{"id":"o","name":"x","status":"active","owner_id":"a"},"me":{"user_id":"a","role":"owner","sharing":true},"members":[],"positions":[],"server_now":"2026-11-04T10:00:00.000Z"}"#.utf8))
        XCTAssertNil(old.silent, "an older server without the field still decodes")
    }

    // MARK: reducer

    func testSilentIsSetAndNeverLive() {
        var v = OutingView(snap(positions: [pos("b", bLastAt)]), deviceNow: t0)
        v.apply(.memberSilent(bSilent))
        XCTAssertTrue(v.isSilent("b"))
        XCTAssertEqual(v.freshness(of: "b", deviceNow: t0), .lost)
        /* Even if the device clock would make the old fix look fresh. */
        XCTAssertEqual(v.freshness(of: "b", deviceNow: ISODate.parse(bLastAt)!), .lost, "a silent member is never live")
    }

    func testFreshFixClearsSilence() {
        var v = OutingView(snap(positions: [pos("b", bLastAt)], silent: [bSilent]), deviceNow: t0)
        XCTAssertTrue(v.isSilent("b"), "from the snapshot")
        v.apply(.position(pos("b", "2026-11-04T09:49:59.000Z")))
        XCTAssertTrue(v.isSilent("b"), "an older fix does not")
        v.apply(.position(pos("b", "2026-11-04T09:59:59.000Z")))
        XCTAssertFalse(v.isSilent("b"))
    }

    func testResumedLeftSharingOffPausedClear() {
        var v = OutingView(snap(silent: [bSilent]), deviceNow: t0)
        v.apply(.memberResumed(userId: "b", reason: nil))
        XCTAssertFalse(v.isSilent("b"))

        v = OutingView(snap(silent: [bSilent]), deviceNow: t0)
        v.apply(.memberLeft(userId: "b"))
        XCTAssertFalse(v.isSilent("b"))

        v = OutingView(snap(silent: [bSilent]), deviceNow: t0)
        v.apply(.memberSharing(userId: "b", sharing: false))
        XCTAssertFalse(v.isSilent("b"))

        v = OutingView(snap(silent: [bSilent]), deviceNow: t0)
        v.apply(.outingStatus(.paused))
        XCTAssertTrue(v.silent.isEmpty)
        v.apply(.memberSilent(bSilent))
        XCTAssertTrue(v.silent.isEmpty, "ignored while the outing is not active")
    }

    func testIgnoresStaleOrInvalidSilence() {
        var v = OutingView(snap(positions: [pos("b", "2026-11-04T09:59:00.000Z")]), deviceNow: t0)
        v.apply(.memberSilent(bSilent))
        XCTAssertFalse(v.isSilent("b"), "we already hold a newer fix")
        v.apply(.memberSilent(SilentInfo(user_id: "a", since: bLastAt, level: 10, last: nil)))
        XCTAssertFalse(v.isSilent("a"), "never about me")
        v.apply(.memberSilent(SilentInfo(user_id: "zz", since: bLastAt, level: 10, last: nil)))
        XCTAssertFalse(v.isSilent("zz"), "not a member")
    }

    // MARK: presenter

    func testParticipantRowAndChipStateAndText() {
        var v = OutingView(snap(positions: [pos("b", bLastAt)], silent: [bSilent]), deviceNow: t0)
        let parts = LiveOutingPresenter.participants(LivePresenterInput(view: v, now: t0))
        let b = parts.first { $0.id == "b" }!
        XCTAssertNotNil(b.silentSince)
        XCTAssertFalse(b.presence.isLive)
        XCTAssertEqual(SilenceText.badge(since: b.silentSince!, now: t0), "انقطع منذ ١٠ د")
        XCTAssertNil(parts.first { $0.id == "c" }?.silentSince)
        XCTAssertTrue(LiveOutingPresenter.mapMembers(LivePresenterInput(view: v, now: t0), hideNotes: false).first { $0.id == "b" }?.presence != .live)
        v.apply(.memberResumed(userId: "b", reason: nil))
        XCTAssertNil(LiveOutingPresenter.participants(LivePresenterInput(view: v, now: t0)).first { $0.id == "b" }?.silentSince)
    }

    func testAlertCardCarriesGoAndCall() throws {
        let v = OutingView(snap(positions: [pos("b", bLastAt)], silent: [bSilent]), deviceNow: t0)
        let a = try XCTUnwrap(LiveOutingPresenter.silentAlert("b", in: v, now: t0))
        XCTAssertEqual(a.name, "فهد")
        XCTAssertEqual(a.level, 10)
        XCTAssertTrue(a.hasLast, "«اتجه» to the last position")
        XCTAssertEqual(a.lastLat, 24.7)
        XCTAssertTrue(a.hasPhone, "«اتصال» when the phone is shared")
        XCTAssertEqual(SilenceText.title(name: a.name, since: a.since, now: t0), "انقطع إرسال فهد منذ ١٠ د")
        XCTAssertEqual(SilenceText.lastFix(a.lastAt, now: t0), "آخر موقع قبل ١٠ د")
        /* «اتجه»: our own guidance to the last known fix, labelled as old. */
        let go = try LiveOutingPresenter.silentTarget(a).get()
        XCTAssertEqual(go.source, .lastKnown)
        XCTAssertEqual(go.name, "آخر موقع فهد")
        XCTAssertEqual(go.position, LngLat(lng: 46.7, lat: 24.7))
        XCTAssertEqual(go.staleNote(now: t0), "آخر موقع معروف · قبل ١٠ د")

        let noPhone = OutingView(snap(silent: [SilentInfo(user_id: "b", since: bLastAt, level: 30, last: nil)], phone: nil), deviceNow: t0)
        let n = try XCTUnwrap(LiveOutingPresenter.silentAlert("b", in: noPhone, now: t0))
        XCTAssertFalse(n.hasPhone)
        XCTAssertFalse(n.hasLast, "no last position: no «اتجه»")
        XCTAssertEqual(LiveOutingPresenter.silentTarget(n), .failure(.missing))
        XCTAssertEqual(SilenceText.lastFix(nil, now: t0), "لا يوجد موقع معروف")
        XCTAssertEqual(SilenceText.resumed(name: "فهد"), "رجع إرسال فهد")
    }

    func testChangesRaiseEscalateAndClear() {
        let calm = OutingView(snap(positions: [pos("b", bLastAt)]), deviceNow: t0)
        var silent = calm
        silent.apply(.memberSilent(bSilent))
        XCTAssertEqual(LiveOutingPresenter.silenceChanges(prev: calm, next: silent).raised, ["b"])
        XCTAssertEqual(LiveOutingPresenter.silenceChanges(prev: silent, next: silent), .init(), "no repeat")

        var thirty = silent
        var s30 = bSilent
        s30.level = 30
        thirty.apply(.memberSilent(s30))
        XCTAssertEqual(LiveOutingPresenter.silenceChanges(prev: silent, next: thirty).raised, ["b"], "escalation re-shows the card")

        var back = thirty
        back.apply(.position(pos("b", "2026-11-04T10:00:00.000Z")))
        back.apply(.memberResumed(userId: "b", reason: nil))
        let c = LiveOutingPresenter.silenceChanges(prev: thirty, next: back)
        XCTAssertEqual(c.cleared.map(\.uid), ["b"])
        XCTAssertEqual(c.cleared.map(\.withFix), [true], "a fresh fix: «رجع إرسال فهد»")

        var offline = thirty
        offline.apply(.memberResumed(userId: "b", reason: "going_offline"))
        XCTAssertEqual(LiveOutingPresenter.silenceChanges(prev: thirty, next: offline).cleared.map(\.withFix), [false], "said they would go offline: no «رجع»")

        var left = thirty
        left.apply(.memberLeft(userId: "b"))
        XCTAssertEqual(LiveOutingPresenter.silenceChanges(prev: thirty, next: left).cleared.map(\.withFix), [false])
    }

    // MARK: push

    @MainActor func testSilencePushOpensTheOuting() {
        /* The APNs body the server sends for member_silent. */
        let info: [AnyHashable: Any] = ["aps": ["alert": ["title": "📡 انقطع إرسال فهد", "body": "انقطع إرسال فهد منذ ١٠ د — آخر موقع قبل ١٠ د"], "interruption-level": "time-sensitive"],
                                        "type": "member_silent", "outing_id": "o-123", "url": "/outings/o-123"]
        XCTAssertEqual(PushRegistrar.outingId(from: info), "o-123")
        XCTAssertEqual(PushRegistrar.outingId(from: ["type": "member_silent", "url": "/outings/o-9"]), "o-9")
    }
}
