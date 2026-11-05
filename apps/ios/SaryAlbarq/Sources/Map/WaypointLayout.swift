import CoreGraphics
import Foundation

/// Screen-space declutter for waypoint pins, run right after `ChipLayout` in the
/// same frame. The cars' name chips, note bubbles and group chips go first; the
/// pins fit around them:
///
/// - A pin always stands on its spot (a place on the ground must not move).
/// - Pins that touch each other fold into one cluster («٣ نقاط»); tap to zoom in.
/// - A pin's title shows only where it has room — never over a car's chip, a note,
///   another pin or title — and never in drive mode.
///
/// Pure and deterministic (order by id), like `ChipLayout`.
enum WaypointLayout {
    struct Item: Equatable {
        var id: String
        /// The spot on screen (the pin's tip).
        var anchor: CGPoint
        var pin: CGSize
        /// The title chip's size; nil for no title.
        var label: CGSize?
    }

    struct Options: Equatable {
        var bounds: CGRect
        /// What the car chips (and their notes / group chips) already took.
        var obstacles: [CGRect] = []
        var clusterSize = CGSize(width: 46, height: 34)
        var showLabels = true
        var gap: CGFloat = 3
    }

    struct Pin: Equatable {
        var id: String
        var frame: CGRect
        /// nil when the title has no room.
        var labelFrame: CGRect?
    }

    struct Cluster: Equatable {
        var key: String
        var ids: [String]
        var frame: CGRect
        var anchor: CGPoint
    }

    struct Result: Equatable {
        var pins: [Pin]
        var clusters: [Cluster]
        /// Everything drawn, for the map ornaments to avoid.
        var frames: [CGRect] { pins.map(\.frame) + pins.compactMap(\.labelFrame) + clusters.map(\.frame) }
    }

    static func pinFrame(_ it: Item) -> CGRect {
        CGRect(x: it.anchor.x - it.pin.width / 2, y: it.anchor.y - it.pin.height, width: it.pin.width, height: it.pin.height)
    }

    static func solve(_ items: [Item], _ o: Options) -> Result {
        let reach = o.bounds.insetBy(dx: -24, dy: -24)
        let near = items.filter { reach.contains($0.anchor) }.sorted { $0.id < $1.id }
        /* Pins that overlap join one cluster (transitively). */
        var parent = Array(near.indices)
        func root(_ i: Int) -> Int { var i = i; while parent[i] != i { i = parent[i] }; return i }
        let frames = near.map { pinFrame($0).insetBy(dx: -o.gap / 2, dy: -o.gap / 2) }
        for i in near.indices {
            for j in near.indices where j > i && frames[i].intersects(frames[j]) { parent[root(j)] = root(i) }
        }
        var comps: [Int: [Item]] = [:]
        for i in near.indices { comps[root(i), default: []].append(near[i]) }
        var pins: [Pin] = []
        var clusters: [Cluster] = []
        for k in comps.keys.sorted() {
            let c = comps[k]!
            if c.count == 1 {
                pins.append(Pin(id: c[0].id, frame: pinFrame(c[0]), labelFrame: nil))
            } else {
                let ids = c.map(\.id).sorted()
                let a = ChipLayout.centroid(c.map(\.anchor))
                let f = CGRect(x: a.x - o.clusterSize.width / 2, y: a.y - o.clusterSize.height, width: o.clusterSize.width, height: o.clusterSize.height)
                clusters.append(Cluster(key: ids.joined(separator: "|"), ids: ids, frame: f, anchor: a))
            }
        }
        guard o.showLabels else { return Result(pins: pins, clusters: clusters) }
        /* Titles under their pin, where nothing else is. */
        var taken = o.obstacles + pins.map(\.frame) + clusters.map(\.frame)
        let byId = Dictionary(near.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for idx in pins.indices {
            guard let it = byId[pins[idx].id], let size = it.label else { continue }
            let f = CGRect(x: it.anchor.x - size.width / 2, y: it.anchor.y + o.gap, width: size.width, height: size.height)
            let inside = o.bounds.contains(f)
            let clash = taken.contains { $0.intersects(f) }
            if inside && !clash {
                pins[idx].labelFrame = f
                taken.append(f.insetBy(dx: -o.gap, dy: -o.gap))
            }
        }
        return Result(pins: pins, clusters: clusters)
    }
}
