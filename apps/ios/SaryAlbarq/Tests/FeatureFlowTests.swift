import XCTest
@testable import SaryAlbarq

/// A scripted server for waypoints / convoy.
final class FakeFeaturesBackend: OutingFeaturesBackend {
    var list: [Waypoint] = []
    var failWith: Error?
    var posted: [WaypointDraft] = []
    var deleted: [String] = []
    var convoys: [ConvoyInfo] = []

    func waypoints(_ outingId: String) async throws -> [Waypoint] {
        if let failWith { throw failWith }
        return list
    }

    func addWaypoint(_ outingId: String, _ draft: WaypointDraft) async throws -> Waypoint {
        if let failWith { throw failWith }
        posted.append(draft)
        let w = Waypoint(id: "srv-\(posted.count)", outing_id: outingId, user_id: "u1", kind: draft.kind, title: draft.title, note: draft.note,
                         lat: draft.lat, lng: draft.lng, photo: draft.photo, created_at: ISODate.string(Date()))
        list.append(w)
        return w
    }

    func deleteWaypoint(_ outingId: String, id: String) async throws {
        if let failWith { throw failWith }
        deleted.append(id)
        list.removeAll { $0.id == id }
    }

    func setConvoy(_ outingId: String, _ convoy: ConvoyInfo) async throws -> ConvoyInfo? {
        if let failWith { throw failWith }
        convoys.append(convoy)
        return convoy.isOn ? convoy : nil
    }
}

/// Waypoints and convoy through the real session and live channel (fake socket, fake server).
@MainActor
final class FeatureFlowTests: XCTestCase {
    private var sockets: [FakeSocket] = []
    private var backend: FakeFeaturesBackend!
    private var savedCacheDir: URL!
    /// The model holds its session weakly (the controller owns it in the app): the test keeps them alive.
    private var keep: [OutingSession] = []

