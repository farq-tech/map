import CoreGraphics
import Foundation

/// Screen-space declutter for the name chips and note bubbles over the cars.
///
/// Cars that are close on screen (zoomed out, or parked together) would stack
/// their chips on top of each other. This turns raw chip positions into a
/// readable layout, in physical screen points (top-left origin):
///
/// - Chips whose boxes collide join one cluster. A cluster of up to
///   `maxStack` chips is stacked in a column above its cars, each chip tied
///   to its car by a leader line.
/// - A bigger cluster folds its friends into one group chip («٣ سيارات»),
///   which the map expands on tap (zoom in, or list them when parked together).
/// - «أنت» is never folded into a group, keeps the slot nearest its car and is
///   drawn last (on top).
/// - A note bubble shows only where it has room; in a crowd it collapses to a
///   small indicator on the chip.
///
/// Pure and deterministic (same input → same output; order is by id, not by
/// screen position, so chips do not swap places while cars move).
enum ChipLayout {
    struct Item: Equatable {
        var id: String
        /// The car on screen.
        var anchor: CGPoint
        /// The name chip's size (with its note indicator, if it has a note).
        var chip: CGSize
        /// The note bubble's size, when the member has a note to show.
        var note: CGSize? = nil
        var isMe: Bool = false
        /// Higher wins ties (live > last known > lost).
        var priority: Int = 0
    }

    struct Options: Equatable {
        /// The visible map, in screen points.
        var bounds: CGRect
        /// Space between the car's centre and the bottom of its chip.
        var lift: CGFloat = 22
        /// Space between stacked chips.
        var gap: CGFloat = 4
        /// The most chips stacked in one column before friends fold into a group.
        var maxStack: Int = 3
        /// Size of the group chip («٣ سيارات»).
        var groupSize = CGSize(width: 92, height: 28)
        /// Members the person spread out (tapped their group while parked together):
        /// a cluster made only of these is listed in a column, never folded.
        var expanded: Set<String> = []
    }

    struct Placement: Equatable {
        var id: String
        var anchor: CGPoint
        /// Where the chip goes.
        var frame: CGRect
        /// Where the note bubble goes (above the chip); nil when it has no note or it collapsed.
        var noteFrame: CGRect?
        /// The member has a note but there is no room: show the indicator on the chip.
        var noteCollapsed: Bool
        /// The chip moved away from its car: draw a line from the car to the chip.
        var leader: Bool
        var isMe: Bool
    }

    struct Group: Equatable {
        /// Stable key: the member ids, sorted, joined.
        var key: String
        var ids: [String]
        var frame: CGRect
        /// Centroid of the folded cars.
        var anchor: CGPoint
    }

    struct Result: Equatable {
        /// Chips to draw, back to front («أنت» last, on top).
        var chips: [Placement]
        /// Group chips; their members are not in `chips`.
        var groups: [Group]
    }

    static func groupKey(_ ids: [String]) -> String { ids.sorted().joined(separator: "|") }

    /// The chip's natural place: centred over its car.
    static func natural(_ it: Item, lift: CGFloat) -> CGRect {
        CGRect(x: it.anchor.x - it.chip.width / 2, y: it.anchor.y - lift - it.chip.height, width: it.chip.width, height: it.chip.height)
    }

    /// Drive mode: name chips over the nearest friends only (`driveNamed`); the others are their car alone.
    static let driveNamed = 2

    /// The chips that keep their name while driving: «أنت» and the `limit` friends nearest to it on screen
    /// (ties by id, so the pick does not flicker). Without «أنت» on the map, or with few friends: all of them.
    /// `keep`: friends who must stay named however far they are (stuck, speaking on the radio): safety first.
    static func namedNearest(_ items: [Item], limit: Int, keep: Set<String> = []) -> Set<String> {
        let all = Set(items.map(\.id))
        guard let me = items.first(where: \.isMe) else { return all }
        let friends = items.filter { !$0.isMe }
        guard friends.count > limit else { return all }
        func d(_ it: Item) -> CGFloat { hypot(it.anchor.x - me.anchor.x, it.anchor.y - me.anchor.y) }
        let near = friends.sorted { d($0) == d($1) ? $0.id < $1.id : d($0) < d($1) }.prefix(max(0, limit))
        return Set([me.id] + near.map(\.id)).union(keep.intersection(all))
    }

    // MARK: -

