import XCTest
@testable import SaryAlbarq

/// Issue #187: routes must not drive through airports / military facilities, whichever provider
/// produced them. Geometry below is real OSM data around Thumamah Airport (OETH, way 110020045),
/// fetched 2026-11-11; no network is used.
final class RestrictedZonesTests: XCTestCase {
    private func pts(_ a: [(Double, Double)]) -> [LngLat] { a.map { LngLat(lng: $0.0, lat: $0.1) } }

    /// OSM way 110020045 «مطار الثمامة» (the runway strip).
    private let airportRing = [
        (46.63728, 25.21776), (46.63799, 25.21786), (46.63820, 25.21662), (46.63943, 25.20975), (46.64271, 25.19113),
        (46.64309, 25.19057), (46.64370, 25.18980), (46.64445, 25.18907), (46.64683, 25.18941), (46.64542, 25.19749),
        (46.64422, 25.20422), (46.64351, 25.20829), (46.64207, 25.21640), (46.64131, 25.22064), (46.64088, 25.22298),
        (46.63888, 25.23436), (46.63793, 25.23978), (46.63418, 25.23925), (46.63560, 25.23128), (46.63490, 25.23116),
        (46.63521, 25.22945), (46.63654, 25.22196), (46.63708, 25.21886), (46.63728, 25.21776),
    ]
    /// OSM way 558636566: `highway=service`, no `access` tag, runs beside the runway ~200 m west of the strip.
    private let serviceRoad = [
        (46.63086, 25.21264), (46.63422, 25.21398), (46.63430, 25.21418), (46.63377, 25.21563), (46.63206, 25.22029),
        (46.63232, 25.22179), (46.63253, 25.22300), (46.63277, 25.22440), (46.63296, 25.22576), (46.63316, 25.22711),
        (46.63349, 25.22949), (46.63372, 25.23110), (46.63343, 25.23117), (46.63332, 25.23163),
    ]

    private var thumamah: RestrictedZoneSet {
        RestrictedZoneSet(zones: [.init(id: "w110020045", kind: .aerodrome, name: "مطار الثمامة", ring: pts(airportRing))])
    }

    private func length(_ r: [LngLat]) -> Double { zip(r, r.dropFirst()).reduce(0) { $0 + Vehicle.distanceMeters($1.0, $1.1) } }

    // The route the report describes: south of the airport, up the untagged service road, out the north.
    private var routeThroughAirfield: [LngLat] {
        pts([(46.6580, 25.1500), (46.6520, 25.2000), (46.63086, 25.21264)] + serviceRoad.dropFirst() + [(46.6335, 25.2400), (46.6330, 25.3000), (46.6500, 25.9600)])
    }
    /// Same trip along the public road east of the airport.
    private var routeAroundAirfield: [LngLat] {
        pts([(46.6580, 25.1500), (46.6620, 25.2000), (46.6620, 25.2600), (46.6560, 25.3000), (46.6500, 25.9600)])
    }

