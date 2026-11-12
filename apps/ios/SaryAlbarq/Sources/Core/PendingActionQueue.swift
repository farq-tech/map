import Combine
import Foundation
import os

/// One outing action this phone already applied (the screen closed, sharing stopped, the rally
/// moved…) whose server request is still owed (#173, docs/RESPONSIVENESS.md). Kept on the phone
/// until the server answered, so it survives the app being killed.
///
/// Never for a local session (demo, solo): those have no server (`OutingSession.isLocal`).
/// Never anything personal beyond what the request itself carries (a note's text, a rally label).
struct PendingOutingAction: Codable, Equatable, Identifiable {
    enum Kind: String, Codable, Equatable {
        /// `POST /:id/leave`.
        case leave
        /// «أنا بخير»: `DELETE /:id/sos`.
        case cancelSOS
        /// `PUT /:id/rally`.
        case setRally
        /// `DELETE /:id/rally`.
        case clearRally
        /// «أخفِ موقعي» (hiding only: showing again opens sharing, so it waits for the server).
        case hide
        /// `POST /:id/members/:m/co-leader`.
        case coLeader
        /// `DELETE /:id/members/:m`.
        case removeMember
        /// «رسالة فوق سيارتي»: `POST /:id/note` (empty text clears it).
        case note
        /// «إنهاء الطلعة للجميع»: `POST /:id/status {end}` (the owner). Applied here at once; idempotent on the server.
        case endOuting
    }

    var id: String = UUID().uuidString
    var user: String
    var outing: String
    var kind: Kind
    var member: String?
    var on: Bool?
    var lat: Double?
    var lng: Double?
    var label: String?
    var text: String?
    /// When the person acted (ms since 1970).
    var createdMs: Double
    /// Failed sends so far.
    var attempts: Int = 0
    /// Not before this time (ms since 1970); 0 = now.
    var nextMs: Double = 0
}

/// The persisted retry queue behind `OutingActionOutbox`, on the pattern of `OfflineFixQueue`:
/// a pure value (tested on its own) with `load`/`save` in `UserDefaults`.
///
/// Rules:
///   * coalesced: a later action on the same target replaces the earlier one (last write wins:
///     rally set then cleared sends only the clear; a co-leader toggled twice sends the last);
///   * a leave makes everything else for that outing moot: it is dropped, and nothing is queued
///     for an outing with a leave waiting;
///   * backoff: 2 s, 4 s, 8 s… capped at 5 min; the network coming back retries at once;
///   * aged out: a leave is kept 7 days, anything else 2 hours (a stale rally is worse than none);
///   * at-least-once: an item is removed only after the server answered (ok, or a refusal that
///     will never change); a request whose answer never came is sent again, and every request
///     here is idempotent on the server (leave, set/clear, put).
struct PendingActionQueue: Codable, Equatable {
    static let cap = 100
    static let baseBackoffMs = 2_000.0
    static let maxBackoffMs = 5 * 60_000.0
    static let leaveMaxAgeMs = 7 * 24 * 3_600_000.0
    static let maxAgeMs = 2 * 3_600_000.0

    /// How long `kind` may wait. A leave and a hide keep for days: dropping either before the
    /// server heard it would let the next snapshot share my location again without my say.
    static func maxAgeMs(for kind: PendingOutingAction.Kind) -> Double {
        kind == .leave || kind == .hide || kind == .endOuting ? leaveMaxAgeMs : maxAgeMs
    }

    private(set) var items: [PendingOutingAction] = []

    var isEmpty: Bool { items.isEmpty }
    var count: Int { items.count }

    static func backoffMs(attempts: Int) -> Double {
        guard attempts > 0 else { return 0 }
        return min(maxBackoffMs, baseBackoffMs * pow(2, Double(min(attempts - 1, 16))))
    }

