import XCTest
@testable import SaryAlbarq

/// Build 10 «دقة المسار»: the drawn line (outliers, simplification), the speed gradient,
/// the three big numbers, and «اسلك هذا المسار» (along-track projection, remaining distance,
/// deviation hysteresis, reverse).
private enum G {
    static let ref = LngLat(lng: 46.30, lat: 24.60)
    static let t0 = 1_800_000_000_000.0
    /// A point `n` metres north and `e` metres east of the reference.
    static func p(_ n: Double, _ e: Double = 0) -> LngLat { TrailGeo.lngLat(e, n, ref: ref) }
    static func raw(_ n: Double, _ e: Double = 0, t: Double, acc: Double = 5, spd: Double? = nil, spdAcc: Double? = 0.5) -> RawFix {
        let q = p(n, e)
        return RawFix(t: t0 + t * 1000, lat: q.lat, lng: q.lng, acc: acc, spd: spd, crs: nil, spdAcc: spd == nil ? nil : spdAcc)
    }
    static func tp(_ n: Double, _ e: Double = 0, t: Double, gap: Bool = false) -> TrailPoint {
        let q = p(n, e)
        return TrailPoint(lat: q.lat, lng: q.lng, t: t0 + t * 1000, gap: gap)
    }
}

final class TrackDisplayTests: XCTestCase {
    func testRejectsInaccurateFixes() {
        let raw = [G.raw(0, t: 0), G.raw(10, t: 1, acc: 26), G.raw(20, t: 2, acc: 25), G.raw(30, t: 3, acc: -1)]
        let kept = TrackDisplay.rejectOutliers(raw)
        XCTAssertEqual(kept.count, 2, "only accuracy ≤ 25 m shapes the line")
        XCTAssertEqual(kept.map(\.t), [G.t0, G.t0 + 2000])
    }

    func testRejectsImpliedSpeedJumps() {
        /* 10 m/s, then a 500 m jump in one second (500 m/s), then back on the line. */
        let raw = [G.raw(0, t: 0), G.raw(10, t: 1), G.raw(510, t: 2), G.raw(30, t: 3), G.raw(40, t: 4)]
        let kept = TrackDisplay.rejectOutliers(raw)
        XCTAssertFalse(kept.contains { abs($0.t - (G.t0 + 2000)) < 1 }, "the jump is out")
        XCTAssertEqual(kept.count, 4)
    }

    func testJumpRuleEdge() {
        XCTAssertTrue(TrackDisplay.plausible(G.p(0), 0, G.p(69.9), 1000))
        XCTAssertFalse(TrackDisplay.plausible(G.p(0), 0, G.p(70.5), 1000))
    }

    func testRejoinsWhenTheKeptFixWasTheOddOne() {
        /* The first fix is 900 m off; the next ones agree with each other: they win. */
        var raw = [G.raw(900, t: 0)]
        for i in 1...6 { raw.append(G.raw(Double(i) * 10, t: Double(i))) }
        let kept = TrackDisplay.rejectOutliers(raw)
        XCTAssertGreaterThanOrEqual(kept.count, 1 + TrackDisplay.rejoinAfter)
    }

    func testSimplificationRemovesZigZagNoiseButKeepsTurns() {
        /* 1 km north with ±1 m jitter, then a right-angle turn 300 m east. */
        var pts: [TrailPoint] = []
        for i in 0...100 { pts.append(G.tp(Double(i) * 10, i % 2 == 0 ? 1 : -1, t: Double(i))) }
        for i in 1...30 { pts.append(G.tp(1000, Double(i) * 10, t: 100 + Double(i))) }
        let line = TrackDisplay.line(trail: pts)
        XCTAssertLessThan(line.points.count, 10, "the jitter is gone")
        XCTAssertTrue(line.points.contains { Vehicle.distanceMeters($0, G.p(1000, 0)) < 3 }, "the corner stays")
        XCTAssertEqual(line.lengthM, 1300, accuracy: 6)
    }

    func testStoredTrailIsNeverChanged() {
        let pts = (0...50).map { G.tp(Double($0) * 10, $0 % 2 == 0 ? 1.5 : -1.5, t: Double($0)) }
        var trail = Trail()
        trail.points = pts
        let before = trail
        _ = TrackDisplay.line(trail: trail.points)
        XCTAssertEqual(trail, before)
    }

    func testGapsAreKeptAsGaps() {
        let pts = [G.tp(0, t: 0), G.tp(100, t: 10), G.tp(1100, t: 400, gap: true), G.tp(1200, t: 410)]
        let line = TrackDisplay.line(trail: pts)
        XCTAssertEqual(line.gaps, [false, true, false])
        XCTAssertNil(line.speeds[1], "an unrecorded stretch has no speed")
        XCTAssertEqual(line.lengthM, 200, accuracy: 1)
        XCTAssertEqual(line.runs.solid.count, 2)
        XCTAssertEqual(line.runs.gaps.count, 1)
    }

