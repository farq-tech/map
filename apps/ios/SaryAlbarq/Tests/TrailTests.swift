import XCTest
@testable import SaryAlbarq

/// «مساري»: noise filter, simplification, gaps, distance along the trail,
/// off-track, persistence — and the owner's rule that the trail never leaves the phone.
/// Fixes on a local metre grid around 24.7 N, 46.6 E.
struct TFix {
    let t0 = 1_800_000_000_000.0
    /// ~1 m of latitude.
    let dLat = 1.0 / 111_195

    func fix(_ northM: Double, _ eastM: Double = 0, t: Double, acc: Double = 5) -> DeviceFix {
        let lat = 24.7 + northM * dLat
        let lng = 46.6 + eastM * dLat / cos(24.7 * .pi / 180)
        return DeviceFix(lat: lat, lng: lng, accuracy: acc, heading: nil, speed: nil, atMs: t0 + t * 1000)
    }
}

final class TrailFilterTests: XCTestCase {
    let f = TFix()
    var dLat: Double { f.dLat }
    func fix(_ n: Double, _ e: Double = 0, t: Double, acc: Double = 5) -> DeviceFix { f.fix(n, e, t: t, acc: acc) }

    func testAccuracyGateMinStepAndOrder() {
        var tr = Trail()
        XCTAssertTrue(tr.add(fix(0, t: 0)))
        XCTAssertFalse(tr.add(fix(50, t: 5, acc: 80)), "a poor fix is not a trail point")
        XCTAssertFalse(tr.add(fix(6, t: 10)), "under 10 m is jitter")
        XCTAssertTrue(tr.add(fix(12, t: 12)))
        XCTAssertFalse(tr.add(fix(40, t: 11)), "older than the last point")
        XCTAssertFalse(tr.add(fix(40, t: 12)), "same time")
        XCTAssertEqual(tr.points.count, 2)
        XCTAssertFalse(tr.points.contains(where: \.gap))
    }

    func testSingleJumpIsRejectedButAConfirmedMoveIsKept() {
        var tr = Trail()
        tr.add(fix(0, t: 0))
        tr.add(fix(20, t: 2))
        XCTAssertFalse(tr.add(fix(2000, t: 4)), "2 km in 2 s is a GPS jump")
        XCTAssertTrue(tr.add(fix(40, t: 6)), "the real track continues; the jump is forgotten")
        XCTAssertEqual(tr.points.count, 3)
        XCTAssertLessThan(tr.points.map(\.lat).max()!, 24.7 + 100 * dLat)

        /* The last kept point was the bad one: three fixes that agree with each other win. */
        var tr2 = Trail()
        tr2.add(fix(0, t: 0))
        XCTAssertFalse(tr2.add(fix(5000, t: 3)))
        XCTAssertFalse(tr2.add(fix(5020, t: 4)))
        XCTAssertTrue(tr2.add(fix(5040, t: 5)))
        XCTAssertTrue(tr2.points[1].gap, "the jump itself is drawn as an unrecorded stretch, not a path")
        XCTAssertEqual(tr2.points.count, 4)
    }
}

final class TrailGapTests: XCTestCase {
    let f = TFix()

    func testBackgroundGapIsMarkedAndDrawnStraight() {
        var tr = Trail()
        tr.markGap()
        XCTAssertFalse(tr.gapNext, "nothing to be a gap from yet")
        tr.add(f.fix(0, t: 0))
        tr.add(f.fix(100, t: 10))
        tr.markGap()
        /* Back from the background 2 km further on, 20 minutes later. */
        XCTAssertTrue(tr.add(f.fix(2100, t: 1210)))
        tr.add(f.fix(2200, t: 1220))
        XCTAssertEqual(tr.points.map(\.gap), [false, false, true, false])
        let r = tr.runs
        XCTAssertEqual(r.solid.count, 2)
        XCTAssertEqual(r.gaps.count, 1)
        XCTAssertEqual(r.gaps[0].count, 2, "a gap is one straight segment between the last and the next known point")
        XCTAssertEqual(tr.recordedLengthM, 200, accuracy: 2, "the unrecorded 2 km are not counted as driven")
        XCTAssertEqual(tr.gapCount, 1)
    }

    func testGapThenNoMovementAddsNothing() {
        var tr = Trail()
        tr.add(f.fix(0, t: 0))
        tr.markGap()
        XCTAssertFalse(tr.add(f.fix(3, t: 600)), "back where we were: no new point, no gap drawn")
        XCTAssertFalse(tr.gapNext)
        XCTAssertTrue(tr.add(f.fix(30, t: 610)))
        XCTAssertFalse(tr.points[1].gap)
    }