    override func setUp() async throws {
        sockets = []
        backend = FakeFeaturesBackend()
        savedCacheDir = WaypointCache.directory
        WaypointCache.directory = FileManager.default.temporaryDirectory.appendingPathComponent("wp-flow-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        WaypointCache.wipeAll()
        WaypointCache.directory = savedCacheDir
    }

    private func open(role: String = "member", coLeader: Bool = false) -> (OutingSession, OutingFeaturesModel) {
        var env = SessionEnv()
        env.makeSocket = { [unowned self] url in let s = FakeSocket(url: url); self.sockets.append(s); return s }
        env.scheduler = FakeScheduler()
        env.isForeground = { true }
        env.defaults = UserDefaults(suiteName: "wp-flow-\(UUID().uuidString)")!
        env.timers = false
        env.authorizationOverride = true
        let s = OutingSession(id: "o1", myUserId: "u1", api: OutingsAPI(tokenProvider: { "t" }), token: String(repeating: "t", count: 43), location: LocationSharer(), env: env)
        s.open()
        keep.append(s)
        sockets.last!.serverSays(["type": "ready", "snapshot": [
            "outing": ["id": "o1", "name": "طلعة الاختبار", "status": "active", "owner_id": "u0"],
            "me": ["user_id": "u1", "role": role, "sharing": true, "co_leader": coLeader],
            "members": [
                ["user_id": "u0", "display_name": "أبو فهد", "role": "owner", "sharing": true, "joined_at": "2026-11-03T10:00:00.000Z"],
                ["user_id": "u1", "display_name": "أنا", "role": role, "sharing": true, "joined_at": "2026-11-03T10:01:00.000Z", "co_leader": coLeader],
            ],
            "positions": [], "server_now": ISODate.string(Date()),
        ]])
        return (s, OutingFeaturesModel(session: s, backend: backend))
    }

    private func wp(_ id: String, by user: String) -> Waypoint {
        Waypoint(id: id, outing_id: "o1", user_id: user, kind: .danger, title: "نزلة", note: nil, lat: 24.7, lng: 46.7, photo: nil, created_at: ISODate.string(Date()))
    }

    func testListThenLiveAddAndRemoveThenOfflineReadsTheCache() async {
        backend.list = [wp("a", by: "u0")]
        let (s1, f) = open(); _ = s1
        var alerts: [LiveAlertUI] = []
        f.pushAlert = { a, _ in alerts.append(a) }
        await f.reload()
        XCTAssertEqual(f.phase, .loaded)
        XCTAssertEqual(f.waypoints.map(\.id), ["a"])
        XCTAssertEqual(f.creatorName(f.waypoints[0]), "أبو فهد")
        /* A friend adds one: it arrives over the socket. */
        sockets[0].serverSays(["type": "waypoint_added", "waypoint": ["id": "b", "user_id": "u0", "kind": "water", "title": "بئر", "lat": 24.71, "lng": 46.71, "created_at": ISODate.string(Date())]])
        XCTAssertEqual(Set(f.waypoints.map(\.id)), ["a", "b"])
        XCTAssertTrue(alerts.contains { $0.id == "waypoint:b" }, "a friend's new point is announced in the lane")
        sockets[0].serverSays(["type": "waypoint_removed", "id": "a"])
        XCTAssertEqual(f.waypoints.map(\.id), ["b"])
        /* Now the network is gone: the next open still reads the last list. */
        backend.failWith = OutingAPIError(code: "network", status: 0)
        let (s2, again) = open(); _ = s2
        again.start()
        XCTAssertEqual(again.waypoints.map(\.id), ["b"], "shown from the cache at once")
        await again.reload()
        guard case .cached = again.phase else { return XCTFail("\(again.phase)") }
        XCTAssertEqual(again.waypoints.map(\.id), ["b"])
    }

    func testAddValidatesThenPostsAndShowsAtOnce() async {
        let (s1, f) = open(); _ = s1
        await f.reload()
        f.compose(at: LngLat(lng: 46.7, lat: 24.7))
        let r1 = await f.add(WaypointDraft(kind: .camp, title: "   ", note: nil, lat: 24.7, lng: 46.7, photo: nil))
        XCTAssertFalse(r1)
        XCTAssertEqual(f.composeError, WaypointRules.Problem.titleMissing.arabic)
        XCTAssertTrue(backend.posted.isEmpty, "nothing the server would refuse is sent")
        let r2 = await f.add(WaypointDraft(kind: .stuck_spot, title: " رمل  ناعم ", note: "نزّل الهواء", lat: 24.7, lng: 46.7, photo: nil))
        XCTAssertTrue(r2)
        XCTAssertEqual(backend.posted.first?.title, "رمل ناعم")
        XCTAssertEqual(f.waypoints.first?.kind, .stuck_spot)
        XCTAssertNil(f.modal, "the composer closes")
        /* The server's own echo of my point does not duplicate it. */
        let mine = f.waypoints[0]
        sockets[0].serverSays(["type": "waypoint_added", "waypoint": ["id": mine.id, "user_id": "u1", "kind": "stuck_spot", "title": mine.title, "lat": 24.7, "lng": 46.7, "created_at": mine.created_at]])
        XCTAssertEqual(f.waypoints.count, 1)
    }

    /// The server branch is not deployed yet: Express answers a bare 404.
    func testNotDeployedSaysSoHonestly() async {
        backend.failWith = OutingAPIError(code: "http_404", status: 404)
        let (s1, f) = open(); _ = s1
        await f.reload()
        XCTAssertEqual(f.phase, .notDeployed)
        let r3 = await f.add(WaypointDraft(kind: .camp, title: "مخيم", note: nil, lat: 24.7, lng: 46.7, photo: nil))
        XCTAssertFalse(r3)
        XCTAssertEqual(f.composeError, FeatureAvailability.notDeployedText)
        XCTAssertTrue(FeatureAvailability.notDeployedText.hasPrefix("غير متاح بعد"))
        let r4 = await f.saveConvoy(ConvoyInfo(lead_user_id: "u0", tail_user_id: "u1", max_gap_m: 500))
        XCTAssertFalse(r4)
        XCTAssertEqual(f.convoyError, FeatureAvailability.notDeployedText)
        /* A real 404 with the server's own code is not "not deployed". */
        XCTAssertFalse(FeatureAvailability.notDeployed(OutingAPIError(code: "not_a_member", status: 404)))
        XCTAssertTrue(FeatureAvailability.notDeployed(OutingAPIError(code: "http_405", status: 405)))
    }

    func testDeleteRights() async {
        backend.list = [wp("mine", by: "u1"), wp("theirs", by: "u0")]
        let (s1, f) = open(); _ = s1
        await f.reload()
        XCTAssertTrue(f.canDelete(f.waypoints.first { $0.id == "mine" }!))
        XCTAssertFalse(f.canDelete(f.waypoints.first { $0.id == "theirs" }!), "a member cannot delete a friend's point")
        let (s3, lead) = open(coLeader: true); _ = s3
        await lead.reload()
        XCTAssertTrue(lead.canDelete(lead.waypoints.first { $0.id == "theirs" }!), "«نائب الأمير» can")
        let r5 = await lead.delete("theirs")
        XCTAssertTrue(r5)
        XCTAssertEqual(backend.deleted, ["theirs"])
        XCTAssertFalse(lead.waypoints.contains { $0.id == "theirs" })
    }

    func testConvoySaveAppliesAndEventUpdatesBadges() async {
        let (s, f) = open(role: "owner")
        let r6 = await f.saveConvoy(ConvoyInfo(lead_user_id: "u0", tail_user_id: "u1", max_gap_m: 800))
        XCTAssertTrue(r6)
        XCTAssertEqual(backend.convoys.count, 1)
        XCTAssertEqual(s.view?.convoy?.lead_user_id, "u0")
        XCTAssertEqual(f.convoyRole("u0"), .lead)
        XCTAssertEqual(f.convoyRole("u1"), .tail)
        /* Another leader turned it off. */
        sockets[0].serverSays(["type": "convoy_updated", "convoy": NSNull()])
        XCTAssertNil(f.convoyRole("u0"))
        let r7 = await f.saveConvoy(.off)
        XCTAssertTrue(r7)
        let body = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(backend.convoys.last!)) as? [String: Any]
        XCTAssertTrue(body?["lead_user_id"] is NSNull)
    }

