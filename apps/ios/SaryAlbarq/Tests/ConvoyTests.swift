import XCTest
@testable import SaryAlbarq

/// Convoy alerts: geometry along the direction of travel, live positions only, rate limit.
final class ConvoyTests: XCTestCase {
    private let o = Geo.LatLng(lat: 24.70, lng: 46.70)

    /// A point `north` / `east` metres from the origin.
    private func at(_ north: Double, _ east: Double) -> Geo.LatLng {
        let mLat = Geo.earthRadiusM * .pi / 180
        return Geo.LatLng(lat: o.lat + north / mLat, lng: o.lng + east / (mLat * cos(o.lat * .pi / 180)))
    }

    private func car(_ id: String, _ north: Double, _ east: Double, heading: Double? = nil) -> ConvoyCar {
        ConvoyCar(id: id, position: at(north, east), heading: heading)
    }

    private let convoy = ConvoyInfo(lead_user_id: "L", tail_user_id: "T", max_gap_m: 500)

    func testAlongTrackIsTheProjectionOnTheDirection() {
        XCTAssertEqual(ConvoyMath.along(at(1000, 0), from: o, bearing: 0), 1000, accuracy: 2)
        XCTAssertEqual(ConvoyMath.along(at(1000, 0), from: o, bearing: 180), -1000, accuracy: 2)
        XCTAssertEqual(ConvoyMath.along(at(0, 800), from: o, bearing: 0), 0, accuracy: 1, "beside the lead is not ahead of it")
        XCTAssertEqual(ConvoyMath.along(at(0, 800), from: o, bearing: 90), 800, accuracy: 2)
    }

    func testBehindTailAndAheadOfLeadAlongTheLeadsCourse() {
        let cars = [
            car("L", 0, 0, heading: 0),
            car("T", -300, 0),
            car("late", -900, 50),   // 600 m behind the tail
            car("fast", 200, -30),   // 200 m in front of the lead
            car("side", -150, 400),  // inside the column, off to the side
        ]
        let e = ConvoyMath.evaluate(convoy, live: cars)
        XCTAssertEqual(e.direction, 0)
        XCTAssertEqual(e.alerts.count, 2, "\(e.alerts)")
        guard case let .aheadOfLead(u1, m1) = e.alerts[0], case let .behindTail(u2, m2) = e.alerts[1] else { return XCTFail("\(e.alerts)") }
        XCTAssertEqual(u1, "fast")
        XCTAssertEqual(m1, 200, accuracy: 3)
        XCTAssertEqual(u2, "late")
        XCTAssertEqual(m2, 600, accuracy: 3)
        XCTAssertFalse(e.leadMissing || e.tailMissing)
    }

    func testOnlyTheComponentAlongTravelCounts() {
        /* Heading east: a car 700 m north of the tail but level with it is not "behind". */
        let cars = [car("L", 0, 0, heading: 90), car("T", 0, -300), car("x", 700, -300)]
        XCTAssertTrue(ConvoyMath.evaluate(convoy, live: cars).alerts.isEmpty)
        /* Same car, but now 600 m further back along the course. */
        let back = [car("L", 0, 0, heading: 90), car("T", 0, -300), car("x", 0, -900)]
        XCTAssertEqual(ConvoyMath.evaluate(convoy, live: back).alerts.map(\.key), ["convoy:behind:x"])
    }

    func testJustInFrontOfTheLeadIsNoise() {
        let e = ConvoyMath.evaluate(convoy, live: [car("L", 0, 0, heading: 0), car("T", -200, 0), car("x", ConvoyMath.aheadToleranceM - 10, 0)])
        XCTAssertTrue(e.alerts.isEmpty)
    }

    func testDirectionFallsBackToTailToLeadWhenTheLeadIsParked() {
        /* Lead parked (no course) 400 m north-east of the tail: the column points tail → lead. */
        let cars = [car("L", 283, 283), car("T", 0, 0), car("x", -500, -500)]
        let e = ConvoyMath.evaluate(convoy, live: cars)
        XCTAssertEqual(e.direction ?? -1, 45, accuracy: 0.5)
        XCTAssertEqual(e.alerts.map(\.key), ["convoy:behind:x"])
    }

    func testNoDirectionNoAlongTrackAlerts() {
        /* Everyone parked on the same spot: nothing to measure "ahead" against. */
        let e = ConvoyMath.evaluate(convoy, live: [car("L", 0, 0), car("T", -10, 0), car("x", 900, 0)])
        XCTAssertNil(e.direction)
        XCTAssertTrue(e.alerts.isEmpty)
    }