    func testSpeedsFromRawFixesWithGoodAccuracyOnly() {
        let pts = [G.tp(0, t: 0), G.tp(100, t: 10), G.tp(100, 300, t: 20)]
        let raw = [G.raw(50, t: 5, spd: 10), G.raw(100, 150, t: 15, spd: 30), G.raw(100, 200, t: 16, spd: 99, spdAcc: 5)]
        var line = TrackDisplay.line(trail: pts, raw: raw)
        XCTAssertEqual(line.speeds.count, 2)
        /* Smoothed over the run: the mean of the two good ones; the 5 m/s-accuracy reading is ignored. */
        XCTAssertEqual(line.speeds[0]!, 20, accuracy: 0.01)
        line = TrackDisplay.line(trail: pts)
        XCTAssertEqual(line.speeds[0]!, 20, accuracy: 0.01, "without raw: distance ÷ time, smoothed")
    }

    func testNoTimesNoSpeeds() {
        let line = TrackDisplay.line(plain: [G.p(0), G.p(500), G.p(500, 500)])
        XCTAssertFalse(line.hasSpeeds)
        XCTAssertNil(TrackGradient.stops(line), "GPX without speeds: one colour")
    }

    func testRawLineEndToEnd() {
        var raw: [RawFix] = []
        for i in 0...200 { raw.append(G.raw(Double(i) * 12, i % 3 == 0 ? 2 : 0, t: Double(i), spd: 12)) }
        raw.append(G.raw(9_000, t: 100.5, spd: 12))
        let line = TrackDisplay.line(raw: raw)
        XCTAssertTrue(line.isDrawable)
        XCTAssertLessThan(line.points.count, 60)
        XCTAssertEqual(line.lengthM, 2400, accuracy: 40)
        XCTAssertTrue(line.hasSpeeds)
    }
}

final class TrackGradientTests: XCTestCase {
    func testRampSlowLightFastDeep() {
        func lum(_ c: UInt32) -> Double { SaryContrast.luminance(c) }
        XCTAssertGreaterThan(lum(TrackGradient.rgb(kmh: 5)), lum(TrackGradient.rgb(kmh: 50)))
        XCTAssertGreaterThan(lum(TrackGradient.rgb(kmh: 50)), lum(TrackGradient.rgb(kmh: 120)))
        XCTAssertEqual(TrackGradient.rgb(kmh: -3), TrackGradient.ramp[0].rgb)
        XCTAssertEqual(TrackGradient.rgb(kmh: 999), TrackGradient.ramp.last!.rgb)
    }

    func testProgressIsMonotonicAndNormalised() {
        let p = TrackGradient.progress([G.p(0), G.p(100), G.p(100, 300), G.p(400, 300)])
        XCTAssertEqual(p.first, 0)
        XCTAssertEqual(p.last!, 1, accuracy: 1e-12)
        XCTAssertEqual(p, p.sorted())
        XCTAssertEqual(p[1], 100.0 / 700, accuracy: 0.002)
    }

    func testStopsStrictlyIncreasingWithSpeedColours() {
        let line = TrackLine(points: [G.p(0), G.p(100), G.p(200), G.p(300)], speeds: [2, 15, 30], gaps: [false, false, false])
        let s = TrackGradient.stops(line)!
        XCTAssertEqual(s.first?.at, 0)
        XCTAssertEqual(s.last!.at, 1, accuracy: 1e-9)
        for i in s.indices.dropFirst() { XCTAssertGreaterThan(s[i].at, s[i - 1].at) }
        XCTAssertEqual(s.first?.color, TrackGradient.hex(kmh: Speed.kmh(2)))
        XCTAssertEqual(s.last?.color, TrackGradient.hex(kmh: Speed.kmh(30)))
        let e = TrackGradient.expression(s)
        XCTAssertEqual(e.count, 3 + s.count * 2)
        XCTAssertEqual(e[0] as? String, "interpolate")
    }

    func testGapsAreTransparentWithHardEdges() {
        /* East–west: Mercator progress is exactly linear in longitude. */
        let line = TrackLine(points: [G.p(0, 0), G.p(0, 100), G.p(0, 200), G.p(0, 300)], speeds: [10, nil, 10], gaps: [false, true, false])
        let s = TrackGradient.stops(line)!
        let clear = s.filter { $0.color == TrackGradient.transparent }
        XCTAssertEqual(clear.count, 2)
        XCTAssertEqual(clear[0].at, 1.0 / 3, accuracy: 1e-4)
        XCTAssertEqual(clear[1].at, 2.0 / 3, accuracy: 1e-4)
        /* Coloured right up to the edge on both sides. */
        XCTAssertTrue(s.contains { abs($0.at - 1.0 / 3) < 1e-9 && $0.color != TrackGradient.transparent })
        XCTAssertTrue(s.contains { abs($0.at - 2.0 / 3) < 1e-9 && $0.color != TrackGradient.transparent })
    }

