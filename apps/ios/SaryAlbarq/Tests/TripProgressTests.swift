import XCTest
@testable import SaryAlbarq

/// «رحلة كاملة»: start → destination → arrival → end (Sources/Core/TripProgress.swift,
/// Sources/Live/TripPresenter.swift).
final class TripProgressTests: XCTestCase {
    private let dest = LngLat(lng: 46.7491, lat: 24.7590)
    private let destination = OutingDestination(name: "روضة الثمامة", lat: 24.7590, lng: 46.7491)
    private let me = "me"
    private let t0 = 1_800_000_000_000.0

    /// A point `m` metres due south of the destination.
    private func south(_ m: Double) -> LngLat { LngLat(lng: dest.lng, lat: dest.lat - m / 111_195) }

    private func fix(_ p: LngLat, at t: Double, acc: Double? = 8, speed: Double? = nil) -> DeviceFix {
        DeviceFix(lat: p.lat, lng: p.lng, accuracy: acc, heading: nil, speed: speed, atMs: t)
    }

    // MARK: start / end state machine

    func testPhasesFromNoDestinationToEnded() {
        var r = TripRecord()
        XCTAssertEqual(r.phase(hasDestination: false, status: .created), .needsDestination)
        XCTAssertEqual(r.phase(hasDestination: false, status: .active), .needsDestination, "no trip without an end")
        XCTAssertEqual(r.phase(hasDestination: true, status: .created), .notStarted)
        XCTAssertEqual(r.phase(hasDestination: true, status: .active), .waitingFirstFix)

        /* Not started: a fix is no start point. */
        XCTAssertTrue(r.ingestMine(fix(south(9000), at: t0), myId: me, destination: dest, status: .created, outingStartedMs: nil, nowMs: t0).isEmpty)
        XCTAssertNil(r.start)

        let ev = r.ingestMine(fix(south(9000), at: t0 + 1000), myId: me, destination: dest, status: .active, outingStartedMs: t0, nowMs: t0 + 1500)
        XCTAssertEqual(ev, [.started(TripStartPoint(lat: south(9000).lat, lng: south(9000).lng, atMs: t0 + 1000))])
        XCTAssertEqual(r.phase(hasDestination: true, status: .active), .underway)

        /* The start is fixed once: later fixes don't move it. */
        _ = r.ingestMine(fix(south(8000), at: t0 + 60_000), myId: me, destination: dest, status: .active, outingStartedMs: t0, nowMs: t0 + 60_500)
        XCTAssertEqual(r.start?.atMs, t0 + 1000)

        let arrived = r.markArrived(myId: me, nowMs: t0 + 3_600_000)
        XCTAssertEqual(arrived, [.arrived(atMs: t0 + 3_600_000, manual: true)])
        XCTAssertEqual(r.phase(hasDestination: true, status: .active), .arrived(at: Date(timeIntervalSince1970: (t0 + 3_600_000) / 1000)))
        XCTAssertTrue(r.markArrived(myId: me, nowMs: t0 + 3_700_000).isEmpty, "arrives once")

        r.ended(nowMs: t0 + 4_000_000)
        XCTAssertEqual(r.phase(hasDestination: true, status: .active), .ended)
        XCTAssertEqual(r.phase(hasDestination: true, status: .ended), .ended)
        XCTAssertTrue(r.markArrived(myId: me, nowMs: t0 + 4_100_000).isEmpty, "nothing after the end")
    }