    /// Queue `a`, replacing whatever it supersedes. False when it is moot (a leave waits for that outing).
    @discardableResult
    mutating func enqueue(_ a: PendingOutingAction) -> Bool {
        func same(_ x: PendingOutingAction) -> Bool { x.user == a.user && x.outing == a.outing }
        if a.kind != .leave, items.contains(where: { same($0) && $0.kind == .leave }) { return false }
        /* An end already waiting makes everything else for that outing moot, like a leave. */
        if a.kind != .leave, a.kind != .endOuting, items.contains(where: { same($0) && $0.kind == .endOuting }) { return false }
        switch a.kind {
        case .leave:
            items.removeAll { same($0) }
        case .endOuting:
            items.removeAll { same($0) && $0.kind != .leave }
        case .setRally, .clearRally:
            items.removeAll { same($0) && ($0.kind == .setRally || $0.kind == .clearRally) }
        case .removeMember:
            items.removeAll { same($0) && $0.member == a.member && ($0.kind == .coLeader || $0.kind == .removeMember) }
        case .cancelSOS, .hide, .coLeader, .note:
            items.removeAll { same($0) && $0.kind == a.kind && $0.member == a.member }
        }
        items.append(a)
        if items.count > Self.cap { items.removeFirst(items.count - Self.cap) }
        return true
    }

    mutating func remove(id: String) {
        items.removeAll { $0.id == id }
    }

    /// Take back what was not sent yet (e.g. a queued «أنا بخير» when a new SOS is raised).
    /// True when something was removed.
    @discardableResult
    mutating func discard(user: String, outing: String, kind: PendingOutingAction.Kind) -> Bool {
        let before = items.count
        items.removeAll { $0.user == user && $0.outing == outing && $0.kind == kind }
        return items.count != before
    }

    /// A send failed and may work later: wait a bit longer each time.
    mutating func failed(id: String, nowMs: Double) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].attempts += 1
        items[i].nextMs = nowMs + Self.backoffMs(attempts: items[i].attempts)
    }

    /// The network is back: everything is due now.
    mutating func retryNow() {
        for i in items.indices { items[i].nextMs = 0 }
    }

    /// The oldest item of `user` that is due now.
    func next(nowMs: Double, user: String) -> PendingOutingAction? {
        items.first { $0.user == user && $0.nextMs <= nowMs }
    }

    /// When the next item of `user` is due (nil: nothing waits).
    func earliestDue(user: String) -> Double? {
        items.filter { $0.user == user }.map(\.nextMs).min()
    }

    func has(user: String, outing: String, kind: PendingOutingAction.Kind) -> Bool {
        items.contains { $0.user == user && $0.outing == outing && $0.kind == kind }
    }

    func pending(user: String, outing: String) -> [PendingOutingAction] {
        items.filter { $0.user == user && $0.outing == outing }
    }

    /// Outings this user left on the phone whose leave has not reached the server yet.
    func pendingLeaves(user: String) -> Set<String> {
        Set(items.filter { $0.user == user && $0.kind == .leave }.map(\.outing))
    }

    /// Drop what is too old to still mean anything. True when something was removed.
    @discardableResult
    mutating func prune(nowMs: Double) -> Bool {
        let before = items.count
        items.removeAll { nowMs - $0.createdMs > Self.maxAgeMs(for: $0.kind) }
        return items.count != before
    }

    mutating func clear() { items = [] }

    // MARK: what a failure means

    enum Verdict: Equatable {
        /// The server agrees (or the result is already what we wanted).
        case done
        /// No network, timeout, server trouble, rate limit: try again later.
        case retry
        /// A refusal that will not change (not allowed, invalid): drop it.
        case drop
    }

    static func verdict(_ error: Error, kind: PendingOutingAction.Kind) -> Verdict {
        guard let e = error as? OutingAPIError else { return .retry }
        if e.status == 0 || e.status >= 500 || e.status == 408 || e.status == 429 { return .retry }
        if e.code == "network" || e.code == "timeout" || e.code == "rate_limited" || e.code == "too_frequent" || e.code == "server_busy" { return .retry }
        if e.status == 401 { return .drop }
        switch kind {
        case .leave:
            /* Not a member, removed, the outing gone: I am out, which is what leaving wanted. */
            return .done
        case .removeMember:
            return e.status == 404 ? .done : .drop
        case .endOuting:
            /* The outing is gone (404) or already ended (409): it is over, which is what ending wanted. */
            return e.status == 404 || e.status == 409 ? .done : .drop
        default:
            return .drop
        }
    }

    // MARK: persistence (survives the app being killed)

    static let key = "sary.pendingActions.v1"

    static func load(defaults: UserDefaults = .standard) -> PendingActionQueue {
        guard let d = defaults.data(forKey: key),
              let q = try? JSONDecoder().decode(PendingActionQueue.self, from: d) else { return PendingActionQueue() }
        return q
    }

    func save(defaults: UserDefaults = .standard) {
        if items.isEmpty { defaults.removeObject(forKey: Self.key); return }
        if let d = try? JSONEncoder().encode(self) { defaults.set(d, forKey: Self.key) }
    }
}

