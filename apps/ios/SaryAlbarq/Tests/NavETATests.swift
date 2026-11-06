import XCTest
@testable import SaryAlbarq

/// «ما يخبرني وقت الوصول»: the arrival on the banner and by voice, the router's number smoothed.
final class NavETATests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testTheArrivalDoesNotJumpWithTheRoutersNoise() {
        var s = NavETASmoother()
        s.update(remainingS: 1_200, speedMps: 14, now: t0)
        let a0 = s.arrival!
        /* The router says +90 s for one progress (a slow stretch), then back. */
        s.update(remainingS: 1_199 + 90, speedMps: 14, now: t0.addingTimeInterval(1))
        XCTAssertLessThan(s.arrival!.timeIntervalSince(a0), 5, "one noisy reading moves the clock by seconds, not 1.5 min")
        /* A lasting change is followed within a few minutes. */
        for i in 2...240 { s.update(remainingS: 1_200 + 120 - Double(i), speedMps: 14, now: t0.addingTimeInterval(Double(i))) }
        XCTAssertEqual(s.arrival!.timeIntervalSince(a0), 120, accuracy: 10)
    }

    func testAShortStopDoesNotPushTheArrival() {
        var s = NavETASmoother()
        s.update(remainingS: 900, speedMps: 14, now: t0)
        let a0 = s.arrival!
        /* A red light, 2 min: the router's remaining time stays at ~880 s while I wait. */
        for i in 1...120 { s.update(remainingS: 880, speedMps: 0, now: t0.addingTimeInterval(Double(i))) }
        XCTAssertEqual(s.arrival!.timeIntervalSince(a0), 0, accuracy: 1, "under 3 min stopped: held")
        /* Stopped longer than 3 min: the arrival does move. */
        for i in 121...400 { s.update(remainingS: 880, speedMps: 0, now: t0.addingTimeInterval(Double(i))) }
        XCTAssertGreaterThan(s.arrival!.timeIntervalSince(a0), 60)
    }

    func testABigChangeIsTakenAtOnce() {
        var s = NavETASmoother()
        s.update(remainingS: 600, speedMps: 14, now: t0)
        s.update(remainingS: 600 + 1_500, speedMps: 14, now: t0.addingTimeInterval(1))
        XCTAssertEqual(s.remaining(t0.addingTimeInterval(1))!, 2_100, accuracy: 1, "a reroute / a jam: the new arrival at once")
    }

    func testTheNearestRecordedDuration() {
        XCTAssertEqual(NavETAAnnouncer.clip(remainingS: 18 * 60), "eta_08", "18 min → «باقي عشرين دقيقة وتوصل.»")
        XCTAssertEqual(NavETAAnnouncer.clip(remainingS: 12 * 60), "eta_06")
        XCTAssertEqual(NavETAAnnouncer.clip(remainingS: 13 * 60), "eta_07")
        XCTAssertEqual(NavETAAnnouncer.clip(remainingS: 40), "eta_01")
        XCTAssertEqual(NavETAAnnouncer.clip(remainingS: 100 * 60), "eta_12")
        XCTAssertNil(NavETAAnnouncer.clip(remainingS: 6 * 3_600))
        for c in NavETAAnnouncer.clips { XCTAssertNotNil(SaryVoiceCatalog.byKey[c.key], c.key) }
        XCTAssertTrue(NavETAAnnouncer.text(arrival: t0, remainingS: 18 * 60).hasPrefix("توصل الساعة"))
    }

    func testWhenTheArrivalIsSaid() {
        var a = NavETAAnnouncer()
        let arr = t0.addingTimeInterval(1_800)
        XCTAssertTrue(a.isDue(arrival: arr, now: t0), "at the start")
        a.said(arrival: arr, now: t0)
        XCTAssertFalse(a.isDue(arrival: arr.addingTimeInterval(120), now: t0.addingTimeInterval(300)), "2 min later, 5 min on: no")
        XCTAssertTrue(a.isDue(arrival: arr.addingTimeInterval(360), now: t0.addingTimeInterval(300)), "moved by 6 min: yes")
        XCTAssertTrue(a.isDue(arrival: arr, now: t0.addingTimeInterval(600)), "every 10 min")
        XCTAssertFalse(a.isDue(arrival: t0.addingTimeInterval(660), now: t0.addingTimeInterval(600)), "a minute from arrival: the arrival line says it")
    }
}
