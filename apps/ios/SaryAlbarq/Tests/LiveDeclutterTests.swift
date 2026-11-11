import SwiftUI
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
    func testPrimaryIsCompactWhileDrivingOrSheetRaised() {
        XCTAssertFalse(LiveScreenRules.primaryCompact(sheetRaised: false, driving: false), "stopped: the primary is big")
        XCTAssertTrue(LiveScreenRules.primaryCompact(sheetRaised: false, driving: true), "driving: «وين رايحين؟» too is a pill")
        XCTAssertTrue(LiveScreenRules.primaryCompact(sheetRaised: true, driving: false))
    }

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

/// Screen-size adaptation (`LiveFit`): the regular design on a standard phone, the compact one
/// only on short / narrow screens or with large text.
final class LiveFitTests: XCTestCase {
    /// iPhone SE 2/3, 13 mini, 15/16, 16 Pro Max (points, portrait).
    let se = CGSize(width: 375, height: 667)
    let mini = CGSize(width: 375, height: 812)
    let standard = CGSize(width: 393, height: 852)
    let proMax = CGSize(width: 440, height: 956)
    /// Display Zoom: an SE at 320 × 568, a mini at 320 × 693.
    let zoomedSE = CGSize(width: 320, height: 568)
    let zoomedMini = CGSize(width: 320, height: 693)

    func testOnlyTheSEIsShort() {
        XCTAssertTrue(LiveFit.compactHeight(se.height))
        XCTAssertFalse(LiveFit.compactHeight(mini.height))
        XCTAssertFalse(LiveFit.compactHeight(standard.height))
        XCTAssertFalse(LiveFit.compactHeight(proMax.height))
        XCTAssertFalse(LiveFit.compactHeight(0), "not measured yet: the regular layout")
        XCTAssertTrue(LiveFit.compactHeight(zoomedSE.height), "Display Zoom")
        XCTAssertTrue(LiveFit.compactHeight(zoomedMini.height))
    }

    func testSideStepsAsideForTheAlertListOnlyWhenShort() {
        XCTAssertTrue(LiveFit.sideWithAlertList(bellOpen: false, screenHeight: zoomedSE.height))
        XCTAssertFalse(LiveFit.sideWithAlertList(bellOpen: true, screenHeight: zoomedSE.height))
        XCTAssertFalse(LiveFit.sideWithAlertList(bellOpen: true, screenHeight: se.height))
        XCTAssertTrue(LiveFit.sideWithAlertList(bellOpen: true, screenHeight: standard.height), "unchanged on a standard phone")
        /* 320 × 568, list open, no side: 20 + 4 + 70 header + 8 + list ends above the dock (568 − 142 − 8 − 84). */
        XCTAssertLessThanOrEqual(20 + 4 + 70 + 8 + LiveFit.alertListMaxHeight(screenHeight: zoomedSE.height), 568 - 142 - 8 - 84)
    }

    func testHeaderWeatherFollowsTheRealWidth() {
        XCTAssertFalse(LiveFit.showsHeaderWeather(width: se.width, largeText: false), "375 pt: the state line needs the width")
        XCTAssertFalse(LiveFit.showsHeaderWeather(width: zoomedSE.width, largeText: false), "Display Zoom")
        XCTAssertFalse(LiveFit.showsHeaderWeather(width: mini.width, largeText: false))
        XCTAssertTrue(LiveFit.showsHeaderWeather(width: standard.width, largeText: false), "unchanged on a standard phone")
        XCTAssertTrue(LiveFit.showsHeaderWeather(width: proMax.width, largeText: false))
        XCTAssertFalse(LiveFit.showsHeaderWeather(width: standard.width, largeText: true), "large text: only the widest phones keep it")
        XCTAssertTrue(LiveFit.showsHeaderWeather(width: proMax.width, largeText: true))
        XCTAssertTrue(LiveFit.showsHeaderWeather(width: 0, largeText: false), "not measured yet")
    }

    func testAlertListStaysAboveTheDockOnTheSE() {
        XCTAssertEqual(LiveFit.alertListMaxHeight(screenHeight: standard.height), standard.height * 0.42, accuracy: 0.01, "unchanged")
        XCTAssertEqual(LiveFit.alertListMaxHeight(screenHeight: proMax.height), proMax.height * 0.42, accuracy: 0.01)
        XCTAssertEqual(LiveFit.alertListMaxHeight(screenHeight: se.height), 200)
        /* SE stopped, list open: 20 status + 4 + 70 header + 8 + list + 8 + 106 side (no captions)
         * must end above the dock (667 − 142 peek − 8 − 84 disc row ≈ 433). */
        XCTAssertLessThanOrEqual(20 + 4 + 70 + 8 + LiveFit.alertListMaxHeight(screenHeight: se.height) + 8 + 106, 433)
    }

