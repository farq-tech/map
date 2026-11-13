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

    func testUnifiedWeatherFollowsTheNewUISwitchAndTheDebugArguments() {
        XCTAssertFalse(WeatherPageFlag.unified(arguments: [], newUIOn: false), "off by default: the old floating card stays")
        XCTAssertTrue(WeatherPageFlag.unified(arguments: [], newUIOn: true), "«الواجهة الجديدة» turns the chip and the page on")
        #if DEBUG
        XCTAssertTrue(WeatherPageFlag.unified(arguments: ["-SaryUnifiedWeather"], newUIOn: false))
        XCTAssertFalse(WeatherPageFlag.unified(arguments: ["-SaryLegacyWeatherCard", "-SaryUnifiedWeather"], newUIOn: true), "legacy wins")
        #endif
    }

    // MARK: W-4: one fetch path

    private final class CountingTransport: WeatherTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        var calls: Int { lock.lock(); defer { lock.unlock() }; return n }
        func data(from url: URL) async throws -> Data {
            lock.lock(); n += 1; lock.unlock()
            try await Task.sleep(nanoseconds: 150_000_000)
            return Data(url.absoluteString.utf8)
        }
    }

    func testTheSameUrlAtTheSameMomentSharesOneRequestAndLaterRefreshesAreReal() async throws {
        let t = CountingTransport()
        let c = WeatherFetchCoalescer()
        let a = URL(string: "https://example.com/a")!
        let b = URL(string: "https://example.com/b")!
        async let x = c.data(from: a, base: t)
        async let y = c.data(from: a, base: t)
        async let z = c.data(from: b, base: t)
        let (rx, ry, rz) = try await (x, y, z)
        XCTAssertEqual(rx, ry)
        XCTAssertNotEqual(rx, rz)
        XCTAssertEqual(t.calls, 2, "two readers of the same point: one request; another point: its own")
        _ = try await c.data(from: a, base: t)
        XCTAssertEqual(t.calls, 3, "nothing is kept: a later refresh is a real request")
    }

    // MARK: Graceful state: the server is still reading the pictures (PR #267)

    func testOutlookWarmingIsNotAnErrorAndCarriesTheRetryTime() async {
        final class P: URLProtocol {
            override class func canInit(with request: URLRequest) -> Bool { true }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
            override func startLoading() {
                client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 202, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data(#"{"error":"warming","retry_after_s":30}"#.utf8))
                client?.urlProtocolDidFinishLoading(self)
            }
            override func stopLoading() {}
        }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [P.self]
        do {
            _ = try await WeatherLayerAPI.cloudOutlook(lat: 26.084, lng: 43.994, base: URL(string: "https://example.test")!, session: URLSession(configuration: cfg))
            XCTFail("a 202 is not an outlook")
        } catch let e as CloudOutlookError {
            XCTAssertEqual(e, .warming(retryAfterS: 30))
        } catch {
            XCTFail("expected the warming state, got \(error)")
        }
    }
}