    func testStartIsMyFirstLiveFixAfterTheOutingStarted() {
        var r = TripRecord()
        /* A fix from before the start (cached GPS) is not the start. */
        XCTAssertTrue(r.ingestMine(fix(south(5000), at: t0 - 60_000), myId: me, destination: dest, status: .active, outingStartedMs: t0, nowMs: t0 - 59_000).isEmpty)
        /* A stale fix (40 s old) is not "now" either. */
        XCTAssertTrue(r.ingestMine(fix(south(5000), at: t0 + 1000), myId: me, destination: dest, status: .active, outingStartedMs: t0, nowMs: t0 + 41_000).isEmpty)
        /* Nor a vague one. */
        XCTAssertTrue(r.ingestMine(fix(south(5000), at: t0 + 50_000, acc: 400), myId: me, destination: dest, status: .active, outingStartedMs: t0, nowMs: t0 + 50_500).isEmpty)
        XCTAssertNil(r.start)
        _ = r.ingestMine(fix(south(5000), at: t0 + 60_000), myId: me, destination: dest, status: .active, outingStartedMs: t0, nowMs: t0 + 60_200)
        XCTAssertEqual(r.start?.atMs, t0 + 60_000)
    }

    func testStorePersistsPerOutingAndForgets() {
        let d = UserDefaults(suiteName: "trip.\(UUID().uuidString)")!
        var r = TripRecord()
        r.start = TripStartPoint(lat: 24.7, lng: 46.6, atMs: t0)
        TripStore.save("o1", r, defaults: d)
        XCTAssertEqual(TripStore.load("o1", defaults: d), r)
        XCTAssertNil(TripStore.load("o2", defaults: d))
        ReturnTripStore.link("o2", returnsFrom: "o1", defaults: d)
        XCTAssertEqual(ReturnTripStore.origin(of: "o2", defaults: d), "o1")
        TripStore.forgetAll(defaults: d)
        ReturnTripStore.forgetAll(defaults: d)
        XCTAssertNil(TripStore.load("o1", defaults: d))
        XCTAssertNil(ReturnTripStore.origin(of: "o2", defaults: d))
    }

    /// UI-AUDIT 0.3: «طريق الرجعة» with no network starts on this phone; other refusals stay errors.
    func testReturnTripOfflineFallsBackToThePhone() {
        XCTAssertTrue(ReturnTripStore.failedOffline(online: false, errorText: nil), "no network path")
        XCTAssertTrue(ReturnTripStore.failedOffline(online: true, errorText: OutingAPIError(code: "network", status: 0).arabic))
        XCTAssertTrue(ReturnTripStore.failedOffline(online: true, errorText: OutingAPIError(code: "timeout", status: 0).arabic))
        XCTAssertFalse(ReturnTripStore.failedOffline(online: true, errorText: OutingAPIError(code: "rate_limited", status: 429).arabic))
        XCTAssertFalse(ReturnTripStore.failedOffline(online: true, errorText: "ما عندنا نقطة بداية محفوظة لهذه الطلعة على هذا الجوال."))
        XCTAssertFalse(ReturnTripStore.failedOffline(online: true, errorText: nil))
    }

    func testArrivalBelongsOnlyToTheDestinationThatWasReached() {
        var r = TripRecord()
        r.bindArrivalDestination(dest)
        _ = r.markArrived(myId: me, nowMs: t0)
        XCTAssertTrue(r.me.arrived)
        XCTAssertEqual(r.arrivals[me], t0)

        let next = LngLat(lng: dest.lng + 0.02, lat: dest.lat)
        r.bindArrivalDestination(next)

        XCTAssertFalse(r.me.arrived, "a previous destination must not make the next one look reached")
        XCTAssertNil(r.me.insideSinceMs)
        XCTAssertFalse(r.arrivedManually)
        XCTAssertTrue(r.arrivals.isEmpty)
        XCTAssertTrue(r.friends.isEmpty)
    }

    // MARK: arrival detection

    func testArrivesAfterThirtySecondsInside() {
        var a = ArrivalDetector()
        XCTAssertFalse(a.ingest(distanceM: 400, accuracy: 8, atMs: t0))
        XCTAssertFalse(a.ingest(distanceM: 140, accuracy: 8, atMs: t0 + 5000))
        XCTAssertFalse(a.ingest(distanceM: 90, accuracy: 8, atMs: t0 + 20_000))
        XCTAssertTrue(a.ingest(distanceM: 60, accuracy: 8, atMs: t0 + 35_000))
        XCTAssertEqual(a.arrivedAtMs, t0 + 5000, "arrival time = when I came inside")
        XCTAssertFalse(a.ingest(distanceM: 10, accuracy: 8, atMs: t0 + 60_000), "once")
    }

