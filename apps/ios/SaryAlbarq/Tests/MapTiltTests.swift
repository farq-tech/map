import XCTest
@testable import SaryAlbarq

/// Build 45: the «٣د / ٢د» camera-angle button. Pure pitch rules, the remembered choice per mode, the one registration
/// point in the side column, and the sun-free light the owner asked for.
final class MapTiltTests: XCTestCase {
    private func model() -> MapTiltModel {
        let d = UserDefaults(suiteName: "map-tilt-tests")!
        d.removePersistentDomain(forName: "map-tilt-tests")
        return MapTiltModel(defaults: d)
    }

    func test2DIsAlwaysTopDown() {
        for m in CameraTiltMode.allCases {
            XCTAssertEqual(CameraTiltRules.pitch(mode: m, is3D: false), 0, "\(m)")
            XCTAssertEqual(CameraTiltRules.pitch(mode: m, is3D: false, lowPower: true, thermalHot: true), 0, "\(m)")
        }
    }

    func test3DPitchesAreTheAppsOwn() {
        XCTAssertEqual(CameraTiltRules.pitch(mode: .navigation, is3D: true), FollowZoom.headingPitch, "the heading-up navigation pitch")
        XCTAssertEqual(CameraTiltRules.pitch(mode: .idle, is3D: true), IdleMapRules.pitch, "the idle map's 3D look")
        XCTAssertEqual(CameraTiltRules.pitch(mode: .overview, is3D: true), IdleMapRules.pitch)
        for m in CameraTiltMode.allCases {
            let p = CameraTiltRules.pitch(mode: m, is3D: true)
            XCTAssertTrue((40...60).contains(p), "\(m): inside the app's 40–60° range")
        }
    }

    func testLowPowerAndHeatLowerTheLookingMapsButNotNavigation() {
        XCTAssertEqual(CameraTiltRules.pitch(mode: .idle, is3D: true, lowPower: true), IdleMapRules.reducedPitch)
        XCTAssertEqual(CameraTiltRules.pitch(mode: .overview, is3D: true, thermalHot: true), IdleMapRules.reducedPitch)
        XCTAssertEqual(CameraTiltRules.pitch(mode: .navigation, is3D: true, lowPower: true), FollowZoom.headingPitch, "driving keeps its look")
    }

    func testModeFollowsTheCameraAndTheMap() {
        XCTAssertEqual(CameraTiltRules.mode(heading: true, idle: false), .navigation)
        XCTAssertEqual(CameraTiltRules.mode(heading: true, idle: true), .navigation, "heading-up wins over the idle map")
        XCTAssertEqual(CameraTiltRules.mode(heading: false, idle: true), .idle)
        XCTAssertEqual(CameraTiltRules.mode(heading: false, idle: false), .overview)
    }

    func testDefaultsKeepTodaysLook() {
        XCTAssertFalse(CameraTiltRules.default3D(.overview), "the outing / plan / home maps open flat as before")
        XCTAssertTrue(CameraTiltRules.default3D(.idle), "the idle map opens in 3D as before")
        XCTAssertTrue(CameraTiltRules.default3D(.navigation), "heading-up follows in 3D as before")
    }

    func testChoiceIsRememberedPerModeAndToggles() {
        let m = model()
        XCTAssertFalse(m.is3D(.overview))
        m.toggle(.overview)
        XCTAssertTrue(m.is3D(.overview))
        XCTAssertTrue(m.is3D(.navigation), "another mode is untouched")
        m.set(.navigation, false)
        XCTAssertFalse(m.is3D(.navigation))
        XCTAssertEqual(m.pitch(.navigation), 0)
        XCTAssertTrue(m.is3D(.overview), "and the first is still 3D")
        // A new model on the same store reads the same choice (it survives a relaunch).
        let again = MapTiltModel(defaults: UserDefaults(suiteName: "map-tilt-tests")!)
        XCTAssertTrue(again.is3D(.overview))
        XCTAssertFalse(again.is3D(.navigation))
    }

    func testToggleBumpsRevisionOnlyOnARealChange() {
        let m = model()
        let r = m.revision
        m.set(.overview, false)
        XCTAssertEqual(m.revision, r, "already flat: nothing to announce")
        m.set(.overview, true)
        XCTAssertEqual(m.revision, r + 1)
    }

    func testTheButtonNamesTheViewATapLeadsTo() {
        XCTAssertEqual(CameraTiltRules.glyph(is3D: false), "٣د")
        XCTAssertEqual(CameraTiltRules.glyph(is3D: true), "٢د")
        let old = SaryMapControlItem.cameraTilt(is3D: false, newUI: false)
        XCTAssertEqual(old.glyph, "٣د", "flag off: unchanged")
        let flat = SaryMapControlItem.cameraTilt(is3D: false, newUI: true)
        XCTAssertEqual(flat.accessibilityID, "map.tilt")
        XCTAssertNil(flat.glyph, "an icon, not «٣د»: it read as minutes beside the ETA")
        XCTAssertEqual(flat.systemImage, "view.3d")
        XCTAssertEqual(SaryMapControlItem.cameraTilt(is3D: true, newUI: true).systemImage, "view.2d")
        XCTAssertFalse(flat.label.isEmpty, "an accessible label")
        XCTAssertNotEqual(SaryMapControlItem.cameraTilt(is3D: true, newUI: true), flat)
    }

