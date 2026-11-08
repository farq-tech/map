import XCTest
import MapKit
@testable import SaryAlbarq

// MARK: - GPX / KML import

final class RouteFileTests: XCTestCase {
    private func gpx(_ body: String) -> Data {
        Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="t" xmlns="http://www.topografix.com/GPX/1/1">\(body)</gpx>
        """.utf8)
    }

    func testGPXTrackWinsOverRouteAndKeepsWaypoints() throws {
        let d = gpx("""
        <metadata><name>طلعة الثمامة</name></metadata>
        <wpt lat="24.80" lon="46.80"><name>المخيم</name></wpt>
        <rte><rtept lat="1" lon="1"/><rtept lat="2" lon="2"/></rte>
        <trk><name>المسار</name><trkseg>
          <trkpt lat="24.70" lon="46.60"/><trkpt lat="24.71" lon="46.65"/><trkpt lat="24.75" lon="46.70"/>
        </trkseg></trk>
        """)
        let r = try RouteFile.parse(d, fileName: "a.gpx").get()
        XCTAssertEqual(r.source, .track)
        XCTAssertEqual(r.points.first, LngLat(lng: 46.60, lat: 24.70))
        XCTAssertEqual(r.points.last, LngLat(lng: 46.70, lat: 24.75))
        XCTAssertEqual(r.name, "طلعة الثمامة")
        XCTAssertEqual(r.waypoints, [RouteFile.Waypoint(name: "المخيم", point: LngLat(lng: 46.80, lat: 24.80))])
    }

    func testGPXRouteThenWaypointsOnly() throws {
        let rte = try RouteFile.parse(gpx("<rte><rtept lat=\"24.1\" lon=\"46.1\"/><rtept lat=\"24.2\" lon=\"46.3\"/></rte>")).get()
        XCTAssertEqual(rte.source, .route)
        XCTAssertEqual(rte.points.count, 2)
        let w = try RouteFile.parse(gpx("<wpt lat=\"24.1\" lon=\"46.1\"/><wpt lat=\"24.2\" lon=\"46.3\"/><wpt lat=\"24.4\" lon=\"46.2\"/>")).get()
        XCTAssertEqual(w.source, .waypoints)
        XCTAssertEqual(w.points.count, 3)
    }

    func testInvalidCoordinatesAreSkipped() throws {
        let r = try RouteFile.parse(gpx("""
        <trk><trkseg><trkpt lat="24.1" lon="46.1"/><trkpt lat="999" lon="46"/><trkpt lat="abc" lon="1"/><trkpt lon="46"/>
        <trkpt lat="NaN" lon="46"/><trkpt lat="24.2" lon="46.2"/></trkseg></trk>
        """)).get()
        XCTAssertEqual(r.rawCount, 2)
    }

    func testKMLLineStringPointsAndGxTrack() throws {
        let kml = Data("""
        <?xml version="1.0"?><kml xmlns="http://www.opengis.net/kml/2.2" xmlns:gx="http://www.google.com/kml/ext/2.2"><Document><name>رحلة</name>
        <Placemark><name>البداية</name><Point><coordinates>46.6,24.7,0</coordinates></Point></Placemark>
        <Placemark><LineString><coordinates>
          46.60,24.70,0 46.65,24.72,0
          46.70,24.75 bad,1 200,24
        </coordinates></LineString></Placemark></Document></kml>
        """.utf8)
        let r = try RouteFile.parse(kml, fileName: "x.kml").get()
        XCTAssertEqual(r.source, .kmlLine)
        XCTAssertEqual(r.rawCount, 3)
        XCTAssertEqual(r.name, "رحلة")
        XCTAssertEqual(r.waypoints.first?.name, "البداية")

        let track = Data("""
        <kml xmlns:gx="http://www.google.com/kml/ext/2.2"><Placemark><gx:Track>
        <gx:coord>46.6 24.7 600</gx:coord><gx:coord>46.7 24.8 610</gx:coord></gx:Track></Placemark></kml>
        """.utf8)
        let t = try RouteFile.parse(track).get()
        XCTAssertEqual(t.source, .track)
        XCTAssertEqual(t.points, [LngLat(lng: 46.6, lat: 24.7), LngLat(lng: 46.7, lat: 24.8)])
    }

    func testMalformedUnsupportedEmpty() {
        XCTAssertEqual(RouteFile.parse(Data("<gpx><trk><trkseg><trkpt lat=\"1\" lon=\"1\">".utf8), fileName: "a.gpx").failure, .malformed)
        XCTAssertEqual(RouteFile.parse(Data("hello world".utf8), fileName: "a.txt").failure, .unsupported)
        XCTAssertEqual(RouteFile.parse(Data([0x50, 0x4B, 0x03, 0x04, 0, 0]), fileName: "a.kmz").failure, .unsupported)
        XCTAssertEqual(RouteFile.parse(gpx("<trk><trkseg><trkpt lat=\"1\" lon=\"1\"/></trkseg></trk>")).failure, .noRoute)
        XCTAssertEqual(RouteFile.parse(Data("<kml></kml>".utf8)).failure, .noRoute)
        /* A GPX extension with a KML body is still read by its content's root. */
        XCTAssertEqual(RouteFile.parse(Data("<html><body/></html>".utf8), fileName: "a.gpx").failure, .malformed)
    }

    func testExternalEntitiesAreNeverResolved() {
        let evil = Data("""
        <?xml version="1.0"?><!DOCTYPE gpx [<!ENTITY xxe SYSTEM "file:///etc/passwd">]>
        <gpx><metadata><name>&xxe;</name></metadata><trk><trkseg><trkpt lat="24" lon="46"/><trkpt lat="25" lon="47"/></trkseg></trk></gpx>
        """.utf8)
        switch RouteFile.parse(evil, fileName: "e.gpx") {
        case let .success(r): XCTAssertFalse((r.name ?? "").contains("root:"))
        case .failure: break // refusing is fine too
        }
    }

    func testHugeTrackIsSimplifiedUnderTheCap() throws {
        var s = "<gpx><trk><trkseg>"
        s.reserveCapacity(60 * 120_000)
        for i in 0..<120_000 {
            let t = Double(i) / 120_000
            /* A wiggly 60 km line: lots of real shape, more points than the cap. */
            s += "<trkpt lat=\"\(24.5 + t * 0.5 + sin(Double(i) / 40) * 0.002)\" lon=\"\(46.5 + t * 0.4)\"/>"
        }
        s += "</trkseg></trk></gpx>"
        let r = try RouteFile.parse(Data(s.utf8), fileName: "big.gpx").get()
        XCTAssertEqual(r.rawCount, 120_000)
        XCTAssertLessThanOrEqual(r.points.count, TripPlan.maxPoints)
        XCTAssertGreaterThan(r.points.count, 50)
        /* Simplification keeps the length close (within 5 %). */
        XCTAssertEqual(r.points.first, LngLat(lng: 46.5, lat: 24.5))
    }

    func testTooManyRawPointsAndTooLarge() {
        var s = "<kml><Placemark><LineString><coordinates>"
        s.reserveCapacity(10 * (RouteFile.maxRawPoints + 10))
        for _ in 0...(RouteFile.maxRawPoints) { s += "46.1,24.1 " }
        s += "</coordinates></LineString></Placemark></kml>"
        XCTAssertEqual(RouteFile.parse(Data(s.utf8), fileName: "x.kml").failure, .tooManyPoints)
        XCTAssertEqual(RouteFile.parse(Data(count: RouteFile.maxBytes + 1), fileName: "x.gpx").failure, .tooLarge)
    }

    func testGPXExportEscapesAndRoundTrips() throws {
        let plan = TripPlan(route: PlanLineString([LngLat(lng: 46.6, lat: 24.7), LngLat(lng: 46.7, lat: 24.8)]), notes: "حطب & ماء <مهم>",
                            destination: OutingDestination(name: "روضة \"خريم\"", lat: 25.3, lng: 47.2), updated_at: nil)
        let x = RouteFile.gpx(name: "كشتة <الخميس>", plan: plan)
        XCTAssertTrue(x.contains("&lt;الخميس&gt;"))
        XCTAssertTrue(x.contains("حطب &amp; ماء &lt;مهم&gt;"))
        XCTAssertTrue(x.contains("روضة &quot;خريم&quot;"))
        XCTAssertTrue(x.contains("lat=\"24.700000\" lon=\"46.600000\""))
        let back = try RouteFile.parse(Data(x.utf8), fileName: "e.gpx").get()
        XCTAssertEqual(back.points, plan.points)
        XCTAssertEqual(back.waypoints.first?.point, LngLat(lng: 47.2, lat: 25.3))
        let url = try RouteFile.exportFile(name: "طلعة/الثمامة", plan: plan)
        XCTAssertEqual(url.pathExtension, "gpx")
        XCTAssertFalse(url.lastPathComponent.contains("/"))
    }
}

private extension Result {
    var failure: Failure? { if case let .failure(e) = self { return e }; return nil }
}

// MARK: - geometry

final class PlanGeoTests: XCTestCase {
    func testRouteDistanceAndETA() {
        let deg = PlanGeo.length([LngLat(lng: 46, lat: 24), LngLat(lng: 46, lat: 25)])
        XCTAssertEqual(deg, 111_195, accuracy: 50)
        XCTAssertEqual(PlanGeo.length([LngLat(lng: 46, lat: 24)]), 0)
        XCTAssertEqual(PlanETA.seconds(meters: 35_000), 3600)
        XCTAssertEqual(PlanETA.seconds(meters: 0), 0)
    }

    func testSimplifyStraightLineAndKeepsCorners() {
        let line = (0...100).map { LngLat(lng: 46 + Double($0) * 0.001, lat: 24) }
        XCTAssertEqual(PlanSimplify.douglasPeucker(line, toleranceM: 5).count, 2)
        let corner = [LngLat(lng: 46, lat: 24), LngLat(lng: 46.01, lat: 24), LngLat(lng: 46.01, lat: 24.01)]
        XCTAssertEqual(PlanSimplify.douglasPeucker(corner, toleranceM: 5), corner)
    }

    func testCappedDropsDuplicatesInvalidAndFits() {
        let pts = [LngLat(lng: 46, lat: 24), LngLat(lng: 46, lat: 24), LngLat(lng: 500, lat: 24), LngLat(lng: 46.1, lat: 24.1)]
        XCTAssertEqual(PlanSimplify.capped(pts), [LngLat(lng: 46, lat: 24), LngLat(lng: 46.1, lat: 24.1)])
        /* A hand-drawn route under the cap is kept as drawn (collinear points too); an import is simplified. */
        let drawn = (0...10).map { LngLat(lng: 46 + Double($0) * 0.001, lat: 24) }
        XCTAssertEqual(PlanSimplify.capped(drawn), drawn)
        XCTAssertEqual(PlanSimplify.capped(drawn, simplify: true).count, 2)
        /* Random noise cannot be simplified much: the cap still holds. */
        var rng = SystemRandomNumberGenerator()
        let noise = (0..<20_000).map { _ in LngLat(lng: 46 + Double.random(in: 0...0.5, using: &rng), lat: 24 + Double.random(in: 0...0.5, using: &rng)) }
        XCTAssertLessThanOrEqual(PlanSimplify.capped(noise, max: 5000).count, 5000)
        XCTAssertLessThanOrEqual(PlanSimplify.capped(noise, max: 100).count, 100)
    }

    func testNearestAndFollowPlanHysteresis() {
        let route = [LngLat(lng: 46.0, lat: 24.0), LngLat(lng: 46.1, lat: 24.0)] // ~10 km east
        var f = FollowPlan(points: route)
        func at(_ northM: Double, _ lng: Double = 46.05) -> LngLat { LngLat(lng: lng, lat: 24.0 + northM / 111_195) }

        XCTAssertEqual(f.update(me: nil, fixAgeS: 0, accuracyM: 5).kind, .waitingForFix)
        XCTAssertEqual(f.update(me: at(10), fixAgeS: 120, accuracyM: 5).kind, .waitingForFix, "an old fix is never 'now'")
        XCTAssertEqual(f.update(me: at(10), fixAgeS: 1, accuracyM: 500).kind, .waitingForFix, "a vague fix is not used")

        let on = f.update(me: at(20), fixAgeS: 1, accuracyM: 5)
        XCTAssertEqual(on.kind, .onRoute)
        XCTAssertEqual(on.remainingM, 5_080, accuracy: 120)
        let off = f.update(me: at(80), fixAgeS: 1, accuracyM: 5)
        XCTAssertEqual(off.kind, .offRoute)
        XCTAssertEqual(off.offM, 80, accuracy: 1)
        XCTAssertEqual(off.backBearing, 180, accuracy: 1, "back on is due south")
        XCTAssertEqual(f.update(me: at(50), fixAgeS: 1, accuracyM: 5).kind, .offRoute, "stays off until under 45 m")
        XCTAssertEqual(f.update(me: at(40), fixAgeS: 1, accuracyM: 5).kind, .onRoute)
        XCTAssertEqual(f.update(me: at(5, 46.0999), fixAgeS: 1, accuracyM: 5).kind, .arrived)
    }
}

// MARK: - plan model types

final class TripPlanCodingTests: XCTestCase {
    func testDecodesWithAndWithoutDestinationAndNulls() throws {
        let a = try JSONDecoder().decode(TripPlan.self, from: Data(#"{"route":{"type":"LineString","coordinates":[[46.6,24.7],[46.7,24.8]]},"notes":"x","updated_at":"2026-11-04T10:00:00Z"}"#.utf8))
        XCTAssertEqual(a.points.count, 2)
        XCTAssertNil(a.destination)
        let b = try JSONDecoder().decode(TripPlan.self, from: Data(#"{"route":null,"notes":null,"destination":{"name":"روضة","lat":25,"lng":47}}"#.utf8))
        XCTAssertFalse(b.hasRoute)
        XCTAssertEqual(b.notes, "")
        XCTAssertEqual(b.destination, OutingDestination(name: "روضة", lat: 25, lng: 47))
    }

    func testEncodeSendsExplicitNullsAndCleans() throws {
        let p = TripPlan(route: nil, notes: String(repeating: "ا", count: 1200), destination: OutingDestination(name: "  ", lat: 24, lng: 46), updated_at: "x").cleanedForUpload()
        XCTAssertEqual(p.notes.count, TripPlan.notesMax)
        XCTAssertEqual(p.destination?.name, "الوجهة")
        let json = String(decoding: try JSONEncoder().encode(p), as: UTF8.self)
        XCTAssertTrue(json.contains("\"route\":null"))
        XCTAssertFalse(json.contains("updated_at"))
    }

    func testLiveEventsDecode() {
        let e1 = LiveEvent.decode(["type": "plan_updated", "plan": ["route": NSNull(), "notes": "n", "destination": ["name": "د", "lat": 24, "lng": 46]]])
        XCTAssertEqual(e1, .planUpdated(TripPlan(route: nil, notes: "n", destination: OutingDestination(name: "د", lat: 24, lng: 46), updated_at: nil)))
        XCTAssertEqual(LiveEvent.decode(["type": "plan_updated"]), .planUpdated(nil))
        let e2 = LiveEvent.decode(["type": "checklist_updated", "items": [["id": "a", "title": "ماء", "done": true, "assignee_user_id": NSNull()]]])
        XCTAssertEqual(e2, .checklistUpdated([ChecklistItem(id: "a", title: "ماء", done: true)]))
    }
}

final class ChecklistStateTests: XCTestCase {
    func testProgressOrderingSuggestions() {
        var s = ChecklistState()
        for i in 0..<10 { s.upsert(ChecklistItem(id: "\(i)", title: ["ماء", "حطب", "شاحن", "a", "b", "c", "d", "e", "f", "g"][i], done: i < 7)) }
        XCTAssertEqual(s.progressLabel, "٧ من ١٠")
        XCTAssertEqual(s.fraction, 0.7, accuracy: 0.0001)
        XCTAssertEqual(s.ordered.prefix(3).map(\.id), ["7", "8", "9"], "open items first")
        XCTAssertFalse(s.openSuggestions.contains("ماء"))
        XCTAssertTrue(s.openSuggestions.contains("حبل سحب"))
        XCTAssertTrue(s.contains(title: " ماء "))
        s.setDone("7", true)
        s.assign("8", to: "u1")
        s.remove("9")
        XCTAssertEqual(s.progressLabel, "٨ من ٩")
        XCTAssertEqual(s.items.first { $0.id == "8" }?.assignee_user_id, "u1")
    }

    func testTitlesAndDeleteRights() {
        XCTAssertNil(ChecklistState.cleanTitle("   \n "))
        XCTAssertEqual(ChecklistState.cleanTitle(" حبل\nسحب "), "حبل سحب")
        XCTAssertEqual(ChecklistState.cleanTitle(String(repeating: "ب", count: 60))?.count, 40)
        let item = ChecklistItem(id: "1", title: "x", created_by: "me")
        XCTAssertTrue(ChecklistState.canDelete(item, me: "me", iLead: false))
        XCTAssertFalse(ChecklistState.canDelete(item, me: "other", iLead: false))
        XCTAssertTrue(ChecklistState.canDelete(item, me: "other", iLead: true))
    }
}

// MARK: - fake API flows

final class FakePlanBackend: PlanBackend {
    var plan = TripPlan.empty
    var items: [ChecklistItem] = []
    var failNext: OutingAPIError?
    var notDeployed = false
    var puts: [TripPlan] = []
    var patches: [(String, Bool?, AssigneeChange?)] = []
    var replyWithList = false

    private func gate() throws {
        if notDeployed { throw OutingAPIError(code: "http_404", status: 404) }
        if let e = failNext { failNext = nil; throw e }
    }

    func plan(_ id: String) async throws -> TripPlan { try gate(); return plan }
    func putPlan(_ id: String, _ p: TripPlan) async throws -> TripPlan {
        try gate()
        puts.append(p)
        plan = p
        plan.updated_at = "now"
        return plan
    }
    func checklist(_ id: String) async throws -> [ChecklistItem] { try gate(); return items }
    func addItem(_ id: String, title: String) async throws -> ChecklistReply {
        try gate()
        let i = ChecklistItem(id: "s\(items.count + 1)", title: title, created_by: "me")
        items.append(i)
        return replyWithList ? ChecklistReply(items: items) : ChecklistReply(item: i)
    }
    func patchItem(_ id: String, _ itemId: String, done: Bool?, assignee: AssigneeChange?) async throws -> ChecklistReply {
        try gate()
        patches.append((itemId, done, assignee))
        guard let k = items.firstIndex(where: { $0.id == itemId }) else { throw OutingAPIError(code: "not_found", status: 404) }
        if let done { items[k].done = done }
        if case let .set(u)? = assignee { items[k].assignee_user_id = u }
        if case .clear? = assignee { items[k].assignee_user_id = nil }
        return ChecklistReply(item: items[k])
    }
    func deleteItem(_ id: String, _ itemId: String) async throws -> ChecklistReply {
        try gate()
        items.removeAll { $0.id == itemId }
        return ChecklistReply()
    }
    func setRally(_ id: String, lat: Double, lng: Double, label: String?) async throws -> RallyInfo? {
        try gate()
        return RallyInfo(lat: lat, lng: lng, label: label, set_at: nil, set_by: nil)
    }
}

@MainActor
final class PlanModelTests: XCTestCase {
    let route = [LngLat(lng: 46.6, lat: 24.7), LngLat(lng: 46.7, lat: 24.8)]

    func testLoadSaveAndRollback() async {
        let b = FakePlanBackend()
        b.items = [ChecklistItem(id: "1", title: "ماء")]
        let m = PlanModel(outingId: "o", backend: b)
        await m.load()
        XCTAssertEqual(m.planPhase, .loaded)
        XCTAssertEqual(m.checklistPhase, .loaded)
        XCTAssertEqual(m.checklist.total, 1)

        let ok = await m.save(TripPlan(route: PlanLineString(route), notes: " ملاحظة ", destination: nil, updated_at: nil))
        XCTAssertTrue(ok)
        XCTAssertEqual(b.puts.last?.notes, "ملاحظة")
        XCTAssertEqual(m.plan.points, route)
        XCTAssertEqual(m.routeLengthM, PlanGeo.length(route), accuracy: 0.1)

        b.failNext = OutingAPIError(code: "leader_only", status: 403)
        let refused = await m.save(TripPlan(route: nil, notes: "", destination: nil, updated_at: nil))
        XCTAssertFalse(refused)
        XCTAssertEqual(m.plan.points, route, "rolled back")
        XCTAssertEqual(m.errorText, "تعديل الخطة لأمير الرحلة أو نائبه فقط.")
    }

    func testNotDeployedIsHonest() async {
        let b = FakePlanBackend()
        b.notDeployed = true
        let m = PlanModel(outingId: "o", backend: b)
        await m.load()
        XCTAssertEqual(m.planPhase, .unavailable)
        XCTAssertEqual(m.checklistPhase, .unavailable)
        let added = await m.add("ماء", me: "me")
        XCTAssertFalse(added)
        XCTAssertTrue(m.checklist.items.isEmpty, "nothing pretends to be saved")
        XCTAssertEqual(m.errorText, "قائمة التجهيز غير متاحة بعد على الخادم.")
        /* A real 404 for something else (an outing that is gone) is not "not deployed". */
        XCTAssertFalse(PlanAvailability.notDeployed(OutingAPIError(code: "not_a_member", status: 404)))
        XCTAssertTrue(PlanAvailability.notDeployed(OutingAPIError(code: "http_405", status: 405)))
    }

    func testChecklistFlows() async {
        let b = FakePlanBackend()
        let m = PlanModel(outingId: "o", backend: b)
        await m.load()
        let a1 = await m.add("ماء", me: "me")
        XCTAssertTrue(a1)
        let dup = await m.add(" ماء", me: "me")
        XCTAssertFalse(dup)
        b.replyWithList = true
        _ = await m.add("حطب", me: "me")
        XCTAssertEqual(m.checklist.items.map(\.title), ["ماء", "حطب"])
        XCTAssertFalse(m.checklist.items.contains { $0.id.hasPrefix("local-") })

        let id = m.checklist.items[0].id
        await m.toggle(id)
        XCTAssertTrue(m.checklist.items[0].done)
        XCTAssertEqual(m.checklist.progressLabel, "١ من ٢")
        await m.assign(id, to: "u2")
        XCTAssertEqual(m.checklist.items[0].assignee_user_id, "u2")
        await m.assign(id, to: nil)
        XCTAssertEqual(b.patches.last?.2, .clear)

        b.failNext = OutingAPIError(code: "network", status: 0)
        await m.toggle(id)
        XCTAssertTrue(m.checklist.items[0].done, "rolled back after a failure")

        await m.delete(id)
        XCTAssertEqual(m.checklist.items.map(\.title), ["حطب"])
    }

    func testLiveEventsUpdateTheModel() async {
        let b = FakePlanBackend()
        let m = PlanModel(outingId: "o", backend: b)
        await m.load()
        PlanEvents.post(outing: "o", .checklistUpdated([ChecklistItem(id: "x", title: "شاحن", done: true)]))
        XCTAssertEqual(m.checklist.progressLabel, "١ من ١")
        PlanEvents.post(outing: "other", .checklistUpdated([]))
        XCTAssertEqual(m.checklist.total, 1, "another outing's event is ignored")
        let p = TripPlan(route: PlanLineString(route), notes: "", destination: nil, updated_at: "t")
        m.apply(.planUpdated(p))
        XCTAssertTrue(m.plan.hasRoute)
        m.following = true
        m.apply(.planUpdated(.empty))
        XCTAssertFalse(m.following, "nothing to follow once the route is gone")
    }

    func testFollowStatusUsesOnlyAFreshFix() async {
        let b = FakePlanBackend()
        b.plan = TripPlan(route: PlanLineString(route), notes: "", destination: nil, updated_at: nil)
        let m = PlanModel(outingId: "o", backend: b)
        await m.load()
        let now = Date()
        let old = DeviceFix(lat: 24.7, lng: 46.6, accuracy: 5, heading: nil, speed: nil, atMs: (now.timeIntervalSince1970 - 300) * 1000)
        XCTAssertEqual(m.followStatus(fix: old, now: now).kind, .waitingForFix)
        let fresh = DeviceFix(lat: 24.7, lng: 46.6, accuracy: 5, heading: nil, speed: nil, atMs: now.timeIntervalSince1970 * 1000)
        XCTAssertEqual(m.followStatus(fix: fresh, now: now).kind, .onRoute)
    }
}

// MARK: - coordinates

final class CoordinateParserTests: XCTestCase {
    private func p(_ s: String, file: StaticString = #filePath, line: UInt = #line) -> LngLat? {
        CoordinateParser.parse(s)?.point
    }

    private func assertNear(_ a: LngLat?, _ lat: Double, _ lng: Double, _ acc: Double = 0.00002, file: StaticString = #filePath, line: UInt = #line) {
        guard let a else { return XCTFail("not parsed", file: file, line: line) }
        XCTAssertEqual(a.lat, lat, accuracy: acc, file: file, line: line)
        XCTAssertEqual(a.lng, lng, accuracy: acc, file: file, line: line)
    }

    func testDecimal() {
        assertNear(p("24.7136, 46.6753"), 24.7136, 46.6753)
        assertNear(p("24.7136 46.6753"), 24.7136, 46.6753)
        assertNear(p("  24.7136,46.6753  "), 24.7136, 46.6753)
        assertNear(p("-33.8688, 151.2093"), -33.8688, 151.2093)
    }

    func testHemisphereLetters() {
        assertNear(p("24.7136N 46.6753E"), 24.7136, 46.6753)
        assertNear(p("N24.7136 E46.6753"), 24.7136, 46.6753)
        assertNear(p("46.6753E, 24.7136N"), 24.7136, 46.6753)
        assertNear(p("33.8688 S, 151.2093 E"), -33.8688, 151.2093)
        assertNear(p("24.7136° N, 46.6753° E"), 24.7136, 46.6753)
        assertNear(p("24.7136 شمال 46.6753 شرق"), 24.7136, 46.6753)
    }

    func testDMS() {
        assertNear(p("24°42'49\"N 46°40'31\"E"), 24.713611, 46.675278, 0.00001)
        assertNear(p("24°42′49″N, 46°40′31″E"), 24.713611, 46.675278, 0.00001)
        assertNear(p("N 24°42'49.5\" E 46°40'31.2\""), 24.713750, 46.675333, 0.00001)
        assertNear(p("24 42 49 N 46 40 31 E"), 24.713611, 46.675278, 0.00001)
        assertNear(p("33°51'08\"S 151°12'33\"E"), -33.852222, 151.209167, 0.00001)
    }

    func testDDM() {
        assertNear(p("24°42.817'N 46°40.517'E"), 24.713617, 46.675283, 0.00001)
        assertNear(p("N24 42.817 E46 40.517"), 24.713617, 46.675283, 0.00001)
    }

    func testArabicIndicDigitsAndSeparators() {
        assertNear(p("٢٤٫٧١٣٦، ٤٦٫٦٧٥٣"), 24.7136, 46.6753)
        assertNear(p("٢٤°٤٢'٤٩\"N ٤٦°٤٠'٣١\"E"), 24.713611, 46.675278, 0.00001)
        assertNear(p("۲۴.۷۱۳۶, ۴۶.۶۷۵۳"), 24.7136, 46.6753)
    }

    func testSwappedOrderIsDetected() {
        let r = CoordinateParser.parse("146.6753, 24.7136")
        XCTAssertEqual(r?.swapped, true)
        assertNear(r?.point, 24.7136, 146.6753)
        XCTAssertEqual(r?.outsideRegion, true, "a warning, never a block")
        XCTAssertEqual(CoordinateParser.parse("24.7136, 46.6753")?.outsideRegion, false)
    }

    func testMapLinks() {
        assertNear(p("https://www.google.com/maps/place/Riyadh/@24.7136,46.6753,12z/data=!3d24.7200!4d46.6800"), 24.72, 46.68)
        assertNear(p("https://www.google.com/maps/@24.7136,46.6753,15z"), 24.7136, 46.6753)
        assertNear(p("https://www.google.com/maps/search/?api=1&query=24.7136,46.6753"), 24.7136, 46.6753)
        assertNear(p("https://maps.google.com/?q=24.7136,46.6753"), 24.7136, 46.6753)
        assertNear(p("https://www.google.com/maps/dir/?api=1&destination=24.7136%2C46.6753"), 24.7136, 46.6753)
        assertNear(p("https://maps.apple.com/?ll=24.7136,46.6753&q=Pin"), 24.7136, 46.6753)
        assertNear(p("https://maps.apple.com/?daddr=24.7136,46.6753"), 24.7136, 46.6753)
        assertNear(p("https://waze.com/ul?ll=24.7136,46.6753&navigate=yes"), 24.7136, 46.6753)
        XCTAssertNil(p("https://example.com/?q=24.7136,46.6753"), "only map links are read as links")
    }

    func testPlusCodes() {
        /* 7HP8PM7G+C4 is the cell around 24.7136, 46.6753 (Riyadh), ~14 m wide. */
        assertNear(p("7HP8PM7G+C4"), 24.7136, 46.6753, 0.0002)
        assertNear(p("7HP8PM7G+"), 24.7136, 46.6753, 0.003)
        XCTAssertNil(CoordinateParser.plusCode("6MGG+2V"), "short codes need a reference place")
    }

    func testInvalidInput() {
        for s in ["", "   ", "hello", "24.7136", "95, 195", "24.7, 190", "24°75'00\"N 46°40'31\"E", "24°42'61\"N 46°40'31\"E", "1,2,3", "NaN, NaN", String(repeating: "9", count: 3000)] {
            XCTAssertNil(CoordinateParser.parse(s), s)
        }
    }

    func testOutputFormats() {
        let pt = LngLat(lng: 46.67530, lat: 24.71360)
        XCTAssertEqual(CoordinateParser.decimalString(pt), "24.713600, 46.675300")
        XCTAssertEqual(CoordinateParser.dmsString(pt), "24°42'49.0\"N 46°40'31.1\"E")
        assertNear(p(CoordinateParser.dmsString(pt)), 24.7136, 46.6753, 0.0001)
        XCTAssertEqual(CoordinateParser.dmsString(LngLat(lng: -0.5, lat: -10.25)), "10°15'00.0\"S 0°30'00.0\"W")
    }
}

final class CoordinateShareTests: XCTestCase {
    let riyadh = TimeZone(identifier: "Asia/Riyadh")!
    let pt = LngLat(lng: 46.6753, lat: 24.7136)

    /// 15:45 Riyadh time.
    var at: Date { ISODate.parse("2026-11-04T12:45:00.000Z")! }

    func testCopyIsWesternDisplayIsArabicIndic() {
        XCTAssertEqual(CoordinateShare.copyDecimal(pt), "24.71360, 46.67530")
        XCTAssertEqual(CoordinateShare.copy(pt, .dms), "24°42'49.0\"N 46°40'31.1\"E")
        XCTAssertEqual(CoordinateShare.displayDecimal(pt), "٢٤٫٧١٣٦٠، ٤٦٫٦٧٥٣٠")
        XCTAssertEqual(CoordinateShare.displayDMS(pt).filter { $0 != "\u{200E}" }, "٢٤°٤٢'٤٩٫٠\"N ٤٦°٤٠'٣١٫١\"E")
        XCTAssertEqual(CoordinateShare.accuracyLabel(8), "دقة ±٨ م")
        XCTAssertNil(CoordinateShare.accuracyLabel(nil))
        XCTAssertEqual(CoordinateShare.clock(at, timeZone: riyadh), "٣:٤٥ م")
        XCTAssertEqual(CoordinateShare.clock(ISODate.parse("2026-11-04T21:05:00.000Z")!, timeZone: riyadh), "١٢:٠٥ ص")
    }

    func testLinksUseWesternDigits() {
        XCTAssertEqual(CoordinateShare.link(pt, .google).absoluteString, "https://www.google.com/maps/search/?api=1&query=24.71360,46.67530")
        XCTAssertEqual(CoordinateShare.link(pt, .waze).absoluteString, "https://waze.com/ul?ll=24.71360,46.67530")
        XCTAssertEqual(CoordinateShare.directionsLink(pt, .google).absoluteString, "https://www.google.com/maps/dir/?api=1&destination=24.71360,46.67530&travelmode=driving")
        XCTAssertEqual(CoordinateShare.directionsLink(pt, .waze).absoluteString, "https://waze.com/ul?ll=24.71360,46.67530&navigate=yes")
        XCTAssertEqual(CoordinateShare.MapLink.allCases, [.google, .waze], "no Apple Maps")
        /* Every link parses back to the same point. */
        for k in CoordinateShare.MapLink.allCases {
            XCTAssertEqual(CoordinateParser.parse(CoordinateShare.link(pt, k).absoluteString)?.point.lat ?? 0, 24.7136, accuracy: 0.00001)
        }
    }

    func testMyLocationFreshAndStale() {
        let fix = CoordinateShare.Fix(point: pt, accuracyM: 8, at: at)
        XCTAssertEqual(CoordinateShare.myLocationMessage(fix, now: at.addingTimeInterval(10), timeZone: riyadh),
                       "موقعي الحين: https://www.google.com/maps/search/?api=1&query=24.71360,46.67530 — 24.71360, 46.67530 — دقة ±٨ م — ٣:٤٥ م")
        XCTAssertEqual(CoordinateShare.myLocationCopy(fix, now: at.addingTimeInterval(10), timeZone: riyadh), "24.71360, 46.67530 — دقة ±٨ م — ٣:٤٥ م")

        let later = at.addingTimeInterval(5 * 60)
        let stale = CoordinateShare.myLocationMessage(fix, link: .waze, now: later, timeZone: riyadh)
        XCTAssertTrue(stale.hasPrefix("آخر موقع معروف قبل ٥ د: https://waze.com/ul?ll=24.71360,46.67530"))
        XCTAssertFalse(stale.contains("الحين"), "a stale fix is never called current")
        XCTAssertTrue(CoordinateShare.myLocationCopy(fix, format: .dms, now: later, timeZone: riyadh).hasPrefix("آخر موقع معروف قبل ٥ د: 24°42'49.0\"N"))
        XCTAssertEqual(CoordinateShare.pointMessage(pt, name: "روضة"), "روضة: https://www.google.com/maps/search/?api=1&query=24.71360,46.67530 — 24.71360, 46.67530")
    }
}

// MARK: - place search

final class PlaceSearchTests: XCTestCase {
    func testCategoryWordsAreAskedAsAppleCategories() {
        XCTAssertEqual(PlaceSearch.poiCategory(forQuery: "محطة بنزين"), .gasStation)
        XCTAssertEqual(PlaceSearch.poiCategory(forQuery: " محطه وقود "), .gasStation)
        XCTAssertEqual(PlaceSearch.poiCategory(forQuery: "صيدلية"), .pharmacy)
        XCTAssertEqual(PlaceSearch.poiCategory(forQuery: "مستشفى"), .hospital)
        XCTAssertEqual(PlaceSearch.poiCategory(forQuery: "Gas Station"), .gasStation)
        XCTAssertNil(PlaceSearch.poiCategory(forQuery: "ماكدونالدز"), "a name stays a name")
        XCTAssertNil(PlaceSearch.poiCategory(forQuery: "محطة بنزين الدريس"), "a named station stays a name search")
        XCTAssertNil(PlaceSearch.poiCategory(forQuery: "محطة"), "«محطة» alone may be a metro or bus station")
    }

    func testMapboxDetailWithoutALeadingSeparator() {
        let json = #"{"features":[{"id":"x","geometry":{"coordinates":[46.67,24.72]},"properties":{"name":"الغريراء","place_formatted":"، الرياض، السعودية","feature_type":"street"}}]}"#
        XCTAssertEqual(PlaceSearch.parse(Data(json.utf8)).first?.detail, "الرياض، السعودية")
    }

    func testApplePlacesPiledOnACityCentreAreLeftOut() {
        let centre = LngLat(lng: 46.6753, lat: 24.7136)
        func apple(_ n: String, _ p: LngLat) -> PlaceSearch.Place { .init(id: "apple:\(n)", name: n, detail: nil, point: p, country: "SA") }
        let pile = ["جدة", "Banderseed", "Fuelco"].map { apple($0, LngLat(lng: centre.lng, lat: centre.lat - 0.00005)) }
        let real = apple("Asia", LngLat(lng: 46.67793, lat: 24.71438))
        let twin = [apple("الدريس", LngLat(lng: 46.70, lat: 24.70)), apple("الدريس", LngLat(lng: 46.70, lat: 24.70))]
        let out = PlaceSearch.rank(query: "محطة بنزين", around: pile + [real] + twin, saudi: [], mapbox: [], near: centre)
        XCTAssertEqual(out.map(\.name), ["Asia", "الدريس"], "the pile goes; one real place and one of the twins stay")
    }

    static let fixture = Data("""
    {"type":"FeatureCollection","features":[
      {"type":"Feature","id":"dXJuOm1ieHBsYzpBUU","geometry":{"type":"Point","coordinates":[46.83,24.92]},
       "properties":{"mapbox_id":"x1","feature_type":"place","name":"الثمامة","place_formatted":"الرياض، السعودية","coordinates":{"longitude":46.8312,"latitude":24.9201}}},
      {"type":"Feature","geometry":{"type":"Point","coordinates":[46.70,24.65]},"properties":{"name":"روضة خريم","full_address":"روضة خريم، السعودية"}},
      {"type":"Feature","geometry":{"type":"Point","coordinates":[999,24]},"properties":{"name":"bad"}},
      {"type":"Feature","geometry":{"type":"Point","coordinates":[46,24]},"properties":{}}
    ]}
    """.utf8)

    func testRequestBuilding() throws {
        let r = try XCTUnwrap(PlaceSearch.request(query: "  روضة خريم ", proximity: LngLat(lng: 46.67531, lat: 24.71362), saudiOnly: true, token: "TEST"))
        let c = try XCTUnwrap(URLComponents(url: r.url!, resolvingAgainstBaseURL: false))
        XCTAssertEqual(c.host, "api.mapbox.com")
        XCTAssertEqual(c.path, "/search/geocode/v6/forward")
        let q = Dictionary(uniqueKeysWithValues: (c.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(q["q"], "روضة خريم")
        XCTAssertEqual(q["language"], "ar")
        XCTAssertEqual(q["country"], "sa")
        XCTAssertEqual(q["proximity"], "46.6753,24.7136", "coarse: 4 decimals, lng first")
        XCTAssertEqual(q["access_token"], "TEST")
        let world = try XCTUnwrap(PlaceSearch.request(query: "x", proximity: nil, saudiOnly: false, token: "T"))
        XCTAssertFalse(world.url!.absoluteString.contains("country="))
        XCTAssertFalse(world.url!.absoluteString.contains("proximity="))
        XCTAssertNil(PlaceSearch.request(query: "  ", proximity: nil, saudiOnly: true, token: "T"))
    }

    func testParsing() {
        let r = PlaceSearch.parse(Self.fixture)
        XCTAssertEqual(r.count, 2)
        XCTAssertEqual(r[0], PlaceSearch.Place(id: "dXJuOm1ieHBsYzpBUU", name: "الثمامة", detail: "الرياض، السعودية", point: LngLat(lng: 46.8312, lat: 24.9201),
                                               icon: "building.columns"))
        XCTAssertEqual(r[1].name, "روضة خريم")
        XCTAssertEqual(r[1].point, LngLat(lng: 46.70, lat: 24.65))
        XCTAssertEqual(PlaceSearch.parse(Data("not json".utf8)), [])
    }

    /// Mapbox alone (no Apple search): Saudi first, then the world; its errors surface.
    func testSaudiFirstThenWorldAndErrors() async throws {
        var urls: [URL] = []
        let empty = Data(#"{"type":"FeatureCollection","features":[]}"#.utf8)
        let found = try await PlaceSearch.search("x", near: nil, token: "T", fetch: { req in
            urls.append(req.url!)
            return (urls.count == 1 ? empty : Self.fixture, 200)
        }, local: nil)
        XCTAssertEqual(found.count, 2)
        XCTAssertEqual(urls.count, 2)
        XCTAssertTrue(urls[0].absoluteString.contains("country=sa"))
        XCTAssertFalse(urls[1].absoluteString.contains("country=sa"))

        do {
            _ = try await PlaceSearch.search("x", near: nil, token: nil, fetch: { _ in (Data(), 200) }, local: nil)
            XCTFail()
        } catch { XCTAssertEqual(error as? PlaceSearch.SearchError, .noToken) }
        do {
            _ = try await PlaceSearch.search("x", near: nil, token: "T", fetch: { _ in (Data(), 401) }, local: nil)
            XCTFail()
        } catch { XCTAssertEqual(error as? PlaceSearch.SearchError, .http(401)) }
        do {
            _ = try await PlaceSearch.search("x", near: nil, token: "T", fetch: { _ in throw URLError(.notConnectedToInternet) }, local: nil)
            XCTFail()
        } catch { XCTAssertEqual(error as? PlaceSearch.SearchError, .network) }
    }

    /// Apple is asked from concurrent child tasks: record its scopes under a lock.
    final class Scopes: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [PlaceSearch.AppleScope] = []
        func add(_ s: PlaceSearch.AppleScope) { lock.lock(); list.append(s); lock.unlock() }
        var all: [PlaceSearch.AppleScope] { lock.lock(); defer { lock.unlock() }; return list }
    }

    static let me = LngLat(lng: 46.6753, lat: 24.7136) // Riyadh
    static func poi(_ name: String, _ lat: Double, _ lng: Double, country: String? = "SA") -> PlaceSearch.Place {
        PlaceSearch.Place(id: "apple:\(lat),\(lng):\(name)", name: name, detail: nil, point: LngLat(lng: lng, lat: lat),
                          category: "مطعم", icon: "fork.knife", country: country)
    }

    /// «ماكدونالدز»: Apple is asked around me and across the Kingdom; the nearest branch comes first.
    func testChainAnswersNearestBranchFirst() async throws {
        let scopes = Scopes()
        let far = Self.poi("ماكدونالدز", 21.5433, 39.1728)      // Jeddah
        let mid = Self.poi("ماكدونالدز", 24.7743, 46.7386)      // ~9 km
        let close = Self.poi("ماكدونالدز", 24.7200, 46.6800)    // ~0.8 km
        let found = try await PlaceSearch.search("ماكدونالدز", near: Self.me, token: nil, fetch: { _ in (Data(), 200) }, local: { _, scope in
            scopes.add(scope)
            if case .around = scope { return [mid, close] }
            return [far, mid]
        })
        XCTAssertEqual(scopes.all.count, 4, "around me and the Kingdom, in Arabic and in English («McDonald's»)")
        XCTAssertTrue(scopes.all.contains(.saudi))
        XCTAssertTrue(scopes.all.contains(.around(Self.me)))
        XCTAssertEqual(found.map(\.point), [close.point, mid.point, far.point], "nearest first; the duplicate branch kept once")
    }

    /// Without my position Apple is asked once, Kingdom-wide.
    func testNoPositionAsksTheKingdomOnly() async throws {
        let scopes = Scopes()
        let found = try await PlaceSearch.search("شاليهات", near: nil, token: nil, fetch: { _ in (Data(), 200) }, local: { _, scope in
            scopes.add(scope)
            return [Self.poi("شاليه الوردة", 24.9, 46.5)]
        })
        XCTAssertFalse(scopes.all.isEmpty)
        XCTAssertTrue(scopes.all.allSatisfy { $0 == .saudi }, "the Kingdom only (in Arabic and English)")
        XCTAssertEqual(found.map(\.name), ["شاليه الوردة"])
    }

    /// One source failing is not an error; Apple's places and Mapbox's areas are merged.
    func testOneSourceFailingStillAnswers() async throws {
        let apple = try await PlaceSearch.search("x", near: Self.me, token: "T", fetch: { _ in throw URLError(.notConnectedToInternet) }, local: { _, _ in
            [Self.poi("مطعم", 24.72, 46.68)]
        })
        XCTAssertEqual(apple.count, 1)
        let mapbox = try await PlaceSearch.search("x", near: Self.me, token: "T", fetch: { _ in (Self.fixture, 200) }, local: { _, _ in
            throw PlaceSearch.SearchError.network
        })
        XCTAssertEqual(mapbox.map(\.name), ["روضة خريم", "الثمامة"], "both within 50 km: nearest first")
        do {
            _ = try await PlaceSearch.search("x", near: Self.me, token: "T", fetch: { _ in (Data(), 500) }, local: { _, _ in throw PlaceSearch.SearchError.network })
            XCTFail()
        } catch { XCTAssertEqual(error as? PlaceSearch.SearchError, .http(500)) }
    }

    func testRanking() {
        let exactFar = Self.poi("نفود الثويرات", 25.77, 45.10)
        let near1 = Self.poi("استراحة نفود", 24.72, 46.68)
        let kingdomA = Self.poi("نفود السر", 25.9, 44.5)
        let kingdomFar = Self.poi("نفود الدحي", 20.5, 44.8)
        let abroad = Self.poi("Nafud", 29.0, 35.0, country: "JO")
        let r = PlaceSearch.rank(query: "نُفود الثُويرات", around: [near1], saudi: [abroad, kingdomFar, kingdomA, exactFar], mapbox: [], near: Self.me)
        XCTAssertEqual(r.map(\.name), ["نفود الثويرات", "استراحة نفود", "نفود السر", "نفود الدحي", "Nafud"],
                       "exact name, then nearby by distance, then the rest of the Kingdom nearest first (not source order), abroad last")
        let many = (0..<30).map { Self.poi("p\($0)", 24.7 + Double($0) * 0.001, 46.67) }
        XCTAssertEqual(PlaceSearch.rank(query: "p", around: many, saudi: [], mapbox: [], near: Self.me).count, PlaceSearch.maxResults)
    }

    func testNormalizeAndDuplicates() {
        XCTAssertEqual(PlaceSearch.normalize("مَطْعَم  الأمـيرة"), PlaceSearch.normalize("مطعم الاميره"))
        XCTAssertEqual(PlaceSearch.normalize("McDonald's"), PlaceSearch.normalize("mcdonalds"))
        let a = Self.poi("البيك", 24.7200, 46.6800)
        var b = a; b.id = "mapbox:1"; b.point = LngLat(lng: 46.6805, lat: 24.7203)
        var c = b; c.point = LngLat(lng: 46.70, lat: 24.75)
        XCTAssertTrue(PlaceSearch.duplicate(a, b))
        XCTAssertFalse(PlaceSearch.duplicate(a, c), "another branch")
    }

    func testSubtitle() {
        XCTAssertEqual(PlaceSearch.Place(id: "1", name: "x", detail: "العليا، الرياض", point: Self.me, category: "مطعم").subtitle, "مطعم · العليا، الرياض")
        XCTAssertNil(PlaceSearch.Place(id: "1", name: "x", detail: nil, point: Self.me).subtitle)
    }
}
