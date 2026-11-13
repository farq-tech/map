import XCTest

/// A user-style walk through the new UI (owner: «تجول كمستخدم ودقق»). For each screen: a screenshot, a layout audit
/// (small targets, off-screen or overlapping buttons, cut text) and a dead-tap probe: every button is tapped on a fresh
/// launch and the screen must change. Findings are attached as text («walk-report-…»); the test itself only fails when a
/// screen cannot be reached, so the report always comes out whole.
final class WalkthroughUITests: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    private var report: [String] = []

    private func el(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-demo", "-SaryScreen", "home", "-SaryScheme", "dark", "-SaryNewUI",
                               "-SarySeedPlace", "مخيم الشعيب,26.0352,44.0521"] + extra
        app.launch(); app.allowLocationIfAsked()
        return app
    }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); a.name = "walk-\(name)"; a.lifetime = .keepAlways; add(a)
    }

    private func note(_ s: String) { report.append(s) }

    private func flush(_ screen: String) {
        let a = XCTAttachment(string: report.joined(separator: "\n")); a.name = "walk-report-\(screen)"; a.lifetime = .keepAlways; add(a)
        report = []
    }

    private struct B { let id: String; let label: String; let frame: CGRect }

    private func buttons(_ app: XCUIApplication) -> [B] {
        let win = app.windows.firstMatch.frame
        var out: [B] = []
        for e in app.buttons.allElementsBoundByIndex.prefix(40) where e.exists && e.isHittable {
            let f = e.frame
            guard f.width > 1, f.height > 1, win.intersects(f) else { continue }
            out.append(B(id: e.identifier, label: e.label, frame: f))
        }
        return out
    }

    private func audit(_ app: XCUIApplication, _ screen: String) -> [B] {
        sleep(2)
        shot(screen)
        let win = app.windows.firstMatch.frame
        let bs = buttons(app)
        note("== \(screen): \(bs.count) buttons")
        for b in bs {
            let name = b.id.isEmpty ? "«\(b.label)»" : "\(b.id) «\(b.label)»"
            if b.frame.width < 40 || b.frame.height < 40 { note("SMALL \(name) \(Int(b.frame.width))x\(Int(b.frame.height))") }
            if !win.contains(b.frame) { note("CLIPPED \(name) \(b.frame)") }
        }
        for i in bs.indices { for j in bs.indices where j > i {
            let x = bs[i].frame.intersection(bs[j].frame)
            guard !x.isNull else { continue }
            let small = min(bs[i].frame.width * bs[i].frame.height, bs[j].frame.width * bs[j].frame.height)
            if small > 0, x.width * x.height > 0.3 * small, !(bs[i].frame.contains(bs[j].frame) || bs[j].frame.contains(bs[i].frame)) {
                note("OVERLAP «\(bs[i].label)» / «\(bs[j].label)»")
            }
        } }
        for t in app.staticTexts.allElementsBoundByIndex.prefix(80) where t.exists && t.label.hasSuffix("…") {
            note("CUT «\(t.label)»")
        }
        return bs
    }

    /// Taps each button on a fresh launch of the screen; a tap that leaves the hierarchy unchanged is reported DEAD.
    private func probe(_ screen: String, reach: (XCUIApplication) -> Bool) {
        let first = launch()
        guard reach(first) else { note("UNREACHABLE \(screen)"); flush(screen); XCTFail("cannot reach \(screen)"); return }
        let bs = audit(first, screen)
        for (k, b) in bs.prefix(20).enumerated() {
            let app = launch()
            guard reach(app) else { note("UNREACHABLE again \(screen)"); break }
            sleep(1)
            let target = b.id.isEmpty ? app.buttons[b.label].firstMatch : el(app, b.id)
            guard target.exists, target.isHittable else { note("GONE «\(b.label)» \(b.id)"); continue }
            let before = app.debugDescription
            target.tap()
            sleep(2)
            let after = app.debugDescription
            let name = b.id.isEmpty ? "«\(b.label)»" : "\(b.id) «\(b.label)»"
            if before == after { note("DEAD \(name)") } else { note("ok \(name)") }
            if k < 6 { shot("\(screen)-tap\(k)") }
        }
        flush(screen)
    }

    private func open(_ app: XCUIApplication, _ id: String, then wait: String? = nil) -> Bool {
        let e = el(app, id)
        guard e.waitForExistence(timeout: 20) else { return false }
        e.tap()
        if let wait { return el(app, wait).waitForExistence(timeout: 10) }
        sleep(2); return true
    }

    func test1Home() {
        probe("home") { app in el(app, "home.card.start").waitForExistence(timeout: 20) }
    }

    func test2Profile() {
        probe("profile") { app in open(app, "home.pill.profile", then: "profile.sheet.favorites") }
    }

    func test3Favorites() {
        probe("favorites") { app in open(app, "home.pill.profile", then: "profile.sheet.favorites") && open(app, "profile.sheet.favorites", then: "favorites.place") }
    }

    func test4Settings() {
        probe("settings") { app in open(app, "home.pill.profile", then: "profile.sheet.settings") && open(app, "profile.sheet.settings") }
    }

    func test5Weather() {
        probe("weather") { app in open(app, "home.tile.weather") }
    }

    func test6Camp() {
        probe("camp") { app in open(app, "home.tile.camp", then: "camp.sheet") }
    }

    func test7Qibla() {
        probe("qibla") { app in open(app, "home.tile.qibla") }
    }

    func test8Routes() {
        probe("routes") { app in open(app, "home.tile.routes") }
    }

    func test9Search() {
        probe("search") { app in open(app, "home.pill.search", then: "home.search") }
    }
}
