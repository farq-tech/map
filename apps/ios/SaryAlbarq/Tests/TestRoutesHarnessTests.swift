import XCTest
@testable import SaryAlbarq

// MARK: - Shared drive scenarios (`Tests/TestRoutes/`)
//
// Each scenario is a pair of files in `Tests/TestRoutes/` (bundled as one folder):
//   * `<name>.gpx`  — the drive: `<trkpt lat lon><time>` points (Riyadh roads from Mapbox
//     Directions geometry, or a synthetic sand track). Also usable in Xcode / `simctl location`.
//   * `<name>.json` — the route and what must happen:
//       {
//         "name", "description", "gpx", "unpaved": Bool,
//         "maneuvers": [ { "kind": NavManeuverKind raw value, "direction": NavTurnDirection raw value | null,
//                          "lat", "lng", "distanceM": the step after it } ],   // depart … arrive
//         "expect": {
//           "speedKmh": optional, informative,
//           "prompts": { "neverOverstate": Bool, "maxErrorM": m | null, "immediateBelowM": m,
//                        "announceIfApproachM": every maneuver with at least this approach gets a line },
//           "arrival": { "withinM": m }
//         },
//         "events": [ ... ]   // scenario events, applied by `ScenarioDrive.apply` (add yours there)
//       }
//   Events understood today: {"type": "stop", "atS": s, "durationS": s} (parked: no movement, speed 0).
//   Others ("offline", "offRoute" …) are for the next scenarios: an unknown type fails the test,
//   so a new scenario never passes silently without its event being implemented.
//
// The drive runs through the REAL pipeline: fixes → `NavSession.ingest` → `LocalGuidanceEngine`
// (cues by speed band) → `NavSession.guidanceLine` → `NavSession.playback` (the voice's
// moment-of-playback decision, `NavPromptTiming`), on a virtual clock with a one-line speaker
// (start latency + the real clip durations). Truth is the GPX position when each line ENDS.

struct ScenarioFile: Decodable {
    struct Maneuver: Decodable { var kind: String; var direction: String?; var lat: Double; var lng: Double; var distanceM: Double }
    struct Prompts: Decodable { var neverOverstate: Bool; var maxErrorM: Double?; var immediateBelowM: Double; var announceIfApproachM: Double }
    struct Arrival: Decodable { var withinM: Double }
    struct Expect: Decodable { var speedKmh: Double?; var prompts: Prompts; var arrival: Arrival }
    struct Event: Decodable { var type: String; var atS: Double?; var durationS: Double? }
    var name: String
    var description: String
    var gpx: String
    var unpaved: Bool
    var maneuvers: [Maneuver]
    var expect: Expect
    var events: [Event]
}

@MainActor
enum ScenarioDrive {
    static var folder: URL? {
        Bundle(for: TestRoutesHarnessTests.self).url(forResource: "TestRoutes", withExtension: nil)
    }

    static func all() throws -> [ScenarioFile] {
        guard let dir = folder else { return [] }
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        return try files.sorted { $0.lastPathComponent < $1.lastPathComponent }.map { try JSONDecoder().decode(ScenarioFile.self, from: Data(contentsOf: $0)) }
    }

    /// (position, seconds from the first point) from a GPX track.
    static func track(_ name: String) throws -> [(p: LngLat, t: Double)] {
        let s = try String(contentsOf: XCTUnwrap(folder).appendingPathComponent(name), encoding: .utf8)
        let rx = try NSRegularExpression(pattern: #"<trkpt lat="([-0-9.]+)" lon="([-0-9.]+)"><time>([^<]+)</time>"#)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var out: [(LngLat, Double)] = []
        var t0: Date?
        for m in rx.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
            func g(_ i: Int) -> String { String(s[Range(m.range(at: i), in: s)!]) }
            let d = try XCTUnwrap(iso.date(from: g(3)))
            if t0 == nil { t0 = d }
            out.append((LngLat(lng: Double(g(2))!, lat: Double(g(1))!), d.timeIntervalSince(t0!)))
        }
        return out
    }

    static func route(_ f: ScenarioFile, coords: [LngLat]) -> NavRoute {
        let steps = f.maneuvers.map { m in
            NavStep(maneuver: NavManeuver(kind: NavManeuverKind(rawValue: m.kind) ?? .turn, direction: m.direction.flatMap(NavTurnDirection.init(rawValue:))),
                    roadName: nil, location: LngLat(lng: m.lng, lat: m.lat), distanceM: m.distanceM, durationS: m.distanceM / 12)
        }
        let cum = LocalGuidanceEngine.cumulative(coords)
        return NavRoute(id: f.name, coordinates: coords, distanceM: cum.last ?? 0, durationS: (cum.last ?? 0) / 12, steps: steps, hasUnpaved: f.unpaved, hasTolls: false, via: nil)
    }
}

