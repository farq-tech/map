import Foundation

// «مخطط دروب البر»: the easiest / shortest / balanced way across the desert to a point, on the
// phone and offline, over a bundled cost grid (~90 m) built from open data by
// scripts/camp-sites/routes.py (the same rules, tested there and in DesertRouterTests).
// Why on the device: the grid is small (0.4–1.5 MB per region), works without signal in the
// desert, and needs no server change; a server would need the network exactly where there is none.

/// One region's grid (`Resources/CampSites/routes-<region>.bin`).
struct DesertGrid {
    enum Ground: UInt8 { case firm = 0, sand, crest, sabkha, wadi, forbidden, rock }
    static let track: UInt8 = 0x10, road: UInt8 = 0x20, bigWadi: UInt8 = 0x40

    struct Header: Decodable {
        var region: String
        var rows: Int, cols: Int
        var south: Double, west: Double, north: Double, east: Double
        var arcsec: Double
        var z0: Double
    }

    let header: Header
    /// Per cell: ground | flags.
    var cell: [UInt8]
    /// Dune-ridge axis 0…179°, 255 = none.
    var ridge: [UInt8]
    /// Elevation, metres.
    var elev: [Float]
    let dx: Double, dy: Double

    var rows: Int { header.rows }
    var cols: Int { header.cols }

    init(header: Header, cell: [UInt8], ridge: [UInt8], elev: [Float]) {
        self.header = header
        self.cell = cell
        self.ridge = ridge
        self.elev = elev
        dy = header.arcsec / 3600 * 110_574
        dx = header.arcsec / 3600 * 111_320 * cos((header.south + header.north) / 2 * .pi / 180)
    }

    /// A synthetic grid (tests): every cell `ground`, flat, no ridges.
    init(rows: Int, cols: Int, ground: Ground = .firm, south: Double = 25, west: Double = 46) {
        let a = 3.0 / 3600
        self.init(header: Header(region: "test", rows: rows, cols: cols, south: south, west: west,
                                 north: south + Double(rows) * a, east: west + Double(cols) * a, arcsec: 3, z0: 500),
                  cell: Array(repeating: ground.rawValue, count: rows * cols), ridge: Array(repeating: 255, count: rows * cols),
                  elev: Array(repeating: 500, count: rows * cols))
    }

    /// Reads the zlib file written by routes.py.
    static func load(_ data: Data) -> DesertGrid? {
        guard data.count > 6, let raw = inflate(data.subdata(in: 2..<(data.count - 4))) else { return nil }
        guard raw.count > 12, raw.prefix(8) == Data("SARYRT1\0".utf8) else { return nil }
        let n = Int(raw[8]) | Int(raw[9]) << 8 | Int(raw[10]) << 16 | Int(raw[11]) << 24
        guard raw.count >= 12 + n, let h = try? JSONDecoder().decode(Header.self, from: raw.subdata(in: 12..<(12 + n))) else { return nil }
        let count = h.rows * h.cols
        guard raw.count >= 12 + n + count * 4 else { return nil }
        var cell = [UInt8](repeating: 0, count: count), ridge = cell
        var elev = [Float](repeating: 0, count: count)
        raw.withUnsafeBytes { (b: UnsafeRawBufferPointer) in
            let base = 12 + n
            for i in 0..<count {
                let o = base + i * 4
                cell[i] = b[o]
                ridge[i] = b[o + 1]
                elev[i] = Float(h.z0 + Double(UInt16(b[o + 2]) | UInt16(b[o + 3]) << 8) / 4)
            }
        }
        return DesertGrid(header: h, cell: cell, ridge: ridge, elev: elev)
    }

    /// Raw DEFLATE (the zlib stream without its 2-byte header and Adler-32 trailer).
    private static func inflate(_ d: Data) -> Data? {
        try? (d as NSData).decompressed(using: .zlib) as Data
    }

    static func bundled(_ region: String) -> DesertGrid? {
        guard let url = Bundle.main.url(forResource: "routes-\(region)", withExtension: "bin"),
              let data = try? Data(contentsOf: url) else { return nil }
        return load(data)
    }

