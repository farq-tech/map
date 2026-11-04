import XCTest
@testable import SaryAlbarq

/// The CarPlay presenters: member rows, trip/guidance models, alert priority, staleness, my SOS guard.
final class CarPlayPresenterTests: XCTestCase {
    private let now = ISODate.parse("2026-11-04T12:00:00.000Z")!
    private func iso(_ agoS: Double) -> String { ISODate.string(now.addingTimeInterval(-agoS)) }

    private func member(_ id: String, _ name: String, sharing: Bool = true, phone: String? = nil, joined: Int, sos: SosInfo? = nil) -> Member {
        Member(user_id: id, display_name: name, avatar: nil, phone: phone, role: id == "me" ? "owner" : "member", sharing: sharing,
               joined_at: "2026-11-04T10:0\(joined):00.000Z", online: true, away: false, last_seen_at: iso(2), gps: .ok, note: nil, sos: sos)
    }

    private func pos(_ id: String, _ lat: Double, _ lng: Double, ago: Double, speed: Double = 10) -> Position {
        Position(user_id: id, lat: lat, lng: lng, accuracy: 5, heading: 90, speed: speed, mode: .balanced, recorded_at: iso(ago))
    }

    private func view(_ members: [Member], _ positions: [Position], rally: RallyInfo? = nil) -> OutingView {
        OutingView(OutingSnapshot(outing: OutingInfo(id: "o", name: "طلعة", status: .active, owner_id: "me", rally: rally),
                                  me: SnapshotMe(user_id: "me", role: "owner", sharing: true),
                                  members: members, positions: positions, invite: nil, server_now: ISODate.string(now)), deviceNow: now)
    }

    private var myFix: DeviceFix { DeviceFix(lat: 24.7000, lng: 46.7000, accuracy: 5, heading: 0, speed: 10, atMs: now.timeIntervalSince1970 * 1000 - 1_000) }

    private func input(_ v: OutingView, fix: DeviceFix? = nil, stuck: [CarPlayStuck] = []) -> CarPlayInput {
        CarPlayInput(view: v, myFix: fix ?? myFix, isSharingNow: true, course: 0, destination: nil, stuck: stuck, convoy: nil, now: now)
    }

    private var crew: OutingView {
        view([member("me", "أنا", joined: 0), member("a", "أبو فهد", phone: "+966500000001", joined: 1), member("b", "سلطان", joined: 2),
              member("c", "ريم", sharing: false, joined: 3), member("d", "خالد", joined: 4)],
             [pos("a", 24.7100, 46.7000, ago: 3), pos("b", 24.7020, 46.7000, ago: 300, speed: 0)])
    }

    // MARK: member rows

    func testRowsExcludeMeAndSayPlainlyWhatIsLive() {
        let rows = CarPlayPresenter.memberRows(input(crew))
        XCTAssertEqual(rows.map(\.id), ["a", "b", "d", "c"], "live first, then old position, then no fix yet, then paused")
        XCTAssertFalse(rows.contains { $0.id == "me" })
        let a = rows[0]
        XCTAssertTrue(a.isLive)
        XCTAssertEqual(a.detail, "١٫١ كم · شمال")
        XCTAssertEqual(a.phone, "+966500000001")
        let b = rows[1]
        XCTAssertFalse(b.isLive, "a 5-minute-old fix is never live")
        XCTAssertEqual(b.state, .stale(since: now.addingTimeInterval(-300)))
        XCTAssertTrue(b.detail.hasPrefix("آخر موقع قبل ٥ د"), b.detail)
        XCTAssertNil(b.phone)
        XCTAssertEqual(rows[2].state, .noFix)
        XCTAssertEqual(rows[2].detail, "ما وصل موقعه بعد")
        XCTAssertEqual(rows[3].state, .paused)
        XCTAssertNil(rows[3].position, "paused: nothing to show")
    }

    func testSOSAndStuckGoFirst() {
        var v = crew
        v.apply(.sos(userId: "b", sos: SosInfo(at: iso(20), fix: nil), refresh: false))
        let rows = CarPlayPresenter.memberRows(input(v, stuck: [CarPlayStuck(memberId: "d", since: now, position: nil)]))
        XCTAssertEqual(rows.prefix(2).map(\.id), ["b", "d"])
        XCTAssertTrue(rows[0].detail.hasPrefix("نداء استغاثة"))
        XCTAssertTrue(rows[1].detail.hasPrefix("غرّز"))
    }

    func testNoFreshFixOfMineMeansNoDistance() {
        var old = myFix
        old.atMs -= 5 * 60_000
        let rows = CarPlayPresenter.memberRows(input(crew, fix: old))
        XCTAssertNil(rows[0].distanceM)
        XCTAssertEqual(rows[0].detail, "مباشر")
    }

