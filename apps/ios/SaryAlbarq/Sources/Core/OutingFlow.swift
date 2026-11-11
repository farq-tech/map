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
    /// «ما بدأت الطلعة»: the leader sees «ابدأ الطلعة», members see that they joined and are waiting for the leader.
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

/// The guidance on this phone, as ONE explicit state, separate from the leg and the outing
/// (owner's build 36 report, item 10: «أوقف التوجيه» brought the outing back showing «وصلنا»).
/// Each changes only by its own action:
///   * `guiding` — turn-by-turn runs (the trip's or a person's own);
///   * `paused`  — «أوقف التوجيه» on this phone: the leg is still on, nothing restarts by itself,
///                 «استأنف التوجيه» is the one primary action;
///   * `arrived` — the leg's destination reached («وصلتوا» / «وصلنا» / detected): guidance is done
///                 for this leg, the OUTING goes on (only «أنهِ الطلعة» ends it);
///   * `off`     — never started on this phone for this leg.
/// The outing's own end and leaving it are `OutingFlowState.ended` and the screen closing.
enum TripGuidanceState: Equatable {
    case off, guiding, paused, arrived

    static func of(guiding: Bool, paused: Bool, arrived: Bool) -> TripGuidanceState {
        if arrived { return .arrived }
        if guiding { return .guiding }
        return paused ? .paused : .off
    }
}

enum OutingCTA: String, Equatable {
    case startOuting, waitLeader, whereTo, startLeg, changeDestination, arrived, resumeGuidance, endOuting, summary

    var title: String {
        switch self {
        case .startOuting: return "ابدأ الطلعة"
        /* The member's ONE waiting message (the header and the sheet stay quiet about it). */
        case .waitLeader: return "ننتظر أمير الطلعة"
        case .whereTo: return "وين رايحين؟"
        case .startLeg: return "ابدأ المشوار"
        case .changeDestination: return "غيّر الوجهة"
        case .arrived: return "وصلنا"
        case .resumeGuidance: return "استأنف التوجيه"
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
        case .resumeGuidance: return "location.north.line.fill"
        case .endOuting: return "house.fill"
        case .summary: return "list.bullet.rectangle"
        }
    }

    /// «استأنف التوجيه» keeps the identifier it had as the guidance prompt (UI tests).
    var id: String { self == .resumeGuidance ? "nav.auto.resume" : "flow.cta.\(rawValue)" }
}

struct OutingFlowInput: Equatable {
    var status: OutingStatus?
    /// Starts the outing (owner, co-leader or `can_lead`): the server's `requireLeader` for «start».
    var iLead = false
    /// Ending stays the owner's — the server's `setStatus` runs `requireOwner` for «end» only
    /// (apps/api/lib/outings/service.js). Every «أنهِ الطلعة» entry uses this same rule:
    /// this CTA (`endSuggested`), «المزيد» → «الطلعة» (`settingsTab.isLeader` = `iOwn`) and
    /// `TripPanelUI.canEnd` (`TripPresenterInput.iLead` is filled from `iOwn`). A co-leader can
    /// start and pause, never end.
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
    /// The guidance on this phone (`TripGuidanceState`): paused, the leg's primary is «استأنف التوجيه».
    var guidance: TripGuidanceState = .off
    /// Before the start, for a member: the leader's and the members' presence (`WaitingLeader`).
    var waiting: WaitingLeaderInfo? = nil
    var now = Date()
}

/// ONE primary action per state (the owner's rule: «زر رئيسي واحد بس»). «أنهِ الطلعة» and
/// «غادر الطلعة» live in the «الرحلة» sheet, quietly; the arrival moment is a 4-second toast.
struct OutingFlowUI: Equatable {
    var state: OutingFlowState
    /// The header's second line: the state, in Najdi.
    var line: String
    var primary: OutingCTA?
    /// Members only, before the start: what «ننتظر أمير الطلعة» is waiting on (shown under it).
    var waiting: WaitingLeaderInfo? = nil
}