    func testLongSilenceInForegroundIsAGapToo() {
        var tr = Trail()
        tr.add(f.fix(0, t: 0))
        tr.add(f.fix(1500, t: 300))
        XCTAssertTrue(tr.points[1].gap, "5 minutes without fixes and 1.5 km: we did not see that path")
        tr.add(f.fix(1600, t: 310))
        XCTAssertFalse(tr.points[2].gap)
    }
}

final class TrailSimplifyTests: XCTestCase {
    let f = TFix()

    func testDouglasPeuckerDropsNearlyStraightPointsKeepsCorners() {
        var pts: [TrailPoint] = []
        for i in 0...50 {
            let wob = i % 2 == 0 ? 1.0 : -1.0
            let x = f.fix(Double(i) * 20, wob, t: Double(i))
            pts.append(TrailPoint(lat: x.lat, lng: x.lng, t: x.atMs))
        }
        for i in 1...50 {
            let x = f.fix(1000, Double(i) * 20, t: Double(50 + i))
            pts.append(TrailPoint(lat: x.lat, lng: x.lng, t: x.atMs))
        }
        let s = TrailSimplify.douglasPeucker(pts, toleranceM: 4)
        XCTAssertEqual(s.count, 3, "start, the corner, the end")
        XCTAssertEqual(s.first, pts.first)
        XCTAssertEqual(s.last, pts.last)
        XCTAssertEqual(s[1], pts[50])
    }

    func testSimplifyKeepsBothEndsOfEveryGap() {
        var tr = Trail()
        for i in 0..<20 { tr.add(f.fix(Double(i) * 15, t: Double(i))) }
        tr.markGap()
        for i in 0..<20 { tr.add(f.fix(3000 + Double(i) * 15, t: 1000 + Double(i))) }
        let s = TrailSimplify.simplify(tr.points, toleranceM: 4)
        XCTAssertEqual(s.count, 4)
        XCTAssertEqual(s.map(\.gap), [false, false, true, false])
        XCTAssertEqual(Trail.runs(s).gaps.count, 1)
    }

    func testRecordingCompactsForStorageButKeepsARawTail() {
        var tr = Trail()
        for i in 0..<600 { tr.add(f.fix(Double(i) * 12, t: Double(i))) }
        XCTAssertLessThan(tr.points.count, 200, "a straight drive is stored as a few points")
        XCTAssertGreaterThanOrEqual(tr.points.count, Trail.rawTail)
        XCTAssertEqual(tr.points.first?.t, f.t0)
        XCTAssertEqual(tr.points.last!.lat, f.fix(599 * 12, t: 0).lat, accuracy: 1e-9)
        XCTAssertEqual(tr.recordedLengthM, 599 * 12, accuracy: 10)
    }
}

final class BackTrackTests: XCTestCase {
    let f = TFix()

    /// 1 km straight north, recorded from the start (south) to me (north).
    func straight() -> Trail {
        var tr = Trail()
        for i in 0...50 { tr.add(f.fix(Double(i) * 20, t: Double(i) * 2)) }
        return tr
    }

    func at(_ n: Double, _ e: Double = 0) -> LngLat {
        let x = f.fix(n, e, t: 0)
        return LngLat(lng: x.lng, lat: x.lat)
    }

    func testDistanceIsAlongTheTrailBackToTheStart() {
        var bt = BackTrack(straight())!
        XCTAssertEqual(bt.totalM, 1000, accuracy: 2)
        let s = bt.update(at(1000))
        XCTAssertEqual(s.remainingM, 1000, accuracy: 2)
        XCTAssertFalse(s.offTrack)
        XCTAssertEqual(s.bearing, 180, accuracy: 2, "back = south, along the trail")
        let mid = bt.update(at(600, 30))
        XCTAssertEqual(mid.alongM, 600, accuracy: 2)
        XCTAssertEqual(mid.offsetM, 30, accuracy: 1)
        XCTAssertEqual(mid.remainingM, 630, accuracy: 3)
        XCTAssertFalse(mid.offTrack, "30 m beside my trail is still on it")
    }

    func testAlongALoopIsLongerThanStraightLine() {
        /* Out east 500 m, then north 500 m, then back west 500 m: start is 500 m away in a straight line. */
        var tr = Trail()
        var t = 0.0
        for i in 0...25 { tr.add(f.fix(0, Double(i) * 20, t: t)); t += 2 }
        for i in 1...25 { tr.add(f.fix(Double(i) * 20, 500, t: t)); t += 2 }
        for i in 1...25 { tr.add(f.fix(500, 500 - Double(i) * 20, t: t)); t += 2 }
        var bt = BackTrack(tr)!
        let s = bt.update(at(500, 0))
        XCTAssertEqual(s.remainingM, 1500, accuracy: 5, "the way I came, not the crow's line")
    }

