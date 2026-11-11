import XCTest
@testable import SaryAlbarq

/// A burst of alerts (stuck + convoy + silence + weather) keeps at most 2 cards; the rest fold into «+٢ تنبيهات».
final class AlertLaneTests: XCTestCase {
    private func alerts(_ n: Int) -> [LiveAlertUI] {
        (0..<n).map { LiveAlertUI(id: "a\($0)", kind: .toast("تنبيه \($0)")) }
    }

    func testBurstShowsTwoAndFoldsTheRest() {
        let v = SaryAlertLane.visible(alerts(4), limit: SaryAlertLane.defaultLimit, expanded: false)
        XCTAssertEqual(v.shown.map(\.id), ["a0", "a1"])
        XCTAssertEqual(v.hidden, 2)
        XCTAssertEqual(SaryAlertLane.overflowLabel(v.hidden), "+٢ تنبيهات")
    }

    func testExpandedShowsAll() {
        let v = SaryAlertLane.visible(alerts(4), limit: 2, expanded: true)
        XCTAssertEqual(v.shown.count, 4)
        XCTAssertEqual(v.hidden, 0)
    }

    func testFewAlertsNothingFolded() {
        let v = SaryAlertLane.visible(alerts(2), limit: 2, expanded: false)
        XCTAssertEqual(v.shown.count, 2)
        XCTAssertEqual(v.hidden, 0)
        XCTAssertEqual(SaryAlertLane.overflowLabel(1), "+١ تنبيه")
    }

    func testDriveKeepsOne() {
        let v = SaryAlertLane.visible(alerts(3), limit: 1, expanded: false)
        XCTAssertEqual(v.shown.count, 1)
        XCTAssertEqual(v.hidden, 2)
    }
}

/// «نقطة البداية» gives its label up to the cars' chips (icon only), with hysteresis.
final class StartPinLayoutTests: XCTestCase {
    func testLabelSitsAboveTheIcon() {
        let r = StartPinLayout.rects(anchor: CGPoint(x: 200, y: 400))
        XCTAssertEqual(r.icon.maxY, 400)
        XCTAssertLessThan(r.label.maxY, r.icon.minY)
        XCTAssertEqual(r.label.midX, 200)
    }

    func testChipOnTheLabelFoldsIt() {
        let r = StartPinLayout.rects(anchor: CGPoint(x: 200, y: 400))
        let chip = CGRect(x: 180, y: r.label.minY + 4, width: 80, height: 28)
        XCTAssertTrue(StartPinLayout.crowded(label: r.label, chips: [chip], wasCompact: false))
        XCTAssertFalse(StartPinLayout.crowded(label: r.label, chips: [CGRect(x: 0, y: 0, width: 40, height: 20)], wasCompact: false))
    }

    func testUnfoldsOnlyWithMargin() {
        let r = StartPinLayout.rects(anchor: CGPoint(x: 200, y: 400))
        /* 6 pt away: still folded once folded, but would not fold a clear label. */
        let near = CGRect(x: r.label.maxX + 6, y: r.label.minY, width: 60, height: 24)
        XCTAssertTrue(StartPinLayout.crowded(label: r.label, chips: [near], wasCompact: true))
        XCTAssertFalse(StartPinLayout.crowded(label: r.label, chips: [near], wasCompact: false))
    }
}

