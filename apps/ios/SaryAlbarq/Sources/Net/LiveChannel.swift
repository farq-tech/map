import Foundation

/// The live link to one outing — the native twin of `live.ts`.
///
///   WebSocket first (auth in the first frame), reconnecting with capped
///   exponential backoff + jitter. If sockets never get through — a proxy that
///   strips upgrades, a captive network — fall back to HTTP polling and keep
///   retrying the socket quietly in the back.
///
/// Only the latest fix is ever kept while disconnected (`LatestFixSlot`).
/// Everything runs on the main queue; transport and clock are injected so the
/// state machine is tested without a network.
final class LiveChannel {
    enum State: String, Equatable { case connecting, live, polling, offline, closed }

    struct Handlers {
        var onSnapshot: (OutingSnapshot) -> Void = { _ in }
        var onEvent: (LiveEvent) -> Void = { _ in }
        var onState: (State) -> Void = { _ in }
        var onClosed: (LiveCloseReason) -> Void = { _ in }
        var onAck: (Bool, String?) -> Void = { _, _ in }
        /// server_now from acks/pongs, to keep the clock offset honest.
        var onServerNow: (String) -> Void = { _ in }
        /// «قناة الطلعة»: floor-control signals (ptt_*).
        var onPTT: (PTTSignal) -> Void = { _ in }
        /// «قناة الطلعة»: a binary audio frame relayed by the server.
        var onAudio: (Data) -> Void = { _ in }
        /// The link's health for the diagnostics line («متصل» / «يعيد الاتصال» / last close code).
        var onDiagnostics: (Diagnostics) -> Void = { _ in }
        /// «المحادثات»: chat_message / chat_ack / chat_read / chat_typing / chat_deleted frames.
        var onChat: ([String: Any]) -> Void = { _ in }
    }

    /// What the channel sheet shows about the link. Numbers and codes only.
    struct Diagnostics: Equatable {
        var state: State = .connecting
        /// The last close code seen (1006 = the connection simply died).
        var lastCloseCode: Int?
        /// The server's close reason text, when it gave one (e.g. "auth_timeout", "replaced").
        var lastCloseReason: String?
        /// Sockets opened after the first one.
        var reconnects = 0
        /// Since when the current socket is live (ms, scheduler clock).
        var liveSinceMs: Double?
        /// Waiting this long before the next attempt (0 when not waiting).
        var retryInMs: Double = 0
    }

    struct Deps {
        var makeSocket: (URL) -> LiveSocket
        var poll: (String) async throws -> OutingSnapshot
        var post: (String, WireFix) async throws -> Void
        var beat: (String, GpsState, BatteryInfo?) async throws -> Void
        var scheduler: Scheduler
        /// The privacy gate (`SendGate.allowsPosition`), asked at the last step
        /// before a position frame or POST. Closed by default: a caller has to
        /// say, every time, that this person is sharing right now.
        var canSendPosition: () -> Bool = { false }
        var random: () -> Double = { Double.random(in: 0...1) }
        var online: () -> Bool = { true }
    }

    private(set) var state: State = .connecting
    private let outingId: String
    private let token: String
    private let url: URL
    var handlers: Handlers
    private let deps: Deps

    private var socket: LiveSocket?
    private var attempts = 0
    private var everReady = false
    private var wasPolling = false
    private var stopped = false
    private var retry: Cancellable?
    private var pollTimer: Cancellable?
    private var pingTimer: Cancellable?
    private var lastFrameAtMs = 0.0
    private var slot = LatestFixSlot()
    private var seq = 0
    private var away = false
    /// In «قناة الطلعة» (re-sent after every reconnect).
    private var pttJoined = false
    /// A floor request made while the socket was (re)connecting: sent right after `ready`, if still fresh.
    private var pendingPTTStart: (id: Int, atMs: Double)?
    /// When the current socket was created (a socket still handshaking is not killed by `reconnectNow`).
    private var socketStartedMs = 0.0
    private var readyTimer: Cancellable?
    /// 4409 «replaced» in a row without a socket that stayed up: after a few, stop fighting.
    private var replacedStreak = 0
    private var opened = 0
    private(set) var diagnostics = Diagnostics()
    private let log: (String) -> Void

