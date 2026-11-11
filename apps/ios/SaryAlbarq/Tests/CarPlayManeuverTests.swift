import CarPlay
import XCTest
@testable import SaryAlbarq

/// CarPlay v2: road maneuvers → CPManeuver / lanes, the trip preview's choices, the
/// destinations list, recents, and the SOS / «يتكلم» alerts.
final class CarPlayManeuverTests: XCTestCase {
    private let now = ISODate.parse("2026-11-04T12:00:00.000Z")!
    private func iso(_ agoS: Double) -> String { ISODate.string(now.addingTimeInterval(-agoS)) }

    private func member(_ id: String, _ name: String, sharing: Bool = true, phone: String? = nil, joined: Int, sos: SosInfo? = nil) -> Member {
        Member(user_id: id, display_name: name, avatar: nil, phone: phone, role: id == "me" ? "owner" : "member", sharing: sharing,
               joined_at: "2026-11-04T10:0\(joined):00.000Z", online: true, away: false, last_seen_at: iso(2), gps: .ok, note: nil, sos: sos)
    }

    private func pos(_ id: String, _ lat: Double, _ lng: Double, ago: Double) -> Position {
        Position(user_id: id, lat: lat, lng: lng, accuracy: 5, heading: 90, speed: 10, mode: .balanced, recorded_at: iso(ago))
    }

    private var crew: OutingView {
        OutingView(OutingSnapshot(outing: OutingInfo(id: "o", name: "طلعة", status: .active, owner_id: "me",
                                                     rally: RallyInfo(lat: 24.7178, lng: 46.6852, label: "عند الطلحة", set_at: nil, set_by: nil)),
                                  me: SnapshotMe(user_id: "me", role: "owner", sharing: true),
                                  members: [member("me", "أنا", joined: 0), member("a", "أبو فهد", phone: "+966500000001", joined: 1),
                                            member("b", "سلطان", joined: 2)],
                                  positions: [pos("a", 24.7100, 46.7000, ago: 3), pos("b", 24.7020, 46.7000, ago: 600)],
                                  invite: nil, server_now: ISODate.string(now)), deviceNow: now)
    }

    private var myFix: DeviceFix { DeviceFix(lat: 24.7000, lng: 46.7000, accuracy: 5, heading: 0, speed: 10, atMs: now.timeIntervalSince1970 * 1000 - 1_000) }

    private func input(_ v: OutingView) -> CarPlayInput {
        CarPlayInput(view: v, myFix: myFix, isSharingNow: true, course: 0, destination: CarPlayDestination(position: LngLat(lng: 46.71, lat: 24.74), label: "روضة خريم"),
                     stuck: [], convoy: nil, now: now)
    }

    private func turn(_ type: String?, lanes: [NavLane] = [], duration: Double? = 20) -> CarPlayRoadManeuver {
        CarPlayRoadManeuver(instruction: "انعطف يمين على طريق الملك فهد", shortInstruction: "انعطف يمين", distanceM: 250,
                            symbol: "arrow.turn.up.right", durationS: duration, lanes: lanes, cpManeuverType: type)
    }

    // MARK: maneuvers

    func testInstructionVariantsAreArabicLongestFirstNeverEmpty() {
        XCTAssertEqual(CarPlayManeuverMapper.instructionVariants(turn("rightTurn")), ["انعطف يمين على طريق الملك فهد", "انعطف يمين"])
        var same = turn(nil)
        same.shortInstruction = same.instruction
        XCTAssertEqual(CarPlayManeuverMapper.instructionVariants(same).count, 1, "no duplicate variant")
        XCTAssertEqual(CarPlayManeuverMapper.instructionVariants(CarPlayRoadManeuver(instruction: " ", shortInstruction: nil, distanceM: 0, symbol: "arrow.up")), ["تابع"])
    }