    func testOffTrackAfterSixtyMetresWithHysteresis() {
        var bt = BackTrack(straight())!
        XCTAssertFalse(bt.update(at(800, 55)).offTrack)
        let off = bt.update(at(800, 75))
        XCTAssertTrue(off.offTrack)
        XCTAssertEqual(off.bearing, 270, accuracy: 3, "the arrow points back to the trail (west)")
        XCTAssertTrue(bt.update(at(800, 50)).offTrack, "no flicker at the edge")
        XCTAssertFalse(bt.update(at(800, 35)).offTrack)
    }

    func testAutoAdvancesAsIRetraceAndArrives() {
        var bt = BackTrack(straight())!
        var last = Double.infinity
        for n in stride(from: 1000.0, through: 0, by: -50) {
            let s = bt.update(at(n, 5))
            XCTAssertLessThanOrEqual(s.remainingM, last + 0.5)
            last = s.remainingM
        }
        let end = bt.update(at(10))
        XCTAssertTrue(end.arrived)
        XCTAssertEqual(end.remainingM, 0)
        /* Progress does not jump back to the far end of the trail when I pass near it again. */
        XCTAssertLessThanOrEqual(bt.cursor, 2)
    }

    func testFrozenCopyIgnoresTheReturnTrip() {
        var tr = straight()
        let bt = BackTrack(tr)!
        tr.add(f.fix(980, 15, t: 200))
        XCTAssertEqual(bt.path.count, 51, "points recorded on the way back do not move the target")
    }

    func testOnGapIsSaidHonestly() {
        var tr = Trail()
        tr.add(f.fix(0, t: 0))
        tr.add(f.fix(100, t: 10))
        tr.markGap()
        tr.add(f.fix(2000, t: 900))
        tr.add(f.fix(2100, t: 910))
        var bt = BackTrack(tr)!
        XCTAssertTrue(bt.update(at(1000)).onGap)
        XCTAssertFalse(bt.update(at(50)).onGap)
        XCTAssertNil(BackTrack(Trail()), "no trail, no back-track")
    }
}

final class FriendTrailsTests: XCTestCase {
    let f = TFix()

    func testKeepsThirtyMinutesFiltersAndForgetsLeavers() {
        var ft = FriendTrails()
        for i in 0..<60 {
            let x = f.fix(Double(i) * 30, t: Double(i) * 60)
            ft.ingest("a", lat: x.lat, lng: x.lng, atMs: x.atMs, accuracy: 8)
        }
        let poor = f.fix(9000, t: 3700)
        ft.ingest("a", lat: poor.lat, lng: poor.lng, atMs: poor.atMs, accuracy: 200)
        ft.ingest("b", lat: 24.7, lng: 46.6, atMs: f.t0, accuracy: 5)
        ft.prune(nowMs: f.t0 + 59 * 60_000, keep: ["a"])
        let a = ft.byId["a"]!
        XCTAssertEqual(a.count, 31, "the last 30 minutes only")
        XCTAssertFalse(a[0].gap)
        XCTAssertNil(ft.byId["b"], "a friend no longer on the map has no trail")
    }

    func testLongSilenceBetweenFriendFixesIsAGap() {
        var ft = FriendTrails()
        let a = f.fix(0, t: 0), b = f.fix(500, t: 400)
        ft.ingest("a", lat: a.lat, lng: a.lng, atMs: a.atMs, accuracy: 5)
        ft.ingest("a", lat: b.lat, lng: b.lng, atMs: b.atMs, accuracy: 5)
        XCTAssertTrue(ft.byId["a"]![1].gap)
    }
}

final class TrailStoreTests: XCTestCase {
    var dir: URL!
    override func setUp() { dir = FileManager.default.temporaryDirectory.appendingPathComponent("trail-\(UUID().uuidString)") }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func testRoundTripPerOutingAndForget() {
        let f = TFix()
        var tr = Trail()
        tr.add(f.fix(0, t: 0))
        tr.add(f.fix(50, t: 5))
        tr.markGap()
        tr.add(f.fix(900, t: 500))
        TrailStore.save(tr, outingId: "o-1", in: dir)
        let back = TrailStore.load("o-1", in: dir)!
        XCTAssertEqual(back.points.count, 3)
        XCTAssertEqual(back.points.map(\.gap), [false, false, true])
        XCTAssertEqual(back.points[1].lat, tr.points[1].lat, accuracy: 1e-6)
        XCTAssertNil(TrailStore.load("o-2", in: dir))
        TrailStore.delete("o-1", in: dir)
        XCTAssertNil(TrailStore.load("o-1", in: dir))
        TrailStore.save(tr, outingId: "o-3", in: dir)
        TrailStore.forgetAll(in: dir)
        XCTAssertNil(TrailStore.load("o-3", in: dir))
    }