    func testShortNames() {
        XCTAssertEqual(CarPlayPresenter.shortName("سلطان العتيبي"), "سلطان")
        XCTAssertEqual(CarPlayPresenter.shortName("أبو فهد"), "أبو فهد")
        XCTAssertEqual(CarPlayPresenter.shortName("عبدالرحمنالطويييل"), "عبدالرحمن…")
        XCTAssertEqual(CarPlayPresenter.shortName("  "), "—")
    }

    func testMapCarsLabelAgeWhenNotLive() {
        let cars = CarPlayPresenter.mapCars(input(crew))
        XCTAssertEqual(cars.first { $0.isMe }?.label, "أنت")
        XCTAssertEqual(cars.first { $0.id == "a" }?.label, "أبو فهد")
        let b = cars.first { $0.id == "b" }!
        XCTAssertFalse(b.live)
        XCTAssertNotEqual(b.label, "سلطان", "an old car always says its age")
        XCTAssertTrue(b.label.contains("قبل") || b.label.contains("انقطع"), b.label)
        XCTAssertNil(b.heading, "no heading arrow on an old fix")
    }

    // MARK: guidance

    private func trail() -> Trail {
        var t = Trail()
        t.points = (0...10).map { TrailPoint(lat: 24.70 + Double($0) * 0.001, lng: 46.70, t: Double($0) * 10_000) }
        return t
    }

    func testWayBackOnTrailOffTrackArrived() {
        var bt = BackTrack(trail())!
        let on = CarPlayGuide.wayBack(bt.update(LngLat(lng: 46.70, lat: 24.7095)), course: 180)
        XCTAssertEqual(on.phase, .onTrail)
        XCTAssertEqual(on.instruction, "تابع مسارك")
        XCTAssertEqual(on.symbol, "arrow.up", "driving south, back along the trail = straight ahead")
        XCTAssertEqual(on.remainingM ?? 0, 1056, accuracy: 30)

        let off = CarPlayGuide.wayBack(bt.update(LngLat(lng: 46.7015, lat: 24.705)), course: 180)
        XCTAssertEqual(off.phase, .offTrack)
        XCTAssertEqual(off.instruction, "ارجع لمسارك")
        XCTAssertTrue(off.offTrack)
        /* Driving south, the trail lies to the west: on my right. */
        XCTAssertEqual(off.symbol, "arrow.right")
    }

    func testWayBackArrowIsRelativeToCourse() {
        var bt = BackTrack(trail())!
        let off = CarPlayGuide.wayBack(bt.update(LngLat(lng: 46.7015, lat: 24.705)), course: 0)
        /* Facing north, the trail lies to the west: turn left. */
        XCTAssertEqual(off.symbol, "arrow.left")
        let arrived = CarPlayGuide.wayBack(bt.update(LngLat(lng: 46.70, lat: 24.7001)), course: 0)
        XCTAssertTrue(arrived.arrived)
        XCTAssertEqual(arrived.remainingM, 0)
        XCTAssertEqual(CarPlayGuide.wayBack(nil, course: nil).phase, .waitingFix)
    }

    func testStraightLineSaysApproximate() {
        let me = LngLat(lng: 46.70, lat: 24.70)
        let g = CarPlayGuide.straight(.rally, from: me, to: LngLat(lng: 46.71, lat: 24.71), course: 0)
        XCTAssertEqual(g.phase, .straight)
        XCTAssertEqual(g.instruction, "اتجه شمال شرق")
        XCTAssertTrue(g.detail.contains("اتجاه تقريبي"))
        XCTAssertEqual(g.symbol, "arrow.up.right")
        XCTAssertTrue(CarPlayTripKind.rally.approximate)
        XCTAssertFalse(CarPlayTripKind.wayBack.approximate)
        XCTAssertEqual(CarPlayGuide.straight(.destination, from: nil, to: me, course: nil).phase, .waitingFix)
        XCTAssertEqual(CarPlayGuide.straight(.destination, from: me, to: LngLat(lng: 46.7005, lat: 24.70), course: nil).phase, .arrived)
    }

