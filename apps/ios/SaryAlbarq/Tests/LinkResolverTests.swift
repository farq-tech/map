import XCTest
@testable import SaryAlbarq

final class LinkResolverTests: XCTestCase {
    /// Scripted redirects; records every URL it was asked about.
    final class FakeNet: LinkResolver.Network, @unchecked Sendable {
        var hops: [String: String]
        private(set) var asked: [String] = []
        init(_ hops: [String: String] = [:]) { self.hops = hops }
        func nextHop(from url: URL, timeout: TimeInterval) async throws -> URL? {
            asked.append(url.absoluteString)
            return hops[url.absoluteString].flatMap(URL.init(string:))
        }
    }

    final class FakeGeo: @unchecked Sendable {
        var queries: [String] = []
        var answer: [PlaceSearch.Place]
        init(_ a: [PlaceSearch.Place] = []) { answer = a }
        func call(_ q: String, _ n: LngLat?) async throws -> [PlaceSearch.Place] { queries.append(q); return answer }
    }

    let rabie = PlaceSearch.Place(id: "p1", name: "حي الربيع", detail: "الرياض", point: LngLat(lng: 46.6600, lat: 24.8100))

    func run(_ s: String, net: FakeNet = FakeNet(), geo: FakeGeo = FakeGeo()) async -> Result<LinkResolver.Resolved, LinkResolver.Failure> {
        await LinkResolver.resolve(s, near: LngLat(lng: 46.7, lat: 24.7), network: net, geocode: { try await geo.call($0, $1) })
    }

    func testCoordinatesNeverTouchTheNetwork() async {
        let net = FakeNet()
        let r = await run("https://www.google.com/maps/place/Foo/@24.7136,46.6753,17z", net: net)
        guard case .success(let v) = r else { return XCTFail() }
        XCTAssertEqual(v.point.lat, 24.7136, accuracy: 1e-6)
        XCTAssertEqual(v.name, "Foo")
        XCTAssertTrue(net.asked.isEmpty)
    }

    func testShortLinkFollowsRedirectToCoordinates() async {
        let net = FakeNet(["https://maps.app.goo.gl/abc123": "https://www.google.com/maps/place/Kingdom+Centre/@24.7114,46.6744,17z/data=!3d24.7114!4d46.6744"])
        let r = await run("انظر هذا https://maps.app.goo.gl/abc123", net: net)
        guard case .success(let v) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(v.point.lng, 46.6744, accuracy: 1e-6)
        XCTAssertEqual(v.name, "Kingdom Centre")
        XCTAssertEqual(net.asked, ["https://maps.app.goo.gl/abc123"])
    }

    func testHttpIsUpgradedAndBareShortHostWorks() async {
        let net = FakeNet(["https://goo.gl/maps/xyz": "https://www.google.com/maps?q=24.5,46.5"])
        let r = await run("goo.gl/maps/xyz", net: net)
        guard case .success(let v) = r else { return XCTFail() }
        XCTAssertEqual(v.point.lat, 24.5, accuracy: 1e-6)
    }

    func testPlaceNameOnlyLinkIsGeocodedWithoutNetwork() async {
        let net = FakeNet(), geo = FakeGeo([rabie])
        let r = await run("https://www.google.com/maps/place/%D8%AD%D9%8A+%D8%A7%D9%84%D8%B1%D8%A8%D9%8A%D8%B9/", net: net, geo: geo)
        guard case .success(let v) = r else { return XCTFail() }
        XCTAssertEqual(geo.queries, ["حي الربيع"])
        XCTAssertEqual(v.point, rabie.point)
        XCTAssertTrue(net.asked.isEmpty)
    }

    func testShortLinkToSearchPageGeocodesQ() async {
        let net = FakeNet(["https://g.co/kgs/q1w2": "https://www.google.com/search?q=Panda+Hypermarket&kgmid=/g/1"])
        let geo = FakeGeo([rabie])
        let r = await run("https://g.co/kgs/q1w2", net: net, geo: geo)
        guard case .success = r else { return XCTFail() }
        XCTAssertEqual(geo.queries, ["Panda Hypermarket"])
    }

    func testGarbageAndEmptyAreNil() async {
        for s in ["", "   ", "hello world", "https://", "مرحبا"] {
            let r = await run(s)
            XCTAssertEqual(r, .failure(.unresolved), s)
            XCTAssertFalse(LinkResolver.needsResolution(s), s)
        }
    }

    func testNonAllowedHostIsRefusedWithoutNetwork() async {
        let net = FakeNet()
        for s in ["https://evil.example.com/maps/place/X", "https://notgoogle.com/maps/place/X", "https://google.com.evil.io/x", "https://bit.ly/abc"] {
            let r = await run(s, net: net)
            XCTAssertEqual(r, .failure(.unresolved), s)
        }
        XCTAssertTrue(net.asked.isEmpty)
        XCTAssertTrue(LinkResolver.needsResolution("https://bit.ly/abc"), "shown as an error, not searched as text")
    }

