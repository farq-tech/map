import XCTest
@testable import SaryAlbarq

/// The owner on a long straight road (build 21): one fork said four times («بعد كيلو ونص … امسك اليسار»,
/// «بعد كيلو …», «امسك اليسار امسك اليسار»). Replay: a 10 km highway at 108 km/h with two «keep left»
/// forks, Mapbox's voice instructions at 2000 / 1500 / 1000 / 400 / 60 m before each, a traffic
/// refresh and a reroute on the way — through the real `NavSession` (budget + playback) on a
/// virtual clock with a one-line speaker. The lines said are printed as `[replay]` for review.
@MainActor
final class NavPromptBudgetTests: XCTestCase {
    final class CueEngine: NavGuidanceEngine {
        var onEvent: (NavGuidanceEvent) -> Void = { _ in }
        func start(route: NavRoute, plan: NavRoutePlan, target: NavTarget) async throws {}
        func stop() {}
        func ingest(_ fix: DeviceFix) {}
    }

    struct Heard { var t: Double; var step: String; var toManeuverM: Double; var text: String; var clips: [String] }

    private let o = LngLat(lng: 46.60, lat: 24.80)

    /// East 8 km (King Fahd), a «keep left» that stays on it at 4 km, then a real fork left at 8 km
    /// onto the ring road (bending 35°), 2 km more. `from`: the route starts there (a reroute).
    private func highway(from s: Double = 0, id: String) -> (NavRoute, [Double]) {
        func east(_ m: Double) -> LngLat { LngLat(lng: o.lng + m / (111_320 * cos(o.lat * .pi / 180)), lat: o.lat) }
        var c: [LngLat] = []
        for m in stride(from: s, through: 8_000, by: 50) { c.append(east(m)) }
        let knee = east(8_000)
        for k in 1...40 {
            let m = Double(k) * 50, b = (90.0 - 35) * .pi / 180
            c.append(LngLat(lng: knee.lng + m * sin(b) / (111_320 * cos(o.lat * .pi / 180)), lat: knee.lat + m * cos(b) / 111_320))
        }
        var steps = [NavStep(maneuver: .init(kind: .depart, direction: nil), roadName: "طريق الملك فهد", location: c[0], distanceM: 0, durationS: 0)]
        var along: [Double] = [0]
        if s < 4_000 {
            steps.append(NavStep(maneuver: .init(kind: .fork, direction: .slightLeft), roadName: "طريق الملك فهد", location: east(4_000), distanceM: 4_000, durationS: 130))
            along.append(4_000)
        }
        steps.append(NavStep(maneuver: .init(kind: .fork, direction: .slightLeft), roadName: "الدائري الشمالي", location: knee, distanceM: 2_000, durationS: 70))
        along.append(8_000)
        steps.append(NavStep(maneuver: .init(kind: .arrive, direction: nil), roadName: nil, location: c.last!, distanceM: 0, durationS: 0))
        along.append(10_000)
        return (NavRoute(id: id, coordinates: c, distanceM: 10_000 - s, durationS: (10_000 - s) / 30, steps: steps), along)
    }

    func testTwoForksOnAHighwayAreSaidAtMostTwiceEachAndNeverRepeated() async throws {
        try XCTSkipIf(SaryVoiceCatalog.entries.isEmpty, "clips not in the test bundle")
        let v = 30.0
        var (route, along) = highway(id: "a")
        let engine = CueEngine()
        let n = NavSession(provider: ScriptedRouter([.success(NavRoutePlan(routes: [route]))]), makeEngine: { _ in engine })
        var x = 0.0
        n.myFix = { DeviceFix(lat: 24.8, lng: 46.6, accuracy: 5, heading: 90, speed: v, atMs: Date().timeIntervalSince1970 * 1000) }
        var waiting: NavLine?
        n.sayGuidance = { waiting = $0 }
        n.autoStart(to: NavTarget(source: .destination, name: "الوجهة", position: route.end!))
        let deadline = Date().addingTimeInterval(3)
        while n.phase != .guiding, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(n.phase, .guiding)

        var heard: [Heard] = []
        var busyUntil = -1.0
        var cuesDone = Set<String>()
        let cueAt: [Double] = [2_000, 1_500, 1_000, 400, 60]
        var refreshed = false, rerouted = false
        func stepIndex() -> Int { along.firstIndex { $0 > x + 1 } ?? along.count - 1 }
        func name(_ i: Int) -> String { route.steps[i].maneuver.kind == .arrive ? "arrive" : route.steps[i].roadName == "طريق الملك فهد" ? "fork1" : "fork2" }
        var t = 0.0
        while x < 9_950 {
            x = v * t
            /* Mapbox's traffic refresh of the same route (new id), then a reroute just before fork 2. */
            if !refreshed, x >= 5_000 { refreshed = true; (route, along) = highway(from: x, id: "b"); n.handle(.rerouted(route)) }
            if !rerouted, x >= 7_200 { rerouted = true; (route, along) = highway(from: x, id: "c"); n.handle(.rerouted(route)) }
            if Int(t * 10) % 10 == 0 {
                let i = stepIndex()
                n.handle(.progress(NavProgress(stepIndex: i, distanceToManeuverM: along[i] - x, distanceRemainingM: 10_000 - x, durationRemainingS: (10_000 - x) / v)))
                /* Each route (a refresh / reroute is a new one) gives its cues again; one per progress. */
                let due = cueAt.filter { along[i] - x <= $0 && !cuesDone.contains("\(route.id):\(name(i)):\($0)") }
                if !due.isEmpty {
                    for c in due { cuesDone.insert("\(route.id):\(name(i)):\(c)") }
                    n.handle(.cue(""))
                }
            }
            if t >= busyUntil, let w = waiting, (w.notBefore?.timeIntervalSince1970 ?? 0) <= t {
                waiting = nil
                let idx = Int(w.maneuverID?.split(separator: ":").last ?? "") ?? -1
                switch n.playback(w, choice: .sary) {
                case let .play(out):
                    busyUntil = t + 0.35 + SaryVoiceCatalog.duration(out.clips)
                    let i = idx >= 0 && idx < route.steps.count ? idx : stepIndex()
                    heard.append(Heard(t: t, step: name(i), toManeuverM: along[i] - x, text: out.text, clips: out.clips))
                case let .hold(l, s):
                    var h = l
                    h.notBefore = Date(timeIntervalSince1970: t + s)
                    h.heldS += s
                    waiting = h
                case .drop: break
                }
            }
            t += 0.1
        }
        for h in heard {
            print(String(format: "[replay] t=%6.1fs  %@  %5.0f m before  «%@»  [%@]", h.t, h.step, h.toManeuverM, h.text, h.clips.joined(separator: " ")))
        }
        let fork1 = heard.filter { $0.step == "fork1" }, fork2 = heard.filter { $0.step == "fork2" }
        XCTAssertLessThanOrEqual(fork1.count, 1, "a keep-left that stays on King Fahd: one short line at most")
        XCTAssertLessThanOrEqual(fork2.count, 2, "a real fork: one early, one final (refresh and reroute do not restart it)")
        XCTAssertGreaterThanOrEqual(fork2.count, 1, "the real fork is announced")
        XCTAssertTrue(fork2.last.map { $0.toManeuverM < 600 } ?? false, "and said near it")
        for g in [fork1, fork2] { XCTAssertEqual(Set(g.map(\.clips)).count, g.count, "never the same line twice: \(g.map(\.text))") }
        for h in heard { XCTAssertFalse(zip(h.clips, h.clips.dropFirst()).contains { $0 == $1 }, "a clip twice in a row: \(h.clips)") }
    }

