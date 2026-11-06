import CoreLocation
import XCTest
@testable import SaryAlbarq

/// GPS quality (build 21) on simulated traces: a jittery desert drive with spikes, a camp,
/// a walk, a signal gap. Deterministic noise (seeded), so a failure is a real regression.
final class GpsQualityTests: XCTestCase {
    /// Small seeded generator (SplitMix64): the same "random" desert every run.
    struct Noise {
        var state: UInt64
        mutating func next() -> Double {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            return Double(z % 1_000_000) / 1_000_000 * 2 - 1 // −1…1
        }
    }

    static let origin = Geo.LatLng(lat: 24.7113, lng: 46.6744)

    private func fix(_ p: Geo.LatLng, acc: Double = 6, speed: Double? = nil, course: Double? = nil, courseAcc: Double? = nil, at: Double) -> DeviceFix {
        DeviceFix(lat: p.lat, lng: p.lng, accuracy: acc, heading: course, speed: speed, atMs: at, speedAccuracy: 0.5, courseAccuracy: courseAcc)
    }

    private func offset(_ p: Geo.LatLng, east: Double, north: Double) -> Geo.LatLng {
        let n = DisplaySmoother.move(p, meters: north, bearingDeg: 0)
        return DisplaySmoother.move(n, meters: east, bearingDeg: 90)
    }

    // MARK: traces

    /// 120 s heading east at 25 m/s (90 km/h), ±8 m jitter, three 400 m spikes.
    private func desertDrive() -> (fixes: [DeviceFix], truth: [Geo.LatLng], spikes: Set<Int>) {
        var noise = Noise(state: 7)
        var fixes: [DeviceFix] = [], truth: [Geo.LatLng] = []
        let spikes: Set<Int> = [30, 61, 95]
        for i in 0..<120 {
            let t = DisplaySmoother.move(Self.origin, meters: 25 * Double(i), bearingDeg: 90)
            truth.append(t)
            var p = offset(t, east: noise.next() * 8, north: noise.next() * 8)
            if spikes.contains(i) { p = offset(t, east: 0, north: 400) }
            fixes.append(fix(p, acc: 8, speed: 25 + noise.next(), course: 90 + noise.next() * 3, courseAcc: 4, at: Double(i) * 1000))
        }
        return (fixes, truth, spikes)
    }

    /// 10 minutes parked at a camp: ±10 m wander, speed ~0.2 m/s, garbage course.
    private func camp() -> [DeviceFix] {
        var noise = Noise(state: 11)
        return (0..<600).map { i in
            let p = offset(Self.origin, east: noise.next() * 10, north: noise.next() * 10)
            return fix(p, acc: 10, speed: abs(noise.next()) * 0.3, course: (noise.next() + 1) * 180, courseAcc: 120, at: Double(i) * 1000)
        }
    }

    // MARK: gate

    func testDriveSpikesAreRejectedAndEverythingElseKept() {
        let d = desertDrive()
        var gate = FixQualityGate()
        var accepted: [Int] = []
        for (i, f) in d.fixes.enumerated() {
            if case .accept = gate.judge(f, nowMs: f.atMs + 300) { accepted.append(i) }
        }
        XCTAssertEqual(gate.rejected[.teleport], d.spikes.count, "each 400 m spike (≈400 m/s) is a teleport")
        XCTAssertEqual(accepted.count, d.fixes.count - d.spikes.count, "no real fix lost")
        XCTAssertTrue(d.spikes.isDisjoint(with: accepted))
    }

    func testInvalidStaleAndCoarseFixes() {
        var gate = FixQualityGate()
        let now = 100_000.0
        XCTAssertEqual(gate.judge(fix(Self.origin, acc: -1, at: now), nowMs: now), .reject(.invalid))
        var nav = FixQualityGate(keepsFirstStale: false)
        XCTAssertEqual(nav.judge(fix(Self.origin, at: now - 30_000), nowMs: now), .reject(.stale), "guidance never steers from an old fix")
        guard case .accept = gate.judge(fix(Self.origin, at: now - 30_000), nowMs: now) else { return XCTFail("the first fix is kept, however old") }
        XCTAssertEqual(gate.judge(fix(Self.origin, at: now - 11_000), nowMs: now), .reject(.stale), "older than 10 s")
        guard case .accept = gate.judge(fix(Self.origin, acc: 5, at: now), nowMs: now) else { return XCTFail() }
        XCTAssertEqual(gate.judge(fix(Self.origin, acc: 120, at: now + 1000), nowMs: now + 1000), .reject(.coarse), "a better fix is recent")
        XCTAssertEqual(gate.judge(fix(Self.origin, at: now - 500), nowMs: now + 1000), .reject(.stale), "out of order")
        /* No good fix for 15 s: a coarse one is better than nothing (and honest about its accuracy). */
        guard case .accept = gate.judge(fix(Self.origin, acc: 120, at: now + 16_000), nowMs: now + 16_000) else { return XCTFail() }
        gate.countInvalid()
        XCTAssertEqual(gate.rejected[.invalid], 2)
    }

