import CoreLocation
import XCTest
@testable import SaryAlbarq

/// Cadence off screen: faster when moving, slower when parked, after 50 m, Low Power doubles it.
final class BackgroundCadenceTests: XCTestCase {
    private func fix(_ lat: Double, speed: Double?, at: Double) -> DeviceFix {
        DeviceFix(lat: lat, lng: 46.67, accuracy: 8, heading: nil, speed: speed, atMs: at)
    }

    func testMotionTiersAndUnknownSpeedNeverParks() {
        XCTAssertEqual(BackgroundCadence.motion(speedMps: 20), .fast)
        XCTAssertEqual(BackgroundCadence.motion(speedMps: 3), .moving)
        XCTAssertEqual(BackgroundCadence.motion(speedMps: 0.2), .parked)
        XCTAssertEqual(BackgroundCadence.motion(speedMps: nil), .moving, "unknown speed is never treated as parked")
        XCTAssertEqual(BackgroundCadence.accuracy(.fast).desiredAccuracy, kCLLocationAccuracyBest)
        XCTAssertEqual(BackgroundCadence.accuracy(.parked).desiredAccuracy, kCLLocationAccuracyHundredMeters, "reduced when parked")
    }

    func testIntervalsAndDistance() {
        let last = BackgroundCadence.Last(fix: fix(24.7, speed: 0, at: 0), sentAtMs: 0)
        XCTAssertEqual(BackgroundCadence.dueAtMs(fix(24.7, speed: 20, at: 1), last: last, lowPower: false), 10_000)
        XCTAssertEqual(BackgroundCadence.dueAtMs(fix(24.7, speed: 0, at: 1), last: last, lowPower: false), 40_000, "parked: inside the 45 s live window")
        XCTAssertEqual(BackgroundCadence.dueAtMs(fix(24.7, speed: 0, at: 1), last: last, lowPower: true), 80_000, "Low Power doubles it")
        /* ~111 m away: due after the 5 s floor. */
        XCTAssertEqual(BackgroundCadence.dueAtMs(fix(24.701, speed: 20, at: 1), last: last, lowPower: false), 5_000)
        XCTAssertEqual(BackgroundCadence.dueAtMs(fix(24.7, speed: 0, at: 1), last: nil, lowPower: false), -.infinity, "first fix goes now")
    }

    func testWorstCaseStaysUnderTheServerLimits() {
        /* routes/outings.js: 120 writes/min/person; service.js: ≥1 s between fixes. */
        let perMinute = 60_000 / BackgroundCadence.distanceFloorMs
        XCTAssertLessThanOrEqual(perMinute, 12)
        XCTAssertGreaterThan(BackgroundCadence.distanceFloorMs, 1_000)
    }

    func testRetryBackoffIsCappedAndRespects429() {
        XCTAssertEqual(BackgroundCadence.retryDelayMs(attempt: 0, rateLimited: false, rand: 0.5), 2_000)
        XCTAssertEqual(BackgroundCadence.retryDelayMs(attempt: 3, rateLimited: false, rand: 0.5), 16_000)
        XCTAssertEqual(BackgroundCadence.retryDelayMs(attempt: 20, rateLimited: false, rand: 0.5), 60_000, "capped")
        XCTAssertGreaterThanOrEqual(BackgroundCadence.retryDelayMs(attempt: 0, rateLimited: true, rand: 0), 30_000)
    }
}

/// The HTTP sender on its own: coalescing, no stale backlog, retry, refusals, stop.
@MainActor
final class BackgroundPositionSenderTests: XCTestCase {
    private var sched: FakeScheduler!
    private var now = 1_700_000_000_000.0
    private var posted: [WireFix] = []
    private var fail: [OutingAPIError] = []
    private var gateOpen = true
    private var results: [BackgroundPositionSender.Outcome] = []

    override func setUp() async throws {
        sched = FakeScheduler()
        posted = []; fail = []; results = []; gateOpen = true
        now = 1_700_000_000_000
    }

    private func sender() -> BackgroundPositionSender {
        let s = BackgroundPositionSender(deps: .init(
            post: { [unowned self] w in
                if !self.fail.isEmpty { throw self.fail.removeFirst() }
                self.posted.append(w)
            },
            scheduler: sched,
            canSend: { [unowned self] in self.gateOpen },
            now: { [unowned self] in self.now },
            lowPower: { false },
            random: { 0.5 },
            keepAlive: { {} }
        ))
        s.onResult = { [unowned self] in self.results.append($0) }
        s.start()
        return s
    }

