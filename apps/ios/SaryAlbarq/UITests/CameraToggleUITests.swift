import XCTest

/// Build 45: the «٣د / ٢د» button (`map.tilt`) on every map state, and no tilting by touch.
/// The pitch is read from the button's accessibility value in DEBUG builds (`… pitch=NN`, the settled map pitch).
final class CameraToggleUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private enum State: String, CaseIterable {
        case standing, driving, exploring, guiding, idleOneMap, legacyHome, soloOuting, standaloneNav, track
        var args: [String] {
            switch self {
            case .standing: return ["-SaryDrive", "0", "-SaryContext", "stopped"]
            case .driving: return ["-SaryDrive", "1", "-SaryContext", "driving"]
            case .exploring: return ["-SaryDrive", "0", "-SaryContext", "stopped", "-SaryExplore"]
            case .guiding: return ["-SaryDrive", "0", "-SaryNavDemo", "-SaryNavTo", "24.7220,46.6650,حطين", "-SaryNavDelay", "3", "-SaryNavState", "guiding"]
            case .idleOneMap: return ["-SaryScreen", "home", "-SaryOneMap"]
            case .legacyHome: return ["-SaryScreen", "home"]
            /* «اتجه» on a place: a solo outing (the live screen), or the old stand-alone screen behind its flag. */
            case .soloOuting: return ["-SaryScreen", "home", "-SaryNavDemo"]
            case .standaloneNav: return ["-SaryScreen", "home", "-SaryNavDemo", "-SaryStandaloneNav"]
            case .track: return ["-SaryScreen", "follow"]
            }
        }
    }

    private func launch(_ s: State, text: String? = nil, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-demo", "-SaryWeatherDemo", "calm", "-SaryWeather", "none", "-SaryScheme", "light"] + s.args + extra
            + (text.map { ["-UIPreferredContentSizeCategoryName", $0] } ?? [])
        app.launch()
        app.allowLocationIfAsked()
        return app
    }

    private func el(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    private func pitch(_ b: XCUIElement) -> Int? {
        guard let v = b.value as? String, let r = v.range(of: "pitch=") else { return nil }
        return Int(v[r.upperBound...].prefix { $0.isNumber || $0 == "-" })
    }

    private func waitPitch(_ b: XCUIElement, _ ok: @escaping (Int) -> Bool, timeout: TimeInterval = 8) -> Bool {
        let p = NSPredicate { [self] _, _ in self.pitch(b).map(ok) ?? false }
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: p, object: nil)], timeout: timeout) == .completed
    }

    private func shot(_ name: String) {
        let s = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: s); a.name = name; a.lifetime = .keepAlways; add(a)
        if let dir = ProcessInfo.processInfo.environment["SARY_SHOTS"] {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let prefix = ProcessInfo.processInfo.environment["SARY_SHOT_PREFIX"] ?? "tilt"
            try? s.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(prefix)-\(name).png"))
        }
    }

    /// Reaches the state where the button should be; the track state needs the follow screen first.
    private func open(_ s: State, text: String? = nil) -> XCUIApplication {
        let app = launch(s, text: text)
        if s == .soloOuting || s == .standaloneNav {
            XCTAssertTrue(el(app, "home.search").waitForExistence(timeout: 30))
            sleep(2)
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).press(forDuration: 1.3)
            let go = el(app, "home.place.go")
            XCTAssertTrue(go.waitForExistence(timeout: 10), "«اتجه» on the place card")
            go.tap()
        }
        return app
    }

    // MARK: present, tappable and toggling in every state

    func testButtonExistsIsTappableAndTogglesInEveryState() {
        for s in State.allCases {
            let app = open(s)
            let b = el(app, "map.tilt")
            XCTAssertTrue(b.waitForExistence(timeout: 30), "\(s): the camera-angle button is on the map")
            /* The old stand-alone screen is a cover over the legacy home, whose own button stays in the tree underneath. */
            if s != .standaloneNav { XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "map.tilt").count, 1, "\(s): exactly one") }
            XCTAssertTrue(b.isHittable, "\(s): not covered by an overlay / SOS / chip / sheet")
            XCTAssertGreaterThanOrEqual(b.frame.width, 44, "\(s): a real touch target")
            XCTAssertGreaterThanOrEqual(b.frame.height, 44, "\(s)")
            XCTAssertFalse((b.label).isEmpty, "\(s): an accessible label")
            sleep(3)
            guard let before = pitch(b) else { XCTFail("\(s): no pitch readout (\(String(describing: b.value)))"); continue }
            let was3D = before >= 5
            b.tap()
            XCTAssertTrue(waitPitch(b, { was3D ? $0 < 5 : $0 >= 30 }), "\(s): tapping flips 2D/3D (was \(before)°, now \(pitch(b) ?? -1)°)")
            shot("\(s.rawValue)-after-tap")
            b.tap()
            XCTAssertTrue(waitPitch(b, { was3D ? $0 >= 30 : $0 < 5 }), "\(s): and back")
            app.terminate()
        }
    }

    // MARK: no tilting by touch

    /// Mapbox's tilt is a two-finger vertical drag, which XCUITest cannot synthesize: the maps report their tilt gesture switch
    /// (DEBUG accessibility value) and the pitch readout stays put through the gestures XCUITest can make (pan, pinch).
    func testTouchTiltIsOffButPanAndPinchStay() {
        for s in [State.standing, .idleOneMap, .legacyHome] {
            let app = open(s)
            let b = el(app, "map.tilt")
            XCTAssertTrue(b.waitForExistence(timeout: 30))
            sleep(3)
            let map = ["outing.map", "plan.map", "home.map"].map { el(app, $0) }.first { $0.exists }
            XCTAssertNotNil(map, "\(s): a map")
            guard let map, let before = pitch(b) else { XCTFail("\(s): no map / pitch readout"); continue }
            XCTAssertTrue(((map.value as? String) ?? "").contains("pitchEnabled=false"), "\(s): the tilt gesture is off (\(String(describing: map.value)))")
            map.pinch(withScale: 1.6, velocity: 1)
            map.swipeLeft()
            sleep(2)
            XCTAssertEqual(pitch(b), before, "\(s): pan and pinch do not change the pitch")
            XCTAssertTrue(map.exists, "\(s): and the map is still there")
            app.terminate()
        }
    }

    // MARK: overlap, small and large text

    func testNoOverlapSmallAndLargeText() {
        for (tag, size) in [("small", "UICTContentSizeCategoryXS"), ("large", "UICTContentSizeCategoryAccessibilityXXL")] {
            for s in [State.standing, .driving, .exploring, .idleOneMap, .legacyHome, .standaloneNav, .track] {
                let app = open(s, text: size)
                let b = el(app, "map.tilt")
                XCTAssertTrue(b.waitForExistence(timeout: 30), "\(tag)/\(s)")
                sleep(2)
                let f = b.frame
                XCTAssertTrue(app.frame.insetBy(dx: -1, dy: -1).contains(f), "\(tag)/\(s): inside the screen \(f)")
                XCTAssertGreaterThanOrEqual(f.width, 44, "\(tag)/\(s): a real touch target")
                XCTAssertTrue(b.isHittable, "\(tag)/\(s): tappable")
                for other in ["map.layers", "outing-sos", "outing-ptt", "outing-locate", "outing-backtrack", "explore-places", "explore-drone",
                              "explore-realistic", "idle-qibla", "idle-more", "home.locate", "home.qibla.toggle", "outing-sheet-summary", "outing-speed"] {
                    let o = el(app, other)
                    guard o.exists, !o.frame.isEmpty else { continue }
                    let x = f.intersection(o.frame)
                    XCTAssertFalse(x.width > 1 && x.height > 1, "\(tag)/\(s): map.tilt \(f) overlaps \(other) \(o.frame)")
                }
                shot("overlap-\(tag)-\(s.rawValue)")
                app.terminate()
            }
        }
    }

    /// 2D vs 3D on the same frame, the toggle as the only variable.
    func testShotsTwoDVersusThreeD() {
        let app = open(.idleOneMap)
        let b = el(app, "map.tilt")
        XCTAssertTrue(b.waitForExistence(timeout: 30))
        sleep(6)
        shot("idle-3d")
        b.tap()
        XCTAssertTrue(waitPitch(b, { $0 < 5 }))
        sleep(4)
        shot("idle-2d")
    }
}
