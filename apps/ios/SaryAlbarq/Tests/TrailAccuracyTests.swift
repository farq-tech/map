import CoreLocation
import XCTest
@testable import SaryAlbarq

// «مساري» accuracy (TestFlight build 4 bug): a real Riyadh drive (al-Rabie, the street
// geometry from Mapbox Directions in Fixtures/riyadh-rabie-drive.json) replayed as 1 Hz
// fixes with GPS noise, tunnels / dropouts, 30–80 m accuracy bursts and urban-canyon jumps.

/// A deterministic random source (tests must not flake).
struct SeededRandom {
    var state: UInt64
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / Double(1 << 53)
    }
    /// Standard normal (Box–Muller).
    mutating func gauss() -> Double {
        let u = max(next(), 1e-12), v = next()
        return (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
    }
}

enum RiyadhDrive {
    static let t0 = 1_800_000_000_000.0

    static func route() throws -> [LngLat] {
        let url = try XCTUnwrap(Bundle(for: TrailKalmanTests.self).url(forResource: "riyadh-rabie-drive", withExtension: "json"))
        let o = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let c = try XCTUnwrap(o["coordinates"] as? [[Double]])
        return c.map { LngLat(lng: $0[0], lat: $0[1]) }
    }

    /// The true position every second, driving the route at `speed` m/s, slowing to 5 m/s near corners.
    static func truth(_ route: [LngLat], speed: Double = 13) -> [(t: Double, p: LngLat, v: Double, course: Double)] {
        var out: [(Double, LngLat, Double, Double)] = []
        var seg = 0, u = 0.0, t = t0
        out.append((t, route[0], 0, Vehicle.bearing(route[0], route[1])))
        while seg < route.count - 1 {
            let a = route[seg], b = route[seg + 1]
            let len = Vehicle.distanceMeters(a, b)
            /* Slower on the short segments (corners, roundabouts). */
            var v = len < 25 ? 5.0 : speed
            var step = v
            while step > 0, seg < route.count - 1 {
                let a2 = route[seg], b2 = route[seg + 1]
                let l2 = max(Vehicle.distanceMeters(a2, b2), 0.001)
                let left = l2 * (1 - u)
                if step < left { u += step / l2; step = 0 } else { step -= left; seg += 1; u = 0 }
            }
            guard seg < route.count - 1 else { break }
            let a3 = route[seg], b3 = route[seg + 1]
            let p = LngLat(lng: a3.lng + (b3.lng - a3.lng) * u, lat: a3.lat + (b3.lat - a3.lat) * u)
            t += 1000
            v = min(v, speed)
            out.append((t, p, v, Vehicle.bearing(a3, b3)))
            _ = len
        }
        return out.map { (t: $0.0, p: $0.1, v: $0.2, course: $0.3) }
    }

    enum Event { case burst(Range<Int>, acc: Double), canyon(Int, offsetM: Double), dropout(Range<Int>) }

    /// GPS as an iPhone in a car reports it.
    static func fixes(_ truth: [(t: Double, p: LngLat, v: Double, course: Double)], events: [Event], seed: UInt64 = 7) -> [RawFix] {
        var r = SeededRandom(state: seed)
        var out: [RawFix] = []
        for (i, s) in truth.enumerated() {
            if events.contains(where: { if case let .dropout(rg) = $0 { return rg.contains(i) }; return false }) { continue }
            var acc = 5 + r.next() * 5
            for e in events { if case let .burst(rg, a) = e, rg.contains(i) { acc = a } }
            /* Reported accuracy is roughly 1σ radius: per-axis noise a bit under it. */
            let sig = acc * 0.6
            var x = r.gauss() * sig, y = r.gauss() * sig
            var reportedAcc = acc
            for e in events {
                if case let .canyon(k, off) = e, k == i {
                    /* A multipath jump: far off, yet iOS claims it is fairly good. */
                    x = off; y = off * 0.4
                    reportedAcc = 25
                }
            }
            let q = TrailGeo.lngLat(x, y, ref: s.p)
            out.append(RawFix(t: s.t, lat: q.lat, lng: q.lng, acc: reportedAcc,
                              spd: max(0, s.v + r.gauss() * 0.5), crs: s.v > 2 ? (s.course + r.gauss() * 4).truncatingRemainder(dividingBy: 360) : nil, spdAcc: 0.8))
        }
        return out
    }

    /// Distance from p to the polyline.
    static func offset(_ p: LngLat, _ line: [LngLat]) -> Double {
        var best = Double.infinity
        for i in 0..<(line.count - 1) { best = min(best, TrailGeo.segmentDistance(p, line[i], line[i + 1])) }
        return best
    }

