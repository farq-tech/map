import Foundation

// The trip's guidance: turn by turn to the trip's NEXT target — the next planned stop not
// yet reached, else the destination — until arrival; a stop reached moves on to the next
// one; the destination reached says «وصلتوا» and stops.
//
// Who starts it (the owner's rule): «أمير الرحلة» starts it for everyone («ابدأ التوجيه
// للكل», a group command over the member-note channel, like «ارجعوا لنقطة التجمع») or
// only for himself («لي فقط»). Everyone else starts it only for themselves; a group
// command from anyone who is not the current leader is ignored. Members who join later,
// or open the app again, resume the leader's last command (or their own start).
//
// Per device: «أوقف التوجيه» / «استأنف» and the setting «ابدأ التوجيه تلقائيًا مع الرحلة»
// (accept the leader's «للكل» without asking) only change THIS phone. The state is kept on
// the phone (UserDefaults, like `TripStore`); the only thing sent is the leader's note.
//
// Pure decisions (unit-tested in Tests/TripAutoNavTests.swift); the live screen applies them
// (`LiveOutingController+AutoNav.swift`).

/// «ابدأ التوجيه تلقائيًا مع الرحلة» (this device; on by default).
enum TripAutoNavPrefs {
    static let enabledKey = "sary.nav.autoTrip.v1"

    static func enabled(_ d: UserDefaults = .standard) -> Bool {
        d.object(forKey: enabledKey) as? Bool ?? true
    }

    static func set(_ on: Bool, _ d: UserDefaults = .standard) {
        d.set(on, forKey: enabledKey)
    }
}

/// What this phone remembers of one outing's automatic guidance.
struct TripAutoNavState: Codable, Equatable {
    /// The trip's guidance is on for this phone (the leader's «للكل» accepted, or started by me).
    var active = false
    /// The leader's group command already handled (its note time), so it is acted on once.
    var broadcastAt: String?
    /// The leader's «للكل» arrived while the setting is off: «أمير الرحلة بدأ التوجيه · ابدأ».
    var offered = false
    /// Planned stops already reached (`TripAutoNav.key`), in the order reached.
    var reachedStops: [String] = []
    /// «أوقف التوجيه» on this phone (until «استأنف»).
    var paused = false
    /// Guidance reached the destination: never restart it for this outing.
    var arrived = false

    init() {}

    /* Tolerant: a state saved by an older build of this branch still decodes. */
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        active = (try? c.decodeIfPresent(Bool.self, forKey: .active)) ?? false
        broadcastAt = try? c.decodeIfPresent(String.self, forKey: .broadcastAt)
        offered = (try? c.decodeIfPresent(Bool.self, forKey: .offered)) ?? false
        reachedStops = (try? c.decodeIfPresent([String].self, forKey: .reachedStops)) ?? []
        paused = (try? c.decodeIfPresent(Bool.self, forKey: .paused)) ?? false
        arrived = (try? c.decodeIfPresent(Bool.self, forKey: .arrived)) ?? false
    }

    /// One dictionary per device (outing id → state), like `TripStore`; wiped with the account.
    static let storeKey = "sary.nav.autoTrip.states.v1"

    static func load(_ outingId: String, _ d: UserDefaults = .standard) -> TripAutoNavState {
        all(d)[outingId] ?? .init()
    }

    func save(_ outingId: String, _ d: UserDefaults = .standard) {
        var a = Self.all(d)
        a[outingId] = self
        if let data = try? JSONEncoder().encode(a) { d.set(data, forKey: Self.storeKey) }
    }

    private static func all(_ d: UserDefaults) -> [String: TripAutoNavState] {
        d.data(forKey: storeKey).flatMap { try? JSONDecoder().decode([String: TripAutoNavState].self, from: $0) } ?? [:]
    }
}

enum TripAutoNav {
    /// Driving past a planned stop this close counts as having reached it (even if guidance
    /// was paused or the route's own arrival did not fire).
    static let stopPassM = 80.0
    /// A fix vaguer than this cannot tell whether we passed a stop.
    static let maxAccuracyM = 60.0
    /// After arriving at a stop, show «وصلتوا» this long before guiding on to the next one.
    static let stopDwellS = 3.0