@MainActor
final class TestRoutesHarnessTests: XCTestCase {
    struct Said { var step: Int; var spokenM: Double?; var endTrueM: Double; var speed: Double; var soft = false }

    /// One scenario on the virtual clock. Returns the lines played and the arrival miss (nil: never arrived).
    private func run(_ f: ScenarioFile) async throws -> (said: [Said], announced: Set<Int>, silent: Set<Int>, arrivalMissM: Double?) {
        let pts = try ScenarioDrive.track(f.gpx)
        let r = ScenarioDrive.route(f, coords: pts.map(\.p))
        let cum = LocalGuidanceEngine.cumulative(r.coordinates)
        let stepAlong = r.steps.map { LocalGuidanceEngine.along(of: $0.location, in: r.coordinates, cum: cum) }
        let engine = LocalGuidanceEngine()
        let n = NavSession(provider: ScriptedRouter([.success(NavRoutePlan(routes: [r]))]), makeEngine: { _ in engine })
        n.muted = true

        /* Virtual clock: where the car is at `t` (GPX interpolation), stops applied. */
        var stops: [(at: Double, dur: Double)] = []
        for e in f.events {
            switch e.type {
            case "stop": stops.append((e.atS ?? 0, e.durationS ?? 0))
            default: XCTFail("\(f.name): event «\(e.type)» is not implemented in ScenarioDrive yet")
            }
        }
        func driveTime(_ t: Double) -> Double {
            var d = t
            for s in stops where t > s.at { d -= min(s.dur, t - s.at) }
            return d
        }
        func state(_ t: Double) -> (p: LngLat, along: Double, v: Double, course: Double) {
            let tt = driveTime(t)
            let i = max(0, (pts.lastIndex { $0.t <= tt } ?? 0))
            let j = min(pts.count - 1, i + 1)
            let span = max(0.001, pts[j].t - pts[i].t)
            let u = i == j ? 0 : min(1, max(0, (tt - pts[i].t) / span))
            let p = LngLat(lng: pts[i].p.lng + (pts[j].p.lng - pts[i].p.lng) * u, lat: pts[i].p.lat + (pts[j].p.lat - pts[i].p.lat) * u)
            let moving = driveTime(t + 0.5) - driveTime(t - 0.5) > 0.5
            let v = moving && i != j ? (cum[j] - cum[i]) / span : 0
            return (p, cum[i] + (cum[j] - cum[i]) * u, v, i == j ? 0 : Vehicle.bearing(pts[i].p, pts[j].p))
        }
        var now = state(0)
        func fix(_ s: (p: LngLat, along: Double, v: Double, course: Double)) -> DeviceFix {
            DeviceFix(lat: s.p.lat, lng: s.p.lng, accuracy: 5, heading: s.course, speed: s.v, atMs: Date().timeIntervalSince1970 * 1000, speedAccuracy: 0.5, courseAccuracy: 5)
        }
        n.myFix = { fix(now) }
        n.autoStart(to: NavTarget(source: .destination, name: "الوجهة", position: try XCTUnwrap(r.end)))
        let deadline = Date().addingTimeInterval(3)
        while n.phase != .guiding, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(n.phase, .guiding, f.name)
        /* Soft maneuvers that go straight on are not announced at all (`NavPromptBudget`). */
        let silent = Set(r.steps.indices.filter { n.isSoft($0) && NavPromptBudget.softLine(r.steps[$0]) == nil })

        /* The voice queue, on the virtual clock: one line playing, one waiting (as `NavVoice`). */
        var waiting: NavLine?
        var busyUntil = -1.0
        var said: [Said] = []
        var announced = Set<Int>()
        var plays: [(start: Double, end: Double, step: Int, spokenM: Double?)] = []
        let orig = engine.onEvent
        engine.onEvent = { ev in
            if case let .speak(t) = ev, let i = t.maneuverID.flatMap(Int.init) {
                if let line = n.guidanceLine(stepIndex: i, distanceM: n.progress?.distanceToManeuverM ?? 0) { waiting = line }
            } else {
                orig(ev)
            }
        }
        let latency = NavPromptTiming.startLatencyS(.sary)
        let endT = (pts.last?.t ?? 0) + stops.reduce(0) { $0 + $1.dur } + 20
        var t = 0.0
        var arrivalMiss: Double?
        while t < endT, n.phase == .guiding {
            now = state(t)
            n.ingest(fix(now))
            if n.phase == .arrived || n.phase == .offRoad { arrivalMiss = max(0, (cum.last ?? 0) - now.along); break }
            /* A held line carries its virtual release time in `notBefore` (seconds since the start). */
            if t >= busyUntil, let w = waiting, (w.notBefore?.timeIntervalSince1970 ?? 0) <= t {
                do {
                    waiting = nil
                    let decision = n.playback(w, choice: .sary)
                    if ProcessInfo.processInfo.environment["SARY_ROUTES_TRACE"] != nil {
                        print("[trace] \(f.name) t=\(String(format: "%.1f", t)) id=\(w.maneuverID ?? "-") held=\(w.notBefore != nil) progress=\(n.progress.map { "\($0.stepIndex):\(Int($0.distanceToManeuverM))" } ?? "-") → \(decision)")
                    }
                    switch decision {
                    case let .play(out):
                        let id = Int(out.maneuverID?.split(separator: ":").last ?? "") ?? -1
                        let dur = SaryVoiceCatalog.duration(out.clips)
                        busyUntil = t + latency + dur
                        let spoken = SaryVoiceScript.distances.first { out.clips.contains($0.key) }?.m
                        plays.append((t, busyUntil, id, spoken))
                        announced.insert(id)
                    case let .hold(l, s):
                        var h = l
                        h.notBefore = Date(timeIntervalSince1970: t + s)
                        h.heldS += s
                        waiting = h
                    case .drop:
                        break
                    }
                }
            }
            /* Truth when a line ends. */
            for k in plays.indices.reversed() where plays[k].end <= t && plays[k].end > t - 0.1 {
                let p = plays[k]
                let trueM = (p.step < stepAlong.count ? stepAlong[p.step] : (cum.last ?? 0)) - now.along
                said.append(Said(step: p.step, spokenM: p.spokenM, endTrueM: trueM, speed: now.v, soft: n.isSoft(p.step)))
            }
            t += 0.1
        }
        n.end()
        return (said, announced, silent, arrivalMiss)
    }