    func testDrivingThroughDoesNotArrive() {
        var a = ArrivalDetector()
        /* 20 m/s straight past the destination: inside for ~15 s only. */
        var t = t0
        for d in stride(from: 600.0, through: -600, by: -100) {
            XCTAssertFalse(a.ingest(distanceM: abs(d), accuracy: 6, atMs: t))
            t += 5000
        }
        XCTAssertFalse(a.arrived)
        XCTAssertFalse(a.evaluate(nowMs: t + 120_000), "it left: the clock does not finish it")
    }

    func testJitterAtTheBoundaryNeitherFakesNorResetsArrival() {
        /* Parked right at 150 m: the fixes wobble 135–205 m. Hysteresis keeps the dwell. */
        var a = ArrivalDetector()
        let wobble = [140.0, 165, 138, 205, 150, 172, 145]
        var arrived = false
        for (k, d) in wobble.enumerated() { arrived = a.ingest(distanceM: d, accuracy: 12, atMs: t0 + Double(k) * 6000) || arrived }
        XCTAssertTrue(arrived, "a wobble across 150 m still arrives")

        /* Wobbling just outside (155–190 m) never entered: no arrival. */
        var b = ArrivalDetector()
        for (k, d) in [155.0, 190, 160, 175, 158, 181].enumerated() { XCTAssertFalse(b.ingest(distanceM: d, accuracy: 10, atMs: t0 + Double(k) * 6000)) }
        XCTAssertFalse(b.evaluate(nowMs: t0 + 120_000))

        /* One wild jump (accuracy 300 m) neither resets nor counts. */
        var c = ArrivalDetector()
        c.ingest(distanceM: 100, accuracy: 10, atMs: t0)
        XCTAssertFalse(c.ingest(distanceM: 900, accuracy: 300, atMs: t0 + 10_000))
        XCTAssertTrue(c.ingest(distanceM: 110, accuracy: 10, atMs: t0 + 31_000))

        /* A clean exit past 220 m resets the dwell. */
        var e = ArrivalDetector()
        e.ingest(distanceM: 100, accuracy: 5, atMs: t0)
        e.ingest(distanceM: 260, accuracy: 5, atMs: t0 + 20_000)
        XCTAssertFalse(e.ingest(distanceM: 100, accuracy: 5, atMs: t0 + 35_000), "the dwell starts again")
        XCTAssertTrue(e.ingest(distanceM: 100, accuracy: 5, atMs: t0 + 66_000))
    }

    func testParkedCarWithNoNewFixArrivesOnTheClock() {
        var a = ArrivalDetector()
        a.ingest(distanceM: 50, accuracy: 5, atMs: t0)
        XCTAssertFalse(a.evaluate(nowMs: t0 + 20_000))
        XCTAssertTrue(a.evaluate(nowMs: t0 + 31_000))
        /* But not on a fix that is long gone (the phone lost GPS). */
        var b = ArrivalDetector()
        b.ingest(distanceM: 50, accuracy: 5, atMs: t0)
        XCTAssertFalse(b.evaluate(nowMs: t0 + 400_000))
    }

