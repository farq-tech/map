import CoreLocation
import XCTest
@testable import SaryAlbarq

/// Guidance fed the way a real iPhone feeds it (build 21 regression): a cached first fix from
/// minutes ago, coarse Wi‑Fi fixes while the chip warms up, speed/course often invalid, then
/// a drive. Every fix goes through the real pipeline: `LocationSharer.ingest` (the quality
/// gate) → `lastFix` → `NavSession` (as `LiveOutingController.locationChanged` does).
@MainActor
final class NavDeviceTraceTests: XCTestCase {
    static let olaya = Geo.LatLng(lat: 24.7113, lng: 46.6744)

    private func at(_ p: Geo.LatLng, north: Double = 0, east: Double = 0) -> Geo.LatLng {
        DisplaySmoother.move(DisplaySmoother.move(p, meters: north, bearingDeg: 0), meters: east, bearingDeg: 90)
    }

    private func fix(_ p: Geo.LatLng, acc: Double, speed: Double?, course: Double?, at t: Double) -> DeviceFix {
        DeviceFix(lat: p.lat, lng: p.lng, accuracy: acc, heading: course, speed: speed, atMs: t,
                  speedAccuracy: speed == nil ? nil : 0.6, courseAccuracy: course == nil ? nil : 8)
    }

    /// (fix, the time it reaches the app). Starts at `t0`; drives `driveS` seconds east at 20 m/s.
    private func deviceTrace(t0: Double, driveS: Int = 150) -> [(DeviceFix, Double)] {
        var out: [(DeviceFix, Double)] = []
        /* 1. iOS's cached fix: 4 minutes old, 2 km away (where the phone last was). */
        out.append((fix(at(Self.olaya, north: 2_000), acc: 10, speed: nil, course: nil, at: t0 - 240_000), t0))
        /* 2. Wi‑Fi / cell while the GPS warms up: coarse, no speed, no course. */
        for (i, a) in [165.0, 65, 65, 47, 35].enumerated() {
            let t = t0 + 600 + Double(i) * 1000
            out.append((fix(at(Self.olaya, north: 40, east: -30), acc: a, speed: nil, course: nil, at: t), t + 150))
        }
        /* 3. GPS lock, parked 10 s (speed 0, course invalid). */
        for i in 0..<10 {
            let t = t0 + 6_000 + Double(i) * 1000
            out.append((fix(Self.olaya, acc: 8, speed: 0, course: nil, at: t), t + 150))
        }
        /* 4. The drive: 20 m/s east, 1 Hz, every 7th fix without speed/course (CoreLocation's −1). */
        for i in 0..<driveS {
            let t = t0 + 16_000 + Double(i) * 1000
            let noSpeed = i % 7 == 3
            out.append((fix(at(Self.olaya, east: 20 * Double(i)), acc: 6, speed: noSpeed ? nil : 20, course: noSpeed ? nil : 90, at: t), t + 150))
        }
        return out
    }

    func testTheGateKeepsAFreshFixForGuidanceOnARealPhoneStart() {
        let loc = LocationSharer()
        let t0 = 1_800_000_000_000.0
        var maxAgeAfterLock = 0.0
        for (f, now) in deviceTrace(t0: t0) {
            loc.ingest(f, nowMs: now)
            if now > t0 + 8_000, let last = loc.lastFix { maxAgeAfterLock = max(maxAgeAfterLock, now - last.atMs) }
        }
        XCTAssertLessThan(maxAgeAfterLock, 2_000, "lastFix must follow the drive (rejected: \(loc.quality.rejected))")
        let end = at(Self.olaya, east: 20 * 149)
        XCTAssertLessThan(Geo.haversineMeters(loc.lastFix!.coordinate, end), 1)
        XCTAssertLessThan(Geo.haversineMeters(loc.displayFix!.coordinate, end), 40, "the dot follows the car")
    }

    func testNavLocatorGateAcceptsTheDrive() {
        var gate = FixQualityGate(keepsFirstStale: false)
        let t0 = 1_800_000_000_000.0
        var accepted = 0, lastAccepted = 0.0
        for (f, now) in deviceTrace(t0: t0) {
            if case .accept = gate.judge(f, nowMs: now) { accepted += 1; lastAccepted = f.atMs }
        }
        XCTAssertGreaterThan(accepted, 150, "rejected: \(gate.rejected)")
        XCTAssertEqual(lastAccepted, t0 + 16_000 + 149_000)
    }

