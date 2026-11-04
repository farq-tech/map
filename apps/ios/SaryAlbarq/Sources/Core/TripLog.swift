import Foundation

/// My own trip totals for an outing, kept on THIS device only.
///
/// Built from the fixes the phone already takes while I share; no point is
/// ever stored, only running totals (distance, first/last time, moving time).
/// After the outing ends I may choose «شارك ملخصي» to send the three numbers.
struct TripTotals: Codable, Equatable {
    var distanceM: Int
    var durationS: Int
    var movingS: Int
}

struct TripLog: Codable, Equatable {
    var distanceM: Double = 0
    var movingS: Double = 0
    var firstAtMs: Double?
    var lastAtMs: Double?
    /// The previous accepted fix (kept only to measure the next step; overwritten every fix).
    var lastLat: Double?
    var lastLng: Double?

    /// Faster than any car here: a GPS jump, not driving.
    static let maxSpeedMps = 70.0
    static let maxAccuracyM = 60.0
    /// A gap longer than this is not counted as moving time.
    static let maxGapS = 60.0
    static let movingSpeedMps = 1.5

    var totals: TripTotals? {
        guard let a = firstAtMs, let b = lastAtMs, b > a else { return nil }
        let dur = (b - a) / 1000
        return TripTotals(distanceM: Int(distanceM.rounded()), durationS: Int(dur.rounded()), movingS: Int(min(movingS, dur).rounded()))
    }

    mutating func add(lat: Double, lng: Double, accuracy: Double?, speed: Double?, atMs: Double) {
        guard (accuracy ?? 0) <= Self.maxAccuracyM else { return }
        if let t = lastAtMs, atMs <= t { return }
        defer {
            lastLat = lat
            lastLng = lng
            lastAtMs = atMs
            if firstAtMs == nil { firstAtMs = atMs }
        }
        guard let pl = lastLat, let pg = lastLng, let pt = lastAtMs else { return }
        let gap = (atMs - pt) / 1000
        let d = Vehicle.distanceMeters(LngLat(lng: pg, lat: pl), LngLat(lng: lng, lat: lat))
        guard d / max(gap, 0.5) <= Self.maxSpeedMps else { return }
        /* Jitter while parked is not distance. */
        if d >= 8 { distanceM += d }
        let v = speed ?? d / max(gap, 0.5)
        if gap <= Self.maxGapS, v >= Self.movingSpeedMps { movingS += gap }
    }
}

/// Per-outing logs in UserDefaults (this device only; cleared on sign-out).
enum TripLogStore {
    static let key = "sary.trip.logs.v1"

    static func load(_ outingId: String, defaults: UserDefaults = .standard) -> TripLog? {
        guard let d = defaults.data(forKey: key), let all = try? JSONDecoder().decode([String: TripLog].self, from: d) else { return nil }
        return all[outingId]
    }

    static func update(_ outingId: String, defaults: UserDefaults = .standard, _ f: (inout TripLog) -> Void) {
        var all: [String: TripLog] = (defaults.data(forKey: key)).flatMap { try? JSONDecoder().decode([String: TripLog].self, from: $0) } ?? [:]
        var log = all[outingId] ?? TripLog()
        f(&log)
        all[outingId] = log
        if let d = try? JSONEncoder().encode(all) { defaults.set(d, forKey: key) }
    }

    static func forgetAll(defaults: UserDefaults = .standard) { defaults.removeObject(forKey: key) }
}
