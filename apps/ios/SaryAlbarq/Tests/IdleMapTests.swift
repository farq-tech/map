import XCTest
@testable import SaryAlbarq

/// EM1 (docs/EXPLORE-MERGE.md): the idle navigation map. Rules, the flag, and that the carrier session keeps nothing.
final class IdleMapTests: XCTestCase {
    private func summary(_ id: String, _ s: OutingStatus) -> OutingSummary {
        OutingSummary(id: id, name: id, status: s, role: "member", my_status: "active", member_count: 2, created_at: nil, started_at: nil, ended_at: nil)
    }

    func testFlagIsOffByDefaultAndReadsTheStoredKey() {
        let d = UserDefaults(suiteName: "idle-map-flag")!
        d.removePersistentDomain(forName: "idle-map-flag")
        XCTAssertFalse(OneMapFlag.isOn(defaults: d, arguments: []))
        d.set(true, forKey: OneMapFlag.key)
        XCTAssertTrue(OneMapFlag.isOn(defaults: d, arguments: []))
        #if DEBUG
        d.set(false, forKey: OneMapFlag.key)
        XCTAssertTrue(OneMapFlag.isOn(defaults: d, arguments: [OneMapFlag.argument]))
        #endif
    }

    func testIdlePitchIsTheNavigationLookUnlessThePhoneIsStrained() {
        XCTAssertEqual(IdleMapRules.idlePitch(lowPower: false, thermalHot: false), IdleMapRules.pitch)
        XCTAssertGreaterThan(IdleMapRules.pitch, 0, "not the flat home map")
        XCTAssertEqual(IdleMapRules.idlePitch(lowPower: true, thermalHot: false), IdleMapRules.reducedPitch)
        XCTAssertEqual(IdleMapRules.idlePitch(lowPower: false, thermalHot: true), IdleMapRules.reducedPitch)
        XCTAssertLessThan(IdleMapRules.reducedPitch, IdleMapRules.pitch)
    }

    func testOutingsShowActiveFirstNeverEndedAndCapped() {
        let all = [summary("a", .created), summary("b", .ended), summary("c", .active), summary("d", .paused), summary("e", .created), summary("f", .active)]
        XCTAssertEqual(IdleMapRules.visibleOutings(all).map(\.id), ["c", "f", "d"])
        XCTAssertEqual(IdleMapRules.visibleOutings(all, limit: 10).map(\.id), ["c", "f", "d", "a", "e"])
        XCTAssertTrue(IdleMapRules.visibleOutings([summary("x", .ended)]).isEmpty)
    }

    @MainActor
    func testTheCarrierSessionIsLocalAndRecordsNothing() {
        let location = LocationSharer()
        location.testAuthorization = .authorizedWhenInUse
        let s = OutingSession.idleMap(me: PublicUser(id: "u1", display_name: "أنا"), location: location)
        XCTAssertTrue(s.isSolo)
        XCTAssertTrue(s.isLocal, "nothing is sent")
        XCTAssertNil(s.safetyBackend, "no server SOS or hide")
        XCTAssertFalse(s.trailRecordingAllowed, "the idle map keeps no trail")
        XCTAssertFalse(s.hasConsent)
        s.close()
    }
}
