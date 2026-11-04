import XCTest
@testable import SaryAlbarq

/// The server's `validate.js` rules, as the app mirrors them.
final class ServerRulesTests: XCTestCase {
    private func fix(lat: Double = 24.7, lng: Double = 46.7, accuracy: Double? = 10, speed: Double? = 5, age: Double = 1_000) -> WireFix {
        WireFix(lat: lat, lng: lng, accuracy: accuracy, heading: 90, speed: speed, mode: .balanced, age_ms: age)
    }

    func testAcceptsAGoodFix() {
        XCTAssertEqual(ServerRules.check(fix()), .ok)
        XCTAssertEqual(ServerRules.check(fix(accuracy: nil, speed: nil, age: 0)), .ok)
    }

    func testCoordinates() {
        XCTAssertEqual(ServerRules.check(fix(lat: 91)), .rejected("invalid_coordinates"))
        XCTAssertEqual(ServerRules.check(fix(lng: -181)), .rejected("invalid_coordinates"))
        XCTAssertEqual(ServerRules.check(fix(lat: 0, lng: 0)), .rejected("invalid_coordinates"))
        XCTAssertEqual(ServerRules.check(fix(lat: .nan)), .rejected("invalid_coordinates"))
    }

    func testAccuracyCap() {
        XCTAssertEqual(ServerRules.check(fix(accuracy: 1_000)), .ok)
        XCTAssertEqual(ServerRules.check(fix(accuracy: 1_000.1)), .rejected("inaccurate"))
        XCTAssertEqual(ServerRules.check(fix(accuracy: -1)), .rejected("invalid_accuracy"))
    }

    func testAgeCapSixtySeconds() {
        XCTAssertEqual(ServerRules.check(fix(age: 60_000)), .ok)
        XCTAssertEqual(ServerRules.check(fix(age: 60_001)), .rejected("stale"))
        XCTAssertEqual(ServerRules.check(fix(age: -1)), .rejected("invalid_age"))
    }

    func testSpeedCap() {
        XCTAssertEqual(ServerRules.check(fix(speed: 55)), .ok)
        XCTAssertEqual(ServerRules.check(fix(speed: 55.5)), .rejected("implausible_speed"))
        /* negative speed is dropped on the server, not refused */
        XCTAssertEqual(ServerRules.check(fix(speed: -1)), .ok)
    }

    func testClientIsStricterThanServer() {
        /* The app never sends what the server would refuse: its own caps are tighter. */
        XCTAssertLessThan(Policy.sendMaxAccuracyM, ServerRules.maxAccuracyM)
        XCTAssertLessThan(Policy.maxSendAgeMs, ServerRules.maxFixAgeMs)
        XCTAssertEqual(Policy.maxPlausibleMps, ServerRules.maxSpeedMps)
        XCTAssertGreaterThanOrEqual(Policy.sendFloorMs, ServerRules.minFixIntervalMs)
    }

    func testPhoneNormalisationMatchesServer() {
        XCTAssertEqual(ServerRules.normalizePhone("0551234567"), "+966551234567")
        XCTAssertEqual(ServerRules.normalizePhone("551234567"), "+966551234567")
        XCTAssertEqual(ServerRules.normalizePhone("966551234567"), "+966551234567")
        XCTAssertEqual(ServerRules.normalizePhone("00966551234567"), "+966551234567")
        XCTAssertEqual(ServerRules.normalizePhone("٠٥٥١٢٣٤٥٦٧"), "+966551234567")
        XCTAssertEqual(ServerRules.normalizePhone("055 123 4567"), "+966551234567")
        XCTAssertEqual(ServerRules.normalizePhone("+44 20 7946 0958"), "+442079460958")
        XCTAssertNil(ServerRules.normalizePhone("12345"))
        XCTAssertNil(ServerRules.normalizePhone("abc"))
    }

    func testCleanTextDropsBidiOverridesAndCollapsesSpace() {
        XCTAssertEqual(ServerRules.cleanText("  أبو\u{202E}   فهد \n", max: 40), "أبو فهد")
        XCTAssertNil(ServerRules.cleanText("   ", max: 40))
        XCTAssertEqual(ServerRules.cleanText(String(repeating: "ب", count: 100), max: 80)?.count, 80)
    }
}

final class CarColorsTests: XCTestCase {
    func testEachMemberDifferentByJoinOrder() {
        let c = CarColors.assign([
            (userId: "b", joinedAt: "2026-11-03T10:00:02Z"),
            (userId: "a", joinedAt: "2026-11-03T10:00:01Z"),
            (userId: "c", joinedAt: "2026-11-03T10:00:03Z"),
        ])
        XCTAssertEqual(c["a"], CarColors.palette[0])
        XCTAssertEqual(c["b"], CarColors.palette[1])
        XCTAssertEqual(Set(c.values).count, 3)
    }

    func testSameOnEveryDeviceWhateverOrder() {
        let m = (0..<12).map { (userId: "u\($0)", joinedAt: String(format: "2026-11-03T10:00:%02dZ", $0)) }
        XCTAssertEqual(CarColors.assign(m), CarColors.assign(m.reversed()))
        XCTAssertEqual(Set(CarColors.assign(m).values).count, 12)
    }

    func testTieBreakByUserIdAndWrap() {
        let same = "2026-11-03T10:00:00Z"
        let c = CarColors.assign([(userId: "z", joinedAt: same), (userId: "m", joinedAt: same)])
        XCTAssertEqual(c["m"], CarColors.palette[0])
        let many = (0..<13).map { (userId: String(format: "u%02d", $0), joinedAt: same) }
        XCTAssertEqual(CarColors.assign(many)["u12"], CarColors.palette[0])
    }

    func testPaletteMatchesWeb() throws {
        /* Read the web palette from the repo when it is reachable (local runs), so the two cannot drift. */
        let here = URL(fileURLWithPath: #filePath)
        let ts = here.deletingLastPathComponent().appendingPathComponent("../../../web/src/lib/outings/carColors.ts").standardized
        guard let src = try? String(contentsOf: ts, encoding: .utf8) else { throw XCTSkip("web source not reachable from the test bundle") }
        let hex = try NSRegularExpression(pattern: "\"#([0-9a-fA-F]{6})\"")
        let found = hex.matches(in: src, range: NSRange(src.startIndex..., in: src)).compactMap { m -> UInt32? in
            Range(m.range(at: 1), in: src).flatMap { UInt32(src[$0], radix: 16) }
        }
        XCTAssertEqual(found, CarColors.palette)
    }
}
