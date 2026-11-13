import CoreLocation
import XCTest
@testable import SaryAlbarq

/// Build 21, a real drive in Riyadh: «بعد ١٠٠ متر لف يمين» at the turn itself. The harness drives
/// a car at a steady speed toward a right turn and asks for a cue at every distance the router
/// may ask (with the queue delays the voice really has), through the real `NavSession.playback`
/// and the real clip durations, and measures where the car is when the line ENDS.
@MainActor
final class NavPromptTimingTests: XCTestCase {
    private let start = LngLat(lng: 46.6744, lat: 24.7113)

    private func session(lengthM: Double = 3_000) -> NavSession {
        let end = LngLat(lng: start.lng + lengthM / 101_000, lat: start.lat)
        let route = NavRoute(id: "r", coordinates: [start, end], distanceM: lengthM, durationS: lengthM / 14, steps: [
            NavStep(maneuver: .init(kind: .depart, direction: nil), roadName: "طريق العليا", location: start, distanceM: lengthM, durationS: lengthM / 14),
            NavStep(maneuver: .init(kind: .turn, direction: .right), roadName: "شارع التحلية", location: end, distanceM: 400, durationS: 30),
            NavStep(maneuver: .init(kind: .arrive, direction: nil), roadName: nil, location: end, distanceM: 0, durationS: 0),
        ])
        let n = NavSession(provider: ScriptedRouter([.success(NavRoutePlan(routes: [route]))]), makeEngine: { _ in LocalGuidanceEngine() })
        n.debugSet(phase: .guiding, target: NavTarget(source: .destination, name: "مخيم", position: end), routes: [route], progress: nil, offRoad: nil)
        return n
    }

    /// The «بعد …» metres in a line of clips (nil: the action alone).
    private func saidM(_ clips: [String]) -> Double? {
        SaryVoiceScript.distances.first { clips.contains($0.key) }?.m
    }

    struct Outcome { var cueM: Double; var queueS: Double; var said: Double?; var endM: Double }

    /// One cue: asked at `cueM`, waits `queueS` in the voice queue, the last progress is `ageS` old,
    /// the line really starts `latencyS` after «play».
    private func drive(_ n: NavSession, cueM: Double, queueS: Double, ageS: Double, latencyS: Double, v: Double) -> Outcome? {
        n.myFix = { DeviceFix(lat: 24.7113, lng: 46.6744, accuracy: 5, heading: 90, speed: v, atMs: Date().timeIntervalSince1970 * 1000) }
        guard let line = n.guidanceLine(stepIndex: 1, distanceM: cueM, force: true) else { return nil }
        var dPlay = cueM - v * queueS
        n.handle(.progress(NavProgress(stepIndex: 1, distanceToManeuverM: dPlay + v * ageS, distanceRemainingM: dPlay + 400, durationRemainingS: 60)))
        var result = n.playback(line, choice: .sary, now: Date().addingTimeInterval(ageS))
        while case let .hold(held, s) = result {
            dPlay -= v * (s + 0.02)
            var h = held
            h.notBefore = Date()
            h.heldS += s
            n.handle(.progress(NavProgress(stepIndex: 1, distanceToManeuverM: dPlay + v * ageS, distanceRemainingM: dPlay + 400, durationRemainingS: 60)))
            result = n.playback(h, choice: .sary, now: Date().addingTimeInterval(ageS))
        }
        guard case let .play(out) = result else { return nil }
        let end = dPlay - v * (latencyS + SaryVoiceCatalog.duration(out.clips))
        return Outcome(cueM: cueM, queueS: queueS, said: saidM(out.clips), endM: end)
    }

    /// Build 21's rule, for the before/after numbers: the distance fixed when the cue was asked,
    /// rounded to the nearest clip, said after the queue.
    private func build21(cueM: Double, queueS: Double, latencyS: Double, v: Double) -> Outcome {
        let r = NavText.roundedMeters(cueM)
        let said = cueM < 30 ? nil : SaryVoiceScript.distances.min { abs($0.m - r) < abs($1.m - r) }?.m
        let clips = (said.flatMap { m in SaryVoiceScript.distances.first { $0.m == m }?.key }.map { [$0] } ?? []) + ["turns_01"]
        return Outcome(cueM: cueM, queueS: queueS, said: said, endM: cueM - v * (queueS + latencyS + SaryVoiceCatalog.duration(clips)))
    }

