import XCTest
@testable import SaryAlbarq

final class CloudOutlookTests: XCTestCase {
    private func decode(_ json: String) throws -> CloudOutlook {
        try JSONDecoder().decode(CloudOutlook.self, from: Data(json.utf8))
    }

    private func outlook(state: String = "approaching", confidence: Double = 0.9, bearing: Double? = 90, speed: Double = 48,
                         eta: Int? = 120, clearing: Int? = nil, margin: Int? = 40, age: Int? = 90, scanned: Int? = nil) -> CloudOutlook {
        CloudOutlook(ok: true, state: state, confidence: confidence, min_confidence: 0.45,
                     motion: .init(bearing_deg: bearing, speed_kmh: speed), eta_minutes: eta, clearing_minutes: clearing,
                     margin_minutes: margin, distance_km: nil, scanned_km: scanned, image_age_min: age)
    }

    func testDecodesTheServerPayload() throws {
        let o = try decode("""
        {"ok":true,"layer":"clouds_outlook","state":"approaching","confidence":0.87,"min_confidence":0.45,
         "motion":{"bearing_deg":61,"speed_kmh":69,"direction_ar":"شمال شرقي"},"eta_minutes":125,"clearing_minutes":null,
         "margin_minutes":38,"distance_km":240,"scanned_km":300,"image_age_min":59,"unknown_field":1}
        """)
        XCTAssertEqual(o.state, "approaching")
        XCTAssertEqual(o.motion?.bearing_deg, 61)
        XCTAssertEqual(o.eta_minutes, 125)
        XCTAssertNil(o.clearing_minutes)
    }

    func testApproachingSaysWhenAndHowOldThePictureIs() {
        let d = CloudOutlookPresenter.display(outlook())
        XCTAssertEqual(d?.arrowDegrees, 90)
        XCTAssertEqual(d?.headline, "السحاب يتجه شرقًا بسرعة ~٤٨ كم/س")
        XCTAssertEqual(d?.detail, "سحاب كثيف يصلك بعد ~ساعتين (±٤٠ دقيقة)")
        XCTAssertTrue(d?.footnote.hasPrefix("بحسب صور قبل ساعة ونصف") == true)
        XCTAssertTrue(d?.footnote.contains("مو توقع مطر") == true)
    }

    func testDestinationWording() {
        let d = CloudOutlookPresenter.display(outlook(eta: 45, margin: 20), subject: .destination)
        XCTAssertEqual(d?.detail, "سحاب كثيف يصل وجهتك بعد ~٤٥ دقيقة (±٢٠ دقيقة)")
    }

    func testLowConfidenceOrUncertainHidesEverything() {
        XCTAssertNil(CloudOutlookPresenter.display(outlook(confidence: 0.3)))
        XCTAssertNil(CloudOutlookPresenter.display(outlook(state: "uncertain", confidence: 0.9)))
        XCTAssertNil(CloudOutlookPresenter.display(CloudOutlook(ok: false, state: "approaching", confidence: 0.9, min_confidence: nil, motion: nil,
                                                                eta_minutes: nil, clearing_minutes: nil, margin_minutes: nil, distance_km: nil,
                                                                scanned_km: nil, image_age_min: nil)))
        /* The server's own floor wins when it is higher than ours. */
        var strict = outlook(confidence: 0.5)
        strict.min_confidence = 0.6
        XCTAssertNil(CloudOutlookPresenter.display(strict))
        XCTAssertNil(CloudOutlookPresenter.display(outlook(eta: nil)), "approaching without an ETA has nothing honest to say")
        var noMotion = outlook()
        noMotion.motion = nil
        XCTAssertNil(CloudOutlookPresenter.display(noMotion))
    }

    func testOtherStates() {
        let over = CloudOutlookPresenter.display(outlook(state: "overhead", eta: nil, clearing: 60, margin: 30))
        XCTAssertEqual(over?.detail, "السحاب فوقك وقت الصورة، ويبتعد بعد ~ساعة (±٣٠ دقيقة)")
        let arrived = CloudOutlookPresenter.display(outlook(state: "arrived", eta: nil))
        XCTAssertTrue(arrived?.detail.contains("غالبًا وصل") == true)
        XCTAssertNil(arrived?.detail.range(of: "بعد"))
        let clear = CloudOutlookPresenter.display(outlook(state: "clear", eta: nil, scanned: 300))
        XCTAssertEqual(clear?.detail, "ما نشوف سحابًا كثيفًا جاي عندك ضمن ~٣٠٠ كم")
        let still = CloudOutlookPresenter.display(outlook(state: "stationary", bearing: nil, speed: 1))
        XCTAssertNil(still?.arrowDegrees)
        XCTAssertEqual(still?.headline, "السحاب شبه ثابت")
    }

    func testDirectionWordsAndWrapAround() {
        XCTAssertEqual(CloudOutlookPresenter.directionText(0), "شمالًا")
        XCTAssertEqual(CloudOutlookPresenter.directionText(359), "شمالًا")
        XCTAssertEqual(CloudOutlookPresenter.directionText(61), "شمال شرقي")
        XCTAssertEqual(CloudOutlookPresenter.directionText(225), "جنوب غربي")
        XCTAssertEqual(CloudOutlookPresenter.directionText(-90), "غربًا")
    }

    func testDurationsNeverClaimFalsePrecision() {
        XCTAssertEqual(CloudOutlookPresenter.durationText(2), "دقائق قليلة")
        XCTAssertEqual(CloudOutlookPresenter.durationText(47), "٤٥ دقيقة")
        XCTAssertEqual(CloudOutlookPresenter.durationText(60), "ساعة")
        XCTAssertEqual(CloudOutlookPresenter.durationText(95), "ساعة ونصف")
        XCTAssertEqual(CloudOutlookPresenter.durationText(125), "ساعتين")
        XCTAssertEqual(CloudOutlookPresenter.durationText(150), "ساعتين ونصف")
        XCTAssertEqual(CloudOutlookPresenter.durationText(195), "٣ ساعات وربع")
        XCTAssertEqual(CloudOutlookPresenter.ageText(59), "٥٩ دقيقة")
        XCTAssertEqual(CloudOutlookPresenter.ageText(90), "ساعة ونصف")
        XCTAssertEqual(CloudOutlookPresenter.ageText(125), "ساعتين و٥ دقيقة")
    }

    func testOutlookURLPointsAtOurAPI() async {
        let base = URL(string: "https://api.example.test/")!
        let exp = expectation(description: "request")
        final class P: URLProtocol {
            static var seen: URL?
            override class func canInit(with request: URLRequest) -> Bool { true }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
            override func startLoading() {
                P.seen = request.url
                client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
                client?.urlProtocolDidFinishLoading(self)
            }
            override func stopLoading() {}
        }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [P.self]
        do { _ = try await WeatherLayerAPI.cloudOutlook(lat: 24.7131, lng: 46.6753, base: base, session: URLSession(configuration: cfg)) } catch { exp.fulfill() }
        await fulfillment(of: [exp], timeout: 5)
        XCTAssertEqual(P.seen?.path, "/api/weather/clouds/outlook")
        XCTAssertEqual(URLComponents(url: P.seen!, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name), ["lat", "lng"])
    }
}