    static func percentile(_ xs: [Double], _ q: Double) -> Double {
        let s = xs.sorted()
        return s[min(s.count - 1, Int(Double(s.count - 1) * q))]
    }
}

final class TrailKalmanTests: XCTestCase {
    func testCleanDriveHasNoGapsAndHugsTheStreets() throws {
        let route = try RiyadhDrive.route()
        let truth = RiyadhDrive.truth(route)
        XCTAssertGreaterThan(truth.count, 600, "a real ~11 km drive")
        let tr = Trail.rebuild(RiyadhDrive.fixes(truth, events: []))
        XCTAssertEqual(tr.gapCount, 0, "fixes every second: never a dashed stretch")
        let offs = tr.points.map { RiyadhDrive.offset($0.position, route) }
        XCTAssertLessThan(RiyadhDrive.percentile(offs, 0.95), 8)
        XCTAssertGreaterThan(tr.recordedLengthM, 9_500)
    }

    /// The build-4 drive: bursts of 30–80 m accuracy (the old 30 m gate dropped them all), urban-canyon
    /// jumps (the old jump rule turned them into dashed straight lines), short tunnels/dropouts.
    func testNoisyCityDriveStaysOnTheRoadWithoutFalseGaps() throws {
        let route = try RiyadhDrive.route()
        let truth = RiyadhDrive.truth(route)
        let events: [RiyadhDrive.Event] = [
            .burst(40..<70, acc: 45), .burst(150..<190, acc: 80), .burst(300..<330, acc: 35),
            .canyon(100, offsetM: 220), .canyon(101, offsetM: 230), .canyon(260, offsetM: -180), .canyon(420, offsetM: 300),
            .dropout(200..<225), .dropout(500..<540),
        ]
        let raw = RiyadhDrive.fixes(truth, events: events)
        let tr = Trail.rebuild(raw)
        XCTAssertEqual(tr.gapCount, 0, "every silence was under a minute: no dashed line at all")
        let offs = tr.points.map { RiyadhDrive.offset($0.position, route) }
        XCTAssertLessThan(RiyadhDrive.percentile(offs, 0.95), 20, "smoothed path within 20 m of the streets (95%)")
        XCTAssertLessThan(offs.max()!, 60, "no canyon spike drawn")
        /* The 80 m burst still contributes: points exist all along it. */
        var k = TrailKalman()
        var used = 0, inBurst = 0
        for f in raw {
            let o = k.step(f)
            guard f.t >= truth[150].t && f.t < truth[190].t else { continue }
            inBurst += 1
            if case .accepted = o { used += 1 }
        }
        XCTAssertEqual(used, inBurst, "every 80 m fix of the burst is used (weighted), none dropped")
        /* Longest straight hop between kept points: only the 40 s dropout. */
        var hop = 0.0
        for i in tr.points.indices.dropFirst() { hop = max(hop, Vehicle.distanceMeters(tr.points[i - 1].position, tr.points[i].position)) }
        XCTAssertLessThan(hop, 600)
    }

    func testOnlyALongSilenceFarAwayIsAGap() throws {
        let route = try RiyadhDrive.route()
        let truth = RiyadhDrive.truth(route)
        /* 90 s with no fix at all while driving ~1.1 km: that one we truly did not see. */
        let tr = Trail.rebuild(RiyadhDrive.fixes(truth, events: [.dropout(300..<390)]))
        XCTAssertEqual(tr.gapCount, 1)
        /* Parked 3 minutes with no fixes: long but not far, so not a gap. */
        var tr2 = Trail()
        let f = TFix()
        tr2.add(f.fix(0, t: 0))
        tr2.add(f.fix(30, t: 3))
        XCTAssertTrue(tr2.add(f.fix(60, t: 200)))
        XCTAssertFalse(tr2.points.last!.gap, "180 s but 30 m: no gap")
        /* Far but quick (a reacquired fix 45 s later, 700 m on): drawn, not dashed. */
        tr2.add(f.fix(760, t: 245))
        XCTAssertFalse(tr2.points.last!.gap)
        XCTAssertTrue(Trail.isGap(silenceS: 61, distanceM: 501))
        XCTAssertFalse(Trail.isGap(silenceS: 61, distanceM: 499))
        XCTAssertFalse(Trail.isGap(silenceS: 59, distanceM: 5000))
    }