    func testFileNameCannotEscapeTheFolder() {
        XCTAssertEqual(TrailStore.fileName("../../etc/x"), "etcx.json")
    }
}

/// Counts every HTTP request the app makes while installed.
final class RecordingURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requests: [URLRequest] = []
    override class func canInit(with request: URLRequest) -> Bool {
        requests.append(request)
        return false
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
}

/// The session end to end with a fake socket: trail points are recorded, kept on the
/// device, and never ride any network call; the screen-locked trail stops with the outing.
@MainActor
final class TrailSessionTests: XCTestCase {
    private var sockets: [FakeSocket] = []
    private var defaults: UserDefaults!
    private var foreground = true
    private var location: LocationSharer!
    private var dir: URL!

    override func setUp() async throws {
        sockets = []
        foreground = true
        defaults = UserDefaults(suiteName: "trail-session-\(UUID().uuidString)")
        location = LocationSharer()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("trail-s-\(UUID().uuidString)")
        RecordingURLProtocol.requests = []
        URLProtocol.registerClass(RecordingURLProtocol.self)
    }

    override func tearDown() async throws {
        URLProtocol.unregisterClass(RecordingURLProtocol.self)
        try? FileManager.default.removeItem(at: dir)
    }

    private func session(always: Bool = true) -> OutingSession {
        var env = SessionEnv()
        env.makeSocket = { [unowned self] url in let s = FakeSocket(url: url); self.sockets.append(s); return s }
        env.scheduler = FakeScheduler()
        env.isForeground = { [unowned self] in self.foreground }
        env.defaults = defaults
        env.timers = false
        env.authorizationOverride = true
        env.alwaysOverride = always
        env.trailDirectory = dir
        let s = OutingSession(id: "o1", myUserId: "u1", api: OutingsAPI(tokenProvider: { "t" }), token: String(repeating: "t", count: 43), location: location, env: env)
        s.open()
        return s
    }

    private func serverReady(_ s: FakeSocket, status: String = "active") {
        s.serverSays(["type": "ready", "snapshot": [
            "outing": ["id": "o1", "name": "x", "status": status, "owner_id": "u0"],
            "me": ["user_id": "u1", "role": "member", "sharing": true],
            "members": [["user_id": "u1", "display_name": "أنا", "role": "member", "sharing": true, "joined_at": "2026-11-03T10:00:00.000Z"]],
            "positions": [], "server_now": ISODate.string(Date()),
        ]])
    }

    /// Distinct, recognisable coordinates for trail-only fixes.
    private func trailFix(_ i: Int) -> DeviceFix {
        DeviceFix(lat: 25.123456 + Double(i) * 0.0003, lng: 47.654321, accuracy: 5, heading: nil, speed: 10,
                  atMs: Date().timeIntervalSince1970 * 1000 - 60_000 + Double(i) * 1000)
    }

    private var sentFrames: [[String: Any]] { sockets.flatMap(\.sent) }

    private func anyFrameMentionsTrail() -> Bool {
        for frame in sentFrames {
            let text = String(data: (try? JSONSerialization.data(withJSONObject: frame)) ?? Data(), encoding: .utf8) ?? ""
            if text.contains("25.12") || text.contains("47.654") || text.contains("trail") || text.contains("points") { return true }
        }
        return false
    }

    func testBackgroundTrailPointsNeverReachTheNetwork() {
        /* Consent given once, but not sharing now: the trail alone must never touch the network. */
        ShareMemory.recordConsent(user: "u1", outing: "o1", defaults: defaults)
        let s = session()
        serverReady(sockets[0])
        XCTAssertFalse(s.gate.allowsPosition, "not sharing")
        /* Screen locked: the trail keeps recording (with «دائمًا»); nothing is sent. */
        foreground = false
        s.foreground(false)
        XCTAssertTrue(s.recordingInBackground)
        XCTAssertFalse(s.gate.allowsBackgroundPosition, "no «شارك موقعي»: no background send either")
        let framesBefore = sentFrames.count
        RecordingURLProtocol.requests = []
        for i in 0..<20 { s.trailFix(trailFix(i)) }
        XCTAssertEqual(s.trail.points.count, 20, "the trail recorded every step")
        XCTAssertFalse(s.trail.points.contains(where: \.gap), "with the screen-locked trail there is no gap")
        /* Even a fix that reaches the sharing path is refused in the background. */
        s.handleFix(trailFix(21))
        XCTAssertEqual(sentFrames.dropFirst(framesBefore).filter { $0["type"] as? String == "position" }.count, 0)
        XCTAssertFalse(anyFrameMentionsTrail(), "no frame carries a trail point")
        XCTAssertTrue(RecordingURLProtocol.requests.isEmpty, "no HTTP request at all while recording the trail")
        s.saveTrail()
        XCTAssertEqual(TrailStore.load("o1", in: dir)?.points.count, 20, "kept on this device")
    }

