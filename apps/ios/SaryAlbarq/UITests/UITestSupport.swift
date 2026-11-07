import XCTest

/// Shared, robust interactions for the UI suites.
extension XCUIElement {
    /// Flips a SwiftUI `Toggle` row and waits until its value really changed.
    ///
    /// Since iOS 26 a tap in the middle of a toggle row (its label) does not flip it: only the
    /// control does. In RTL the control sits on the left, in LTR on the right; the inner switch
    /// element is used when the tree exposes one. Returns whether the value changed.
    /// `until`: the visible effect of the flip (better than the switch's value, which a row-level
    /// element may not report); by default, the value changing.
    @discardableResult
    func flipSwitch(timeout: TimeInterval = 4, until done: (() -> Bool)? = nil) -> Bool {
        let before = value as? String
        let changed = NSPredicate { [weak self] _, _ in done?() ?? ((self?.value as? String) != before) }
        func waitChange() -> Bool {
            XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: changed, object: nil)], timeout: timeout) == .completed
        }
        /* A page still sliding in takes the tap without acting on it: wait until it settles. */
        _ = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: self)], timeout: 4)
        Thread.sleep(forTimeInterval: 0.6)
        let inner = switches.firstMatch
        /* A tap that lands while the list is still decelerating only stops the scroll: tap the
         * control itself again (not the row's label, which does not flip it since iOS 26). */
        for attempt in 0..<3 {
            if attempt > 0 { Thread.sleep(forTimeInterval: 1) }
            if inner.exists, inner.frame != frame { inner.tap() } else { coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.5)).tap() }
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

extension XCUIApplication {
    /// Answers iOS's location prompt if it shows within `seconds` (a clean simulator asks on the
    /// first launch; the interruption monitor only fires on the next interaction, often too late).
    func allowLocationIfAsked(within seconds: TimeInterval = 6) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let labels = ["Allow While Using App", "السماح أثناء استخدام التطبيق", "Allow Once", "السماح مرة واحدة"]
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            for l in labels {
                let b = springboard.buttons[l]
                if b.exists { b.tap(); return }
            }
            usleep(300_000)
        }
    }
}

extension XCUIApplication {
    /// «أدوات الطلعة» (the map's «+» / «أدوات») → one tile («تخفيف الزحمة» ١٣: every tool two taps away).
    @discardableResult
    func openTool(_ id: String, timeout: TimeInterval = 10) -> Bool {
        let plus = buttons["outing-actions"]
        guard plus.waitForExistence(timeout: timeout) else { return false }
        plus.tap()
        let groupedUnder: [String: String] = [
            "outing-brief": "outing-location-tools", "outing-save-place": "outing-location-tools", "outing-waypoint-add": "outing-location-tools",
            "outing-camp-suggest": "outing-desert-tools", "outing-desert-route": "outing-desert-tools",
            "outing-weather": "outing-weather-tools", "outing-qibla": "outing-weather-tools",
        ]
        let tile = descendants(matching: .any)[id].firstMatch
        if !tile.exists, let parentID = groupedUnder[id] {
            let parent = descendants(matching: .any)[parentID].firstMatch
            guard parent.waitForExistence(timeout: 5) else { return false }
            parent.tap()
        }
        guard tile.waitForExistence(timeout: 5) else { return false }
        tile.tap()
        return true
    }

    /// «المزيد» → «الطلعة» → «غادر الطلعة»: opens the confirmation (the trip's buttons are there once,
    /// UX simplification). Returns the confirming button («غادر»).
    @discardableResult
    func openLeaveConfirmation(timeout: TimeInterval = 10) -> XCUIElement {
        let more = buttons["outing-actions"]
        if !more.waitForExistence(timeout: 3) { descendants(matching: .any)["outing-sheet-summary"].firstMatch.tap() }
        _ = more.waitForExistence(timeout: timeout)
        more.tap()
        let leave = descendants(matching: .any)["settings-leave"].firstMatch
        _ = leave.waitForExistence(timeout: 5)
        leave.scrollIntoView(in: self)
        leave.tap()
        return buttons["غادر"].firstMatch
    }

    /// The home map's sheet raised, «طلعاتي» in view («طلعة جديدة», «انضم برابط»).
    func openHomeOutings(timeout: TimeInterval = 20) {
        let create = buttons["list.create"]
        let handle = descendants(matching: .any)["home.sheet.handle"].firstMatch
        if !create.exists, handle.waitForExistence(timeout: timeout) { handle.tap() }
        _ = create.waitForExistence(timeout: 5)
        create.scrollIntoView(in: self)
    }

    /// «الإعدادات» → «متقدم» (screen shape, driving realism) scrolled into view.
    func openAdvancedSettings() {
        descendants(matching: .any)["settings-advanced"].firstMatch.scrollIntoView(in: self)
    }
}