    func testReducedAccuracyFixesNeverDrawAndNeverGap() {
        var tr = Trail()
        let f = TFix()
        for i in 0..<60 { XCTAssertFalse(tr.add(f.fix(Double(i) * 15, t: Double(i), acc: 1_500)), "Precise Location off: km-level fixes are not a trail") }
        XCTAssertTrue(tr.isEmpty)
        XCTAssertFalse(tr.add(f.fix(0, t: 100, acc: 101)))
        XCTAssertTrue(tr.add(f.fix(0, t: 101, acc: 99)), "≤ 100 m still contributes (weighted)")
        let h = TrailHealth.compute(raw: [RawFix(t: 1000, lat: 24.7, lng: 46.6, acc: 1500)], nowMs: 2000, preciseOff: true, whenInUseOnly: false, lowPower: false)
        XCTAssertTrue(h.warnings.first!.hasPrefix("فعّل الموقع الدقيق"))
        var i = LivePresenterInput()
        i.locationAuthorized = true
        i.preciseOff = true
        XCTAssertTrue(LiveOutingPresenter.warnings(i).contains(.preciseOff))
        XCTAssertEqual(LiveWarningUI.preciseOff.label, "فعّل الموقع الدقيق • مسارك تقريبي الآن")
    }

    func testHealthLine() {
        let now = 1_800_000_060_000.0
        let raw = (0..<12).map { RawFix(t: now - Double($0) * 5000, lat: 24.7, lng: 46.6, acc: 8) }.reversed()
        let h = TrailHealth.compute(raw: Array(raw), nowMs: now, preciseOff: false, whenInUseOnly: true, lowPower: true)
        XCTAssertEqual(h.line, "الدقة ±\(SaryFormat.number(8)) م • \(SaryFormat.number(12)) نقطة/دقيقة")
        XCTAssertEqual(h.warnings.count, 2)
    }

    func testRecordingSettingsAreTheBest() {
        let road = LocationTuning.trailSettings(onRoad: true)
        XCTAssertEqual(road.desiredAccuracy, kCLLocationAccuracyBestForNavigation)
        XCTAssertEqual(road.distanceFilter, kCLDistanceFilterNone)
        XCTAssertEqual(road.activityType, .automotiveNavigation)
        XCTAssertEqual(LocationTuning.trailSettings(onRoad: false).activityType, .otherNavigation, "no road snapping in the desert")
    }
}

final class TrailRawLogTests: XCTestCase {
    var dir: URL!
    override func setUp() { dir = FileManager.default.temporaryDirectory.appendingPathComponent("raw-\(UUID().uuidString)") }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func testAppendLoadAndEveryFieldSurvives() {
        let a = RawFix(t: 1_800_000_000_123, lat: 24.7912345, lng: 46.6512345, acc: 7.5, spd: 12.34, crs: 271.5, spdAcc: 0.6)
        let b = RawFix(t: 1_800_000_001_000, lat: 24.79, lng: 46.65, acc: 65, spd: nil, crs: nil, spdAcc: nil)
        TrailRawLog.append([a], outingId: "o1", in: dir)
        TrailRawLog.append([b], outingId: "o1", in: dir)
        let back = TrailRawLog.load("o1", in: dir)
        XCTAssertEqual(back.count, 2)
        XCTAssertEqual(back[0].t, a.t)
        XCTAssertEqual(back[0].lat, a.lat, accuracy: 1e-7)
        XCTAssertEqual(back[0].crs, 271.5)
        XCTAssertNil(back[1].spd)
        TrailStore.delete("o1", in: dir)
        XCTAssertTrue(TrailRawLog.load("o1", in: dir).isEmpty, "clearing the trail clears its raw log")
    }

    func testCapThinsTheOlderHalf() {
        let n = TrailRawLog.cap + 1000
        let all = (0..<n).map { RawFix(t: Double($0), lat: 24, lng: 46, acc: 5) }
        let thin = TrailRawLog.thin(all)
        XCTAssertLessThan(thin.count, n)
        XCTAssertEqual(thin.last, all.last, "the newest fixes stay whole")
    }

    func testGPXHasRawFilteredAndMatchedWithAccuracy() {
        let raw = [RawFix(t: 1_800_000_000_000, lat: 24.79, lng: 46.65, acc: 8, spd: 10, crs: 90)]
        let pts = [TrailPoint(lat: 24.79, lng: 46.65, t: 1_800_000_000_000), TrailPoint(lat: 24.8, lng: 46.66, t: 1_800_000_100_000, gap: true)]
        let g = TrailGPX.document(name: "x & y", raw: raw, filtered: pts, matched: pts)
        XCTAssertTrue(g.contains("<sary:acc>8.0</sary:acc>"))
        XCTAssertTrue(g.contains("<name>raw</name>") && g.contains("<name>filtered</name>") && g.contains("<name>matched</name>"))
        XCTAssertTrue(g.contains("x &amp; y"))
        XCTAssertEqual(g.components(separatedBy: "<trkseg>").count - 1, 5, "a gap splits the segment")
        TrailRawLog.append(raw, outingId: "o9", in: dir)
        XCTAssertNotNil(TrailGPX.export(outingId: "o9", in: dir))
    }
}