    /// The bundled region that holds both points.
    static func covering(_ a: LngLat, _ b: LngLat) -> String? {
        CampSiteCatalog.regions.first { r in bboxes[r].map { $0.contains(a) && $0.contains(b) } ?? false }
    }

    struct BBox { var s, w, n, e: Double; func contains(_ p: LngLat) -> Bool { p.lat > s && p.lat < n && p.lng > w && p.lng < e } }
    /// scripts/camp-sites/regions.py
    static let bboxes: [String: BBox] = [
        "thumamah": BBox(s: 25.0, w: 46.4, n: 25.4, e: 46.9),
        "nafud": BBox(s: 28.0, w: 41.0, n: 28.6, e: 41.8),
        "dahna": BBox(s: 24.85, w: 47.45, n: 25.25, e: 47.95),
    ]

    func ground(_ i: Int) -> Ground { Ground(rawValue: cell[i] & 0x0F) ?? .firm }

    func index(_ p: LngLat) -> Int {
        let h = header
        let r = min(max(Int((h.north - p.lat) / (h.north - h.south) * Double(rows)), 0), rows - 1)
        let c = min(max(Int((p.lng - h.west) / (h.east - h.west) * Double(cols)), 0), cols - 1)
        return r * cols + c
    }

    func point(_ i: Int) -> LngLat {
        let h = header
        let r = i / cols, c = i % cols
        return LngLat(lng: h.west + (Double(c) + 0.5) * (h.east - h.west) / Double(cols),
                      lat: h.north - (Double(r) + 0.5) * (h.north - h.south) / Double(rows))
    }
}

/// Why a stretch is hard (its Najdi words on the map and the card).
enum DesertHard: String, CaseIterable {
    case crest, against, sabkha, wadi, down, up, rock

    var text: String {
        switch self {
        case .crest: return "طعس قوي"
        case .against: return "طعس عكس العرق"
        case .sabkha: return "سبخة"
        case .wadi: return "بطن وادي"
        case .down: return "نزلة قوية"
        case .up: return "طلعة قوية"
        case .rock: return "منحدر صخري"
        }
    }

    /// «كيف تتجنبها».
    var tip: String {
        switch self {
        case .crest: return "لفّ مع بطن الفلج بدل ما تقطع الطعس"
        case .against: return "امشِ مع العرق لين تلقى قطعة منخفضة ثم اعبر"
        case .sabkha: return "دُر حول السبخة من الأرض الصلبة"
        case .wadi: return "اعبر الوادي عرضيًا ولا تمشي في بطنه"
        case .down: return "نزلة قوية: انزل مع ميلها بشويش أو لف حولها"
        case .up: return "طلعة قوية: خذها بزاوية أو لف حولها"
        case .rock: return "منحدر صخري: دوّر مدخل أسهل"
        }
    }
}

/// The router (mirrors scripts/camp-sites/routes.py).
enum DesertRouter {
    enum Mode: String, CaseIterable, Identifiable {
        case easy, balanced, short
        var id: String { rawValue }
        var label: String {
            switch self {
            case .easy: return "الأسهل"
            case .balanced: return "المتوازن"
            case .short: return "الأقصر"
            }
        }
        var detail: String {
            switch self {
            case .easy: return "أقل مشقة، حتى لو أطول"
            case .balanced: return "بين المشقة والمسافة"
            case .short: return "أقصر مسافة، وفيه مقاطع صعبة"
            }
        }
    }

    static let effort: [DesertGrid.Ground: Double] = [.firm: 1.0, .sand: 1.7, .crest: 4.5, .sabkha: 9.0, .wadi: 2.5, .rock: 6.0]
    static let speedKmh: [DesertGrid.Ground: Double] = [.firm: 35, .sand: 18, .crest: 7, .sabkha: 10, .wadi: 20, .rock: 6]
    static let trackEffort = 0.45, trackKmh = 40.0
    static let roadEffort = 0.35, roadKmh = 70.0
    static let maxGrade = 0.32
    static let hardGrade = 0.15