    func testCPManeuverCarriesTextSymbolEstimatesAndType() {
        let m = CarPlayManeuverMapper.maneuver(turn("rightTurn"), speed: 10)
        XCTAssertEqual(m.instructionVariants, ["انعطف يمين على طريق الملك فهد", "انعطف يمين"])
        XCTAssertEqual(m.dashboardInstructionVariants, ["انعطف يمين"])
        XCTAssertNotNil(m.symbolImage)
        XCTAssertNotNil(m.dashboardSymbolImage)
        XCTAssertEqual(m.initialTravelEstimates?.distanceRemaining.converted(to: .meters).value, 250)
        XCTAssertEqual(m.initialTravelEstimates?.timeRemaining, 20, "the router's (traffic) step time wins over speed")
        if #available(iOS 17.4, *) {
            XCTAssertEqual(m.maneuverType, .rightTurn)
            XCTAssertEqual(m.trafficSide, .right, "KSA drives on the right")
        }
    }

    func testEstimatesNeverInventTime() {
        XCTAssertEqual(CarPlayManeuverMapper.estimates(distanceM: 300, durationS: nil, speed: 10).timeRemaining, 30)
        XCTAssertEqual(CarPlayManeuverMapper.estimates(distanceM: 300, durationS: nil, speed: 0.5).timeRemaining, 0, "parked: no ETA")
        XCTAssertEqual(CarPlayManeuverMapper.estimates(distanceM: -5, durationS: nil, speed: nil).distanceRemaining.value, 0)
        XCTAssertEqual(CarPlayManeuverMapper.tripEstimates(remainingM: 5000, remainingS: 420, speed: 30).timeRemaining, 420, "Mapbox traffic ETA")
    }

    @available(iOS 17.4, *)
    func testManeuverTypeNamesMapToCarPlay() {
        func t(_ n: String) -> CPManeuverType? { CarPlayManeuverMapper.maneuverTypeRaw(n).flatMap { CPManeuverType(rawValue: $0) } }
        XCTAssertEqual(t("leftTurn"), .leftTurn)
        XCTAssertEqual(t("straightAhead"), .straightAhead)
        XCTAssertEqual(t("uTurn"), .uTurn)
        XCTAssertEqual(t("startRoute"), .startRoute)
        XCTAssertEqual(t("arriveAtDestination"), .arriveAtDestination)
        XCTAssertEqual(t("enterRoundabout"), .enterRoundabout)
        XCTAssertEqual(t("roundaboutExit1"), .roundaboutExit1)
        XCTAssertEqual(t("roundaboutExit2"), .roundaboutExit2)
        XCTAssertEqual(t("roundaboutExit19"), .roundaboutExit19)
        XCTAssertEqual(t("sharpLeftTurn"), .sharpLeftTurn)
        XCTAssertEqual(t("sharpRightTurn"), .sharpRightTurn)
        XCTAssertEqual(t("slightLeftTurn"), .slightLeftTurn)
        XCTAssertEqual(t("slightRightTurn"), .slightRightTurn)
        XCTAssertEqual(t("keepLeft"), .keepLeft)
        XCTAssertEqual(t("keepRight"), .keepRight)
        XCTAssertEqual(t("offRampLeft"), .highwayOffRampLeft, "NavGlyph's name for a left exit")
        XCTAssertEqual(t("offRampRight"), .highwayOffRampRight)
        XCTAssertEqual(t("highwayMerge"), .changeHighway)
        XCTAssertNil(CarPlayManeuverMapper.maneuverTypeRaw("somethingElse"))
        XCTAssertNil(CarPlayManeuverMapper.maneuverTypeRaw("roundaboutExit20"))
    }

    /// Every name NavGlyph produces maps to a CarPlay type.
    func testEveryNavGlyphTypeIsKnown() {
        let dirs: [NavTurnDirection?] = [nil, .straight, .slightRight, .right, .sharpRight, .slightLeft, .left, .sharpLeft, .uTurn]
        let kinds: [NavManeuverKind] = [.depart, .turn, .continue, .newName, .merge, .onRamp, .offRamp, .fork, .endOfRoad, .useLane,
                                        .roundabout, .exitRoundabout, .notification, .arrive]
        for k in kinds {
            for d in dirs {
                for exit in [nil, 3] as [Int?] {
                    let n = NavGlyph.carPlayType(NavManeuver(kind: k, direction: d, exit: exit))
                    XCTAssertNotNil(CarPlayManeuverMapper.maneuverTypeRaw(n), "\(k) \(String(describing: d)) → \(n)")
                }
            }
        }
    }

    // MARK: lanes

    func testLaneGuidance() throws {
        guard #available(iOS 18.0, *) else { throw XCTSkip("CPLane initialisers are iOS 18+") }
        let lanes = [NavLane(directions: [.left], valid: false),
                     NavLane(directions: [.straight], valid: false),
                     NavLane(directions: [.straight, .right], valid: true, preferred: true)]
        let g = try XCTUnwrap(CarPlayManeuverMapper.laneGuidance(turn("rightTurn", lanes: lanes), turn: .right))
        XCTAssertEqual(g.lanes.count, 3)
        XCTAssertEqual(g.lanes.map(\.status), [.notGood, .notGood, .preferred])
        XCTAssertEqual(g.lanes[2].highlightedAngle?.value, 90)
        XCTAssertEqual(g.instructionVariants, ["خذ المسار الأيمن"])
        XCTAssertNil(CarPlayManeuverMapper.laneGuidance(turn("rightTurn"), turn: .right), "no lane data, no lane card")
    }

    func testLaneLines() {
        func l(_ valid: [Bool]) -> String { CarPlayManeuverMapper.laneLine(valid.map { NavLane(directions: [.straight], valid: $0) }) }
        XCTAssertEqual(l([false, false, true]), "خذ المسار الأيمن")
        XCTAssertEqual(l([true, false, false]), "خذ المسار الأيسر")
        XCTAssertEqual(l([false, true, false]), "خذ المسار اللي في النص")
        XCTAssertEqual(l([false, true, true]), "خلك يمين")
        XCTAssertEqual(l([true, true, false]), "خلك يسار")
        XCTAssertEqual(l([true, true]), "أي مسار")
        XCTAssertEqual(CarPlayManeuverMapper.angle(.uTurn), -180, "right-hand traffic: U-turn on the left")
    }

    // MARK: trip preview

    func testRouteChoicesFastestThenShortest() {
        let opts = [CarPlayRouteOption(id: "long-fast", distanceM: 9000, durationS: 600, via: "طريق الملك فهد"),
                    CarPlayRouteOption(id: "short-slow", distanceM: 7000, durationS: 900, via: nil, hasUnpaved: true),
                    CarPlayRouteOption(id: "other", distanceM: 9500, durationS: 700, via: nil)]
        let c = CarPlayManeuverMapper.choices(opts)
        XCTAssertEqual(c.map(\.id), ["long-fast", "short-slow", "other"])
        XCTAssertEqual(c[0].summary, ["الأسرع · طريق الملك فهد", "الأسرع"])
        XCTAssertEqual(c[1].summary, ["الأقصر"])
        XCTAssertEqual(c[2].summary, ["طريق ثاني"])
        XCTAssertTrue(c[1].info[0].contains("فيه ترابي"))
        XCTAssertTrue(c[0].info[0].contains(ArabicFormat.distance(9000)))
        let cp = CarPlayManeuverMapper.routeChoices(opts)
        XCTAssertEqual(cp.map { $0.userInfo as? String }, ["long-fast", "short-slow", "other"])
        XCTAssertEqual(CarPlayManeuverMapper.choices([opts[0]]).first?.summary.last, "الأسرع والأقصر")
        XCTAssertTrue(CarPlayManeuverMapper.choices([]).isEmpty)
    }

    func testAdapterCarriesLanesTypeAndPlanningOptions() {
        var s = NavSnapshot.idle
        s.phase = .guiding
        s.target = NavTarget(source: .point, name: "حطين", position: LngLat(lng: 46.665, lat: 24.722))
        s.routes = [NavRoute(id: "r1", coordinates: [LngLat(lng: 46.67, lat: 24.71), LngLat(lng: 46.665, lat: 24.722)], distanceM: 2100, durationS: 120, steps: [])]
        s.carPlayManeuvers = [NavCarPlayManeuver(instructionVariants: ["خذ المخرج الثاني", "المخرج الثاني"], symbolName: "arrow.triangle.turn.up.right.circle",
                                                 distanceM: 90, durationS: 12, lanes: [NavLane(directions: [.right], valid: true)],
                                                 maneuver: NavManeuver(kind: .roundabout, direction: .right, exit: 2), cpManeuverType: "roundaboutExit2")]
        let m = CarPlayNavAdapter.progress(s).maneuvers[0]
        XCTAssertEqual(m.cpManeuverType, "roundaboutExit2")
        XCTAssertEqual(m.lanes.count, 1)
        XCTAssertEqual(m.durationS, 12)
        XCTAssertTrue(CarPlayNavAdapter.options(s).isEmpty, "guiding: no preview choices")
        s.phase = .planning
        let o = CarPlayNavAdapter.options(s)
        XCTAssertEqual(o.map(\.id), ["r1"])
        XCTAssertEqual(o[0].line.count, 2)
    }

    // MARK: recents

    func testRecentsDedupeCapAndPersist() {
        var r = CarPlayRecents()
        for k in 0..<8 { r.add(name: "مكان \(k)", at: LngLat(lng: 46.6 + Double(k) * 0.01, lat: 24.7)) }
        XCTAssertEqual(r.places.count, CarPlayRecents.max)
        XCTAssertEqual(r.places.first?.name, "مكان 7")
        r.add(name: "نفس المكان", at: LngLat(lng: 46.6 + 0.07 + 0.0001, lat: 24.7))
        XCTAssertEqual(r.places.first?.name, "نفس المكان")
        XCTAssertFalse(r.places.contains { $0.name == "مكان 7" }, "within 50 m: replaced, not duplicated")
        r.add(name: "  ", at: LngLat(lng: 0, lat: 0))
        XCTAssertEqual(r.places.first?.name, "نفس المكان")
        let d = UserDefaults(suiteName: "carplay.recents.test")!
        d.removePersistentDomain(forName: "carplay.recents.test")
        r.save(d)
        XCTAssertEqual(CarPlayRecents.load(d), r)
    }

    // MARK: destinations list

    func testDestinationSections() {
        var rec = CarPlayRecents()
        rec.add(name: "برج المملكة", at: LngLat(lng: 46.6753, lat: 24.7114))
        let secs = CarPlayDestinations.sections(input(crew), trail: Trail(), recents: rec)
        XCTAssertEqual(secs.map(\.header), ["الطلعة", "الربع", "الأخيرة"])
        XCTAssertEqual(secs[0].rows.map(\.action), [.trip(.rally), .trip(.destination)])
        XCTAssertEqual(secs[0].rows[0].title, "نقطة التجمع: عند الطلحة")
        XCTAssertEqual(secs[0].rows[1].title, "الوجهة: روضة خريم")
        let fahd = secs[1].rows[0]
        XCTAssertEqual(fahd.title, "روح لـأبو فهد")
        if case let .member(id, _, _) = fahd.action { XCTAssertEqual(id, "a") } else { XCTFail("live member is drivable") }
        XCTAssertEqual(secs[1].rows[1].action, .disabled, "a 10-minute-old fix: never driven to")
        XCTAssertTrue(secs[1].rows[1].detail.hasPrefix("آخر موقع"))
        XCTAssertEqual(secs[2].rows[0].title, "برج المملكة")
    }

    // MARK: alerts

    func testFriendSOSAlertCanBeDrivenTo() {
        var v = crew
        v.apply(.sos(userId: "a", sos: SosInfo(at: iso(20), fix: SosFix(lat: 24.71, lng: 46.70, accuracy: 8, recorded_at: iso(20))), refresh: false))
        var i = input(v)
        i.talking = CarPlayTalking(noteId: "n1", userId: "b", name: "سلطان")
        let a = CarPlayAlerts.current(i, guidance: nil)
        XCTAssertEqual(a.first?.kind, .friendSOS)
        XCTAssertEqual(a.first?.title, "أبو فهد يحتاج مساعدة")
        XCTAssertEqual(a.first?.memberId, "a")
        XCTAssertNotNil(a.first?.position, "«اتجه له» needs a position")
        XCTAssertEqual(a.first?.phone, "+966500000001")
        XCTAssertTrue(a.first?.sticky == true)
        XCTAssertEqual(a.last?.kind, .talking, "a voice note never outranks a help request")
        var book = CarPlayAlertBook()
        XCTAssertEqual(book.next(from: a)?.kind, .friendSOS)
        book.handle(a[0].id)
        XCTAssertEqual(book.next(from: a)?.kind, .talking)
    }

    func testTalkingBanner() {
        var i = input(crew)
        i.talking = CarPlayTalking(noteId: "n1", userId: "a", name: "أبو فهد العتيبي")
        let a = CarPlayAlerts.current(i, guidance: nil)
        XCTAssertEqual(a.map(\.title), ["أبو فهد يتكلم"])
        XCTAssertEqual(a[0].durationS, 5)
        XCTAssertFalse(a[0].sticky)
        i.talking = CarPlayTalking(noteId: "n2", userId: "me", name: "أنا")
        XCTAssertTrue(CarPlayAlerts.current(i, guidance: nil).isEmpty, "my own note: no banner")
    }

    func testPresenceReasonOnlyForNotLive() {
        var i = input(crew)
        i.presenceReasons = ["a": "بلا إنترنت", "b": "الجوال مقفل"]
        let rows = CarPlayPresenter.memberRows(i)
        XCTAssertFalse(rows.first { $0.id == "a" }!.detail.contains("بلا إنترنت"), "live: no reason shown")
        XCTAssertTrue(rows.first { $0.id == "b" }!.detail.contains("الجوال مقفل"))
    }
}