    func testTailTooFarBehindTheLead() {
        /* 3 live cars, 500 m gap: the column may be 1 km long. */
        let cars = [car("L", 0, 0, heading: 0), car("mid", -900, 0), car("T", -2000, 0)]
        let e = ConvoyMath.evaluate(convoy, live: cars)
        XCTAssertEqual(e.spanLimitM, 1000)
        XCTAssertEqual(e.alerts.map(\.key), ["convoy:tailfar"])
        guard case let .tailFarBehindLead(m)? = e.alerts.first else { return XCTFail() }
        XCTAssertEqual(m, 2000, accuracy: 5)
        XCTAssertTrue(ConvoyMath.evaluate(convoy, live: [car("L", 0, 0, heading: 0), car("mid", -500, 0), car("T", -900, 0)]).alerts.isEmpty)
    }

    /// Stale cars are never in `live`: a stale lead switches its checks off (and says so),
    /// it never raises an alert from an old position.
    func testMissingLeadOrTailTurnsTheirChecksOff() {
        let noLead = ConvoyMath.evaluate(convoy, live: [car("T", 0, 0, heading: 0), car("x", 3000, 0), car("y", -900, 0)])
        XCTAssertTrue(noLead.leadMissing)
        XCTAssertEqual(noLead.alerts.map(\.key), ["convoy:behind:y"], "behind-tail still works from the tail's own course; nobody is 'ahead' of a lead we cannot see")
        let noTail = ConvoyMath.evaluate(convoy, live: [car("L", 0, 0, heading: 0), car("y", -5000, 0)])
        XCTAssertTrue(noTail.tailMissing)
        XCTAssertTrue(noTail.alerts.isEmpty)
    }

    func testOffOrSameCarForBoth() {
        XCTAssertTrue(ConvoyMath.evaluate(.off, live: [car("L", 0, 0, heading: 0), car("x", 900, 0)]).alerts.isEmpty)
        let same = ConvoyInfo(lead_user_id: "L", tail_user_id: "L", max_gap_m: 500)
        XCTAssertEqual(ConvoyMath.evaluate(same, live: [car("L", 0, 0, heading: 0), car("x", 900, 0)]).alerts.map(\.key), ["convoy:ahead:x"])
    }

    // MARK: wire