    func testAt50KmhTheSpokenDistanceIsNeverLargerAndWithin15m() throws {
        try XCTSkipIf(SaryVoiceCatalog.entries.isEmpty, "clips not in the test bundle")
        let v = 50 / 3.6
        var after: [Outcome] = [], before: [Outcome] = []
        for cue in stride(from: 45.0, through: 1_000, by: 5) {
            for q in [0.0, 0.5, 1.0, 2.0, 3.0] {
                for (age, lat) in [(0.0, 0.35), (0.5, 0.2), (0.9, 0.5)] {
                    let n = session()
                    if let o = drive(n, cueM: cue, queueS: q, ageS: age, latencyS: lat, v: v) { after.append(o) }
                    before.append(build21(cueM: cue, queueS: q, latencyS: lat, v: v))
                }
            }
        }
        func report(_ name: String, _ os: [Outcome]) -> (over: Int, maxOver: Double, maxErr: Double) {
            let spoken = os.filter { $0.said != nil }
            let over = spoken.filter { $0.said! > $0.endM + 0.5 }
            let maxOver = over.map { $0.said! - $0.endM }.max() ?? 0
            let maxErr = spoken.filter { $0.cueM <= 1_000 }.map { abs($0.endM - $0.said!) }.max() ?? 0
            print("[prompt-timing] \(name): \(os.count) cues • overstated \(over.count) (worst +\(Int(maxOver)) m) • max |error| \(Int(maxErr)) m")
            return (over.count, maxOver, maxErr)
        }
        let b = report("build 21", before)
        let a = report("build 22", after)
        XCTAssertGreaterThan(b.over, 0, "the harness reproduces the field report")
        XCTAssertEqual(a.over, 0, "never a distance larger than the real one when the line ends")
        XCTAssertLessThanOrEqual(a.maxErr, 15, "the line ends within 15 m of the distance it says")
        /* The immediate phrase only when the turn is right there, never past it. */
        for o in after where o.said == nil {
            XCTAssertLessThan(o.endM, 2 * NavPromptTiming.immediateM + 1.5 * v, "«لف يمين» alone only near the turn (cue \(o.cueM) m, queue \(o.queueS) s)")
        }
        /* The field report itself: a cue asked ~100 m before the turn, 2 s in the queue. */
        let field = try XCTUnwrap(drive(session(), cueM: 100, queueS: 2, ageS: 0.5, latencyS: 0.35, v: 60 / 3.6))
        XCTAssertNil(field.said, "at 60 km/h, 100 m and 2 s late: «لف يمين», not «بعد مية متر»")
    }

    func testImmediatePhraseUnder40mOr3s() {
        let band = NavPromptTiming.band(.sary, miles: false)
        let dur: (Double?) -> Double = { $0 == nil ? 0.8 : 1.8 }
        XCTAssertNil(NavPromptTiming.plan(distanceNowM: 38, speedMps: 2, latencyS: 0.35, canHold: false, band: band, duration: dur).spokenM, "under 40 m")
        XCTAssertNil(NavPromptTiming.plan(distanceNowM: 90, speedMps: 22, latencyS: 0.35, canHold: false, band: band, duration: dur).spokenM,
                     "80 km/h: 90 m now is under 3 s when the line ends")
        let p = NavPromptTiming.plan(distanceNowM: 120, speedMps: 10, latencyS: 0.35, canHold: false, band: band, duration: dur)
        XCTAssertEqual(p.spokenM, 50, "120 m − 21.5 m (latency + line) = 98.5 → «بعد خمسين», never «بعد مية»")
        XCTAssertGreaterThanOrEqual(p.endM, p.spokenM!)
        /* Parked / no speed: the distance now, rounded down. */
        XCTAssertEqual(NavPromptTiming.plan(distanceNowM: 140, speedMps: nil, latencyS: 0.35, canHold: true, band: band, duration: dur).spokenM, 100)
    }