    func testConvoyAlertsReachTheLaneOnceWithOneHaptic() {
        let (s, f) = open(role: "owner")
        s.applyLocal(.convoy(ConvoyInfo(lead_user_id: "u0", tail_user_id: "u1", max_gap_m: 500)))
        var alerts: [LiveAlertUI] = []
        var buzz = 0
        f.pushAlert = { a, _ in alerts.append(a) }
        f.haptic = { buzz += 1 }
        let now = Date()
        func member(_ id: String, _ lat: Double, live: Bool = true) -> MapMember {
            MapMember(id: id, position: LngLat(lng: 46.70, lat: lat), color: 0xFFFFFF, name: id, presence: live ? .live : .recent,
                      heading: id == "u0" ? 0 : nil, accuracyM: 5, atMs: now.timeIntervalSince1970 * 1000, note: nil, isMe: id == "u1")
        }
        /* Lead north, me (tail) 300 m south, a third car 1.2 km behind me. */
        let cars = [member("u0", 24.70), member("u1", 24.6973), member("x", 24.6865)]
        f.evaluateConvoy(members: cars, now: now)
        f.evaluateConvoy(members: cars, now: now.addingTimeInterval(4))
        XCTAssertEqual(alerts.map(\.id), ["convoy:behind:x"])
        XCTAssertEqual(buzz, 1)
        guard case let .convoy(c) = alerts[0].kind else { return XCTFail() }
        XCTAssertEqual(c.kind, .behindTail)
        XCTAssertTrue(c.title.contains("متأخر عن المؤخرة"))
        /* The same car, its fix now old: no new alert, and the sheet status no longer counts it. */
        f.evaluateConvoy(members: [cars[0], cars[1], member("x", 24.6865, live: false)], now: now.addingTimeInterval(8))
        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(f.convoyCheck?.alerts.count, 0)
    }
}