    func testRedirectToDisallowedOrPlainHttpHostIsRefused() async {
        for target in ["https://evil.example.com/x", "http://www.google.com/maps/place/A"] {
            let net = FakeNet(["https://maps.app.goo.gl/a": target])
            let r = await run("https://maps.app.goo.gl/a", net: net)
            XCTAssertEqual(r, .failure(.unresolved), target)
        }
    }

    func testHopCapIsFive() async {
        var hops: [String: String] = [:]
        for i in 0..<8 { hops["https://goo.gl/maps/h\(i)"] = "https://goo.gl/maps/h\(i + 1)" }
        let net = FakeNet(hops)
        let r = await run("https://goo.gl/maps/h0", net: net)
        XCTAssertEqual(r, .failure(.unresolved))
        XCTAssertLessThanOrEqual(net.asked.count, 6)
    }

    func testConsentWallIsUnwrapped() async {
        let net = FakeNet(["https://maps.app.goo.gl/c": "https://consent.google.com/m?continue=https://www.google.com/maps/@24.6,46.7,15z&gl=SA"])
        let r = await run("https://maps.app.goo.gl/c", net: net)
        guard case .success(let v) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(v.point.lat, 24.6, accuracy: 1e-6)
    }

    func testNetworkFailureIsAnErrorNotACrash() async {
        struct Boom: LinkResolver.Network { func nextHop(from url: URL, timeout: TimeInterval) async throws -> URL? { throw URLError(.timedOut) } }
        let r = await LinkResolver.resolve("https://maps.app.goo.gl/zzz", near: nil, network: Boom(), geocode: { _, _ in [] })
        XCTAssertEqual(r, .failure(.unresolved))
    }

    func testNationalAddressShape() async {
        XCTAssertEqual(LinkResolver.nationalAddress("RARA6498")?.code, "RARA6498")
        XCTAssertEqual(LinkResolver.nationalAddress("rara 6498 حي الربيع الرياض")?.rest, "حي الربيع الرياض")
        XCTAssertEqual(LinkResolver.nationalAddress("RARA٦٤٩٨")?.code, "RARA6498")
        XCTAssertNil(LinkResolver.nationalAddress("RAR6498"))
        XCTAssertNil(LinkResolver.nationalAddress("RARA64987"))
        XCTAssertNil(LinkResolver.nationalAddress("حي الربيع"))
        XCTAssertTrue(LinkResolver.needsResolution("RARA6498"))
        let r = await run("RARA6498")
        XCTAssertEqual(r, .failure(.nationalAddress))
        XCTAssertEqual(LinkResolver.Failure.nationalAddress.arabic, "هذا رمز عنوان وطني، لا أستطيع حلّه دون خدمة العناوين")
    }

    func testFreeTextAndPlainCoordinatesAreNotLinks() {
        XCTAssertFalse(LinkResolver.needsResolution("حي الربيع، الرياض"))
        XCTAssertFalse(LinkResolver.needsResolution("24.7136, 46.6753"))
        XCTAssertFalse(LinkResolver.needsResolution("https://www.google.com/maps/@24.7,46.6,15z"))
        XCTAssertTrue(LinkResolver.needsResolution("https://maps.app.goo.gl/abc"))
    }

    func testLookupRowAndErrors() async {
        let net = FakeNet(["https://maps.app.goo.gl/abc": "https://www.google.com/maps/place/Foo/@24.7,46.6,17z"])
        let ok = await LinkResolver.lookup("https://maps.app.goo.gl/abc", near: nil, network: net)
        XCTAssertEqual(ok.places.first?.name, "Foo")
        XCTAssertEqual(ok.places.first?.category, "الموقع من الرابط")
        XCTAssertNil(ok.error)
        let bad = await LinkResolver.lookup("https://bit.ly/x", near: nil, network: net)
        XCTAssertTrue(bad.places.isEmpty)
        XCTAssertEqual(bad.error, "ما قدرت أحدد الموقع من هذا الرابط")
    }

    func testHostAllowList() {
        for h in ["www.google.com", "maps.google.com.sa", "google.co.uk", "maps.app.goo.gl", "goo.gl", "g.co", "waze.com", "ul.waze.com", "maps.apple.com"] {
            XCTAssertTrue(LinkResolver.isAllowed(host: h), h)
        }
        for h in ["evil.com", "notgoogle.com", "google.com.evil.io", "goo.gl.evil.com", "apple.com", ""] {
            XCTAssertFalse(LinkResolver.isAllowed(host: h), h)
        }
    }
}
