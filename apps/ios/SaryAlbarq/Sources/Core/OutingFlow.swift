import Foundation

// «الطلعة» و«المشوار» (ux/الطلعة-والمشوار.md):
//
//   الطلعة (outing) = the container. Starts with «ابدأ الطلعة» (the leader), runs until
//   «أنهِ الطلعة». Zero or many المشاوير inside it.
//   المشوار (leg)   = A → B. Starts with «ابدأ المشوار», ends on arrival («وصلنا X»);
//   the outing goes on.
//
//   notStarted ──ابدأ الطلعة──▶ idle ──وين رايحين؟──▶ picked ──ابدأ المشوار──▶ onLeg
//        ▲                       ▲  ▲                    │                       │
//        │                       │  └──── غيّر ──────────┘                       │ وصلنا / detected
//        │                       └──────────── stopped(at: X) ◀─────────────────┘
//        │                                       │
//        └ (never back)          ended ◀── أنهِ الطلعة (idle / stopped / suggested)
//
// Pure (no UI, no network): every rule is unit-tested in Tests/OutingFlowTests.swift.

/// One leg of the outing (an «مشوار»), as the server keeps it (`/api/outings/:id/legs`),
/// or as this phone keeps it when the server has no legs yet (older API: still the plan's destination).
struct OutingLeg: Codable, Equatable, Identifiable {
    enum Scope: String, Codable { case group, personal }
    enum State: String, Codable { case active, arrived, cancelled, ended }

    var id: String
    var seq: Int
    var scope: Scope
    var destination: OutingDestination
    var state: State
    var started_at: String
    var arrived_at: String?
    var closed_at: String?
    var distance_m: Int?
    var duration_s: Int?
    var started_by: String?

    var isActive: Bool { state == .active }
    var startedDate: Date? { ISODate.parse(started_at) }
    var arrivedDate: Date? { arrived_at.flatMap(ISODate.parse) }

    /// Tolerant decode: an unknown state (newer server) reads as `ended`, never a crash.
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        seq = (try? c.decode(Int.self, forKey: .seq)) ?? 0
        scope = (try? c.decode(Scope.self, forKey: .scope)) ?? .group
        destination = try c.decode(OutingDestination.self, forKey: .destination)
        state = (try? c.decode(State.self, forKey: .state)) ?? .ended
        started_at = (try? c.decode(String.self, forKey: .started_at)) ?? ISODate.string(Date())
        arrived_at = try? c.decodeIfPresent(String.self, forKey: .arrived_at)
        closed_at = try? c.decodeIfPresent(String.self, forKey: .closed_at)
        distance_m = try? c.decodeIfPresent(Int.self, forKey: .distance_m)
        duration_s = try? c.decodeIfPresent(Int.self, forKey: .duration_s)
        started_by = try? c.decodeIfPresent(String.self, forKey: .started_by)
    }

    init(id: String, seq: Int, scope: Scope, destination: OutingDestination, state: State = .active, started_at: String,
         arrived_at: String? = nil, closed_at: String? = nil, distance_m: Int? = nil, duration_s: Int? = nil, started_by: String? = nil) {
        self.id = id
        self.seq = seq
        self.scope = scope
        self.destination = destination
        self.state = state
        self.started_at = started_at
        self.arrived_at = arrived_at
        self.closed_at = closed_at
        self.distance_m = distance_m
        self.duration_s = duration_s
        self.started_by = started_by
    }
}

/// The leg lifecycle on a list of legs (server and local share these rules).
enum LegLifecycle {
    /// Starting a leg replaces the active one of the same scope (it becomes `cancelled`).
    static func start(_ legs: [OutingLeg], _ leg: OutingLeg, now: Date = Date()) -> [OutingLeg] {
        var out = legs.map { l -> OutingLeg in
            guard l.isActive, l.scope == leg.scope else { return l }
            var c = l
            c.state = .cancelled
            c.closed_at = ISODate.string(now)
            return c
        }
        var l = leg
        l.seq = (legs.map(\.seq).max() ?? 0) + 1
        out.append(l)
        return out
    }