    /// A socket that has not reached `ready` by then is given up and retried.
    static let readyTimeoutMs = 15_000.0
    /// A queued floor request older than this is dropped (the person has let go or given up).
    static let pendingStartMaxMs = 6_000.0
    /// Live but no frame for this long: on a wake-up (push, talk button) reconnect at once rather than trust it.
    static let staleMs = 25_000.0
    /// After a 4409 the next try waits at least this long (another socket of ours is newer: do not fight it).
    static let replacedWaitMs = 20_000.0
    static let replacedGiveUp = 4

    init(outingId: String, token: String, url: URL = Endpoints.liveSocket, handlers: Handlers = Handlers(), deps: Deps,
         log: @escaping (String) -> Void = { PTTDiagnosticsLog.shared.add("link", $0) }) {
        self.outingId = outingId
        self.token = token
        self.url = url
        self.handlers = handlers
        self.deps = deps
        self.log = log
    }

    func start() { connect() }

    func stop() {
        if !stopped { log("stop") }
        stopped = true
        pendingPTTStart = nil
        slot.clear()
        clearTimers()
        let s = socket
        socket = nil
        s?.close(code: 1000)
        setState(.closed)
    }

    /// Send now if we can; otherwise keep it as the one pending fix.
    func sendFix(_ fix: DeviceFix, mode: ShareMode) {
        guard !stopped, deps.canSendPosition() else { return slot.clear() }
        slot.put(fix, mode: mode)
        flush()
    }

    /// Sharing stopped, the app went to the background, or consent ended: a fix
    /// held for "when the network is back" must never go out later.
    func dropPendingFix() { slot.clear() }

    /// "Still here", with no coordinates — so others can tell no-GPS from no-network.
    /// `battery` only when the person chose to share it.
    func heartbeat(gps: GpsState, battery: BatteryInfo? = nil) {
        guard !stopped else { return }
        if state == .live {
            var f: [String: Any] = ["type": "heartbeat", "gps": gps.rawValue]
            if let battery { f["battery"] = ["level": battery.level, "charging": battery.charging] }
            sendFrame(f)
        } else if state == .polling {
            let id = outingId, beat = deps.beat
            Task { try? await beat(id, gps, battery) }
        }
    }

    func setAway(_ away: Bool) {
        self.away = away
        sendFrame(["type": "presence", "away": away])
        if !away && state == .offline && deps.online() { reconnectNow() }
    }

    /// «المحادثات»: one chat frame (chat_message / chat_read / chat_typing). False when not live.
    @discardableResult
    func sendChat(_ frame: [String: Any]) -> Bool {
        guard let type = frame["type"] as? String, type.hasPrefix("chat_") else { return false }
        return sendFrame(frame)
    }

    func sendNote(_ text: String) -> Bool {
        seq += 1
        return sendFrame(["type": "note", "id": seq, "text": text])
    }

    // MARK: «قناة الطلعة»

    /// Join (or mute = leave) the outing's live voice channel. Survives reconnects.
    func setPTTJoined(_ on: Bool) {
        pttJoined = on
        sendFrame(["type": on ? "ptt_join" : "ptt_leave"])
    }

    /// Ask for the floor. While the socket is (re)connecting the request waits for `ready`
    /// (≤ `pendingStartMaxMs`) instead of being lost, and the reconnect starts now.
    @discardableResult
    func pttStart(id: Int) -> Bool {
        if sendFrame(["type": "ptt_start", "id": id]) { return true }
        guard !stopped else { return false }
        pendingPTTStart = (id, deps.scheduler.nowMs)
        log("ptt_start queued (state=\(state.rawValue))")
        ensureLive(reason: "ptt_start")
        return true
    }

    func pttStop() {
        if pendingPTTStart != nil {
            pendingPTTStart = nil
            return
        }
        sendFrame(["type": "ptt_stop"])
    }

    /// One encoded audio frame. False when the socket is not live (nothing is queued: it is live audio).
    @discardableResult
    func sendAudio(_ frame: Data) -> Bool {
        guard state == .live, let b = socket as? LiveBinarySocket else { return false }
        b.send(data: frame)
        return true
    }

    var isLive: Bool { state == .live }
    /// Stopped for good (a terminal close, or the session closed it).
    var isStopped: Bool { stopped }
    /// A socket exists and is still on its way to `ready`.
    var isConnecting: Bool { socket != nil && state != .live }

