import Foundation

// MARK: - Wire content (inside the AES-GCM box)

/// A position as it travels phone to phone. `at` is the ORIGINAL fix time on
/// the subject's own phone (kept for ordering and display); `age` is how old
/// the fix was when this frame left the last phone, measured on that phone's
/// clock. Freshness is decided from `age`, so a phone whose clock is off can
/// neither make an old fix look live nor a live one look old.
struct MeshFix: Codable, Equatable {
    var u: String
    var lat: Double
    var lng: Double
    var acc: Double?
    var hdg: Double?
    var spd: Double?
    var at: Double
    var age: Double
    /// 0 = the subject's own phone sent it to us; each relay adds one; never above 3.
    var hops: Int
}

/// Something a member did, relayed like positions (deduplicated by `id`).
struct MeshEvent: Codable, Equatable {
    enum Kind: String, Codable { case note, sos, sosClear, stuck, stuckClear, stop }

    var id: String
    var u: String
    var k: Kind
    /// Note text (empty = note cleared) or the stuck note. ≤ 80.
    var text: String?
    /// SOS: the fix it carries, if the SOS was raised with one.
    var lat: Double?
    var lng: Double?
    var acc: Double?
    /// SOS fix time on the subject's clock (same clock as `at`).
    var fixAt: Double?
    var at: Double
    var age: Double
    var hops: Int
}

struct MeshPayload: Codable, Equatable {
    var pos: [MeshFix] = []
    var ev: [MeshEvent] = []

    static let maxFixes = 32
    static let maxEvents = 32
    static let maxText = 80

    var isWithinLimits: Bool {
        guard pos.count <= Self.maxFixes, ev.count <= Self.maxEvents else { return false }
        for f in pos where f.u.count > 64 || !f.lat.isFinite || !f.lng.isFinite || !f.age.isFinite || !f.at.isFinite { return false }
        for e in ev where e.id.count > 64 || e.u.count > 64 || (e.text?.count ?? 0) > Self.maxText || !e.age.isFinite || !e.at.isFinite { return false }
        return true
    }
}

// MARK: - What this phone knows from nearby phones

/// The pure state of the nearby link: what was heard, what to pass on, and
/// how it shows over the server's picture. Every rule here is unit-tested.
struct MeshStore: Equatable {
    static let maxHops = 3
    /// A position older than this is neither shown from the mesh nor relayed.
    static let maxFixAgeMs = 30 * 60_000.0
    /// Events are re-sent this long so a car that comes in range later still gets them.
    static let eventRelayMs = 30 * 60_000.0
    /// Kept (for display and dedup) this long — the server's SOS lifetime.
    static let eventKeepMs = 60 * 60_000.0
    /// "Directly connected": a member's own phone was heard this recently.
    static let directWindowMs = 30_000.0
    static let maxSkewMs = 2 * 60_000.0

    struct KnownFix: Equatable {
        var fix: MeshFix
        /// This device's clock time of the fix (received − age).
        var deviceAtMs: Double
    }

    struct KnownEvent: Equatable {
        var event: MeshEvent
        var deviceAtMs: Double
        /// SOS fix time on this device's clock.
        var fixDeviceAtMs: Double?
    }

    let me: String
    var members: Set<String>
    private(set) var fixes: [String: KnownFix] = [:]
    private(set) var events: [String: KnownEvent] = [:]
    /// Member → device time their phone was last heard directly.
    private(set) var direct: [String: Double] = [:]
    /// Member → subject-clock time they stopped sharing; older fixes are refused.
    private(set) var stoppedAt: [String: Double] = [:]

    init(me: String, members: Set<String>) {
        self.me = me
        self.members = members
    }

    private func isMember(_ u: String) -> Bool { members.contains(u) }

    // MARK: in

    /// Take in a frame that already authenticated as coming from `from`.
    /// Returns the events that are new to this phone.
    @discardableResult
    mutating func ingest(_ p: MeshPayload, from: String, nowMs: Double) -> [MeshEvent] {
        guard isMember(from), from != me else { return [] }
        direct[from] = nowMs
        for f in p.pos { accept(f, from: from, nowMs: nowMs) }
        var fresh: [MeshEvent] = []
        for e in p.ev where accept(e, from: from, nowMs: nowMs) { fresh.append(e) }
        return fresh
    }

    /// Hop rules: a hop-0 fix must be the sender's own; a relayed one never is.
    static func hopsValid(subject: String, from: String, hops: Int) -> Bool {
        guard hops >= 0, hops <= maxHops else { return false }
        return hops == 0 ? subject == from : subject != from
    }

