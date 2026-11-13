import Foundation
#if !STANDALONE
import XCTest
@testable import SaryAlbarq
#endif

/// «توجيه البر»: the off-road wording, which line and when (`OffRoadVoice`). No route, voice or clock: the
/// provider is a value with its own memory, so every rule is a plain call.
final class OffRoadVoiceTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func ctx(_ at: Double = 0, maneuverM: Double? = nil, warning: Bool = false) -> OffRoadContext {
        OffRoadContext(distanceToManeuverM: maneuverM, warningActive: warning, now: t0.addingTimeInterval(at))
    }

    /// A provider whose clips «exist» (or not).
    private func voice(clips: Bool = true) -> OffRoadVoice {
        var v = OffRoadVoice()
        v.hasClips = { _ in clips }
        return v
    }

    // MARK: progress

    func testMilestonesAreSaidOnceEachAtTheirNumber() {
        var v = voice()
        var said: [OffRoadLine] = []
        var at = 0.0
        for km in stride(from: 52.0, through: 0.15, by: -0.05) {
            at += 30   // 30 s between readings: the minimum gap never hides a milestone here
            if let s = v.progress(remainingM: km * 1000, ctx(at)) { said.append(s.line) }
        }
        XCTAssertEqual(said, [.km50, .km20, .km10, .km5, .km2, .km1, .near800, .near500, .near200])
    }

    func testAMilestoneTheTripStartedPastIsSkippedNotSaidLate() {
        var v = voice()
        // 30 km left at the start: «باقي خمسين كيلو» would be a lie.
        XCTAssertNil(v.progress(remainingM: 30_000, ctx(0)))
        XCTAssertNil(v.progress(remainingM: 29_000, ctx(60)))
        XCTAssertEqual(v.progress(remainingM: 19_900, ctx(120))?.line, .km20)
    }

    func testANumberIsNeverSaidWhenTheRealDistanceIsFarFromIt() {
        var v = voice()
        // 1.4 km is not «كيلوين» (the band is 1.5–2 km) and not yet «كيلو واحد».
        XCTAssertNil(v.progress(remainingM: 1_400, ctx(0)))
        XCTAssertNil(v.progress(remainingM: 1_300, ctx(60)))
        XCTAssertEqual(v.progress(remainingM: 980, ctx(120))?.line, .km1)
    }

    func testArrivalIsSaidEvenRightAfterAnotherLine() {
        var v = voice()
        XCTAssertNotNil(v.begin(ctx(0)))
        XCTAssertEqual(v.arrival(ctx(2))?.line, .arrived)
        XCTAssertNil(v.arrival(ctx(4)), "once")
    }

    func testTheMinimumGapHoldsBackASecondMilestoneButNotForever() {
        var v = voice()
        XCTAssertNotNil(v.begin(ctx(0)))
        // 5 s later: too soon after the first line, and it stays unsaid…
        XCTAssertNil(v.progress(remainingM: 19_900, ctx(5)))
        // …until the gap has passed (the number is still true).
        XCTAssertEqual(v.progress(remainingM: 19_800, ctx(40))?.line, .km20)
    }

    func testNothingButWarningsIsSaidNearAManeuverOrDuringAWarning() {
        var v = voice()
        XCTAssertNil(v.progress(remainingM: 19_900, ctx(0, maneuverM: 80)), "a manoeuvre 80 m away")
        XCTAssertNil(v.progress(remainingM: 19_900, ctx(1, warning: true)), "a warning is up")
        XCTAssertNotNil(v.rough(aheadM: 250, ctx(2, maneuverM: 80, warning: true)), "the warning itself is said")
        XCTAssertEqual(v.progress(remainingM: 19_800, ctx(60))?.line, .km20, "and the milestone was kept for later")
    }

    // MARK: turns

    func testATurnIsSaidOncePerManeuverAndOnlyAtItsNumber() {
        var v = voice()
        XCTAssertNil(v.turn(.right, distanceM: 600, maneuverID: "3", ctx(0)), "too early for «ثلاثمية»")
        XCTAssertEqual(v.turn(.right, distanceM: 280, maneuverID: "3", ctx(1))?.line, .right300)
        XCTAssertNil(v.turn(.right, distanceM: 260, maneuverID: "3", ctx(2)), "once")
        XCTAssertEqual(v.turn(.left, distanceM: 290, maneuverID: "4", ctx(3))?.line, .left300)
        XCTAssertEqual(v.turn(.slightLeft, distanceM: 120, maneuverID: "5", ctx(4))?.line, .slightLeft)
        XCTAssertNil(v.turn(.straight, distanceM: 100, maneuverID: "6", ctx(5)))
    }

    // MARK: deviation

    func testTheWayBackHasEightHeadings() {
        let expected: [(Double, OffRoadLine)] = [
            (0, .backN), (44, .backNE), (90, .backE), (135, .backSE), (180, .backS),
            (225, .backSW), (270, .backW), (315, .backNW), (359, .backN), (-45, .backNW), (400, .backNE),
        ]
        for (deg, line) in expected { XCTAssertEqual(OffRoadVoice.backLine(bearing: deg), line, "\(deg)°") }
    }

    func testDeviationNeedsDistanceAndIsNotRepeatedEveryFix() {
        var v = voice()
        XCTAssertNil(v.deviation(crossM: 30, bearingToRoute: 90, ctx(0)), "30 m is GPS noise")
        let first = v.deviation(crossM: 120, bearingToRoute: 90, ctx(10))
        XCTAssertEqual(first?.line, .backE)
        XCTAssertTrue(first?.text.contains("ارجع شرقًا") == true)
        XCTAssertNil(v.deviation(crossM: 130, bearingToRoute: 90, ctx(20)), "45 s apart at least")
        XCTAssertEqual(v.deviation(crossM: 500, bearingToRoute: 90, ctx(70))?.line, .farOff)
    }

    func testBackOnTheRouteIsSaidOnlyAfterADeviation() {
        var v = voice()
        XCTAssertNil(v.backOnRoute(ctx(0)))
        _ = v.deviation(crossM: 120, bearingToRoute: 0, ctx(1))
        XCTAssertEqual(v.backOnRoute(ctx(30))?.line, .backOn)
        XCTAssertNil(v.backOnRoute(ctx(31)), "once")
    }

    func testRoughGroundIsWarnedOnceBeforeTheRunNotRepeatedAndNotWhenFarOrAlreadyOnIt() {
        var v = voice()
        XCTAssertNil(v.rough(aheadM: 900, ctx(0)), "too far")
        XCTAssertNil(v.rough(aheadM: 40, ctx(1)), "already on it")
        XCTAssertEqual(v.rough(aheadM: 250, ctx(2))?.line, .rough)
        XCTAssertNil(v.rough(aheadM: 200, ctx(30)), "90 s apart at least")
        XCTAssertNotNil(v.rough(aheadM: 200, ctx(100)))
    }

    // MARK: people, fuel, offline, sunset

    func testFriendLinesAreCappedAtThreePerTripAndFiveMinutesApart() {
        var v = voice()
        XCTAssertEqual(v.friendFar(distanceM: 3_000, ctx(0))?.line, .friendFar3)
        XCTAssertNil(v.friendFar(distanceM: 3_000, ctx(60)), "5 minutes apart")
        XCTAssertNotNil(v.friendLost(ctx(400)))
        XCTAssertNotNil(v.friendFar(distanceM: 6_000, ctx(800)))
        XCTAssertNil(v.friendLost(ctx(1_300)), "the fourth is never said")
        XCTAssertEqual(v.personalCount, 3)
    }

    func testTheFriendNumberIsOnlyForAboutThreeKilometres() {
        var a = voice(), b = voice(), c = voice()
        XCTAssertEqual(a.friendFar(distanceM: 3_300, ctx())?.line, .friendFar3)
        let far = b.friendFar(distanceM: 6_000, ctx())
        XCTAssertEqual(far?.line, .friendFarGeneric)
        XCTAssertEqual(far?.clips, [], "no recording for the number-less line: the device voice says it")
        XCTAssertFalse(far?.text.contains("ثلاثة") == true)
        XCTAssertNil(c.friendFar(distanceM: 900, ctx()), "close: nothing")
    }

    func testNoFriendNameIsEverPartOfALine() {
        for l in OffRoadLine.allCases { XCTAssertFalse(l.entry.text.contains("{"), l.rawValue) }
    }

    func testStationBuckets() {
        var a = voice(), b = voice(), c = voice(), d = voice()
        XCTAssertEqual(a.station(distanceM: 40_000, ctx())?.line, .station40)
        XCTAssertEqual(b.station(distanceM: 25_000, ctx())?.line, .stationGeneric)
        XCTAssertNil(c.station(distanceM: 120_000, ctx()))
        XCTAssertEqual(d.station(distanceM: nil, ctx())?.line, .noStation)
    }

    func testSunsetAndOfflineAreSaidOnceNotOften() {
        var v = voice()
        XCTAssertEqual(v.sunset(minutes: 40, ctx(0))?.line, .sunset40)
        XCTAssertNil(v.sunset(minutes: 39, ctx(60)), "once")
        XCTAssertEqual(v.offline(ctx(100))?.line, .offline)
        XCTAssertNil(v.offline(ctx(200)), "10 minutes apart")
        XCTAssertNotNil(v.offline(ctx(800)))
    }

    // MARK: text, clips, device voice

    func testWithoutClipsTheDeviceVoiceGetsTheStandardSpelling() {
        var noClips = voice(clips: false), withClips = voice(clips: true)
        _ = noClips.progress(remainingM: 990, ctx(0))   // «كيلو واحد» first, as on a real drive
        let a = noClips.progress(remainingM: 790, ctx(60))
        XCTAssertEqual(a?.line, .near800)
        XCTAssertEqual(a?.clips, [])
        XCTAssertEqual(a?.text, "قربنا، ثمانمية متر", "the phone's voice reads the standard spelling")
        _ = withClips.progress(remainingM: 990, ctx(0))
        let b = withClips.progress(remainingM: 790, ctx(60))
        XCTAssertEqual(b?.clips, ["offr_08"])
        XCTAssertEqual(b?.text, "قربنا، ثمنمية متر", "the owner's spelling of 800")
    }

    func testTheLineGoesToTheNavigationVoiceWithItsClipsAndSafety() {
        var v = voice()
        let rough = v.rough(aheadM: 250, ctx())!
        let nav = rough.navLine(routeRevision: 4)
        XCTAssertEqual(nav.text, "أرض وعرة قدامك، خفّف")
        XCTAssertEqual(nav.clips, ["offr_28"])
        XCTAssertTrue(nav.safety)
        XCTAssertEqual(nav.routeRevision, 4)
        XCTAssertNotNil(nav.expiresAt, "a late line is dropped, never said late")
    }

    func testOnlyApprovedWordsAreUsed() {
        for l in OffRoadLine.allCases {
            let t = l.entry.text
            XCTAssertFalse(t.contains("الأثر"), "«مسارك», never «الأثر»: \(l.rawValue)")
            for banned in ["بنزين يكفي", "الشبكة", "نفود", "سبخة", "السيل", "نزّل هواء"] {
                XCTAssertFalse(t.contains(banned), "\(l.rawValue) says «\(banned)» (no data for it yet)")
            }
        }
        // The number words are the ones the owner heard and approved.
        XCTAssertEqual(OffRoadLine.near800.entry.text, "قربنا، ثمنمية متر")
        XCTAssertEqual(OffRoadLine.right300.entry.text, "خذ يمينك بعد ثلاثمية متر")
        XCTAssertEqual(OffRoadLine.near500.entry.text, "قربنا، خمسمية متر")
    }

    func testKeysAreUniqueAndNumberedInOrder() {
        let keys = OffRoadLine.allCases.compactMap(\.entry.key)
        XCTAssertEqual(Set(keys).count, keys.count)
        XCTAssertEqual(keys, (1 ... keys.count).map { String(format: "offr_%02d", $0) })
        XCTAssertEqual(keys.count, 34)
    }

    // MARK: which trips

    func testAnOffRoadTripIsOneWhoseRouteIsMostlyNotAsphalt() {
        var km = NavSurfaceKm()
        km.paved = 10_000; km.unpaved = 4_000; km.offRoad = 8_000
        XCTAssertTrue(OffRoadVoice.isOffRoadTrip(km))
        km.paved = 30_000; km.unpaved = 1_000; km.offRoad = 0
        XCTAssertFalse(OffRoadVoice.isOffRoadTrip(km), "a city trip with a dirt end is not an off-road trip")
        XCTAssertTrue(OffRoadVoice.isOffRoadTrip(km, straightLeg: true))
        XCTAssertFalse(OffRoadVoice.isOffRoadTrip(NavSurfaceKm()), "no data: not off-road")
    }

    // MARK: the way back

    func testNearestPointOfTheRouteGivesTheBearingBack() throws {
        // A north–south line 100 m east of me (lat 24.7): the way back is east.
        let me = LngLat(lng: 46.6753, lat: 24.7136)
        let east = 0.001
        let line = [LngLat(lng: 46.6753 + east, lat: 24.70), LngLat(lng: 46.6753 + east, lat: 24.73)]
        let n = try XCTUnwrap(OffRoadGeometry.nearest(on: line, from: me))
        XCTAssertEqual(n.distanceM, 101, accuracy: 3)
        XCTAssertEqual(n.bearing, 90, accuracy: 1)
        // A line 200 m north: the way back is north.
        let north = [LngLat(lng: 46.66, lat: 24.7136 + 0.0018), LngLat(lng: 46.69, lat: 24.7136 + 0.0018)]
        let m = try XCTUnwrap(OffRoadGeometry.nearest(on: north, from: me))
        XCTAssertEqual(m.bearing, 0, accuracy: 1)
        XCTAssertEqual(m.distanceM, 200, accuracy: 3)
        XCTAssertNil(OffRoadGeometry.nearest(on: [me], from: me))
    }

    #if !STANDALONE
    // MARK: the clips and the pending file

    /// The rows waiting for their recordings are exactly the script's keys (the import script moves them to the manifest).
    func testPendingFileMatchesTheScript() throws {
        let manifest = try XCTUnwrap(SaryVoiceCatalog.manifestURL())
        let pendingURL = manifest.deletingLastPathComponent().appendingPathComponent("offroad-pending.json")
        let data = try Data(contentsOf: pendingURL)
        let pending = try JSONDecoder().decode([SaryVoiceCatalog.Entry].self, from: data)
        let script = OffRoadLine.allCases.compactMap { l in l.entry.key.map { ($0, l.entry.text) } }
        XCTAssertEqual(pending.map(\.key) + SaryVoiceCatalog.entries.filter { $0.section == "offroad" }.map(\.key), script.map(\.0),
                       "every key is either pending or already imported")
        for p in pending {
            XCTAssertEqual(p.text, script.first { $0.0 == p.key }?.1, p.key)
            XCTAssertNil(SaryVoiceCatalog.byKey[p.key], "\(p.key) is pending: it must not be in the manifest yet")
            XCTAssertEqual(p.file, p.key + ".m4a")
        }
    }

    /// With no recordings yet the line still speaks (device voice), because its clips are not in the bundle.
    func testWithTheRealBundleAMissingClipFallsBackToText() {
        var v = OffRoadVoice()
        let s = v.begin(ctx())
        XCTAssertEqual(s?.line, .start)
        if SaryVoiceCatalog.has(["offr_01"]) { XCTAssertEqual(s?.clips, ["offr_01"]) }
        else { XCTAssertEqual(s?.clips, []); XCTAssertEqual(s?.text, "توكلنا على الله، اتبع مسارك") }
    }
    #endif
}