    /// Network came back, or the app came to the foreground.
    ///
    /// A live socket is kept, and so is one still handshaking (younger than `readyTimeoutMs`):
    /// killing it and starting over on every foreground made a slow network never get through.
    func reconnectNow() {
        guard !stopped else { return }
        attempts = 0
        if replacedStreak > 0, retry != nil { return } // waiting out a 4409: do not fight
        retry?.cancel()
        retry = nil
        if wasPolling && !everReady { startPolling() }
        if socket != nil && state == .live { return }
        if socket != nil, deps.scheduler.nowMs - socketStartedMs < Self.readyTimeoutMs { return }
        let old = socket
        socket = nil
        old?.close(code: 1000)
        connect()
    }

    /// A wake-up that needs the link now (a pushtotalk push, the talk button, the app back on screen):
    /// a live socket that has said nothing for `staleMs` is presumed dead and replaced at once;
    /// otherwise a ping proves it. Not live: connect now.
    func ensureLive(reason: String) {
        guard !stopped else { return }
        if state == .live, let s = socket {
            if deps.scheduler.nowMs - lastFrameAtMs > Self.staleMs {
                log("stale live socket on \(reason): replacing")
                socket = nil
                s.close(code: 1000)
                attempts = 0
                retry?.cancel()
                retry = nil
                return connect()
            }
            sendFrame(["type": "ping"])
            return
        }
        /* Someone is waiting on this (a press, a push): no backoff, not even after a 4409. */
        retry?.cancel()
        retry = nil
        reconnectNow()
    }

    func networkLost() {
        guard !stopped else { return }
        setState(.offline)
    }

    // MARK: - internals

    private func setState(_ s: State) {
        guard state != s else { return }
        state = s
        log("state \(s.rawValue)")
        diagnostics.state = s
        if s != .live { diagnostics.liveSinceMs = nil }
        handlers.onState(s)
        handlers.onDiagnostics(diagnostics)
    }

    private func noteClose(_ code: Int, _ reason: String?, wasReady: Bool) {
        diagnostics.lastCloseCode = code
        diagnostics.lastCloseReason = reason
        log("close code=\(code)\(reason.map { " reason=\($0)" } ?? "") ready=\(wasReady)")
        handlers.onDiagnostics(diagnostics)
    }

    private func clearTimers() {
        retry?.cancel()
        pollTimer?.cancel()
        pingTimer?.cancel()
        readyTimer?.cancel()
        retry = nil
        pollTimer = nil
        pingTimer = nil
        readyTimer = nil
    }