    func testTiltSitsRightAfterLayersInEveryColumn() {
        let layers = SaryMapControlItem.layers()
        let tilt = SaryMapControlItem.cameraTilt(is3D: false)
        let locate = SaryMapControlItem(id: "locate", systemImage: "scope", label: "موقعي", accessibilityID: "outing-locate")
        let back = SaryMapControlItem(id: "backtrack", systemImage: "arrow.uturn.backward", label: "طريق الرجعة", accessibilityID: "outing-backtrack")
        func ids(_ items: [SaryMapControlItem]) -> [String] {
            LiveCalmRules.withTilt(LiveCalmRules.withLayers(items, layers: layers), tilt: tilt).map(\.id)
        }
        XCTAssertEqual(ids([locate, back]), ["layers", "tilt", "locate", "backtrack"])
        XCTAssertEqual(ids([]), ["layers", "tilt"], "after the end / any empty column")
        XCTAssertEqual(ids([tilt, locate]), ["layers", "tilt", "locate"], "never twice")
        XCTAssertEqual(LiveCalmRules.withTilt([locate], tilt: tilt).map(\.id), ["tilt", "locate"], "without a layers button it still leads")
    }

    func testTheIdleColumnStaysWithinTheOverlapBound() {
        // layers + tilt + the idle items: one more than `IdleSideRules.columnCount`, still short enough for an SE.
        // (The Qibla button left the column by the owner's decision: 4 on a compact phone, 5 otherwise.)
        XCTAssertEqual(IdleSideRules.columnCount(compact: true) + 1, 4)
        XCTAssertEqual(IdleSideRules.columnCount(compact: false) + 1, 5)
    }

    // MARK: the sun-free look

    func testSunLookIsFlatByDefault() {
        XCTAssertFalse(SunLook.enabled, "the owner's flat look is on unless the DEBUG comparison switch is given")
        XCTAssertFalse(SunLook.castShadows)
        XCTAssertFalse(SunLook.sunLitRelief)
    }

    func testDawnDuskAndNightArePlainDay() {
        XCTAssertEqual(SunLook.preset(.dawn), .day)
        XCTAssertEqual(SunLook.preset(.dusk), .day)
        XCTAssertEqual(SunLook.preset(.day), .day)
        XCTAssertEqual(SunLook.preset(.night), .day, "the map never darkens at night (2026-11-12)")
    }

    func testNightLookSwitchIsOffAndMapIsDayAtEveryHourInRiyadh() {
        XCTAssertFalse(NightLook.mapDarkens, "the DEBUG -SaryNightMapDark switch is not given")
        let start = ISO8601DateFormatter().date(from: "2026-11-12T00:00:00Z")!
        for h in 0..<24 {
            let d = start.addingTimeInterval(Double(h) * 3600)
            let real = SunLight.preset(d, lat: 24.71, lng: 46.68)
            XCTAssertEqual(NightLook.preset(forcedNight: false, real: real), .day, "hour \(h) UTC, automatic")
            XCTAssertEqual(NightLook.preset(forcedNight: true, real: real), .day, "hour \(h) UTC, forced night theme")
        }
        // The clock really does reach night in Riyadh, so the loop above is not vacuous.
        XCTAssertTrue((0..<24).contains { SunLight.preset(start.addingTimeInterval(Double($0) * 3600), lat: 24.71, lng: 46.68) == .night })
        XCTAssertFalse(NightLook.mapIsDark(nightTheme: true), "casings are contrasted for a light map")
    }

    func testSkyHasNoGoldenHorizonAndNoNight() {
        for alt in [-30.0, -12, -6, -5, 0, 3, 10, 40, 80] { XCTAssertEqual(SunLook.skyAltitude(alt), 30, "alt \(alt): a fixed neutral noon, no night sky") }
        XCTAssertEqual(SkyAtmosphere.sky(sunAltitude: SunLook.skyAltitude(-20)).starIntensity, 0, "no stars")
        // And the noon sky it picks is the plain one: no warm orange horizon colour.
        let sky = SkyAtmosphere.sky(sunAltitude: SunLook.skyAltitude(2))
        XCTAssertGreaterThan(sky.color.r, 200)
        XCTAssertLessThan(sky.color.r - sky.color.b, 70, "a sand haze, not the sunset's orange (244, 172, 122)")
    }
}