/// UI-AUDIT م3 (docs/UI-AUDIT.md §٢ «شاشة الطلعة لكل حالة»): what each state of the live screen
/// keeps — one primary (the CTA), each action once (`LiveScreenRules`).
final class LiveScreenRulesTests: XCTestCase {
    func testQuickRowIsFourAndOnlyWhileStoppedInARunningTrip() {
        XCTAssertEqual(LiveScreenRules.quickRow(chat: true), ["desert", "chat", "rally", "more"])
        XCTAssertEqual(LiveScreenRules.quickRow(chat: false), ["desert", "rally", "more"], "no chat on an older server")
        XCTAssertFalse(LiveScreenRules.quickRow(chat: true).contains("hide"), "«أخفِ موقعي» is in «المزيد»")
        XCTAssertFalse(LiveScreenRules.quickRow(chat: true).contains("backtrack"), "«طريق الرجعة» is the side shortcut / «المزيد»")
        XCTAssertTrue(LiveScreenRules.showsQuickRow(ended: false, notStarted: false, navigating: false, driving: false, sosFocused: false))
        XCTAssertFalse(LiveScreenRules.showsQuickRow(ended: false, notStarted: true, navigating: false, driving: false, sosFocused: false),
                       "not started: the map, SOS, the CTA and the sheet (people + «ادعُ ربعك») only")
        XCTAssertFalse(LiveScreenRules.showsQuickRow(ended: false, notStarted: false, navigating: true, driving: false, sosFocused: false))
        XCTAssertFalse(LiveScreenRules.showsQuickRow(ended: false, notStarted: false, navigating: false, driving: true, sosFocused: false))
        XCTAssertFalse(LiveScreenRules.showsQuickRow(ended: true, notStarted: false, navigating: false, driving: false, sosFocused: false))
        XCTAssertFalse(LiveScreenRules.showsQuickRow(ended: false, notStarted: false, navigating: false, driving: false, sosFocused: true),
                       "my SOS on: the focused mode")
    }

    /// Owner report (Build 36, «اهتزاز النافذة السفلية»): the peek detent's height must not depend on
    /// where the sheet is. Raising it reads «stopped» (`LiveContextRule`), which used to add the quick
    /// row to the PEEK height too (88 → 172 in drive mode), so the detent set changed under the
    /// finger and SwiftUI re-snapped the sheet by itself.
    func testPeekQuickRowIgnoresTheSheetPosition() {
        let peek = { (o: LiveContextOverride, moving: Bool, drive: Bool) in
            LiveScreenRules.peekShowsQuickRow(override: o, navigating: false, moving: moving, driveMode: drive,
                                              exploring: false, ended: false, notStarted: false, sosFocused: false)
        }
        XCTAssertTrue(peek(.auto, false, false), "stopped: the quick row is part of the peek")
        XCTAssertFalse(peek(.auto, false, true), "drive mode at peek: no quick row, whatever the raised sheet reads")
        XCTAssertFalse(peek(.auto, true, false), "moving at peek: no quick row")
        XCTAssertFalse(peek(.driving, false, false))
        XCTAssertTrue(peek(.stopped, true, true))
        /* It is exactly the content rule as it stands AT PEEK (sheet not raised). */
        for o in LiveContextOverride.allCases {
            for moving in [false, true] {
                for drive in [false, true] {
                    let atPeek = LiveContextRule.resolve(override: o, navigating: false, moving: moving, driveMode: drive, sheetRaised: false)
                    XCTAssertEqual(peek(o, moving, drive),
                                   LiveScreenRules.showsQuickRow(ended: false, notStarted: false, navigating: false,
                                                                 driving: atPeek == .driving, sosFocused: false))
                }
            }
        }
        XCTAssertFalse(LiveScreenRules.peekShowsQuickRow(override: .auto, navigating: true, moving: false, driveMode: false,
                                                         exploring: false, ended: false, notStarted: false, sosFocused: false),
                       "guiding: the peek is the guidance bar")
        XCTAssertFalse(LiveScreenRules.peekShowsQuickRow(override: .auto, navigating: false, moving: false, driveMode: false,
                                                         exploring: false, ended: true, notStarted: false, sosFocused: false))
        XCTAssertFalse(LiveScreenRules.peekShowsQuickRow(override: .auto, navigating: false, moving: false, driveMode: false,
                                                         exploring: false, ended: false, notStarted: true, sosFocused: false))
        XCTAssertFalse(LiveScreenRules.peekShowsQuickRow(override: .auto, navigating: false, moving: false, driveMode: false,
                                                         exploring: false, ended: false, notStarted: false, sosFocused: true))
    }

    /// The detent shape a finger went down with stays until the settle is over.
    func testSheetShapeHoldsStillWhileFrozen() {
        let stopped = LiveSheetShape(drive: false, trip: true)
        let driving = LiveSheetShape(drive: true, trip: false)
        XCTAssertEqual(LiveSheetShape.resolve(live: driving, frozen: stopped), stopped)
        XCTAssertEqual(LiveSheetShape.resolve(live: driving, frozen: nil), driving)
        XCTAssertEqual(stopped.peekHeight, SheetDetentUI.peekHeight(drive: false, trip: true))
        XCTAssertEqual(driving.peekHeight, SheetDetentUI.peekHeight(drive: true, trip: false))
    }