/// A matcher that knows the true streets (stands in for Mapbox in unit tests).
struct TruthMatcher: TrailMatchingService {
    let road: [LngLat]
    var confidence = 0.9
    var maxPoints: Int { 100 }
    final class Log: @unchecked Sendable { var calls: [[MatchInput]] = [] }
    let log = Log()

    /// The road densified to ~5 m.
    static func densify(_ l: [LngLat]) -> [LngLat] {
        var out: [LngLat] = [l[0]]
        for i in 1..<l.count {
            let d = Vehicle.distanceMeters(l[i - 1], l[i])
            let n = max(1, Int(d / 5))
            for k in 1...n {
                let u = Double(k) / Double(n)
                out.append(LngLat(lng: l[i - 1].lng + (l[i].lng - l[i - 1].lng) * u, lat: l[i - 1].lat + (l[i].lat - l[i - 1].lat) * u))
            }
        }
        return out
    }

    func match(_ pts: [MatchInput]) async throws -> [MatchedPiece] {
        log.calls.append(pts)
        var idx: [Int] = []
        var from = 0
        for (n, p) in pts.enumerated() {
            /* Nearest vertex (anywhere for the first point), then moving forward like a real HMM matcher. */
            var best = from, bd = Double.infinity
            for i in from..<(n == 0 ? road.count : min(road.count, from + 400)) {
                let d = Vehicle.distanceMeters(LngLat(lng: p.lng, lat: p.lat), road[i])
                if d < bd { bd = d; best = i }
            }
            idx.append(best)
            from = best
        }
        guard let lo = idx.first, let hi = idx.last, hi > lo else { return [] }
        let coords = Array(road[lo...hi])
        let anchors = zip(pts, idx).map { (t: $0.t, index: $1 - lo) }
        return [MatchedPiece(first: 0, last: pts.count - 1, coords: coords, anchors: anchors, confidence: confidence)]
    }
}

final class TrailMatchingTests: XCTestCase {
    func testChunksAreAtMostOneHundredWithOverlap() {
        let c = TrailMatchPlanner.chunks(count: 250)
        XCTAssertEqual(c.first, 0..<100)
        XCTAssertTrue(c.allSatisfy { $0.count <= 100 })
        for i in 1..<c.count { XCTAssertEqual(c[i - 1].upperBound - c[i].lowerBound, TrailMatchPlanner.overlap, "consecutive chunks share the overlap") }
        XCTAssertEqual(c.last?.upperBound, 250)
        XCTAssertEqual(TrailMatchPlanner.chunks(count: 1), [])
        XCTAssertEqual(TrailMatchPlanner.chunks(count: 100), [0..<100])
        XCTAssertEqual(TrailMatchPlanner.chunks(count: 105), [0..<100, 90..<105])
    }

    func testMapboxRequestIsWellFormed() throws {
        let m = MapboxTrailMatching(token: "pk.test")
        let pts = (0..<100).map { MatchInput(lat: 24.79 + Double($0) * 1e-4, lng: 46.65, t: 1_800_000_000_000 + Double($0) * 3000, radiusM: MapboxTrailMatching.radius(Double($0))) }
        let u = try XCTUnwrap(m.url(pts)).absoluteString
        XCTAssertTrue(u.hasPrefix("https://api.mapbox.com/matching/v5/mapbox/driving/46.650000,24.790000;"))
        XCTAssertTrue(u.contains("geometries=polyline6") && u.contains("tidy=true") && u.contains("overview=full"))
        XCTAssertTrue(u.contains("timestamps=1800000000;1800000003;"), "seconds, increasing")
        XCTAssertTrue(u.contains("waypoints=0;99"))
        XCTAssertEqual(MapboxTrailMatching.radius(nil), 25)
        XCTAssertEqual(MapboxTrailMatching.radius(2), 5)
        XCTAssertEqual(MapboxTrailMatching.radius(80), 50, "Mapbox caps radiuses at 50 m")
        XCTAssertLessThan(u.count, 8000, "fits a GET")
    }