    func testRecordArrivesMeAndFriendsOnlyFromLivePositions() {
        var r = TripRecord()
        _ = r.ingestMine(fix(south(100), at: t0), myId: me, destination: dest, status: .active, outingStartedMs: t0 - 1000, nowMs: t0)
        let ev = r.ingestMine(fix(south(80), at: t0 + 32_000), myId: me, destination: dest, status: .active, outingStartedMs: t0 - 1000, nowMs: t0 + 32_000)
        XCTAssertTrue(ev.contains(.arrived(atMs: t0, manual: false)))
        XCTAssertEqual(r.arrivals[me], t0)

        /* A friend whose last position is old, even inside: never «وصل». */
        let p = south(20)
        XCTAssertTrue(r.ingestFriend("f", lat: p.lat, lng: p.lng, accuracy: 5, atMs: t0, live: false, destination: dest, nowMs: t0 + 600_000).isEmpty)
        XCTAssertTrue(r.ingestFriend("f", lat: p.lat, lng: p.lng, accuracy: 5, atMs: t0 + 1000, live: true, destination: dest, nowMs: t0 + 1000).isEmpty)
        let fe = r.ingestFriend("f", lat: p.lat, lng: p.lng, accuracy: 5, atMs: t0 + 1000, live: true, destination: dest, nowMs: t0 + 40_000)
        XCTAssertEqual(fe, [.memberArrived("f", atMs: t0 + 1000)])
    }

    // MARK: remaining distance: navigation → planned route → straight line

    func testRemainingSourcePriority() {
        let here = south(10_000)
        /* Planned route: a dog-leg 2 km east then north. */
        let east = LngLat(lng: here.lng + 2000 / (111_195 * cos(here.lat * .pi / 180)), lat: here.lat)
        let route = [here, east, LngLat(lng: east.lng, lat: dest.lat)]

        let nav = TripMath.remaining(me: here, destination: dest, navRemainingM: 13_400, navTarget: dest, navGuiding: true, planRoute: route)
        XCTAssertEqual(nav.source, .navigation)
        XCTAssertEqual(nav.meters, 13_400)

        /* Guidance to somewhere else (a friend) is not the trip's remaining. */
        let other = TripMath.remaining(me: here, destination: dest, navRemainingM: 900, navTarget: south(5000), navGuiding: true, planRoute: route)
        XCTAssertEqual(other.source, .plannedRoute)
        XCTAssertEqual(other.meters, 2000 + 10_000 + 2000, accuracy: 60, "along the route, then the last leg to the destination")
        XCTAssertFalse(other.source.approximate)

        /* Navigation planned but not guiding: not used. */
        XCTAssertEqual(TripMath.remaining(me: here, destination: dest, navRemainingM: 500, navTarget: dest, navGuiding: false, planRoute: route).source, .plannedRoute)

        let straight = TripMath.remaining(me: here, destination: dest, navRemainingM: nil, navTarget: nil, navGuiding: false, planRoute: [])
        XCTAssertEqual(straight.source, .straightLine)
        XCTAssertTrue(straight.source.approximate, "said «تقريبي»")
        XCTAssertEqual(straight.meters, 10_000, accuracy: 20)

        /* Far off the planned route (> 3 km), the route says nothing about my way. */
        let far = LngLat(lng: here.lng - 0.08, lat: here.lat)
        XCTAssertEqual(TripMath.remaining(me: far, destination: dest, navRemainingM: nil, navTarget: nil, navGuiding: false, planRoute: route).source, .straightLine)
    }

    // MARK: progress

    func testProgressMath() {
        XCTAssertEqual(TripMath.progress(drivenM: 0, remainingM: 10_000, arrived: false), 0)
        XCTAssertEqual(TripMath.progress(drivenM: 6200, remainingM: 3800, arrived: false)!, 0.62, accuracy: 1e-9)
        XCTAssertEqual(TripMath.percent(0.62), 62)
        XCTAssertEqual(TripMath.progress(drivenM: 50_000, remainingM: 0, arrived: false), 0.99, "never 100 % before arriving")
        XCTAssertEqual(TripMath.percent(0.999), 99)
        XCTAssertEqual(TripMath.progress(drivenM: 10, remainingM: 10, arrived: true), 1)
        XCTAssertEqual(TripMath.percent(1), 100)
        XCTAssertNil(TripMath.progress(drivenM: 100, remainingM: nil, arrived: false), "no remaining, no percent")
        XCTAssertEqual(TripMath.progress(drivenM: 0, remainingM: 0, arrived: false), 0)
        /* A detour adds remaining: the percent drops, honestly. */
        let before = TripMath.progress(drivenM: 5000, remainingM: 5000, arrived: false)!
        let after = TripMath.progress(drivenM: 6000, remainingM: 7000, arrived: false)!
        XCTAssertLessThan(after, before)
    }