/// Sends the `PendingActionQueue` in the background: one request at a time, oldest first, with
/// backoff, and again at once when the network is back. One per app (`AppModel.outbox`), shared
/// by every session, so a leave keeps going after its screen closed; a session made without one
/// (tests) builds its own.
@MainActor
final class OutingActionOutbox: ObservableObject {
    enum Outcome: Equatable {
        case sent
        case willRetry
        case dropped(OutingAPIError?)
    }

    /// `action` as it was before this send (`attempts == 0`: the first failure).
    struct Report {
        let action: PendingOutingAction
        let outcome: Outcome
    }

    struct Deps {
        var perform: @MainActor (PendingOutingAction) async throws -> Void
        var defaults: UserDefaults = .standard
        var now: () -> Double = { Date().timeIntervalSince1970 * 1000 }
        /// Waits `ms` (tests move a fake clock instead).
        var sleep: @MainActor (Double) async -> Void = { ms in
            try? await Task.sleep(nanoseconds: UInt64(max(0, ms) * 1_000_000))
        }
        /// Keeps the app running until one request finishes (UIKit background task).
        var keepAlive: @MainActor () -> () -> Void = { {} }
    }

    @Published private(set) var queue: PendingActionQueue
    let reports = PassthroughSubject<Report, Never>()
    /// Whose items may be sent now (the signed-in identity); nil sends nothing.
    var currentUser: () -> String? = { nil }

    private let deps: Deps
    private var draining: Task<Void, Never>?
    private var generation = 0
    private var sleeping = false
    /// The action being sent right now (its request may already be on the wire).
    private(set) var inFlight: PendingOutingAction?
    private var traces: [String: ActionTrace.Interval] = [:]

    init(deps: Deps) {
        self.deps = deps
        queue = PendingActionQueue.load(defaults: deps.defaults)
    }

    /// The real one: each action is the same `OutingsAPI` call the screen used to wait for.
    static func live(api: OutingsAPI, defaults: UserDefaults = .standard,
                     keepAlive: @escaping @MainActor () -> () -> Void = { BackgroundPositionSender.backgroundTask() }) -> OutingActionOutbox {
        OutingActionOutbox(deps: Deps(perform: { a in try await OutingActionOutbox.perform(a, api: api) }, defaults: defaults, keepAlive: keepAlive))
    }

    static func perform(_ a: PendingOutingAction, api: OutingsAPI) async throws {
        switch a.kind {
        case .leave:
            try await api.leave(a.outing)
        case .cancelSOS:
            try await api.cancelSos(a.outing)
        case .setRally:
            guard let lat = a.lat, let lng = a.lng else { return }
            _ = try await api.setRally(a.outing, lat: lat, lng: lng, label: a.label)
        case .clearRally:
            try await api.clearRally(a.outing)
        case .hide:
            _ = try await api.setHidden(a.outing, hidden: true)
        case .coLeader:
            guard let m = a.member else { return }
            try await api.setCoLeader(a.outing, member: m, on: a.on ?? false)
        case .removeMember:
            guard let m = a.member else { return }
            try await api.removeMember(a.outing, member: m)
        case .note:
            _ = try await api.note(a.outing, text: a.text ?? "")
        case .endOuting:
            _ = try await api.setStatus(a.outing, action: "end")
        }
    }

