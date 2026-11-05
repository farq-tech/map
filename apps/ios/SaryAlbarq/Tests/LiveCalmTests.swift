import XCTest
@testable import SaryAlbarq

/// «تخفيف الزحمة» phase A (the calm live screen, styled after the owner's Lovable prototype):
/// what each context keeps on the map, the tools grid, the convoy line and the auto-hiding bits.
final class LiveCalmTests: XCTestCase {
    private func p(_ id: String, me: Bool = false, _ presence: ParticipantPresence, _ d: Double?) -> ParticipantUI {
        ParticipantUI(id: id, name: id, color: 0, role: .member, isMe: me, presence: presence,
                      distanceMeters: d, bearingDegrees: nil, batteryPercent: nil, note: nil, hasPhone: false)
    }

    // MARK: convoy line

    func testConvoyLineCountsLiveFriendsAndTheFarthest() {
        let list = [p("me", me: true, .live, nil), p("a", .live, 900), p("b", .live, 1_240), p("c", .stale(since: Date()), 6_100)]
        XCTAssertEqual(LiveCalmRules.convoyLine(list), "٢ مباشر · الأبعد ١٫٢ كم")
    }

    func testConvoyLineAloneOrWithoutDistances() {
        XCTAssertNil(LiveCalmRules.convoyLine([p("me", me: true, .live, nil)]), "alone: nothing to say")
        XCTAssertEqual(LiveCalmRules.convoyLine([p("me", me: true, .live, nil), p("a", .stale(since: Date()), 300)]), "٠ مباشر",
                       "a stale friend's old distance is not «الأبعد»")
    }

    // MARK: the map's side

    private let camera = SaryMapControlItem(id: "locate", systemImage: "location", label: "تتبعني", accessibilityID: "outing-locate")

    func testDrivingHasNoSideColumn() {
        XCTAssertTrue(LiveCalmRules.sideItems(camera: camera, backTrack: nil, plusBadge: nil, driving: true, ended: false).isEmpty)
    }

    func testStoppedKeepsCameraAndTools() {
        let items = LiveCalmRules.sideItems(camera: camera, backTrack: nil, plusBadge: 1, driving: false, ended: false)
        XCTAssertEqual(items.map(\.accessibilityID), ["outing-locate", "outing-actions"])
        XCTAssertEqual(items.last?.label, "أدوات")
        XCTAssertEqual(items.last?.badge, 1, "«غرّزت» is waiting in there")
    }

    func testBackTrackShortcutOnlyWhenItFitsAndNoToolsAfterTheEnd() {
        let back = SaryMapControlItem(id: "backtrack", systemImage: "x", label: "طريق العودة", accessibilityID: "outing-backtrack")
        XCTAssertEqual(LiveCalmRules.sideItems(camera: camera, backTrack: back, plusBadge: nil, driving: false, ended: false).map(\.id),
                       ["locate", "backtrack", "actions"])
        XCTAssertEqual(LiveCalmRules.sideItems(camera: camera, backTrack: nil, plusBadge: nil, driving: false, ended: true).map(\.id), ["locate"],
                       "ended: «المزيد» on the banner replaces «+»")
    }

    func testExplorationKeepsThreeButtons() {
        let ids = SaryMapControlItem.explore(terrain3D: false, tracksShown: 2).map(\.accessibilityID)
        XCTAssertEqual(ids, ["explore-layers", "explore-places", "outing-locate"])
        XCTAssertEqual(SaryMapControlItem.explore(terrain3D: false, tracksShown: 2)[1].badge, 2, "shown tracks still counted")
    }

    // MARK: «أدوات الطلعة»

    func testToolsGridSectionsAndNothingLost() {
        let groups = LiveActionCatalog.groups(.init(channels: true))
        XCTAssertEqual(groups.map(\.title), ["الطريق", "الجماعة", "السلامة", "المكان", "الترفيه", "الخريطة"])
        let grid = Set(groups.flatMap(\.items).map(\.id))
        let moved = Set(LiveActionCatalog.tripRouteActions(.init(guideAllTarget: "روضة")).map(\.id))
        XCTAssertEqual(moved, ["follow", "guideAll"], "«اتبع الخطة» and «وجّه الكل» live in «الرحلة»")
        XCTAssertTrue(grid.isDisjoint(with: moved))
        /* Every action the old «+» had is still one or two taps away. */
        let old: Set<String> = ["navigate", "search", "backtrack", "chat", "note", "stuck", "waypoint", "nearest", "weather", "radio", "youtube", "explore"]
        XCTAssertTrue(grid.isSuperset(of: old), "\(old.subtracting(grid))")
        XCTAssertTrue(grid.isSuperset(of: ["channels", "fit", "enjad"]))
        XCTAssertLessThanOrEqual(groups.flatMap(\.items).count, 16, "a grid that fits one screen")
    }

    func testToolsGridAfterTheEnd() {
        let ids = Set(LiveActionCatalog.groups(.init(ended: true, channels: true)).flatMap(\.items).map(\.id))
        XCTAssertTrue(ids.isDisjoint(with: LiveActionCatalog.needsRunningTrip), "\(ids)")
        XCTAssertTrue(ids.isSuperset(of: ["search", "navigate", "explore", "weather"]))
        XCTAssertTrue(LiveActionCatalog.tripRouteActions(.init(ended: true, guideAllTarget: "x")).isEmpty)
    }

    func testChannelsTileOnlyWithChannels() {
        XCTAssertFalse(LiveActionCatalog.groups(.init()).flatMap(\.items).contains { $0.id == "channels" })
    }

    // MARK: auto-hiding bits

    func testTimings() {
        XCTAssertEqual(VisualsSourceView.sourceSeconds, 5, "«الأجواء من الطقس» folds after 5 s")
        XCTAssertEqual(NoteFold.seconds, 10, "a note bubble folds to an icon after 10 s")
        XCTAssertEqual(SaryPTTButton.quietSeconds, 5, "«القناة غير متاحة» spelled out for 5 s")
    }

    func testSourceLineFoldsAndComesBackWhenItChanges() {
        let v = VisualsSourceView()
        v.set(source: "الأجواء من الطقس: غبار · Open-Meteo", slope: nil)
        XCTAssertGreaterThan(v.fit(maxWidth: 300).height, 0, "shown when it appears")
        let folded = expectation(description: "folded")
        v.onExpire = { folded.fulfill() }
        v.armFold()
        wait(for: [folded], timeout: 7)
        XCTAssertEqual(v.fit(maxWidth: 300).height, 0, "gone after 5 s")
        v.set(source: "الأجواء من الطقس: غبار · Open-Meteo", slope: nil)
        XCTAssertEqual(v.fit(maxWidth: 300).height, 0, "the same line does not come back by itself")
        v.armFold()
        XCTAssertEqual(v.fit(maxWidth: 300).height, 0, "arming again does not bring it back")
        v.set(source: "الأجواء من الطقس: مطر · Open-Meteo", slope: nil)
        XCTAssertGreaterThan(v.fit(maxWidth: 300).height, 0, "a new line shows again")
    }
}