    @discardableResult
    private func sendFrame(_ obj: [String: Any]) -> Bool {
        guard let socket, state == .live,
              let d = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: d, encoding: .utf8) else { return false }
        socket.send(s)
        return true
    }

    private func flush() {
        guard slot.pending != nil else { return }
        /* Re-asked here because a fix can wait in the slot across a reconnect. */
        guard deps.canSendPosition() else { return slot.clear() }
        if state == .live {
            guard let pending = slot.pending, let wire = slot.take(nowMs: deps.scheduler.nowMs) else { return }
            seq += 1
            guard let fixObj = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(wire)) else { return }
            if !sendFrame(["type": "position", "id": seq, "fix": fixObj]) { slot.restore(pending.fix, mode: pending.mode) }
            return
        }
        if state == .polling {
            guard let wire = slot.take(nowMs: deps.scheduler.nowMs) else { return }
            let id = outingId, post = deps.post
            Task { @MainActor [weak self] in
                do {
                    try await post(id, wire)
                    self?.handlers.onAck(true, nil)
                } catch let e as OutingAPIError {
                    if e.code == "not_a_member" { self?.terminal(.notAMember) } else { self?.handlers.onAck(false, e.code) }
                } catch {
                    self?.handlers.onAck(false, "network")
                }
            }
        }
    }

    private func terminal(_ r: LiveCloseReason) {
        guard !stopped else { return }
        stop()
        handlers.onClosed(r)
    }

    private func connect() {
        guard !stopped else { return }
        guard deps.online() else { return setState(.offline) }
        if state != .polling { setState(.connecting) }
        let s = deps.makeSocket(url)
        socket = s
        socketStartedMs = deps.scheduler.nowMs
        opened += 1
        if opened > 1 { diagnostics.reconnects = opened - 1 }
        diagnostics.retryInMs = 0
        log("connect #\(opened)")
        var reachedReady = false
        var readyAtMs = 0.0
        readyTimer?.cancel()
        readyTimer = deps.scheduler.after(ms: Self.readyTimeoutMs) { [weak self, weak s] in
            guard let self, let s, self.socket === s, !reachedReady else { return }
            /* Handshake or auth never finished (a dead network, a stuck proxy): give up on this one. */
            self.log("no ready after \(Int(Self.readyTimeoutMs / 1000)) s: retrying")
            self.socket = nil
            s.close(code: 1000)
            self.noteClose(0, "ready_timeout", wasReady: false)
            self.onSocketFailed()
        }
        s.onOpen = { [weak self, weak s] in
            guard let self, let s, self.socket === s else { return }
            let auth: [String: Any] = ["type": "auth", "token": self.token, "outing_id": self.outingId]
            if let d = try? JSONSerialization.data(withJSONObject: auth), let t = String(data: d, encoding: .utf8) { s.send(t) }
        }
        s.onMessage = { [weak self, weak s] text in
            guard let self, let s, self.socket === s else { return }
            self.lastFrameAtMs = self.deps.scheduler.nowMs
            guard let d = text.data(using: .utf8),
                  let msg = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                  let type = msg["type"] as? String else { return }
            switch type {
            case "ready":
                reachedReady = true
                readyAtMs = self.deps.scheduler.nowMs
                self.readyTimer?.cancel()
                self.readyTimer = nil
                self.everReady = true
                self.attempts = 0
                self.stopPolling()
                self.diagnostics.liveSinceMs = readyAtMs
                self.setState(.live)
                if let raw = msg["snapshot"], let sd = try? JSONSerialization.data(withJSONObject: raw),
                   let snap = try? JSONDecoder().decode(OutingSnapshot.self, from: sd) {
                    self.handlers.onSnapshot(snap)
                }
                /* «قناة الطلعة» (Sources/Media): only when the server sends it, so an older server reads as "not there". */
                if let snap = msg["snapshot"] as? [String: Any], snap.keys.contains("media") { MediaEvents.post(outingId: self.outingId, raw: snap["media"]) }
                if self.away { self.sendFrame(["type": "presence", "away": true]) }
                if self.pttJoined { self.sendFrame(["type": "ptt_join"]) }
                if let p = self.pendingPTTStart {
                    self.pendingPTTStart = nil
                    if self.deps.scheduler.nowMs - p.atMs <= Self.pendingStartMaxMs {
                        self.log("ptt_start sent after ready")
                        self.sendFrame(["type": "ptt_start", "id": p.id])
                    }
                }
                self.flush()
                self.schedulePing()
            case "ack":
                if let now = msg["server_now"] as? String { self.handlers.onServerNow(now) }
                self.handlers.onAck(msg["ok"] as? Bool == true, msg["reason"] as? String)
            case "pong":
                if let now = msg["server_now"] as? String { self.handlers.onServerNow(now) }
            case "error":
                self.log("server error \(msg["code"] as? String ?? "?")")
            case "closed", "note_ack":
                break
            case _ where type.hasPrefix("ptt_"):
                if let sig = PTTSignal.decode(msg) { self.handlers.onPTT(sig) }
            case "media_state":
                MediaEvents.post(outingId: self.outingId, raw: msg["state"])
            case _ where type.hasPrefix("chat_"):
                self.handlers.onChat(msg)
            default:
                if let e = LiveEvent.decode(msg) { self.handlers.onEvent(e) }
            }
        }
        (s as? LiveBinarySocket)?.onBinary = { [weak self, weak s] data in
            guard let self, let s, self.socket === s else { return }
            self.lastFrameAtMs = self.deps.scheduler.nowMs
            self.handlers.onAudio(data)
        }
        s.onClose = { [weak self, weak s] code in
            guard let self, let s, self.socket === s else { return }
            self.socket = nil
            self.pingTimer?.cancel()
            self.readyTimer?.cancel()
            let reason = (s as? LiveCloseReasonSource)?.closeReasonText
            self.noteClose(code, reason, wasReady: reachedReady)
            if self.stopped { return }
            if reachedReady, self.deps.scheduler.nowMs - readyAtMs > 60_000 { self.replacedStreak = 0 }
            switch LiveClosePolicy.decide(code: code, reason: reason) {
            case .retry:
                if !reachedReady { return self.onSocketFailed() }
                self.scheduleReconnect()
            case .backOff:
                /* 4409: a newer socket of ours (or another phone signed in as us) holds the room. Wait it out. */
                self.replacedStreak += 1
                if self.replacedStreak >= Self.replacedGiveUp { return self.terminal(.replaced) }
                self.scheduleReconnect(atLeastMs: Self.replacedWaitMs * Double(self.replacedStreak))
            case .verify(let r):
                /* 4401 / 4404 used to end the outing on this phone for good. Ask over HTTP first:
                 * only the API saying so (401 / not a member) is final; anything else retries. */
                self.verifyThenClose(r, reachedReady: reachedReady)
            case .terminal(let r):
                self.terminal(r)
            }
        }
        s.connect()
    }

    private func verifyThenClose(_ r: LiveCloseReason, reachedReady: Bool) {
        let id = outingId, poll = deps.poll
        if state != .polling { setState(.connecting) }
        Task { @MainActor [weak self] in
            var final = false
            do {
                _ = try await poll(id)
            } catch let e as OutingAPIError {
                final = (r == .unauthorized && e.code == "unauthorized") || (r == .notAMember && e.code == "not_a_member")
            } catch {}
            guard let self, !self.stopped else { return }
            if final { return self.terminal(r) }
            self.log("close \(r.rawValue) not confirmed over HTTP: retrying")
            if !reachedReady { self.onSocketFailed() } else { self.scheduleReconnect() }
        }
    }

    private func onSocketFailed() {
        attempts += 1
        if !everReady && attempts >= Backoff.failsBeforePolling { startPolling() }
        scheduleReconnect()
    }

    private func scheduleReconnect(atLeastMs: Double = 0) {
        guard !stopped else { return }
        guard deps.online() else { return setState(.offline) }
        if state != .polling { setState(.connecting) }
        retry?.cancel()
        let wait = max(atLeastMs, Backoff.delayMs(attempt: attempts, rand: deps.random()))
        attempts += 1
        diagnostics.retryInMs = wait
        handlers.onDiagnostics(diagnostics)
        retry = deps.scheduler.after(ms: wait) { [weak self] in
            self?.retry = nil
            self?.connect()
        }
    }

    private func schedulePing() {
        pingTimer?.cancel()
        pingTimer = deps.scheduler.after(ms: Backoff.pingMs) { [weak self] in
            guard let self, !self.stopped, let s = self.socket else { return }
            if self.deps.scheduler.nowMs - self.lastFrameAtMs > Backoff.silenceMs {
                /* Half-open: the tunnel ate the socket without a close frame. */
                self.socket = nil
                s.close(code: 1000)
                self.noteClose(0, "silent", wasReady: true)
                return self.scheduleReconnect()
            }
            self.sendFrame(["type": "ping"])
            self.schedulePing()
        }
    }

    private func startPolling() {
        guard !stopped, state != .polling else { return }
        wasPolling = true
        setState(.polling)
        pollTick()
    }

    private func pollTick() {
        guard !stopped, state == .polling else { return }
        let id = outingId, poll = deps.poll
        Task { @MainActor [weak self] in
            do {
                let snap = try await poll(id)
                guard let self, !self.stopped, self.state == .polling else { return }
                self.handlers.onSnapshot(snap)
                if snap.outing.status == .ended { return self.terminal(.outingEnded) }
                self.flush()
            } catch let e as OutingAPIError {
                if e.code == "not_a_member" { self?.terminal(.notAMember); return }
                if e.code == "unauthorized" { self?.terminal(.unauthorized); return }
            } catch {}
            guard let self, !self.stopped, self.state == .polling else { return }
            self.pollTimer = self.deps.scheduler.after(ms: Backoff.pollMs) { [weak self] in self?.pollTick() }
        }
    }

    private func stopPolling() {
        pollTimer?.cancel()
        pollTimer = nil
    }
}