    func testRoadRouteWinsOnlyWhenActive() {
        let road = CarPlayRoadProgress(destinationLabel: "روضة", remainingM: 5000, remainingS: 400,
                                       maneuvers: [CarPlayRoadManeuver(instruction: "انعطف يمين", distanceM: 300, symbol: "arrow.turn.up.right")])
        let fb = CarPlayGuide.waiting(.destination)
        XCTAssertEqual(CarPlayGuide.pick(road: road, roadActive: true, kind: .destination) { fb }.phase, .road)
        XCTAssertEqual(CarPlayGuide.pick(road: road, roadActive: true, kind: .destination) { fb }.instruction, "انعطف يمين")
        XCTAssertEqual(CarPlayGuide.pick(road: road, roadActive: false, kind: .destination) { fb }, fb)
        var empty = road
        empty.maneuvers = []
        XCTAssertEqual(CarPlayGuide.pick(road: empty, roadActive: true, kind: .destination) { fb }, fb, "no maneuvers: fall back")
    }

    func testAvailableTrips() {
        var v = crew
        XCTAssertEqual(CarPlayPresenter.availableTrips(input(v), trail: Trail()), [])
        v.apply(.rally(RallyInfo(lat: 24.71, lng: 46.71, label: nil, set_at: nil, set_by: nil)))
        var i = input(v)
        i.destination = CarPlayDestination(position: LngLat(lng: 46.8, lat: 24.8))
        XCTAssertEqual(CarPlayPresenter.availableTrips(i, trail: trail()), [.wayBack, .rally, .destination])
        XCTAssertEqual(CarPlayPresenter.rally(i)?.label, "نقطة التجمع")
        XCTAssertEqual(CarPlayPresenter.destination(i)?.label, "الوجهة")
    }

    // MARK: alerts

    func testAlertPriority() {
        var v = crew
        v.apply(.sos(userId: "b", sos: SosInfo(at: iso(30), fix: SosFix(lat: 24.702, lng: 46.70, accuracy: 5, recorded_at: iso(600))), refresh: false))
        var i = input(v, stuck: [CarPlayStuck(memberId: "d", since: now, position: LngLat(lng: 46.70, lat: 24.69))])
        i.convoy = CarPlayConvoy(gapWarning: "خالد بعيد")
        var g = CarPlayGuide.waiting(.wayBack)
        g.phase = .offTrack
        let a = CarPlayAlerts.current(i, guidance: g)
        XCTAssertEqual(a.map(\.kind), [.friendSOS, .stuck, .offTrack, .convoyGap])
        XCTAssertEqual(a[0].title, "سلطان يطلب نجدة")
        XCTAssertTrue(a[0].subtitle.contains("آخر موقع قبل ١٠ د"), "an old SOS fix says its age: \(a[0].subtitle)")
        XCTAssertTrue(a[0].sticky)
        XCTAssertEqual(a[0].durationS, 0)
        XCTAssertFalse(a[2].sticky)
        XCTAssertEqual(a[1].title, "خالد غرّز")
    }

    func testAlertBookReArms() {
        var book = CarPlayAlertBook()
        let off = CarPlayAlert(id: "offtrack", kind: .offTrack, title: "", subtitle: "", since: now)
        let sos = CarPlayAlert(id: "b|t", kind: .friendSOS, title: "", subtitle: "", since: now)
        XCTAssertEqual(book.next(from: [sos, off])?.id, "b|t")
        book.handle("b|t")
        XCTAssertEqual(book.next(from: [sos, off])?.id, "offtrack")
        book.handle("offtrack")
        XCTAssertNil(book.next(from: [sos, off]))
        /* Back on the trail, then off again: the alert comes back. */
        XCTAssertNil(book.next(from: [sos]))
        XCTAssertEqual(book.next(from: [sos, off])?.id, "offtrack")
    }

    // MARK: my SOS

    func testMySOSNeedsTwoSteps() {
        var guardian = CarPlaySOSGuard()
        XCTAssertEqual(guardian.confirm(active: false, now: now), .askConfirm, "a confirm without the question first never sends")
        guardian = CarPlaySOSGuard()
        XCTAssertEqual(guardian.press(active: false, now: now), .askConfirm, "one tap only asks")
        XCTAssertEqual(guardian.confirm(active: false, now: now.addingTimeInterval(3)), .send)
        XCTAssertEqual(guardian.confirm(active: false, now: now.addingTimeInterval(4)), .askConfirm, "the confirm is used up")
        _ = guardian.press(active: false, now: now)
        XCTAssertEqual(guardian.confirm(active: false, now: now.addingTimeInterval(60)), .askConfirm, "a late confirm asks again")
        _ = guardian.press(active: true, now: now)
        XCTAssertEqual(guardian.confirm(active: true, now: now.addingTimeInterval(2)), .cancel)
        _ = guardian.press(active: false, now: now)
        guardian.dismiss()
        XCTAssertEqual(guardian.confirm(active: false, now: now.addingTimeInterval(1)), .askConfirm)
    }
}