    func testSideCaptionsDropOnlyWhenShortOrGuiding() {
        XCTAssertTrue(LiveFit.sideCaptions(guiding: false, screenHeight: standard.height))
        XCTAssertTrue(LiveFit.sideCaptions(guiding: false, screenHeight: mini.height))
        XCTAssertFalse(LiveFit.sideCaptions(guiding: false, screenHeight: se.height))
        XCTAssertFalse(LiveFit.sideCaptions(guiding: true, screenHeight: standard.height))
    }

    func testDockKeepsTheDesignWhenThereIsRoom() {
        /* Stopped, no primary: the 178 pt pill alone. */
        let alone = LiveFit.dock(width: standard.width - 32, ptt: LiveFit.pillPTTWidth, speed: 0, cta: nil, cluster: 0)
        XCTAssertEqual(alone, LiveFit.Dock(pttMinWidth: LiveFit.pillPTTWidth, ctaOwnRow: false))
        /* Driving, speed + big pill, no primary. */
        let speed = LiveFit.dock(width: se.width - 32, ptt: LiveFit.bigPTTWidth, speed: LiveFit.speedBubbleWidth, cta: nil, cluster: 0)
        XCTAssertEqual(speed, LiveFit.Dock(pttMinWidth: LiveFit.bigPTTWidth, ctaOwnRow: false))
        /* Pro Max: speed + big pill + «وصلنا» all fit at full size. */
        let wide = LiveFit.dock(width: proMax.width - 32, ptt: LiveFit.bigPTTWidth, speed: LiveFit.speedBubbleWidth,
                                cta: LiveFit.compactCTAWidth(title: "وصلنا"), cluster: 0)
        XCTAssertEqual(wide, LiveFit.Dock(pttMinWidth: LiveFit.bigPTTWidth, ctaOwnRow: false))
    }

    func testDockNeverOverflowsANarrowPhone() {
        for size in [zoomedSE, zoomedMini, se, mini, standard, proMax] {
            let width = size.width - 32
            for title in ["وصلنا", "وين رايحين؟", "استأنف التوجيه", "ننتظر أمير الطلعة"] {
                for (speed, cluster) in [(LiveFit.speedBubbleWidth, CGFloat(0)), (0, LiveFit.navSpeedClusterWidth(drive: true, limit: true))] {
                    let cta = LiveFit.compactCTAWidth(title: title)
                    let fit = LiveFit.dock(width: width, ptt: LiveFit.bigPTTWidth, speed: speed, cta: cta, cluster: cluster)
                    XCTAssertGreaterThanOrEqual(fit.pttMinWidth, LiveFit.minPTTWidth)
                    let row = (speed > 0 ? speed + 8 : 0) + fit.pttMinWidth + (cluster > 0 ? cluster + 8 : 0) + (fit.ctaOwnRow ? 0 : cta + 8)
                    XCTAssertLessThanOrEqual(row, width, "\(size) «\(title)»: the row fits")
                    if fit.ctaOwnRow { XCTAssertLessThanOrEqual(cta, width, "its own row fits it") }
                }
            }
        }
    }

    func testDockOnTheSE() {
        let width = se.width - 32
        /* Speed + pill + «وصلنا»: the pill narrows, the primary stays in the row. */
        let arrived = LiveFit.dock(width: width, ptt: LiveFit.bigPTTWidth, speed: LiveFit.speedBubbleWidth,
                                   cta: LiveFit.compactCTAWidth(title: "وصلنا"), cluster: 0)
        XCTAssertFalse(arrived.ctaOwnRow)
        XCTAssertLessThan(arrived.pttMinWidth, LiveFit.bigPTTWidth)
        /* Guiding: pill + primary + speed and limit do not fit: the primary moves up a row. */
        let guiding = LiveFit.dock(width: width, ptt: LiveFit.bigPTTWidth, speed: 0,
                                   cta: LiveFit.compactCTAWidth(title: "وصلنا"), cluster: LiveFit.navSpeedClusterWidth(drive: true, limit: true))
        XCTAssertTrue(guiding.ctaOwnRow)
        XCTAssertEqual(guiding.pttMinWidth, LiveFit.bigPTTWidth)
        XCTAssertEqual(LiveFit.dock(width: 0, ptt: 200, speed: 76, cta: 100, cluster: 0), LiveFit.Dock(pttMinWidth: 200, ctaOwnRow: false), "not measured yet")
    }

    func testTextScaleGrowsAndIsCappedAtTheDockCap() {
        XCTAssertEqual(LiveFit.textScale(.large), 1)
        XCTAssertLessThan(LiveFit.textScale(.small), 1)
        XCTAssertEqual(LiveFit.textScale(.xxLarge), LiveFit.textScale(.accessibility5), "the dock is capped at xxLarge")
        XCTAssertGreaterThan(LiveFit.compactCTAWidth(title: "وصلنا", textScale: 1.24), LiveFit.compactCTAWidth(title: "وصلنا"))
    }
}