    func testPatchBodySendsNullsAndGapIsClamped() throws {
        let off = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ConvoyInfo.off)) as? [String: Any]
        XCTAssertTrue(off?["lead_user_id"] is NSNull, "null clears the lead on the server")
        XCTAssertTrue(off?["tail_user_id"] is NSNull)
        XCTAssertNil(off?["max_gap_m"])
        XCTAssertEqual(ConvoyInfo(lead_user_id: "a", tail_user_id: nil, max_gap_m: 50).gapM, 200)
        XCTAssertEqual(ConvoyInfo(lead_user_id: "a", tail_user_id: nil, max_gap_m: 9000).gapM, 5000)
        XCTAssertEqual(ConvoyInfo(lead_user_id: "a", tail_user_id: nil, max_gap_m: nil).gapM, ConvoyInfo.defaultGapM)
        let back = try JSONDecoder().decode(ConvoyInfo.self, from: Data(#"{"lead_user_id":"a","tail_user_id":null,"max_gap_m":800}"#.utf8))
        XCTAssertEqual(back, ConvoyInfo(lead_user_id: "a", tail_user_id: nil, max_gap_m: 800))
        XCTAssertEqual(back.role(of: "a"), .lead)
    }

    func testOutingPayloadAndEvent() throws {
        let json = #"{"outing":{"id":"o","name":"x","status":"active","owner_id":"u","convoy":{"lead_user_id":"a","tail_user_id":"b","max_gap_m":700}},"me":{"user_id":"u","role":"owner","sharing":true},"members":[],"positions":[],"server_now":"2026-11-04T10:00:00.000Z"}"#
        var v = OutingView(try JSONDecoder().decode(OutingSnapshot.self, from: Data(json.utf8)))
        XCTAssertEqual(v.convoy?.gapM, 700)
        v.apply(try XCTUnwrap(LiveEvent.decode(["type": "convoy_updated", "convoy": NSNull()])))
        XCTAssertNil(v.convoy, "convoy_updated {convoy: null} turns it off")
        v.apply(try XCTUnwrap(LiveEvent.decode(["type": "convoy_updated", "convoy": ["lead_user_id": "b", "tail_user_id": NSNull(), "max_gap_m": 300]])))
        XCTAssertEqual(v.convoy?.lead_user_id, "b")
    }

    // MARK: rate limit

    func testGateFiresOnceThenRemindsThenNeedsToClearFirst() {
        var g = ConvoyAlertGate(repeatAfter: 180, clearAfter: 60, hapticMinInterval: 20)
        let a = ConvoyAlert.behindTail(userId: "x", meters: 700)
        let t0 = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(g.admit([a], now: t0).fire, [a])
        XCTAssertTrue(g.admit([a], now: t0.addingTimeInterval(5)).fire.isEmpty, "still true: not again every evaluation")
        XCTAssertEqual(g.admit([a], now: t0.addingTimeInterval(181)).fire, [a], "a reminder while it stays true")
        /* Flapping at the threshold: cleared for 10 s then back — not new. */
        _ = g.admit([], now: t0.addingTimeInterval(190))
        XCTAssertTrue(g.admit([a], now: t0.addingTimeInterval(200)).fire.isEmpty)
        /* Clear for a full minute: the next one is news. */
        _ = g.admit([], now: t0.addingTimeInterval(210))
        _ = g.admit([], now: t0.addingTimeInterval(275))
        XCTAssertEqual(g.admit([a], now: t0.addingTimeInterval(280)).fire, [a])
    }

    func testHapticIsRateLimitedAcrossAlerts() {
        var g = ConvoyAlertGate(repeatAfter: 180, clearAfter: 60, hapticMinInterval: 20)
        let t0 = Date(timeIntervalSince1970: 1000)
        XCTAssertTrue(g.admit([.behindTail(userId: "x", meters: 700)], now: t0).haptic)
        let second = g.admit([.behindTail(userId: "x", meters: 700), .aheadOfLead(userId: "y", meters: 100)], now: t0.addingTimeInterval(3))
        XCTAssertEqual(second.fire.map(\.key), ["convoy:ahead:y"], "a new alert still shows")
        XCTAssertFalse(second.haptic, "but the phone does not buzz twice in 3 s")
        XCTAssertTrue(g.admit([.tailFarBehindLead(meters: 3000)], now: t0.addingTimeInterval(25)).haptic)
    }

    // MARK: live only, end to end

    /// From the real presenter: an old fix is `recent` and never reaches the convoy check.
    func testStalePositionsAreExcludedEndToEnd() {
        let now = ISODate.parse("2026-11-04T12:00:00.000Z")!
        func iso(_ s: Double) -> String { ISODate.string(now.addingTimeInterval(-s)) }
        func m(_ id: String, _ j: Int) -> Member {
            Member(user_id: id, display_name: id, avatar: nil, phone: nil, role: id == "me" ? "owner" : "member", sharing: true,
                   joined_at: "2026-11-04T10:0\(j):00.000Z", online: true, away: false, last_seen_at: iso(2), gps: .ok)
        }
        let lead = at(0, 0), late = at(-3000, 0)
        var snap = OutingSnapshot(
            outing: OutingInfo(id: "o", name: "x", status: .active, owner_id: "me", convoy: ConvoyInfo(lead_user_id: "L", tail_user_id: "me", max_gap_m: 500)),
            me: SnapshotMe(user_id: "me", role: "owner", sharing: true),
            members: [m("me", 0), m("L", 1), m("late", 2)],
            positions: [
                Position(user_id: "L", lat: lead.lat, lng: lead.lng, accuracy: 5, heading: nil, speed: 0, mode: .balanced, recorded_at: iso(5)),
                /* 3 km behind, but this fix is 4 minutes old. */
                Position(user_id: "late", lat: late.lat, lng: late.lng, accuracy: 5, heading: nil, speed: 0, mode: .balanced, recorded_at: iso(240)),
            ], invite: nil, server_now: ISODate.string(now))
        var i = LivePresenterInput()
        i.view = OutingView(snap, deviceNow: now)
        let me = at(-300, 0)
        i.myFix = DeviceFix(lat: me.lat, lng: me.lng, accuracy: 5, heading: nil, speed: 0, atMs: now.timeIntervalSince1970 * 1000 - 1000)
        i.gpsState = .ok
        i.now = now
        let cars = OutingFeaturesModel.liveCars(LiveOutingPresenter.mapMembers(i, hideNotes: true))
        XCTAssertEqual(Set(cars.map(\.id)), ["me", "L"], "the stale car is left out")
        XCTAssertTrue(ConvoyMath.evaluate(i.view!.convoy!, live: cars).alerts.isEmpty, "no alert from a 4-minute-old position")
        /* The same car with a fresh fix does raise it. */
        snap.positions[1].recorded_at = iso(3)
        i.view = OutingView(snap, deviceNow: now)
        let fresh = OutingFeaturesModel.liveCars(LiveOutingPresenter.mapMembers(i, hideNotes: true))
        XCTAssertEqual(ConvoyMath.evaluate(i.view!.convoy!, live: fresh).alerts.map(\.key), ["convoy:behind:late"])
    }
}
