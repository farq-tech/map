import Foundation

// Pure CarPlay presenters: the phone's real data in, short glanceable values out.
// No CarPlay, no MapKit, no Mapbox in this file, so every rule is unit-tested
// (Tests/CarPlayPresenterTests.swift). The CarPlay templates only copy these values.
//
// Rules carried over from the phone app, never relaxed in the car:
//  • an old position is never shown as live: it says «آخر موقع قبل …»;
//  • straight-line guidance says «اتجاه تقريبي» — there is no road routing;
//  • my own SOS needs two deliberate steps (`CarPlaySOSGuard`).

/// Everything the CarPlay screens are made from, as plain values.
struct CarPlayInput {
    var view: OutingView?
    var myFix: DeviceFix?
    var isSharingNow = false
    /// My trusted course (degrees), when moving.
    var course: Double?
    var destination: CarPlayDestination?
    var stuck: [CarPlayStuck] = []
    var convoy: CarPlayConvoy?
    var now = Date()

    var myPosition: LngLat? {
        guard let f = myFix, now.timeIntervalSince1970 * 1000 - f.atMs <= CarPlayPresenter.myFixMaxAgeMs else { return nil }
        return LngLat(lng: f.lng, lat: f.lat)
    }

    /// The live-screen presenter's input, for the rules it already owns (presence, map cars).
    var live: LivePresenterInput {
        var i = LivePresenterInput()
        i.view = view
        i.myFix = myFix
        i.gpsState = myFix == nil ? .unavailable : .ok
        i.isSharingNow = isSharingNow
        i.now = now
        return i
    }
}

// MARK: - members («الأصحاب»)

struct CarPlayMemberRow: Equatable, Identifiable {
    enum State: Equatable {
        case live
        /// Last real fix is old; `since` is that fix's time.
        case stale(since: Date)
        /// They paused sharing.
        case paused
        /// Sharing, but no fix has arrived yet.
        case noFix
    }

    var id: String
    var name: String
    var shortName: String
    var color: UInt32
    var state: State
    /// One short line: distance · direction, or how old the position is.
    var detail: String
    var distanceM: Double?
    /// Their last real fix (nil when none): «أظهره» centres here.
    var position: LngLat?
    /// E.164 for «اتصال»; nil hides the action.
    var phone: String?
    var sos: Bool
    var stuck: Bool

    var isLive: Bool { state == .live }
}

/// One car on the CarPlay map.
struct CarPlayMapCar: Equatable, Identifiable {
    var id: String
    var position: LngLat
    var color: UInt32
    /// Short name, plus its age when the fix is not live.
    var label: String
    var live: Bool
    var heading: Double?
    var isMe: Bool
}

enum CarPlayPresenter {
    /// My own fix older than this is not used for distances or guidance.
    static let myFixMaxAgeMs = 60_000.0
    static let shortNameMax = 10
    static let rallyArrivedM = LiveOutingPresenter.arrivedRadiusM
    static let destinationArrivedM = 100.0

