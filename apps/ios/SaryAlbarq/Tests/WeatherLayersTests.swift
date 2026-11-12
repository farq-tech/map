import XCTest
@testable import SaryAlbarq

@MainActor
final class WeatherLayersTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let d = UserDefaults(suiteName: "weather-layers-\(UUID().uuidString)")!
        return d
    }

    func testChoiceIsRememberedAndDaysAreClamped() {
        let d = defaults()
        let a = WeatherLayers(defaults: d)
        XCTAssertEqual(a.kind, .none)
        XCTAssertEqual(a.rainDays, 3)
        a.kind = .rain
        a.rainDays = 7
        let b = WeatherLayers(defaults: d)
        XCTAssertEqual(b.kind, .rain)
        XCTAssertEqual(b.rainDays, 7)
        b.rainDays = 5
        XCTAssertEqual(b.rainDays, 3)
    }

    func testEveryLayerCarriesItsLicenceCredit() {
        XCTAssertEqual(WeatherOverlayKind.clouds.attribution(year: 2026), "Contains modified EUMETSAT Meteosat data 2026")
        XCTAssertTrue(WeatherOverlayKind.rain.attribution().contains("NASA GPM IMERG"))
        XCTAssertTrue(WeatherOverlayKind.green.attribution().contains("VIIRS"))
        XCTAssertEqual(WeatherOverlayKind.none.attribution(), "")
        for k in WeatherOverlayKind.allCases where k != .none {
            XCTAssertFalse(WeatherLegend.items(k).isEmpty, "\(k) has a legend")
        }
        XCTAssertEqual(WeatherLegend.rain.count, 5)
    }

    func testTileTemplatesPointAtOurAPIOnly() {
        let base = URL(string: "https://api.example.test/")!
        XCTAssertEqual(WeatherLayerAPI.rainTiles(days: 3, base: base), "https://api.example.test/api/weather/rain/tile/3/{z}/{x}/{y}.png")
        XCTAssertEqual(WeatherLayerAPI.greenTiles(base: base), "https://api.example.test/api/weather/green/tile/{z}/{x}/{y}.png")
        XCTAssertEqual(WeatherLayerAPI.absolute("/api/weather/clouds/tile/20261107T1100Z/{z}/{x}/{y}.png", base: base),
                       "https://api.example.test/api/weather/clouds/tile/20261107T1100Z/{z}/{x}/{y}.png")
        for k in [WeatherLayerAPI.rainTiles(days: 1), WeatherLayerAPI.greenTiles()] {
            XCTAssertFalse(k.contains("key="), "no provider key in the app")
            XCTAssertFalse(k.contains("eumetsat") || k.contains("nasa.gov"))
        }
    }

    func testCloudFramesDecode() throws {
        let json = """
        {"ok":true,"layer":"clouds","attribution":"Contains modified EUMETSAT Meteosat data 2026",
         "frames":[{"id":"20261107T1000Z","time":"2026-11-07T10:00:00.000Z","label_ar":"١:٠٠ م","licence":"core-hourly",
                    "tile_url":"/api/weather/clouds/tile/20261107T1000Z/{z}/{x}/{y}.png"}],
         "minzoom":3,"maxzoom":9,"bounds":[25,8,65,40],"refresh_seconds":300}
        """
        let r = try JSONDecoder().decode(CloudFramesResponse.self, from: Data(json.utf8))
        XCTAssertTrue(r.ok)
        XCTAssertEqual(r.frames.first?.label_ar, "١:٠٠ م")
        XCTAssertEqual(r.maxzoom, 9)
    }

    #if DEBUG
    func testStubCloudFramesGiveAScrubbableTimeline() {
        let r = WeatherLayerAPI.stubCloudFrames()
        XCTAssertTrue(r.ok)
        XCTAssertGreaterThan(r.frames.count, 1, "the card shows the scrubber only for more than one frame")
        XCTAssertEqual(Set(r.frames.map(\.id)).count, r.frames.count, "unique ids: each frame is its own map source")
        XCTAssertEqual(WeatherOverlay.ageLabel(r.frames.last!.time), "الآن")
        XCTAssertTrue(r.frames.allSatisfy { $0.tile_url.hasPrefix("http://127.0.0.1:") }, "never a real host")
    }
    #endif

    func testDaysLabels() {
        XCTAssertEqual(WeatherLayers.daysLabel(1), "آخر يوم")
        XCTAssertEqual(WeatherLayers.daysLabel(3), "آخر ٣ أيام")
        XCTAssertEqual(WeatherLayers.daysLabel(7), "آخر أسبوع")
    }
}