    /// Arrival ends that leg only. Idempotent; a closed leg stays as it was.
    static func arrive(_ legs: [OutingLeg], id: String, at: Date, distanceM: Int?, now: Date = Date()) -> [OutingLeg] {
        legs.map { l in
            guard l.id == id, l.isActive else { return l }
            var c = l
            c.state = .arrived
            c.arrived_at = ISODate.string(at)
            c.closed_at = ISODate.string(now)
            c.distance_m = distanceM.map { max(0, min($0, 3_000_000)) }
            if let s = l.startedDate { c.duration_s = max(0, Int(at.timeIntervalSince(s))) }
            return c
        }
    }

    static func cancel(_ legs: [OutingLeg], id: String, now: Date = Date()) -> [OutingLeg] {
        legs.map { l in
            guard l.id == id, l.isActive else { return l }
            var c = l
            c.state = .cancelled
            c.closed_at = ISODate.string(now)
            return c
        }
    }

    /// «أنهِ الطلعة»: a leg still on the way is closed as `ended` (not «وصلنا»).
    static func endOuting(_ legs: [OutingLeg], now: Date = Date()) -> [OutingLeg] {
        legs.map { l in
            guard l.isActive else { return l }
            var c = l
            c.state = .ended
            c.closed_at = ISODate.string(now)
            return c
        }
    }

    /// The legs that belong in «سجل الطلعة» and the summary: arrived or still on the way
    /// (or cut short by the end), in order. A changed mind (`cancelled`) is not a leg.
    static func timeline(_ legs: [OutingLeg]) -> [OutingLeg] {
        legs.filter { $0.state != .cancelled }.sorted { $0.seq < $1.seq }
    }

    /// The leg that drives the screen: my own personal one, else the group's.
    static func current(_ legs: [OutingLeg]) -> OutingLeg? {
        legs.last { $0.isActive && $0.scope == .personal } ?? legs.last { $0.isActive && $0.scope == .group }
    }

    static func lastArrived(_ legs: [OutingLeg]) -> OutingLeg? {
        legs.filter { $0.state == .arrived }.max { ($0.arrivedDate ?? .distantPast) < ($1.arrivedDate ?? .distantPast) }
    }
}

/// What the outing screen is doing right now — unmistakable on screen at all times.
enum OutingFlowState: Equatable {
    /// «ما بدأت الطلعة»: the leader sees «ابدأ الطلعة», members «بانتظار أمير الرحلة يبدأ».
    case notStarted
    case paused
    /// «الطلعة شغّالة»: no leg, never arrived anywhere yet.
    case idle
    /// A destination chosen, the leg not started: «ابدأ المشوار».
    case picked(OutingDestination)
    /// «في الطريق إلى X».
    case onLeg(OutingLeg)
    /// «واقفين عند X»: the last leg arrived (on this phone), no new one yet.
    case stopped(at: String, since: Date)
    case ended
}

enum OutingCTA: String, Equatable {
    case startOuting, waitLeader, whereTo, startLeg, changeDestination, arrived, endOuting, summary

    var title: String {
        switch self {
        case .startOuting: return "ابدأ الطلعة"
        case .waitLeader: return "بانتظار أمير الرحلة يبدأ"
        case .whereTo: return "وين رايحين؟"
        case .startLeg: return "ابدأ المشوار"
        case .changeDestination: return "غيّر الوجهة"
        case .arrived: return "وصلنا"
        case .endOuting: return "أنهِ الطلعة"
        case .summary: return "ملخص الطلعة"
        }
    }

    var systemImage: String {
        switch self {
        case .startOuting: return "play.fill"
        case .waitLeader: return "hourglass"
        case .whereTo: return "magnifyingglass"
        case .startLeg: return "location.north.line.fill"
        case .changeDestination: return "arrow.triangle.swap"
        case .arrived: return "flag.checkered"
        case .endOuting: return "house.fill"
        case .summary: return "list.bullet.rectangle"
        }
    }

    var id: String { "flow.cta.\(rawValue)" }
}

struct OutingFlowInput: Equatable {
    var status: OutingStatus?
    var iLead = false
    /// Ending stays the owner's (the server's rule).
    var iOwn = false
    var legs: [OutingLeg] = []
    /// Chosen in «وين رايحين؟», not started yet.
    var picked: OutingDestination?
    /// I arrived at the current leg's destination (detected or «وصلنا»), on this phone.
    var myArrivedAt: Date?
    var liveCount = 0
    var remainingM: Double?
    var eta: Date?
    /// «رجعتوا؟»: everyone is back near the start after hours out (`OutingEndSuggest`).
    var endSuggested = false
    var now = Date()
}

