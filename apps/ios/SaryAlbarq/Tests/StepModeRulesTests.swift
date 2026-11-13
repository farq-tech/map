import XCTest
@testable import SaryAlbarq

/// «التوجيه خطوة بخطوة» عند ضعف GPS (UX backlog R4): متى نقترحه، ومتى نرجع للتتبع الحي.
final class StepModeRulesTests: XCTestCase {
    private func feed(_ r: inout StepModeRules, accuracy: Double, from: Double, to: Double, every: Double = 1) {
        var t = from
        while t <= to { r.ingest(accuracyM: accuracy, at: t); t += every }
    }

    func testGoodSignalNeverSuggests() {
        var r = StepModeRules()
        feed(&r, accuracy: 8, from: 0, to: 300)
        XCTAssertEqual(r.mode, .live)
    }

    func testBadSignalForLongEnoughSuggests() {
        var r = StepModeRules()
        feed(&r, accuracy: 120, from: 0, to: 19)
        XCTAssertEqual(r.mode, .live, "not yet: 19 s")
        r.ingest(accuracyM: 120, at: 20)
        XCTAssertEqual(r.mode, .suggested)
    }

    func testAnInvalidFixCountsAsBad() {
        var r = StepModeRules()
        feed(&r, accuracy: -1, from: 0, to: 25)
        XCTAssertEqual(r.mode, .suggested)
    }

    func testABorderlineFixDoesNotFlap() {
        var r = StepModeRules()
        feed(&r, accuracy: 120, from: 0, to: 15)
        r.ingest(accuracyM: 45, at: 16)          // between good (30) and bad (60): neither streak breaks
        feed(&r, accuracy: 120, from: 17, to: 25)
        XCTAssertEqual(r.mode, .suggested)
    }

    func testAGoodFixBreaksTheBadStreak() {
        var r = StepModeRules()
        feed(&r, accuracy: 120, from: 0, to: 15)
        r.ingest(accuracyM: 8, at: 16)
        feed(&r, accuracy: 120, from: 17, to: 30)
        XCTAssertEqual(r.mode, .live, "a new streak starts at 17 s: only 13 s old")
    }

    func testSignalBackBeforeAnswerWithdrawsTheOffer() {
        var r = StepModeRules()
        feed(&r, accuracy: 120, from: 0, to: 20)
        XCTAssertEqual(r.mode, .suggested)
        feed(&r, accuracy: 8, from: 21, to: 31)
        XCTAssertEqual(r.mode, .live)
    }

    func testAcceptedStepModeGoesBackToLiveWhenTheSignalRecovers() {
        var r = StepModeRules()
        feed(&r, accuracy: 120, from: 0, to: 20)
        r.accept()
        XCTAssertEqual(r.mode, .stepping)
        feed(&r, accuracy: 120, from: 21, to: 60)
        XCTAssertEqual(r.mode, .stepping, "bad signal keeps the steps")
        feed(&r, accuracy: 8, from: 61, to: 71)
        XCTAssertEqual(r.mode, .live)
    }

    func testDismissSilencesTheOfferForTheCooldown() {
        var r = StepModeRules()
        feed(&r, accuracy: 120, from: 0, to: 20)
        r.dismiss(at: 21)
        XCTAssertEqual(r.mode, .live)
        feed(&r, accuracy: 120, from: 22, to: 300)
        XCTAssertEqual(r.mode, .live, "cooldown 600 s")
        feed(&r, accuracy: 120, from: 301, to: 640)
        XCTAssertEqual(r.mode, .suggested, "after the cooldown it may offer again")
    }

    func testAcceptOnlyWorksFromSuggested() {
        var r = StepModeRules()
        r.accept()
        XCTAssertEqual(r.mode, .live)
    }

    func testResetForgetsEverything() {
        var r = StepModeRules()
        feed(&r, accuracy: 120, from: 0, to: 20)
        r.dismiss(at: 21)
        r.reset()
        feed(&r, accuracy: 120, from: 30, to: 50)
        XCTAssertEqual(r.mode, .suggested)
    }
}
