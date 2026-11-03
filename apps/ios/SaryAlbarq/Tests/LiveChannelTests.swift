import XCTest
@testable import SaryAlbarq

final class BackoffTests: XCTestCase {
    func testGrowsCappedAndJittered() {
        XCTAssertEqual(Backoff.delayMs(attempt: 0, rand: 0), 500)
        XCTAssertEqual(Backoff.delayMs(attempt: 3, rand: 1), 8_000)
        XCTAssertEqual(Backoff.delayMs(attempt: 20, rand: 1), 30_000)
        XCTAssertEqual(Backoff.delayMs(attempt: 20, rand: 0), 15_000)
        for a in 0..<10 {
            let d = Backoff.delayMs(attempt: a, rand: 0.5)
            XCTAssertGreaterThan(d, 0, "never zero: a storm of phones must not reconnect in lockstep")
            XCTAssertLessThanOrEqual(d, Backoff.maxMs)
        }
    }

    func testCloseCodes() {
        XCTAssertEqual(LiveCloseReason(code: 4401), .unauthorized)
        XCTAssertEqual(LiveCloseReason(code: 4403), .removed)
        XCTAssertEqual(LiveCloseReason(code: 4404), .notAMember)
        XCTAssertEqual(LiveCloseReason(code: 4409), .replaced)
        XCTAssertEqual(LiveCloseReason(code: 4410), .outingEnded)
        XCTAssertNil(LiveCloseReason(code: 1006))
    }

    func testLatestFixSlotKeepsOnlyNewest() {
        var s = LatestFixSlot()
        s.put(DeviceFix(lat: 24, lng: 46, accuracy: 5, heading: nil, speed: nil, atMs: 1_000), mode: .balanced)
        s.put(DeviceFix(lat: 24.1, lng: 46, accuracy: 5, heading: nil, speed: nil, atMs: 3_000), mode: .balanced)
        s.put(DeviceFix(lat: 24.2, lng: 46, accuracy: 5, heading: nil, speed: nil, atMs: 2_000), mode: .balanced) // late, older
        let w = s.take(nowMs: 4_000)
        XCTAssertEqual(w?.lat, 24.1)
        XCTAssertEqual(w?.age_ms, 1_000)
        XCTAssertNil(s.take(nowMs: 4_000))
    }

    func testLatestFixSlotDropsTooOld() {
        var s = LatestFixSlot()
        s.put(DeviceFix(lat: 24, lng: 46, accuracy: 5, heading: nil, speed: nil, atMs: 0), mode: .balanced)
        XCTAssertNil(s.take(nowMs: 56_000))
    }
}

// MARK: - LiveChannel state machine with a fake socket and clock

final class FakeSocket: LiveSocket {
    var onOpen: () -> Void = {}
    var onMessage: (String) -> Void = { _ in }
    var onClose: (Int) -> Void = { _ in }
    var sent: [[String: Any]] = []
    var connected = false
    var closedWith: Int?
    let url: URL
    init(url: URL) { self.url = url }
    func connect() { connected = true }
    func send(_ text: String) {
        if let d = text.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { sent.append(o) }
    }
    func close(code: Int) { closedWith = code }
    func serverSays(_ obj: [String: Any]) {
        let d = try! JSONSerialization.data(withJSONObject: obj)
        onMessage(String(data: d, encoding: .utf8)!)
    }
}

final class FakeScheduler: Scheduler {
    final class Item: Cancellable {
        var cancelled = false
        let at: Double
        let block: () -> Void
        init(at: Double, block: @escaping () -> Void) { self.at = at; self.block = block }
        func cancel() { cancelled = true }
    }
    var nowMs: Double = 1_000_000
    var items: [Item] = []
    func after(ms: Double, _ block: @escaping () -> Void) -> Cancellable {
        let i = Item(at: nowMs + ms, block: block)
        items.append(i)
        return i
    }
    var pendingDelays: [Double] { items.filter { !$0.cancelled }.map { $0.at - nowMs } }
    func advance(_ ms: Double) {
        nowMs += ms
        while let next = items.filter({ !$0.cancelled && $0.at <= nowMs }).min(by: { $0.at < $1.at }) {
            next.cancelled = true
            next.block()
        }
    }
}

