import XCTest
@testable import SaryAlbarq

/// The name-chip declutter (`ChipLayout`) and the Mapbox ornament spot.
final class ChipLayoutTests: XCTestCase {
    let screen = CGRect(x: 0, y: 0, width: 440, height: 956)
    let chip = CGSize(width: 70, height: 26)

    func item(_ id: String, _ x: CGFloat, _ y: CGFloat, me: Bool = false, note: CGSize? = nil, prio: Int = 2) -> ChipLayout.Item {
        ChipLayout.Item(id: id, anchor: CGPoint(x: x, y: y), chip: chip, note: note, isMe: me, priority: prio)
    }

    func opts(_ f: (inout ChipLayout.Options) -> Void = { _ in }) -> ChipLayout.Options {
        var o = ChipLayout.Options(bounds: screen)
        f(&o)
        return o
    }

    /// No two drawn things (chips, notes, group chips) overlap.
    func assertNoOverlap(_ r: ChipLayout.Result, file: StaticString = #filePath, line: UInt = #line) {
        let rects = r.chips.map(\.frame) + r.chips.compactMap(\.noteFrame) + r.groups.map(\.frame)
        for i in rects.indices {
            for j in rects.indices where j > i {
                XCTAssertFalse(rects[i].intersects(rects[j]), "\(rects[i]) overlaps \(rects[j])", file: file, line: line)
            }
        }
    }

    func testFarApartChipsStayOverTheirCarsWithoutLines() {
        let r = ChipLayout.solve([item("a", 100, 400), item("b", 300, 600)], opts())
        XCTAssertEqual(r.chips.count, 2)
        XCTAssertTrue(r.groups.isEmpty)
        for p in r.chips {
            XCTAssertFalse(p.leader)
            XCTAssertEqual(p.frame.midX, p.anchor.x, accuracy: 0.5)
            XCTAssertEqual(p.frame.maxY, p.anchor.y - 22, accuracy: 0.5)
        }
    }

    /// The drive-light screenshot: «أنت», «سعد», «سلطان» parked within a few points.
    func testThreeCloseCarsStackInAColumnWithLeaders() {
        let r = ChipLayout.solve([item("me", 250, 1000 - 40, me: true), item("saad", 245, 975), item("sultan", 262, 990)], opts())
        XCTAssertTrue(r.groups.isEmpty, "three fit in one column")
        XCTAssertEqual(r.chips.count, 3)
        assertNoOverlap(r)
        let xs = Set(r.chips.map { Int($0.frame.midX.rounded()) })
        XCTAssertEqual(xs.count, 1, "one column")
        XCTAssertTrue(r.chips.contains(where: \.leader), "moved chips are tied to their car")
        /* «أنت» is nearest the cars (lowest in the column) and drawn last (on top). */
        let me = r.chips.first(where: \.isMe)!
        XCTAssertEqual(me.frame.maxY, r.chips.map(\.frame.maxY).max()!)
        XCTAssertTrue(r.chips.last!.isMe)
    }

    func testCrowdFoldsFriendsIntoAGroupButNeverMe() {
        var items = [item("me", 200, 500, me: true)]
        for i in 0..<5 { items.append(item("f\(i)", 200 + CGFloat(i) * 6, 505)) }
        let r = ChipLayout.solve(items, opts())
        XCTAssertEqual(r.groups.count, 1)
        XCTAssertEqual(Set(r.groups[0].ids), Set((0..<5).map { "f\($0)" }))
        XCTAssertEqual(r.chips.map(\.id), ["me"], "only «أنت» keeps its own chip")
        XCTAssertFalse(r.groups[0].ids.contains("me"))
        assertNoOverlap(r)
        /* The group sits above «أنت». */
        XCTAssertLessThan(r.groups[0].frame.maxY, r.chips[0].frame.minY)
    }

    func testGroupWithoutMeSitsOverTheCentroid() {
        let r = ChipLayout.solve((0..<4).map { item("f\($0)", 100 + CGFloat($0) * 4, 300) }, opts())
        XCTAssertEqual(r.groups.count, 1)
        XCTAssertTrue(r.chips.isEmpty)
        XCTAssertEqual(r.groups[0].frame.midX, 106, accuracy: 0.5)
        XCTAssertEqual(r.groups[0].key, ChipLayout.groupKey(["f3", "f1", "f0", "f2"]))
    }

    func testExpandedGroupListsEveryone() {
        let items = (0..<5).map { item("f\($0)", 200, 600 + CGFloat($0)) }
        let r = ChipLayout.solve(items, opts { $0.expanded = Set(items.map(\.id)) })
        XCTAssertTrue(r.groups.isEmpty)
        XCTAssertEqual(r.chips.count, 5)
        assertNoOverlap(r)
    }