    func testParsesAMapboxResponse() throws {
        let geom = [LngLat(lng: 46.65, lat: 24.79), LngLat(lng: 46.651, lat: 24.79), LngLat(lng: 46.652, lat: 24.79)]
        XCTAssertEqual(Polyline.decode(Polyline.encode(geom)), geom)
        let json: [String: Any] = [
            "code": "Ok",
            "matchings": [["confidence": 0.87, "geometry": Polyline.encode(geom), "distance": 200]],
            "tracepoints": [
                ["location": [46.65, 24.79], "matchings_index": 0, "waypoint_index": 0],
                NSNull(),
                ["location": [46.652, 24.79], "matchings_index": 0, "waypoint_index": 1],
            ],
        ]
        let inputs = (0..<3).map { MatchInput(lat: 24.7901, lng: 46.65 + Double($0) * 1e-3, t: Double($0) * 1000, radiusM: 10) }
        let pieces = try MapboxTrailMatching.parse(JSONSerialization.data(withJSONObject: json), inputs: inputs)
        XCTAssertEqual(pieces.count, 1)
        XCTAssertEqual(pieces[0].first, 0)
        XCTAssertEqual(pieces[0].last, 2)
        XCTAssertEqual(pieces[0].anchors.map(\.index), [0, 2], "the unmatched middle point has no anchor")
        XCTAssertEqual(pieces[0].confidence, 0.87)
        let none = try MapboxTrailMatching.parse(JSONSerialization.data(withJSONObject: ["code": "NoMatch"]), inputs: inputs)
        XCTAssertTrue(none.isEmpty, "desert: no match is an answer, not an error")
    }

    /// The whole drive in chunks: merged geometry is continuous, follows the streets, and the seams are clean.
    func testChunkedMatchingMergesIntoOneRoadLine() async throws {
        let route = try RiyadhDrive.route()
        let truth = RiyadhDrive.truth(route)
        let raw = RiyadhDrive.fixes(truth, events: [.burst(150..<190, acc: 60), .canyon(260, offsetM: -150)])
        let tr = Trail.rebuild(raw)
        let svc = TruthMatcher(road: TruthMatcher.densify(route))
        var cache = TrailMatchCache()
        let plan = try XCTUnwrap(TrailMatchCoordinator.plan(tr.points, cache: cache))
        XCTAssertGreaterThan(plan.jobs.count, 2, "a long drive needs several requests")
        XCTAssertTrue(plan.jobs.allSatisfy { $0.inputs.count <= 100 })
        XCTAssertNil(plan.jobs[0].cutT)
        for job in plan.jobs { cache.integrate(try await svc.match(job.inputs), inputs: job.inputs, cutT: job.cutT) }
        XCTAssertEqual(cache.spans.count, plan.jobs.count)
        for i in 1..<cache.spans.count {
            XCTAssertEqual(cache.spans[i - 1].endT, cache.spans[i].startT, "seam cut at the same input time in both chunks")
            let a = cache.spans[i - 1].line.last!, b = cache.spans[i].line.first!
            XCTAssertLessThan(Vehicle.distanceMeters(a, b), 6, "no jump at the seam")
        }
        let shown = TrailDisplay.compose(tr.points, cache)
        let offs = shown.map { RiyadhDrive.offset($0.position, route) }
        XCTAssertLessThan(offs.max()!, 3, "the matched line is on the streets")
        XCTAssertFalse(shown.contains(where: \.gap))
        for i in shown.indices.dropFirst() { XCTAssertGreaterThan(shown[i].t, shown[i - 1].t - 1, "time keeps going forward") }

        /* Incremental: nothing new → no plan; the trail grows → only the new stretch plus the overlap. */
        XCTAssertNil(TrailMatchCoordinator.plan(tr.points, cache: cache))
        var longer = tr
        let more = RiyadhDrive.fixes(truth.map { ($0.t + 10_000_000, $0.p, $0.v, $0.course) }, events: []).prefix(60)
        for f in more { longer.add(f) }
        let next = try XCTUnwrap(TrailMatchCoordinator.plan(longer.points, cache: cache))
        XCTAssertEqual(next.jobs.count, 1)
        XCTAssertNotNil(next.jobs[0].cutT)
        XCTAssertEqual(next.jobs[0].inputs.first!.t, TrailMatchPlanner.inputs(tr.points).suffix(TrailMatchPlanner.overlap).first!.t)
    }

    func testLowConfidenceOrFarMatchKeepsTheSmoothedLine() async throws {
        let route = try RiyadhDrive.route()
        let tr = Trail.rebuild(RiyadhDrive.fixes(RiyadhDrive.truth(route), events: []))
        let inputs = Array(TrailMatchPlanner.inputs(tr.points).prefix(50))
        var weak = TruthMatcher(road: TruthMatcher.densify(route))
        weak.confidence = 0.1
        var c = TrailMatchCache()
        c.integrate(try await weak.match(inputs), inputs: inputs, cutT: nil)
        XCTAssertTrue(c.spans.isEmpty)
        XCTAssertEqual(c.doneUpToT, inputs.last!.t, "tried: not asked again")
        /* A "match" on a road 300 m away (a parallel highway): not the road we drove. */
        let shifted = TruthMatcher.densify(route).map { TrailGeo.lngLat(300, 0, ref: $0) }
        var c2 = TrailMatchCache()
        c2.integrate(try await TruthMatcher(road: shifted).match(inputs), inputs: inputs, cutT: nil)
        XCTAssertTrue(c2.spans.isEmpty)
        XCTAssertEqual(TrailDisplay.compose(tr.points, c2), tr.points, "the smoothed path stays (desert, low confidence)")
    }