// MARK: - transport and clock

protocol Cancellable { func cancel() }

protocol Scheduler {
    var nowMs: Double { get }
    func after(ms: Double, _ block: @escaping () -> Void) -> Cancellable
}

final class MainScheduler: Scheduler {
    private final class Item: Cancellable {
        let work: DispatchWorkItem
        init(_ w: DispatchWorkItem) { work = w }
        func cancel() { work.cancel() }
    }

    var nowMs: Double { Date().timeIntervalSince1970 * 1000 }

    func after(ms: Double, _ block: @escaping () -> Void) -> Cancellable {
        let w = DispatchWorkItem(block: block)
        DispatchQueue.main.asyncAfter(deadline: .now() + ms / 1000, execute: w)
        return Item(w)
    }
}

/// A text WebSocket. Callbacks arrive on the main queue.
protocol LiveSocket: AnyObject {
    var onOpen: () -> Void { get set }
    var onMessage: (String) -> Void { get set }
    /// Close code (1006 when the connection simply died).
    var onClose: (Int) -> Void { get set }
    func connect()
    func send(_ text: String)
    func close(code: Int)
}

/// A socket that can say why the server closed it (the close frame's reason text).
protocol LiveCloseReasonSource: AnyObject {
    var closeReasonText: String? { get }
}