    /// First word of the name, at most 10 characters (map labels, alert titles).
    static func shortName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let first = trimmed.split(separator: " ").first.map(String.init) ?? trimmed
        /* «أبو فهد»: a kunya alone says nothing, keep both words. */
        let word = (first == "أبو" || first == "ابو" || first == "أم" || first == "ام") ? trimmed.split(separator: " ").prefix(2).joined(separator: " ") : first
        if word.count <= shortNameMax { return word.isEmpty ? "—" : word }
        return String(word.prefix(shortNameMax - 1)) + "…"
    }

    static func ageText(since: Date, now: Date) -> String {
        "آخر موقع " + ArabicFormat.ago(max(0, now.timeIntervalSince(since)) * 1000)
    }

    static func distanceAndDirection(from a: LngLat?, to b: LngLat?) -> (m: Double, text: String)? {
        guard let a, let b else { return nil }
        let d = Vehicle.distanceMeters(a, b)
        return (d, ArabicFormat.distance(d) + " · " + Geo.directionLabel(Vehicle.bearing(a, b)))
    }

    static func memberRows(_ i: CarPlayInput) -> [CarPlayMemberRow] {
        guard let v = i.view else { return [] }
        let colors = v.colors
        let me = i.myPosition
        let stuckIds = Set(i.stuck.map(\.memberId))
        var rows: [(CarPlayMemberRow, Int)] = []
        for (idx, m) in v.orderedMembers.enumerated() where m.user_id != v.myId {
            let presence = LiveOutingPresenter.presence(of: m, in: v, myFix: i.myFix, isMe: false, isSharingNow: i.isSharingNow, now: i.now)
            let pos = v.positions[m.user_id].map { LngLat(lng: $0.lng, lat: $0.lat) }
            let state: CarPlayMemberRow.State
            switch presence {
            case .live: state = .live
            case .paused: state = .paused
            case let .stale(since): state = pos == nil ? .noFix : .stale(since: since)
            }
            /* An SOS carries its own fix (maybe older): use it for where to look. */
            let sosPos = m.sos?.fix.map { LngLat(lng: $0.lng, lat: $0.lat) }
            let target = sosPos ?? pos
            let dd = distanceAndDirection(from: me, to: target)
            var parts: [String] = []
            if m.sos != nil { parts.append("نداء استغاثة") } else if stuckIds.contains(m.user_id) { parts.append("غرّز") }
            switch state {
            case .live:
                parts.append(dd?.text ?? "مباشر")
            case let .stale(since):
                parts.append(ageText(since: since, now: i.now))
                if let dd { parts.append(ArabicFormat.distance(dd.m)) }
            case .paused:
                parts.append("ما يشارك موقعه الحين")
            case .noFix:
                parts.append("ما وصل موقعه بعد")
            }
            let phone = (m.phone ?? "").isEmpty ? nil : m.phone
            rows.append((CarPlayMemberRow(id: m.user_id, name: m.display_name, shortName: shortName(m.display_name), color: colors[m.user_id] ?? 0xFFFFFF,
                                          state: state, detail: parts.joined(separator: " · "), distanceM: dd?.m, position: target, phone: phone,
                                          sos: m.sos != nil, stuck: stuckIds.contains(m.user_id)), idx))
        }
        /* Who needs help first, then the live ones nearest first, then old positions, then paused. */
        func rank(_ r: CarPlayMemberRow) -> Int {
            if r.sos { return 0 }
            if r.stuck { return 1 }
            switch r.state {
            case .live: return 2
            case .stale: return 3
            case .noFix: return 4
            case .paused: return 5
            }
        }
        return rows.sorted { a, b in
            let ra = rank(a.0), rb = rank(b.0)
            if ra != rb { return ra < rb }
            switch (a.0.distanceM, b.0.distanceM) {
            case let (x?, y?) where x != y: return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.1 < b.1
            }
        }.map(\.0)
    }

    /// Header line of the members list: my own sharing, said plainly.
    static func mySharingLine(_ i: CarPlayInput) -> String {
        i.isSharingNow ? "موقعك يظهر للأصحاب" : "موقعك ما يظهر للأصحاب (المشاركة متوقفة)"
    }

    static func mapCars(_ i: CarPlayInput) -> [CarPlayMapCar] {
        LiveOutingPresenter.mapMembers(i.live, hideNotes: true).map { m in
            var label = m.isMe ? "أنت" : shortName(m.name)
            switch m.presence {
            case .live: break
            case .recent: label += " · " + ArabicFormat.ago(max(0, i.now.timeIntervalSince1970 * 1000 - m.atMs))
            case .lost: label += " · انقطع"
            }
            return CarPlayMapCar(id: m.id, position: m.position, color: m.color, label: label, live: m.presence == .live,
                                 heading: m.heading, isMe: m.isMe)
        }
    }

    // MARK: points («نقطة البداية», rally, destination)

    static func rally(_ i: CarPlayInput) -> (position: LngLat, label: String)? {
        guard let r = i.view?.snapshot.outing.rally else { return nil }
        let l = (r.label ?? "").trimmingCharacters(in: .whitespaces)
        return (LngLat(lng: r.lng, lat: r.lat), l.isEmpty ? "نقطة التجمع" : l)
    }

    static func destination(_ i: CarPlayInput) -> (position: LngLat, label: String)? {
        guard let d = i.destination else { return nil }
        return (d.position, d.label.isEmpty ? "الوجهة" : d.label)
    }

    /// Trips the «إلى…» list offers right now (way back first when there is a trail).
    static func availableTrips(_ i: CarPlayInput, trail: Trail) -> [CarPlayTripKind] {
        var out: [CarPlayTripKind] = []
        if trail.points.count >= 2 { out.append(.wayBack) }
        if rally(i) != nil { out.append(.rally) }
        if destination(i) != nil { out.append(.destination) }
        return out
    }
}