    func testRouteAlongServiceRoadBesideRunwayIsRejected() {
        let hits = thumamah.crossings(of: routeThroughAirfield)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.title, "مطار الثمامة")
        XCTAssertGreaterThan(hits.first?.meters ?? 0, 1500, "≈2 km of the service road lie within the airfield margin")
        print("THUMAMAH before: route \(Int(length(routeThroughAirfield))) m, inside airfield \(Int(hits.first?.meters ?? 0)) m")
    }

    func testRouteAroundTheAirportIsAccepted() {
        XCTAssertTrue(thumamah.crossings(of: routeAroundAirfield).isEmpty)
        print("THUMAMAH after: route \(Int(length(routeAroundAirfield))) m, inside airfield 0 m")
    }

    func testRoutePassingAnAirportFarAwayIsAccepted() {
        let far = pts([(46.80, 24.60), (46.85, 24.90), (46.90, 25.10)])
        XCTAssertTrue(thumamah.crossings(of: far).isEmpty)
    }

    func testClassifiedRoadThroughTheZoneIsNotFlagged() {
        // A trunk road that crosses the aerodrome polygon (airport access road) stays legal.
        let road = pts([(46.6300, 25.2100), (46.6420, 25.2100), (46.6550, 25.2100)])
        XCTAssertFalse(thumamah.crossings(of: road).isEmpty, "without the carve-out the crossing is flagged")
        let withOpen = RestrictedZoneSet(zones: thumamah.zones, openLines: [road])
        XCTAssertTrue(withOpen.crossings(of: road).isEmpty)
    }

    func testOriginInsideTheZoneDoesNotBlockLeavingIt() {
        let leaving = pts([(46.6400, 25.2100), (46.6620, 25.2100), (46.6620, 25.2600)])
        XCTAssertEqual(thumamah.crossings(of: leaving, exempt: [leaving[0]]).count, 0)
    }

    func testTerminalParkingDestinationIsAllowedButRunwayIsNot() {
        let parking = pts([(46.6395, 25.2095), (46.6405, 25.2095), (46.6405, 25.2105), (46.6395, 25.2105), (46.6395, 25.2095)])
        let set = RestrictedZoneSet(zones: thumamah.zones, openRings: [parking])
        XCTAssertNil(set.restrictedZone(containing: LngLat(lng: 46.6400, lat: 25.2100)))
        XCTAssertNotNil(thumamah.restrictedZone(containing: LngLat(lng: 46.6400, lat: 25.2100)))
    }

    func testBundledDataKnowsThumamah() throws {
        let set = RestrictedZoneSet.bundled
        XCTAssertGreaterThan(set.zones.count, 100, "restricted_zones.json is bundled")
        XCTAssertNotNil(set.zones.first { $0.id == "w110020045" })
        XCTAssertFalse(set.crossings(of: routeThroughAirfield).isEmpty)
        XCTAssertTrue(set.crossings(of: routeAroundAirfield).isEmpty)
    }

    // MARK: guard provider

    private final class Stub: NavRoutingProvider {
        let name = "stub"
        var calls: [NavRouteRequest] = []
        let answer: (NavRouteRequest) throws -> [NavRoute]
        init(_ answer: @escaping (NavRouteRequest) throws -> [NavRoute]) { self.answer = answer }
        func routes(_ r: NavRouteRequest) async throws -> NavRoutePlan {
            calls.append(r)
            return NavRoutePlan(routes: try answer(r))
        }
    }

    private func route(_ id: String, _ c: [LngLat]) -> NavRoute { NavRoute(id: id, coordinates: c, distanceM: 0, durationS: 0, steps: []) }
    private func request(to t: LngLat = LngLat(lng: 46.65, lat: 25.96)) -> NavRouteRequest {
        NavRouteRequest(origin: LngLat(lng: 46.658, lat: 25.15), heading: nil,
                        target: NavTarget(source: .point, name: "x", position: t), options: .init())
    }

    func testGuardAsksAgainAroundTheZoneAndReturnsTheCleanRoute() async throws {
        let bad = routeThroughAirfield, good = routeAroundAirfield
        let stub = Stub { $0.avoidPolygons.isEmpty ? [self.route("bad", bad)] : [self.route("good", good)] }
        let plan = try await RestrictedZoneGuardProvider(base: stub, zones: thumamah).routes(request())
        XCTAssertEqual(plan.routes.map(\.id), ["good"])
        XCTAssertEqual(stub.calls.count, 2)
        XCTAssertEqual(stub.calls[1].avoidPolygons.count, 1)
        XCTAssertEqual(stub.calls[1].avoidPolygons[0].count, airportRing.count)
    }

    func testGuardDropsCrossingAlternativesWithoutAsking() async throws {
        let bad = routeThroughAirfield, good = routeAroundAirfield
        let stub = Stub { _ in [self.route("bad", bad), self.route("good", good)] }
        let plan = try await RestrictedZoneGuardProvider(base: stub, zones: thumamah).routes(request())
        XCTAssertEqual(plan.routes.map(\.id), ["good"])
        XCTAssertEqual(stub.calls.count, 1)
    }

    func testGuardRefusesWhenEveryRouteStillCrosses() async {
        let bad = routeThroughAirfield
        let stub = Stub { _ in [self.route("bad", bad)] }
        do {
            _ = try await RestrictedZoneGuardProvider(base: stub, zones: thumamah).routes(request())
            XCTFail("must refuse")
        } catch let e as NavRoutingError {
            XCTAssertEqual(e, .restrictedRoute("مطار الثمامة"))
            XCTAssertTrue(e.message.contains("منطقة مقيّدة"))
        } catch { XCTFail("\(error)") }
    }

    func testGuardRefusesDestinationInsideTheAirfieldWithoutCallingTheEngine() async {
        let stub = Stub { _ in XCTFail("engine must not be asked"); return [] }
        do {
            _ = try await RestrictedZoneGuardProvider(base: stub, zones: thumamah).routes(request(to: LngLat(lng: 46.6400, lat: 25.2100)))
            XCTFail("must refuse")
        } catch let e as NavRoutingError {
            XCTAssertEqual(e, .restrictedDestination("مطار الثمامة"))
            XCTAssertTrue(e.message.contains("الوجهة داخل منطقة مقيّدة"))
        } catch { XCTFail("\(error)") }
        XCTAssertTrue(stub.calls.isEmpty)
    }

    func testGuardPassesCleanRoutesUntouched() async throws {
        let good = routeAroundAirfield
        let stub = Stub { _ in [self.route("good", good)] }
        let plan = try await RestrictedZoneGuardProvider(base: stub, zones: thumamah).routes(request())
        XCTAssertEqual(plan.routes.map(\.id), ["good"])
        XCTAssertEqual(stub.calls.count, 1)
    }

    func testValhallaBodyCarriesExcludePolygons() throws {
        var r = request()
        XCTAssertNil(FarqValhallaRouteProvider.body(r)["exclude_polygons"])
        r.avoidPolygons = [pts(airportRing)]
        let polys = try XCTUnwrap(FarqValhallaRouteProvider.body(r)["exclude_polygons"] as? [[[Double]]])
        XCTAssertEqual(polys.count, 1)
        XCTAssertEqual(polys[0][0], [46.63728, 25.21776], "GeoJSON order: lng, lat")
    }
}