    func testGapInsideAMatchIsDashedAlongTheRoad() async throws {
        let route = try RiyadhDrive.route()
        let truth = RiyadhDrive.truth(route)
        let tr = Trail.rebuild(RiyadhDrive.fixes(truth, events: [.dropout(100..<180)]))
        XCTAssertEqual(tr.gapCount, 1)
        let inputs = Array(TrailMatchPlanner.inputs(tr.points).prefix(100))
        var c = TrailMatchCache()
        c.integrate(try await TruthMatcher(road: TruthMatcher.densify(route)).match(inputs), inputs: inputs, cutT: nil)
        let shown = TrailDisplay.compose(tr.points, c)
        let runs = Trail.runs(shown)
        XCTAssertEqual(runs.gaps.count, 1, "still one honest gap…")
        XCTAssertGreaterThan(runs.gaps[0].count, 10, "…drawn along the street, not as one straight line")
        XCTAssertLessThan(runs.gaps[0].map { RiyadhDrive.offset($0, route) }.max()!, 3)
    }

    @MainActor
    func testCoordinatorCachesAndSurvivesOffline() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("match-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        struct Offline: TrailMatchingService {
            var maxPoints: Int { 100 }
            func match(_ pts: [MatchInput]) async throws -> [MatchedPiece] { throw TrailMatchError.offline }
        }
        let route = try RiyadhDrive.route()
        let tr = Trail.rebuild(RiyadhDrive.fixes(RiyadhDrive.truth(route), events: []))
        let off = TrailMatchCoordinator(outingId: "o", dir: dir, service: Offline())
        off.tick(tr, force: true)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(off.cache.spans.isEmpty, "offline: the smoothed trail stays, nothing cached")

        let on = TrailMatchCoordinator(outingId: "o", dir: dir, service: TruthMatcher(road: TruthMatcher.densify(route)))
        let changed = expectation(description: "matched")
        on.onChange = { changed.fulfill() }
        on.tick(tr, force: true)
        await fulfillment(of: [changed], timeout: 5)
        XCTAssertFalse(on.cache.spans.isEmpty)
        XCTAssertEqual(TrailMatchStore.load("o", in: dir), on.cache, "cached on this device")
        XCTAssertEqual(TrailMatchCoordinator(outingId: "o", dir: dir, service: Offline()).cache, on.cache, "a relaunch starts from the cache (offline-first)")
    }

    /// Opt-in: the real Mapbox Map Matching API on the noisy Riyadh drive (`TEST_RUNNER_SARY_LIVE_MATCH=1`).
    func testLiveMapboxMatchesTheNoisyDrive() async throws {
        guard ProcessInfo.processInfo.environment["SARY_LIVE_MATCH"] == "1",
              let token = ProcessInfo.processInfo.environment["SARY_MAPBOX_TOKEN"], token.hasPrefix("pk.") else {
            throw XCTSkip("live Mapbox test is opt-in")
        }
        let route = try RiyadhDrive.route()
        let truth = RiyadhDrive.truth(route)
        let raw = RiyadhDrive.fixes(truth, events: [.burst(40..<70, acc: 45), .burst(150..<190, acc: 80), .canyon(100, offsetM: 220), .canyon(260, offsetM: -180), .dropout(200..<225)])
        let tr = Trail.rebuild(raw)
        let svc = MapboxTrailMatching(token: token)
        var cache = TrailMatchCache()
        let plan = try XCTUnwrap(TrailMatchCoordinator.plan(tr.points, cache: cache))
        for job in plan.jobs { cache.integrate(try await svc.match(job.inputs), inputs: job.inputs, cutT: job.cutT) }
        let shown = TrailDisplay.compose(tr.points, cache)
        let offs = shown.map { RiyadhDrive.offset($0.position, route) }
        let smoothed = tr.points.map { RiyadhDrive.offset($0.position, route) }
        print("LIVE MATCH: requests=\(plan.jobs.count) spans=\(cache.spans.count) matched p95=\(RiyadhDrive.percentile(offs, 0.95)) max=\(offs.max()!) smoothed p95=\(RiyadhDrive.percentile(smoothed, 0.95)) max=\(smoothed.max()!)")
        XCTAssertFalse(cache.spans.isEmpty)
        XCTAssertLessThan(RiyadhDrive.percentile(offs, 0.95), 6, "on the real streets")
    }
}

