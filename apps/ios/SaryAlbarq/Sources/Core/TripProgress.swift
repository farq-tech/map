import Foundation

// «رحلة كاملة»: every outing is a trip with a START and an END — «لا يوجد رحلة من غير نهاية».
//
//   needsDestination → notStarted → waitingFirstFix → underway → arrived → ended
//
// Pure value types (no UI, no network), so every rule here is unit-tested in
// Tests/TripProgressTests.swift. The live screen feeds it (`TripTracker`), the
// sheet / drive mode / Live Activity / CarPlay only show what it decides.
//
// PRIVACY: the start point, my arrival, the arrival order and every derived
// number stay on THIS device (`TripStore`, UserDefaults). Nothing here is sent;
// the only thing that ever leaves is what «شارك ملخصي» already sends, on purpose.

// MARK: - phase

enum TripPhase: Equatable {
    /// The outing has no destination: the leader is asked «حدّد الوجهة», members see «بانتظار الوجهة».
    case needsDestination
    /// A destination, but the outing has not started yet.
    case notStarted
    /// Started; this phone has no live fix since then, so no start point yet.
    case waitingFirstFix
    /// Driving: start point set, not arrived.
    case underway
    /// I arrived (detected or «وصلنا»).
    case arrived(at: Date)
    /// The outing ended.
    case ended
}

/// Where (and when) the trip started for me: my first live fix after the outing started.
struct TripStartPoint: Codable, Equatable {
    var lat: Double
    var lng: Double
    /// Device time of that fix, ms since 1970.
    var atMs: Double

    var position: LngLat { LngLat(lng: lng, lat: lat) }
}

// MARK: - arrival detection

/// «وصلت»: within `radiusM` of the destination for at least `dwellS` seconds.
///
/// GPS jitter at the boundary must neither fake an arrival nor keep postponing a real
/// one, so leaving needs `exitRadiusM` (hysteresis), a fix too vague to tell is ignored,
/// and a parked car that stops reporting fixes still arrives (`evaluate(nowMs:)` runs on
/// a clock, not only on fixes).
struct ArrivalDetector: Codable, Equatable {
    static let radiusM = 150.0
    /// Once inside, only farther than this counts as having left.
    static let exitRadiusM = 220.0
    static let dwellS = 30.0
    /// A fix vaguer than this can't tell 150 m from 400 m: ignored either way.
    static let maxAccuracyM = 100.0
    /// The last inside fix must be at most this old for the clock to finish the dwell.
    static let maxSilenceS = 180.0

    var insideSinceMs: Double?
    var lastFixMs: Double?
    var lastDistanceM: Double?
    private(set) var arrivedAtMs: Double?

    var arrived: Bool { arrivedAtMs != nil }

    /// One fix's distance to the destination. True when this fix completes the arrival.
    @discardableResult
    mutating func ingest(distanceM: Double, accuracy: Double?, atMs: Double) -> Bool {
        guard arrivedAtMs == nil else { return false }
        guard distanceM.isFinite, distanceM >= 0 else { return false }
        if let a = accuracy, a > Self.maxAccuracyM { return false }
        if let t = lastFixMs, atMs <= t { return false }
        lastFixMs = atMs
        lastDistanceM = distanceM
        if let since = insideSinceMs {
            if distanceM > Self.exitRadiusM {
                insideSinceMs = nil
                return false
            }
            return finish(since: since, nowMs: atMs)
        }
        guard distanceM <= Self.radiusM else { return false }
        insideSinceMs = atMs
        return false
    }

    /// The clock: a car parked inside reports no new fix, yet it has arrived after 30 s.
    @discardableResult
    mutating func evaluate(nowMs: Double) -> Bool {
        guard arrivedAtMs == nil, let since = insideSinceMs, let last = lastFixMs else { return false }
        guard (nowMs - last) / 1000 <= Self.maxSilenceS else { return false }
        return finish(since: since, nowMs: nowMs)
    }

    /// «وصلنا» tapped.
    mutating func markArrived(atMs: Double) {
        if arrivedAtMs == nil { arrivedAtMs = atMs }
    }

    private mutating func finish(since: Double, nowMs: Double) -> Bool {
        guard (nowMs - since) / 1000 >= Self.dwellS else { return false }
        arrivedAtMs = since
        return true
    }
}

// MARK: - the trip on this device

