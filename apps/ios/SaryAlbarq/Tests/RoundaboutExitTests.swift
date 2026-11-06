import XCTest
@testable import SaryAlbarq

/// The owner (build 21): «خذ المخرج الأول» where the right one was the second. The exit number is the
/// router's own — Mapbox `maneuver.exit` (`RouteStep.exitIndex`), Valhalla's roundabout_exit_count
/// through the proxy's OSRM JSON — and goes to the clip and the banner with no ±1 anywhere.
/// Replays a real Mapbox response through Riyadh's Diplomatic Quarter (two rotaries: exit 3 and
/// exit 2) and a Valhalla OSRM response with a roundabout exit 2, through the real decoding.
final class RoundaboutExitTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json")))
    }

    private let req = NavRouteRequest(origin: LngLat(lng: 46.617, lat: 24.679), heading: 90,
                                      target: NavTarget(source: .point, name: "هنا", position: LngLat(lng: 46.629, lat: 24.687)), options: .init())

    func testMapboxRiyadhRotaryExitTwoIsTheSecond() throws {
        let plan = try FarqValhallaRouteProvider.plan(from: fixture("mapbox-roundabout-dq"), request: req)
        let rb = plan.routes[0].steps.filter { $0.maneuver.kind == .roundabout }
        XCTAssertEqual(rb.map(\.maneuver.exit), [3, 2], "the API's exit numbers, unchanged")
        let second = try XCTUnwrap(rb.last)
        XCTAssertEqual(SaryVoiceScript.action(second.maneuver), ["rb_03"])
        XCTAssertEqual(SaryVoiceCatalog.byKey["rb_03"]?.text, "في الدوّار، خذ المخرج الثاني.")
        XCTAssertTrue(NavText.action(second.maneuver).contains("المخرج الثاني"), NavText.action(second.maneuver))
        XCTAssertTrue(NavText.banner(second, distanceM: 300, targetName: nil).contains("المخرج الثاني"))
        XCTAssertEqual(SaryVoiceScript.action(rb[0].maneuver), ["rb_04"], "exit 3 → «الثالث»")
        XCTAssertFalse(rb.contains { $0.maneuver.lastExit }, "Arabic instructions: no «last exit» guess")
    }

    func testValhallaRoundaboutExitTwoIsTheSecond() throws {
        let plan = try FarqValhallaRouteProvider.plan(from: fixture("farq-route-roundabout"), request: req)
        let s = try XCTUnwrap(plan.routes[0].steps.first { $0.maneuver.kind == .roundabout })
        XCTAssertEqual(s.maneuver.exit, 2)
        XCTAssertEqual(SaryVoiceScript.step(s, distanceM: 200, miles: false), ["dist_04", "rb_03"], "«بعد ميتين متر. في الدوّار، خذ المخرج الثاني.»")
        XCTAssertTrue(NavText.banner(s, distanceM: 200, targetName: nil).contains("المخرج الثاني"))
    }

    func testEveryExitMapsToItsOwnOrdinal() {
        let names = ["الأول", "الثاني", "الثالث", "الرابع", "الخامس", "السادس", "السابع", "الثامن", "التاسع"]
        for e in 1...9 {
            let m = NavManeuver(kind: .roundabout, direction: .right, exit: e)
            let key = SaryVoiceScript.action(m)[0]
            XCTAssertEqual(SaryVoiceCatalog.byKey[key]?.text, "في الدوّار، خذ المخرج \(names[e - 1]).", "exit \(e)")
            XCTAssertEqual(NavText.action(m), "في الدوّار خذ المخرج \(names[e - 1])")
        }
    }

    func testNoExitNumberSaysTheDirectionNotAGuess() {
        let m = NavManeuver(kind: .roundabout, direction: .left, exit: nil)
        XCTAssertEqual(SaryVoiceScript.action(m), ["round_01", "turns_02"], "«ادخل الدوّار. لف يسار.»")
        XCTAssertEqual(NavText.action(m), "في الدوّار انعطف يسارًا")
    }
}