    func testAHeldLineEndsAtTheDistanceItSays() {
        let band = NavPromptTiming.band(.sary, miles: false)
        let p = NavPromptTiming.plan(distanceNowM: 190, speedMps: 14, latencyS: 0.35, canHold: true, band: band) { $0 == nil ? 0.8 : 1.8 }
        /* 190 − 14 × 2.15 = 160 → «بعد مية وخمسين» is 10 m off: said now. */
        XCTAssertEqual(p.spokenM, 150)
        XCTAssertEqual(p.holdS, 0)
        let q = NavPromptTiming.plan(distanceNowM: 140, speedMps: 14, latencyS: 0.35, canHold: true, band: band) { $0 == nil ? 0.8 : 1.8 }
        /* 140 → ends at 110 → «بعد مية» at once. */
        XCTAssertEqual(q.spokenM, 100)
        let h = NavPromptTiming.plan(distanceNowM: 125, speedMps: 14, latencyS: 0.35, canHold: true, band: band) { $0 == nil ? 0.8 : 1.8 }
        /* 125 → ends at 95 → 50 is 45 m low: held ~2.5 s so it ends at ~60 m. */
        XCTAssertEqual(h.spokenM, 50)
        XCTAssertGreaterThan(h.holdS, 2)
        XCTAssertLessThanOrEqual(h.endM - 50, NavPromptTiming.maxErrorM)
        XCTAssertGreaterThanOrEqual(h.endM, 50)
    }

    func testSpokenDistancesRoundDown() {
        XCTAssertEqual(SaryVoiceScript.distance(75, miles: false), "dist_01", "75 m: «بعد خمسين», never «بعد مية»")
        XCTAssertEqual(SaryVoiceScript.distance(99, miles: false), "dist_01")
        XCTAssertEqual(SaryVoiceScript.distance(100, miles: false), "dist_02")
        XCTAssertEqual(SaryVoiceScript.distance(48, miles: false), "m_07")
        XCTAssertEqual(SaryVoiceScript.distance(380, miles: false), "dist_05")
        XCTAssertEqual(SaryVoiceScript.distance(980, miles: false), "m_05")
        XCTAssertEqual(NavText.spokenInDistance(75), "بعد ٧٠ متر")
        XCTAssertEqual(NavText.spokenInDistance(380), "بعد ٣٥٠ متر")
        XCTAssertEqual(NavText.spokenInDistance(1_990), "بعد ١٫٩ كيلومتر")
        /* The banner still rounds to the nearest (it is read, not heard late). */
        XCTAssertEqual(NavText.distance(75), "٨٠ م")
    }

    func testAPassedManeuverIsNotSaid() throws {
        let n = session()
        let line = try XCTUnwrap(n.guidanceLine(stepIndex: 1, distanceM: 200, force: true))
        n.handle(.progress(NavProgress(stepIndex: 2, distanceToManeuverM: 380, distanceRemainingM: 380, durationRemainingS: 30)))
        XCTAssertEqual(n.playback(line, choice: .sary), .drop)
    }

    func testTheLeadOfAStartLineIsKept() throws {
        let n = session()
        let first = try XCTUnwrap(n.guidanceLine(stepIndex: 1, distanceM: 600, force: true))
        let line = NavLine("نبدأ التوجيه", clips: ["start_01"]) + first
        n.myFix = { DeviceFix(lat: 24.7113, lng: 46.6744, accuracy: 5, heading: 90, speed: 0, atMs: Date().timeIntervalSince1970 * 1000) }
        n.handle(.progress(NavProgress(stepIndex: 1, distanceToManeuverM: 590, distanceRemainingM: 990, durationRemainingS: 60)))
        guard case let .play(out) = n.playback(line, choice: .sary) else { return XCTFail("played") }
        XCTAssertEqual(out.clips, ["start_01", "dist_07", "turns_01"], "«بسم الله نبدأ.» «بعد خمس مية متر.» «لف يمين.»")
        XCTAssertTrue(out.text.hasPrefix("نبدأ التوجيه"))
    }

    func testGuidanceAsksTheChipForNavigationAccuracy() {
        /* Build 21: the SDK's own manager was left at kCLLocationAccuracyBest / .other. */
        let m = MapboxNavLocation.shared.manager
        XCTAssertEqual(m.desiredAccuracy, kCLLocationAccuracyBestForNavigation)
        XCTAssertEqual(m.activityType, .automotiveNavigation)
        XCTAssertEqual(m.distanceFilter, kCLDistanceFilterNone)
        XCTAssertFalse(m.pausesLocationUpdatesAutomatically)
    }

    func testTheMapDotIsTheSmoothedFixWhenNotGuiding() {
        let n = session()
        let f = DeviceFix(lat: 24.7113, lng: 46.6744, accuracy: 5, heading: 90, speed: 10, atMs: Date().timeIntervalSince1970 * 1000)
        XCTAssertEqual(n.mapFix(f), f, "no matched position yet: the app's own fix")
    }
}
