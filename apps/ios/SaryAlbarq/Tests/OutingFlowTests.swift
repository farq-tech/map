import XCTest
@testable import SaryAlbarq

/// «الطلعة» و«المشوار» (Sources/Core/OutingFlow.swift, Sources/Live/OutingLegsCenter.swift):
/// the state machine, the one big button, the header's words, and the leg lifecycle.
@MainActor
final class OutingFlowTests: XCTestCase {
    private let gas = OutingDestination(name: "محطة الوقود", lat: 24.7240, lng: 46.6960)
    private let camp = OutingDestination(name: "مخيم النفود", lat: 24.7590, lng: 46.7491)
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func leg(_ id: String, _ d: OutingDestination, scope: OutingLeg.Scope = .group, state: OutingLeg.State = .active, seq: Int = 1, at: Date? = nil) -> OutingLeg {
        OutingLeg(id: id, seq: seq, scope: scope, destination: d, state: state, started_at: ISODate.string(at ?? t0))
    }

    private func input(_ status: OutingStatus?, lead: Bool = true, legs: [OutingLeg] = [], picked: OutingDestination? = nil) -> OutingFlowInput {
        var i = OutingFlowInput()
        i.status = status
        i.iLead = lead
        i.iOwn = lead
        i.legs = legs
        i.picked = picked
        i.now = t0
        return i
    }

    // MARK: states and the one button

    func testNotStartedLeaderAndMember() {
        let leader = OutingFlow.ui(input(.created))
        XCTAssertEqual(leader.state, .notStarted)
        XCTAssertEqual(leader.line, "ما بدأت الطلعة")
        XCTAssertEqual(leader.primary, .startOuting)
        XCTAssertEqual(leader.primary?.title, "ابدأ الطلعة")

        let member = OutingFlow.ui(input(.created, lead: false))
        /* UI-AUDIT م3: the member's waiting message is said ONCE — on the button, not in the header too. */
        XCTAssertEqual(member.line, "ما بدأت الطلعة")
        XCTAssertEqual(member.primary, .waitLeader)
        XCTAssertEqual(member.primary?.title, "ننتظر أمير الطلعة")
        XCTAssertFalse(member.line.contains("ننتظر"), "the header does not repeat the button")
    }

    // MARK: «ننتظر أمير الطلعة» with its facts (Build 36 item 9)

    private func member(_ id: String, _ name: String, owner: Bool = false, online: Bool? = nil, away: Bool? = nil, seen: Date? = nil) -> Member {
        Member(user_id: id, display_name: name, avatar: nil, phone: nil, role: owner ? "owner" : "member", sharing: false,
               joined_at: ISODate.string(t0.addingTimeInterval(-3600)), online: online, away: away,
               last_seen_at: seen.map { ISODate.string($0) })
    }

    func testWaitingShowsTheLeaderTheMembersAndMyLink() {
        let all = [member("L", "فهد", owner: true, online: true), member("me", "أنا"), member("b", "سعد", online: true), member("c", "ناصر", online: false)]
        let w = WaitingLeader.info(members: all, myId: "me", clockOffsetMs: 0, myLinkUp: true, myLinkText: "متصل", now: t0)
        XCTAssertEqual(w.leader, "أمير الطلعة فهد متصل الآن")
        XCTAssertTrue(w.leaderOnline)
        XCTAssertEqual(w.members, "الربع ٤ · المتصلين ٣", "me (link up), the leader and سعد")
        XCTAssertNil(w.connection)
        XCTAssertEqual(w.line, "أمير الطلعة فهد متصل الآن · الربع ٤ · المتصلين ٣")
        XCTAssertTrue(w.accessibility.hasPrefix("ما بدأت الطلعة، "))

        let away = WaitingLeader.info(members: [member("L", "فهد", owner: true, online: true, away: true)], myId: "me", clockOffsetMs: 0,
                                      myLinkUp: true, myLinkText: "متصل", now: t0)
        XCTAssertEqual(away.leader, "أمير الطلعة فهد متصل (سرى بالخلفية عنده)")

        /* Offline leader: when we last heard from him, measured on the server's clock. */
        let seen = WaitingLeader.info(members: [member("L", "فهد", owner: true, online: false, seen: t0.addingTimeInterval(-12 * 60 + 30))],
                                      myId: "me", clockOffsetMs: 30_000, myLinkUp: true, myLinkText: "متصل", now: t0)
        XCTAssertEqual(seen.leader, "أمير الطلعة فهد آخر ظهور قبل ١٢ د")
        XCTAssertFalse(seen.leaderOnline)
        let never = WaitingLeader.info(members: [member("L", "فهد", owner: true)], myId: "me", clockOffsetMs: 0, myLinkUp: true, myLinkText: "متصل", now: t0)
        XCTAssertEqual(never.leader, "أمير الطلعة فهد غير متصل الآن")

        /* My link is down: the line says so first (what we show is the last state that reached us). */
        let down = WaitingLeader.info(members: all, myId: "me", clockOffsetMs: 0, myLinkUp: false, myLinkText: "بلا إنترنت", now: t0)
        XCTAssertEqual(down.connection, "اتصالك: بلا إنترنت · آخر حالة وصلتنا")
        XCTAssertEqual(down.members, "الربع ٤ · المتصلين ٢")
        XCTAssertTrue(down.line.hasPrefix("اتصالك: بلا إنترنت"))
    }

