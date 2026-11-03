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
    }

    struct Deps {
        var makeSocket: (URL) -> LiveSocket
        var poll: (String) async throws -> OutingSnapshot
        var post: (String, WireFix) async throws -> Void
        var beat: (String, GpsState) async throws -> Void
        var scheduler: Scheduler
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

    init(outingId: String, token: String, url: URL = Endpoints.liveSocket, handlers: Handlers = Handlers(), deps: Deps) {
        self.outingId = outingId
        self.token = token
        self.url = url
        self.handlers = handlers
        self.deps = deps
    }

    func start() { connect() }

    func stop() {
        stopped = true
        slot.clear()
        clearTimers()
        let s = socket
        socket = nil
        s?.close(code: 1000)
        setState(.closed)
    }

    /// Send now if we can; otherwise keep it as the one pending fix.
    func sendFix(_ fix: DeviceFix, mode: ShareMode) {
        guard !stopped else { return }
        slot.put(fix, mode: mode)
        flush()
    }

    /// "Still here", with no coordinates — so others can tell no-GPS from no-network.
    func heartbeat(gps: GpsState) {
        guard !stopped else { return }
        if state == .live {
            sendFrame(["type": "heartbeat", "gps": gps.rawValue])
        } else if state == .polling {
            let id = outingId, beat = deps.beat
            Task { try? await beat(id, gps) }
        }
    }

    func setAway(_ away: Bool) {
        self.away = away
        sendFrame(["type": "presence", "away": away])
        if !away && state == .offline && deps.online() { reconnectNow() }
    }

    func sendNote(_ text: String) -> Bool {
        seq += 1
        return sendFrame(["type": "note", "id": seq, "text": text])
    }

    /// Network came back, or the app came to the foreground.
    func reconnectNow() {
        guard !stopped else { return }
        attempts = 0
        retry?.cancel()
        retry = nil
        if wasPolling && !everReady { startPolling() }
        if socket != nil && state == .live { return }
        let old = socket
        socket = nil
        old?.close(code: 1000)
        connect()
    }

    func networkLost() {
        guard !stopped else { return }
        setState(.offline)
    }

    // MARK: - internals

    private func setState(_ s: State) {
        guard state != s else { return }
        state = s
        handlers.onState(s)
    }

    private func clearTimers() {
        retry?.cancel()
        pollTimer?.cancel()
        pingTimer?.cancel()
        retry = nil
        pollTimer = nil
        pingTimer = nil
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
        var reachedReady = false
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
                self.everReady = true
                self.attempts = 0
                self.stopPolling()
                self.setState(.live)
                if let raw = msg["snapshot"], let sd = try? JSONSerialization.data(withJSONObject: raw),
                   let snap = try? JSONDecoder().decode(OutingSnapshot.self, from: sd) {
                    self.handlers.onSnapshot(snap)
                }
                if self.away { self.sendFrame(["type": "presence", "away": true]) }
                self.flush()
                self.schedulePing()
            case "ack":
                if let now = msg["server_now"] as? String { self.handlers.onServerNow(now) }
                self.handlers.onAck(msg["ok"] as? Bool == true, msg["reason"] as? String)
            case "pong":
                if let now = msg["server_now"] as? String { self.handlers.onServerNow(now) }
            case "error", "closed", "note_ack":
                break
            default:
                if let e = LiveEvent.decode(msg) { self.handlers.onEvent(e) }
            }
        }
        s.onClose = { [weak self, weak s] code in
            guard let self, let s, self.socket === s else { return }
            self.socket = nil
            self.pingTimer?.cancel()
            if let r = LiveCloseReason(code: code) { return self.terminal(r) }
            if self.stopped { return }
            if !reachedReady { return self.onSocketFailed() }
            self.scheduleReconnect()
        }
        s.connect()
    }

    private func onSocketFailed() {
        attempts += 1
        if !everReady && attempts >= Backoff.failsBeforePolling { startPolling() }
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard !stopped else { return }
        guard deps.online() else { return setState(.offline) }
        if state != .polling { setState(.connecting) }
        retry?.cancel()
        let wait = Backoff.delayMs(attempt: attempts, rand: deps.random())
        attempts += 1
        retry = deps.scheduler.after(ms: wait) { [weak self] in self?.connect() }
    }

    private func schedulePing() {
        pingTimer?.cancel()
        pingTimer = deps.scheduler.after(ms: Backoff.pingMs) { [weak self] in
            guard let self, !self.stopped, let s = self.socket else { return }
            if self.deps.scheduler.nowMs - self.lastFrameAtMs > Backoff.silenceMs {
                /* Half-open: the tunnel ate the socket without a close frame. */
                self.socket = nil
                s.close(code: 1000)
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

final class URLSessionLiveSocket: NSObject, LiveSocket, URLSessionWebSocketDelegate {
    var onOpen: () -> Void = {}
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
                    if let s = String(data: d, encoding: .utf8) { self.onMessage(s) }
                    self.receive()
                case .success:
                    self.receive()
                case .failure:
                    let code = self.task?.closeCode.rawValue ?? 1006
                    self.finish(code == 0 ? 1006 : code)
                }
            }
        }
    }

    func send(_ text: String) {
        task?.send(.string(text)) { _ in }
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
        finish(closeCode.rawValue)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let code = (task as? URLSessionWebSocketTask)?.closeCode.rawValue ?? 0
        finish(code == 0 ? 1006 : code)
    }
}