    /// Cost per metre of moving into a cell (nil: refused) and why it is hard.
    static func effort(ground g: DesertGrid.Ground, flags: UInt8, ridge: UInt8, bearing: Double, grade: Double, rain: Bool) -> (Double?, DesertHard?) {
        if g == .forbidden { return (nil, nil) }
        if flags & DesertGrid.bigWadi != 0, rain, flags & DesertGrid.road == 0 { return (nil, .wadi) }
        if abs(grade) > maxGrade, flags & (DesertGrid.track | DesertGrid.road) == 0 { return (nil, grade < 0 ? .down : .up) }
        var base: Double
        var why: DesertHard?
        if flags & DesertGrid.road != 0 {
            base = roadEffort
        } else if flags & DesertGrid.track != 0 {
            base = trackEffort
        } else {
            base = (effort[g] ?? 1) * (rain && g == .wadi ? 3 : 1)
            switch g {
            case .crest: why = .crest
            case .sabkha: why = .sabkha
            case .wadi: why = .wadi
            case .rock: why = .rock
            default: break
            }
            if g == .sand || g == .crest, ridge != 255 {
                let cross = abs(sin((bearing - Double(ridge)) * .pi / 180))
                base *= 1 + 1.6 * cross
                if cross > 0.75, why == nil { why = .against }
            }
        }
        let a = abs(grade)
        base *= 1 + (a / 0.10) * (a / 0.10)
        if a > hardGrade, why == nil { why = grade < 0 ? .down : .up }
        return (base, why)
    }

    static func stepCost(_ mode: Mode, effort: Double, dist: Double) -> Double {
        switch mode {
        case .short: return dist
        case .balanced: return dist * effort.squareRoot()
        case .easy: return dist * effort
        }
    }

    private static let nb: [(Int, Int)] = [(-1, 0), (1, 0), (0, -1), (0, 1), (-1, -1), (-1, 1), (1, -1), (1, 1)]