final class BackTrackHysteresisTests: XCTestCase {
    let f = TFix()

    func straight() -> BackTrack {
        var pts: [TrailPoint] = []
        for i in 0...50 { let x = f.fix(Double(i) * 20, t: Double(i) * 2); pts.append(TrailPoint(lat: x.lat, lng: x.lng, t: x.atMs)) }
        return BackTrack(path: pts)!
    }

    func at(_ n: Double, _ e: Double = 0) -> LngLat { let x = f.fix(n, e, t: 0); return LngLat(lng: x.lng, lat: x.lat) }

    func testWarnsOnlyAfterTenSecondsFarAndClearsInside35() {
        var bt = straight()
        let t0 = 1_800_000_000_000.0
        for s in 0..<10 { XCTAssertFalse(bt.update(at(800, 80), accuracy: 5, atMs: t0 + Double(s) * 1000).offTrack, "a moment beside the trail is not leaving it") }
        XCTAssertTrue(bt.update(at(800, 80), accuracy: 5, atMs: t0 + 10_000).offTrack)
        XCTAssertTrue(bt.update(at(800, 40), accuracy: 5, atMs: t0 + 11_000).offTrack, "hysteresis: still out at 40 m")
        XCTAssertFalse(bt.update(at(800, 30), accuracy: 5, atMs: t0 + 12_000).offTrack, "back inside 35 m")
        /* Out and straight back in before the hold: never warned. */
        _ = bt.update(at(700, 90), accuracy: 5, atMs: t0 + 20_000)
        _ = bt.update(at(700, 20), accuracy: 5, atMs: t0 + 25_000)
        XCTAssertFalse(bt.update(at(700, 90), accuracy: 5, atMs: t0 + 29_000).offTrack, "the hold restarts")
    }

    func testNeverWarnsWhenTheGPSIsLessSureThanTheDistance() {
        var bt = straight()
        let t0 = 1_800_000_000_000.0
        for s in 0...20 { XCTAssertFalse(bt.update(at(500, 90), accuracy: 120, atMs: t0 + Double(s) * 1000).offTrack) }
        for s in 21...40 { _ = bt.update(at(500, 90), accuracy: 10, atMs: t0 + Double(s) * 1000) }
        XCTAssertTrue(bt.update(at(500, 90), accuracy: 10, atMs: t0 + 41_000).offTrack)
        XCTAssertFalse(bt.update(at(500, 90), accuracy: 95, atMs: t0 + 42_000).offTrack, "accuracy worse than the distance: no claim")
    }

    func testReacquiresWhenTheCursorWasMisled() {
        var bt = straight()
        /* A glitch near the start pulls the cursor back… */
        _ = bt.update(at(20, 5))
        XCTAssertLessThanOrEqual(bt.cursor, 2)
        /* …but I am really driving at 800 m on the trail: found again, not «خرجت» by 780 m. */
        let s = bt.update(at(800, 5))
        XCTAssertFalse(s.offTrack)
        XCTAssertEqual(s.offsetM, 5, accuracy: 1)
        XCTAssertEqual(s.alongM, 800, accuracy: 3)
    }
}

/// «المركبة تخرج عن المسار وتجي فوق المبنى»: the car (mine and friends') on the street in town,
/// at the true position off-road.
final class CarOnStreetTests: XCTestCase {
    /// The real route as Mapbox Streets would give it, cut into long lines, plus a parallel street 45 m east.
    func roads(_ route: [LngLat]) -> [RoadSnap.RoadLine] {
        let main = RoadSnap.RoadLine(key: "main", coords: route.map { [$0.lng, $0.lat] })
        /* Offset perpendicular to the local direction: a real parallel street on every leg. */
        let parallel = RoadSnap.RoadLine(key: "parallel", coords: route.indices.map { i in
            let a = route[max(0, i - 1)], b = route[min(route.count - 1, i + 1)]
            let d = TrailGeo.xy(b, ref: a)
            let len = max((d.x * d.x + d.y * d.y).squareRoot(), 0.001)
            let q = TrailGeo.lngLat(45 * d.y / len, -45 * d.x / len, ref: route[i])
            return [q.lng, q.lat]
        })
        return [main, parallel]
    }