    func testDrivenMetersCountFromTheStartOnly() {
        let pts = (0..<11).map { k in TrailPoint(lat: south(10_000 - Double(k) * 1000).lat, lng: dest.lng, t: t0 + Double(k) * 60_000) }
        XCTAssertEqual(TripMath.drivenMeters(trail: pts, sinceMs: t0), 10_000, accuracy: 20)
        XCTAssertEqual(TripMath.drivenMeters(trail: pts, sinceMs: t0 + 5 * 60_000), 5000, accuracy: 20)
        XCTAssertEqual(TripMath.drivenMeters(trail: [], sinceMs: t0), 0)
    }

    func testETAPrefersNavigationThenMyAverage() {
        let now = Date(timeIntervalSince1970: t0 / 1000)
        let navETA = now.addingTimeInterval(900)
        let n = TripMath.eta(remaining: RemainingDistance(meters: 12_000, source: .navigation, navETA: navETA), avgMovingKmh: 80, now: now)
        XCTAssertEqual(n.date, navETA)
        XCTAssertFalse(n.estimated)
        let a = TripMath.eta(remaining: RemainingDistance(meters: 12_000, source: .straightLine), avgMovingKmh: 60, now: now)
        XCTAssertEqual(a.date.timeIntervalSince(now), 720, accuracy: 1)
        XCTAssertTrue(a.estimated)
        let d = TripMath.eta(remaining: RemainingDistance(meters: 10_000, source: .plannedRoute), avgMovingKmh: 2, now: now)
        XCTAssertEqual(d.date.timeIntervalSince(now), 720, accuracy: 1, "parked average → the cautious 50 km/h")
    }

    // MARK: moving / stopped

    func testMovingStoppedSplitAndLongestStop() {
        var log = TripLog()
        var t = t0
        var p = south(20_000)
        func step(_ m: Double, _ s: Double, speed: Double?) {
            t += s * 1000
            p = LngLat(lng: p.lng, lat: p.lat + m / 111_195)
            log.add(lat: p.lat, lng: p.lng, accuracy: 5, speed: speed, atMs: t)
        }
        log.add(lat: p.lat, lng: p.lng, accuracy: 5, speed: 0, atMs: t)
        for _ in 0..<60 { step(200, 10, speed: 20) }      // 10 min driving
        for _ in 0..<30 { step(0, 10, speed: 0) }         // 5 min stopped
        for _ in 0..<30 { step(200, 10, speed: 20) }      // 5 min driving
        for _ in 0..<12 { step(0, 10, speed: 0) }         // 2 min stopped (still now)
        let m = TripMotion.make(log: log, startMs: t0, endMs: t)
        XCTAssertEqual(m.elapsedS, 22 * 60)
        XCTAssertEqual(Double(m.movingS), 15 * 60, accuracy: 15)
        XCTAssertEqual(Double(m.stoppedS), 7 * 60, accuracy: 15)
        XCTAssertEqual(Double(m.longestStopS ?? 0), 5 * 60, accuracy: 15)
        XCTAssertEqual(m.avgMovingKmh ?? 0, 72, accuracy: 2)
        XCTAssertEqual(m.maxKmh ?? 0, 72, accuracy: 1)
    }