    private func fix(_ i: Int, ageMs: Double = 200, speed: Double = 20) -> DeviceFix {
        DeviceFix(lat: 24.7 + Double(i) * 0.00001, lng: 46.67, accuracy: 6, heading: nil, speed: speed, atMs: now - ageMs)
    }

    private func settle() async { for _ in 0..<10 { await Task.yield() } }

    private func advance(_ ms: Double) async {
        now += ms
        sched.advance(ms)
        await settle()
    }

    func testFirstFixGoesAtOnceThenOnlyTheLatestAfterTheInterval() async {
        let s = sender()
        s.offer(fix(0), mode: .balanced)
        await settle()
        XCTAssertEqual(posted.count, 1)
        /* Nine more fixes within 9 s (a metre apart): coalesced into one pending slot. */
        for i in 1...9 {
            await advance(1_000)
            s.offer(fix(i), mode: .balanced)
        }
        XCTAssertEqual(posted.count, 1, "not yet: 10 s while driving")
        await advance(1_500)
        XCTAssertEqual(posted.count, 2)
        XCTAssertEqual(posted.last?.lat ?? 0, fix(9).lat, accuracy: 1e-9, "only the latest fix is sent")
    }

    func testStaleFixIsDroppedNeverSentLate() async {
        let s = sender()
        s.offer(fix(0, ageMs: 56_000), mode: .balanced)
        await settle()
        XCTAssertTrue(posted.isEmpty, "older than 55 s: history, not live")
        XCTAssertFalse(s.hasPending)
    }

    func testOfflineKeepsOnlyTheLatestAndItsRealAge() async {
        let s = sender()
        fail = [OutingAPIError(code: "network", status: 0)]
        s.offer(fix(0), mode: .balanced)
        await settle()
        XCTAssertTrue(posted.isEmpty)
        XCTAssertTrue(s.hasPending, "kept for when the network is back")
        /* While offline, newer fixes replace the pending one. */
        await advance(500)
        s.offer(fix(1), mode: .balanced)
        await advance(1_000)
        s.offer(fix(2), mode: .balanced)
        s.networkBack()
        await settle()
        XCTAssertEqual(posted.count, 1, "one position, not a backlog")
        XCTAssertEqual(posted[0].lat, fix(2).lat, accuracy: 1e-9)
        XCTAssertEqual(posted[0].age_ms, 200, accuracy: 1, "age is the fix's real age at send time")
    }

    func testOfflineTooLongSendsNothingOld() async {
        let s = sender()
        fail = Array(repeating: OutingAPIError(code: "network", status: 0), count: 10)
        s.offer(fix(0), mode: .balanced)
        await settle()
        await advance(70_000)
        fail = []
        s.networkBack()
        await settle()
        XCTAssertTrue(posted.isEmpty, "the only fix is now 70 s old: dropped")
    }

    func testRetryBacksOffAndSucceeds() async {
        let s = sender()
        fail = [OutingAPIError(code: "server_busy", status: 503)]
        s.offer(fix(0, ageMs: 0), mode: .balanced)
        await settle()
        XCTAssertTrue(posted.isEmpty)
        XCTAssertEqual(sched.pendingDelays.first ?? 0, 2_000, accuracy: 1)
        await advance(2_000)
        XCTAssertEqual(posted.count, 1)
    }

    func testRefusalStopsRetryingAndReports() async {
        let s = sender()
        fail = [OutingAPIError(code: "sharing_off", status: 409)]
        s.offer(fix(0), mode: .balanced)
        await settle()
        XCTAssertEqual(results, [.refused("sharing_off")])
        XCTAssertFalse(s.hasPending)
        XCTAssertTrue(sched.pendingDelays.isEmpty, "no retry")
    }

    func testNotAMemberStops() async {
        let s = sender()
        fail = [OutingAPIError(code: "not_a_member", status: 404)]
        s.offer(fix(0), mode: .balanced)
        await settle()
        XCTAssertEqual(results, [.notAMember])
        XCTAssertFalse(s.running)
    }

    func testStopAndClosedGateSendNothing() async {
        let s = sender()
        s.offer(fix(0), mode: .balanced)
        await settle()
        s.offer(fix(1), mode: .balanced)
        s.stop()
        await advance(60_000)
        s.offer(fix(2), mode: .balanced)
        await advance(60_000)
        XCTAssertEqual(posted.count, 1, "nothing after stop")
        s.start()
        gateOpen = false
        s.offer(fix(3), mode: .balanced)
        await advance(60_000)
        XCTAssertEqual(posted.count, 1, "the gate is asked at the last step")
    }
}

