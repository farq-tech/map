import XCTest
@testable import SaryAlbarq

/// EM4 (docs/EXPLORE-MERGE.md): exploration's capabilities are no longer only a mode.
final class MapCapabilityTests: XCTestCase {
    func testWithoutTheFlagOnlyExplorationHasThem() {
        XCTAssertTrue(MapCapabilityRules.unlocked(exploring: true, oneMap: false, navigating: false, following: false, moving: false))
        XCTAssertFalse(MapCapabilityRules.unlocked(exploring: false, oneMap: false, navigating: false, following: false, moving: false), "today's outing map is untouched")
    }

    func testWithTheFlagTheyAreOnWhileLookingAroundAndOffWhileGuidingFollowingOrMoving() {
        XCTAssertTrue(MapCapabilityRules.unlocked(exploring: false, oneMap: true, navigating: false, following: false, moving: false))
        XCTAssertFalse(MapCapabilityRules.unlocked(exploring: false, oneMap: true, navigating: true, following: false, moving: false), "guidance keeps the trip map")
        XCTAssertFalse(MapCapabilityRules.unlocked(exploring: false, oneMap: true, navigating: false, following: true, moving: false), "following a track keeps it")
        XCTAssertFalse(MapCapabilityRules.unlocked(exploring: false, oneMap: true, navigating: false, following: false, moving: true), "driving keeps it")
    }

    @MainActor
    func testTheMapDrawsCapabilitiesWithoutStoppingTheGroupCamera() {
        let location = LocationSharer()
        let s = OutingSession.idleMap(me: PublicUser(id: "u1", display_name: "أنا"), location: location)
        let c = LiveOutingController(session: s, location: location, appearance: AppearanceSettings())
        XCTAssertFalse(c.exploreActive)
        XCTAssertEqual(c.mapExplore(places: [], tracks: TrackLibrary.shared), MapExplore(), "no capability, nothing drawn (default)")
        let e = c.mapExplore(places: [], tracks: TrackLibrary.shared, capable: true)
        XCTAssertTrue(e.capabilities)
        XCTAssertFalse(e.active, "`active` stops the camera keeping the group in view: capabilities must not")
        c.exploreActive = true
        XCTAssertTrue(c.mapExplore(places: [], tracks: TrackLibrary.shared).active)
        s.close()
    }
}