// MARK: - guidance

enum CarPlayTripKind: String, Equatable, CaseIterable {
    case wayBack, rally, destination

    var title: String {
        switch self {
        case .wayBack: return "طريق العودة"
        case .rally: return "إلى نقطة التجمع"
        case .destination: return "إلى الوجهة"
        }
    }

    /// Straight-line trips are honest about it.
    var approximate: Bool { self != .wayBack }
}

/// One guidance card: what CPManeuver / CPTravelEstimates show.
struct CarPlayGuidance: Equatable {
    enum Phase: Equatable { case waitingFix, onTrail, onGap, offTrack, straight, arrived, road }

    var kind: CarPlayTripKind
    var phase: Phase
    /// The big line («تابع مسارك», «ارجع لمسارك», «اتجه شمال شرق»).
    var instruction: String
    /// The small line (what kind of guidance this is, said honestly).
    var detail: String
    var remainingM: Double?
    /// Arrow, degrees clockwise from where the car points (or from north when not moving).
    var arrowDegrees: Double
    /// Absolute compass bearing to follow.
    var bearing: Double?
    var offsetM: Double?
    /// SF Symbol for the arrow, one of 8 directions.
    var symbol: String

    var arrived: Bool { phase == .arrived }
    var offTrack: Bool { phase == .offTrack }
}

enum CarPlayGuide {
    static let symbols = ["arrow.up", "arrow.up.right", "arrow.right", "arrow.down.right", "arrow.down", "arrow.down.left", "arrow.left", "arrow.up.left"]

    static func relative(_ bearing: Double, course: Double?) -> Double {
        LiveOutingPresenter.relative(bearing, mapBearing: course ?? 0)
    }