    static func solve(_ items: [Item], _ o: Options) -> Result {
        /* Cars far off the screen are the edge arrows' business: place them naturally, never cluster them. */
        let reach = o.bounds.insetBy(dx: -120, dy: -120)
        let near = items.filter { reach.contains($0.anchor) }.sorted(by: order)
        let far = items.filter { !reach.contains($0.anchor) }

        /* First, chips that collide where they naturally sit belong together (transitively)... */
        var parent = Array(near.indices)
        func root(_ i: Int) -> Int { var i = i; while parent[i] != i { i = parent[i] }; return i }
        let nat = near.map { natural($0, lift: o.lift).insetBy(dx: -o.gap / 2, dy: -o.gap / 2) }
        for i in near.indices {
            for j in near.indices where j > i && nat[i].intersects(nat[j]) { parent[root(j)] = root(i) }
        }
        var comps: [Int: [Item]] = [:]
        for i in near.indices { comps[root(i), default: []].append(near[i]) }
        var units: [Unit] = comps.keys.sorted().map { Unit(items: comps[$0]!.sorted(by: order), o) }
        /* ...then laid-out clusters that still collide merge, until none do. Each merge removes a unit, so this ends. */
        var merged = true
        while merged {
            merged = false
            outer: for i in units.indices {
                for j in units.indices where j > i {
                    if units[i].box.insetBy(dx: -o.gap / 2, dy: -o.gap / 2).intersects(units[j].box) {
                        let joined = Unit(items: (units[i].items + units[j].items).sorted(by: order), o)
                        units.remove(at: j)
                        units[i] = joined
                        merged = true
                        break outer
                    }
                }
            }
        }

        /* Notes: only where they have room, «أنت» first. A note in a crowd collapses. */
        var taken = units.map(\.box)
        var placements: [Placement] = []
        let noteOrder = units.indices.sorted { a, b in
            let ua = units[a], ub = units[b]
            if ua.hasMe != ub.hasMe { return ua.hasMe }
            return order(ua.items[0], ub.items[0])
        }
        var byUnit: [Int: [Placement]] = [:]
        for ui in noteOrder {
            var ps = units[ui].placements
            for k in ps.indices {
                guard let note = units[ui].items.first(where: { $0.id == ps[k].id })?.note else { continue }
                guard units[ui].items.count == 1 else { ps[k].noteCollapsed = true; continue }
                let f = ps[k].frame
                let nf = CGRect(x: f.midX - note.width / 2, y: f.minY - o.gap / 2 - note.height, width: note.width, height: note.height)
                let clash = taken.enumerated().contains { idx, r in idx != ui && r.intersects(nf) }
                    || placements.contains { $0.noteFrame?.intersects(nf) ?? false }
                    || nf.minY < o.bounds.minY
                if clash {
                    ps[k].noteCollapsed = true
                } else {
                    ps[k].noteFrame = nf
                    taken[ui] = taken[ui].union(nf)
                }
            }
            byUnit[ui] = ps
            placements += ps
        }

        for it in far {
            placements.append(Placement(id: it.id, anchor: it.anchor, frame: natural(it, lift: o.lift), noteFrame: nil,
                                        noteCollapsed: it.note != nil, leader: false, isMe: it.isMe))
        }
        /* Back to front: friends by priority, «أنت» last so it is always on top. */
        placements.sort { a, b in
            if a.isMe != b.isMe { return !a.isMe }
            return a.id < b.id
        }
        return Result(chips: placements, groups: units.compactMap(\.group))
    }

    /// Stable order: «أنت» first, then priority, then id.
    static func order(_ a: Item, _ b: Item) -> Bool {
        if a.isMe != b.isMe { return a.isMe }
        if a.priority != b.priority { return a.priority > b.priority }
        return a.id < b.id
    }

    /// One cluster and its layout.
    struct Unit {
        var items: [Item]
        var placements: [Placement] = []
        var group: Group?
        var box: CGRect = .null
        var hasMe: Bool { items.contains(where: \.isMe) }