    func testRealJumpIsConfirmedByTheNextFix() {
        /* The reference itself was wrong (a multipath fix accepted first): the next two agree, so believe them. */
        var gate = FixQualityGate()
        _ = gate.judge(fix(offset(Self.origin, east: 0, north: 2_000), acc: 5, at: 0), nowMs: 0)
        XCTAssertEqual(gate.judge(fix(Self.origin, acc: 5, at: 1000), nowMs: 1000), .reject(.teleport))
        guard case .accept = gate.judge(fix(offset(Self.origin, east: 10, north: 0), acc: 5, at: 2000), nowMs: 2000) else {
            return XCTFail("two agreeing fixes re-anchor the gate")
        }
    }

    func testSignalGapStartsAfresh() {
        /* 3 minutes without signal, then 3 km further on: not a teleport (≈17 m/s), and after 30 s no judgement anyway. */
        var gate = FixQualityGate()
        var s = DisplaySmoother()
        let a = fix(Self.origin, acc: 6, speed: 20, course: 90, courseAcc: 5, at: 0)
        guard case let .accept(ok) = gate.judge(a, nowMs: 0) else { return XCTFail() }
        _ = s.update(ok)
        let far = DisplaySmoother.move(Self.origin, meters: 3_000, bearingDeg: 90)
        let b = fix(far, acc: 6, speed: 20, course: 90, courseAcc: 5, at: 180_000)
        guard case let .accept(ok2) = gate.judge(b, nowMs: 180_200) else { return XCTFail("a gap is not a teleport") }
        let shown = s.update(ok2)
        XCTAssertLessThan(Geo.haversineMeters(shown.coordinate, far), 0.01, "after a gap the dot goes straight to the new fix")
        XCTAssertEqual(gate.rejected.values.reduce(0, +), 0)
    }

    // MARK: display

    func testDriveIsSmoothedWithoutLag() {
        let d = desertDrive()
        var gate = FixQualityGate()
        var s = DisplaySmoother()
        var rawErr = 0.0, shownErr = 0.0, n = 0.0, worst = 0.0
        for (i, f) in d.fixes.enumerated() {
            guard case let .accept(ok) = gate.judge(f, nowMs: f.atMs + 300) else { continue }
            let shown = s.update(ok)
            guard i > 5 else { continue }
            rawErr += Geo.haversineMeters(ok.coordinate, d.truth[i])
            let e = Geo.haversineMeters(shown.coordinate, d.truth[i])
            shownErr += e
            worst = max(worst, e)
            n += 1
            XCTAssertEqual(shown.heading ?? -1, ok.heading ?? -2, accuracy: 1e-9, "moving fast, good courseAccuracy: the course")
        }
        XCTAssertLessThan(shownErr / n, rawErr / n, "smoothing beats the raw jitter")
        XCTAssertLessThan(worst, 15, "never trails behind at 90 km/h")
    }

    func testCampDoesNotWander() {
        var gate = FixQualityGate()
        var s = DisplaySmoother()
        var shown: [Geo.LatLng] = [], raw: [Geo.LatLng] = []
        for f in camp() {
            guard case let .accept(ok) = gate.judge(f, nowMs: f.atMs + 200) else { continue }
            let out = s.update(ok)
            XCTAssertNil(out.heading, "a parked car gets no arrow")
            raw.append(ok.coordinate)
            shown.append(out.coordinate)
        }
        func path(_ p: [Geo.LatLng]) -> Double { zip(p, p.dropFirst()).map { Geo.haversineMeters($0, $1) }.reduce(0, +) }
        XCTAssertGreaterThan(path(raw), 2_000, "the raw dot wanders kilometres in ten minutes")
        XCTAssertLessThan(path(shown), 30, "the shown dot stays put")
        XCTAssertLessThan(Geo.haversineMeters(shown.last!, Self.origin), 3, "and sits on the true spot")
        XCTAssertTrue(s.parked)
    }