    static func symbol(forRelative deg: Double) -> String {
        let n = (deg.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        return symbols[Int((n / 45).rounded()) % 8]
    }

    static func waiting(_ kind: CarPlayTripKind) -> CarPlayGuidance {
        CarPlayGuidance(kind: kind, phase: .waitingFix, instruction: "ننتظر موقعك", detail: "يبدأ التوجيه أول ما يوصل موقع حديث",
                        remainingM: nil, arrowDegrees: 0, bearing: nil, offsetM: nil, symbol: "location")
    }

    /// «طريق العودة» along my recorded trail (from the trail module's `BackTrackStatus`).
    static func wayBack(_ st: BackTrackStatus?, course: Double?) -> CarPlayGuidance {
        guard let st else { return waiting(.wayBack) }
        let rel = relative(st.bearing, course: course)
        let dir = Geo.directionLabel(st.bearing)
        if st.arrived {
            return CarPlayGuidance(kind: .wayBack, phase: .arrived, instruction: "وصلت نقطة البداية", detail: "انتهى طريق العودة",
                                   remainingM: 0, arrowDegrees: 0, bearing: nil, offsetM: st.offsetM, symbol: "flag.checkered")
        }
        if st.offTrack {
            return CarPlayGuidance(kind: .wayBack, phase: .offTrack, instruction: "ارجع لمسارك",
                                   detail: "أنت \(ArabicFormat.distance(st.offsetM)) عن المسار · اتجه \(dir)",
                                   remainingM: st.remainingM, arrowDegrees: rel, bearing: st.bearing, offsetM: st.offsetM, symbol: symbol(forRelative: rel))
        }
        if st.onGap {
            return CarPlayGuidance(kind: .wayBack, phase: .onGap, instruction: "اتجه \(dir)",
                                   detail: "مقطع ما انسجل: خط مستقيم تقريبي", remainingM: st.remainingM, arrowDegrees: rel,
                                   bearing: st.bearing, offsetM: st.offsetM, symbol: symbol(forRelative: rel))
        }
        return CarPlayGuidance(kind: .wayBack, phase: .onTrail, instruction: "تابع مسارك", detail: "على طريقك المسجّل · \(dir)",
                               remainingM: st.remainingM, arrowDegrees: rel, bearing: st.bearing, offsetM: st.offsetM, symbol: symbol(forRelative: rel))
    }

    /// A turn-by-turn road route (feat/ios-navigation) when one is active; the trail /
    /// straight-line guidance otherwise. A road route that lost its maneuvers falls back too.
    static func pick(road: CarPlayRoadProgress?, roadActive: Bool, kind: CarPlayTripKind, fallback: () -> CarPlayGuidance) -> CarPlayGuidance {
        guard roadActive, let road, let next = road.maneuvers.first else { return fallback() }
        return CarPlayGuidance(kind: kind, phase: .road, instruction: next.instruction,
                               detail: road.rerouting ? "نعيد حساب الطريق…" : "بعد \(ArabicFormat.distance(next.distanceM))",
                               remainingM: road.remainingM, arrowDegrees: 0, bearing: nil, offsetM: nil, symbol: next.symbol)
    }

    /// Rally / destination: a straight line, never a road route.
    static func straight(_ kind: CarPlayTripKind, from me: LngLat?, to target: LngLat, course: Double?) -> CarPlayGuidance {
        guard let me else { return waiting(kind) }
        let d = Vehicle.distanceMeters(me, target)
        let arrivedM = kind == .rally ? CarPlayPresenter.rallyArrivedM : CarPlayPresenter.destinationArrivedM
        if d <= arrivedM {
            return CarPlayGuidance(kind: kind, phase: .arrived, instruction: kind == .rally ? "وصلت نقطة التجمع" : "وصلت الوجهة",
                                   detail: "خلاص، أنت قريب منها", remainingM: 0, arrowDegrees: 0, bearing: nil, offsetM: nil, symbol: "flag.checkered")
        }
        let b = Vehicle.bearing(me, target)
        let rel = relative(b, course: course)
        return CarPlayGuidance(kind: kind, phase: .straight, instruction: "اتجه \(Geo.directionLabel(b))",
                               detail: "اتجاه تقريبي: خط مستقيم، مو طريق", remainingM: d, arrowDegrees: rel, bearing: b,
                               offsetM: nil, symbol: symbol(forRelative: rel))
    }
}

// MARK: - alerts

struct CarPlayAlert: Equatable, Identifiable {
    enum Kind: Int, Equatable, Comparable {
        /// Lower raw value = more urgent.
        case friendSOS = 0, stuck, offTrack, convoyGap, arrived
        static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }
    }

    var id: String
    var kind: Kind
    var title: String
    var subtitle: String
    var memberId: String?
    var phone: String?
    var position: LngLat?
    var since: Date

    /// Help requests stay until the driver acts; the rest time out.
    var sticky: Bool { kind == .friendSOS || kind == .stuck }
    var durationS: TimeInterval { sticky ? 0 : 8 }
}

