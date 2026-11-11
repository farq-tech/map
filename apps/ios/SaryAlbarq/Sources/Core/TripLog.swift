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
    /// Top speed so far (local only; see `Speed.swift`). Optional so older saved logs still decode.
    var peak: SpeedPeak?
    /// «أطول وقفة»: when the current stop began, and the longest one so far (seconds). Optional: older logs decode.
    var stopStartMs: Double?
    var longestStopS: Double?

    /// Faster than any car here: a GPS jump, not driving.
    static let maxSpeedMps = 70.0
    static let maxAccuracyM = 60.0
    /// A gap longer than this is not counted as moving time.
    static let maxGapS = 60.0
    static let movingSpeedMps = 1.5
    /// A silence that ended farther than this from where it began was driving, not a stop.
    static let stopMaxDriftM = 150.0

    private mutating func closeStop() {
        guard let s = stopStartMs, let t = lastAtMs else { return }
        longestStopS = max(longestStopS ?? 0, (t - s) / 1000)
        stopStartMs = nil
    }

    var totals: TripTotals? {
        guard let a = firstAtMs, let b = lastAtMs, b > a else { return nil }
        let dur = (b - a) / 1000
        return TripTotals(distanceM: Int(distanceM.rounded()), durationS: Int(dur.rounded()), movingS: Int(min(movingS, dur).rounded()))
    }

    mutating func add(lat: Double, lng: Double, accuracy: Double?, speed: Double?, atMs: Double, speedAccuracy: Double? = nil) {
        guard (accuracy ?? 0) <= Self.maxAccuracyM else { return }
        if let t = lastAtMs, atMs <= t { return }
        var pk = peak ?? SpeedPeak()
        pk.add(DeviceFix(lat: lat, lng: lng, accuracy: accuracy, heading: nil, speed: speed, atMs: atMs, speedAccuracy: speedAccuracy))
        peak = pk
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
        if gap <= Self.maxGapS, v >= Self.movingSpeedMps {
            movingS += gap
            closeStop()
        } else if gap > Self.maxGapS, d >= Self.stopMaxDriftM {
            /* A long silence that ended far away: not a stop (we just did not hear). */
            closeStop()
        } else {
            /* Standing (or a silence that ended where it began: parked with the screen locked). */
            if stopStartMs == nil { stopStartMs = pt }
        }
    }
}

/// Per-outing logs in UserDefaults (this device only; cleared on sign-out).
///
/// `update` runs on every shared GPS fix. It used to decode and re-encode every outing's log
/// on the main thread each time. Now the decoded logs and each outing's encoded JSON member are
/// kept in memory, keyed by the exact bytes last seen in UserDefaults: while those bytes are
/// unchanged, nothing is decoded, and only the changed outing is encoded before the object is
/// re-assembled. Any other writer of the key (a wipe, the settings clean-up) changes the bytes,
/// so the next read decodes again. Every write is still immediate (nothing waits in memory, so
/// nothing is lost if the app is killed), and the stored value is the same `[String: TripLog]` JSON.
enum TripLogStore {
    static let key = "sary.trip.logs.v1"

    private struct Cache {
        /// The stored bytes these logs were decoded from or written as (nil: no value stored).
        var data: Data?
        var logs: [String: TripLog]
        /// `"<id>":{…}` per outing, ready to join into the stored object.
        var members: [String: Data]
        /// False when a log could not be encoded alone (then `update` encodes everything, as before).
        var complete: Bool
    }

    private static let lock = NSLock()
    private static var cache: Cache?
    private static let encoder = JSONEncoder()

    /// The logs as stored now. Caller holds `lock`.
    private static func current(_ defaults: UserDefaults) -> Cache {
        let stored = defaults.data(forKey: key)
        if let c = cache, c.data == stored { return c }
        let logs = stored.flatMap { try? JSONDecoder().decode([String: TripLog].self, from: $0) } ?? [:]
        var members: [String: Data] = [:]
        var complete = true
        for (id, log) in logs {
            if let m = member(id, log) { members[id] = m } else { complete = false }
        }
        let c = Cache(data: stored, logs: logs, members: members, complete: complete)
        cache = c
        return c
    }

    /// One `"<id>":{…}` member of the stored JSON object. Caller holds `lock`.
    private static func member(_ id: String, _ log: TripLog) -> Data? {
        guard let k = try? encoder.encode(id), let v = try? encoder.encode(log) else { return nil }
        var m = k
        m.append(UInt8(ascii: ":"))
        m.append(v)
        return m
    }

    /// `{` members joined by `,` `}`: the same JSON object `JSONEncoder` writes for the dictionary.
    static func joinObject(_ members: [Data]) -> Data {
        var out = Data([UInt8(ascii: "{")])
        out.reserveCapacity(members.reduce(2) { $0 + $1.count + 1 })
        for (i, m) in members.enumerated() {
            if i > 0 { out.append(UInt8(ascii: ",")) }
            out.append(m)
        }
        out.append(UInt8(ascii: "}"))
        return out
    }

    static func load(_ outingId: String, defaults: UserDefaults = .standard) -> TripLog? {
        lock.lock()
        defer { lock.unlock() }
        return current(defaults).logs[outingId]
    }

    static func update(_ outingId: String, defaults: UserDefaults = .standard, _ f: (inout TripLog) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        var c = current(defaults)
        let before = c.logs[outingId]
        var log = before ?? TripLog()
        f(&log)
        /* Unchanged (a fix the log ignored): the stored value already says exactly this. */
        if before == log { return }
        c.logs[outingId] = log
        guard c.complete, let m = member(outingId, log) else {
            /* The old path: one encoder over everything (fails, and writes nothing, on a bad value). */
            cache = nil
            if let d = try? encoder.encode(c.logs) { defaults.set(d, forKey: key) }
            return
        }
        c.members[outingId] = m
        let data = joinObject(Array(c.members.values))
        defaults.set(data, forKey: key)
        c.data = data
        cache = c
    }

    static func forgetAll(defaults: UserDefaults = .standard) {
        lock.lock()
        defer { lock.unlock() }
        cache = nil
        defaults.removeObject(forKey: key)
    }
}