    func testWaitingInfoReachesOnlyTheMembersButton() {
        let w = WaitingLeader.info(members: [member("L", "فهد", owner: true, online: true)], myId: "me", clockOffsetMs: 0, myLinkUp: true, myLinkText: "متصل", now: t0)
        var m = input(.created, lead: false)
        m.waiting = w
        XCTAssertEqual(OutingFlow.ui(m).waiting, w)
        var l = input(.created)
        l.waiting = w
        XCTAssertNil(OutingFlow.ui(l).waiting, "the leader starts it: nothing to wait for")
        var running = input(.active, lead: false)
        running.waiting = w
        XCTAssertNil(OutingFlow.ui(running).waiting)
    }

    func testRunningWithoutALegAsksWhereTo() {
        var i = input(.active)
        i.liveCount = 4
        let ui = OutingFlow.ui(i)
        XCTAssertEqual(ui.state, .idle)
        /* «٤ مباشر» is the sheet's line (SarySheetSummary): the header does not repeat the live count. */
        XCTAssertEqual(ui.line, "الطلعة شغّالة")
        XCTAssertFalse(ui.line.contains("مباشر"))
        XCTAssertEqual(ui.primary?.title, "وين رايحين؟")
        XCTAssertEqual(OutingFlow.ui(input(.active, lead: false)).primary, .whereTo, "members start their own legs")
    }

    func testPickedThenOnLegThenArrived() {
        let picked = OutingFlow.ui(input(.active, picked: camp))
        XCTAssertEqual(picked.state, .picked(camp))
        XCTAssertEqual(picked.primary?.title, "ابدأ المشوار")

        var i = input(.active, legs: [leg("l1", camp)])
        i.remainingM = 12_000
        i.eta = t0.addingTimeInterval(18 * 60)
        let on = OutingFlow.ui(i)
        XCTAssertEqual(on.state, .onLeg(leg("l1", camp)))
        XCTAssertEqual(on.line, "في الطريق إلى مخيم النفود · ١٢ كم · ١٨ د")
        XCTAssertEqual(on.primary?.title, "وصلنا")

        /* I arrived (detected or «وصلنا») while the group's leg is still open on the server. */
        i.myArrivedAt = t0.addingTimeInterval(-10)
        let here = OutingFlow.ui(i)
        XCTAssertEqual(here.line, "واقفين عند مخيم النفود")
        XCTAssertEqual(here.primary, .whereTo, "the outing goes on: ONE primary")
    }

    func testArrivedLegStopsUntilTheNextOne() {
        var arrived = leg("l1", camp)
        arrived = LegLifecycle.arrive([arrived], id: "l1", at: t0.addingTimeInterval(-600), distanceM: 34_000)[0]
        var i = input(.active, legs: [arrived])
        let ui = OutingFlow.ui(i)
        XCTAssertEqual(ui.line, "واقفين عند مخيم النفود")
        XCTAssertEqual(ui.primary, .whereTo)
        i.endSuggested = true
        XCTAssertEqual(OutingFlow.ui(i).primary, .endOuting, "back near the start after hours: «أنهِ الطلعة» first")
        XCTAssertEqual(OutingFlowUI(state: .idle, line: "", primary: nil).primary, nil)
        XCTAssertEqual(OutingFlow.momentS, 4, "the arrival moment is a 4-second toast")
    }