    func testRoadGuidanceAdvancesOnADeviceTrace() async {
        let loc = LocationSharer()
        let t0 = Date().timeIntervalSince1970 * 1000
        let trace = deviceTrace(t0: t0)
        let end = LngLat(lng: at(Self.olaya, east: 3_000).lng, lat: Self.olaya.lat)
        let start = LngLat(lng: Self.olaya.lng, lat: Self.olaya.lat)
        let c = (0...30).map { i in LngLat(lng: start.lng + (end.lng - start.lng) * Double(i) / 30, lat: start.lat) }
        let d = Vehicle.distanceMeters(start, end)
        let route = NavRoute(id: "r", coordinates: c, distanceM: d, durationS: d / 20, steps: [
            NavStep(maneuver: .init(kind: .depart, direction: nil), roadName: "العليا", location: start, distanceM: 1_500, durationS: 75),
            NavStep(maneuver: .init(kind: .turn, direction: .right), roadName: "التخصصي", location: c[15], distanceM: 1_500, durationS: 75),
            NavStep(maneuver: .init(kind: .arrive, direction: nil), roadName: nil, location: end, distanceM: 0, durationS: 0),
        ])
        let n = NavSession(provider: ScriptedRouter([.success(NavRoutePlan(routes: [route]))]), makeEngine: { _ in LocalGuidanceEngine() })
        n.muted = true
        n.myFix = { [weak loc] in loc?.lastFix }
        var said: [String] = []
        n.voice.onSpoken = { said.append($0) }
        /* Warm-up: the cached fix and the Wi‑Fi ones. */
        for (f, now) in trace.prefix(6) { loc.ingest(f, nowMs: now); if let l = loc.lastFix { n.ingest(l) } }
        n.autoStart(to: NavTarget(source: .destination, name: "الوجهة", position: end))
        let deadline = Date().addingTimeInterval(3)
        while n.phase != .guiding, Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(n.phase, .guiding)
        var steps: Set<Int> = []
        for (f, now) in trace.dropFirst(6) {
            loc.ingest(f, nowMs: now)
            /* `locationChanged` runs once per publish: lastFix, displayFix and «جودة GPS» each publish. */
            for _ in 0..<3 { if let l = loc.lastFix { n.ingest(l) } }
            if let p = n.progress { steps.insert(p.stepIndex) }
        }
        XCTAssertTrue(steps.contains(2), "guidance advanced past the turn (steps seen \(steps))")
        XCTAssertFalse(n.rerouting, "never rerouted on a straight drive along the route")
        XCTAssertFalse(said.isEmpty, "something was said")
        n.end()
    }

    // MARK: «التوجيه بالصوت مرات يشتغل ومرات لا»

    /// Mapbox drives the progress and the cue timing; nothing else.
    final class CueEngine: NavGuidanceEngine {
        var onEvent: (NavGuidanceEvent) -> Void = { _ in }
        func start(route: NavRoute, plan: NavRoutePlan, target: NavTarget) async throws {}
        func stop() {}
        func ingest(_ fix: DeviceFix) {}
    }

