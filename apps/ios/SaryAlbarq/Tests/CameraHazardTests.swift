import XCTest
@testable import SaryAlbarq

/// «كاميرات الرصد»: projecting cameras onto the route, the nearest one ahead, and
/// the rule that matters most on the road — one alert per camera per tier, never
/// repeated, muted when the driver muted, silent for a camera facing the other way.
final class CameraHazardTests: XCTestCase {
    /// A straight run north along one meridian from 24.70 to 24.75 (~5.5 km).
    private func northRoute() -> [LngLat] {
        var route: [LngLat] = []
        var lat = 24.70
        while lat <= 24.7501 { route.append(LngLat(lng: 46.6753, lat: lat)); lat += 0.005 }
        return route
    }

    private func cam(_ id: String, _ lat: Double, _ lon: Double, kind: CameraKind = .fixed,
                     bearing: Double? = nil, confidence: Double = 0.9) -> SpeedCamera {
        SpeedCamera(id: id, lat: lat, lon: lon, bearing: bearing, kind: kind,
                    speed_limit: 120, source: .official, confidence: confidence)
    }

    func testProjectionKeepsOnRouteCamerasAndDropsParallelAndFacingAway() {
        let route = northRoute()
        let onRoute = cam("c1", 24.73, 46.6753)                 // on the line
        let parallel = cam("c2", 24.73, 46.6783)                // ~300 m east — another road
        let facingAway = cam("c3", 24.73, 46.6753, bearing: 180) // on the line but watching south
        let eng = CameraHazardEngine()
        eng.load(route: route, cameras: [onRoute, parallel, facingAway])
        let ids = Set(eng.projected.map(\.camera.id))
        XCTAssertTrue(ids.contains("c1"))
        XCTAssertFalse(ids.contains("c2"), "a camera on a parallel road is not on this route")
        XCTAssertFalse(ids.contains("c3"), "a camera facing the other way must not alert")
    }

    func testNearestAheadIsTheClosestCameraInFront() {
        let route = northRoute()
        let eng = CameraHazardEngine()
        eng.load(route: route, cameras: [cam("far", 24.745, 46.6753), cam("near", 24.72, 46.6753)])
        let n = eng.nearestAhead(of: LngLat(lng: 46.6753, lat: 24.705))
        XCTAssertEqual(n?.camera.id, "near")
        XCTAssertGreaterThan(n!.remainingM, 0)
        // Standing past the near one, the far one becomes nearest.
        XCTAssertEqual(eng.nearestAhead(of: LngLat(lng: 46.6753, lat: 24.73))?.camera.id, "far")
    }

    func testOneApproachAndOneImminentAlertNeverRepeated() {
        let route = northRoute()
        let eng = CameraHazardEngine()
        eng.load(route: route, cameras: [cam("c1", 24.73, 46.6753)])
        var alerts: [CameraAlert] = []
        for lat in [24.700, 24.724, 24.726, 24.727, 24.7285, 24.7292, 24.7298, 24.732] {
            if let a = eng.advance(to: LngLat(lng: 46.6753, lat: lat)) { alerts.append(a) }
        }
        XCTAssertEqual(alerts.filter { $0.tier == .approach }.count, 1, "exactly one approach alert")
        XCTAssertEqual(alerts.filter { $0.tier == .imminent }.count, 1, "exactly one imminent alert")
        XCTAssertEqual(alerts.count, 2, "no repeats")
        XCTAssertTrue(alerts[0].text.contains("متر"))
        XCTAssertEqual(alerts[1].text, "كاميرا رصد قدّامك")
    }

    func testLowConfidenceCameraDrawsButDoesNotAlert() {
        let route = northRoute()
        let eng = CameraHazardEngine()
        eng.load(route: route, cameras: [cam("c1", 24.73, 46.6753, confidence: 0.2)])
        XCTAssertEqual(eng.projected.count, 1, "it is still on the map")
        var fired = false
        for lat in stride(from: 24.70, through: 24.735, by: 0.0008) {
            if eng.advance(to: LngLat(lng: 46.6753, lat: lat)) != nil { fired = true }
        }
        XCTAssertFalse(fired, "a low-confidence camera never alerts")
    }

    @MainActor
    func testProviderRespectsMute() {
        let provider = CameraHazardProvider()
        provider.setRoute(northRoute())
        provider.setCameras([cam("c1", 24.73, 46.6753)])
        provider.muted = true
        for lat in stride(from: 24.70, through: 24.735, by: 0.0008) {
            _ = provider.update(position: LngLat(lng: 46.6753, lat: lat))
        }
        XCTAssertNil(provider.latestAlert, "muted: nothing is published to speak")
    }

    func testArabicDistanceFormatting() {
        XCTAssertEqual(ArabicDigits.meters(500), "٥٠٠ متر")
        XCTAssertEqual(ArabicDigits.meters(1200), "١٫٢ كم")
        XCTAssertEqual(ArabicDigits.meters(2000), "٢ كم")
    }
}
