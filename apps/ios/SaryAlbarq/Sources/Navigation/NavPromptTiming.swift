import Foundation

/// When a guidance line is said and which distance it says (build 22).
///
/// Build 21 (a real drive in Riyadh): «بعد ١٠٠ متر لف يمين» at the turn itself. Three causes:
///   1. The distance was fixed when the cue was ASKED for, then the line waited (queue, audio
///      session, composing the clips) and took ~2 s to say: at 60 km/h that is 50 m and more.
///   2. It was rounded to the NEAREST recorded clip: 75 m → «بعد مية متر».
///   3. Nothing said «now» under 30 m, and 30–70 m still got a distance that ended at the turn.
///
/// Now (as Google Maps / OsmAnd do it): at the moment the line starts playing, the distance
/// is projected to when the line ENDS (start latency + its own duration, at my speed), then
/// rounded DOWN to a recorded distance. Under `immediateM` or `immediateS` from the turn
/// when it ends: the action alone («لف يمين»). If the next recorded distance is far below,
/// the line is held a moment so it ends right at it (at most `maxHoldS`).
/// The location is the guidance engine's own (Mapbox: map-matched; ours: raw fixes), never
/// the smoothed map dot.
enum NavPromptTiming {
    /// The turn is right here when the line ends: no distance, just the action.
    static let immediateM = 40.0
    static let immediateS = 3.0
    /// A line ends at most this far before the distance it says (else it is held).
    static let maxErrorM = 15.0
    /// Room for the unknowns (start latency varies ±0.15 s, the speed a little): the distance said
    /// is chosen this much below where the line should end.
    static func safetyM(_ v: Double) -> Double { 3 + 0.25 * v }
    /// A held line aims to end this far above the distance it says (a little early, never late).
    static func holdMarginM(_ v: Double) -> Double { safetyM(v) + 3 }
    /// Never held longer than this (the cue is not delayed into the next one).
    static let maxHoldS = 8.0
    /// The device voice: seconds per character (ar-SA at the rate `NavVoice` uses).
    static let deviceSecondsPerChar = 0.075

    /// From «play» to the first sample heard: clips composed off the main thread and the audio
    /// session activated; the device voice also wakes the synthesizer.
    static func startLatencyS(_ c: NavVoiceChoice) -> Double { c == .sary ? 0.35 : 0.6 }

    struct Plan: Equatable {
        /// The distance said (metres), nil: the immediate phrase (action only).
        var spokenM: Double?
        /// Where I will be (metres before the maneuver) when the line ends.
        var endM: Double
        /// Wait this long before playing (0: now).
        var holdS: Double = 0
    }

    static func isImmediate(_ endM: Double, speedMps v: Double) -> Bool {
        endM < immediateM || (v > 0.5 && endM / v < immediateS)
    }

    /// - distanceNowM: to the maneuver now (the engine's along-route distance, projected to now).
    /// - band: the largest distance we can say that is ≤ m (nil: under the smallest / too far).
    /// - duration: seconds of the whole line built for that distance (nil: the immediate phrase).
    static func plan(distanceNowM d: Double, speedMps: Double?, latencyS: Double, canHold: Bool, heldS: Double = 0,
                     band: (Double) -> Double?, duration: (Double?) -> Double) -> Plan {
        let v = max(0, speedMps ?? 0)
        func end(_ s: Double?, hold: Double = 0) -> Double { d - v * (hold + latencyS + duration(s)) }
        /* Not moving (or no speed): the distance now, rounded down. */
        guard v > 0.5 else {
            if d < immediateM { return Plan(spokenM: nil, endM: d) }
            return Plan(spokenM: band(d) ?? d, endM: d)
        }
        /* A first guess for the line's length, then the distance where it ends. */
        let guess = band(max(0, d - v * latencyS))
        var e = end(guess)
        if isImmediate(e, speedMps: v) { return Plan(spokenM: nil, endM: end(nil)) }
        let safe = safetyM(v)
        guard var b = band(e - safe) else {
            /* Farther than anything recorded: say what is true now (the caller says «كمّل سيده»). */
            return e > immediateM * 10 ? Plan(spokenM: e, endM: e) : Plan(spokenM: nil, endM: end(nil))
        }
        /* With the real line for that distance (its clip may be longer or shorter). */
        e = end(b)
        if e - safe < b {
            guard !isImmediate(e, speedMps: v), let lower = band(e - safe) else { return Plan(spokenM: nil, endM: end(nil)) }
            b = lower
            e = end(b)
        }
        /* Far above the distance it says: hold it so it ends right there (Google Maps' timing). */
        /* (Less the start-latency spread: a line that starts 0.15 s early ends that much farther.) */
        if e - b > maxErrorM - 0.15 * v - 1 {
            let hold = (e - b - holdMarginM(v)) / v
            if canHold, hold <= maxHoldS - heldS, !isImmediate(end(b, hold: hold), speedMps: v) {
                return Plan(spokenM: b, endM: end(b, hold: hold), holdS: hold)
            }
            /* «بعد ثلاثين» said at 55 m: the turn is close enough for the action alone. */
            if e < 2 * immediateM { return Plan(spokenM: nil, endM: end(nil)) }
        }
        return Plan(spokenM: b, endM: e)
    }

