import Foundation

// Convoy mode («وضع القافلة») — contract §4. The leader picks «المقدمة» and
// «المؤخرة» and a max gap; every phone computes the alerts itself, from LIVE
// positions only (an old fix never raises — or silences — an alert).

/// `outing.convoy` and the body of `PATCH /:id/convoy`.
struct ConvoyInfo: Codable, Equatable {
    var lead_user_id: String?
    var tail_user_id: String?
    var max_gap_m: Double?

    static let gapRange: ClosedRange<Double> = 200...5000
    static let defaultGapM = 1000.0
    static let off = ConvoyInfo(lead_user_id: nil, tail_user_id: nil, max_gap_m: nil)

    var isOn: Bool { lead_user_id != nil || tail_user_id != nil }
    /// The gap in force, always inside the server's range.
    var gapM: Double { min(max(max_gap_m ?? Self.defaultGapM, Self.gapRange.lowerBound), Self.gapRange.upperBound) }

    func role(of uid: String) -> ConvoyRole? {
        if uid == lead_user_id { return .lead }
        if uid == tail_user_id { return .tail }
        return nil
    }

    private enum K: String, CodingKey { case lead_user_id, tail_user_id, max_gap_m }

    init(lead_user_id: String?, tail_user_id: String?, max_gap_m: Double?) {
        self.lead_user_id = lead_user_id
        self.tail_user_id = tail_user_id
        self.max_gap_m = max_gap_m
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        lead_user_id = try c.decodeIfPresent(String.self, forKey: .lead_user_id)
        tail_user_id = try c.decodeIfPresent(String.self, forKey: .tail_user_id)
        max_gap_m = try c.decodeIfPresent(Double.self, forKey: .max_gap_m)
    }

    /// `null` is sent on purpose: it is how the leader clears «المقدمة» / «المؤخرة».
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        try c.encode(lead_user_id, forKey: .lead_user_id)
        try c.encode(tail_user_id, forKey: .tail_user_id)
        try c.encodeIfPresent(max_gap_m.map { $0.rounded() }, forKey: .max_gap_m)
    }
}

enum ConvoyRole: Equatable {
    case lead, tail

    var label: String { self == .lead ? "المقدمة" : "المؤخرة" }
}

/// A car with a LIVE fix (the caller filters; stale ones never get here).
struct ConvoyCar: Equatable {
    var id: String
    var position: Geo.LatLng
    /// Trusted course (moving, live), degrees from north; nil when parked or unknown.
    var heading: Double?
}

enum ConvoyAlert: Equatable {
    /// Further back than the tail by more than the gap.
    case behindTail(userId: String, meters: Double)
    /// In front of the lead.
    case aheadOfLead(userId: String, meters: Double)
    /// The tail is too far behind the lead.
    case tailFarBehindLead(meters: Double)

    var key: String {
        switch self {
        case let .behindTail(u, _): return "convoy:behind:\(u)"
        case let .aheadOfLead(u, _): return "convoy:ahead:\(u)"
        case .tailFarBehindLead: return "convoy:tailfar"
        }
    }
}

enum ConvoyMath {
    /// Ahead of the lead by less than this is GPS noise / overtaking for a moment.
    static let aheadToleranceM = 60.0
    /// Tail→lead closer than this gives no usable direction.
    static let minDirectionSpanM = 30.0

    struct Evaluation: Equatable {
        var alerts: [ConvoyAlert]
        /// Direction of travel used, degrees from north; nil = cannot tell (no alerts along it).
        var direction: Double?
        /// «المقدمة» / «المؤخرة» is set but has no live fix: those checks are off, said in the UI.
        var leadMissing: Bool
        var tailMissing: Bool
        /// Lead→tail limit used for «المؤخرة بعيدة».
        var spanLimitM: Double
    }

    /// Metres along the direction of travel from `origin` to `p` (positive = ahead),
    /// on a local flat projection (good to well under 1 % over a convoy's length).
    static func along(_ p: Geo.LatLng, from origin: Geo.LatLng, bearing: Double) -> Double {
        let r = Double.pi / 180
        let x = (p.lng - origin.lng) * r * cos(origin.lat * r) * Geo.earthRadiusM
        let y = (p.lat - origin.lat) * r * Geo.earthRadiusM
        return x * sin(bearing * r) + y * cos(bearing * r)
    }

