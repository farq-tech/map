import Foundation

/// RAM-only LRU keyed by tile, bounded by a byte cost. Nothing here ever touches the disk:
/// neither the enhanced tiles nor the raw parent tiles are persisted (docs/AI-SATELLITE.md).
/// Thread-safe (the tile callbacks arrive on Mapbox worker threads).
final class HiResTileCache<Value> {
    private struct Entry { var value: Value; var cost: Int; var tick: UInt64 }
    private var entries: [HiResTileID: Entry] = [:]
    private var tick: UInt64 = 0
    private let lock = NSLock()
    let limit: Int
    private(set) var totalCost = 0

    init(limitBytes: Int) { limit = limitBytes }

    var count: Int { lock.withLock { entries.count } }
    var bytes: Int { lock.withLock { totalCost } }

    func get(_ k: HiResTileID) -> Value? {
        lock.withLock {
            guard var e = entries[k] else { return nil }
            tick += 1
            e.tick = tick
            entries[k] = e
            return e.value
        }
    }

    func contains(_ k: HiResTileID) -> Bool { lock.withLock { entries[k] != nil } }

    func set(_ k: HiResTileID, _ v: Value, cost: Int) {
        lock.withLock {
            if let old = entries[k] { totalCost -= old.cost }
            tick += 1
            entries[k] = Entry(value: v, cost: cost, tick: tick)
            totalCost += cost
            /* Evict least-recently used until under the limit (the newest entry always stays). */
            while totalCost > limit, entries.count > 1,
                  let oldest = entries.filter({ $0.key != k }).min(by: { $0.value.tick < $1.value.tick }) {
                totalCost -= oldest.value.cost
                entries.removeValue(forKey: oldest.key)
            }
        }
    }

    func removeAll() {
        lock.withLock {
            entries.removeAll()
            totalCost = 0
        }
    }
}
