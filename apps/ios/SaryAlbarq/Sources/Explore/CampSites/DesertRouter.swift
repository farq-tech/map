import CryptoKit
import Foundation
import UIKit

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

    /// The bundled grid for `region`, read and inflated once and then kept in memory (routing,
    /// reroutes and the planner sheet all ask for it; parsing costs a 0.4–1.5 MB read and a full
    /// inflate each time). Thread-safe: callers run off the main thread. A memory warning drops it.
    static func bundled(_ region: String) -> DesertGrid? {
        BundledGridCache.grid(region) {
            guard let url = Bundle.main.url(forResource: "routes-\(region)", withExtension: "bin"),
                  let data = try? Data(contentsOf: url) else { return nil }
            return load(data)
        }
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

    /// Data-backed entry candidates on mapped OSM roads/tracks. Sorted by distance from the
    /// destination and spatially spread so the road router can try distinct approaches.
    func accessPoints(near target: LngLat, limit: Int = 4) -> [LngLat] {
        guard rows > 0, cols > 0, limit > 0 else { return [] }
        let candidates = cell.indices.compactMap { i -> (LngLat, Double)? in
            let flags = cell[i] & 0xF0
            guard flags & (Self.road | Self.track) != 0,
                  ground(i) != .forbidden else { return nil }
            let p = point(i)
            let d = Vehicle.distanceMeters(p, target)
            return d <= 30_000 ? (p, d) : nil
        }.sorted { $0.1 < $1.1 }

        var chosen: [LngLat] = []
        let spacing = max(180.0, hypot(dx, dy) * 3)
        for (point, _) in candidates {
            guard chosen.allSatisfy({ Vehicle.distanceMeters($0, point) >= spacing }) else { continue }
            chosen.append(point)
            if chosen.count == limit { break }
        }
        return chosen
    }
}

/// Per-region cache behind `DesertGrid.bundled`. The arrays are copy-on-write, so handing out
/// the cached struct shares its storage instead of copying megabytes.
private enum BundledGridCache {
    private static let lock = NSLock()
    private static var grids: [String: DesertGrid] = [:]
    private static let memoryWarning: NSObjectProtocol = NotificationCenter.default.addObserver(
        forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil
    ) { _ in
        BundledGridCache.clear()
    }

    static func grid(_ region: String, load: () -> DesertGrid?) -> DesertGrid? {
        _ = memoryWarning
        lock.lock()
        defer { lock.unlock() }
        if let cached = grids[region] { return cached }
        // Loaded under the lock so two concurrent first requests do not both parse the file.
        // A missing grid is not cached (cheap to look up, and never expected in a release build).
        guard let grid = load() else { return nil }
        grids[region] = grid
        return grid
    }

    static func clear() {
        lock.lock()
        grids.removeAll()
        lock.unlock()
    }
}

// MARK: - National tiles («دروب البر» for the whole Kingdom)
//
// Beyond the three bundled pilots, the same grid is built for the Kingdom as 1°×1° tiles
// (scripts/camp-sites/tiles.py) and served by apps/tiles (`/desert/manifest.json`,
// `/desert/tiles/<id>.bin`). Tiles do not overlap: every tile, and every pilot grid, sits on one
// global 3-arc-second lattice (cell edges at multiples of 1/1200°), so a corridor grid is cut out
// of any of them by lattice index (`DesertGrid.stitch`).

extension DesertGrid.BBox: Equatable {
    func intersects(_ o: DesertGrid.BBox) -> Bool { s < o.n && o.s < n && w < o.e && o.w < e }

    /// `o` lies inside (edges included, to a lattice-rounding tolerance).
    func covers(_ o: DesertGrid.BBox) -> Bool {
        let t = 1e-7
        return o.s >= s - t && o.n <= n + t && o.w >= w - t && o.e <= e + t
    }

    func intersection(_ o: DesertGrid.BBox) -> DesertGrid.BBox? {
        let r = DesertGrid.BBox(s: max(s, o.s), w: max(w, o.w), n: min(n, o.n), e: min(e, o.e))
        return r.s < r.n && r.w < r.e ? r : nil
    }
}

extension DesertGrid {
    var bbox: BBox { BBox(s: header.south, w: header.west, n: header.north, e: header.east) }