    // MARK: queue

    /// Already applied on the phone; the server is told in the background. `trace`'s ack interval
    /// ends when the server answers. False when it was moot (a leave waits for that outing).
    @discardableResult
    func enqueue(_ a: PendingOutingAction, trace: ActionTrace.Interval? = nil) -> Bool {
        /* Belt and braces: a solo outing never reaches the network (OutingsAPI refuses it too). */
        guard !SoloOuting.isSoloId(a.outing), queue.enqueue(a) else {
            if let trace { ActionTrace.acked(trace, ok: false) }
            return false
        }
        save()
        endSupersededTraces()
        if let trace { traces[a.id] = trace }
        /* A loop asleep behind an earlier action's backoff must not hold this one for minutes. */
        if sleeping { stop() }
        kick()
        return true
    }

    /// Take back a queued action that was not sent yet. True when there was one.
    @discardableResult
    func discard(user: String, outing: String, kind: PendingOutingAction.Kind) -> Bool {
        /* Already sent (its answer may still be coming): taking it back would only lie on the phone. */
        if isInFlight(user: user, outing: outing, kind: kind) { return false }
        guard queue.has(user: user, outing: outing, kind: kind) else { return false }
        queue.discard(user: user, outing: outing, kind: kind)
        save()
        endSupersededTraces()
        return true
    }

    /// An action replaced or taken back before the server answered: its `tap-ack` interval ends here.
    private func endSupersededTraces() {
        for (id, t) in traces where !queue.items.contains(where: { $0.id == id }) {
            traces[id] = nil
            ActionTrace.acked(t, ok: false)
        }
    }

    func has(user: String, outing: String, kind: PendingOutingAction.Kind) -> Bool {
        queue.has(user: user, outing: outing, kind: kind)
    }

    func isInFlight(user: String, outing: String, kind: PendingOutingAction.Kind) -> Bool {
        guard let a = inFlight else { return false }
        return a.user == user && a.outing == outing && a.kind == kind
    }

    /// Waits (at most `timeoutMs`) until that action is no longer on the wire, so a request that
    /// must land after it (show after hide, SOS after «أنا بخير») does. True when it cleared.
    @discardableResult
    func waitUntilNotInFlight(user: String, outing: String, kind: PendingOutingAction.Kind, timeoutMs: Double) async -> Bool {
        var waited = 0.0
        while isInFlight(user: user, outing: outing, kind: kind) {
            guard waited < timeoutMs else { return false }
            try? await Task.sleep(nanoseconds: 50_000_000)
            waited += 50
        }
        return true
    }

    /// The device has a network path again: everything waiting goes now.
    func networkBack() {
        guard !queue.isEmpty else { return }
        queue.retryNow()
        save()
        if sleeping { stop() }
        kick()
    }

    /// Start sending, unless already sending (or waiting for the next try).
    func kick() {
        guard draining == nil, !queue.isEmpty else { return }
        generation &+= 1
        let gen = generation
        draining = Task { [weak self] in
            await self?.drain(gen)
            if self?.generation == gen { self?.draining = nil }
        }
    }

    /// Stop sending (what waits stays on disk). Account wipe, tests standing in for an app kill.
    func stop() {
        draining?.cancel()
        draining = nil
        sleeping = false
        /* A cancelled loop that wakes up later must not touch the next one's state. */
        generation &+= 1
    }

    /// The account is gone from this phone: nothing of it is sent any more.
    func forgetAll() {
        stop()
        queue.clear()
        traces = [:]
        save()
    }

    private func save() { queue.save(defaults: deps.defaults) }