    /// A city drive with many maneuvers of every kind, at `speed`; Mapbox's voice instructions
    /// for each step at its own distances (early, then ~5 s before the maneuver). Returns
    /// (maneuvers whose last cue was voiced, maneuvers) and the spoken lines.
    private func cueCoverage(speed: Double) async -> (voiced: Int, total: Int, lines: [String]) {
        let kinds: [NavManeuver] = [
            .init(kind: .turn, direction: .right), .init(kind: .turn, direction: .slightLeft), .init(kind: .fork, direction: .right),
            .init(kind: .merge, direction: .left), .init(kind: .onRamp, direction: .right), .init(kind: .offRamp, direction: .slightRight),
            .init(kind: .roundabout, direction: .right, exit: 2), .init(kind: .endOfRoad, direction: .left), .init(kind: .continue, direction: .straight),
            .init(kind: .newName, direction: nil), .init(kind: .turn, direction: .sharpLeft), .init(kind: .turn, direction: .uTurn),
            .init(kind: .turn, direction: .left), .init(kind: .exitRoundabout, direction: nil), .init(kind: .arrive, direction: .right),
        ]
        let lens: [Double] = [120, 900, 260, 1800, 450, 90, 600, 2400, 300, 700, 180, 140, 1100, 380, 0]
        let o = LngLat(lng: 46.6744, lat: 24.7113)
        var steps = [NavStep(maneuver: .init(kind: .depart, direction: nil), roadName: "العليا", location: o, distanceM: 200, durationS: 14)]
        for (i, k) in kinds.enumerated() {
            steps.append(NavStep(maneuver: k, roadName: "طريق \(i)", location: LngLat(lng: o.lng + Double(i) * 0.002, lat: o.lat), distanceM: lens[i], durationS: lens[i] / speed))
        }
        let coords = steps.map(\.location)
        let total = steps.map(\.distanceM).reduce(0, +)
        let route = NavRoute(id: "city", coordinates: coords, distanceM: total, durationS: total / speed, steps: steps)
        let engine = CueEngine()
        let n = NavSession(provider: ScriptedRouter([.success(NavRoutePlan(routes: [route]))]), makeEngine: { _ in engine })
        n.muted = true
        let now = Date().timeIntervalSince1970 * 1000
        n.myFix = { DeviceFix(lat: o.lat, lng: o.lng, accuracy: 5, heading: 90, speed: speed, atMs: now) }
        var lines: [String] = []
        n.voice.onSpoken = { lines.append($0) }
        n.autoStart(to: NavTarget(source: .destination, name: "الوجهة", position: steps.last!.location))
        let deadline = Date().addingTimeInterval(3)
        while n.phase != .guiding, Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
        while lines.isEmpty, Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
        var voiced = 0
        var remaining = total
        for idx in 1..<steps.count {
            /* Driving the step before maneuver `idx` (its length = the previous step's). */
            let len = steps[idx - 1].distanceM
            /* Mapbox's announcements for this maneuver (metres before it), as its voice instructions do. */
            var at: [Double] = []
            if len > 1_500 { at.append(1_000) }
            if len > 500 { at.append(400) }
            at.append(min(len * 0.9, 150))
            at.append(max(20, speed * 5))
            /* Mapbox spaces its instructions (a short step gets one): none within 25 m of the previous. */
            var spaced: [Double] = []
            for d in at.filter({ $0 < len }).sorted(by: >) where spaced.last.map({ $0 - d >= 25 }) ?? true { spaced.append(d) }
            at = spaced
            var lastVoiced = false
            for d in at {
                n.handle(.progress(NavProgress(stepIndex: idx, distanceToManeuverM: d, distanceRemainingM: remaining - (len - d), durationRemainingS: 0)))
                let before = lines.count
                n.handle(.cue("text"))
                lastVoiced = lines.count > before
            }
            if lastVoiced { voiced += 1 }
            remaining -= len
        }
        n.end()
        return (voiced, steps.count - 1, lines)
    }

    func testEveryManeuverGetsItsLastCueSpokenAtCitySpeed() async {
        let r = await cueCoverage(speed: 14)
        print("[VOICE-COVERAGE] city 50 km/h: \(r.voiced)/\(r.total)")
        XCTAssertEqual(r.voiced, r.total, "the «now» cue of every maneuver is said: \(r.lines)")
    }

    func testEveryManeuverGetsItsLastCueSpokenOnTheHighway() async {
        let r = await cueCoverage(speed: 30)
        print("[VOICE-COVERAGE] highway 110 km/h: \(r.voiced)/\(r.total)")
        XCTAssertEqual(r.voiced, r.total, "the «now» cue of every maneuver is said: \(r.lines)")
    }

    func testEveryManeuverGetsItsLastCueSpokenSlowly() async {
        let r = await cueCoverage(speed: 4)
        print("[VOICE-COVERAGE] desert track 15 km/h: \(r.voiced)/\(r.total)")
        XCTAssertEqual(r.voiced, r.total, "the «now» cue of every maneuver is said: \(r.lines)")
    }

    /// Every maneuver Mapbox Directions can give (turn, fork, merge, ramps, roundabout / rotary
    /// with every exit, end of road, continue, new name, notification, use lane, arrive, depart,
    /// U-turn), with every modifier, at every distance band: a clip sequence that is all in the bundle.
    func testEveryManeuverHasRecordedClips() {
        let dirs: [NavTurnDirection?] = [nil] + [.sharpRight, .right, .slightRight, .straight, .slightLeft, .left, .sharpLeft, .uTurn]
        let kinds: [NavManeuverKind] = [.depart, .turn, .continue, .newName, .merge, .onRamp, .offRamp, .fork, .endOfRoad, .useLane,
                                        .roundabout, .exitRoundabout, .notification, .arrive]
        var missing: [String] = []
        var checked = 0
        for k in kinds {
            for d in dirs {
                for exit in k == .roundabout ? [nil, 1, 2, 3, 4, 5, 6, 7, 8, 9, 12] : [nil] {
                    for last in k == .roundabout ? [false, true] : [false] {
                        let m = NavManeuver(kind: k, direction: d, exit: exit, lastExit: last)
                        let step = NavStep(maneuver: m, roadName: nil, location: LngLat(lng: 46.67, lat: 24.71), distanceM: 300, durationS: 20)
                        for dist in [5.0, 40, 75, 150, 300, 700, 1_500, 3_000, 40_000, 300_000] {
                            for auto in [false, true] {
                                let clips = SaryVoiceScript.step(step, distanceM: dist, auto: auto)
                                checked += 1
                                if clips.isEmpty || !SaryVoiceCatalog.has(clips) { missing.append("\(k) \(String(describing: d)) exit=\(String(describing: exit)) \(dist) → \(clips)") }
                            }
                        }
                    }
                }
            }
        }
        print("[VOICE-CLIPS] \(checked) lines, \(missing.count) without clips")
        XCTAssertTrue(missing.isEmpty, missing.prefix(10).joined(separator: "\n"))
    }