    /// The recorded «صوت سرى» distances (rounded down), or the device voice's own rounding.
    static func band(_ c: NavVoiceChoice, miles: Bool = DistanceUnits.miles) -> (Double) -> Double? {
        switch c {
        case .sary:
            return { m in SaryVoiceScript.floorBand(m, miles: miles)?.m }
        case .device:
            return { m in m >= SaryVoiceScript.nowM && !SaryVoiceScript.isFar(m, miles: false) ? NavText.flooredMeters(m) : nil }
        }
    }

    /// Seconds of a line for the voice that will say it.
    static func duration(_ c: NavVoiceChoice, clips: [String], text: String) -> Double {
        switch c {
        case .sary: return SaryVoiceCatalog.duration(clips)
        case .device: return Double(text.count) * deviceSecondsPerChar
        }
    }
}

// MARK: - How many lines per maneuver (build 22)

/// The owner on a long straight road (build 21): «بعد كيلو ونص عند التفرّع امسك اليسار», then «بعد كيلو…
/// امسك اليسار», then «امسك اليسار امسك اليسار» — for a fork he simply drove through. Mapbox asks for
/// a cue at each of its voice instructions (often three or four per maneuver); each was said.
///
/// Now every maneuver has a budget of two lines: ONE early (whatever distance it comes at) and
/// ONE final (within `finalS` / `finalM`). Never the same line twice for a maneuver. The budget
/// is kept per maneuver (kind, direction, place within `sameManeuverM`), so a reroute or Mapbox's
/// traffic refresh of the same road does not start it again; only a changed maneuver does.
/// A «soft» maneuver — a fork / lane / continue that stays on the same road or bends under
/// `softAngleDeg` — gets no early line, and one short «خلّك على اليسار» near it (or nothing if straight).
struct NavPromptBudget: Equatable {
    enum Stage: Int, Equatable { case early, final }

    struct Said: Equatable {
        var kind: NavManeuverKind
        var direction: NavTurnDirection?
        var at: LngLat
        var stages: Set<Int>
        var lines: [[String]]
    }

    static let finalS = 15.0
    static let finalM = 200.0
    static let sameManeuverM = 50.0
    static let softAngleDeg = 20.0

    private(set) var said: [Said] = []

    mutating func reset() { said = [] }

    static func stage(distanceM d: Double, speedMps v: Double?) -> Stage {
        d <= finalM || d / max(5, v ?? 0) <= finalS ? .final : .early
    }

    private func index(_ s: NavStep) -> Int? {
        said.firstIndex { $0.kind == s.maneuver.kind && $0.direction == s.maneuver.direction && Vehicle.distanceMeters($0.at, s.location) <= Self.sameManeuverM }
    }