    func testEqualColoursMergeAndLongLinesThin() {
        let n = 2000
        let pts = (0...n).map { G.p(Double($0) * 10) }
        let same = TrackLine(points: pts, speeds: Array(repeating: 10, count: n), gaps: Array(repeating: false, count: n))
        XCTAssertEqual(TrackGradient.stops(same)?.count, 2, "one colour: just the two ends")
        let varied = TrackLine(points: pts, speeds: (0..<n).map { Double($0 % 40) }, gaps: Array(repeating: false, count: n))
        let s = TrackGradient.stops(varied)!
        XCTAssertLessThanOrEqual(s.count, TrackGradient.maxStops)
        for i in s.indices.dropFirst() { XCTAssertGreaterThan(s[i].at, s[i - 1].at) }
    }

    func testUnknownSpeedInsideARunBorrowsANeighbourNotInvented() {
        let line = TrackLine(points: [G.p(0), G.p(100), G.p(200)], speeds: [nil, 20], gaps: [false, false])
        let s = TrackGradient.stops(line)!
        XCTAssertEqual(Set(s.map(\.color)), [TrackGradient.hex(kmh: Speed.kmh(20))])
    }
}

final class TrackStatsTests: XCTestCase {
    func testDistanceMaxSpeedMovingTime() {
        var raw: [RawFix] = []
        /* 60 s at 10 m/s, 120 s parked, 30 s at 20 m/s; one 40 m/s spike with good accuracy. */
        for i in 0...60 { raw.append(G.raw(Double(i) * 10, t: Double(i), spd: 10)) }
        for i in 61...180 { raw.append(G.raw(600, t: Double(i), spd: 0)) }
        for i in 1...30 { raw.append(G.raw(600 + Double(i) * 20, t: 180 + Double(i), spd: i == 15 ? 40 : 20)) }
        let line = TrackDisplay.line(raw: raw)
        let s = TrackStats.make(raw: raw, line: line)
        XCTAssertEqual(s.distanceM, 1200, accuracy: 30)
        XCTAssertEqual(s.maxKmh!, 72, accuracy: 0.5, "a single spike is not the top speed")
        XCTAssertEqual(Double(s.movingS!), 90, accuracy: 3)
        XCTAssertEqual(s.movingText, "٠٠:٠١")
    }

    func testMaxSpeedNeedsGoodSpeedAccuracy() {
        let raw = (0...20).map { G.raw(Double($0) * 15, t: Double($0), spd: 15, spdAcc: 4) }
        let s = TrackStats.make(raw: raw, line: TrackDisplay.line(raw: raw))
        XCTAssertNil(s.maxKmh, "never a number we cannot stand behind")
        XCTAssertEqual(s.maxSpeedText, "—")
    }

    func testPointsOnlyAndPlain() {
        let pts = (0...10).map { G.tp(Double($0) * 100, t: Double($0) * 10) }
        let s = TrackStats.make(points: pts, line: TrackDisplay.line(trail: pts))
        XCTAssertNil(s.maxKmh)
        XCTAssertEqual(s.movingS, 100)
        let g = TrackStats.make(plain: TrackDisplay.line(plain: [G.p(0), G.p(13_300)]))
        XCTAssertEqual(g.distanceText, "١٣٫٣")
        XCTAssertNil(g.movingS)
        XCTAssertEqual(g.movingText, "—")
    }

    func testClockFormat() {
        XCTAssertEqual(TrackStats.hhmm(2 * 3600 + 44 * 60 + 59), "٠٢:٤٤")
        XCTAssertEqual(TrackStats.hhmm(0), "٠٠:٠٠")
        XCTAssertEqual(TrackStats(distanceM: 0, maxKmh: 60.4, movingS: nil).maxSpeedText, "٦٠")
    }
}

final class TrackFollowTests: XCTestCase {
    /// 1 km north, then 1 km east.
    let pts = [G.p(0), G.p(1000), G.p(1000, 1000)]

    func testProjectionAndRemainingAlongTheTrack() {
        var f = TrackFollow(points: pts)!
        XCTAssertEqual(f.totalM, 2000, accuracy: 1)
        let s = f.update(G.p(400, 20))
        XCTAssertEqual(s.alongM, 400, accuracy: 1)
        XCTAssertEqual(s.remainingM, 1600, accuracy: 1)
        XCTAssertEqual(s.offsetM, 20, accuracy: 0.5)
        XCTAssertEqual(s.progress, 0.2, accuracy: 0.001)
        XCTAssertEqual(Vehicle.distanceMeters(s.snapped, G.p(400)), 0, accuracy: 0.5, "snapped to the track, not a road")
        XCTAssertFalse(s.offTrack)
        XCTAssertFalse(s.far)
        let t = f.update(G.p(1010, 600))
        XCTAssertEqual(t.remainingM, 400, accuracy: 1)
    }