/// Everything this phone remembers about one outing's trip (UserDefaults, never sent).
struct TripRecord: Codable, Equatable {
    var start: TripStartPoint?
    /// The group's start point = the leader's start (as this phone saw it).
    var groupStart: TripStartPoint?
    var me = ArrivalDetector()
    var arrivedManually = false
    var endedAtMs: Double?
    /// The destination this device associated with its persisted arrival detector. Old records
    /// did not store this, so their arrival state is discarded once a destination is first bound.
    var arrivalDestinationLat: Double?
    var arrivalDestinationLng: Double?
    /// Members (me included) and when they arrived, as this phone saw it.
    var arrivals: [String: Double] = [:]
    /// Friends' detectors (fed only from their fresh positions).
    var friends: [String: ArrivalDetector] = [:]

    /// Keep arrival state scoped to one destination. A previous stop must never make a newly
    /// selected destination look reached after the app restores its per-outing record.
    mutating func bindArrivalDestination(_ destination: LngLat) {
        let changed: Bool
        if let lat = arrivalDestinationLat, let lng = arrivalDestinationLng {
            changed = Vehicle.distanceMeters(LngLat(lng: lng, lat: lat), destination) > 5
        } else {
            // Migration from records written before the target was persisted: don't trust an
            // unscoped arrival (or an unfinished dwell) against today's destination.
            changed = true
        }
        if changed {
            me = ArrivalDetector()
            arrivedManually = false
            arrivals.removeAll()
            friends.removeAll()
        }
        arrivalDestinationLat = destination.lat
        arrivalDestinationLng = destination.lng
    }

    enum Event: Equatable {
        case started(TripStartPoint)
        case arrived(atMs: Double, manual: Bool)
        case memberArrived(String, atMs: Double)
    }

    /// «ابدأ المشوار»: a new leg inside the same outing. The start points stay (they are the
    /// outing's); my arrival and what this phone saw of the others' start over for the new destination.
    mutating func beginLeg() {
        me = ArrivalDetector()
        arrivedManually = false
        arrivals = [:]
        friends = [:]
    }

    func phase(hasDestination: Bool, status: OutingStatus?) -> TripPhase {
        if status == .ended || endedAtMs != nil { return .ended }
        if let a = me.arrivedAtMs { return .arrived(at: Date(timeIntervalSince1970: a / 1000)) }
        guard hasDestination else { return .needsDestination }
        guard let status, status != .created else { return .notStarted }
        return start == nil ? .waitingFirstFix : .underway
    }

    /// One of MY fixes. `outingStartedMs`: when the outing started (device clock); a fix
    /// from before that is not the trip's start. `nowMs` decides "live" (≤ 30 s old).
    mutating func ingestMine(_ f: DeviceFix, myId: String, destination: LngLat?, status: OutingStatus?, outingStartedMs: Double?, nowMs: Double) -> [Event] {
        guard status == .active || status == .paused, endedAtMs == nil else { return [] }
        guard nowMs - f.atMs <= TripMath.liveFixMaxAgeMs, (f.accuracy ?? 0) <= ArrivalDetector.maxAccuracyM else { return [] }
        var out: [Event] = []
        if start == nil, f.atMs >= (outingStartedMs ?? -.infinity) - 1000 {
            let s = TripStartPoint(lat: f.lat, lng: f.lng, atMs: f.atMs)
            start = s
            out.append(.started(s))
        }
        guard let d = destination else { return out }
        let dist = Vehicle.distanceMeters(LngLat(lng: f.lng, lat: f.lat), d)
        if me.ingest(distanceM: dist, accuracy: f.accuracy, atMs: f.atMs), let at = me.arrivedAtMs {
            out.append(arrivedMe(myId, at, manual: false))
        }
        return out
    }

    /// The clock tick (a parked car sends no fix).
    mutating func tick(myId: String, nowMs: Double) -> [Event] {
        guard endedAtMs == nil else { return [] }
        if me.evaluate(nowMs: nowMs), let at = me.arrivedAtMs { return [arrivedMe(myId, at, manual: false)] }
        return []
    }

    /// «وصلنا».
    mutating func markArrived(myId: String, nowMs: Double) -> [Event] {
        guard !me.arrived, endedAtMs == nil else { return [] }
        me.markArrived(atMs: nowMs)
        arrivedManually = true
        return [arrivedMe(myId, nowMs, manual: true)]
    }

    private mutating func arrivedMe(_ myId: String, _ at: Double, manual: Bool) -> Event {
        if arrivals[myId] == nil { arrivals[myId] = at }
        return .arrived(atMs: at, manual: manual)
    }

