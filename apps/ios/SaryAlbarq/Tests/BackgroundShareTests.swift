import Combine
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
        XCTAssertEqual(BackgroundCadence.dueAtMs(fix(24.7, speed: 0, at: 1), last: last, lowPower: true), 40_000, "Low Power never sends slower than the «مباشر» window (was 80 s: flicker)")
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
        hints = []; backfills = []; backfillAccepts = true
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

    private var hints: [PresenceHint] = []
    private var backfills: [[WireFix]] = []
    private var backfillAccepts = true

    private func session(always: Bool = true, bgSession: Bool = false, outbox: OutingActionOutbox? = nil) -> OutingSession {
        location.testAuthorization = always ? .authorizedAlways : .authorizedWhenInUse
        var env = SessionEnv()
        env.makeSocket = { [unowned self] url in let s = FakeSocket(url: url); self.sockets.append(s); return s }
        env.scheduler = sched
        env.isForeground = { [unowned self] in self.foreground }
        env.defaults = defaults
        env.timers = false
        env.authorizationOverride = true
        env.alwaysOverride = always
        env.backgroundSessionOverride = bgSession
        env.postHint = { [unowned self] _, h, _ in self.hints.append(h) }
        env.postBackfill = { [unowned self] _, fixes, _ in self.backfills.append(fixes); return self.backfillAccepts }
        env.trailDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("bg-\(UUID().uuidString)")
        env.lowPower = { false }
        env.now = { [unowned self] in self.clock }
        env.keepAlive = { {} }
        env.postPosition = { [unowned self] _, w in
            if let e = self.postError { throw e }
            self.posted.append(w)
        }
        env.outbox = outbox
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
    private func sharingInBackground(always: Bool = true, bgSession: Bool = false, outbox: OutingActionOutbox? = nil) async -> OutingSession {
        ShareMemory.recordConsent(user: "u1", outing: "o1", defaults: defaults)
        ShareMemory.setActiveShare(user: "u1", outing: "o1", defaults: defaults)
        let s = session(always: always, bgSession: bgSession, outbox: outbox)
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

    /// Field 2026-11-06: members on «أثناء الاستخدام» went dark the moment the phone locked. With
    /// the iOS 17+ background activity session (taken on screen) the share keeps going.
    func testWhenInUseWithActivitySessionKeepsSendingOffScreen() async {
        let s = await sharingInBackground(always: false, bgSession: true)
        XCTAssertTrue(s.gate.allowsBackgroundPosition)
        s.handleFix(fix(0))
        await settle()
        XCTAssertEqual(posted.count, 1, "POST /:id/positions with the screen locked")
        XCTAssertEqual(hints.last, .backgroundAlways, "the others are told it keeps going")
    }

    /// Leaving the screen with «أثناء الاستخدام» and no session: the others learn why at once.
    func testLeavingTheScreenTellsTheReason() async {
        _ = await sharingInBackground(always: false)
        await settle()
        XCTAssertEqual(hints.last, .backgroundWhenInUse, "«الموقع «أثناء الاستخدام» بس» instead of a vague «انقطع»")
    }

    /// No network off screen: every fix that cannot go out is queued (thinned) and uploaded in
    /// ONE batch as soon as a send goes through; acked, the queue is empty and persisted so.
    func testOfflineFixesAreQueuedAndBackfilledInOneBatch() async {
        let s = await sharingInBackground()
        postError = OutingAPIError(code: "network", status: 0)
        for i in 0..<6 {
            s.handleFix(fix(i))
            clockOffset += 30_000
            sched.advance(30_000)
            await settle()
        }
        XCTAssertTrue(posted.isEmpty)
        XCTAssertGreaterThanOrEqual(s.offlineQueue.count, 4, "kept on the phone, not dropped")
        XCTAssertFalse(OfflineFixQueue.load(user: "u1", outing: "o1", defaults: defaults).isEmpty, "survives the app being killed")
        postError = nil
        /* The pending retry wakes (its fix is too old by now: dropped, it is already queued)… */
        clockOffset += 120_000
        sched.advance(120_000)
        await settle()
        /* …and the next fresh fix goes out live, then the queue follows in one batch. */
        s.handleFix(fix(11))
        await settle()
        XCTAssertFalse(posted.isEmpty, "live again")
        XCTAssertEqual(backfills.count, 1, "one batch")
        XCTAssertGreaterThanOrEqual(backfills[0].count, 4)
        XCTAssertTrue(zip(backfills[0], backfills[0].dropFirst()).allSatisfy { $0.age_ms >= $1.age_ms }, "oldest first, true ages")
        XCTAssertTrue(s.offlineQueue.isEmpty)
        XCTAssertTrue(OfflineFixQueue.load(user: "u1", outing: "o1", defaults: defaults).isEmpty)
    }

    /// Leaving the trip forgets whatever was queued: nothing goes out after the trip.
    func testLeavingForgetsTheQueue() async {
        let s = await sharingInBackground()
        postError = OutingAPIError(code: "network", status: 0)
        s.handleFix(fix(0))
        await settle()
        s.leave()
        XCTAssertTrue(s.offlineQueue.isEmpty)
        XCTAssertTrue(OfflineFixQueue.load(user: "u1", outing: "o1", defaults: defaults).isEmpty)
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
        s.leave()
        await assertStopped(s, "leave")
        XCTAssertTrue(StubAPIProtocol.requests.contains { $0.path.hasSuffix("/o1/leave") || $0.path.hasSuffix("/o1/me") && $0.method == "DELETE" } || s.closedReason == .left)
    }

    /// #173: a failed «غادر الطلعة» (no network, server error) still stops at once — on this phone
    /// I have left — and the request is retried through the persisted outbox until the server agrees.
    /// (Before #173 the screen waited for the server, and a failure kept me sharing.)
    func testFailedLeaveStillStopsAtOnceAndIsRetried() async {
        let s = await sharingInBackground()
        StubAPIProtocol.failing = ["/leave"]
        defer { StubAPIProtocol.failing = [] }
        XCTAssertTrue(s.leave())
        XCTAssertEqual(s.closedReason, .left, "left on this phone right away")
        XCTAssertFalse(s.wantsToShare, "sharing stops before the server answers")
        await assertStopped(s, "leave while the server fails")
        await waitUntil { (s.outbox.queue.items.first?.attempts ?? 0) >= 1 }
        XCTAssertEqual(s.outbox.queue.items.map(\.kind), [.leave], "kept for another try")
        XCTAssertFalse(PendingActionQueue.load(defaults: defaults).isEmpty, "on disk: survives the app being killed")
        XCTAssertFalse(s.wantsToShare, "a failure never resumes sharing")
        XCTAssertFalse(s.gate.allowsBackgroundPosition)
        StubAPIProtocol.failing = []
        s.outbox.networkBack()
        await waitUntil { s.outbox.queue.isEmpty }
        XCTAssertGreaterThanOrEqual(StubAPIProtocol.requests.filter { $0.method == "POST" && $0.path == "/api/outings/o1/leave" }.count, 2,
                                    "sent again once the network was back")
        XCTAssertTrue(PendingActionQueue.load(defaults: defaults).isEmpty)
        await assertStopped(s, "still stopped after the server agreed")
    }

    // MARK: #173 — instant actions over a slow server

    /// A server that answers after `delay` (2 s: slower than the 0.4–0.6 s measured from a Mac,
    /// like a weak cellular link), failing the first `failuresLeft` requests with "no network".
    @MainActor
    private final class SlowServer {
        var delay: UInt64 = 2_000_000_000
        var failuresLeft = 0
        private(set) var calls = 0
        private(set) var done: [PendingOutingAction] = []

        func perform(_ a: PendingOutingAction) async throws {
            calls += 1
            try await Task.sleep(nanoseconds: delay)
            if failuresLeft > 0 {
                failuresLeft -= 1
                throw OutingAPIError(code: "network", status: 0)
            }
            done.append(a)
        }
    }

    /// An outbox over `server`; backoff waits move the test clock instead of sleeping.
    private func slowOutbox(_ server: SlowServer) -> OutingActionOutbox {
        let o = OutingActionOutbox(deps: .init(
            perform: { a in try await server.perform(a) },
            defaults: defaults,
            now: { [unowned self] in self.clock },
            sleep: { [unowned self] ms in
                self.clockOffset += ms
                await Task.yield()
            }
        ))
        o.currentUser = { "u1" }
        return o
    }

    /// Like `slowOutbox`, but a failed action really waits out its backoff (10 s), so it stays
    /// queued — not back on the wire at once — while the test looks at it. Stop it at the end.
    private func heldOutbox(_ server: SlowServer) -> OutingActionOutbox {
        let o = OutingActionOutbox(deps: .init(
            perform: { a in try await server.perform(a) },
            defaults: defaults,
            now: { [unowned self] in self.clock },
            sleep: { _ in try? await Task.sleep(nanoseconds: 10_000_000_000) }
        ))
        o.currentUser = { "u1" }
        return o
    }

    private func waitUntil(timeout: TimeInterval = 8, _ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let end = Date().addingTimeInterval(timeout)
        while !condition() && Date() < end { try? await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(condition(), "timed out after \(timeout) s", file: file, line: line)
    }

    func testLeaveChangesTheScreenAtOnceAndTheServerHearsLater() async {
        let server = SlowServer()
        let outbox = slowOutbox(server)
        let s = await sharingInBackground(outbox: outbox)
        let tap = Date()
        s.leave()
        XCTAssertLessThan(Date().timeIntervalSince(tap), 0.1, "< 100 ms: nothing waits for the network")
        XCTAssertEqual(s.closedReason, .left)
        XCTAssertFalse(s.wantsToShare)
        XCTAssertFalse(location.isSharing, "my location stops at once")
        XCTAssertNil(ShareMemory.activeShare(user: "u1", defaults: defaults), "no resume after a relaunch")
        XCTAssertEqual(outbox.queue.items.map(\.kind), [.leave])
        XCTAssertTrue(server.done.isEmpty, "the server has not answered yet")
        await assertStopped(s, "left, the server still thinking")
        await waitUntil { !server.done.isEmpty }
        XCTAssertEqual(server.done.map(\.kind), [.leave])
        XCTAssertEqual(server.done.first?.outing, "o1")
        XCTAssertTrue(outbox.queue.isEmpty)
        XCTAssertTrue(PendingActionQueue.load(defaults: defaults).isEmpty)
    }

    // MARK: «إنهاء الطلعة للجميع» is instant too (owner's Build 44 report: «ياخذ وقت، ومرات ما يستجيب»)

    /// The server stalls (answers after 30 s): the screen still shows the ended outing within 100 ms, sharing is stopped on this phone,
    /// and the end waits in the persisted outbox. Before this, `setStatus("end")` awaited the server, so the screen sat on «جاري الإنهاء…».
    func testEndOutingChangesTheScreenAtOnceEvenWhenTheServerStalls() async {
        let server = SlowServer()
        server.delay = 30_000_000_000
        let outbox = heldOutbox(server)
        defer { outbox.stop() }
        let s = await sharingInBackground(outbox: outbox)
        let tap = Date()
        XCTAssertTrue(s.endOuting())
        XCTAssertLessThan(Date().timeIntervalSince(tap), 0.1, "< 100 ms: nothing waits for the network")
        XCTAssertLessThan(s.endLatencyMs ?? 9_999, 100, "end_latency_ms is recorded")
        XCTAssertEqual(s.closedReason, .outingEnded)
        XCTAssertEqual(s.view?.status, .ended)
        XCTAssertFalse(s.wantsToShare)
        XCTAssertFalse(location.isSharing, "my location stops at once")
        XCTAssertNil(ShareMemory.activeShare(user: "u1", defaults: defaults), "no resume after a relaunch")
        XCTAssertEqual(outbox.queue.items.map(\.kind), [.endOuting])
        XCTAssertTrue(server.done.isEmpty, "the server has not answered")
        await assertStopped(s, "ended, the server stalled")
    }

    /// No network at all: the end is kept (on disk too), retried, the first failure is said once, and sharing never comes back.
    func testEndOutingOfflineIsQueuedRetriedAndSaidOnce() async {
        let server = SlowServer()
        server.delay = 20_000_000
        server.failuresLeft = 1
        let outbox = slowOutbox(server)
        var outcomes: [OutingActionOutbox.Outcome] = []
        let sink = outbox.reports.sink { outcomes.append($0.outcome) }
        defer { sink.cancel() }
        let s = await sharingInBackground(outbox: outbox)
        var notices: [String] = []
        s.onDeferredNotice = { notices.append($0) }
        s.endOuting()
        XCTAssertEqual(s.closedReason, .outingEnded, "ended on this phone with no network")
        await waitUntil { outcomes.contains(.willRetry) }
        XCTAssertEqual(notices, ["تعذّر إبلاغ الخادم، نعيد المحاولة"], "said once, without blocking anything")
        XCTAssertFalse(PendingActionQueue.load(defaults: defaults).isEmpty, "survives the app being killed")
        XCTAssertFalse(s.wantsToShare)
        XCTAssertFalse(location.isSharing)
        await waitUntil { outcomes.contains(.sent) }
        XCTAssertEqual(server.done.map(\.kind), [.endOuting])
        XCTAssertTrue(outbox.queue.isEmpty)
        XCTAssertFalse(s.wantsToShare)
    }

    func testAnEndWaitingMakesLaterActionsMootAndSecondEndIsIgnored() async {
        var q = PendingActionQueue()
        let end = PendingOutingAction(user: "u1", outing: "o1", kind: .endOuting, createdMs: 1)
        XCTAssertTrue(q.enqueue(PendingOutingAction(user: "u1", outing: "o1", kind: .note, text: "x", createdMs: 0)))
        XCTAssertTrue(q.enqueue(end))
        XCTAssertEqual(q.items.map(\.kind), [.endOuting], "the note is moot once the outing ends")
        XCTAssertFalse(q.enqueue(PendingOutingAction(user: "u1", outing: "o1", kind: .note, text: "y", createdMs: 2)))
        XCTAssertEqual(PendingActionQueue.maxAgeMs(for: .endOuting), PendingActionQueue.leaveMaxAgeMs, "kept for days, like a leave")
        XCTAssertEqual(PendingActionQueue.verdict(OutingAPIError(code: "outing_ended", status: 409), kind: .endOuting), .done)
        XCTAssertEqual(PendingActionQueue.verdict(OutingAPIError(code: "network", status: 0), kind: .endOuting), .retry)
    }

    func testAFailedLeaveIsQueuedAndRetriedWithoutEverResumingSharing() async {
        let server = SlowServer()
        server.failuresLeft = 1
        let outbox = slowOutbox(server)
        var outcomes: [OutingActionOutbox.Outcome] = []
        let sink = outbox.reports.sink { outcomes.append($0.outcome) }
        defer { sink.cancel() }
        let s = await sharingInBackground(outbox: outbox)
        s.leave()
        await waitUntil { outcomes.contains(.willRetry) }
        XCTAssertEqual(outbox.queue.items.first?.attempts, 1, "queued again with a backoff")
        XCTAssertFalse(PendingActionQueue.load(defaults: defaults).isEmpty, "persisted while it waits")
        XCTAssertFalse(s.wantsToShare, "a failure never resumes sharing")
        XCTAssertFalse(location.isSharing)
        await assertStopped(s, "a failed leave")
        await waitUntil { outcomes.contains(.sent) }
        XCTAssertEqual(server.calls, 2, "tried again and went through")
        XCTAssertTrue(outbox.queue.isEmpty)
        XCTAssertFalse(s.wantsToShare)
    }

    func testAQueuedLeaveSurvivesARestart() async {
        let offline = SlowServer()
        offline.delay = 20_000_000
        offline.failuresLeft = .max
        let before = slowOutbox(offline)
        let s = await sharingInBackground(outbox: before)
        s.leave()
        await waitUntil { (before.queue.items.first?.attempts ?? 0) >= 1 }
        /* The app is killed: the outbox in memory is gone, the disk keeps the leave. */
        before.stop()
        s.close()
        let online = SlowServer()
        online.delay = 20_000_000
        let after = slowOutbox(online)
        XCTAssertEqual(after.queue.items.map(\.kind), [.leave], "read back from disk after the restart")
        XCTAssertEqual(after.queue.items.first?.outing, "o1")
        after.kick()
        await waitUntil { !online.done.isEmpty }
        XCTAssertEqual(online.done.map(\.kind), [.leave])
        XCTAssertTrue(after.queue.isEmpty)
        XCTAssertTrue(PendingActionQueue.load(defaults: defaults).isEmpty)
    }

    func testRallyAndImOKChangeTheScreenAtOnce() async {
        let server = SlowServer()
        let outbox = slowOutbox(server)
        let s = session(outbox: outbox)
        ready(sockets[0])
        let tap = Date()
        let rallied = await s.setRally(lat: 24.7, lng: 46.6, label: "الطعس")
        XCTAssertTrue(rallied)
        XCTAssertEqual(s.view?.snapshot.outing.rally?.lat, 24.7, "the rally is on the map before the server answers")
        await s.cancelSOS()
        XCTAssertLessThan(Date().timeIntervalSince(tap), 0.1)
        XCTAssertNil(s.view?.members["u1"]?.sos)
        XCTAssertEqual(Set(outbox.queue.items.map(\.kind)), [.setRally, .cancelSOS])
        XCTAssertTrue(server.done.isEmpty)
        /* A snapshot from before the server heard must not take the rally off the map. */
        ready(sockets[0])
        XCTAssertEqual(s.view?.snapshot.outing.rally?.lat, 24.7)
        await waitUntil(timeout: 10) { server.done.count == 2 }
        XCTAssertTrue(outbox.queue.isEmpty)
    }

    /// Privacy: a «أخفِ موقعي» on its way keeps the gate closed, even when a snapshot from before
    /// it says "shown", and after it failed; showing again takes back a hide the server never got.
    func testAPendingHideKeepsTheGateClosed() async {
        let server = SlowServer()
        server.delay = 50_000_000
        server.failuresLeft = .max
        /* Flaky under load before (Build 42): with the clock-moving backoff the failed hide was
         * retried at once, so «أظهر» often found it on the wire (can't be taken back) instead of
         * queued. Here it waits out a real backoff, so it is queued when we look. */
        let outbox = heldOutbox(server)
        let s = await sharingInBackground(outbox: outbox)
        foreground = true
        s.foreground(true)
        XCTAssertTrue(s.gate.allowsPosition)
        let hid = await s.setHidden(true)
        XCTAssertTrue(hid)
        XCTAssertFalse(s.gate.allowsPosition, "hidden at once")
        ready(sockets[0])
        XCTAssertEqual(s.view?.me?.hidden, true, "a snapshot from before the hide does not show me again")
        XCTAssertFalse(s.gate.allowsPosition, "a pending hide never resumes sharing")
        await waitUntil { (outbox.queue.items.first?.attempts ?? 0) >= 1 && !outbox.isInFlight(user: "u1", outing: "o1", kind: .hide) }
        XCTAssertFalse(s.gate.allowsPosition, "nor a failed one")
        let shown = await s.setHidden(false)
        XCTAssertTrue(shown)
        XCTAssertTrue(outbox.queue.isEmpty, "the hide is taken back, not sent")
        XCTAssertFalse(StubAPIProtocol.requests.contains { $0.path.hasSuffix("/hidden") }, "nothing to undo on the server")
        outbox.stop()
    }

    /// Safety: a «أنا بخير» that was on the wire when a new SOS went out, and failed, goes back
    /// in the queue to retry; `raiseSOS` takes it back after waiting, so it can't cancel the new SOS.
    func testAFailedInFlightCancelCanBeTakenBackOnceItIsOffTheWire() async {
        let server = SlowServer()
        server.delay = 50_000_000
        server.failuresLeft = 1
        /* A real backoff (not the clock-moving one): the retry must still be waiting when we look. */
        let outbox = heldOutbox(server)
        outbox.enqueue(PendingOutingAction(user: "u1", outing: "o1", kind: .cancelSOS, createdMs: clock))
        await waitUntil { outbox.isInFlight(user: "u1", outing: "o1", kind: .cancelSOS) }
        XCTAssertFalse(outbox.discard(user: "u1", outing: "o1", kind: .cancelSOS), "on the wire: can't be taken back")
        let cleared = await outbox.waitUntilNotInFlight(user: "u1", outing: "o1", kind: .cancelSOS, timeoutMs: 5_000)
        XCTAssertTrue(cleared)
        XCTAssertTrue(outbox.has(user: "u1", outing: "o1", kind: .cancelSOS), "failed, so queued again to retry")
        XCTAssertTrue(outbox.discard(user: "u1", outing: "o1", kind: .cancelSOS), "off the wire: taken back")
        XCTAssertTrue(outbox.queue.isEmpty)
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(server.done.isEmpty, "the retry never cancels the new SOS")
        outbox.stop()
    }

    /// Demo and solo have no server: every action applies on this phone and nothing is queued.
    func testLocalSessionsNeverQueueServerWork() async {
        let server = SlowServer()
        let outbox = slowOutbox(server)
        var env = SessionEnv()
        env.makeSocket = { [unowned self] url in let s = FakeSocket(url: url); self.sockets.append(s); return s }
        env.scheduler = sched
        env.isForeground = { true }
        env.defaults = defaults
        env.timers = false
        env.authorizationOverride = true
        env.alwaysOverride = false
        env.backgroundSessionOverride = false
        env.trailMatching = nil
        env.keepAlive = { {} }
        env.trailDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("local-\(UUID().uuidString)")
        env.outbox = outbox
        location.testAuthorization = .authorizedWhenInUse
        let solo = OutingSession.solo(me: PublicUser(id: "u1", display_name: "أنا"), name: "مشوار", location: location, env: env)
        let demo = OutingSession(id: DemoData.outingId, myUserId: DemoData.meId, api: api(), token: "", location: location,
                                 demo: DemoData.view(me: DemoData.meId), env: env)
        for s in [solo, demo] {
            s.open()
            _ = await s.setRally(lat: 24.7, lng: 46.6, label: nil)
            await s.clearRally()
            await s.cancelSOS()
            _ = await s.setHidden(true)
            _ = await s.sendNote("هلا", deferred: true)
            s.leave()
            XCTAssertEqual(s.closedReason, .left, "\(s.kind): left on this phone")
            s.close()
        }
        XCTAssertTrue(outbox.queue.isEmpty, "nothing queued for a local session")
        XCTAssertTrue(PendingActionQueue.load(defaults: defaults).isEmpty)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(server.calls, 0, "no server work at all")
        XCTAssertTrue(sockets.isEmpty, "no live channel either")
        XCTAssertTrue(StubAPIProtocol.requests.isEmpty)
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

    /// Issue #163: after the outing closed, returning to the app must not re-arm the GPS
    /// (nothing is left to stop it: the status-bar location arrow stayed on).
    func testClosedSessionDoesNotRearmTheGPSOnReturn() async {
        let s = session()
        ready(sockets[0])
        s.foreground(true)
        XCTAssertTrue(location.watching, "on screen: the foreground watch is armed")
        s.close()
        XCTAssertFalse(location.watching, "closing releases the watch")
        foreground = false
        s.foreground(false)
        s.foreground(true)
        XCTAssertFalse(location.watching, "a closed session never re-arms the GPS")
        XCTAssertFalse(location.isSharing)
        XCTAssertNil(location.plan, "no consumer left: the manager is stopped")
    }
}

/// Review findings on #179: an undelivered hide must outlive the 2 h cap, like a leave.
final class PendingActionAgeTests: XCTestCase {
    func testHideAndLeaveKeepForDaysOthersForTwoHours() {
        XCTAssertEqual(PendingActionQueue.maxAgeMs(for: .hide), PendingActionQueue.leaveMaxAgeMs)
        XCTAssertEqual(PendingActionQueue.maxAgeMs(for: .leave), PendingActionQueue.leaveMaxAgeMs)
        XCTAssertEqual(PendingActionQueue.maxAgeMs(for: .setRally), PendingActionQueue.maxAgeMs)
    }

    func testPruneKeepsAnUndeliveredHideAfterThreeHours() {
        var q = PendingActionQueue()
        q.enqueue(PendingOutingAction(user: "u", outing: "o", kind: .hide, createdMs: 0))
        q.enqueue(PendingOutingAction(user: "u", outing: "o2", kind: .note, text: "x", createdMs: 0))
        q.prune(nowMs: 3 * 3_600_000)
        XCTAssertTrue(q.has(user: "u", outing: "o", kind: .hide), "hide still waits: dropping it could share again")
        XCTAssertFalse(q.has(user: "u", outing: "o2", kind: .note), "a note is moot after 2 h")
    }
}
