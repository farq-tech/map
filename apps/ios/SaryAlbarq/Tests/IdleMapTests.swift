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

    func testWhoPresentsAnInvite() {
        XCTAssertTrue(IdleMapRules.rootShowsInvite(hasSession: false, idleMapShown: false), "no trip, no idle map: the root presents it")
        XCTAssertFalse(IdleMapRules.rootShowsInvite(hasSession: true, idleMapShown: false), "a trip: its live sheet presents it")
        XCTAssertFalse(IdleMapRules.rootShowsInvite(hasSession: false, idleMapShown: true), "the idle map: its live sheet presents it, never twice")
    }

    @MainActor
    private func idleController(go: ((OutingDestination) -> Void)?) -> (LiveOutingController, OutingSession) {
        let location = LocationSharer()
        location.testAuthorization = .authorizedWhenInUse
        let s = OutingSession.idleMap(me: PublicUser(id: "u1", display_name: "أنا"), location: location)
        let c = LiveOutingController(session: s, location: location, appearance: AppearanceSettings())
        c.idleHome = true
        c.idleNavigate = go
        return (c, s)
    }

    @MainActor
    func testGuidanceFromTheIdleMapOpensARealSoloOutingInsteadOfPlanningOnTheCarrier() {
        var handed: [OutingDestination] = []
        let (c, s) = idleController { handed.append($0) }
        let t = NavTarget(source: .point, name: "روضة الثمامة", position: LngLat(lng: 46.7491, lat: 24.7590))
        XCTAssertTrue(c.handOffToSolo(t))
        XCTAssertEqual(c.nav.phase, .idle, "the carrier session plans nothing")
        let done = expectation(description: "handed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { done.fulfill() }
        wait(for: [done], timeout: 2)
        XCTAssertEqual(handed.map(\.name), ["روضة الثمامة"])
        XCTAssertEqual(handed.first?.lat ?? 0, 24.7590, accuracy: 1e-6)
        s.close()
    }

    @MainActor
    func testAnOrdinaryTripNeverHandsOff() {
        let (c, s) = idleController(go: nil)
        c.idleHome = false
        XCTAssertFalse(c.handOffToSolo(NavTarget(source: .point, name: "x", position: LngLat(lng: 46, lat: 24))))
        s.close()
    }

    func testSideColumnNeverGrowsPastTheEssentialsOnAShortPhone() {
        XCTAssertTrue(IdleSideRules.isCompact(screenHeight: 667), "iPhone SE")
        XCTAssertFalse(IdleSideRules.isCompact(screenHeight: 852), "iPhone Pro")
        XCTAssertFalse(IdleSideRules.isCompact(screenHeight: 1366), "iPad")
        XCTAssertEqual(IdleSideRules.items(compact: true), [.locate, .qibla, .more])
        XCTAssertEqual(IdleSideRules.items(compact: false), [.locate, .qibla, .places, .more])
        XCTAssertEqual(IdleSideRules.columnCount(compact: true), 4, "layers + locate + compass + more")
        XCTAssertEqual(IdleSideRules.columnCount(compact: false), 5)
        XCTAssertLessThanOrEqual(IdleSideRules.columnCount(compact: false), 5)
    }

    func testEverythingTheColumnDropsIsUnderMore() {
        for compact in [true, false] {
            let inColumn = Set(IdleSideRules.items(compact: compact).map(\.rawValue))
            let inMore = Set(IdleSideRules.moreActions(compact: compact).map(\.rawValue))
            for a in IdleMoreAction.allCases { XCTAssertTrue(inColumn.contains(a.rawValue) || inMore.contains(a.rawValue), "\(a) stays reachable (compact=\(compact))") }
            XCTAssertTrue(inColumn.isDisjoint(with: inMore.subtracting(["drone", "realistic"])), "«أماكني» is in one place only")
        }
    }

    func testTheSettingsSwitchStoresTheFlagAndIsLabelledExperimental() {
        let d = UserDefaults(suiteName: "idle-map-switch")!
        d.removePersistentDomain(forName: "idle-map-switch")
        XCTAssertFalse(OneMapFlag.isOn(defaults: d, arguments: []), "off by default")
        d.set(true, forKey: OneMapFlag.key)   // what the «متقدم» switch writes (@AppStorage on the same key)
        XCTAssertTrue(OneMapFlag.isOn(defaults: d, arguments: []))
        d.set(false, forKey: OneMapFlag.key)
        XCTAssertFalse(OneMapFlag.isOn(defaults: d, arguments: []))
        XCTAssertEqual(OneMapFlag.settingsTitle, "الخريطة الواحدة (تجريبي)")
        XCTAssertTrue(OneMapFlag.restartNote.contains("بعد إغلاق التطبيق"), "the restart note")
    }

    func testTheNotificationExplainerIsQueuedBehindIdleSheets() {
        XCTAssertTrue(IdleMapRules.rootShowsNotifyExplainer(hasSession: false, idleMapShown: false, offer: true, pendingInvite: false))
        XCTAssertFalse(IdleMapRules.rootShowsNotifyExplainer(hasSession: false, idleMapShown: true, offer: true, pendingInvite: false), "not from the root over the idle map")
        XCTAssertFalse(IdleMapRules.rootShowsNotifyExplainer(hasSession: false, idleMapShown: false, offer: true, pendingInvite: true), "an invite goes first")
        XCTAssertTrue(IdleMapRules.idlePresentsNotifyExplainer(offer: true, pendingInvite: false, idleSheetOpen: false, liveModalOpen: false))
        XCTAssertFalse(IdleMapRules.idlePresentsNotifyExplainer(offer: true, pendingInvite: false, idleSheetOpen: true, liveModalOpen: false), "queued behind the search/tools/profile…")
        XCTAssertFalse(IdleMapRules.idlePresentsNotifyExplainer(offer: true, pendingInvite: false, idleSheetOpen: false, liveModalOpen: true), "queued behind a live sheet")
        XCTAssertFalse(IdleMapRules.idlePresentsNotifyExplainer(offer: true, pendingInvite: true, idleSheetOpen: false, liveModalOpen: false))
        XCTAssertFalse(IdleMapRules.idlePresentsNotifyExplainer(offer: false, pendingInvite: false, idleSheetOpen: false, liveModalOpen: false))
    }

    func testTheIdleCameraOpensWhereTheBestImageryIsForTheContext() {
        XCTAssertEqual(IdleMapRules.openingZoom(lat: 24.7136, lng: 46.6753), 15, "Riyadh: a city, its enhancement needs 18 (gate not lowered)")
        XCTAssertEqual(IdleMapRules.openingZoom(lat: 21.5, lng: 39.2), 15, "Jeddah")
        XCTAssertEqual(IdleMapRules.openingZoom(lat: 25.12, lng: 46.10), 16, "open land: where the enhancement already draws")
        XCTAssertEqual(IdleMapRules.openingZoom(lat: 28.0, lng: 41.5), 16, "the Nafud")
        XCTAssertTrue(HiResZoom.wantsLayer(zoom: IdleMapRules.openingZoom(lat: 25.12, lng: 46.10), lat: 25.12, lng: 46.10), "open land opens inside the gate")
        XCTAssertFalse(HiResZoom.wantsLayer(zoom: IdleMapRules.openingZoom(lat: 24.7136, lng: 46.6753), lat: 24.7136, lng: 46.6753), "a city opens outside it, by design")
    }

    func testTheHiResHintShowsOnlyWhenItIsAvailableAndNotDrawnAtThisZoom() {
        // Riyadh z15: allowed, not drawn at this zoom -> hint.
        XCTAssertTrue(IdleMapRules.showsHiResHint(decision: .on, zoom: 15, lat: 24.7136, lng: 46.6753))
        // Riyadh z18: drawn -> no hint.
        XCTAssertFalse(IdleMapRules.showsHiResHint(decision: .on, zoom: 18, lat: 24.7136, lng: 46.6753))
        // Open land z16: drawn; z14: hint.
        XCTAssertFalse(IdleMapRules.showsHiResHint(decision: .on, zoom: 16, lat: 25.12, lng: 46.10))
        XCTAssertTrue(IdleMapRules.showsHiResHint(decision: .on, zoom: 14, lat: 25.12, lng: 46.10))
        // Not available (off / paused by low power or heat): never a hint that promises it.
        XCTAssertFalse(IdleMapRules.showsHiResHint(decision: .off(.userOff), zoom: 15, lat: 24.7136, lng: 46.6753))
        XCTAssertFalse(IdleMapRules.showsHiResHint(decision: .paused, zoom: 15, lat: 24.7136, lng: 46.6753))
        XCTAssertFalse(IdleMapRules.showsHiResHint(decision: .off(.notSatellite), zoom: 15, lat: 24.7136, lng: 46.6753))
        XCTAssertTrue(HiResZoom.wantsLayer(zoom: IdleMapRules.hiResTargetZoom(lat: 24.7136, lng: 46.6753), lat: 24.7136, lng: 46.6753), "the chip lands inside the gate, not a rounding error short of it")
        XCTAssertTrue(HiResZoom.wantsLayer(zoom: IdleMapRules.hiResTargetZoom(lat: 25.12, lng: 46.10), lat: 25.12, lng: 46.10))
    }
}
