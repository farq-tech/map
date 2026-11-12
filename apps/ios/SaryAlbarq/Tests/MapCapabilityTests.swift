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

    func testDrivingFromTheIdleMapTakesTheCapabilitiesAway() {
        // The idle map is always "exploring" (no way out): starting guidance, following or moving must unlock the trip map rules.
        for (nav, follow, move) in [(true, false, false), (false, true, false), (false, false, true)] {
            XCTAssertFalse(MapCapabilityRules.unlocked(exploring: true, oneMap: true, navigating: nav, following: follow, moving: move),
                           "oneMap + exploring + nav=\(nav) follow=\(follow) moving=\(move): the base layer and 3D are not forced")
        }
        XCTAssertTrue(MapCapabilityRules.unlocked(exploring: true, oneMap: true, navigating: false, following: false, moving: false))
        // The switch-off path is untouched: exploration keeps its capabilities exactly as before.
        XCTAssertTrue(MapCapabilityRules.unlocked(exploring: true, oneMap: false, navigating: true, following: true, moving: true))
    }

    func testShownTracksReachTheVisualsPackWithCapabilitiesToo() {
        let t = MapExplore.Track(id: "t", name: "t", points: [LngLat(lng: 46, lat: 24), LngLat(lng: 46.1, lat: 24.1)])
        XCTAssertEqual(MapExplore(active: true, tracks: [t]).visualRoutes.count, 1, "exploration, as before")
        XCTAssertEqual(MapExplore(active: false, capabilities: true, tracks: [t]).visualRoutes.count, 1, "capabilities (sary.oneMap): the slope overlay works")
        XCTAssertTrue(MapExplore(active: false, capabilities: false, tracks: [t]).visualRoutes.isEmpty, "neither: nothing")
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

    /// EM5 (P12/P13): the permanent coordinate card + crosshair on the live map while the capabilities are on.
    func testThePermanentReadoutIsOnlyForTheCapableMapOutsideExplorationTheEndCardAndPicking() {
        XCTAssertTrue(MapCapabilityRules.permanentReadout(capable: true, exploring: false, ended: false, picking: false))
        XCTAssertFalse(MapCapabilityRules.permanentReadout(capable: false, exploring: false, ended: false, picking: false), "without the flag the outing map is untouched")
        XCTAssertFalse(MapCapabilityRules.permanentReadout(capable: true, exploring: true, ended: false, picking: false), "exploration has its own top bar")
        XCTAssertFalse(MapCapabilityRules.permanentReadout(capable: true, exploring: false, ended: true, picking: false), "never over the end card")
        XCTAssertFalse(MapCapabilityRules.permanentReadout(capable: true, exploring: false, ended: false, picking: true), "never while picking a point")
    }

    func testTheReadoutFollowsTheCapabilitiesThroughDrivingAndGuidance() {
        for (nav, follow, move) in [(true, false, false), (false, true, false), (false, false, true)] {
            let capable = MapCapabilityRules.unlocked(exploring: false, oneMap: true, navigating: nav, following: follow, moving: move)
            XCTAssertFalse(MapCapabilityRules.permanentReadout(capable: capable, exploring: false, ended: false, picking: false),
                           "the card goes with the capabilities while driving (nav=\(nav) follow=\(follow) moving=\(move))")
        }
    }
}
