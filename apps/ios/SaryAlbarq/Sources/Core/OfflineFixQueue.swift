import Foundation

/// Positions taken while nothing reached the server (no network, a dead zone in the desert),
/// kept on this phone and uploaded in ONE batch when the network is back
/// (`POST /api/outings/:id/positions/batch`). The server never shows them as live: the newest
/// becomes the last known position with its true time («آخر موقع قبل ٥ د») and the others fill
/// the trail. Pure apart from `load`/`save`, so it is tested on its own.
///
/// Rules:
///   * thinned: a fix is kept only if `minGapMs` passed or the phone moved `minMoveM` since the
///     last kept one (a parked car does not fill the queue);
///   * capped: at most `cap` fixes; past that the oldest go first;
///   * aged out: older than `maxAgeMs` (the server's backfill window) is dropped;
///   * at-least-once: a batch is removed only after the server said ok (`ack`); a batch whose
///     answer never came (app killed mid-upload) is simply sent again — the server ignores a
///     fix older than the one it has, so a repeat is harmless.
struct OfflineFixQueue: Codable, Equatable {
    struct Item: Codable, Equatable {
        var lat: Double
        var lng: Double
        var accuracy: Double?
        var heading: Double?
        var speed: Double?
        var mode: ShareMode
        var atMs: Double
    }

    static let cap = 300
    static let minGapMs = 20_000.0
    static let minMoveM = 75.0
    /// Same as the server's `backfillMaxAgeMs` (6 h).
    static let maxAgeMs = 6 * 3_600_000.0

    private(set) var items: [Item] = []

    var isEmpty: Bool { items.isEmpty }
    var count: Int { items.count }

    /// Keep this fix for later (if it adds something).
    @discardableResult
    mutating func enqueue(_ f: DeviceFix, mode: ShareMode) -> Bool {
        if let last = items.last {
            if f.atMs <= last.atMs { return false }
            let moved = Geo.haversineMeters(Geo.LatLng(lat: last.lat, lng: last.lng), f.coordinate)
            if f.atMs - last.atMs < Self.minGapMs && moved < Self.minMoveM { return false }
        }
        items.append(Item(lat: f.lat, lng: f.lng, accuracy: f.accuracy, heading: f.heading, speed: f.speed, mode: mode, atMs: f.atMs))
        if items.count > Self.cap { items.removeFirst(items.count - Self.cap) }
        return true
    }

    /// Drop what the server would refuse anyway.
    mutating func prune(nowMs: Double) {
        items.removeAll { nowMs - $0.atMs > Self.maxAgeMs - 60_000 }
    }

    /// The batch to upload now, oldest first, ages measured now. `upToMs` is what `ack` removes.
    func batch(nowMs: Double) -> (fixes: [WireFix], upToMs: Double)? {
        let fresh = items.filter { nowMs - $0.atMs <= Self.maxAgeMs - 60_000 }
        guard let last = fresh.last else { return nil }
        let wire = fresh.map {
            WireFix(lat: $0.lat, lng: $0.lng, accuracy: $0.accuracy, heading: $0.heading, speed: $0.speed,
                    mode: $0.mode, age_ms: max(0, (nowMs - $0.atMs).rounded()))
        }
        return (wire, last.atMs)
    }

    /// The server took the batch: forget every fix up to (and including) `upToMs`.
    mutating func ack(upToMs: Double) {
        items.removeAll { $0.atMs <= upToMs }
    }

    /// A fix newer than everything here reached the server live: what is queued is still worth
    /// sending (the trail), but nothing newer should be queued twice.
    mutating func clear() { items = [] }

    // MARK: persistence (survives the app being killed)

    static func key(user: String, outing: String) -> String { "sary.offlineFixes.v1.\(user).\(outing)" }

    static func load(user: String, outing: String, defaults: UserDefaults = .standard) -> OfflineFixQueue {
        guard let d = defaults.data(forKey: key(user: user, outing: outing)),
              let q = try? JSONDecoder().decode(OfflineFixQueue.self, from: d) else { return OfflineFixQueue() }
        return q
    }

    func save(user: String, outing: String, defaults: UserDefaults = .standard) {
        let k = Self.key(user: user, outing: outing)
        if items.isEmpty { defaults.removeObject(forKey: k); return }
        if let d = try? JSONEncoder().encode(self) { defaults.set(d, forKey: k) }
    }
}