    /// UI-AUDIT م3: «أنهِ الطلعة» is the CTA only for the owner (the server ends with `requireOwner`);
    /// a co-leader who may start never gets it.
    func testEndSuggestionFollowsTheServersOwnerRule() {
        var arrived = leg("l1", camp)
        arrived = LegLifecycle.arrive([arrived], id: "l1", at: t0.addingTimeInterval(-600), distanceM: 34_000)[0]
        var i = input(.active, legs: [arrived])
        i.endSuggested = true
        i.iLead = true
        i.iOwn = false
        XCTAssertEqual(OutingFlow.ui(i).primary, .whereTo, "a co-leader cannot end: no «أنهِ الطلعة» CTA")
        i.iOwn = true
        XCTAssertEqual(OutingFlow.ui(i).primary, .endOuting)
        XCTAssertEqual(OutingCTA.endOuting.systemImage, EndOutingCopy.systemImage, "one icon for ending")
        XCTAssertEqual(OutingCTA.arrived.systemImage, "flag.checkered", "the flag stays «وصلنا»'s")
        XCTAssertNotEqual(EndOutingCopy.systemImage, OutingCTA.arrived.systemImage)
    }

    /// ONE confirmation everywhere (UI-AUDIT §٢ word dictionary).
    func testEndOutingConfirmationCopy() {
        XCTAssertEqual(EndOutingCopy.title, "تنهي الطلعة للكل؟")
        XCTAssertEqual(EndOutingCopy.confirm, "أنهِها")
        XCTAssertEqual(EndOutingCopy.cancel, "لا")
        XCTAssertEqual(EndOutingCopy.systemImage, "house.fill")
        XCTAssertFalse(EndOutingCopy.message().contains("الرحلة"), "«الطلعة», never «الرحلة»")
        XCTAssertNotEqual(EndOutingCopy.message(everyoneArrived: true), EndOutingCopy.message())
    }

    func testPausedAndEnded() {
        XCTAssertEqual(OutingFlow.ui(input(.paused)).line, "الطلعة متوقفة مؤقتًا")
        XCTAssertNil(OutingFlow.ui(input(.paused)).primary)
        let ended = OutingFlow.ui(input(.ended, legs: [leg("l1", camp)]))
        XCTAssertEqual(ended.state, .ended)
        XCTAssertEqual(ended.primary, .summary)
    }

    func testMyPersonalLegDrivesTheScreenOverTheGroups() {
        let g = leg("g", camp)
        let p = leg("p", gas, scope: .personal, seq: 2)
        XCTAssertEqual(LegLifecycle.current([g, p])?.id, "p")
        XCTAssertEqual(LegLifecycle.current([g])?.id, "g")
    }

    func testMinutesLine() {
        XCTAssertEqual(OutingFlow.minutesLine(t0.addingTimeInterval(65 * 60), now: t0), "١ س ٥ د")
        XCTAssertEqual(OutingFlow.minutesLine(t0.addingTimeInterval(120 * 60), now: t0), "٢ س")
        XCTAssertEqual(OutingFlow.minutesLine(t0.addingTimeInterval(5), now: t0), "١ د")
        XCTAssertNil(OutingFlow.minutesLine(nil, now: t0))
    }

    // MARK: leg lifecycle

    func testStartReplacesTheActiveLegOfTheSameScopeOnly() {
        var legs = LegLifecycle.start([], leg("a", gas), now: t0)
        legs = LegLifecycle.start(legs, leg("p", camp, scope: .personal), now: t0)
        legs = LegLifecycle.start(legs, leg("b", camp), now: t0)
        XCTAssertEqual(legs.map(\.seq), [1, 2, 3])
        XCTAssertEqual(legs.first { $0.id == "a" }?.state, .cancelled)
        XCTAssertEqual(legs.first { $0.id == "p" }?.state, .active, "a member's own leg is not the group's")
        XCTAssertEqual(LegLifecycle.timeline(legs).map(\.id), ["p", "b"], "a changed mind is not a leg")
    }

    func testArriveEndsThatLegOnlyAndIsIdempotent() {
        var legs = LegLifecycle.start([], leg("a", gas, at: t0), now: t0)
        let at = t0.addingTimeInterval(900)
        legs = LegLifecycle.arrive(legs, id: "a", at: at, distanceM: 8200)
        XCTAssertEqual(legs[0].state, .arrived)
        XCTAssertEqual(legs[0].duration_s, 900)
        XCTAssertEqual(legs[0].distance_m, 8200)
        let again = LegLifecycle.arrive(legs, id: "a", at: at.addingTimeInterval(60), distanceM: 1)
        XCTAssertEqual(again, legs)
        XCTAssertEqual(LegLifecycle.lastArrived(legs)?.id, "a")
    }