    func testTheBudget() {
        let s = NavStep(maneuver: .init(kind: .fork, direction: .left), roadName: "الدائري", location: o, distanceM: 0, durationS: 0)
        var b = NavPromptBudget()
        XCTAssertEqual(NavPromptBudget.stage(distanceM: 1_500, speedMps: 30), .early)
        XCTAssertEqual(NavPromptBudget.stage(distanceM: 400, speedMps: 30), .final)
        XCTAssertEqual(NavPromptBudget.stage(distanceM: 300, speedMps: 14), .early)
        XCTAssertEqual(NavPromptBudget.stage(distanceM: 150, speedMps: 14), .final)
        XCTAssertTrue(b.allows(s, .early))
        b.note(s, .early, clips: ["dist_10", "mv_07"])
        XCTAssertFalse(b.allows(s, .early), "one early line")
        XCTAssertTrue(b.allows(s, .final))
        var moved = s
        moved.location = LngLat(lng: o.lng + 30 / 101_000, lat: o.lat)
        XCTAssertFalse(b.allows(moved, .early), "the same fork 30 m off after a reroute: still said")
        moved.location = LngLat(lng: o.lng + 120 / 101_000, lat: o.lat)
        XCTAssertTrue(b.allows(moved, .early), "a different maneuver")
        b.note(s, .final, clips: ["mv_07"])
        XCTAssertFalse(b.allows(s, .final))
        XCTAssertTrue(b.repeats(s, clips: ["mv_07"]))
        XCTAssertEqual(NavPromptBudget.tidy(["mv_07", "mv_07"]), ["mv_07"], "«امسك اليسار امسك اليسار»")
        XCTAssertEqual(NavPromptBudget.tidy(["dist_02", "mv_07", "turns_14", "mv_07"]), ["dist_02", "mv_07"], "no «وبعدها، <the same>»")
        XCTAssertEqual(NavPromptBudget.tidy(["dist_02", "turns_01", "turns_14", "turns_02"]), ["dist_02", "turns_01", "turns_14", "turns_02"])
    }

    func testSoftForks() {
        let prev = NavStep(maneuver: .init(kind: .depart, direction: nil), roadName: "طريق الملك فهد", location: o, distanceM: 0, durationS: 0)
        let same = NavStep(maneuver: .init(kind: .fork, direction: .slightLeft), roadName: "طريق الملك فهد", location: o, distanceM: 0, durationS: 0)
        let other = NavStep(maneuver: .init(kind: .fork, direction: .left), roadName: "الدائري", location: o, distanceM: 0, durationS: 0)
        XCTAssertTrue(NavPromptBudget.isSoft(same, previous: prev, bendDeg: 40), "same road")
        XCTAssertTrue(NavPromptBudget.isSoft(other, previous: prev, bendDeg: 12), "barely bends")
        XCTAssertFalse(NavPromptBudget.isSoft(other, previous: prev, bendDeg: 35))
        XCTAssertFalse(NavPromptBudget.isSoft(NavStep(maneuver: .init(kind: .turn, direction: .left), roadName: "طريق الملك فهد", location: o, distanceM: 0, durationS: 0), previous: prev, bendDeg: 5), "a turn is never soft")
        XCTAssertEqual(NavPromptBudget.softLine(same)?.clips, ["turns_10"], "«خلّك على اليسار.»")
        XCTAssertNil(NavPromptBudget.softLine(NavStep(maneuver: .init(kind: .fork, direction: .straight), roadName: nil, location: o, distanceM: 0, durationS: 0)))
    }
}