        init(items: [Item], _ o: Options) {
            self.items = items
            if items.count == 1 {
                let it = items[0]
                var f = ChipLayout.natural(it, lift: o.lift)
                /* Right under the top chrome: the chip goes below the car instead of under the chrome. */
                let flipped = f.minY < o.bounds.minY && o.bounds.contains(it.anchor)
                if flipped { f.origin.y = it.anchor.y + o.lift }
                placements = [Placement(id: it.id, anchor: it.anchor, frame: Self.clamped(f, o), noteFrame: nil, noteCollapsed: false, leader: flipped, isMe: it.isMe)]
                box = placements[0].frame
                return
            }
            let me = items.first(where: \.isMe)
            let friends = items.filter { !$0.isMe }
            let key = ChipLayout.groupKey(friends.map(\.id))
            /* Spread out by the person; a column that grows into one more chip stays spread. */
            let newcomers = friends.filter { !o.expanded.contains($0.id) }.count
            let expanded = newcomers < friends.count && newcomers <= 1
            let fold = !expanded && items.count > o.maxStack && friends.count >= 2
            /* The column: «أنت» nearest the cars, then the rest (or their group chip). */
            var column: [(id: String?, size: CGSize, anchor: CGPoint, isMe: Bool)] = []
            if let me { column.append((me.id, me.chip, me.anchor, true)) }
            if fold {
                column.append((nil, o.groupSize, ChipLayout.centroid(friends.map(\.anchor)), false))
            } else {
                for f in friends { column.append((f.id, f.chip, f.anchor, false)) }
            }
            let anchors = items.map(\.anchor)
            let cx = ChipLayout.centroid(anchors).x
            let width = column.map(\.size.width).max() ?? 0
            let height = column.map(\.size.height).reduce(0, +) + o.gap * CGFloat(max(0, column.count - 1))
            /* Above the highest car; below the lowest one if that would run off the top. */
            let topCar = anchors.map(\.y).min() ?? 0
            let lowCar = anchors.map(\.y).max() ?? 0
            let above = topCar - o.lift - height >= o.bounds.minY
            var x = cx
            x = min(max(x, o.bounds.minX + width / 2 + 4), o.bounds.maxX - width / 2 - 4)
            var frames: [CGRect] = []
            if above {
                var bottom = topCar - o.lift
                for c in column {
                    frames.append(CGRect(x: x - c.size.width / 2, y: bottom - c.size.height, width: c.size.width, height: c.size.height))
                    bottom -= c.size.height + o.gap
                }
            } else {
                var top = lowCar + o.lift
                for c in column {
                    frames.append(CGRect(x: x - c.size.width / 2, y: top, width: c.size.width, height: c.size.height))
                    top += c.size.height + o.gap
                }
            }
            for (c, f) in zip(column, frames) {
                if let id = c.id {
                    /* A chip still sitting right over its car needs no line. */
                    let natural = CGPoint(x: c.anchor.x, y: c.anchor.y - o.lift)
                    let attach = CGPoint(x: f.midX, y: above ? f.maxY : f.minY)
                    let moved = hypot(attach.x - natural.x, attach.y - natural.y) > 6
                    placements.append(Placement(id: id, anchor: c.anchor, frame: f, noteFrame: nil, noteCollapsed: false, leader: moved, isMe: c.isMe))
                } else {
                    group = Group(key: key, ids: friends.map(\.id), frame: f, anchor: c.anchor)
                }
            }
            /* The cars and the lines up to the column belong to the cluster too: no other chip may sit on them. */
            let cars = anchors.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
            box = frames.reduce(cars) { $0.union($1) }
        }

        /// Keep a lone chip inside the screen horizontally (its car may be at the edge).
        static func clamped(_ f: CGRect, _ o: Options) -> CGRect {
            guard o.bounds.contains(CGPoint(x: f.midX, y: f.maxY)) else { return f }
            var r = f
            r.origin.x = min(max(r.minX, o.bounds.minX + 4), o.bounds.maxX - r.width - 4)
            return r
        }
    }

    static func centroid(_ pts: [CGPoint]) -> CGPoint {
        guard !pts.isEmpty else { return .zero }
        let s = pts.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: s.x / CGFloat(pts.count), y: s.y / CGFloat(pts.count))
    }
}

/// Where Mapbox's logo and attribution go: the first free candidate spot.
/// Mapbox's terms need both visible; they move, they are never hidden.
enum OrnamentSpot {
    struct Candidate: Equatable {
        /// Logo + attribution together, in screen points.
        var rect: CGRect
        var name: String
    }

    /// The first candidate that collides with nothing in `avoid` (the rally
    /// label, chips, our controls), or the one that collides least.
    static func choose(_ candidates: [Candidate], avoid: [CGRect]) -> Candidate? {
        guard !candidates.isEmpty else { return nil }
        func overlap(_ c: Candidate) -> CGFloat {
            avoid.reduce(0) { acc, r in
                let i = c.rect.intersection(r)
                return acc + (i.isNull ? 0 : i.width * i.height)
            }
        }
        if let free = candidates.first(where: { overlap($0) == 0 }) { return free }
        return candidates.min { overlap($0) < overlap($1) }
    }
}