    /// One grid over `bbox` (snapped outward to the lattice) from `sources`, the first source
    /// winning where they overlap. Sources with another resolution or off the lattice are skipped.
    /// Cells no source covers are forbidden ground (no data is never a way through). nil when the
    /// box is empty, larger than `maxCells`, or no source covers any of it.
    static func stitch(_ sources: [DesertGrid], bbox: BBox, arcsec: Double = DesertTiles.arcsec,
                       maxCells: Int = DesertTiles.maxCorridorCells) -> DesertGrid? {
        let k = 3600 / arcsec
        let kS = Int((bbox.s * k + 1e-6).rounded(.down)), kN = Int((bbox.n * k - 1e-6).rounded(.up))
        let jW = Int((bbox.w * k + 1e-6).rounded(.down)), jE = Int((bbox.e * k - 1e-6).rounded(.up))
        let rows = kN - kS, cols = jE - jW
        guard rows > 0, cols > 0, rows <= maxCells / cols else { return nil }
        let count = rows * cols
        var cell = [UInt8](repeating: Ground.forbidden.rawValue, count: count)
        var ridge = [UInt8](repeating: 255, count: count)
        var elev = [Float](repeating: 0, count: count)
        var filled = [Bool](repeating: false, count: count)
        // Lowest priority first: a later (higher-priority) source overwrites.
        for src in sources.reversed() {
            let h = src.header
            guard abs(h.arcsec - arcsec) < 1e-9, src.rows > 0, src.cols > 0,
                  src.cell.count == src.rows * src.cols, src.ridge.count == src.cell.count, src.elev.count == src.cell.count
            else { continue }
            let north = h.north * k, west = h.west * k
            let iN = Int(north.rounded()), iW = Int(west.rounded())
            guard abs(north - Double(iN)) < 1e-4, abs(west - Double(iW)) < 1e-4 else { continue }
            let c0 = max(0, iW - jW), c1 = min(cols, iW + src.cols - jW)
            guard c1 > c0 else { continue }
            let len = c1 - c0
            for r in 0..<rows {
                // Output row r has its north edge at lattice line kN - r; source row rs at iN - rs.
                let rs = iN - kN + r
                guard rs >= 0, rs < src.rows else { continue }
                let o = r * cols + c0, so = rs * src.cols + (jW + c0 - iW)
                cell.replaceSubrange(o..<(o + len), with: src.cell[so..<(so + len)])
                ridge.replaceSubrange(o..<(o + len), with: src.ridge[so..<(so + len)])
                elev.replaceSubrange(o..<(o + len), with: src.elev[so..<(so + len)])
                filled.replaceSubrange(o..<(o + len), with: repeatElement(true, count: len))
            }
        }
        guard filled.contains(true) else { return nil }
        let header = Header(region: "corridor", rows: rows, cols: cols,
                            south: Double(kS) / k, west: Double(jW) / k, north: Double(kN) / k, east: Double(jE) / k,
                            arcsec: arcsec, z0: 0)
        return DesertGrid(header: header, cell: cell, ridge: ridge, elev: elev)
    }
}

/// Tile names and corridor geometry (mirrors scripts/camp-sites/regions.py).
enum DesertTiles {
    static let arcsec = 3.0
    /// The Kingdom's land bbox (generous; the manifest says which tiles really exist).
    static let kingdom = DesertGrid.BBox(s: 16, w: 34, n: 33, e: 56)
    /// A corridor is at most this many degrees on a side (≤ 3×3 tiles, ≤ ~2.1 M cells: the A*
    /// arrays stay ~30 MB). Larger asks fall back to the road route + final bearing.
    static let maxSpanDeg = 1.2
    /// Around the destination: mapped access points are looked for within 30 km of it.
    static let aroundTargetDeg = 0.3
    /// Around the road end / origin, so its cell and a few neighbours are inside.
    static let padDeg = 0.05
    static var maxCorridorCells: Int {
        let side = Int((maxSpanDeg * 3600 / arcsec).rounded()) + 2
        return side * side
    }

    /// `t{lat}_{lng}`: the south-west corner in integer degrees.
    struct TileID: Hashable {
        var lat: Int, lng: Int
        init(lat: Int, lng: Int) { self.lat = lat; self.lng = lng }
        init?(_ name: String) {
            guard name.hasPrefix("t") else { return nil }
            let parts = name.dropFirst().split(separator: "_", omittingEmptySubsequences: false)
            guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0.count <= 3 && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
                  let la = Int(parts[0]), let lo = Int(parts[1]) else { return nil }
            self.init(lat: la, lng: lo)
        }
        var name: String { "t\(lat)_\(lng)" }
        var bbox: DesertGrid.BBox { DesertGrid.BBox(s: Double(lat), w: Double(lng), n: Double(lat + 1), e: Double(lng + 1)) }
    }

