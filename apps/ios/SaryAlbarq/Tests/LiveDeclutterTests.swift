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
