import XCTest
@testable import SaryAlbarq

final class OutingStateTests: XCTestCase {
    private let t0 = ISODate.parse("2026-11-03T10:00:00.000Z")!

    private func snap(status: OutingStatus = .active, positions: [Position] = [], serverNow: String = "2026-11-03T10:00:00.000Z") -> OutingSnapshot {
        OutingSnapshot(
            outing: OutingInfo(id: "o", name: "طلعة", status: status, owner_id: "a"),
            me: SnapshotMe(user_id: "a", role: "owner", sharing: true),
            members: [
                Member(user_id: "a", display_name: "أ", role: "owner", sharing: true, joined_at: "2026-11-03T09:00:00Z"),
                Member(user_id: "b", display_name: "ب", role: "member", sharing: true, joined_at: "2026-11-03T09:01:00Z"),
            ],
            positions: positions, invite: nil, server_now: serverNow
        )
    }

    private func pos(_ uid: String, _ at: String, lat: Double = 24.7, speed: Double? = 10) -> Position {
        Position(user_id: uid, lat: lat, lng: 46.7, accuracy: 5, heading: 90, speed: speed, mode: .balanced, recorded_at: at)
    }

    func testLateOlderFixNeverMovesMarkerBack() {
        var v = OutingView(snap(positions: [pos("b", "2026-11-03T09:59:58.000Z", lat: 24.8)]), deviceNow: t0)
        v.apply(.position(pos("b", "2026-11-03T09:59:50.000Z", lat: 24.1)))
        XCTAssertEqual(v.positions["b"]?.lat, 24.8)
        v.apply(.position(pos("b", "2026-11-03T09:59:59.000Z", lat: 24.9)))
        XCTAssertEqual(v.positions["b"]?.lat, 24.9)
    }

    func testReconnectSnapshotKeepsNewerFix() {
        let prev = OutingView(snap(positions: [pos("b", "2026-11-03T09:59:59.000Z", lat: 24.9)]), deviceNow: t0)
        let next = OutingView.merge(prev, snap(positions: [pos("b", "2026-11-03T09:59:40.000Z", lat: 24.1)]), deviceNow: t0)
        XCTAssertEqual(next.positions["b"]?.lat, 24.9)
    }

    func testPauseEndAndSharingOffDropPositions() {
        var v = OutingView(snap(positions: [pos("b", "2026-11-03T09:59:58.000Z")]), deviceNow: t0)
        v.apply(.memberSharing(userId: "b", sharing: false))
        XCTAssertNil(v.positions["b"])
        var w = OutingView(snap(positions: [pos("b", "2026-11-03T09:59:58.000Z")]), deviceNow: t0)
        w.apply(.outingStatus(.paused))
        XCTAssertTrue(w.positions.isEmpty)
        w.apply(.position(pos("b", "2026-11-03T10:00:00.000Z")))
        XCTAssertTrue(w.positions.isEmpty, "no positions while not active")
    }

    func testFreshnessMeasuredOnServerClock() {
        /* Device clock is 10 minutes fast; the server says 10:00:00. A fix from 09:59:55 is still live. */
        let deviceNow = t0.addingTimeInterval(600)
        let v = OutingView(snap(positions: [pos("b", "2026-11-03T09:59:55.000Z")]), deviceNow: deviceNow)
        XCTAssertEqual(v.freshness(of: "b", deviceNow: deviceNow), .live)
        XCTAssertEqual(v.freshness(of: "b", deviceNow: deviceNow.addingTimeInterval(30)), .recent)
        XCTAssertEqual(v.freshness(of: "b", deviceNow: deviceNow.addingTimeInterval(120)), .lost)
    }

    func testLinkHeartbeatUpdatesLastSeenWithoutTouchingPositions() {
        var v = OutingView(snap(positions: [pos("b", "2026-11-03T09:58:00.000Z")]), deviceNow: t0)
        XCTAssertEqual(v.freshness(of: "b", deviceNow: t0), .lost)
        v.apply(.memberLink(userId: "b", lastSeenAt: "2026-11-03T09:59:59.000Z", gps: .weak))
        XCTAssertEqual(v.freshness(of: "b", deviceNow: t0), .recent, "reachable, but the fix is old: آخر موقع, not مباشر")
        XCTAssertEqual(v.positions["b"]?.recorded_at, "2026-11-03T09:58:00.000Z")
    }

    func testMemberLeftAndOwnerChanged() {
        var v = OutingView(snap(positions: [pos("b", "2026-11-03T09:59:58.000Z")]), deviceNow: t0)
        v.apply(.ownerChanged(ownerId: "b"))
        XCTAssertEqual(v.snapshot.me.role, "member")
        XCTAssertEqual(v.members["b"]?.role, "owner")
        v.apply(.memberLeft(userId: "b"))
        XCTAssertNil(v.members["b"])
        XCTAssertNil(v.positions["b"])
    }