    func testLeavingCampMovesTheDot() {
        var s = DisplaySmoother()
        for f in camp().prefix(60) { _ = s.update(f) }
        /* Pull away: 2 m/s, then 6 m/s, north. */
        var last = Self.origin
        for i in 1...10 {
            last = DisplaySmoother.move(Self.origin, meters: Double(i) * 6, bearingDeg: 0)
            _ = s.update(fix(last, acc: 5, speed: i < 3 ? 2 : 6, course: 0, courseAcc: 8, at: 60_000 + Double(i) * 1000))
        }
        XCTAssertFalse(s.parked)
        XCTAssertLessThan(Geo.haversineMeters(s.out!.coordinate, last), 8)
    }

    func testWalkingKeepsUpAndUsesNoCourse() {
        /* Walking 1.3 m/s around the camp: smoothed, the dot follows, no course (compass territory). */
        var s = DisplaySmoother()
        var noise = Noise(state: 3)
        var worst = 0.0
        for i in 0..<120 {
            let t = DisplaySmoother.move(Self.origin, meters: 1.3 * Double(i), bearingDeg: 45)
            let p = offset(t, east: noise.next() * 3, north: noise.next() * 3)
            let out = s.update(fix(p, acc: 5, speed: 1.3, course: 45 + noise.next() * 40, courseAcc: 40, at: Double(i) * 1000))
            XCTAssertNil(out.heading)
            if i > 10 { worst = max(worst, Geo.haversineMeters(out.coordinate, t)) }
        }
        XCTAssertLessThan(worst, 10)
        var m = MotionClass.parked
        m = MotionClass.next(m, speedMps: 1.3)
        XCTAssertEqual(m, .walking)
    }

    // MARK: heading

    func testHeadingChoice() {
        XCTAssertEqual(HeadingChooser.course(fix(Self.origin, speed: 10, course: 270, courseAcc: 5, at: 0)), 270)
        XCTAssertNil(HeadingChooser.course(fix(Self.origin, speed: 10, course: 270, courseAcc: 60, at: 0)), "a poor course is not a direction")
        XCTAssertNil(HeadingChooser.course(fix(Self.origin, speed: 1.5, course: 270, courseAcc: 5, at: 0)), "too slow")
        XCTAssertNil(HeadingChooser.course(fix(Self.origin, speed: 2.7, course: 270, at: 0)), "unknown accuracy needs ≥3 m/s")
        XCTAssertEqual(HeadingChooser.course(fix(Self.origin, speed: 3.5, course: 270, at: 0)), 270)
        let slow = fix(Self.origin, speed: 1, course: 10, courseAcc: 5, at: 0)
        XCTAssertEqual(HeadingChooser.choose(slow, compass: 200, compassError: 10).source, .compass)
        XCTAssertEqual(HeadingChooser.choose(slow, compass: 200, compassError: 10).heading, 200)
        XCTAssertEqual(HeadingChooser.choose(slow, compass: 200, compassError: 90).source, .none, "a bad compass is no better")
        XCTAssertEqual(HeadingChooser.choose(fix(Self.origin, speed: 20, course: 90, courseAcc: 3, at: 0), compass: 200, compassError: 5).source, .course)
    }

    func testFollowHeadingIgnoresAPoorCourse() {
        var h = FollowHeadingSource()
        XCTAssertEqual(h.update(speedKmh: 30, course: 90, compass: 200, compassError: 5, courseAccuracy: 90), 200, "a 90° course error: compass")
        XCTAssertEqual(h.update(speedKmh: 30, course: 90, compass: 200, compassError: 5, courseAccuracy: 5), 90)
    }

    // MARK: motion & settings

    func testMotionHysteresis() {
        var m = MotionClass.parked
        for (v, want) in [(0.3, MotionClass.parked), (1.0, .walking), (3.5, .driving), (2.7, .driving), (2.3, .walking),
                          (nil as Double?, .walking), (30, .fast), (22, .fast), (19, .driving), (0, .parked)] {
            m = MotionClass.next(m, speedMps: v)
            XCTAssertEqual(m, want, "\(String(describing: v))")
        }
    }