    /// A* over the grid. Returns cell indices from a to b, or nil.
    static func route(_ g: DesertGrid, from a: Int, to b: Int, mode: Mode, rain: Bool, maxExpand: Int = 3_000_000) -> [Int]? {
        let n = g.rows * g.cols
        var best = [Double](repeating: .infinity, count: n)
        var prev = [Int32](repeating: -1, count: n)
        let floor: Double = {
            switch mode {
            case .short: return 1
            case .balanced: return min(trackEffort, roadEffort).squareRoot()
            case .easy: return min(trackEffort, roadEffort)
            }
        }()
        let br = b / g.cols, bc = b % g.cols
        func h(_ i: Int) -> Double {
            let r = i / g.cols, c = i % g.cols
            return floor * hypot(Double(r - br) * g.dy, Double(c - bc) * g.dx)
        }
        var heap = MinHeap()
        best[a] = 0
        heap.push(h(a), a)
        var expanded = 0
        /* Per-neighbour geometry, computed once. */
        let geo = nb.map { (dr, dc) -> (Int, Int, Double, Double) in
            let d = hypot(Double(dr) * g.dy, Double(dc) * g.dx)
            let bearing = (atan2(Double(dc) * g.dx, Double(-dr) * g.dy) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
            return (dr, dc, d, bearing)
        }
        while let (f, i) = heap.pop() {
            if i == b {
                var path = [b]
                var k = b
                while prev[k] >= 0 { k = Int(prev[k]); path.append(k) }
                return path.reversed()
            }
            let gi = best[i]
            if f - h(i) > gi + 1e-6 { continue }
            expanded += 1
            if expanded > maxExpand { return nil }
            let r = i / g.cols, c = i % g.cols
            for (dr, dc, d, bearing) in geo {
                let rr = r + dr, cc = c + dc
                guard rr >= 0, rr < g.rows, cc >= 0, cc < g.cols else { continue }
                let j = rr * g.cols + cc
                let grade = Double(g.elev[j] - g.elev[i]) / d
                let (e, _) = effort(ground: g.ground(j), flags: g.cell[j] & 0xF0, ridge: g.ridge[j], bearing: bearing, grade: grade, rain: rain)
                guard let e else { continue }
                let ng = gi + stepCost(mode, effort: e, dist: d)
                if ng < best[j] {
                    best[j] = ng
                    prev[j] = Int32(i)
                    heap.push(ng + h(j), j)
                }
            }
        }
        return nil
    }

    struct HardStretch: Equatable {
        var reason: DesertHard
        var points: [LngLat]
        var meters: Double
    }

    struct Option: Identifiable, Equatable {
        var mode: Mode
        var points: [LngLat]
        var distanceM: Double
        var minutes: Double
        var trackPercent: Double
        var hard: [HardStretch]
        var id: String { mode.rawValue }

        /// Metres of each hard kind, most first.
        var hardTotals: [(DesertHard, Double)] {
            var t: [DesertHard: Double] = [:]
            for h in hard { t[h.reason, default: 0] += h.meters }
            return t.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
        }

        /// «كيف تتجنب الصعب».
        var tip: String? { hardTotals.first?.0.tip }
    }

    static func summarize(_ g: DesertGrid, _ path: [Int], mode: Mode, rain: Bool) -> Option {
        var dist = 0.0, hours = 0.0, onTrack = 0.0
        var hard: [HardStretch] = []
        var open: (reason: DesertHard, end: Int)?
        for (i, j) in zip(path, path.dropFirst()) {
            let r = i / g.cols, c = i % g.cols, rr = j / g.cols, cc = j % g.cols
            let d = hypot(Double(rr - r) * g.dy, Double(cc - c) * g.dx)
            let bearing = (atan2(Double(cc - c) * g.dx, Double(r - rr) * g.dy) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
            let grade = Double(g.elev[j] - g.elev[i]) / d
            let gr = g.ground(j), fl = g.cell[j] & 0xF0
            let (_, why) = effort(ground: gr, flags: fl, ridge: g.ridge[j], bearing: bearing, grade: grade, rain: rain)
            var v: Double
            if fl & DesertGrid.road != 0 { v = roadKmh } else if fl & DesertGrid.track != 0 { v = trackKmh; onTrack += d } else {
                v = speedKmh[gr] ?? 10
                if why == .against { v *= 0.6 }
            }
            dist += d
            hours += d / 1000 / v
            if let why {
                if let o = open, o.reason == why, o.end == i, !hard.isEmpty {
                    hard[hard.count - 1].points.append(g.point(j))
                    hard[hard.count - 1].meters += d
                } else {
                    hard.append(HardStretch(reason: why, points: [g.point(i), g.point(j)], meters: d))
                }
                open = (why, j)
            } else {
                open = nil
            }
        }
        return Option(mode: mode, points: path.map(g.point), distanceM: dist, minutes: hours * 60,
                      trackPercent: dist > 0 ? 100 * onTrack / dist : 0, hard: hard.filter { $0.meters >= 120 })
    }

    /// The three options (fewer when two coincide or one finds no way).
    static func options(_ g: DesertGrid, from a: LngLat, to b: LngLat, rain: Bool) -> [Option] {
        let ia = g.index(a), ib = g.index(b)
        var out: [Option] = []
        for m in Mode.allCases {
            guard let p = route(g, from: ia, to: ib, mode: m, rain: rain) else { continue }
            let o = summarize(g, p, mode: m, rain: rain)
            if out.contains(where: { $0.points == o.points }) { continue }
            out.append(o)
        }
        return out
    }
}

/// A small binary min-heap of (priority, index).
struct MinHeap {
    private var a: [(Double, Int)] = []
    var isEmpty: Bool { a.isEmpty }

    mutating func push(_ p: Double, _ v: Int) {
        a.append((p, v))
        var i = a.count - 1
        while i > 0 {
            let up = (i - 1) / 2
            if a[up].0 <= a[i].0 { break }
            a.swapAt(up, i)
            i = up
        }
    }

    mutating func pop() -> (Double, Int)? {
        guard !a.isEmpty else { return nil }
        let top = a[0]
        let last = a.removeLast()
        if !a.isEmpty {
            a[0] = last
            var i = 0
            while true {
                let l = 2 * i + 1, r = l + 1
                var m = i
                if l < a.count, a[l].0 < a[m].0 { m = l }
                if r < a.count, a[r].0 < a[m].0 { m = r }
                if m == i { break }
                a.swapAt(m, i)
                i = m
            }
        }
        return top
    }
}