    func testParkedWithTheScreenLockedIsAStopNotDriving() {
        var log = TripLog()
        let p = south(5000)
        log.add(lat: p.lat, lng: p.lng, accuracy: 5, speed: 0, atMs: t0)
        /* 20 min of silence, then a fix in the same place. */
        log.add(lat: p.lat, lng: p.lng, accuracy: 5, speed: 0, atMs: t0 + 20 * 60_000)
        let q = south(4000)
        log.add(lat: q.lat, lng: q.lng, accuracy: 5, speed: 20, atMs: t0 + 20 * 60_000 + 50_000)
        XCTAssertEqual(log.longestStopS ?? 0, 20 * 60, accuracy: 1)
        XCTAssertEqual(log.movingS, 50, accuracy: 1)
        /* Old saved logs (no stop fields) still decode. */
        let old = #"{"distanceM":10,"movingS":5}"#.data(using: .utf8)!
        XCTAssertNotNil(try? JSONDecoder().decode(TripLog.self, from: old))
    }

    // MARK: arrival order

    func testArrivalOrderLine() {
        let members = [(id: me, name: "راشد"), (id: "f", name: "فهد"), (id: "s", name: "سلطان"), (id: "n", name: "نورة")]
        XCTAssertNil(ArrivalOrder.line(arrivals: [:], members: members, myId: me))
        let arr = ["s": t0 + 500, "f": t0, me: t0 + 900]
        XCTAssertEqual(ArrivalOrder.line(arrivals: arr, members: members, myId: me), "وصل أول: فهد، ثم سلطان، أنت · باقي: نورة")
        XCTAssertFalse(ArrivalOrder.everyoneArrived(arrivals: arr, memberIds: members.map(\.id)))
        var all = arr
        all["n"] = t0 + 2000
        XCTAssertTrue(ArrivalOrder.everyoneArrived(arrivals: all, memberIds: members.map(\.id)))
        XCTAssertEqual(ArrivalOrder.line(arrivals: all, members: members, myId: me), "وصل أول: فهد، ثم سلطان، أنت، نورة · وصل الجميع")
        /* Someone who left the outing is not listed. */
        XCTAssertEqual(ArrivalOrder.split(arrivals: ["gone": t0], members: members).arrived, [])
    }

    // MARK: the presenter

    private func input(fixAt p: LngLat?, fixAgeS: Double = 2, trail: [TrailPoint] = [], record: TripRecord? = nil) -> TripPresenterInput {
        var i = TripPresenterInput()
        let now = Date(timeIntervalSince1970: (t0 + 3_600_000) / 1000)
        var r = record ?? TripRecord()
        if record == nil { r.start = TripStartPoint(lat: south(10_000).lat, lng: dest.lng, atMs: t0) }
        i.record = r
        i.destination = destination
        i.status = .active
        i.myId = me
        i.myFix = p.map { fix($0, at: now.timeIntervalSince1970 * 1000 - fixAgeS * 1000) }
        i.trail = trail
        i.members = [(me, "أنا"), ("f", "فهد")]
        i.now = now
        return i
    }

    func testPanelUnderwayShowsProgressRemainingAndETA() {
        let trail = (0..<7).map { k in TrailPoint(lat: south(10_000 - Double(k) * 1000).lat, lng: dest.lng, t: t0 + Double(k) * 60_000) }
        let ui = TripPresenter.panel(input(fixAt: south(4000), trail: trail))
        XCTAssertEqual(ui.phase, .underway)
        XCTAssertEqual(ui.drivenMeters, 6000, accuracy: 20)
        XCTAssertEqual(ui.remainingMeters ?? 0, 4000, accuracy: 20)
        XCTAssertEqual(ui.remainingSource, .straightLine)
        XCTAssertEqual(ui.percent, 60)
        XCTAssertEqual(ui.progressLine, "قطعنا ٦٠٪")
        XCTAssertEqual(ui.remainingLine, "باقي ٤ كم تقريبي")
        XCTAssertNotNil(ui.eta)
        XCTAssertEqual(ui.elapsedSeconds, 3600)
    }