    func testPlanPerMode() {
        var n = LocationTuning.Need()
        XCTAssertNil(LocationTuning.plan(n), "nothing asks: GPS off")
        n.watching = true
        XCTAssertEqual(LocationTuning.plan(n)?.desiredAccuracy, kCLLocationAccuracyNearestTenMeters)
        n.sharing = true
        n.motion = .fast; n.speedMps = 30; n.mode = .precise
        XCTAssertEqual(LocationTuning.plan(n), .init(desiredAccuracy: kCLLocationAccuracyBestForNavigation, distanceFilter: kCLDistanceFilterNone, activityType: .otherNavigation))
        n.motion = .walking; n.speedMps = 1.2; n.mode = .balanced
        XCTAssertEqual(LocationTuning.plan(n)?.activityType, .fitness, "on foot: the pedestrian model")
        n.offScreen = true; n.backgroundShare = true
        n.motion = .parked; n.speedMps = nil
        XCTAssertEqual(LocationTuning.plan(n), .init(desiredAccuracy: kCLLocationAccuracyHundredMeters, distanceFilter: kCLDistanceFilterNone, activityType: .otherNavigation),
                       "locked at camp: coarse but still fixes, so the heartbeat stays fresh")
        n.motion = .driving; n.speedMps = 8
        XCTAssertEqual(LocationTuning.plan(n)?.distanceFilter, kCLDistanceFilterNone, "a car that stops must still get fixes")
        n.trail = true; n.onRoad = true
        XCTAssertEqual(LocationTuning.plan(n), .init(desiredAccuracy: kCLLocationAccuracyBestForNavigation, distanceFilter: kCLDistanceFilterNone, activityType: .automotiveNavigation))
        n.onRoad = false
        XCTAssertEqual(LocationTuning.plan(n)?.activityType, .otherNavigation, "dunes: no road snapping")
        XCTAssertEqual(LocationTuning.describe(LocationTuning.plan(n)), "nav · none · otherNav")
    }

    func testBackgroundCadenceStaysInsideTheLiveWindow() {
        for m in [BackgroundCadence.Motion.fast, .moving] {
            XCTAssertLessThan(BackgroundCadence.intervalMs(m, lowPower: false), Policy.liveMovingMs, "moving: a send before others see me stale")
        }
        XCTAssertLessThan(BackgroundCadence.intervalMs(.parked, lowPower: false), Policy.liveParkedMs)
        for m in [BackgroundCadence.Motion.fast, .moving, .parked] {
            XCTAssertEqual(BackgroundCadence.accuracy(m).distanceFilter, kCLDistanceFilterNone)
        }
    }

    // MARK: the sharer end to end (no CoreLocation)

    @MainActor
    func testSharerKeepsRawForSOSAndSmoothsTheDisplay() {
        let loc = LocationSharer()
        var trail: [DeviceFix] = []
        loc.onTrailFix = { trail.append($0) }
        let c = camp().prefix(120)
        for f in c { loc.ingest(f, nowMs: f.atMs + 200) }
        XCTAssertEqual(loc.quality.hz, 1, accuracy: 0.05)
        loc.ingest(nil, nowMs: 121_000)
        let spike = fix(offset(Self.origin, east: 0, north: 3_000), acc: 5, speed: 0.1, at: 121_500)
        loc.ingest(spike, nowMs: 121_600)
        XCTAssertEqual(loc.lastFix, c.last, "lastFix is the raw fix, untouched (SOS)")
        XCTAssertNotEqual(loc.displayFix?.coordinate, c.last?.coordinate, "the display is smoothed")
        XCTAssertEqual(loc.displayFix?.atMs, c.last?.atMs)
        XCTAssertEqual(trail.count, 120, "the spike never reaches the trail")
        XCTAssertEqual(loc.quality.rejected[.teleport], 1)
        XCTAssertEqual(loc.quality.rejected[.invalid], 1)
        XCTAssertEqual(loc.quality.accepted, 120)
        XCTAssertEqual(loc.quality.lines.count, 4)
    }

    // MARK: the «live» label never lies

    func testSharingLabelNeedsAFreshFix() {
        var i = LivePresenterInput()
        i.view = nil
        i.isSharingNow = true
        i.now = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(LiveOutingPresenter.sharing(i), .starting, "no fix: locating, not «مُشارَك»")
        i.myFix = fix(Self.origin, at: 999_000)
        XCTAssertEqual(LiveOutingPresenter.sharing(i), .sharing)
        i.myFix = fix(Self.origin, at: 1_000_000 - LiveOutingPresenter.myLiveMaxAgeMs - 1)
        XCTAssertEqual(LiveOutingPresenter.sharing(i), .starting, "a stale fix is not shown as live")
    }
}
