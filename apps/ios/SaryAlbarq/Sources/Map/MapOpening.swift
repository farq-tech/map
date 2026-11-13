import Foundation

/// Where a user-facing map OPENS. Never Riyadh just because it is the default:
/// explicit target (route / destination / picked point) → the live fix → the last
/// known place (persisted across launches, ignored after 30 days) → Riyadh.
enum MapOpening {
    static let riyadh = LngLat(lng: 46.6753, lat: 24.7136)
    static let maxAge: TimeInterval = 30 * 24 * 3600
    static let minWriteInterval: TimeInterval = 20

    private static let latKey = "sary.lastKnown.lat"
    private static let lngKey = "sary.lastKnown.lng"
    private static let atKey = "sary.lastKnown.at"

    /// Latest fix of this launch (set by `LocationSharer`); the persisted copy outlives it.
    nonisolated(unsafe) static var liveFix: LngLat?
    nonisolated(unsafe) private static var lastWrite = Date.distantPast

    /// The pure order. Internal for tests.
    static func resolve(explicit: LngLat?, fix: LngLat?, persisted: LngLat?) -> LngLat {
        explicit ?? fix ?? persisted ?? riyadh
    }

    static func center(explicit: LngLat? = nil, store: UserDefaults = .standard, now: Date = Date()) -> LngLat {
        resolve(explicit: explicit, fix: liveFix, persisted: ignoresPersisted ? nil : lastKnown(store: store, now: now))
    }

    /// The persisted last known place, nil when absent, invalid or older than 30 days.
    static func lastKnown(store: UserDefaults = .standard, now: Date = Date()) -> LngLat? {
        guard store.object(forKey: atKey) != nil, store.object(forKey: latKey) != nil, store.object(forKey: lngKey) != nil else { return nil }
        let at = Date(timeIntervalSince1970: store.double(forKey: atKey))
        let age = now.timeIntervalSince(at)
        guard age >= -60, age <= maxAge else { return nil }
        let p = LngLat(lng: store.double(forKey: lngKey), lat: store.double(forKey: latKey))
        guard (-90...90).contains(p.lat), (-180...180).contains(p.lng), !(p.lat == 0 && p.lng == 0) else { return nil }
        return p
    }

    /// Called for every believable fix; writes at most once per `minWriteInterval`.
    static func remember(_ p: LngLat, store: UserDefaults = .standard, now: Date = Date(), throttled: Bool = true) {
        liveFix = p
        guard (-90...90).contains(p.lat), (-180...180).contains(p.lng) else { return }
        if throttled, now.timeIntervalSince(lastWrite) < minWriteInterval { return }
        lastWrite = now
        store.set(p.lat, forKey: latKey)
        store.set(p.lng, forKey: lngKey)
        store.set(now.timeIntervalSince1970, forKey: atKey)
    }

    /// Demo / UI-test launches stay deterministic: no persisted place from an earlier run.
    private static var ignoresPersisted: Bool { ProcessInfo.processInfo.arguments.contains("-demo") }

    static func distanceM(_ a: LngLat, _ b: LngLat) -> Double {
        let k = 111_320.0
        let dy = (a.lat - b.lat) * k
        let dx = (a.lng - b.lng) * k * cos((a.lat + b.lat) / 2 * .pi / 180)
        return (dx * dx + dy * dy).squareRoot()
    }

    static func forgetLive() { liveFix = nil; lastWrite = .distantPast }
}
