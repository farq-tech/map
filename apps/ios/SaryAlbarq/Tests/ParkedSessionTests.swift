import XCTest
@testable import SaryAlbarq

/// «ارجع للقائمة» (build 15): the map closes but the trip's session — and its forced sharing —
/// keeps running until «غادر الطلعة» or the trip's end.
@MainActor
final class ParkedSessionTests: XCTestCase {
    func testBackToTheListKeepsTheSessionRunningAndReopeningReusesIt() {
        let m = AppModel(arguments: ["-demo", "-SaryScreen", "privacy"])
        m.open(DemoData.outingId)
        guard let s = m.session else { return XCTFail("the demo trip opens") }
        m.parkSession()
        XCTAssertNil(m.session, "back in «طلعاتي»")
        XCTAssertTrue(m.parkedSession === s, "the trip's session is still running")
        XCTAssertNil(s.closedReason)
        XCTAssertFalse(s.didClose, "not closed: its sharing keeps going off the map")
        m.open(DemoData.outingId)
        XCTAssertTrue(m.session === s, "opening the trip again picks the same session up")
        XCTAssertNil(m.parkedSession)
    }

    func testLeavingFromTheListClosesTheParkedSession() async {
        let m = AppModel(arguments: ["-demo", "-SaryScreen", "privacy"])
        m.open(DemoData.outingId)
        guard let s = m.session else { return XCTFail("the demo trip opens") }
        m.parkSession()
        _ = await s.leave()
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertNil(m.parkedSession, "left: nothing keeps running")
        XCTAssertTrue(s.didClose)
    }
}
