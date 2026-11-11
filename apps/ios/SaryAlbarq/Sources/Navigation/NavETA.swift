import Foundation

/// «ما يخبرني وقت الوصول» (build 21): the arrival time on the banner always, and said by voice.
///
/// The source is the guidance engine's own remaining time (Mapbox: `RouteProgress.durationRemaining`,
/// from `driving-traffic`, live traffic). It is only smoothed here, never replaced:
///   * an exponential blend of the ARRIVAL TIME (now + remaining), so the clock does not jump;
///   * a short stop (a light, under `stopGraceS`) does not push the arrival later at all — the
///     router's number does not count down while I wait, the real arrival barely moves;
///   * a big change (a reroute, a jam) is taken at once.
struct NavETASmoother: Equatable {
    /// Time constant of the blend.
    static let tauS = 45.0
    /// Stopped shorter than this: the arrival is held.
    static let stopGraceS = 180.0
    /// Below this I am stopped.
    static let stoppedMps = 1.0
    /// A change this big is real news: taken at once.
    static let snapS = 600.0

    private(set) var arrival: Date?
    private var lastAt: Date?
    private var stoppedSince: Date?
    /// The next reading is taken as it is (`snapNext`).
    private var snapPending = false

    mutating func reset() { self = NavETASmoother() }

    /// A new route from here (a reroute): its remaining time is not a noisy reading of the old
    /// route's — the next one is taken at once. Build 36: a reroute that added 3 min was blended in
    /// over a minute or two, so the time left did not move with the new remaining distance.
    mutating func snapNext() { snapPending = true }

    /// One progress: the engine's remaining seconds, my speed. Returns the smoothed remaining seconds.
    @discardableResult
    mutating func update(remainingS: Double, speedMps: Double?, now: Date = Date()) -> Double {
        let target = now.addingTimeInterval(max(0, remainingS))
        defer { lastAt = now }
        guard let a = arrival, let last = lastAt else {
            arrival = target
            snapPending = false
            return max(0, remainingS)
        }
        if let v = speedMps, v < Self.stoppedMps {
            if stoppedSince == nil { stoppedSince = now }
        } else {
            stoppedSince = nil
        }
        let diff = target.timeIntervalSince(a)
        if snapPending || abs(diff) >= Self.snapS {
            snapPending = false
            arrival = target
        } else if let s = stoppedSince, now.timeIntervalSince(s) < Self.stopGraceS {
            /* Waiting at a light: the arrival stays where it was. */
        } else {
            let dt = max(0, now.timeIntervalSince(last))
            let k = 1 - exp(-dt / Self.tauS)
            arrival = a.addingTimeInterval(diff * k)
        }
        return max(0, arrival!.timeIntervalSince(now))
    }

    func remaining(_ now: Date = Date()) -> Double? { arrival.map { max(0, $0.timeIntervalSince(now)) } }
}

/// When the arrival is said: at the start, every 10 minutes, and when it moved by more than 5.
struct NavETAAnnouncer: Equatable {
    static let everyS = 600.0
    static let changeS = 300.0
    /// Nearly there: the arrival line says it, not this.
    static let minRemainingS = 90.0

    private(set) var lastArrival: Date?
    private(set) var lastAt: Date?

    mutating func reset() { self = NavETAAnnouncer() }

    func isDue(arrival: Date, now: Date = Date()) -> Bool {
        guard arrival.timeIntervalSince(now) >= Self.minRemainingS else { return false }
        guard let la = lastArrival, let at = lastAt else { return true }
        return now.timeIntervalSince(at) >= Self.everyS || abs(arrival.timeIntervalSince(la)) > Self.changeS
    }

    mutating func said(arrival: Date, now: Date = Date()) {
        lastArrival = arrival
        lastAt = now
    }

    /// «باقي … وتوصل.»: the nearest recorded duration (minutes → clip).
    static let clips: [(min: Double, key: String)] = [
        (0.5, "eta_01"), (1, "eta_02"), (2, "eta_03"), (3, "eta_04"), (5, "eta_05"), (10, "eta_06"), (15, "eta_07"),
        (20, "eta_08"), (30, "eta_09"), (45, "eta_10"), (60, "eta_11"), (90, "eta_12"), (120, "eta_13"), (180, "eta_14"), (240, "eta_15"),
    ]

    /// nil past ~5 h (nothing recorded that long: the device voice says the clock instead).
    static func clip(remainingS s: Double) -> String? {
        let m = max(0, s) / 60
        guard m <= 300 else { return nil }
        return clips.min { abs($0.min - m) < abs($1.min - m) }?.key
    }

    /// «توصل الساعة ١١:٤٢ م، باقي ١٨ د» (the device voice / CarPlay text).
    static func text(arrival: Date, remainingS: Double) -> String {
        "توصل الساعة \(NavText.clock(arrival))، باقي \(NavText.remaining(seconds: remainingS))"
    }
}
