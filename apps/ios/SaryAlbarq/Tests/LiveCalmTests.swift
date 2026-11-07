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
        XCTAssertNil(LiveCalmRules.convoyLine([p("me", me: true, .live, nil), p("a", .stale(since: Date()), 300)]),
                     "nobody live: no «٠ مباشر», and a stale friend's old distance is not «الأبعد»")
    }

    // MARK: the map's side

    private let camera = SaryMapControlItem(id: "locate", systemImage: "location", label: "تتبعني", accessibilityID: "outing-locate")

    func testDrivingHasNoSideColumn() {
        XCTAssertTrue(LiveCalmRules.sideItems(camera: camera, backTrack: nil, plusBadge: nil, driving: true, ended: false).isEmpty)
    }

    func testStoppedKeepsTheCameraOnly() {
        /* «أدوات» left the map: it is «المزيد» in the sheet's quick row (one way in). */
        let items = LiveCalmRules.sideItems(camera: camera, backTrack: nil, plusBadge: 1, driving: false, ended: false)
        XCTAssertEqual(items.map(\.accessibilityID), ["outing-locate"])
    }

    func testBackTrackShortcutOnlyWhenItFitsAndNoToolsAfterTheEnd() {
        let back = SaryMapControlItem(id: "backtrack", systemImage: "x", label: "طريق العودة", accessibilityID: "outing-backtrack")
        XCTAssertEqual(LiveCalmRules.sideItems(camera: camera, backTrack: back, plusBadge: nil, driving: false, ended: false).map(\.id),
                       ["locate", "backtrack"])
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
        let groups = LiveActionCatalog.groups(.init(guideAllTarget: "الوجهة", channels: true))
        XCTAssertEqual(groups.map(\.title), ["الطريق", "الجماعة", "السلامة", "المكان", "الخريطة"])
        let grid = Set(groups.flatMap(\.items).map(\.id))
        XCTAssertLessThanOrEqual(grid.count, 15, "even with PTT channels and a leader navigation action, «المزيد» stays short")
        XCTAssertEqual(groups.first { $0.title == "السلامة" }?.items.map(\.title), ["غرّزت", "اتصل بإنجاد", "مؤقت الرجوع"])
        /* What left the grid is still reachable: the quick row, «الطبقات», the settings. */
        let quick: Set<String> = ["navigate", "chat", "rally", "backtrack"]
        XCTAssertTrue(quick.isSubset(of: LiveActionCatalog.inQuickRow))
        XCTAssertTrue(grid.isDisjoint(with: ["hires", "realistic", "effects", "radio", "youtube"]), "duplicates of «الطبقات» / settings are gone")
        XCTAssertTrue(grid.isSuperset(of: ["channels", "fit", "enjad", "convoy", "timer", "locationTools", "search", "note", "stuck",
                                           "nearest", "weatherTools", "explore", "route", "invite"]))
        let nested = Set(groups.flatMap(\.items).flatMap(\.children).map(\.id))
        XCTAssertEqual(nested, ["brief", "savePlace", "waypoint", "weather", "qibla"], "all related actions stay one tap inside their grouped tile")
    }

    func testToolsGridAfterTheEnd() {
        let ids = Set(LiveActionCatalog.groups(.init(ended: true, channels: true)).flatMap(\.items).map(\.id))
        XCTAssertTrue(ids.isDisjoint(with: LiveActionCatalog.needsRunningTrip), "\(ids)")
        XCTAssertTrue(ids.isSuperset(of: ["search", "navigate", "route", "explore", "weatherTools"]))
        let location = LiveActionCatalog.groups(.init(ended: true)).first { $0.title == "المكان" }?.items.first { $0.id == "locationTools" }
        XCTAssertFalse(location?.children.contains(where: { $0.id == "waypoint" }) ?? true, "adding route points requires a running trip")
        XCTAssertTrue(LiveActionCatalog.tripRouteActions(.init(ended: true, guideAllTarget: "x")).isEmpty)
    }

    func testChannelsTileOnlyWithChannels() {
        XCTAssertFalse(LiveActionCatalog.groups(.init()).flatMap(\.items).contains { $0.id == "channels" })
    }

    // MARK: auto-hiding bits

    func testChipAgeOnlyAfterTwoMinutes() {
        let now = Date()
        XCTAssertFalse(NameChipAge.shows(.live, now: now))
        XCTAssertFalse(NameChipAge.shows(.stale(since: now.addingTimeInterval(-90)), now: now), "«قبل ١ د» is noise")
        XCTAssertTrue(NameChipAge.shows(.stale(since: now.addingTimeInterval(-240)), now: now), "«خالد · قبل ٤ د»")
        XCTAssertTrue(NameChipAge.shows(.paused, now: now))
    }

    func testCompassBearingWrap() {
        XCTAssertEqual(LiveSideButtons.wrap(350), -10, accuracy: 1e-9)
        XCTAssertEqual(LiveSideButtons.wrap(-190), 170, accuracy: 1e-9)
    }

    // MARK: Lovable's settings rows

    func testMilesForEveryDistance() {
        defer { DistanceUnits.miles = false }
        XCTAssertEqual(SaryFormat.distance(meters: 1_240), "١٫٢ كم")
        DistanceUnits.miles = true
        XCTAssertEqual(SaryFormat.distance(meters: 1_609.344 * 2.5), "٢٫٥ ميل")
        XCTAssertEqual(SaryFormat.distance(meters: 30), "١٠٠ قدم")
        XCTAssertEqual(SaryFormat.distance(meters: 1_609.344 * 150), "١٥٠ ميل")
    }

    @MainActor func testDefaultChannelStartsANewOuting() {
        let d = UserDefaults(suiteName: "calm-channel")!
        d.removePersistentDomain(forName: "calm-channel")
        XCTAssertEqual(OutingWalkieTalkie.savedChannel("o1", defaults: d), "1")
        d.set("3", forKey: PTTChannels.preferredKey)
        XCTAssertEqual(OutingWalkieTalkie.savedChannel("o1", defaults: d), "3", "a new outing starts on «التردد الافتراضي»")
        d.set("5", forKey: OutingWalkieTalkie.channelKeyPrefix + "o1")
        XCTAssertEqual(OutingWalkieTalkie.savedChannel("o1", defaults: d), "5", "a channel chosen in this outing wins")
        d.set("9", forKey: PTTChannels.preferredKey)
        XCTAssertEqual(OutingWalkieTalkie.savedChannel("o2", defaults: d), "1", "only a public channel")
    }

    func testClearHistoryKeepsTheCurrentOuting() throws {
        let d = UserDefaults(suiteName: "calm-history")!
        d.removePersistentDomain(forName: "calm-history")
        TripLogStore.update("old", defaults: d) { _ in }
        TripLogStore.update("now", defaults: d) { _ in }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("calm-trails-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for id in ["old", "now"] { try Data("x".utf8).write(to: dir.appendingPathComponent(TrailStore.fileName(id))) }
        LocalTripHistory.clear(keeping: "now", defaults: d, trailsDir: dir)
        XCTAssertNil(TripLogStore.load("old", defaults: d))
        XCTAssertNotNil(TripLogStore.load("now", defaults: d))
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(left, [TrailStore.fileName("now")])
    }

    func testTimings() {
        XCTAssertEqual(VisualsSourceView.sourceSeconds, 5, "«الأجواء من الطقس» folds after 5 s")
        XCTAssertEqual(NoteFold.seconds, 10, "a note bubble folds to an icon after 10 s")
    }

    /// UX ٢١: the talk button says what it does in each «طريقة اللاسلكي».
    func testPTTLabelsFollowTheTalkMode() {
        XCTAssertEqual(SaryPTTButton.label(for: .idle, notes: true), "سجّل رسالة")
        XCTAssertEqual(SaryPTTButton.label(for: .idle, notes: false), "اضغط وتكلم")
        XCTAssertEqual(SaryPTTButton.label(for: .talking(seconds: 5, remaining: 55), notes: true), "يسجّل ٠:٠٥")
        XCTAssertEqual(SaryPTTButton.label(for: .talking(seconds: 5, remaining: 55), notes: false), "على الهواء ٠:٠٥")
        XCTAssertEqual(SaryPTTButton.label(for: .listening(name: "فهد", color: 0), notes: true), "رسالة من فهد")
        XCTAssertEqual(SaryPTTButton.label(for: .listening(name: "فهد", color: 0), notes: false), "فهد يتكلم")
        XCTAssertEqual(SaryPTTButton.label(for: .unavailable, notes: false), "اللاسلكي واقف · ما فيه شبكة", "persistent, with the reason")
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