    /// The lead's own course when it is moving; else the line from the tail to the lead; else the tail's course.
    static func direction(lead: ConvoyCar?, tail: ConvoyCar?) -> Double? {
        if let h = lead?.heading { return h }
        if let l = lead, let t = tail, Geo.haversineMeters(t.position, l.position) >= minDirectionSpanM {
            return Geo.bearingDeg(t.position, l.position)
        }
        return tail?.heading
    }

    static func evaluate(_ convoy: ConvoyInfo, live cars: [ConvoyCar]) -> Evaluation {
        let byId = Dictionary(cars.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let leadId = convoy.lead_user_id
        let tailId = convoy.tail_user_id == leadId ? nil : convoy.tail_user_id
        let lead = leadId.flatMap { byId[$0] }
        let tail = tailId.flatMap { byId[$0] }
        let gap = convoy.gapM
        /* Each car may be up to one gap behind the one in front: the whole column, (n − 1) gaps. */
        let span = gap * Double(max(1, cars.count - 1))
        var out = Evaluation(alerts: [], direction: nil, leadMissing: leadId != nil && lead == nil,
                             tailMissing: tailId != nil && tail == nil, spanLimitM: span)
        guard convoy.isOn else { return out }
        let dir = direction(lead: lead, tail: tail)
        out.direction = dir
        let others = cars.filter { $0.id != leadId && $0.id != tailId }.sorted { $0.id < $1.id }
        if let dir {
            if let lead {
                for o in others {
                    let a = along(o.position, from: lead.position, bearing: dir)
                    if a > aheadToleranceM { out.alerts.append(.aheadOfLead(userId: o.id, meters: a)) }
                }
            }
            if let tail {
                for o in others {
                    let b = -along(o.position, from: tail.position, bearing: dir)
                    if b > gap { out.alerts.append(.behindTail(userId: o.id, meters: b)) }
                }
            }
        }
        if let lead, let tail {
            let behind = dir.map { -along(tail.position, from: lead.position, bearing: $0) } ?? Geo.haversineMeters(lead.position, tail.position)
            if behind > span { out.alerts.append(.tailFarBehindLead(meters: behind)) }
        }
        return out
    }
}

/// Rate limit for the alert lane and the haptic: an alert fires when it first
/// becomes true, again only as a reminder every `repeatAfter` while it stays
/// true, and after it clears it must stay clear for `clearAfter` before it counts
/// as new (a car hovering at the threshold does not buzz every few seconds).
struct ConvoyAlertGate {
    var repeatAfter: TimeInterval = 180
    var clearAfter: TimeInterval = 60
    var hapticMinInterval: TimeInterval = 20
    private(set) var lastFired: [String: Date] = [:]
    private var clearedSince: [String: Date] = [:]
    private var lastHaptic: Date?

    init(repeatAfter: TimeInterval = 180, clearAfter: TimeInterval = 60, hapticMinInterval: TimeInterval = 20) {
        self.repeatAfter = repeatAfter
        self.clearAfter = clearAfter
        self.hapticMinInterval = hapticMinInterval
    }

    mutating func admit(_ alerts: [ConvoyAlert], now: Date) -> (fire: [ConvoyAlert], haptic: Bool) {
        let current = Set(alerts.map(\.key))
        for k in lastFired.keys where !current.contains(k) {
            let since = clearedSince[k] ?? now
            clearedSince[k] = since
            if now.timeIntervalSince(since) >= clearAfter {
                lastFired[k] = nil
                clearedSince[k] = nil
            }
        }
        var fire: [ConvoyAlert] = []
        for a in alerts {
            clearedSince[a.key] = nil
            if let last = lastFired[a.key], now.timeIntervalSince(last) < repeatAfter { continue }
            lastFired[a.key] = now
            fire.append(a)
        }
        var haptic = false
        if !fire.isEmpty, lastHaptic.map({ now.timeIntervalSince($0) >= hapticMinInterval }) ?? true {
            haptic = true
            lastHaptic = now
        }
        return (fire, haptic)
    }

    mutating func reset() {
        lastFired = [:]
        clearedSince = [:]
    }
}