    /// A stable id for a stop (its position, ~1 m): survives renames and a relaunch.
    static func key(_ s: OutingDestination) -> String {
        String(format: "%.5f,%.5f", s.lat, s.lng)
    }

    static func target(stop s: OutingDestination, index: Int) -> NavTarget {
        NavTarget(source: .tripStop, name: s.name.isEmpty ? "المحطة \(SaryFormat.number(index + 1))" : s.name, position: LngLat(lng: s.lng, lat: s.lat))
    }

    /// The trip's next target: the first planned stop not yet reached, else the destination.
    static func nextTarget(destination: OutingDestination?, stops: [OutingDestination], reached: [String]) -> NavTarget? {
        guard let d = destination else { return nil }
        let done = Set(reached)
        if let i = stops.firstIndex(where: { !done.contains(key($0)) }) { return target(stop: stops[i], index: i) }
        guard case let .success(t) = NavTargets.destination(d) else { return nil }
        return t
    }

    /// Stops I am at (or drove through) now are reached. A vague fix changes nothing.
    static func passStops(_ s: TripAutoNavState, stops: [OutingDestination], me: LngLat, accuracy: Double?) -> TripAutoNavState {
        if let a = accuracy, a > maxAccuracyM { return s }
        var out = s
        for stop in stops where !out.reachedStops.contains(key(stop)) {
            if Vehicle.distanceMeters(me, LngLat(lng: stop.lng, lat: stop.lat)) <= stopPassM { out.reachedStops.append(key(stop)) }
        }
        return out
    }

    /// Guidance arrived at `t`: a stop is reached; the destination ends the trip's guidance.
    static func arrived(_ s: TripAutoNavState, at t: NavTarget, stops: [OutingDestination]) -> TripAutoNavState {
        var out = s
        switch t.source {
        case .tripStop:
            if let stop = stops.first(where: { Vehicle.distanceMeters(LngLat(lng: $0.lng, lat: $0.lat), t.position) < 1 }), !out.reachedStops.contains(key(stop)) {
                out.reachedStops.append(key(stop))
            }
        case .destination:
            out.arrived = true
        default:
            break
        }
        return out
    }

    struct Input: Equatable {
        var state = TripAutoNavState()
        var status: OutingStatus?
        /// The screen is closed for this outing (left, removed, ended).
        var closed = false
        var destination: OutingDestination?
        var stops: [OutingDestination] = []
        /// The trip says I arrived (detected at the destination, or «وصلنا»).
        var tripArrived = false
        /// A GPS fix to route from.
        var hasFix = false
        var navPhase: NavPhase = .idle
        /// The running navigation was started by the trip (not by a person's tap).
        var navAuto = false
        var navTarget: NavTarget?
        /// Seconds since the running navigation arrived.
        var arrivedAgoS: Double?
    }

    enum Decision: Equatable {
        case none
        /// Guide to this target now (nothing is running).
        case start(NavTarget)
        /// The trip's target changed under a running automatic navigation (a stop added
        /// or reached, the destination moved): guide to the new one instead.
        case retarget(NavTarget)
        /// I arrived (the trip detected it): end the guidance on «وصلتوا».
        case finish
        /// The outing ended or closed: stop the automatic guidance.
        case stop
    }

    static func decide(_ i: Input) -> Decision {
        let running = i.navPhase == .guiding || i.navPhase == .offRoad || i.navPhase == .planning
        if i.closed || i.status == .ended {
            return i.navAuto && i.navPhase != .idle && i.navPhase != .arrived ? .stop : .none
        }
        /* Only once started on this phone: by the leader's «للكل» or by me («لي فقط» / «ابدأ التوجيه»). */
        guard i.state.active, !i.state.paused, i.status == .active, i.destination != nil else { return .none }
        if i.state.arrived || i.tripArrived {
            return i.navAuto && (i.navPhase == .guiding || i.navPhase == .offRoad) ? .finish : .none
        }
        guard let next = nextTarget(destination: i.destination, stops: i.stops, reached: i.state.reachedStops) else { return .none }
        switch i.navPhase {
        case .idle:
            return i.hasFix ? .start(next) : .none
        case .planning, .guiding, .offRoad:
            /* A person's own navigation («روح له», a searched point) is theirs: never taken over. */
            guard i.navAuto, running, let t = i.navTarget else { return .none }
            return same(t, next) ? .none : (i.hasFix ? .retarget(next) : .none)
        case .arrived:
            /* At a stop: «وصلتوا» for a moment, then on to the next target. */
            guard i.navAuto, i.hasFix, let t = i.navTarget, t.source == .tripStop, !same(t, next) else { return .none }
            return (i.arrivedAgoS ?? 0) >= stopDwellS ? .start(next) : .none
        }
    }

