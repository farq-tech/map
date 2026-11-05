import XCTest

/// «قناة الطلعة» lab: one simulator of a two-simulator run. Launches the app
/// with the arguments in `SARY_LAB_ARGS` (separated by "␟"), answers the
/// location prompt, stays up `SARY_LAB_SECONDS`, and takes screenshots at
/// `SARY_LAB_SHOTS` ("<second>:<name>,…") into `SARY_SHOT_DIR`.
/// Skipped unless `SARY_LAB_ARGS` is set (TEST_RUNNER_SARY_LAB_ARGS).
final class WalkieTalkieLabUITests: XCTestCase {
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    func testLab() throws {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["SARY_LAB_ARGS"], !raw.isEmpty else { throw XCTSkip("lab only") }
        let app = XCUIApplication()
        app.launchArguments = raw.components(separatedBy: "␟")
        app.launch()
        let allow = springboard.buttons["Allow While Using App"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
        let total = Double(env["SARY_LAB_SECONDS"] ?? "30") ?? 30
        var shots: [(Double, String)] = (env["SARY_LAB_SHOTS"] ?? "").split(separator: ",").compactMap {
            let p = $0.split(separator: ":")
            guard p.count == 2, let t = Double(p[0]) else { return nil }
            return (t, String(p[1]))
        }.sorted { $0.0 < $1.0 }
        let start = Date()
        /* `SARY_LAB_WAIT_SHOT` = "<caption text>:<name>": a shot the moment the button's caption says so. */
        var waitShot: (String, String)? = (env["SARY_LAB_WAIT_SHOT"]).flatMap {
            let p = $0.split(separator: ":", maxSplits: 1).map(String.init)
            return p.count == 2 ? (p[0], p[1]) : nil
        }
        let caption = app.staticTexts["outing-ptt-caption"]
        while Date().timeIntervalSince(start) < total {
            if let (text, name) = waitShot, caption.exists, caption.label.contains(text) {
                waitShot = nil
                Thread.sleep(forTimeInterval: 0.6)
                let s = XCUIScreen.main.screenshot()
                if let dir = env["SARY_SHOT_DIR"] {
                    try? s.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
                }
                add(XCTAttachment(screenshot: s))
            }
            if let (t, name) = shots.first, Date().timeIntervalSince(start) >= t {
                shots.removeFirst()
                let s = XCUIScreen.main.screenshot()
                let a = XCTAttachment(screenshot: s)
                a.name = name
                a.lifetime = .keepAlways
                add(a)
                if let dir = env["SARY_SHOT_DIR"] {
                    try? s.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
                }
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
    }
}