/// ONE primary action per state (the owner's rule: «زر رئيسي واحد بس»). «أنهِ الطلعة» and
/// «غادر الطلعة» live in the «الرحلة» sheet, quietly; the arrival moment is a 4-second toast.
struct OutingFlowUI: Equatable {
    var state: OutingFlowState
    /// The header's second line: the state, in Najdi.
    var line: String
    var primary: OutingCTA?
}

enum OutingFlow {
    /// How long «وصلنا X» stays on screen as a moment (one toast).
    static let momentS: TimeInterval = 4

    static func state(_ i: OutingFlowInput) -> OutingFlowState {
        switch i.status {
        case nil, .created?: return .notStarted
        case .ended?: return .ended
        case .paused?: return .paused
        case .active?: break
        }
        if let leg = LegLifecycle.current(i.legs) {
            if let a = i.myArrivedAt { return .stopped(at: leg.destination.name, since: a) }
            return .onLeg(leg)
        }
        if let p = i.picked { return .picked(p) }
        if let last = LegLifecycle.lastArrived(i.legs) { return .stopped(at: last.destination.name, since: last.arrivedDate ?? i.now) }
        return .idle
    }

    static func ui(_ i: OutingFlowInput) -> OutingFlowUI {
        let s = state(i)
        let endFirst = i.endSuggested && i.iOwn
        switch s {
        case .notStarted:
            return OutingFlowUI(state: s, line: i.iLead ? "ما بدأت الطلعة" : "بانتظار أمير الرحلة يبدأ", primary: i.iLead ? .startOuting : .waitLeader)
        case .paused:
            return OutingFlowUI(state: s, line: "الطلعة متوقفة مؤقتًا", primary: nil)
        case .idle:
            return OutingFlowUI(state: s, line: liveLine(i.liveCount), primary: endFirst ? .endOuting : .whereTo)
        case let .picked(d):
            return OutingFlowUI(state: s, line: "الوجهة \(d.name) · جاهزين؟", primary: .startLeg)
        case let .onLeg(leg):
            let parts = ["في الطريق إلى \(leg.destination.name)", i.remainingM.map { SaryFormat.distance(meters: $0) }, minutesLine(i.eta, now: i.now)]
            return OutingFlowUI(state: s, line: parts.compactMap { $0 }.joined(separator: " · "), primary: .arrived)
        case let .stopped(at, _):
            return OutingFlowUI(state: s, line: "واقفين عند \(at)", primary: endFirst ? .endOuting : .whereTo)
        case .ended:
            return OutingFlowUI(state: s, line: "انتهت الطلعة", primary: .summary)
        }
    }

    /// «الطلعة شغّالة · ٤ مباشر».
    static func liveLine(_ n: Int) -> String {
        n > 0 ? "الطلعة شغّالة · \(SaryFormat.number(n)) مباشر" : "الطلعة شغّالة"
    }

    /// «١٨ د» / «١ س ٥ د»; nil without an ETA.
    static func minutesLine(_ eta: Date?, now: Date) -> String? {
        guard let eta else { return nil }
        let m = max(1, Int((eta.timeIntervalSince(now) / 60).rounded()))
        if m < 60 { return "\(SaryFormat.number(m)) د" }
        let h = m / 60, r = m % 60
        return r == 0 ? "\(SaryFormat.number(h)) س" : "\(SaryFormat.number(h)) س \(SaryFormat.number(r)) د"
    }
}

/// «رجعتوا؟»: suggest «أنهِ الطلعة» when, after hours out, everyone live is back near the start.
/// The start is the group's start (the leader's first fix); nobody's home is ever known or stored.
enum OutingEndSuggest {
    static let minHours = 3.0
    static let radiusM = 2_000.0

    static func shouldSuggest(startedAt: Date?, groupStart: LngLat?, livePositions: [LngLat], hasActiveLeg: Bool, now: Date) -> Bool {
        guard !hasActiveLeg, let s = startedAt, now.timeIntervalSince(s) >= minHours * 3600,
              let g = groupStart, !livePositions.isEmpty else { return false }
        return livePositions.allSatisfy { Vehicle.distanceMeters($0, g) <= radiusM }
    }
}