    /// Guidance would start (or move on) right now if only my fix were fresh: the wait is shown
    /// («ننتظر موقعك…») instead of doing nothing in silence.
    static func waitsForFix(_ i: Input) -> Bool {
        guard !i.hasFix else { return false }
        var fresh = i
        fresh.hasFix = true
        switch decide(fresh) {
        case .start, .retarget: return true
        default: return false
        }
    }

    static func same(_ a: NavTarget, _ b: NavTarget) -> Bool {
        a.source == b.source && Vehicle.distanceMeters(a.position, b.position) < 1
    }

    /// The one line said when automatic guidance starts («نبدأ التوجيه إلى …»).
    static func intro(_ t: NavTarget, resumed: Bool) -> String {
        resumed ? "نكمل إلى \(t.name)" : "نبدأ التوجيه إلى \(t.name)"
    }
}

/// «ابدأ التوجيه للكل»: the leader's group command, carried as his member note (the same
/// channel as «ارجعوا لنقطة التجمع»: server note + nearby link, no new endpoint).
/// It carries no route and no position: each phone guides from where IT is to the trip's
/// next target as IT has reached it.
enum NavBroadcast {
    static let prefix = "🧭 التوجيه للكل"
    /// The deputy («نائب الأمير») may also start guidance for everyone. The owner said
    /// «كأمير»: leader only.
    static let deputyMayBroadcast = false

    /// «🧭 التوجيه للكل: روضة الثمامة» (≤ the note limit).
    static func text(targetName: String) -> String {
        String("\(prefix): \(targetName)".prefix(ServerRules.noteMax))
    }

    static func isBroadcast(_ text: String?) -> Bool {
        text?.trimmingCharacters(in: .whitespaces).hasPrefix(prefix) == true
    }

    static func targetName(_ text: String) -> String? {
        guard isBroadcast(text), let r = text.range(of: ":") else { return nil }
        let n = text[r.upperBound...].trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? nil : n
    }

    /// «للكل؟» only means something with somebody else in the trip: alone (or with nobody
    /// joined yet) the leader is simply guided, never asked (UI-AUDIT ١-هـ).
    static func asksForAll(memberCount: Int) -> Bool { memberCount > 1 }

    /// May this sender start guidance for everyone? Verified on receipt, on every phone.
    static func mayBroadcast(senderId: String, ownerId: String, senderIsDeputy: Bool) -> Bool {
        senderId == ownerId || (deputyMayBroadcast && senderIsDeputy)
    }

    enum Receipt: Equatable {
        /// Nothing new.
        case none
        /// Not from the leader: ignored (never starts anything).
        case ignored
        /// Start now (the setting accepts it without asking).
        case start
        /// The setting is off: offer it («أمير الرحلة بدأ التوجيه · ابدأ»).
        case offer
    }

    /// A note that is a group command reached this phone.
    static func receive(_ s: inout TripAutoNavState, text: String, at: String, senderId: String, ownerId: String,
                        senderIsDeputy: Bool, myId: String, autoAccept: Bool) -> Receipt {
        guard isBroadcast(text), senderId != myId, s.broadcastAt != at else { return .none }
        guard mayBroadcast(senderId: senderId, ownerId: ownerId, senderIsDeputy: senderIsDeputy) else { return .ignored }
        s.broadcastAt = at
        guard !s.arrived else { return .none }
        if autoAccept {
            s.active = true
            s.paused = false
            s.offered = false
            return .start
        }
        s.offered = true
        return .offer
    }
}