    func testEndingTheOutingClosesWhatIsStillOnTheWay() {
        var legs = LegLifecycle.start([], leg("a", gas), now: t0)
        legs = LegLifecycle.arrive(legs, id: "a", at: t0, distanceM: nil)
        legs = LegLifecycle.start(legs, leg("b", camp), now: t0)
        legs = LegLifecycle.endOuting(legs, now: t0)
        XCTAssertEqual(legs.map(\.state), [.arrived, .ended])
        XCTAssertEqual(LegText.title(legs[1]), "إلى مخيم النفود (ما كمل)")
        XCTAssertEqual(LegText.title(legs[0]), "وصلنا محطة الوقود")
    }

    func testLegNumbersAreOnlyRealOnes() {
        var l = leg("a", gas, at: t0)
        l = LegLifecycle.arrive([l], id: "a", at: t0.addingTimeInterval(20), distanceM: 0)[0]
        let d = LegText.detail(l, now: t0)
        XCTAssertFalse(d.contains("٠ م"), d)
        XCTAssertFalse(d.contains("٠ د"), d)
        l = LegLifecycle.arrive([leg("b", gas, at: t0)], id: "b", at: t0.addingTimeInterval(18 * 60), distanceM: 12_000)[0]
        XCTAssertTrue(LegText.detail(l, now: t0).contains("١٢ كم"), LegText.detail(l, now: t0))
    }

    func testDecodesTheServerShapeAndToleratesNewStates() throws {
        let json = #"{"id":"x","seq":2,"scope":"group","destination":{"name":"روضة","lat":25.1,"lng":46.2},"state":"teleported","started_at":"2026-11-06T18:00:00.000Z","arrived_at":null,"distance_m":null}"#
        let l = try JSONDecoder().decode(OutingLeg.self, from: Data(json.utf8))
        XCTAssertEqual(l.seq, 2)
        XCTAssertEqual(l.state, .ended)
        XCTAssertEqual(l.destination.name, "روضة")
    }

    func testEndSuggestion() {
        let start = LngLat(lng: 46.6744, lat: 24.7113)
        let near = LngLat(lng: 46.6750, lat: 24.7120)
        let far = LngLat(lng: 46.9, lat: 24.9)
        let started = t0.addingTimeInterval(-4 * 3600)
        XCTAssertTrue(OutingEndSuggest.shouldSuggest(startedAt: started, groupStart: start, livePositions: [near, near], hasActiveLeg: false, now: t0))
        XCTAssertFalse(OutingEndSuggest.shouldSuggest(startedAt: started, groupStart: start, livePositions: [near, far], hasActiveLeg: false, now: t0))
        XCTAssertFalse(OutingEndSuggest.shouldSuggest(startedAt: t0.addingTimeInterval(-3600), groupStart: start, livePositions: [near], hasActiveLeg: false, now: t0))
        XCTAssertFalse(OutingEndSuggest.shouldSuggest(startedAt: started, groupStart: start, livePositions: [near], hasActiveLeg: true, now: t0))
    }

    // MARK: the center (local, as on an API without legs)

    func testCenterLocalLifecycleAndStore() async {
        let d = UserDefaults(suiteName: "legs-\(UUID().uuidString)")!
        let c = OutingLegsCenter(outingId: "o1", backend: nil, defaults: d)
        var began: [String] = []
        c.onNewLeg = { began.append($0.id) }
        c.picked = gas
        let a = await c.start(gas, scope: .group, myId: "me", now: t0)
        XCTAssertNil(c.picked)
        XCTAssertEqual(c.current?.id, a?.id)
        XCTAssertEqual(began, [a?.id].compactMap { $0 })
        await c.arrive(a!.id, at: t0.addingTimeInterval(600), distanceM: 5000)
        XCTAssertNil(c.current)
        let b = await c.start(camp, scope: .group, myId: "me", now: t0)
        await c.arrive(b!.id, at: t0.addingTimeInterval(1200), distanceM: 30_000)
        c.outingEnded()
        XCTAssertEqual(c.timeline.count, 2)
        XCTAssertEqual(OutingLegStore.load("o1", defaults: d).count, 2, "kept on this phone for the summary")
        XCTAssertEqual(began.count, 2)
    }

