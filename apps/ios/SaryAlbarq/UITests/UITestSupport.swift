import XCTest

/// Shared, robust interactions for the UI suites.
extension XCUIElement {
    /// Flips a SwiftUI `Toggle` row and waits until its value really changed.
    ///
    /// Since iOS 26 a tap in the middle of a toggle row (its label) does not flip it: only the
    /// control does. In RTL the control sits on the left, in LTR on the right; the inner switch
    /// element is used when the tree exposes one. Returns whether the value changed.
    @discardableResult
    /// `until`: the visible effect of the flip (better than the switch's value, which a row-level
    /// element may not report); by default, the value changing.
    func flipSwitch(timeout: TimeInterval = 4, until done: (() -> Bool)? = nil) -> Bool {
        let before = value as? String
        let changed = NSPredicate { [weak self] _, _ in done?() ?? ((self?.value as? String) != before) }
        func waitChange() -> Bool {
            XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: changed, object: nil)], timeout: timeout) == .completed
        }
        let inner = switches.firstMatch
        if inner.exists, inner.frame != frame {
            inner.tap()
            if waitChange() { return true }
        }
        for dx in [0.08, 0.92] {
            coordinate(withNormalizedOffset: CGVector(dx: dx, dy: 0.5)).tap()
            if waitChange() { return true }
        }
        return false
    }

    /// Taps a text field until it really has the keyboard (a tap during a sheet's animation can
    /// land before the field accepts focus), then types.
    func focusAndType(_ text: String) {
        let focused = NSPredicate { [weak self] _, _ in (self?.value(forKey: "hasKeyboardFocus") as? Bool) == true }
        for _ in 0..<4 {
            tap()
            if XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: focused, object: nil)], timeout: 2) == .completed { break }
        }
        typeText(text)
    }

    /// Scrolls `container` (swipe up) until this element is hittable and clear of the bottom
    /// `margin` (the home indicator, a floating bar).
    func scrollIntoView(in app: XCUIApplication, margin: CGFloat = 140, maxSwipes: Int = 10) {
        for _ in 0..<maxSwipes where !(exists && isHittable && frame.maxY < app.frame.maxY - margin) {
            app.swipeUp()
        }
    }
}