/// Answers the app's REST calls in tests and records them (no real network).
final class StubAPIProtocol: URLProtocol {
    nonisolated(unsafe) static var requests: [(method: String, path: String, body: [String: Any])] = []
    nonisolated(unsafe) static var snapshot: [String: Any] = [:]
    /// Paths (suffix) answered with HTTP 503, e.g. "/leave" to test a failed «غادر الطلعة».
    nonisolated(unsafe) static var failing: Set<String> = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body: [String: Any] = [:]
        if let s = request.httpBodyStream {
            s.open()
            var d = Data()
            var buf = [UInt8](repeating: 0, count: 4096)
            while s.hasBytesAvailable { let n = s.read(&buf, maxLength: buf.count); if n <= 0 { break }; d.append(buf, count: n) }
            s.close()
            body = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:]
        } else if let d = request.httpBody {
            body = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:]
        }
        let path = request.url?.path ?? ""
        let method = request.httpMethod ?? "GET"
        Self.requests.append((method, path, body))
        var out: [String: Any] = ["ok": true]
        if path.hasSuffix("/live") { out = Self.snapshot }
        if method == "PATCH" { out["sharing"] = (body["sharing"] as? Bool) ?? false }
        let fail = Self.failing.contains { path.hasSuffix($0) }
        if fail { out = ["error": "unavailable"] }
        let data = try! JSONSerialization.data(withJSONObject: out)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: fail ? 503 : 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// The whole session with «دائمًا»: sharing keeps going off screen over HTTP, only the
/// latest fix, and every stop condition stops it at once and sends the stop signal.
@MainActor
final class BackgroundSessionTests: XCTestCase {
    private var sockets: [FakeSocket] = []
    private var defaults: UserDefaults!
    private var foreground = true
    private var location: LocationSharer!
    private var posted: [WireFix] = []
    private var postError: OutingAPIError?
    private var sched: FakeScheduler!
    private var clockOffset = 0.0
    private var clock: Double { Date().timeIntervalSince1970 * 1000 + clockOffset }

    override func setUp() async throws {
        sockets = []
        posted = []
        postError = nil
        clockOffset = 0
        foreground = true
        sched = FakeScheduler()
        defaults = UserDefaults(suiteName: "bg-share-\(UUID().uuidString)")
        location = LocationSharer()
        location.ignoresSystemFixes = true
        StubAPIProtocol.requests = []
        StubAPIProtocol.snapshot = Self.snapshotJSON()
    }

    static func snapshotJSON(status: String = "active", sharing: Bool = true) -> [String: Any] {
        [
            "outing": ["id": "o1", "name": "x", "status": status, "owner_id": "u0"],
            "me": ["user_id": "u1", "role": "member", "sharing": sharing],
            "members": [["user_id": "u1", "display_name": "أنا", "role": "member", "sharing": sharing, "joined_at": "2026-11-03T10:00:00.000Z"]],
            "positions": [], "server_now": ISODate.string(Date()),
        ]
    }