    // MARK: the trip record restarts per leg

    func testBeginLegKeepsTheStartAndForgetsTheArrival() {
        var r = TripRecord()
        r.start = TripStartPoint(lat: 24.7, lng: 46.6, atMs: 1)
        r.groupStart = r.start
        r.me.markArrived(atMs: 2)
        r.arrivals["me"] = 2
        r.beginLeg()
        XCTAssertFalse(r.me.arrived)
        XCTAssertTrue(r.arrivals.isEmpty)
        XCTAssertNotNil(r.start)
        XCTAssertNotNil(r.groupStart)
    }
}

/// Build 36 (owner's report item 10): stopping the guidance, arriving, ending and leaving are
/// separate states; «أوقف التوجيه» brought the outing back with «وصلنا» as its one button.
@MainActor
final class OutingGuidanceStateTests: XCTestCase {
    private let camp = OutingDestination(name: "مخيم النفود", lat: 24.7590, lng: 46.7491)
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func onLeg(_ g: TripGuidanceState, arrivedAt: Date? = nil) -> OutingFlowInput {
        var i = OutingFlowInput()
        i.status = .active
        i.iLead = true
        i.iOwn = true
        i.legs = [OutingLeg(id: "l1", seq: 1, scope: .group, destination: camp, started_at: ISODate.string(t0))]
        i.guidance = g
        i.myArrivedAt = arrivedAt
        i.now = t0
        return i
    }

    func testStoppedGuidanceIsNotAnArrival() {
        let ui = OutingFlow.ui(onLeg(.paused))
        XCTAssertEqual(ui.state, .onLeg(onLeg(.paused).legs[0]), "the leg goes on")
        XCTAssertEqual(ui.primary, .resumeGuidance)
        XCTAssertEqual(ui.primary?.title, "استأنف التوجيه")
        XCTAssertNotEqual(ui.primary, .arrived, "«وصلنا» is not what «أوقف التوجيه» leads to")
        XCTAssertTrue(ui.line.hasPrefix("في الطريق إلى مخيم النفود"), ui.line)
        XCTAssertTrue(ui.line.contains("التوجيه موقّف"), ui.line)
        XCTAssertEqual(OutingCTA.resumeGuidance.id, "nav.auto.resume", "the identifier the guidance prompt had")
    }

    func testGuidingOrOffKeepsArrivedAsTheLegsAction() {
        XCTAssertEqual(OutingFlow.ui(onLeg(.guiding)).primary, .arrived)
        XCTAssertEqual(OutingFlow.ui(onLeg(.off)).primary, .arrived)
        XCTAssertFalse(OutingFlow.ui(onLeg(.guiding)).line.contains("موقّف"))
    }

    func testArrivalStopsTheLegButNotTheOuting() {
        let ui = OutingFlow.ui(onLeg(.arrived, arrivedAt: t0))
        XCTAssertEqual(ui.state, .stopped(at: camp.name, since: t0))
        XCTAssertEqual(ui.primary, .whereTo, "the outing goes on: «وين رايحين؟», never «أنهِ الطلعة» by itself")
        var ended = onLeg(.paused)
        ended.status = .ended
        XCTAssertEqual(OutingFlow.ui(ended).primary, .summary, "an ended outing has no guidance button")
    }

    func testTheStateIsDerivedOnlyFromItsOwnFacts() {
        XCTAssertEqual(TripGuidanceState.of(guiding: true, paused: false, arrived: false), .guiding)
        XCTAssertEqual(TripGuidanceState.of(guiding: false, paused: true, arrived: false), .paused)
        XCTAssertEqual(TripGuidanceState.of(guiding: true, paused: true, arrived: false), .guiding, "«استأنف» / a person's own guidance runs")
        XCTAssertEqual(TripGuidanceState.of(guiding: false, paused: true, arrived: true), .arrived)
        XCTAssertEqual(TripGuidanceState.of(guiding: false, paused: false, arrived: false), .off)
    }

    /// The header and the guidance bar count the minutes left the same way (build 36: «١٩ د» over «١٨ د»).
    func testHeaderMinutesMatchTheGuidanceBar() {
        for s in [18 * 60 + 40.0, 18 * 60 + 5, 65 * 60 + 50, 61 * 60] {
            let line = OutingFlow.minutesLine(t0.addingTimeInterval(s), now: t0)
            XCTAssertEqual(line, NavText.remaining(seconds: s), "\(s) s")
        }
    }
}