    static func tile(containing p: LngLat) -> TileID { TileID(lat: Int(p.lat.rounded(.down)), lng: Int(p.lng.rounded(.down))) }

    /// Every tile intersecting `b`; an edge exactly on a degree does not pull in the neighbour.
    static func tiles(covering b: DesertGrid.BBox) -> [TileID] {
        guard b.n > b.s, b.e > b.w else { return [] }
        let la0 = Int(b.s.rounded(.down)), la1 = Int(b.n.rounded(.up))
        let lo0 = Int(b.w.rounded(.down)), lo1 = Int(b.e.rounded(.up))
        return (la0..<la1).flatMap { la in (lo0..<lo1).map { TileID(lat: la, lng: $0) } }
    }

    static func inKingdom(_ p: LngLat) -> Bool {
        p.lat >= kingdom.s && p.lat <= kingdom.n && p.lng >= kingdom.w && p.lng <= kingdom.e
    }

    /// The grid box to route to `target` from `hint` (the road route's end, or nil): the target with
    /// `aroundTargetDeg` around it, grown to take in the hint, then cut to `maxSpanDeg` on the
    /// hint's side (the target always keeps its margin). nil outside the Kingdom.
    static func corridor(from hint: LngLat?, to target: LngLat) -> DesertGrid.BBox? {
        guard inKingdom(target) else { return nil }
        var s = target.lat - aroundTargetDeg, n = target.lat + aroundTargetDeg
        var w = target.lng - aroundTargetDeg, e = target.lng + aroundTargetDeg
        if let h = hint {
            s = min(s, h.lat - padDeg); n = max(n, h.lat + padDeg)
            w = min(w, h.lng - padDeg); e = max(e, h.lng + padDeg)
        }
        func cut(_ lo: inout Double, _ hi: inout Double, keep t: Double) {
            guard hi - lo > maxSpanDeg else { return }
            if t - lo > hi - t { lo = hi - maxSpanDeg } else { hi = lo + maxSpanDeg }
        }
        cut(&s, &n, keep: target.lat)
        cut(&w, &e, keep: target.lng)
        return DesertGrid.BBox(s: s, w: w, n: n, e: e)
    }

    /// A box holding both points (padded), or nil when they are too far apart for one grid.
    static func corridor(spanning a: LngLat, _ b: LngLat) -> DesertGrid.BBox? {
        guard inKingdom(a), inKingdom(b) else { return nil }
        let box = DesertGrid.BBox(s: min(a.lat, b.lat) - padDeg, w: min(a.lng, b.lng) - padDeg,
                                  n: max(a.lat, b.lat) + padDeg, e: max(a.lng, b.lng) + padDeg)
        return box.n - box.s <= maxSpanDeg && box.e - box.w <= maxSpanDeg ? box : nil
    }
}

/// Finds, verifies and caches the national tiles, and stitches the corridor grid a route needs.
/// Order per tile: a bundled pilot grid that already covers that part (no download), the memory
/// cache, the disk cache (Application Support/DesertTiles, checked against the manifest's
/// sha256), then the tiles server. A tile from the server is used only if its size and sha256
/// match the manifest. All work runs in the caller's async context, never on the main thread's
/// critical path (`corridor` is async; callers are the route provider and a detached task).
final class DesertTileStore: @unchecked Sendable {
    struct Manifest: Decodable, Equatable {
        struct Tile: Decodable, Equatable { var id: String; var bytes: Int; var sha256: String }
        var version: String
        var arcsec: Double
        var tiles: [Tile]
        func entry(_ id: DesertTiles.TileID) -> Tile? { tiles.first { $0.id == id.name } }
    }

    /// GET → (body, HTTP status).
    typealias Fetch = (URL) async throws -> (Data, Int)

    static let shared = DesertTileStore()
    static let memoryTiles = 4
    static let manifestTTL: TimeInterval = 6 * 3600
    static let retryAfterFailure: TimeInterval = 60

    let baseURL: URL?
    let cacheDir: URL?
    private let fetch: Fetch
    private let seeds: (DesertGrid.BBox) -> [DesertGrid]
    private let now: () -> Date

    private let lock = NSLock()
    private var memory: [DesertTiles.TileID: DesertGrid] = [:]
    private var recent: [DesertTiles.TileID] = []
    private var manifest: Manifest?
    private var manifestFetched: Date?
    private var lastFailure: Date?
    private var memoryWarning: NSObjectProtocol?