    /// A friend's position. Only a LIVE one counts (`live`): an old fix never says «وصل».
    mutating func ingestFriend(_ id: String, lat: Double, lng: Double, accuracy: Double?, atMs: Double, live: Bool, destination: LngLat?, nowMs: Double) -> [Event] {
        guard endedAtMs == nil, arrivals[id] == nil, live, let d = destination else { return [] }
        var det = friends[id] ?? ArrivalDetector()
        let dist = Vehicle.distanceMeters(LngLat(lng: lng, lat: lat), d)
        var done = det.ingest(distanceM: dist, accuracy: accuracy, atMs: atMs)
        if !done { done = det.evaluate(nowMs: nowMs) }
        friends[id] = det
        guard done, let at = det.arrivedAtMs else { return [] }
        arrivals[id] = at
        return [.memberArrived(id, atMs: at)]
    }

    mutating func ended(nowMs: Double) {
        if endedAtMs == nil { endedAtMs = nowMs }
    }
}

/// Per-outing trip records (this device only; cleared on sign-out / account deletion).
enum TripStore {
    static let key = "sary.trip.records.v1"

    static func load(_ outingId: String, defaults: UserDefaults = .standard) -> TripRecord? {
        all(defaults)[outingId]
    }

    static func save(_ outingId: String, _ r: TripRecord, defaults: UserDefaults = .standard) {
        var a = all(defaults)
        a[outingId] = r
        if let d = try? JSONEncoder().encode(a) { defaults.set(d, forKey: key) }
    }

    static func forgetAll(defaults: UserDefaults = .standard) { defaults.removeObject(forKey: key) }

    private static func all(_ defaults: UserDefaults) -> [String: TripRecord] {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([String: TripRecord].self, from: $0) } ?? [:]
    }
}

/// «طريق العودة» as a new trip: which outing a return trip came back from (this device only).
enum ReturnTripStore {
    static let key = "sary.trip.returnOf.v1"

    static func origin(of outingId: String, defaults: UserDefaults = .standard) -> String? {
        (defaults.dictionary(forKey: key) as? [String: String])?[outingId]
    }

    static func link(_ newId: String, returnsFrom oldId: String, defaults: UserDefaults = .standard) {
        var d = (defaults.dictionary(forKey: key) as? [String: String]) ?? [:]
        d[newId] = oldId
        defaults.set(d, forKey: key)
    }

    static func forgetAll(defaults: UserDefaults = .standard) { defaults.removeObject(forKey: key) }
}

// MARK: - remaining distance

/// Where «باقي» comes from, best first.
enum RemainingSource: Equatable {
    /// Along the active guidance route (turn-by-turn to the destination).
    case navigation
    /// Along the leader's planned route («تخطيط الطلعة»).
    case plannedRoute
    /// A straight line: said as «تقريبي».
    case straightLine

    var approximate: Bool { self == .straightLine }
}

struct RemainingDistance: Equatable {
    var meters: Double
    var source: RemainingSource
    /// From the navigation itself, when guiding.
    var navETA: Date?
}

enum TripMath {
    /// A fix of mine older than this is not «now»: no remaining / ETA from it.
    static let liveFixMaxAgeMs = 30_000.0
    /// The remaining/ETA keep showing up to this age of my fix (screen locked, parked); then «آخر موقع قبل …».
    static let myFixShowMaxAgeMs = 120_000.0
    /// Navigation counts for the trip only when its target is the destination (within this).
    static let navTargetMatchM = 200.0
    /// Farther than this from the planned route, the route says nothing about my way.
    static let planRouteMaxOffM = 3_000.0
    /// ETA speed when I have no moving average yet.
    static let defaultKmh = ArrivalEstimate.defaultKmh
    static let minAverageKmh = 5.0

    /// Navigation → planned route → straight line.
    static func remaining(me: LngLat, destination: LngLat,
                          navRemainingM: Double?, navTarget: LngLat?, navGuiding: Bool, navETA: Date? = nil,
                          planRoute: [LngLat]) -> RemainingDistance {
        if navGuiding, let m = navRemainingM, m.isFinite, m >= 0, let t = navTarget,
           Vehicle.distanceMeters(t, destination) <= navTargetMatchM {
            return RemainingDistance(meters: m, source: .navigation, navETA: navETA)
        }
        if planRoute.count >= 2, let n = PlanGeo.nearest(me, on: planRoute), n.distanceM <= planRouteMaxOffM {
            /* Get onto the route, follow it, then whatever is left from its end to the destination. */
            let tail = Vehicle.distanceMeters(planRoute[planRoute.count - 1], destination)
            return RemainingDistance(meters: n.distanceM + n.remainingM + tail, source: .plannedRoute)
        }
        return RemainingDistance(meters: Vehicle.distanceMeters(me, destination), source: .straightLine)
    }