    func testForegroundTrailNeverRidesTheWireEither() {
        ShareMemory.recordConsent(user: "u1", outing: "o1", defaults: defaults)
        ShareMemory.setActiveShare(user: "u1", outing: "o1", defaults: defaults)
        let s = session()
        serverReady(sockets[0])
        s.resumeIfPreviouslySharing()
        RecordingURLProtocol.requests = []
        for i in 0..<15 { s.trailFix(trailFix(i)) }
        XCTAssertEqual(s.trail.points.count, 15)
        XCTAssertFalse(anyFrameMentionsTrail())
        XCTAssertTrue(RecordingURLProtocol.requests.isEmpty)
    }

    func testWithoutAlwaysTheLockedStretchIsAGap() {
        let s = session(always: false)
        serverReady(sockets[0])
        s.trailFix(trailFix(0))
        s.trailFix(trailFix(1))
        foreground = false
        s.foreground(false)
        XCTAssertFalse(s.recordingInBackground)
        s.trailFix(trailFix(5))
        XCTAssertEqual(s.trail.points.count, 2, "nothing is recorded with the screen locked")
        foreground = true
        s.foreground(true)
        s.trailFix(trailFix(9))
        XCTAssertEqual(s.trail.points.map(\.gap), [false, false, true], "the unseen stretch is an honest gap")
    }

    func testBackgroundRecordingStopsWhenTheOutingEnds() {
        let s = session()
        serverReady(sockets[0])
        foreground = false
        s.foreground(false)
        XCTAssertTrue(s.recordingInBackground)
        sockets[0].serverSays(["type": "outing_status", "status": "ended"])
        XCTAssertFalse(s.recordingInBackground, "ended: the screen-locked trail stops at once")
        s.trailFix(trailFix(0))
        XCTAssertTrue(s.trail.isEmpty, "and nothing more is recorded")
    }

    func testBackgroundRecordingStopsOnLeaveSwitchOffAndClose() {
        let s = session()
        serverReady(sockets[0])
        foreground = false
        s.foreground(false)
        XCTAssertTrue(s.recordingInBackground)
        s.setBackgroundTrail(false)
        XCTAssertFalse(s.recordingInBackground, "switch off")
        foreground = true
        s.foreground(true)
        s.setBackgroundTrail(true)
        foreground = false
        s.foreground(false)
        XCTAssertTrue(s.recordingInBackground)
        sockets[0].serverSays(["type": "member_left", "user_id": "u1"])
        XCTAssertFalse(s.recordingInBackground, "left / removed")
        let s2 = session()
        serverReady(sockets[1])
        s2.foreground(false)
        XCTAssertTrue(s2.recordingInBackground)
        s2.close()
        XCTAssertFalse(s2.recordingInBackground, "session closed (sign-out / delete account close it)")
    }

    func testNotRecordedBeforeTheOutingStartsOrWhenSwitchedOff() {
        let s = session()
        serverReady(sockets[0], status: "created")
        s.trailFix(trailFix(0))
        XCTAssertTrue(s.trail.isEmpty)
        let s2 = session()
        serverReady(sockets[1])
        s2.setTrailRecording(false)
        s2.trailFix(trailFix(0))
        XCTAssertTrue(s2.trail.isEmpty)
    }

    func testTrailSurvivesARestartWithAGapAndCanBeCleared() {
        let s = session()
        serverReady(sockets[0])
        for i in 0..<5 { s.trailFix(trailFix(i)) }
        s.close()
        let s2 = session()
        XCTAssertEqual(s2.trail.points.count, 5, "loaded from this device, offline")
        serverReady(sockets[1])
        s2.trailFix(trailFix(30))
        XCTAssertTrue(s2.trail.points.last!.gap, "the time the app was closed is a gap")
        s2.clearTrail()
        XCTAssertTrue(s2.trail.isEmpty)
        XCTAssertNil(TrailStore.load("o1", in: dir))
    }
}