    func testSOSFocusOnlyOnceSent() {
        XCTAssertFalse(LiveScreenRules.sosFocused(.none))
        XCTAssertFalse(LiveScreenRules.sosFocused(.sending))
        XCTAssertTrue(LiveScreenRules.sosFocused(.active(since: Date())))
    }

    func testBackTrackShortcutNeverDuplicatesTheRunningPanel() {
        XCTAssertTrue(LiveScreenRules.backTrackShortcut(running: false, arrived: true, offRoute: false))
        XCTAssertTrue(LiveScreenRules.backTrackShortcut(running: false, arrived: false, offRoute: true))
        XCTAssertFalse(LiveScreenRules.backTrackShortcut(running: false, arrived: false, offRoute: false), "only when it fits the moment")
        XCTAssertFalse(LiveScreenRules.backTrackShortcut(running: true, arrived: true, offRoute: true), "running: the panel's «أنهِ الرجعة» only")
    }

    func testGuidingKeepsTwoSideCircles() {
        XCTAssertEqual(LiveScreenRules.navSideIDs, ["locate", "nav.search"])
        XCTAssertFalse(LiveScreenRules.navSideIDs.contains("nav.mute"), "«الصوت» is in the guidance sheet")
        XCTAssertFalse(LiveScreenRules.navSideIDs.contains("nav.routes"), "«المسارات» is in the guidance sheet")
    }

    func testConvoyLineOnlyWithAConvoyAlert() {
        XCTAssertFalse(LiveScreenRules.showsConvoyLine([]))
        XCTAssertFalse(LiveScreenRules.showsConvoyLine([LiveAlertUI(id: "t", kind: .toast("نُسخ"))]))
        XCTAssertTrue(LiveScreenRules.showsConvoyLine([LiveAlertUI(id: "d", kind: .drift(name: "فهد", color: 0, distanceMeters: 900))]))
    }

    func testAlertHistoryOnceAndOnlyWithSomethingInIt() {
        XCTAssertFalse(LiveScreenRules.showsBell(bell: 0, hasHistory: false, open: false), "nothing yet: no button")
        XCTAssertTrue(LiveScreenRules.showsBell(bell: 2, hasHistory: false, open: false))
        XCTAssertTrue(LiveScreenRules.showsBell(bell: 0, hasHistory: true, open: false))
        XCTAssertTrue(LiveScreenRules.showsBell(bell: 0, hasHistory: false, open: true), "open: the button closes it")
        XCTAssertFalse(LiveScreenRules.historyBesideCard(bannerOnly: false), "with the header, its bell is the one way in")
        XCTAssertTrue(LiveScreenRules.historyBesideCard(bannerOnly: true))
    }

    /// «روح له» asks before replacing guidance, like «اتجه»; refreshing the same friend does not.
    func testGoToMemberConfirmsADestinationChange() {
        XCTAssertTrue(LiveScreenRules.memberGoNeedsConfirm(phase: .guiding, currentMemberId: nil, memberId: "fahad"))
        XCTAssertTrue(LiveScreenRules.memberGoNeedsConfirm(phase: .offRoad, currentMemberId: "salem", memberId: "fahad"))
        XCTAssertTrue(LiveScreenRules.memberGoNeedsConfirm(phase: .planning, currentMemberId: nil, memberId: "fahad"))
        XCTAssertFalse(LiveScreenRules.memberGoNeedsConfirm(phase: .guiding, currentMemberId: "fahad", memberId: "fahad"), "«حدّث الطريق»")
        XCTAssertFalse(LiveScreenRules.memberGoNeedsConfirm(phase: .idle, currentMemberId: nil, memberId: "fahad"))
        XCTAssertFalse(LiveScreenRules.memberGoNeedsConfirm(phase: .arrived, currentMemberId: nil, memberId: "fahad"))
    }
}