    func testEveryScenarioInTestRoutes() async throws {
        try XCTSkipIf(SaryVoiceCatalog.entries.isEmpty, "clips not in the test bundle")
        let all = try ScenarioDrive.all()
        XCTAssertGreaterThanOrEqual(all.count, 3, "Tests/TestRoutes is bundled (city, highway, desert)")
        for f in all {
            let res = try await run(f)
            let e = f.expect
            let spoken = res.said.filter { $0.spokenM != nil }
            let over = spoken.filter { $0.spokenM! > $0.endTrueM + 0.5 }
            let maxErr = spoken.map { abs($0.endTrueM - $0.spokenM!) }.max() ?? 0
            print("[routes] \(f.name): \(res.said.count) lines (\(spoken.count) with a distance) · overstated \(over.count) · max |error| \(Int(maxErr)) m · arrival miss \(res.arrivalMissM.map { "\(Int($0)) m" } ?? "never")")
            if e.prompts.neverOverstate {
                XCTAssertTrue(over.isEmpty, "\(f.name): said more than the real distance: \(over.map { "step \($0.step) said \(Int($0.spokenM!)) at \(Int($0.endTrueM))" })")
            }
            for s in spoken where abs(s.endTrueM - s.spokenM!) > (e.prompts.maxErrorM ?? .infinity) {
                print("[routes]   \(f.name) step \(s.step): said \(Int(s.spokenM!)) m, ended at \(Int(s.endTrueM)) m, \(Int(s.speed * 3.6)) km/h")
            }
            if let m = e.prompts.maxErrorM {
                XCTAssertLessThanOrEqual(maxErr, m, "\(f.name): a line ended more than \(Int(m)) m before the distance it said")
            }
            for s in res.said where s.spokenM == nil && !s.soft {
                XCTAssertLessThan(s.endTrueM, 2 * e.prompts.immediateBelowM + 1.5 * s.speed, "\(f.name): the action alone, far from step \(s.step)")
            }
            /* Every maneuver with a real approach got at least one line. */
            for i in 1..<f.maneuvers.count where f.maneuvers[i - 1].distanceM >= e.prompts.announceIfApproachM && f.maneuvers[i].kind != "arrive" && !res.silent.contains(i) {
                XCTAssertTrue(res.announced.contains(i), "\(f.name): maneuver \(i) (\(f.maneuvers[i].kind) \(f.maneuvers[i].direction ?? "")) never announced")
            }
            let miss = try XCTUnwrap(res.arrivalMissM, "\(f.name): never arrived")
            XCTAssertLessThanOrEqual(miss, e.arrival.withinM, "\(f.name): arrival")
        }
    }
}
