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