    func testEventDecoding() {
        XCTAssertEqual(LiveEvent.decode(["type": "presence", "user_id": "b", "online": true, "away": true]), .presence(userId: "b", online: true, away: true))
        XCTAssertEqual(LiveEvent.decode(["type": "member_note", "user_id": "b", "note": NSNull()]), .memberNote(userId: "b", note: nil))
        XCTAssertNil(LiveEvent.decode(["type": "ack", "ok": true]))
        let p = LiveEvent.decode(["type": "position", "position": ["user_id": "b", "lat": 24.7, "lng": 46.7, "accuracy": NSNull(), "heading": NSNull(), "speed": 3.2, "mode": "saver", "recorded_at": "2026-11-03T10:00:00.000Z", "received_at": "2026-11-03T10:00:00.100Z"]])
        if case let .position(pp)? = p { XCTAssertEqual(pp.speed, 3.2); XCTAssertEqual(pp.mode, .saver) } else { XCTFail("position not decoded") }
    }

    func testSnapshotDecodesServerJSON() throws {
        let json = """
        {"ok":true,"outing":{"id":"o","name":"n","status":"active","owner_id":"a","created_at":"2026-11-03T09:00:00.000Z","started_at":null,"ended_at":null},
         "me":{"user_id":"a","role":"owner","sharing":true},
         "members":[{"user_id":"a","display_name":"أ","avatar":null,"phone":"+966551234567","role":"owner","sharing":true,"joined_at":"2026-11-03T09:00:00.000Z","online":true,"away":false,"last_seen_at":null,"gps":null,"note":null}],
         "positions":[],"invite":{"active":true,"expires_at":"2026-11-04T09:00:00.000Z"},"server_now":"2026-11-03T10:00:00.000Z"}
        """
        let s = try JSONDecoder().decode(OutingSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(s.members.first?.phone, "+966551234567")
        XCTAssertEqual(s.invite?.active, true)
    }

    func testMeFirstThenJoinOrder() {
        let v = OutingView(snap(), deviceNow: t0)
        XCTAssertEqual(v.orderedMembers.map(\.user_id), ["a", "b"])
        XCTAssertEqual(v.colors["a"], CarColors.palette[0])
    }
}

final class InviteLinkTests: XCTestCase {
    let token = "AbCdEfGhIjKlMnOpQrStUvWxYz0123456789-_abcd"

    func testTokenShape() {
        XCTAssertEqual(token.count, 42)
        let t43 = token + "e"
        XCTAssertTrue(InviteLink.isTokenShaped(t43))
        XCTAssertFalse(InviteLink.isTokenShaped(token))
        XCTAssertFalse(InviteLink.isTokenShaped(String(t43.dropLast()) + "=")) // no padding
    }

    func testUniversalLinkAndScheme() {
        let t = token + "e"
        XCTAssertEqual(InviteLink.token(from: URL(string: "https://farq-map-investor.vercel.app/outings/join#\(t)")!), t)
        XCTAssertEqual(InviteLink.token(from: URL(string: "saryalbarq://join#\(t)")!), t)
        XCTAssertEqual(InviteLink.token(from: URL(string: "saryalbarq://join/\(t)")!), t)
        XCTAssertNil(InviteLink.token(from: URL(string: "https://farq-map-investor.vercel.app/other#\(t)")!))
        XCTAssertNil(InviteLink.token(from: URL(string: "https://farq-map-investor.vercel.app/outings/join#short")!))
        XCTAssertEqual(InviteLink.url(for: t).absoluteString, "https://farq-map-investor.vercel.app/outings/join#\(t)")
    }

    func testPasted() {
        let t = token + "e"
        XCTAssertEqual(InviteLink.token(fromPasted: "  \(t) \n"), t)
        XCTAssertEqual(InviteLink.token(fromPasted: "تعال معنا https://farq-map-investor.vercel.app/outings/join#\(t) يلا"), t)
        XCTAssertNil(InviteLink.token(fromPasted: "مرحبا"))
    }
}

private extension Member {
    init(user_id: String, display_name: String, role: String, sharing: Bool, joined_at: String) {
        self.init(user_id: user_id, display_name: display_name, avatar: nil, phone: nil, role: role, sharing: sharing, joined_at: joined_at, online: true, away: false, last_seen_at: nil, gps: nil, note: nil)
    }
}

private extension OutingInfo {
    init(id: String, name: String, status: OutingStatus, owner_id: String) {
        self.init(id: id, name: name, status: status, owner_id: owner_id, created_at: nil, started_at: nil, ended_at: nil)
    }
}