    func testNoisyCityDriveIsDrawnOnTheStreetWithoutFlicker() throws {
        let route = try RiyadhDrive.route()
        let truth = RiyadhDrive.truth(route)
        let raw = RiyadhDrive.fixes(truth, events: [.burst(40..<70, acc: 45), .burst(150..<190, acc: 80), .canyon(100, offsetM: 70), .canyon(260, offsetM: -60), .dropout(200..<225)])
        let lines = roads(route)
        for useKalman in [false, true] {
            /* Friends: raw fixes from the server. «أنت»: the Kalman position. Both with speed + course. */
            let m = RoadSnap.Matcher()
            var k = TrailKalman()
            var onStreet = 0, n = 0, switches = 0, lastKey: String?
            for f in raw {
                var p = f.position
                if useKalman, case let .accepted(q, _, _, _) = k.step(f) { p = q }
                let r = m.match(p, RoadSnap.nearby(lines, p), course: f.crs, speed: f.spd, accuracy: f.acc, atMs: f.t)
                guard (f.spd ?? 0) >= RoadSnap.drivingMps else { continue }
                n += 1
                if r.key != nil, RiyadhDrive.offset(r.point, route) < 2 { onStreet += 1 }
                if let key = r.key, key != lastKey { if lastKey != nil { switches += 1 }; lastKey = key }
            }
            let share = Double(onStreet) / Double(n)
            XCTAssertGreaterThan(share, 0.97, "\(useKalman ? "me (Kalman)" : "friend (raw)"): on the driven street, not on the roofs (\(share))")
            XCTAssertLessThanOrEqual(switches, 2, "no flicker to the parallel street (\(useKalman ? "me" : "friend"))")
        }
    }

    func testBuild4DroppedLongStraightStreets() {
        /* One straight 2 km street: two vertices only, 1 km from the car each way. */
        let street = RoadSnap.RoadLine(key: "s", coords: [[46.64, 24.80], [46.66, 24.80]])
        let p = LngLat(lng: 46.65, lat: 24.80 + 20 / 110_540)
        XCTAssertEqual(RoadSnap.nearby([street], p).map(\.key), ["s"], "found by its segment, not only its vertices")
    }

    func testWideCanyonFixWhileDrivingSnapsButParkedOrOffRoadDoesNot() {
        let street = RoadSnap.RoadLine(key: "s", coords: [[46.64, 24.80], [46.66, 24.80]])
        func north(_ m: Double, _ lng: Double = 46.65) -> LngLat { LngLat(lng: lng, lat: 24.80 + m / 110_540) }
        XCTAssertEqual(RoadSnap.searchRadius(accuracy: 70, speed: 12, course: 90), 100)
        XCTAssertEqual(RoadSnap.searchRadius(accuracy: 70, speed: 0, course: nil), 60)
        /* Driving east, a 70 m city fix 80 m north of the street: on the street. */
        let a = RoadSnap.Matcher()
        XCTAssertEqual(a.match(north(80), [street], course: 90, speed: 12, accuracy: 70, atMs: 0).key, "s")
        /* Parked 40 s, 35 m from the street (a car park): where it is. */
        let b = RoadSnap.Matcher()
        for s in 0...40 { _ = b.match(north(35, 46.65 + Double(s) * 1e-7), [street], course: nil, speed: 0, accuracy: 20, atMs: Double(s) * 1000) }
        XCTAssertNil(b.match(north(35, 46.651), [street], course: nil, speed: 0, accuracy: 20, atMs: 41_000).key)
        /* Off-road beside the street (sand track 60 m north, good GPS): never pulled onto it, even by a poor fix. */
        let c = RoadSnap.Matcher()
        for s in 0..<5 { XCTAssertNil(c.match(north(60, 46.65 + Double(s) * 1e-4), [street], course: 90, speed: 8, accuracy: 5, atMs: Double(s) * 1000).key) }
        XCTAssertTrue(c.offRoad)
        XCTAssertNil(c.match(north(20, 46.6506), [street], course: 90, speed: 8, accuracy: 70, atMs: 6000).key, "clearly off-road: a noisy fix is not a road")
        /* Back on the street with good fixes: snapped again. */
        XCTAssertEqual(c.match(north(3, 46.6508), [street], course: 90, speed: 8, accuracy: 5, atMs: 7000).key, "s")
    }

    @MainActor
    func testMyCarIsTheSmoothedPosition() {
        var tr = Trail()
        let f = TFix()
        for i in 0..<20 { tr.add(f.fix(Double(i) * 12, t: Double(i))) }
        let spike = f.fix(19 * 12 + 12, 80, t: 20, acc: 40)
        tr.add(spike)
        let k = tr.filter!
        let truth = f.fix(20 * 12, t: 20)
        XCTAssertLessThan(Vehicle.distanceMeters(k.position, LngLat(lng: truth.lng, lat: truth.lat)), 25, "the drawn car stays near the street…")
        XCTAssertGreaterThan(Vehicle.distanceMeters(k.position, LngLat(lng: spike.lng, lat: spike.lat)), 50, "…not on the roof the 40 m fix points at")
    }
}