    func testArrival() {
        var f = TrackFollow(points: pts)!
        _ = f.update(G.p(900))
        let s = f.update(G.p(1000, 985))
        XCTAssertTrue(s.arrived)
        XCTAssertEqual(s.remainingM, 0)
        XCTAssertEqual(s.progress, 1)
    }

    func testDeviationNeedsFiftyMetresForTenSeconds() {
        var f = TrackFollow(points: pts)!
        var dev = FollowDeviation()
        let t0 = G.t0
        _ = f.update(G.p(100), atMs: t0)
        var s = f.update(G.p(200, 60), atMs: t0 + 1000)
        XCTAssertFalse(s.offTrack, "not yet: the warning waits")
        XCTAssertEqual(dev.ingest(s), .none)
        s = f.update(G.p(205, 60), atMs: t0 + 9_000)
        XCTAssertFalse(s.offTrack)
        s = f.update(G.p(210, 60), atMs: t0 + 11_500)
        XCTAssertTrue(s.offTrack)
        guard case let .raise(m) = dev.ingest(s) else { return XCTFail("one alert") }
        XCTAssertEqual(m, 60, accuracy: 1)
        s = f.update(G.p(215, 45), atMs: t0 + 12_500)
        XCTAssertTrue(s.offTrack, "hysteresis: still out until inside 30 m")
        XCTAssertEqual(dev.ingest(s), .none, "only one alert at a time")
        s = f.update(G.p(220, 25), atMs: t0 + 13_500)
        XCTAssertFalse(s.offTrack)
        XCTAssertEqual(dev.ingest(s), .clear)
    }

    func testShortExcursionResetsTheHold() {
        var f = TrackFollow(points: pts)!
        let t0 = G.t0
        _ = f.update(G.p(100, 60), atMs: t0)
        _ = f.update(G.p(110, 10), atMs: t0 + 6_000)
        let s = f.update(G.p(120, 60), atMs: t0 + 12_000)
        XCTAssertFalse(s.offTrack, "the clock restarted when I came back")
    }

    func testUnsureGPSNeverWarns() {
        var f = TrackFollow(points: pts)!
        _ = f.update(G.p(100, 70), accuracy: 80, atMs: G.t0)
        let s = f.update(G.p(100, 70), accuracy: 80, atMs: G.t0 + 20_000)
        XCTAssertFalse(s.offTrack)
    }

    func testFarOffersApproach() {
        var f = TrackFollow(points: pts)!
        let s = f.update(G.p(-3000, -500))
        XCTAssertTrue(s.far)
        let n = f.nearestPoint(to: G.p(-3000, -500))
        XCTAssertEqual(Vehicle.distanceMeters(n.point, G.p(0)), 0, accuracy: 1)
        XCTAssertEqual(n.alongM, 0, accuracy: 1)
    }

    func testReverseFollowsBackwards() {
        let f = TrackFollow(points: pts, gaps: [false, true])!
        var r = f.reversedFollow()!
        XCTAssertTrue(r.reversed)
        XCTAssertEqual(r.startPoint, pts[2])
        XCTAssertEqual(r.endPoint, pts[0])
        XCTAssertEqual(r.gaps, [true, false])
        let s = r.update(G.p(1000, 900))
        XCTAssertEqual(s.alongM, 100, accuracy: 1)
        XCTAssertEqual(s.remainingM, 1900, accuracy: 1)
        XCTAssertTrue(s.onGap)
        XCTAssertEqual(r.reversedFollow()!.path, f.path, "twice is the original direction")
    }

    func testCursorDoesNotJumpToAnotherPassOfALoop() {
        /* Out 500 m north and back 20 m to the east: two parallel passes. */
        let loop = [G.p(0), G.p(500), G.p(500, 20), G.p(0, 20)]
        var f = TrackFollow(points: loop)!
        _ = f.update(G.p(50, 2))
        _ = f.update(G.p(150, 4))
        let s = f.update(G.p(250, 9))
        XCTAssertLessThan(s.alongM, 300, "still on the way out, not the way back")
    }

    func testRejectsDegenerateTracks() {
        XCTAssertNil(TrackFollow(points: [G.p(0)]))
        XCTAssertNil(TrackFollow(points: [G.p(0), G.p(0)]))
        XCTAssertNil(TrackFollow(points: pts, gaps: [false]))
    }
}