    private mutating func accept(_ f: MeshFix, from: String, nowMs: Double) {
        guard isMember(f.u), f.u != me, Self.hopsValid(subject: f.u, from: from, hops: f.hops) else { return }
        guard (-90...90).contains(f.lat), (-180...180).contains(f.lng), f.age >= 0, f.age <= Self.maxFixAgeMs else { return }
        if let acc = f.acc, !(acc >= 0 && acc <= ServerRules.maxAccuracyM) { return }
        if let s = stoppedAt[f.u], f.at <= s { return }
        if let old = fixes[f.u] {
            /* Same subject, same clock: newer wins; for the same fix, the shorter path. */
            if f.at < old.fix.at { return }
            if f.at == old.fix.at && f.hops >= old.fix.hops { return }
        }
        fixes[f.u] = KnownFix(fix: f, deviceAtMs: nowMs - f.age)
    }

    private mutating func accept(_ e: MeshEvent, from: String, nowMs: Double) -> Bool {
        guard isMember(e.u), Self.hopsValid(subject: e.u, from: from, hops: e.hops) else { return false }
        guard e.age >= 0, e.age <= Self.eventKeepMs, events[e.id] == nil else { return false }
        if e.k == .sos, let la = e.lat, let ln = e.lng, !((-90...90).contains(la) && (-180...180).contains(ln)) { return false }
        let at = nowMs - e.age
        var fixAt: Double?
        if let fa = e.fixAt, fa <= e.at { fixAt = at - (e.at - fa) }
        events[e.id] = KnownEvent(event: e, deviceAtMs: at, fixDeviceAtMs: fixAt)
        if e.k == .stop {
            stoppedAt[e.u] = max(stoppedAt[e.u] ?? e.at, e.at)
            if let f = fixes[e.u], f.fix.at <= e.at { fixes[e.u] = nil }
        }
        /* Their own phone says so: it's their latest word, whatever the order of arrival. */
        return e.u != me
    }

    // MARK: my own

    mutating func addOwn(_ k: MeshEvent.Kind, text: String? = nil, sosFix: DeviceFix? = nil, nowMs: Double, id: String = UUID().uuidString) -> MeshEvent {
        let e = MeshEvent(id: id, u: me, k: k, text: text.map { String($0.prefix(MeshPayload.maxText)) },
                          lat: sosFix?.lat, lng: sosFix?.lng, acc: sosFix?.accuracy, fixAt: sosFix?.atMs,
                          at: nowMs, age: 0, hops: 0)
        events[id] = KnownEvent(event: e, deviceAtMs: nowMs, fixDeviceAtMs: sosFix?.atMs)
        return e
    }

    /// The server announced a member cleared their SOS: drop our copy of it.
    mutating func serverClearedSOS(_ u: String) {
        for (id, k) in events where k.event.u == u && k.event.k == .sos { events[id] = nil }
    }

    // MARK: out

    /// What this phone sends: its own fix (hop 0) and everything it may pass on.
    func outgoing(myFix: DeviceFix?, nowMs: Double) -> MeshPayload {
        var p = MeshPayload()
        if let f = myFix, nowMs - f.atMs <= Self.maxFixAgeMs, nowMs - f.atMs >= -Self.maxSkewMs {
            p.pos.append(MeshFix(u: me, lat: f.lat, lng: f.lng, acc: f.accuracy, hdg: f.heading, spd: f.speed,
                                 at: f.atMs, age: max(0, nowMs - f.atMs), hops: 0))
        }
        let relays = fixes.values
            .filter { $0.fix.hops < Self.maxHops && nowMs - $0.deviceAtMs <= Self.maxFixAgeMs }
            .sorted { $0.deviceAtMs > $1.deviceAtMs }
            .prefix(MeshPayload.maxFixes - p.pos.count)
        for k in relays {
            var f = k.fix
            f.hops += 1
            f.age = max(0, nowMs - k.deviceAtMs)
            p.pos.append(f)
        }
        let evs = events.values
            .filter { ($0.event.u == me || $0.event.hops < Self.maxHops) && nowMs - $0.deviceAtMs <= Self.eventRelayMs }
            .sorted { $0.deviceAtMs > $1.deviceAtMs }
            .prefix(MeshPayload.maxEvents)
        for k in evs {
            var e = k.event
            if e.u != me { e.hops += 1 }
            e.age = max(0, nowMs - k.deviceAtMs)
            p.ev.append(e)
        }
        return p
    }

    mutating func prune(nowMs: Double) {
        fixes = fixes.filter { nowMs - $0.value.deviceAtMs <= Self.maxFixAgeMs && members.contains($0.key) }
        events = events.filter { nowMs - $0.value.deviceAtMs <= Self.eventKeepMs }
        direct = direct.filter { nowMs - $0.value <= Self.directWindowMs * 4 }
    }