    private func api() -> OutingsAPI {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubAPIProtocol.self]
        return OutingsAPI(base: URL(string: "http://stub.test")!, session: URLSession(configuration: cfg), tokenProvider: { "t" })
    }

    private func session(always: Bool = true) -> OutingSession {
        location.testAuthorization = always ? .authorizedAlways : .authorizedWhenInUse
        var env = SessionEnv()
        env.makeSocket = { [unowned self] url in let s = FakeSocket(url: url); self.sockets.append(s); return s }
        env.scheduler = sched
        env.isForeground = { [unowned self] in self.foreground }
        env.defaults = defaults
        env.timers = false
        env.authorizationOverride = true
        env.alwaysOverride = always
        env.trailDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("bg-\(UUID().uuidString)")
        env.lowPower = { false }
        env.now = { [unowned self] in self.clock }
        env.keepAlive = { {} }
        env.postPosition = { [unowned self] _, w in
            if let e = self.postError { throw e }
            self.posted.append(w)
        }
        let s = OutingSession(id: "o1", myUserId: "u1", api: api(), token: String(repeating: "t", count: 43), location: location, env: env)
        s.open()
        return s
    }

    private func ready(_ s: FakeSocket) { s.serverSays(["type": "ready", "snapshot": Self.snapshotJSON()]) }

    private func fix(_ i: Int, ageMs: Double = 300) -> DeviceFix {
        DeviceFix(lat: 24.71 + Double(i) * 0.001, lng: 46.67, accuracy: 6, heading: 10, speed: 20,
                  atMs: clock - ageMs)
    }

    private var socketPositions: Int { sockets.flatMap(\.sent).filter { $0["type"] as? String == "position" }.count }

    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 50_000_000)
        for _ in 0..<20 { await Task.yield() }
    }

    /// Consent + «شارك موقعي» on screen, then the screen locks.
    private func sharingInBackground(always: Bool = true) async -> OutingSession {
        ShareMemory.recordConsent(user: "u1", outing: "o1", defaults: defaults)
        ShareMemory.setActiveShare(user: "u1", outing: "o1", defaults: defaults)
        let s = session(always: always)
        ready(sockets[0])
        s.resumeIfPreviouslySharing()
        XCTAssertTrue(s.isSharingNow, "sharing on screen")
        foreground = false
        s.foreground(false)
        return s
    }

    func testWithAlwaysPositionsKeepGoingOverHTTPNotTheSocket() async {
        let s = await sharingInBackground()
        XCTAssertTrue(s.gate.allowsBackgroundPosition)
        XCTAssertTrue(location.isSharing, "the GPS keeps running for sharing")
        XCTAssertTrue(location.backgroundShare, "armed for the background (indicator, activity session, backstops)")
        let before = socketPositions
        s.handleFix(fix(0))
        await settle()
        XCTAssertEqual(posted.count, 1, "POST /:id/positions")
        XCTAssertEqual(socketPositions, before, "never the (suspended) socket off screen")
    }

    func testOnlyTheLatestFixAndNoStaleBacklog() async {
        let s = await sharingInBackground()
        s.handleFix(fix(0))
        await settle()
        for i in 1...6 { s.handleFix(fix(i)) }
        XCTAssertEqual(posted.count, 1, "within the 5 s floor: held, coalesced")
        clockOffset += 5_000
        sched.advance(5_000)
        await settle()
        XCTAssertEqual(posted.count, 2)
        XCTAssertEqual(posted[1].lat, fix(6).lat, accuracy: 1e-9, "the latest one, not the six in between")
        clockOffset += 60_000
        s.handleFix(fix(7, ageMs: 58_000))
        sched.advance(60_000)
        await settle()
        XCTAssertEqual(posted.count, 2, "a 58 s old fix is never sent as live")
    }

    func testWhenInUseOnlySendsNothingOffScreen() async {
        let s = await sharingInBackground(always: false)
        XCTAssertFalse(s.gate.allowsPosition)
        XCTAssertFalse(location.isSharing, "GPS for sharing stops off screen")
        XCTAssertFalse(location.backgroundShare)
        s.handleFix(fix(0))
        await settle()
        XCTAssertTrue(posted.isEmpty)
        XCTAssertTrue(s.wantsToShare, "the intent stays; it resumes on screen")
    }

    private func assertStopped(_ s: OutingSession, _ why: String, file: StaticString = #filePath, line: UInt = #line) async {
        XCTAssertFalse(s.gate.allowsBackgroundPosition, why, file: file, line: line)
        XCTAssertFalse(location.backgroundShare, "background updates stop: \(why)", file: file, line: line)
        let n = posted.count
        s.handleFix(fix(50))
        sched.advance(120_000)
        await settle()
        XCTAssertEqual(posted.count, n, "nothing more is sent: \(why)", file: file, line: line)
    }

    func testStopButtonStopsAndSendsTheStopSignal() async {
        let s = await sharingInBackground()
        s.handleFix(fix(0))
        await settle()
        await s.stopSharing()
        await assertStopped(s, "«أوقف المشاركة»")
        XCTAssertTrue(StubAPIProtocol.requests.contains { $0.method == "PATCH" && $0.path == "/api/outings/o1/me" && $0.body["sharing"] as? Bool == false },
                      "the existing stop signal: the server deletes my last fix")
        XCTAssertNil(ShareMemory.activeShare(user: "u1", defaults: defaults), "no resume after a relaunch")
    }

    func testLeaveStops() async {
        let s = await sharingInBackground()
        _ = await s.leave()
        await assertStopped(s, "leave")
        XCTAssertTrue(StubAPIProtocol.requests.contains { $0.path.hasSuffix("/o1/leave") || $0.path.hasSuffix("/o1/me") && $0.method == "DELETE" } || s.closedReason == .left)
    }

    /// A failed «غادر الطلعة» (no network, server error): still a member, so still sharing.
    func testFailedLeaveKeepsSharingUntilTheServerAgrees() async {
        let s = await sharingInBackground()
        StubAPIProtocol.failing = ["/leave"]
        defer { StubAPIProtocol.failing = [] }
        let ok = await s.leave()
        XCTAssertFalse(ok)
        XCTAssertNil(s.closedReason, "still a member")
        XCTAssertTrue(s.wantsToShare, "sharing is not stopped before the server confirms")
        XCTAssertTrue(s.gate.allowsBackgroundPosition)
        StubAPIProtocol.failing = []
        let ok2 = await s.leave()
        XCTAssertTrue(ok2)
        await assertStopped(s, "leave once the server agreed")
    }

    func testRemovedStops() async {
        let s = await sharingInBackground()
        sockets[0].onClose(4403)
        await assertStopped(s, "removed by the owner")
    }

    func testOutingEndedStops() async {
        let s = await sharingInBackground()
        sockets[0].serverSays(["type": "outing_status", "status": "ended"])
        await assertStopped(s, "outing ended")
    }

    func testOutingPausedStops() async {
        let s = await sharingInBackground()
        sockets[0].serverSays(["type": "outing_status", "status": "paused"])
        await assertStopped(s, "outing paused")
    }

    func testSharingSwitchedOffElsewhereStops() async {
        let s = await sharingInBackground()
        sockets[0].serverSays(["type": "member_sharing", "user_id": "u1", "sharing": false])
        await assertStopped(s, "sharing switched off on the server")
    }

    func testServerRefusalOverHTTPStops() async {
        let s = await sharingInBackground()
        postError = OutingAPIError(code: "outing_ended", status: 409)
        s.handleFix(fix(0))
        await settle()
        postError = nil
        await assertStopped(s, "409 outing_ended from POST /positions")
    }

    func testRemovedOverHTTPStops() async {
        let s = await sharingInBackground()
        postError = OutingAPIError(code: "not_a_member", status: 404)
        s.handleFix(fix(0))
        await settle()
        postError = nil
        XCTAssertEqual(s.closedReason, .notAMember)
        await assertStopped(s, "404 not_a_member from POST /positions")
    }

    func testSignOutOrAccountDeletionClosesTheSession() async {
        let s = await sharingInBackground()
        s.close()
        await assertStopped(s, "session closed (sign out / account deleted)")
    }

    func testAlwaysWithdrawnStops() async {
        let s = await sharingInBackground()
        location.testAuthorization = .authorizedWhenInUse
        location.stopSharing() // what the authorization callback does for the background part
        s.handleFix(fix(1))
        var g = s.gate
        g.alwaysAuthorized = false
        XCTAssertFalse(g.allowsBackgroundPosition, "consent to «دائمًا» withdrawn in Settings")
    }

    func testRelaunchedInBackgroundResumesFromDiskAfterTheSnapshot() async {
        ShareMemory.recordConsent(user: "u1", outing: "o1", defaults: defaults)
        ShareMemory.setActiveShare(user: "u1", outing: "o1", defaults: defaults)
        foreground = false
        let s = session()
        s.resumeIfPreviouslySharing()
        XCTAssertTrue(location.isSharing, "GPS starts at once (keeps the app alive after an iOS relaunch)")
        s.handleFix(fix(0))
        XCTAssertTrue(posted.isEmpty, "nothing before the snapshot confirms the outing")
        await settle()
        XCTAssertTrue(StubAPIProtocol.requests.contains { $0.path == "/api/outings/o1/live" }, "outing fetched over HTTP")
        XCTAssertTrue(s.gate.allowsBackgroundPosition)
        s.handleFix(fix(1))
        await settle()
        XCTAssertEqual(posted.count, 1)
    }

    func testRelaunchDoesNotResumeWhenTheOutingEndedMeanwhile() async {
        StubAPIProtocol.snapshot = Self.snapshotJSON(status: "ended")
        ShareMemory.recordConsent(user: "u1", outing: "o1", defaults: defaults)
        ShareMemory.setActiveShare(user: "u1", outing: "o1", defaults: defaults)
        foreground = false
        let s = session()
        s.resumeIfPreviouslySharing()
        await settle()
        await assertStopped(s, "ended while the app was terminated")
        XCTAssertFalse(location.isSharing)
    }

    func testRelaunchWithoutConsentResumesNothing() async {
        ShareMemory.setActiveShare(user: "u1", outing: "o1", defaults: defaults)
        foreground = false
        let s = session()
        s.resumeIfPreviouslySharing()
        XCTAssertFalse(location.isSharing)
        XCTAssertFalse(s.wantsToShare)
    }
}