    func testPanelNeverComputesFromAStaleFix() {
        let ui = TripPresenter.panel(input(fixAt: south(4000), fixAgeS: 600))
        XCTAssertNil(ui.remainingMeters)
        XCTAssertNil(ui.eta)
        XCTAssertNil(ui.percent)
        XCTAssertNotNil(ui.myFixStaleSince, "says «آخر موقع قبل …» instead")
        /* A friend's old position: no remaining, no «وصل». */
        let m = TripPresenter.member(id: "f", position: Geo.LatLng(lat: dest.lat, lng: dest.lng), live: false, destination: destination, arrivals: [:])
        XCTAssertNil(m.remainingM)
        XCTAssertFalse(m.arrived)
        let live = TripPresenter.member(id: "f", position: Geo.LatLng(lat: south(3000).lat, lng: dest.lng), live: true, destination: destination, arrivals: [:])
        XCTAssertEqual(live.remainingM ?? 0, 3000, accuracy: 10)
        XCTAssertTrue(TripPresenter.member(id: "f", position: nil, live: false, destination: destination, arrivals: ["f": t0]).arrived)
    }

    func testPanelArrivedAndEnded() {
        var r = TripRecord()
        r.start = TripStartPoint(lat: south(10_000).lat, lng: dest.lng, atMs: t0)
        _ = r.markArrived(myId: me, nowMs: t0 + 1_800_000)
        var i = input(fixAt: south(30), record: r)
        var ui = TripPresenter.panel(i)
        XCTAssertEqual(ui.phase, .arrived(at: Date(timeIntervalSince1970: (t0 + 1_800_000) / 1000), manual: true))
        XCTAssertEqual(ui.percent, 100)
        XCTAssertEqual(ui.elapsedSeconds, 1800, "the clock stops at arrival")
        XCTAssertEqual(ui.arrivalLine, "وصل أول: أنت · باقي: فهد")
        XCTAssertFalse(ui.everyoneArrived)
        XCTAssertFalse(ui.canEnd, "only the leader ends it")
        i.iLead = true
        XCTAssertTrue(TripPresenter.panel(i).canEnd)
        i.status = .ended
        ui = TripPresenter.panel(i)
        XCTAssertEqual(ui.phase, .ended)
        XCTAssertFalse(ui.canEnd)
    }

    func testPanelWithoutDestinationAsksTheLeaderOnly() {
        var i = input(fixAt: south(4000))
        i.destination = nil
        XCTAssertEqual(TripPresenter.panel(i).phase, .needsDestination(canSet: false))
        i.iLead = true
        XCTAssertEqual(TripPresenter.panel(i).phase, .needsDestination(canSet: true))
    }

    // MARK: Live Activity / CarPlay