/// «ننتظر أمير الطلعة» with the facts behind it (Build 36 report, item 9: the bare message said
/// nothing): is the leader here, how many of «الربع» joined and are connected, and is MY link up
/// (when it is not, everything above is the last thing we heard, and is said to be).
struct WaitingLeaderInfo: Equatable {
    /// «أمير الطلعة فهد متصل الآن» / «… آخر ظهور قبل ١٢ د» / «… غير متصل الآن».
    var leader: String
    var leaderOnline: Bool
    /// «الربع ٤ · المتصلين ٢».
    var members: String
    /// Nil while my connection is up; «اتصالك: بلا إنترنت · آخر حالة وصلتنا» otherwise.
    var connection: String?

    /// The one line under the button.
    var line: String { "\(connection ?? leader) · \(members)" }
    /// Everything, for VoiceOver.
    var accessibility: String {
        var parts = ["ما بدأت الطلعة", leader, members]
        if let connection { parts.append(connection) }
        return parts.joined(separator: "، ")
    }
}

enum WaitingLeader {
    /// `members`: the outing's members as the server last sent them (`online` / `away` from the live
    /// channel's presence, `last_seen_at` from the heartbeat). `clockOffsetMs`: server − device.
    /// `myLinkUp`: my live channel is connected (else the presence above may be old).
    static func info(members: [Member], myId: String, clockOffsetMs: Double, myLinkUp: Bool, myLinkText: String, now: Date) -> WaitingLeaderInfo {
        let leader = members.first { $0.role == "owner" }
        let leaderText: String
        var online = false
        if let l = leader {
            let name = "\(SaryCopy.leader) \(l.display_name)"
            if l.online == true {
                online = true
                leaderText = l.away == true ? "\(name) متصل (سرى بالخلفية عنده)" : "\(name) متصل الآن"
            } else if let seen = ISODate.parse(l.last_seen_at)?.addingTimeInterval(-clockOffsetMs / 1000) {
                leaderText = "\(name) آخر ظهور \(SaryFormat.elapsed(since: seen, now: now))"
            } else {
                leaderText = "\(name) غير متصل الآن"
            }
        } else {
            leaderText = "ما نعرف حالة \(SaryCopy.leader)"
        }
        let connected = members.filter { $0.user_id == myId ? myLinkUp : $0.online == true }.count
        let membersText = "\(SaryCopy.members) \(SaryFormat.number(members.count)) · المتصلين \(SaryFormat.number(connected))"
        return WaitingLeaderInfo(leader: leaderText, leaderOnline: online, members: membersText,
                                 connection: myLinkUp ? nil : "اتصالك: \(myLinkText) · آخر حالة وصلتنا")
    }
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
            /* The member hears «ننتظر أمير الطلعة» once — on the button; the header only says the state. */
            return OutingFlowUI(state: s, line: "ما بدأت الطلعة", primary: i.iLead ? .startOuting : .waitLeader,
                                waiting: i.iLead ? nil : i.waiting)
        case .paused:
            return OutingFlowUI(state: s, line: "الطلعة متوقفة مؤقتًا", primary: nil)
        case .idle:
            /* «… مباشر» is the sheet's line (SarySheetSummary): the header does not repeat the count. */
            return OutingFlowUI(state: s, line: liveLine(0), primary: endFirst ? .endOuting : .whereTo)
        case let .picked(d):
            return OutingFlowUI(state: s, line: "الوجهة \(d.name) · جاهزين؟", primary: .startLeg)
        case let .onLeg(leg):
            /* «أوقف التوجيه» is not an arrival: the leg goes on and its one primary action brings the
             * guidance back. «وصلنا» stays in the «الرحلة» card for when we really are there. */
            let paused = i.guidance == .paused
            let parts = ["في الطريق إلى \(leg.destination.name)", i.remainingM.map { SaryFormat.distance(meters: $0) }, minutesLine(i.eta, now: i.now),
                         paused ? "التوجيه موقّف" : nil]
            return OutingFlowUI(state: s, line: parts.compactMap { $0 }.joined(separator: " · "), primary: paused ? .resumeGuidance : .arrived)
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