    /// `FarqTilesURL` (`https://host/farq.json`) → `https://host/desert/`.
    static var configuredBaseURL: URL? {
        guard let raw = FarqTiles.configuredURL, let u = URL(string: raw) else { return nil }
        return u.deletingLastPathComponent().appendingPathComponent("desert", isDirectory: true)
    }

    static var defaultCacheDir: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("DesertTiles", isDirectory: true)
    }

    static let urlSessionFetch: Fetch = { url in
        let req = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 20)
        let (data, response) = try await URLSession.shared.data(for: req)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    /// The bundled pilot grids that touch `box` (offline seed).
    static let bundledSeeds: (DesertGrid.BBox) -> [DesertGrid] = { box in
        DesertGrid.bboxes.filter { $0.value.intersects(box) }.keys.sorted().compactMap { DesertGrid.bundled($0) }
    }

    init(baseURL: URL? = DesertTileStore.configuredBaseURL,
         cacheDir: URL? = DesertTileStore.defaultCacheDir,
         fetch: @escaping Fetch = DesertTileStore.urlSessionFetch,
         seeds: @escaping (DesertGrid.BBox) -> [DesertGrid] = DesertTileStore.bundledSeeds,
         now: @escaping () -> Date = Date.init) {
        self.baseURL = baseURL
        self.cacheDir = cacheDir
        self.fetch = fetch
        self.seeds = seeds
        self.now = now
        memoryWarning = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil
        ) { [weak self] _ in
            self?.purgeMemory()
        }
    }

    deinit {
        if let memoryWarning { NotificationCenter.default.removeObserver(memoryWarning) }
    }

    func purgeMemory() {
        lock.lock()
        memory.removeAll()
        recent.removeAll()
        lock.unlock()
    }

    /// The decoded tiles held in memory (tests, diagnostics).
    var memoryTileNames: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recent.map(\.name)
    }

    /// One grid over `box` from the tiles and pilot grids it needs; nil when the box is too big,
    /// a needed tile is unavailable (offline, missing, failed its checksum) and no pilot covers
    /// that part, or nothing covers it at all. The caller then keeps the road route + bearing.
    func corridor(_ box: DesertGrid.BBox) async -> DesertGrid? {
        let ids = DesertTiles.tiles(covering: box)
        guard !ids.isEmpty, ids.count <= 16,
              box.n - box.s <= DesertTiles.maxSpanDeg + 1e-9, box.e - box.w <= DesertTiles.maxSpanDeg + 1e-9 else { return nil }
        let pilots = seeds(box)
        var tiles: [DesertGrid] = []
        var manifest: Manifest?
        var askedManifest = false
        for id in ids {
            guard let part = id.bbox.intersection(box) else { continue }
            if pilots.contains(where: { $0.bbox.covers(part) }) { continue }
            if let g = memoryTile(id) { tiles.append(g); continue }
            if !askedManifest { manifest = await currentManifest(); askedManifest = true }
            switch await loadTile(id, manifest: manifest) {
            case let .loaded(g): tiles.append(g)
            case .absent: continue
            case .unavailable: return nil
            }
        }
        // Tiles are the national build (consistent across their edges); pilots fill what they lack.
        return DesertGrid.stitch(tiles + pilots, bbox: box)
    }

    /// Save to disk the tiles covering `box` (an offline map area), so desert routing works there
    /// without signal. Pilot-covered parts are skipped. Returns how many tiles are now on disk.
    @discardableResult
    func prefetch(_ box: DesertGrid.BBox) async -> Int {
        let ids = DesertTiles.tiles(covering: box)
        guard !ids.isEmpty, ids.count <= 16 else { return 0 }
        let pilots = seeds(box)
        let manifest = await currentManifest()
        var ready = 0
        for id in ids {
            guard let part = id.bbox.intersection(box), !pilots.contains(where: { $0.bbox.covers(part) }) else { continue }
            if case .loaded = await loadTile(id, manifest: manifest) { ready += 1 }
        }
        return ready
    }

    enum TileState { case loaded(DesertGrid), absent, unavailable }

    func loadTile(_ id: DesertTiles.TileID, manifest: Manifest?) async -> TileState {
        if let g = memoryTile(id) { return .loaded(g) }
        let entry = manifest?.entry(id)
        // Not in the national set (sea, abroad): nothing to fetch; its cells stay forbidden.
        if manifest != nil, entry == nil { return .absent }
        let file = cacheDir?.appendingPathComponent("routes-\(id.name).bin")
        var stale: Data?
        if let file, let data = try? Data(contentsOf: file) {
            // Without a manifest (offline since install) a cached file is trusted: it was checked when saved.
            if entry.map({ Self.sha256Hex(data) == $0.sha256 }) ?? true, let g = Self.decode(data, id) {
                remember(id, g)
                return .loaded(g)
            }
            stale = data
        }
        if let entry, let baseURL, !recentlyFailed() {
            let res = try? await fetch(baseURL.appendingPathComponent("tiles/\(id.name).bin"))
            if let res, (200..<300).contains(res.1), res.0.count == entry.bytes,
               Self.sha256Hex(res.0) == entry.sha256, let g = Self.decode(res.0, id) {
                save(res.0, to: file)
                remember(id, g)
                return .loaded(g)
            }
            // No answer at all (offline): do not ask again for a minute (reroutes come often).
            if res == nil { noteFailure() }
        }
        // An older build of the tile is still real data: better than nothing in the desert.
        if let stale, let g = Self.decode(stale, id) {
            remember(id, g)
            return .loaded(g)
        }
        return .unavailable
    }

    /// The manifest: from memory while fresh, else the server, else the last one saved on disk.
    func currentManifest() async -> Manifest? {
        lock.lock()
        let held = manifest, fetched = manifestFetched
        lock.unlock()
        if let held, let fetched, now().timeIntervalSince(fetched) < Self.manifestTTL { return held }
        if let baseURL, !recentlyFailed() {
            let res = try? await fetch(baseURL.appendingPathComponent("manifest.json"))
            if let res, (200..<300).contains(res.1), let m = Self.decodeManifest(res.0) {
                lock.lock()
                manifest = m
                manifestFetched = now()
                lock.unlock()
                save(res.0, to: cacheDir?.appendingPathComponent("manifest.json"))
                return m
            }
            noteFailure()
        }
        if let held { return held }
        if let file = cacheDir?.appendingPathComponent("manifest.json"),
           let data = try? Data(contentsOf: file), let m = Self.decodeManifest(data) {
            lock.lock()
            manifest = m  // manifestFetched stays nil: the server is asked again next time
            lock.unlock()
            return m
        }
        return nil
    }

    static func decodeManifest(_ data: Data) -> Manifest? {
        guard let m = try? JSONDecoder().decode(Manifest.self, from: data), abs(m.arcsec - DesertTiles.arcsec) < 1e-9 else { return nil }
        return m
    }

    /// A tile file, refused unless its header is exactly that tile on the 3″ lattice.
    static func decode(_ data: Data, _ id: DesertTiles.TileID) -> DesertGrid? {
        guard let g = DesertGrid.load(data) else { return nil }
        let h = g.header, b = id.bbox, t = 1e-7
        guard abs(h.arcsec - DesertTiles.arcsec) < 1e-9, abs(h.south - b.s) < t, abs(h.west - b.w) < t,
              abs(h.north - b.n) < t, abs(h.east - b.e) < t else { return nil }
        return g
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func memoryTile(_ id: DesertTiles.TileID) -> DesertGrid? {
        lock.lock()
        defer { lock.unlock() }
        guard let g = memory[id] else { return nil }
        recent.removeAll { $0 == id }
        recent.append(id)
        return g
    }

    private func remember(_ id: DesertTiles.TileID, _ g: DesertGrid) {
        lock.lock()
        memory[id] = g
        recent.removeAll { $0 == id }
        recent.append(id)
        while recent.count > Self.memoryTiles { memory[recent.removeFirst()] = nil }
        lock.unlock()
    }

    private func recentlyFailed() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return lastFailure.map { now().timeIntervalSince($0) < Self.retryAfterFailure } ?? false
    }

    private func noteFailure() {
        lock.lock()
        lastFailure = now()
        lock.unlock()
    }

    private func save(_ data: Data, to file: URL?) {
        guard let file else { return }
        var dir = file.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true  // re-downloadable
        try? dir.setResourceValues(values)
        try? data.write(to: file, options: .atomic)
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

    static let groundEffort: [DesertGrid.Ground: Double] = [.firm: 1.0, .sand: 1.7, .crest: 4.5, .sabkha: 9.0, .wadi: 2.5, .rock: 6.0]
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
            base = (groundEffort[g] ?? 1) * (rain && g == .wadi ? 3 : 1)
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
        while let top = heap.pop() {
            let (f, i) = top
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
        guard a.lat >= g.header.south, a.lat <= g.header.north,
              a.lng >= g.header.west, a.lng <= g.header.east,
              b.lat >= g.header.south, b.lat <= g.header.north,
              b.lng >= g.header.west, b.lng <= g.header.east else { return [] }
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