/// What a close code means for reconnecting. Pure, so it is tested on its own.
enum LiveClosePolicy: Equatable {
    case retry
    /// Retry, but slowly: someone newer holds our place (4409).
    case backOff
    /// Final only if the HTTP API agrees.
    case verify(LiveCloseReason)
    case terminal(LiveCloseReason)

    static func decide(code: Int, reason: String?) -> LiveClosePolicy {
        switch code {
        /* Servers before the fix closed a slow auth with 4401 "auth_timeout": not a bad token. */
        case 4401 where reason == "auth_timeout": return .retry
        case 4408, 1011: return .retry
        case 4409: return .backOff
        case 4401: return .verify(.unauthorized)
        case 4404: return .verify(.notAMember)
        default:
            if let r = LiveCloseReason(code: code) { return .terminal(r) }
            return .retry
        }
    }
}

/// A socket that also carries binary frames (the walkie-talkie's audio).
protocol LiveBinarySocket: AnyObject {
    var onBinary: (Data) -> Void { get set }
    func send(data: Data)
}

final class URLSessionLiveSocket: NSObject, LiveSocket, LiveBinarySocket, LiveCloseReasonSource, URLSessionWebSocketDelegate {
    private(set) var closeReasonText: String?
    var onOpen: () -> Void = {}
    var onBinary: (Data) -> Void = { _ in }
    var onMessage: (String) -> Void = { _ in }
    var onClose: (Int) -> Void = { _ in }

    private let url: URL
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var closed = false

    init(url: URL) { self.url = url }

    func connect() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 15
        cfg.waitsForConnectivity = false
        let s = URLSession(configuration: cfg, delegate: self, delegateQueue: .main)
        session = s
        let t = s.webSocketTask(with: url)
        t.maximumMessageSize = 64 * 1024
        task = t
        t.resume()
        receive()
    }

    private func receive() {
        task?.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self, !self.closed else { return }
                switch result {
                case let .success(.string(s)):
                    self.onMessage(s)
                    self.receive()
                case let .success(.data(d)):
                    /* The server's only binary frames are walkie-talkie audio. */
                    self.onBinary(d)
                    self.receive()
                case .success:
                    self.receive()
                case .failure:
                    self.captureReason()
                    let code = self.task?.closeCode.rawValue ?? 1006
                    self.finish(code == 0 ? 1006 : code)
                }
            }
        }
    }

    func send(_ text: String) {
        task?.send(.string(text)) { _ in }
    }

    func send(data: Data) {
        task?.send(.data(data)) { _ in }
    }

    func close(code: Int) {
        closed = true
        task?.cancel(with: URLSessionWebSocketTask.CloseCode(rawValue: code) ?? .normalClosure, reason: nil)
        session?.invalidateAndCancel()
    }

    private func finish(_ code: Int) {
        guard !closed else { return }
        closed = true
        session?.invalidateAndCancel()
        onClose(code)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        onOpen()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        if let reason, let t = String(data: reason, encoding: .utf8), !t.isEmpty { closeReasonText = String(t.prefix(40)) }
        finish(closeCode.rawValue)
    }

    private func captureReason() {
        guard closeReasonText == nil, let d = task?.closeReason, let t = String(data: d, encoding: .utf8), !t.isEmpty else { return }
        closeReasonText = String(t.prefix(40))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        captureReason()
        let code = (task as? URLSessionWebSocketTask)?.closeCode.rawValue ?? 0
        finish(code == 0 ? 1006 : code)
    }
}