    func testLiveActivityTripRow() {
        var s = OutingActivityState(liveCount: 2, memberCount: 3, gpsOK: true, online: true, updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertNil(OutingActivityDisplay.make(s, now: s.updatedAt).tripLine)
        s.tripPercent = 62
        s.tripRemainingM = 12_400
        s.tripApprox = true
        var d = OutingActivityDisplay.make(s, now: s.updatedAt)
        XCTAssertEqual(d.tripLine, "قطعنا ٦٢٪ · باقي ١٢٫٤ كم تقريبًا")
        XCTAssertEqual(d.tripShort, "١٢٫٤ كم")
        XCTAssertEqual(d.tripFraction ?? 0, 0.62, accuracy: 1e-9)
        /* An old picture keeps the percent, not the distance. */
        d = OutingActivityDisplay.make(s, now: s.updatedAt.addingTimeInterval(600))
        XCTAssertEqual(d.tripLine, "قطعنا ٦٢٪")
        XCTAssertNil(d.tripShort)
        s.tripArrived = true
        XCTAssertEqual(OutingActivityDisplay.make(s, now: s.updatedAt).tripLine, "وصلنا 🎉")

        /* The builder never passes a remaining distance from a stale fix. */
        var t = TripPanelUI(phase: .underway, destinationName: "x", percent: 40, drivenMeters: 4000, remainingMeters: 6000, remainingSource: .straightLine, canEnd: false)
        var st = s
        st.tripArrived = false
        st.tripPercent = nil
        st.tripRemainingM = nil
        t.myFixStaleSince = Date()
        OutingActivityBuilder.applyTrip(t, to: &st, gpsOK: true)
        XCTAssertEqual(st.tripPercent, 40)
        XCTAssertNil(st.tripRemainingM)
        XCTAssertTrue(OutingActivityThrottle.isUrgent(st, s), "arriving is pushed at once")
    }

    func testCarPlayTripLineAndPin() {
        var i = CarPlayInput()
        i.destination = CarPlayDestination(position: dest, label: "روضة خريم")
        XCTAssertNil(CarPlayPresenter.tripLine(i))
        i.trip = CarPlayTripProgress(percent: 62, remainingM: 12_400, approximate: false, eta: nil, arrived: false)
        XCTAssertEqual(CarPlayPresenter.tripLine(i), "قطعنا ٦٢٪ · باقي \(ArabicFormat.distance(12_400))")
        XCTAssertEqual(CarPlayPresenter.destination(i)?.label, "روضة خريم · ٦٢٪")
        i.trip = CarPlayTripProgress(percent: 100, remainingM: 0, approximate: false, eta: nil, arrived: true)
        XCTAssertEqual(CarPlayPresenter.tripLine(i), "وصلنا الوجهة")
        XCTAssertEqual(CarPlayPresenter.destination(i)?.label, "روضة خريم · وصلنا")
    }
}

/// `StoredBytesMemo`: the stored trip logs are decoded again only when their bytes change.
final class StoredBytesMemoTests: XCTestCase {
    private func count(_ d: Data?) -> Int? { d.map { $0.count } }

    func testSameBytesDecodeOnce() {
        var memo = StoredBytesMemo<Int?>()
        let first: Int? = memo.value(for: Data([1, 2, 3]), decode: count)
        let second: Int? = memo.value(for: Data([1, 2, 3]), decode: { _ in 99 })
        XCTAssertEqual(first, 3)
        XCTAssertEqual(second, 3)
        XCTAssertEqual(memo.decodeCount, 1)
    }

    func testChangedOrMissingBytesDecodeAgain() {
        var memo = StoredBytesMemo<Int?>()
        let one: Int? = memo.value(for: Data([1]), decode: count)
        let two: Int? = memo.value(for: Data([1, 2]), decode: count)
        XCTAssertEqual(one, 1)
        XCTAssertEqual(two, 2)
        /* A nil result is kept too (no log stored for this outing yet). */
        let none: Int? = memo.value(for: nil, decode: count)
        let stillNone: Int? = memo.value(for: nil, decode: { _ in 7 })
        XCTAssertNil(none)
        XCTAssertNil(stillNone)
        XCTAssertEqual(memo.decodeCount, 3)
    }

    func testTripLogFollowsTheStore() {
        let suite = "StoredBytesMemoTests"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        var memo = StoredBytesMemo<TripLog?>()
        func read() -> TripLog? {
            memo.value(for: defaults.data(forKey: TripLogStore.key), decode: { _ in TripLogStore.load("o1", defaults: defaults) })
        }
        XCTAssertNil(read())
        TripLogStore.update("o1", defaults: defaults) { $0.distanceM = 120 }
        XCTAssertEqual(read()?.distanceM, 120)
        XCTAssertEqual(read()?.distanceM, 120)
        XCTAssertEqual(memo.decodeCount, 2)
        TripLogStore.update("o1", defaults: defaults) { $0.distanceM = 300 }
        XCTAssertEqual(read()?.distanceM, 300)
        XCTAssertEqual(memo.decodeCount, 3)
        defaults.removePersistentDomain(forName: suite)
    }
}