    func testSpreadColumnAbsorbingOneMoreChipStaysSpread() {
        let items = (0..<4).map { item("f\($0)", 200, 600 + CGFloat($0)) } + [item("late", 202, 470)]
        let r = ChipLayout.solve(items, opts { $0.expanded = Set((0..<4).map { "f\($0)" }) })
        XCTAssertTrue(r.groups.isEmpty)
        assertNoOverlap(r)
        /* Two strangers joining fold again. */
        let more = items + [item("late2", 198, 468)]
        XCTAssertEqual(ChipLayout.solve(more, opts { $0.expanded = Set((0..<4).map { "f\($0)" }) }).groups.count, 1)
    }

    func testDriveModeFoldsSooner() {
        let items = [item("a", 200, 600), item("b", 205, 600), item("c", 210, 600)]
        XCTAssertTrue(ChipLayout.solve(items, opts()).groups.isEmpty)
        XCTAssertEqual(ChipLayout.solve(items, opts { $0.maxStack = 2 }).groups.count, 1)
    }

    func testNoteShowsWhenThereIsRoomAndCollapsesInACrowd() {
        let note = CGSize(width: 150, height: 40)
        let alone = ChipLayout.solve([item("a", 200, 600, note: note), item("b", 200, 200)], opts())
        let a = alone.chips.first { $0.id == "a" }!
        XCTAssertNotNil(a.noteFrame)
        XCTAssertFalse(a.noteCollapsed)
        XCTAssertLessThan(a.noteFrame!.maxY, a.frame.minY + 0.1)

        let crowded = ChipLayout.solve([item("a", 200, 600, note: note), item("b", 205, 602)], opts())
        let c = crowded.chips.first { $0.id == "a" }!
        XCTAssertNil(c.noteFrame)
        XCTAssertTrue(c.noteCollapsed)
        assertNoOverlap(crowded)
    }

    func testNoteCollapsesWhenItWouldCoverAnotherChip() {
        /* b's chip sits exactly where a's note would go. */
        let r = ChipLayout.solve([item("a", 200, 600, note: CGSize(width: 150, height: 40)), item("b", 200, 570)], opts())
        assertNoOverlap(r)
        let a = r.chips.first { $0.id == "a" }
        if let a, a.noteFrame == nil { XCTAssertTrue(a.noteCollapsed) }
    }

    func testMyNoteWinsTheRoom() {
        let note = CGSize(width: 180, height: 40)
        /* Two singles far enough apart for their chips, but their notes would collide. */
        let r = ChipLayout.solve([item("b", 260, 600, note: note), item("me", 140, 600, me: true, note: note)], opts())
        XCTAssertNotNil(r.chips.first { $0.isMe }!.noteFrame)
        XCTAssertTrue(r.chips.first { $0.id == "b" }!.noteCollapsed)
        assertNoOverlap(r)
    }

    func testStackFlipsBelowWhenItWouldRunOffTheTop() {
        let r = ChipLayout.solve([item("a", 200, 60), item("b", 204, 62), item("c", 208, 64)], opts())
        XCTAssertTrue(r.chips.allSatisfy { $0.frame.minY >= 0 })
        XCTAssertTrue(r.chips.allSatisfy { $0.frame.minY > 60 })
        assertNoOverlap(r)
    }

    func testChipsAtTheEdgeStayOnScreen() {
        let r = ChipLayout.solve([item("a", 3, 400)], opts())
        XCTAssertGreaterThanOrEqual(r.chips[0].frame.minX, 4)
        let s = ChipLayout.solve([item("a", 438, 400), item("b", 436, 405)], opts())
        XCTAssertTrue(s.chips.allSatisfy { $0.frame.maxX <= 436 })
    }

    func testFarOffScreenCarsAreNotClustered() {
        let r = ChipLayout.solve([item("a", -900, 400), item("b", -905, 400)], opts())
        XCTAssertTrue(r.groups.isEmpty)
        XCTAssertEqual(r.chips.count, 2)
    }

    func testStableWhenInputOrderChanges() {
        let items = [item("me", 250, 900, me: true), item("x", 255, 905), item("y", 245, 910), item("z", 260, 300)]
        XCTAssertEqual(ChipLayout.solve(items, opts()), ChipLayout.solve(items.reversed(), opts()))
    }

    func testChainedClustersNeverOverlap() {
        /* A dense line of cars: merging cascades until the result is clean. */
        let items = (0..<12).map { item("c\($0)", 60 + CGFloat($0) * 28, 500 + CGFloat($0 % 3) * 9) }
        assertNoOverlap(ChipLayout.solve(items, opts()))
    }

