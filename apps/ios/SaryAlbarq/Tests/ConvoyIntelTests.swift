import XCTest
@testable import SaryAlbarq

/// Build 9 stage B — convoy intelligence (Core/ConvoyWatch.swift).
final class ConvoyIntelTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)
    private let leader = Geo.LatLng(lat: 24.70, lng: 46.70)

    /// `km` north of the leader.
    private func north(_ km: Double) -> Geo.LatLng { Geo.LatLng(lat: 24.70 + km / 111.2, lng: 46.70) }

    private func car(_ id: String, _ p: Geo.LatLng, _ kmh: Double? = 60, live: Bool = true, me: Bool = false) -> ConvoyWatch.Car {
        .init(id: id, position: p, speedKmh: kmh, live: live, isMe: me)
    }

    func testLeaderIsTheConvoyLeadElseTheOwner() {
        XCTAssertEqual(ConvoyLeader.id(convoy: nil, ownerId: "o"), "o")
        XCTAssertEqual(ConvoyLeader.id(convoy: ConvoyInfo(lead_user_id: "l", tail_user_id: nil, max_gap_m: nil), ownerId: "o"), "l")
        XCTAssertEqual(ConvoyLeader.id(convoy: ConvoyInfo(lead_user_id: nil, tail_user_id: "t", max_gap_m: nil), ownerId: "o"), "o")
        XCTAssertEqual(ConvoyLeader.title(convoy: nil), "أمير الطلعة")
        XCTAssertEqual(ConvoyLeader.title(convoy: ConvoyInfo(lead_user_id: "l", tail_user_id: nil, max_gap_m: nil)), "المقدمة")
    }

    func testSeparationWaitsForTheGracePeriodThenClearsWithHysteresis() {
        var w = ConvoyWatch()
        let s = ConvoyAlertSettings()
        let ctx = ConvoyWatch.Context(leaderId: "L")
        func tick(_ km: Double, _ t: TimeInterval, live: Bool = true) -> (fire: [ConvoyWatch.Alert], clear: [String]) {
            w.ingest([car("L", leader), car("a", north(km), live: live)], context: ctx, settings: s, now: base.addingTimeInterval(t))
        }
        XCTAssertTrue(tick(2.5, 0).fire.isEmpty, "far, but the grace period runs")
        XCTAssertTrue(tick(2.5, 59).fire.isEmpty)
        let r = tick(2.5, 61)
        XCTAssertEqual(r.fire.map(\.key), ["convoy:sep:a"])
        XCTAssertTrue(tick(2.6, 120).fire.isEmpty, "no spam: reminder only after 5 min")
        XCTAssertTrue(tick(1.9, 150).clear.isEmpty, "just under the threshold: hysteresis holds it")
        XCTAssertEqual(tick(1.5, 160).clear, ["convoy:sep:a"], "well back: cleared")
        XCTAssertTrue(tick(2.5, 170).fire.isEmpty)
        XCTAssertTrue(tick(2.5, 240).fire.isEmpty, "back over: grace again, and quiet after a clear")
        XCTAssertEqual(tick(2.5, 300).fire.map(\.key), ["convoy:sep:a"])
    }

    func testStalePositionsNeverAlert() {
        var w = ConvoyWatch()
        let s = ConvoyAlertSettings()
        let ctx = ConvoyWatch.Context(leaderId: "L")
        for t in stride(from: 0.0, through: 600, by: 30) {
            let r = w.ingest([car("L", leader), car("a", north(9), live: false)], context: ctx, settings: s, now: base.addingTimeInterval(t))
            XCTAssertTrue(r.fire.isEmpty)
        }
        /* The leader stale: nothing can be measured. */
        for t in stride(from: 0.0, through: 600, by: 30) {
            let r = w.ingest([car("L", leader, live: false), car("b", north(9))], context: ctx, settings: s, now: base.addingTimeInterval(700 + t))
            XCTAssertTrue(r.fire.isEmpty)
        }
    }

    func testSeparationOffOrThresholdTuned() {
        var s = ConvoyAlertSettings()
        s.separationOn = false
        var w = ConvoyWatch()
        let ctx = ConvoyWatch.Context(leaderId: "L")
        for t in stride(from: 0.0, through: 300, by: 30) {
            XCTAssertTrue(w.ingest([car("L", leader), car("a", north(8))], context: ctx, settings: s, now: base.addingTimeInterval(t)).fire.isEmpty)
        }
        s.separationOn = true
        s.separationKm = 10
        for t in stride(from: 0.0, through: 300, by: 30) {
            XCTAssertTrue(w.ingest([car("L", leader), car("a", north(8))], context: ctx, settings: s, now: base.addingTimeInterval(400 + t)).fire.isEmpty, "8 km < 10 km")
        }
    }

    func testUnexpectedStop() {
        var w = ConvoyWatch()
        let s = ConvoyAlertSettings()
        let ctx = ConvoyWatch.Context(leaderId: "L")
        let spot = north(0.5)
        func tick(_ kmh: Double, _ t: TimeInterval, groupKmh: Double = 70) -> (fire: [ConvoyWatch.Alert], clear: [String]) {
            w.ingest([car("L", leader, groupKmh), car("a", spot, kmh)], context: ctx, settings: s, now: base.addingTimeInterval(t))
        }
        _ = tick(80, 0)
        _ = tick(0, 30)
        XCTAssertNotNil(w.stoppedSince("a"))
        XCTAssertTrue(tick(0, 200).fire.isEmpty, "under 3 min")
        XCTAssertEqual(tick(0, 211).fire.map(\.key), ["convoy:stop:a"])
        XCTAssertTrue(tick(0, 400).fire.isEmpty, "said once")
        XCTAssertTrue(tick(6, 420).clear.isEmpty, "creeping: still the same stop")
        XCTAssertEqual(tick(40, 440).clear, ["convoy:stop:a"], "moving again: taken down")
        XCTAssertNil(w.stoppedSince("a"))
    }

    func testStopIsExpectedWhenTheGroupStopsOrAtAKnownPlace() {
        let s = ConvoyAlertSettings()
        var w = ConvoyWatch()
        let ctx = ConvoyWatch.Context(leaderId: "L")
        _ = w.ingest([car("L", leader, 80), car("a", north(1), 80)], context: ctx, settings: s, now: base)
        for t in stride(from: 30.0, through: 600, by: 30) {
            let r = w.ingest([car("L", leader, 0), car("a", north(1), 0)], context: ctx, settings: s, now: base.addingTimeInterval(t))
            XCTAssertTrue(r.fire.isEmpty, "everyone stopped: a break, not an alarm")
        }
        var w2 = ConvoyWatch()
        let rally = north(1)
        let ctx2 = ConvoyWatch.Context(leaderId: "L", knownStops: [Geo.LatLng(lat: rally.lat + 0.001, lng: rally.lng)])
        _ = w2.ingest([car("L", leader, 80), car("a", rally, 80)], context: ctx2, settings: s, now: base)
        for t in stride(from: 30.0, through: 600, by: 30) {
            XCTAssertTrue(w2.ingest([car("L", leader, 80), car("a", rally, 0)], context: ctx2, settings: s, now: base.addingTimeInterval(t)).fire.isEmpty,
                          "at the rally point")
        }
        var w3 = ConvoyWatch()
        for t in stride(from: 0.0, through: 600, by: 30) {
            XCTAssertTrue(w3.ingest([car("L", leader, 80), car("a", north(1), 0)], context: ctx, settings: s, now: base.addingTimeInterval(t)).fire.isEmpty,
                          "never seen driving: parked, not a sudden stop")
        }
    }

    func testMyOwnStopDoesNotAlertMe() {
        var w = ConvoyWatch()
        let ctx = ConvoyWatch.Context(leaderId: "L")
        _ = w.ingest([car("L", leader, 80), car("me", north(1), 80, me: true)], context: ctx, settings: ConvoyAlertSettings(), now: base)
        for t in stride(from: 30.0, through: 600, by: 30) {
            XCTAssertTrue(w.ingest([car("L", leader, 80), car("me", north(1), 0, me: true)], context: ctx, settings: ConvoyAlertSettings(),
                                   now: base.addingTimeInterval(t)).fire.isEmpty)
        }
    }

    func testSettingsClampAndPersist() {
        var s = ConvoyAlertSettings()
        s.separationKm = 99
        s.stopMinutes = 0
        s.silentMinutes = 17
        s.behindTailGraceS = -5
        let c = s.clamped()
        XCTAssertEqual(c.separationKm, 10)
        XCTAssertEqual(c.stopMinutes, 1)
        XCTAssertEqual(c.silentMinutes, 10)
        XCTAssertEqual(c.behindTailGraceS, 0)
        let d = ConvoyAlertSettings()
        XCTAssertEqual(d.separationKm, 2)
        XCTAssertEqual(d.separationGraceS, 60)
        XCTAssertEqual(d.stopMinutes, 3)
        XCTAssertTrue(d.stopOn && d.separationOn && d.silentOn && d.behindTailOn)
        XCTAssertEqual(d.behindTailGraceS, 0, "the existing alert keeps its old timing by default")
    }

    @MainActor
    func testPrefsRoundTrip() {
        let ud = UserDefaults(suiteName: "convoy-test-\(UUID().uuidString)")!
        let a = ConvoyAlertPrefs(defaults: ud)
        a.settings.stopMinutes = 7
        XCTAssertEqual(ConvoyAlertPrefs(defaults: ud).settings.stopMinutes, 7)
    }

    func testGraceFilter() {
        var g = GraceFilter()
        XCTAssertTrue(g.pass(["k"], grace: 30, now: base).isEmpty)
        XCTAssertEqual(g.pass(["k"], grace: 30, now: base.addingTimeInterval(31)), ["k"])
        XCTAssertTrue(g.pass([], grace: 30, now: base.addingTimeInterval(32)).isEmpty)
        XCTAssertTrue(g.pass(["k"], grace: 30, now: base.addingTimeInterval(33)).isEmpty, "restarts after it cleared")
        XCTAssertEqual(g.pass(["k"], grace: 0, now: base.addingTimeInterval(34)), ["k"])
    }

    func testRecallNoteAndPriority() {
        XCTAssertTrue(RallyRecall.isRecall(RallyRecall.noteText))
        XCTAssertFalse(RallyRecall.isRecall("ارجعوا"))
        let stop = ConvoyAlertUI(kind: .unexpectedStop, userId: "a", name: "فهد", color: 0, meters: 0, minutes: 4)
        XCTAssertEqual(AlertPriority(.convoy(stop)), .silent, "a sudden stop is as urgent as a silent car")
        XCTAssertEqual(stop.title, "فهد وقف فجأة")
        XCTAssertEqual(stop.detail, "واقف منذ ٤ د والمجموعة تتحرك")
        let sep = ConvoyAlertUI(kind: .separated, userId: "a", name: "فهد", color: 0, meters: 2600, otherName: "سلطان", leaderTitle: "المقدمة")
        XCTAssertEqual(AlertPriority(.convoy(sep)), .convoy)
        XCTAssertEqual(sep.title, "فهد ابتعد عن المقدمة")
        let back = ConvoyAlertUI(kind: .returnToRally, userId: "o", name: "سلطان", color: 0, meters: -1, otherName: "سلطان")
        XCTAssertEqual(back.title, "سلطان: ارجعوا لنقطة التجمع")
        XCTAssertFalse(back.detail.contains("-"), "no distance without a live fix")
    }

    func testRowLine() {
        let now = base
        var p = ParticipantUI(id: "a", name: "فهد", color: 0, role: .member, isMe: false, presence: .live, distanceMeters: nil, bearingDegrees: nil,
                              batteryPercent: nil, note: nil, hasPhone: false, photo: nil)
        XCTAssertNil(SaryConvoyLine.text(p, now: now))
        p.leaderDistanceMeters = 1200
        XCTAssertEqual(SaryConvoyLine.text(p, now: now), "عن أمير الطلعة ١٫٢ كم")
        p.stoppedSince = now.addingTimeInterval(-30)
        XCTAssertEqual(SaryConvoyLine.text(p, now: now), "عن أمير الطلعة ١٫٢ كم", "a red light is not «واقف»")
        p.stoppedSince = now.addingTimeInterval(-260)
        XCTAssertEqual(SaryConvoyLine.text(p, now: now), "عن أمير الطلعة ١٫٢ كم · واقف منذ ٤ د")
        p.presence = .stale(since: now.addingTimeInterval(-600))
        XCTAssertEqual(SaryConvoyLine.text(p, now: now), "عن أمير الطلعة ١٫٢ كم", "never a stale «واقف»")
    }
}