    /// «متصل مباشرة بـ …»: members whose own phone we heard in the last 30 s.
    func directCount(nowMs: Double) -> Int {
        direct.filter { members.contains($0.key) && nowMs - $0.value <= Self.directWindowMs }.count
    }

    /// The latest event of these kinds for a member (by its real time).
    func latest(_ u: String, _ kinds: Set<MeshEvent.Kind>) -> KnownEvent? {
        events.values.filter { $0.event.u == u && kinds.contains($0.event.k) }.max { $0.deviceAtMs < $1.deviceAtMs }
    }

    // MARK: over the server's picture

    /// The server's picture with what nearby phones said laid over it, newest
    /// wins. Positions keep their real time (so `Policy.freshness` greys an old
    /// relayed one exactly like an old server one). Returns the members whose
    /// shown position came over the nearby link.
    func overlay(_ base: OutingView, deviceNow: Date = Date()) -> (view: OutingView, viaNearby: Set<String>) {
        var v = base
        var via: Set<String> = []
        guard v.status != .ended else { return (v, via) }
        let offset = v.clockOffsetMs
        func serverISO(_ deviceMs: Double) -> String { ISODate.string(Date(timeIntervalSince1970: (deviceMs + offset) / 1000)) }
        func deviceMs(_ iso: String?) -> Double? { ISODate.parse(iso).map { $0.timeIntervalSince1970 * 1000 - offset } }

        if v.status == .active {
            for (u, k) in fixes where u != v.myId && v.members[u] != nil {
                if let p = v.positions[u], let server = deviceMs(p.recorded_at), server >= k.deviceAtMs { continue }
                let f = k.fix
                v.positions[u] = Position(user_id: u, lat: f.lat, lng: f.lng, accuracy: f.acc, heading: f.hdg, speed: f.spd,
                                          mode: nil, recorded_at: serverISO(k.deviceAtMs), received_at: nil)
                /* Their phone was sharing (its gate was open) when it sent this. */
                v.members[u]?.sharing = true
                if (deviceMs(v.members[u]?.last_seen_at) ?? 0) < k.deviceAtMs { v.members[u]?.last_seen_at = serverISO(k.deviceAtMs) }
                via.insert(u)
            }
        }
        for u in v.members.keys {
            if let n = latest(u, [.note]), n.deviceAtMs > (deviceMs(v.members[u]?.note?.at) ?? 0) + 1_000 {
                let t = n.event.text ?? ""
                v.members[u]?.note = t.isEmpty ? nil : MemberNote(text: t, at: serverISO(n.deviceAtMs))
            }
            if let s = latest(u, [.sos, .sosClear]), s.deviceAtMs > (deviceMs(v.members[u]?.sos?.at) ?? 0) + 1_000 {
                if s.event.k == .sosClear {
                    v.members[u]?.sos = nil
                } else {
                    let e = s.event
                    let fix = (e.lat != nil && e.lng != nil) ? SosFix(lat: e.lat!, lng: e.lng!, accuracy: e.acc, recorded_at: serverISO(s.fixDeviceAtMs ?? s.deviceAtMs)) : nil
                    v.members[u]?.sos = SosInfo(at: serverISO(s.deviceAtMs), fix: fix)
                }
            }
        }
        return (v, via)
    }
}

/// When the nearby link runs. Never without the same consent as sharing
/// (`SendGate.allowsPosition`); then only when it is needed: this phone's
/// server link is down, or a friend has dropped off the server. Hysteresis so
/// a flaky link does not toggle the radios every second.
struct MeshActivation: Equatable {
    static let startAfterMs = 8_000.0
    static let stopAfterMs = 90_000.0

    private(set) var on = false
    private var needSince: Double?
    private var fineSince: Double?

    mutating func update(gateOpen: Bool, linkHealthy: Bool, friendLost: Bool, forced: Bool = false, nowMs: Double) -> Bool {
        guard gateOpen else {
            on = false
            needSince = nil
            fineSince = nil
            return false
        }
        if forced { on = true; return true }
        if !linkHealthy || friendLost {
            fineSince = nil
            needSince = needSince ?? nowMs
            if nowMs - (needSince ?? nowMs) >= Self.startAfterMs { on = true }
        } else {
            needSince = nil
            if on {
                fineSince = fineSince ?? nowMs
                if nowMs - (fineSince ?? nowMs) >= Self.stopAfterMs { on = false; fineSince = nil }
            }
        }
        return on
    }
}