    func testRandomScenesNeverOverlap() {
        var g = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            let n = Int.random(in: 2...14, using: &g)
            var items: [ChipLayout.Item] = []
            for i in 0..<n {
                let note: CGSize? = Bool.random(using: &g) ? CGSize(width: .random(in: 80...200, using: &g), height: 36) : nil
                items.append(item("m\(i)", .random(in: 150...290, using: &g), .random(in: 380...560, using: &g), me: i == 0, note: note, prio: .random(in: 0...2, using: &g)))
            }
            let r = ChipLayout.solve(items, opts())
            assertNoOverlap(r)
            XCTAssertTrue(r.chips.contains(where: \.isMe), "«أنت» is always visible")
            XCTAssertTrue(r.chips.last?.isMe ?? false, "«أنت» on top")
            let shown = Set(r.chips.map(\.id)).union(r.groups.flatMap(\.ids))
            XCTAssertEqual(shown, Set(items.map(\.id)), "everyone is either a chip or in a group")
        }
    }

    func testCarsCountWording() {
        XCTAssertEqual(SaryFormat.cars(2), "سيارتان")
        XCTAssertEqual(SaryFormat.cars(3), "٣ سيارات")
        XCTAssertEqual(SaryFormat.cars(11), "١١ سيارة")
    }

    // MARK: ornaments

    func testOrnamentsTakeTheFirstFreeSpot() {
        let a = OrnamentSpot.Candidate(rect: CGRect(x: 160, y: 800, width: 115, height: 24), name: "bottom-center")
        let b = OrnamentSpot.Candidate(rect: CGRect(x: 8, y: 800, width: 115, height: 24), name: "bottom-left")
        XCTAssertEqual(OrnamentSpot.choose([a, b], avoid: [])?.name, "bottom-center")
        /* The rally label sits on the first spot: move to the next one. */
        XCTAssertEqual(OrnamentSpot.choose([a, b], avoid: [CGRect(x: 150, y: 780, width: 120, height: 60)])?.name, "bottom-left")
        /* Nothing is free: the least covered, never nothing (the logo must stay visible). */
        let both = [CGRect(x: 150, y: 790, width: 200, height: 40), CGRect(x: 0, y: 805, width: 40, height: 10)]
        XCTAssertEqual(OrnamentSpot.choose([a, b], avoid: both)?.name, "bottom-left")
    }
}

/// Offline area rules.
final class OfflinePlanTests: XCTestCase {
    func box(_ km: Double) -> OfflinePlan.Box {
        let dLat = km / 111.0, dLng = km / (111.0 * cos(24.7 * .pi / 180))
        return .init(west: 46.67 - dLng / 2, south: 24.7 - dLat / 2, east: 46.67 + dLng / 2, north: 24.7 + dLat / 2)
    }

    func testSizeLimits() {
        XCTAssertEqual(box(5).widthKm, 5, accuracy: 0.05)
        XCTAssertEqual(OfflinePlan.check(box(5), estimateBytes: 30_000_000, usedBytes: 0), .ok)
        XCTAssertEqual(OfflinePlan.check(box(0.2), estimateBytes: nil, usedBytes: 0), .tooSmall)
        XCTAssertEqual(OfflinePlan.check(box(80), estimateBytes: nil, usedBytes: 0), .tooBig(maxKm: 60))
    }

    func testTotalCapIsEnforcedAndExplained() {
        let used = OfflinePlan.totalCapBytes - 10_000_000
        XCTAssertEqual(OfflinePlan.check(box(5), estimateBytes: 30_000_000, usedBytes: used), .overCap(freeBytes: 10_000_000))
        /* Without an estimate (offline) the size is checked as it downloads. */
        XCTAssertEqual(OfflinePlan.check(box(5), estimateBytes: nil, usedBytes: used), .ok)
    }

    func testZoomsAndTilesetsMatchTheLiveMap() {
        XCTAssertEqual(OfflinePlan.minZoom, 11)
        XCTAssertEqual(OfflinePlan.maxZoom, 16)
        XCTAssertTrue(OfflinePlan.extraTilesets.contains("mapbox://mapbox.mapbox-streets-v8"))
        XCTAssertTrue(OfflinePlan.extraTilesets.contains("mapbox://mapbox.mapbox-terrain-dem-v1"))
        XCTAssertTrue(OfflinePlan.regionId().hasPrefix("sary-"))
    }

    // MARK: offline area picker box (AreaPickerMap.boxRect)

    func testOfflineBoxIsUnchangedOnStandardAndLargePhones() {
        for size in [CGSize(width: 393, height: 852), CGSize(width: 440, height: 956), CGSize(width: 375, height: 812)] {
            let r = AreaPickerMap.boxRect(in: size)
            XCTAssertEqual(r.width, min(size.width - 48, size.height * 0.42), accuracy: 0.001, "\(size)")
        }
    }

    func testOfflineBoxStaysAboveThePanelOnAnSE() {
        let size = CGSize(width: 375, height: 667)
        let r = AreaPickerMap.boxRect(in: size)
        XCTAssertEqual(r.width, 667 - AreaPickerMap.chromeHeight, accuracy: 0.001)
        // The panel (≈ 300 pt + margins) starts around y 350 on an SE.
        XCTAssertLessThanOrEqual(r.maxY, 352)
        XCTAssertGreaterThanOrEqual(AreaPickerMap.boxRect(in: CGSize(width: 320, height: 568)).width, 120)
    }
}