    /// A line «صوت سرى» cannot say (no clip) is said with the device voice — never silence.
    func testALineWithoutClipsFallsBackToTheDeviceVoice() {
        let v = NavVoice()
        v.muted = false
        v.choice = { .sary }
        var device: [String] = []
        v.speakDevice = { device.append($0) }
        v.say("انعطف يمينًا", clips: [])
        XCTAssertEqual(device, ["انعطف يمينًا"])
        XCTAssertEqual(v.stats.deviceFallback, 1)
        XCTAssertEqual(v.stats.spoken, 1)
        v.stop()
    }

    func testRepeatsAreOnlyTheSameMoment() {
        XCTAssertFalse(NavSession.isRepeat(distanceM: 400, lastSaidM: nil))
        XCTAssertTrue(NavSession.isRepeat(distanceM: 395, lastSaidM: 400), "the same cue twice")
        XCTAssertFalse(NavSession.isRepeat(distanceM: 150, lastSaidM: 400))
        XCTAssertFalse(NavSession.isRepeat(distanceM: 70, lastSaidM: 150), "Mapbox's «now» after its 150 m cue (build 21: silenced)")
        XCTAssertTrue(NavSession.isRepeat(distanceM: 60, lastSaidM: 70))
    }

    /// Mapbox sends off-route, then the new route's first cue, then «rerouted»: the cue used to be
    /// judged against the OLD route and lost; the new route was silent until its next cue.
    func testARerouteSaysTheNewRoutesFirstManeuverAtOnce() async {
        let o = LngLat(lng: 46.6744, lat: 24.7113)
        func route(_ id: String, _ dir: NavTurnDirection) -> NavRoute {
            let a = LngLat(lng: o.lng + 0.004, lat: o.lat), b = LngLat(lng: o.lng + 0.01, lat: o.lat)
            return NavRoute(id: id, coordinates: [o, a, b], distanceM: 1_000, durationS: 70, steps: [
                NavStep(maneuver: .init(kind: .depart, direction: nil), roadName: "العليا", location: o, distanceM: 400, durationS: 30),
                NavStep(maneuver: .init(kind: .turn, direction: dir), roadName: "التخصصي", location: a, distanceM: 600, durationS: 40),
                NavStep(maneuver: .init(kind: .arrive, direction: nil), roadName: nil, location: b, distanceM: 0, durationS: 0),
            ])
        }
        let engine = CueEngine()
        let n = NavSession(provider: ScriptedRouter([.success(NavRoutePlan(routes: [route("a", .right)]))]), makeEngine: { _ in engine })
        n.muted = true
        n.myFix = { DeviceFix(lat: o.lat, lng: o.lng, accuracy: 5, heading: 90, speed: 14, atMs: Date().timeIntervalSince1970 * 1000) }
        var lines: [String] = []
        n.voice.onSpoken = { lines.append($0) }
        n.autoStart(to: NavTarget(source: .destination, name: "الوجهة", position: LngLat(lng: o.lng + 0.01, lat: o.lat)))
        let deadline = Date().addingTimeInterval(3)
        while lines.isEmpty, Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
        n.handle(.progress(NavProgress(stepIndex: 1, distanceToManeuverM: 300, distanceRemainingM: 900, durationRemainingS: 60)))
        n.handle(.offRoute)
        let before = lines.count
        n.handle(.cue("القيادة باتجاه الشمال"))
        n.handle(.rerouted(route("b", .left)))
        let after = lines.dropFirst(before).filter { !$0.hasPrefix("خرجت") }
        XCTAssertEqual(after.count, 1, "\(lines)")
        XCTAssertEqual(after.first, "بعد ٤٠٠ متر، انعطف يسارًا إلى التخصصي", "the NEW route's turn (left), not the old one (right)")
        n.end()
    }
}