    private func drain(_ gen: Int) async {
        while !Task.isCancelled && generation == gen {
            guard let user = currentUser() else { return }
            let now = deps.now()
            if queue.items.contains(where: { now - $0.createdMs > PendingActionQueue.maxAgeMs(for: $0.kind) }) {
                queue.prune(nowMs: now)
                save()
            }
            if let a = queue.next(nowMs: now, user: user) {
                let done = deps.keepAlive()
                inFlight = a
                defer { if inFlight?.id == a.id { inFlight = nil } }
                let outcome: Outcome
                do {
                    try await deps.perform(a)
                    outcome = .sent
                } catch {
                    switch PendingActionQueue.verdict(error, kind: a.kind) {
                    case .done: outcome = .sent
                    case .retry: outcome = .willRetry
                    case .drop: outcome = .dropped(error as? OutingAPIError)
                    }
                }
                done()
                /* Stopped meanwhile (account wiped, the app going away): leave the queue as it is. */
                guard generation == gen else { return }
                if outcome == .willRetry {
                    queue.failed(id: a.id, nowMs: deps.now())
                } else {
                    queue.remove(id: a.id)
                    if let t = traces.removeValue(forKey: a.id) { ActionTrace.acked(t, ok: outcome == .sent) }
                }
                save()
                reports.send(Report(action: a, outcome: outcome))
                continue
            }
            guard let due = queue.earliestDue(user: user) else { return }
            sleeping = true
            await deps.sleep(min(PendingActionQueue.maxBackoffMs, max(50, due - now)))
            if generation == gen { sleeping = false }
        }
    }
}

/// `os_signpost` intervals per action (#173), category «Actions» in Instruments (Points of
/// Interest / os_signpost): `tap-ui` from the tap to the screen changing, `tap-ack` from the tap
/// to the server's answer. Before #173 the screen waited for the answer, so the old tap→screen
/// time is the `tap-ack` interval.
enum ActionTrace {
    static let signposter = OSSignposter(subsystem: "sa.sary.albarq", category: "Actions")

    struct Interval {
        let action: String
        let ui: OSSignpostIntervalState
        let ack: OSSignpostIntervalState
    }

    static func begin(_ action: String) -> Interval {
        let id = signposter.makeSignpostID()
        let ui = signposter.beginInterval("tap-ui", id: id, "\(action, privacy: .public)")
        let ack = signposter.beginInterval("tap-ack", id: id, "\(action, privacy: .public)")
        return Interval(action: action, ui: ui, ack: ack)
    }

    /// The screen shows the result.
    static func uiShown(_ i: Interval) {
        signposter.endInterval("tap-ui", i.ui, "\(i.action, privacy: .public)")
    }

    /// The server answered (or never will: local session, refused).
    static func acked(_ i: Interval, ok: Bool) {
        signposter.endInterval("tap-ack", i.ack, "\(i.action, privacy: .public) ok=\(ok, privacy: .public)")
    }
}

/// What the person reads while an action waits for the network.
enum PendingActionCopy {
    /// «طلعاتي»: one line for everything waiting (shown once a send failed).
    static func banner(_ items: [PendingOutingAction]) -> String? {
        let waiting = items.filter { $0.attempts > 0 }
        if waiting.contains(where: { $0.kind == .leave }) { return "نكمل المغادرة لما يرجع النت" }
        return waiting.isEmpty ? nil : "نكمل إرسال تغييراتك لما يرجع النت"
    }

    /// The live screen, once, the first time a send failed.
    static func toast(_ kind: PendingOutingAction.Kind) -> String {
        switch kind {
        case .leave: return "نكمل المغادرة لما يرجع النت"
        case .cancelSOS: return "نكمل إرسال «أنا بخير» لما يرجع النت"
        case .setRally, .clearRally: return "نكمل إرسال نقطة التجمع لما يرجع النت"
        case .hide: return "موقعك مخفي عندك، ونبلّغ الخادم لما يرجع النت"
        case .coLeader, .removeMember: return "نكمل التغيير لما يرجع النت"
        case .note: return "نكمل إرسال رسالتك لما يرجع النت"
        case .endOuting: return "تعذّر إبلاغ الخادم، نعيد المحاولة"
        }
    }
}