enum CarPlayAlerts {
    /// Every alert that stands right now, most urgent first (then newest).
    static func current(_ i: CarPlayInput, guidance: CarPlayGuidance?) -> [CarPlayAlert] {
        var out: [CarPlayAlert] = []
        let rows = Dictionary(CarPlayPresenter.memberRows(i).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        if let v = i.view {
            for m in v.orderedMembers where m.user_id != v.myId {
                guard let s = m.sos else { continue }
                let row = rows[m.user_id]
                out.append(CarPlayAlert(id: LiveOutingPresenter.sosKey(m.user_id, s), kind: .friendSOS,
                                        title: "\(CarPlayPresenter.shortName(m.display_name)) يطلب نجدة",
                                        subtitle: sosSubtitle(m, s, i: i, view: v), memberId: m.user_id, phone: row?.phone,
                                        position: row?.position, since: LiveOutingPresenter.deviceDate(s.at, view: v) ?? i.now))
            }
            for st in i.stuck {
                guard let m = v.members[st.memberId], st.memberId != v.myId, m.sos == nil else { continue }
                let row = rows[st.memberId]
                let pos = st.position ?? row?.position
                let dd = CarPlayPresenter.distanceAndDirection(from: i.myPosition, to: pos)
                out.append(CarPlayAlert(id: "stuck:\(st.memberId):\(Int(st.since.timeIntervalSince1970))", kind: .stuck,
                                        title: "\(CarPlayPresenter.shortName(m.display_name)) غرّز", subtitle: dd?.text ?? "موقعه غير معروف",
                                        memberId: st.memberId, phone: row?.phone, position: pos, since: st.since))
            }
        }
        if let g = guidance, g.offTrack {
            out.append(CarPlayAlert(id: "offtrack", kind: .offTrack, title: "خرجت عن الطريق", subtitle: g.detail, since: i.now))
        }
        if let w = i.convoy?.gapWarning, !w.isEmpty {
            out.append(CarPlayAlert(id: "convoy:\(w)", kind: .convoyGap, title: "القافلة", subtitle: w, since: i.now))
        }
        if let g = guidance, g.arrived {
            out.append(CarPlayAlert(id: "arrived:\(g.kind.rawValue)", kind: .arrived, title: g.instruction, subtitle: g.detail, since: i.now))
        }
        return out.sorted { a, b in a.kind != b.kind ? a.kind < b.kind : a.since > b.since }
    }

    static func sosSubtitle(_ m: Member, _ s: SosInfo, i: CarPlayInput, view v: OutingView) -> String {
        guard let fix = s.fix else {
            if let p = v.positions[m.user_id] {
                let dd = CarPlayPresenter.distanceAndDirection(from: i.myPosition, to: LngLat(lng: p.lng, lat: p.lat))
                let at = LiveOutingPresenter.deviceDate(p.recorded_at, view: v) ?? i.now
                return [CarPlayPresenter.ageText(since: at, now: i.now), dd?.text].compactMap { $0 }.joined(separator: " · ")
            }
            return "موقعه غير معروف"
        }
        let dd = CarPlayPresenter.distanceAndDirection(from: i.myPosition, to: LngLat(lng: fix.lng, lat: fix.lat))
        let at = LiveOutingPresenter.deviceDate(fix.recorded_at, view: v) ?? i.now
        /* The SOS fix may be old: say how old unless it is fresh. */
        let age = i.now.timeIntervalSince(at) > 45 ? CarPlayPresenter.ageText(since: at, now: i.now) : nil
        return [dd?.text, age].compactMap { $0 }.joined(separator: " · ")
    }
}

/// Which alerts the driver already dealt with. An alert comes back if it goes away and returns
/// (back on the trail, then off it again; an SOS cleared, then raised again).
struct CarPlayAlertBook: Equatable {
    private(set) var handled: Set<String> = []

    mutating func handle(_ id: String) { handled.insert(id) }

    /// The most urgent alert not dealt with yet. Forgets handled ids that no longer stand.
    mutating func next(from current: [CarPlayAlert]) -> CarPlayAlert? {
        let ids = Set(current.map(\.id))
        handled = handled.intersection(ids)
        return current.first { !handled.contains($0.id) }
    }
}

// MARK: - my SOS: two deliberate steps

/// My SOS from the car is never one tap: «نداء» asks, and only a «نعم، أرسل» within
/// `window` of that question sends. A late or stray confirm asks again.
struct CarPlaySOSGuard: Equatable {
    enum Action: Equatable { case askConfirm, send, askCancel, cancel, nothing }

    static let window: TimeInterval = 20
    private(set) var askedAt: Date?

    /// The «نداء» button. `active`: my SOS already stands.
    mutating func press(active: Bool, now: Date = Date()) -> Action {
        askedAt = now
        return active ? .askCancel : .askConfirm
    }

    /// «نعم» on the confirm sheet.
    mutating func confirm(active: Bool, now: Date = Date()) -> Action {
        guard let a = askedAt, now.timeIntervalSince(a) <= Self.window, now >= a else {
            askedAt = now
            return active ? .askCancel : .askConfirm
        }
        askedAt = nil
        return active ? .cancel : .send
    }

    mutating func dismiss() { askedAt = nil }
}