final class LiveChannelTests: XCTestCase {
    var sockets: [FakeSocket] = []
    var clock = FakeScheduler()
    var states: [LiveChannel.State] = []
    var closed: [LiveCloseReason] = []
    var snapshots = 0
    var events: [LiveEvent] = []
    var polls = 0

    private func makeChannel(online: Bool = true) -> LiveChannel {
        sockets = []
        clock = FakeScheduler()
        let ch = LiveChannel(outingId: "o1", token: String(repeating: "t", count: 43), deps: .init(
            makeSocket: { [unowned self] url in let s = FakeSocket(url: url); self.sockets.append(s); return s },
            poll: { [unowned self] _ in self.polls += 1; throw OutingAPIError(code: "network", status: 0) },
            post: { _, _ in },
            beat: { _, _ in },
            scheduler: clock,
            random: { 0.5 },
            online: { online }
        ))
        ch.handlers = .init(
            onSnapshot: { [unowned self] _ in self.snapshots += 1 },
            onEvent: { [unowned self] e in self.events.append(e) },
            onState: { [unowned self] s in self.states.append(s) },
            onClosed: { [unowned self] r in self.closed.append(r) }
        )
        return ch
    }

    private func ready(_ s: FakeSocket) {
        s.serverSays(["type": "ready", "snapshot": Self.snapshotJSON])
    }

    static let snapshotJSON: [String: Any] = [
        "outing": ["id": "o1", "name": "x", "status": "active", "owner_id": "u1"],
        "me": ["user_id": "u1", "role": "owner", "sharing": true],
        "members": [], "positions": [], "invite": NSNull(), "server_now": "2026-11-03T10:00:00.000Z",
    ]

    private func fix(at: Double, lat: Double = 24.7) -> DeviceFix {
        DeviceFix(lat: lat, lng: 46.7, accuracy: 5, heading: nil, speed: 10, atMs: at)
    }

    func testAuthenticatesInFirstFrameNotURL() {
        let ch = makeChannel()
        ch.start()
        let s = sockets[0]
        XCTAssertEqual(s.url.absoluteString, "wss://api-production-ddc84.up.railway.app/api/outings/live")
        XCTAssertNil(s.url.query)
        s.onOpen()
        XCTAssertEqual(s.sent.first?["type"] as? String, "auth")
        XCTAssertEqual(s.sent.first?["outing_id"] as? String, "o1")
        XCTAssertEqual((s.sent.first?["token"] as? String)?.count, 43)
    }

    func testKeepsOnlyLatestFixWhileDisconnectedAndSendsOnReady() {
        let ch = makeChannel()
        ch.start()
        let s = sockets[0]
        s.onOpen()
        ch.sendFix(fix(at: clock.nowMs - 3_000, lat: 24.1), mode: .balanced)
        ch.sendFix(fix(at: clock.nowMs - 1_000, lat: 24.2), mode: .balanced)
        XCTAssertEqual(s.sent.count, 1, "only auth before ready")
        ready(s)
        XCTAssertEqual(ch.state, .live)
        XCTAssertEqual(snapshots, 1)
        let positions = s.sent.filter { $0["type"] as? String == "position" }
        XCTAssertEqual(positions.count, 1)
        let f = positions[0]["fix"] as? [String: Any]
        XCTAssertEqual(f?["lat"] as? Double, 24.2)
        XCTAssertEqual(f?["age_ms"] as? Double, 1_000)
        XCTAssertEqual(f?["mode"] as? String, "balanced")
    }

    func testDropsAFixTooOldToSend() {
        let ch = makeChannel()
        ch.start()
        sockets[0].onOpen()
        ch.sendFix(fix(at: clock.nowMs - 58_000), mode: .balanced)
        ready(sockets[0])
        XCTAssertTrue(sockets[0].sent.filter { $0["type"] as? String == "position" }.isEmpty)
    }