    /// At most this many lines for one maneuver (the owner heard a fork four times): a soft one once.
    static func maxLines(_ s: NavStep, soft: Bool) -> Int { soft ? 1 : 2 }

    /// This stage of this maneuver has not been said, the per-maneuver cap is not reached, and no
    /// early line after a final one.
    func allows(_ s: NavStep, _ stage: Stage, soft: Bool = false) -> Bool {
        guard let i = index(s) else { return true }
        if said[i].lines.count >= Self.maxLines(s, soft: soft) { return false }
        if said[i].stages.contains(stage.rawValue) { return false }
        return !(stage == .early && said[i].stages.contains(Stage.final.rawValue))
    }

    /// Exactly this line was already said for this maneuver.
    func repeats(_ s: NavStep, clips: [String]) -> Bool {
        index(s).map { said[$0].lines.contains(clips) } ?? false
    }

    mutating func note(_ s: NavStep, _ stage: Stage, clips: [String]) {
        if let i = index(s) {
            said[i].stages.insert(stage.rawValue)
            said[i].lines.append(clips)
        } else {
            said.append(Said(kind: s.maneuver.kind, direction: s.maneuver.direction, at: s.location, stages: [stage.rawValue], lines: [clips]))
            if said.count > 60 { said.removeFirst(said.count - 60) }
        }
    }

    // MARK: soft maneuvers

    /// The route's bend at `at`: bearing ~40 m after minus ~40 m before (degrees, −180…180). nil off the line.
    static func bendDeg(_ c: [LngLat], at p: LngLat) -> Double? {
        guard c.count >= 3 else { return nil }
        /* The nearest vertex (the first of equals, as `min(by:)` picked), one distance per vertex
         * instead of two per comparison. */
        var i = 0, nearest = Double.infinity
        for k in c.indices {
            let d = Vehicle.distanceMeters(c[k], p)
            if d < nearest { nearest = d; i = k }
        }
        guard nearest < 30 else { return nil }
        var a = i, b = i
        while a > 0, Vehicle.distanceMeters(c[a], c[i]) < 40 { a -= 1 }
        while b < c.count - 1, Vehicle.distanceMeters(c[b], c[i]) < 40 { b += 1 }
        guard a < i, b > i else { return nil }
        let d = Vehicle.bearing(c[i], c[b]) - Vehicle.bearing(c[a], c[i])
        return (d + 540).truncatingRemainder(dividingBy: 360) - 180
    }

    private static func sameRoad(_ a: String?, _ b: String?) -> Bool {
        guard let a = a?.trimmingCharacters(in: .whitespaces), let b = b?.trimmingCharacters(in: .whitespaces), !a.isEmpty else { return false }
        return a == b
    }

    /// A fork / lane / continue that keeps to the same road, or bends less than `softAngleDeg`.
    static func isSoft(_ step: NavStep, previous: NavStep?, bendDeg: Double?) -> Bool {
        switch step.maneuver.kind {
        case .fork, .useLane, .continue, .newName: break
        default: return false
        }
        if sameRoad(previous?.roadName, step.roadName) { return true }
        return bendDeg.map { abs($0) < softAngleDeg } ?? false
    }

    /// The short line for a soft maneuver: «خلّك على اليمين/اليسار», or nothing when it goes straight on.
    static func softLine(_ step: NavStep) -> (text: String, clips: [String])? {
        switch step.maneuver.direction {
        case .right, .slightRight, .sharpRight: return ("خلّك على اليمين", ["turns_09"])
        case .left, .slightLeft, .sharpLeft: return ("خلّك على اليسار", ["turns_10"])
        default: return nil
        }
    }

    /// No clip twice in a row in one line («امسك اليسار امسك اليسار»), and no «وبعدها، <the same action>».
    static func tidy(_ clips: [String]) -> [String] {
        var out: [String] = []
        for c in clips where out.last != c { out.append(c) }
        if let t = out.firstIndex(of: "turns_14"), t > 0, t + 1 < out.count, Array(out[(t + 1)...]) == [out[t - 1]] {
            out.removeSubrange(t...)
        }
        return out
    }
}