    /// «قطعنا ٦٢٪»: driven ÷ (driven + remaining). Detours don't push it backwards past
    /// what is already driven; arrived is 100 %.
    static func progress(drivenM: Double, remainingM: Double?, arrived: Bool) -> Double? {
        if arrived { return 1 }
        guard let r = remainingM, r.isFinite, drivenM.isFinite else { return nil }
        let d = max(0, drivenM), rem = max(0, r)
        guard d + rem > 0 else { return 0 }
        return min(0.99, max(0, d / (d + rem)))
    }

    /// Whole percent for the UI (never 100 before arrival).
    static func percent(_ p: Double) -> Int {
        p >= 1 ? 100 : min(99, max(0, Int((p * 100).rounded())))
    }

    /// ETA: the navigation's own when guiding; else remaining ÷ my average moving speed
    /// (or the cautious default). `estimated` = not from the navigation.
    static func eta(remaining r: RemainingDistance, avgMovingKmh: Double?, now: Date) -> (date: Date, estimated: Bool) {
        if r.source == .navigation, let e = r.navETA { return (e, false) }
        let v = avgMovingKmh.flatMap { $0 >= minAverageKmh ? $0 : nil } ?? defaultKmh
        return (now.addingTimeInterval(r.meters / (v / 3.6)), true)
    }

    /// The trail's length from the start point on (gaps count as their straight line: we
    /// know at least that much was driven).
    static func drivenMeters(trail: [TrailPoint], sinceMs: Double) -> Double {
        var s = 0.0
        var prev: TrailPoint?
        for p in trail where p.t >= sinceMs - 1000 {
            if let q = prev { s += Vehicle.distanceMeters(q.position, p.position) }
            prev = p
        }
        return s
    }
}

// MARK: - moving / stopped

/// «وقت الحركة / الوقوف»: from my trip log (local only).
struct TripMotion: Equatable {
    var elapsedS: Int
    var movingS: Int
    var stoppedS: Int
    var longestStopS: Int?
    var avgMovingKmh: Double?
    var maxKmh: Double?

    static func make(log: TripLog?, startMs: Double?, endMs: Double) -> TripMotion {
        let begin = startMs ?? log?.firstAtMs ?? endMs
        let elapsed = max(0, (endMs - begin) / 1000)
        let moving = min(elapsed, log?.movingS ?? 0)
        let avg = (log?.movingS ?? 0) >= 60 ? (log?.distanceM ?? 0) / max(1, log?.movingS ?? 1) * 3.6 : nil
        let peak = log?.peak?.maxMps ?? 0
        var longest = log?.longestStopS
        /* Standing still right now counts too. */
        if let s = log?.stopStartMs, let last = log?.lastAtMs { longest = max(longest ?? 0, (last - s) / 1000) }
        return TripMotion(elapsedS: Int(elapsed.rounded()), movingS: Int(moving.rounded()), stoppedS: Int((elapsed - moving).rounded()),
                          longestStopS: longest.flatMap { $0 >= 60 ? Int($0.rounded()) : nil },
                          avgMovingKmh: avg.flatMap { $0 > 0 ? $0 : nil }, maxKmh: peak > 0 ? Speed.kmh(peak) : nil)
    }
}

// MARK: - arrival order

enum ArrivalOrder {
    struct Entry: Equatable {
        var id: String
        var name: String
        var atMs: Double
    }

    /// Who arrived, first first; and who has not.
    static func split(arrivals: [String: Double], members: [(id: String, name: String)]) -> (arrived: [Entry], waiting: [String]) {
        var names: [String: String] = [:]
        for m in members where names[m.id] == nil { names[m.id] = m.name }
        var done: [Entry] = []
        for (id, at) in arrivals {
            if let n = names[id] { done.append(Entry(id: id, name: n, atMs: at)) }
        }
        done.sort { a, b in a.atMs != b.atMs ? a.atMs < b.atMs : a.id < b.id }
        let waiting = members.filter { arrivals[$0.id] == nil }.map(\.name)
        return (done, waiting)
    }

    /// «وصل أول: فهد، ثم سلطان · باقي: نورة».
    static func line(arrivals: [String: Double], members: [(id: String, name: String)], myId: String) -> String? {
        let s = split(arrivals: arrivals, members: members.map { ($0.id, $0.id == myId ? "أنت" : $0.name) })
        guard let first = s.arrived.first else { return nil }
        var text = "وصل أول: \(first.name)"
        if s.arrived.count > 1 { text += "، ثم " + s.arrived.dropFirst().map(\.name).joined(separator: "، ") }
        if s.waiting.isEmpty { text += " · وصل الجميع" } else { text += " · باقي: " + s.waiting.joined(separator: "، ") }
        return text
    }

    static func everyoneArrived(arrivals: [String: Double], memberIds: [String]) -> Bool {
        !memberIds.isEmpty && memberIds.allSatisfy { arrivals[$0] != nil }
    }
}
