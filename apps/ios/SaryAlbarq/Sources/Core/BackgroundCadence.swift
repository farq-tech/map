import CoreLocation
import Foundation

/// How often a position goes out while the app is in the background (screen
/// locked, another app, CarPlay). Pure, so it is tested on its own.
///
/// The socket is not used there (iOS suspends it): each send is one
/// `POST /api/outings/:id/positions`. The server allows 120 writes a minute per
/// person (`writeLimit` in routes/outings.js, shared with notes, heartbeats…),
/// at least 1 s between fixes (`minFixIntervalMs`) and refuses a fix older than
/// 60 s (`MAX_FIX_AGE_MS`). The fastest this cadence can go is one POST every
/// `distanceFloorMs` (12 a minute), far under the limit.
enum BackgroundCadence {
    enum Motion: Equatable { case fast, moving, parked }

    /// A send after this much movement, as long as `distanceFloorMs` has passed.
    static let distanceM = 50.0
    static let distanceFloorMs = 5_000.0
    static let lowPowerDistanceFloorMs = 10_000.0

    /// Speed unknown counts as moving: the phone never gets stuck in the slow, coarse tier.
    static func motion(speedMps: Double?) -> Motion {
        guard let s = speedMps, s >= 0 else { return .moving }
        if s >= Policy.slowMps { return .fast }
        if s >= Policy.stillMps { return .moving }
        return .parked
    }

    /// The longest gap between two sends: faster when moving, slower when parked.
    /// Low Power Mode doubles it (the person is told).
    static func intervalMs(_ m: Motion, lowPower: Bool) -> Double {
        let base: Double
        switch m {
        case .fast: base = 15_000
        case .moving: base = 20_000
        case .parked: base = 60_000
        }
        return lowPower ? base * 2 : base
    }

    struct Last: Equatable {
        var fix: DeviceFix
        var sentAtMs: Double
    }

    /// When the next send is due for `fix` (ms on the same clock as `last.sentAtMs`).
    /// Due now (or earlier) means send.
    static func dueAtMs(_ fix: DeviceFix, last: Last?, lowPower: Bool) -> Double {
        guard let last else { return -.infinity }
        let floor = lowPower ? lowPowerDistanceFloorMs : distanceFloorMs
        let moved = Geo.haversineMeters(last.fix.coordinate, fix.coordinate)
        if moved >= distanceM { return last.sentAtMs + floor }
        return last.sentAtMs + intervalMs(motion(speedMps: fix.speed), lowPower: lowPower)
    }

    /// GPS settings in the background: best when moving, reduced when parked (battery).
    static func accuracy(_ m: Motion) -> (desiredAccuracy: CLLocationAccuracy, distanceFilter: CLLocationDistance) {
        switch m {
        case .fast: return (kCLLocationAccuracyBest, 20)
        case .moving: return (kCLLocationAccuracyBest, 10)
        case .parked: return (kCLLocationAccuracyHundredMeters, 25)
        }
    }

    /// Retry after a failed send: 2 s, 4 s, 8 s … capped at 60 s, with jitter; a 429 waits at least 30 s.
    static func retryDelayMs(attempt: Int, rateLimited: Bool, rand: Double) -> Double {
        let base = min(60_000, 2_000 * pow(2, Double(max(0, attempt))))
        let jittered = base * (0.75 + 0.5 * rand)
        return rateLimited ? max(30_000, jittered) : jittered
    }
}