    func testTerminalCloseCodesStopReconnecting() {
        for (code, reason) in [(4401, LiveCloseReason.unauthorized), (4403, .removed), (4404, .notAMember), (4409, .replaced), (4410, .outingEnded)] {
            closed = []
            let ch = makeChannel()
            ch.start()
            sockets[0].onOpen()
            ready(sockets[0])
            sockets[0].onClose(code)
            XCTAssertEqual(closed, [reason])
            XCTAssertEqual(ch.state, .closed)
            clock.advance(120_000)
            XCTAssertEqual(sockets.count, 1, "no reconnect after \(code)")
        }
    }

    func testReconnectsWithBackoffAfterDroppedSocket() {
        let ch = makeChannel()
        ch.start()
        sockets[0].onOpen()
        ready(sockets[0])
        sockets[0].onClose(1006)
        XCTAssertEqual(ch.state, .connecting)
        XCTAssertEqual(clock.pendingDelays.filter { $0 == Backoff.delayMs(attempt: 0, rand: 0.5) }.count, 1)
        clock.advance(Backoff.delayMs(attempt: 0, rand: 0.5))
        XCTAssertEqual(sockets.count, 2)
        sockets[1].onOpen()
        ready(sockets[1])
        XCTAssertEqual(ch.state, .live)
        XCTAssertEqual(snapshots, 2, "the reconnect snapshot restores state")
    }

    func testBackoffGrowsAcrossFailedAttemptsThenPolls() {
        let ch = makeChannel()
        ch.start()
        var waits: [Double] = []
        for i in 0..<3 {
            sockets[i].onClose(1006) // never reached ready
            waits.append(clock.pendingDelays.max() ?? 0)
            clock.advance(waits.last!)
        }
        XCTAssertTrue(waits[0] < waits[1] && waits[1] < waits[2], "\(waits)")
        XCTAssertEqual(ch.state, .polling, "falls back to HTTP after \(Backoff.failsBeforePolling) failures")
        XCTAssertTrue(states.contains(.polling))
        XCTAssertGreaterThanOrEqual(sockets.count, 4, "keeps retrying the socket quietly while polling")
    }

    func testOfflineIsAStateAndReconnectNowIsImmediate() {
        let ch = makeChannel(online: false)
        ch.start()
        XCTAssertEqual(ch.state, .offline)
        XCTAssertTrue(sockets.isEmpty)
        let ch2 = makeChannel()
        ch2.start()
        sockets[0].onClose(1006)
        ch2.reconnectNow()
        XCTAssertEqual(sockets.count, 2, "no wait for the backoff timer")
    }

    func testHalfOpenSocketIsReplacedAfterSilence() {
        let ch = makeChannel()
        ch.start()
        sockets[0].onOpen()
        ready(sockets[0])
        clock.advance(Backoff.pingMs)
        XCTAssertEqual(sockets[0].sent.last?["type"] as? String, "ping")
        clock.advance(Backoff.pingMs + 10_000) // > 45 s since the last frame
        XCTAssertNotNil(sockets[0].closedWith)
        clock.advance(Backoff.maxMs)
        XCTAssertEqual(sockets.count, 2)
        _ = ch
    }

    func testEventsAreDecodedAndForwarded() {
        let ch = makeChannel()
        ch.start()
        sockets[0].onOpen()
        ready(sockets[0])
        sockets[0].serverSays(["type": "member_note", "user_id": "u2", "note": ["text": "بوقف", "at": "2026-11-03T10:00:00.000Z"]])
        sockets[0].serverSays(["type": "outing_status", "status": "paused"])
        sockets[0].serverSays(["type": "pong", "server_now": "2026-11-03T10:00:00.000Z"])
        XCTAssertEqual(events, [.memberNote(userId: "u2", note: MemberNote(text: "بوقف", at: "2026-11-03T10:00:00.000Z")), .outingStatus(.paused)])
        _ = ch
    }

    func testStopClosesAndForgetsPendingFix() {
        let ch = makeChannel()
        ch.start()
        ch.sendFix(fix(at: clock.nowMs), mode: .balanced)
        ch.stop()
        XCTAssertEqual(ch.state, .closed)
        XCTAssertEqual(sockets[0].closedWith, 1000)
        sockets[0].onOpen()
        XCTAssertTrue(sockets[0].sent.isEmpty, "a stopped channel never sends")
    }
}
