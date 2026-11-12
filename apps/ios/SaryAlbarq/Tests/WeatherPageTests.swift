import XCTest
@testable import SaryAlbarq

/// W-1 (docs/UNIFIED-SURFACES.md): the map keeps one weather chip; everything else lives in the page.
@MainActor
final class WeatherPageTests: XCTestCase {
    func testStatusLineNamesTheLayerAndItsAge() {
        XCTAssertEqual(WeatherPageRules.statusLine(kind: .clouds, time: "الساعة ٢:٠٠ م", age: "قبل ٢٠ دقيقة"),
                       "\(WeatherOverlayKind.clouds.label) · قبل ٢٠ دقيقة", "clouds show the picture's age")
        XCTAssertEqual(WeatherPageRules.statusLine(kind: .rain, time: "آخر ٣ أيام", age: "قبل ٢٠ دقيقة"),
                       "\(WeatherOverlayKind.rain.label) · آخر ٣ أيام", "only clouds use the age")
        XCTAssertEqual(WeatherPageRules.statusLine(kind: .wind, time: "", age: ""), WeatherOverlayKind.wind.label)
    }

    func testChipExistsOnlyWhileALayerIsOn() {
        XCTAssertFalse(WeatherPageRules.showsStatusChip(kind: .none))
        for k in WeatherOverlayKind.allCases where k != .none { XCTAssertTrue(WeatherPageRules.showsStatusChip(kind: k), k.rawValue) }
    }

    func testChipTapOpensThePage() {
        let m = WeatherLegendModel()
        var opened = 0
        m.onOpenPage = { opened += 1 }
        m.onOpenPage()
        XCTAssertEqual(opened, 1)
    }

    func testTheRouterIsWhatTheMapCalls() {
        var opened = 0
        WeatherPageRouter.open = { opened += 1 }
        WeatherPageRouter.open?()
        XCTAssertEqual(opened, 1)
        WeatherPageRouter.open = nil
    }

    func testReleaseNeverShowsTheLegacyCard() {
        #if !DEBUG
        XCTAssertFalse(WeatherPageFlag.legacyCard)
        #endif
        /* Without the DEBUG argument the page is the default. */
        XCTAssertFalse(WeatherPageFlag.legacyCard)
    }
}