    /// «١٨ د» / «١ س ٥ د»; nil without an ETA. Whole minutes counted the way the guidance bar counts
    /// them (`NavText.remaining` → `SaryFormat.duration`): build 36 rounded here and truncated there,
    /// so the header could say «١٩ د» over a bar saying «١٨ د».
    static func minutesLine(_ eta: Date?, now: Date) -> String? {
        guard let eta else { return nil }
        let m = max(1, max(0, Int(eta.timeIntervalSince(now).rounded())) / 60)
        if m < 60 { return "\(SaryFormat.number(m)) د" }
        let h = m / 60, r = m % 60
        return r == 0 ? "\(SaryFormat.number(h)) س" : "\(SaryFormat.number(h)) س \(SaryFormat.number(r)) د"
    }
}

/// The word dictionary (UI-AUDIT §٢ «قاموس الكلمات», owner-approved): ONE Najdi word per concept,
/// on every screen, CarPlay and notifications. The widget / Live Activity target does not compile
/// this file: its copies of these words are literals that must match (`Widgets/`, `Shared/`).
enum SaryCopy {
    /// The whole outing: «الطلعة», never «الرحلة».
    static let outing = "الطلعة"
    /// Its leader.
    static let leader = "أمير الطلعة"
    /// The outing's members.
    static let members = "الربع"
    /// Retrace your own recorded trail back (offline, on this phone).
    static let backTrack = "طريق الرجعة"
    /// End the retrace (its panel's button).
    static let endBackTrack = "أنهِ الرجعة"
    /// A NEW outing from here to the start point (needs the server).
    static let returnOuting = "طلعة الرجعة"
    /// The leg / pin back to where you started.
    static let startPoint = "نقطة البداية"
    /// Start guidance for me.
    static let go = "اتجه"
    /// Start guidance for everyone (the leader).
    static let guideAll = "وجّه الكل"
    /// Stop guidance.
    static let stopGuidance = "أوقف التوجيه"
    /// Close the «وصلت» card: the guidance is already over, so it is NOT «أوقف التوجيه».
    static let arrivedDone = "تمام"
    /// End the outing (the action); its confirmation is `EndOutingCopy`.
    static let endOuting = "أنهِ الطلعة"
    /// Postpone («not now»).
    static let later = "لاحقًا"
    /// Back out of what you were doing.
    static let cancel = "إلغاء"
    /// Frame everyone on the map.
    static let seeAll = "شوف الكل"
    static let rally = "نقطة التجمع"
    static let chat = "المحادثة"
    static let myPlaces = "أماكني"
    /// The emergency button's word (no Latin «SOS» on screen).
    static let emergency = "طوارئ"
    /// The outing has ended.
    static let outingEnded = "انتهت الطلعة"
    /// Back from explore mode to the outing.
    static let backToOuting = "ارجع للطلعة"
    /// The generic failure, said in Najdi.
    static let genericError = "صار خلل. جرّب مرة ثانية."
}

/// «أنهِ الطلعة»: ONE confirmation everywhere (the CTA, «المزيد» → «الطلعة»), one icon.
/// `flag.checkered` stays «وصلنا»'s.
enum EndOutingCopy {
    static let action = SaryCopy.endOuting
    static let title = "تنهي الطلعة للكل؟"
    static let confirm = "أنهِها"
    static let cancel = "لا"
    static let systemImage = "house.fill"

    static func message(everyoneArrived: Bool = false) -> String {
        everyoneArrived ? "وصل الربع كلهم. يوقف إرسال المواقع عند الكل ويطلع ملخص الطلعة."
                        : "يوقف إرسال المواقع عند الكل ويطلع ملخص الطلعة بكل مشاويرها. ما تقدر ترجعها."
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
