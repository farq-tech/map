@_spi(Experimental) import MapboxMaps
import Foundation
import SwiftUI

/// Pure rules for offline areas (unit-tested): zooms, the per-area and total caps.
enum OfflinePlan {
    /// Satellite + roads + terrain from district to street detail. Mapbox loads tiles in
    /// batches (6–10, 11–14, 15–16) that cover the whole parent tile, so starting at 6
    /// would pull a ~600 km square; 11 keeps a small area small (~20 km batches).
    static let minZoom: UInt8 = 11
    static let maxZoom: UInt8 = 16
    /// Everything saved on this phone together.
    static let totalCapBytes: Int64 = 1 << 30
    /// One area: at most this many km per side (a whole day's desert outing fits).
    static let maxSideKm = 60.0
    static let minSideKm = 0.5

    struct Box: Equatable, Codable {
        var west: Double
        var south: Double
        var east: Double
        var north: Double

        var center: LngLat { LngLat(lng: (west + east) / 2, lat: (south + north) / 2) }
        var widthKm: Double { Vehicle.distanceMeters(LngLat(lng: west, lat: center.lat), LngLat(lng: east, lat: center.lat)) / 1000 }
        var heightKm: Double { Vehicle.distanceMeters(LngLat(lng: center.lng, lat: south), LngLat(lng: center.lng, lat: north)) / 1000 }
    }

    enum Verdict: Equatable {
        case ok
        case tooSmall
        case tooBig(maxKm: Double)
        /// Would pass the total cap: how much is free now.
        case overCap(freeBytes: Int64)
    }

    static func check(_ b: Box, estimateBytes: Int64?, usedBytes: Int64, cap: Int64 = totalCapBytes) -> Verdict {
        if b.widthKm < minSideKm || b.heightKm < minSideKm { return .tooSmall }
        if b.widthKm > maxSideKm || b.heightKm > maxSideKm { return .tooBig(maxKm: maxSideKm) }
        if let e = estimateBytes, usedBytes + e > cap { return .overCap(freeBytes: max(0, cap - usedBytes)) }
        return .ok
    }

    /// The Mapbox tilesets the live map draws besides the style's own: terrain (DEM) and the
    /// streets the cars are matched to (`RoadSnap`).
    static let extraTilesets = ["mapbox://mapbox.mapbox-terrain-dem-v1", "mapbox://mapbox.mapbox-streets-v8"]

    static func regionId(_ now: Date = Date()) -> String { "sary-\(Int(now.timeIntervalSince1970))" }
}

/// One saved area as the list shows it.
struct OfflineArea: Identifiable, Equatable {
    var id: String
    var name: String
    var box: OfflinePlan.Box?
    var outingName: String?
    var createdAt: Date?
    var bytes: Int64
    var completed: UInt64
    var required: UInt64
    var expires: Date?
    /// Layers saved for this area (areas from before build 9: satellite only).
    var layers: Set<MapLayer> = [.satellite]
    var isComplete: Bool { required > 0 && completed >= required }
}

/// Downloads and manages offline areas with Mapbox's OfflineManager + TileStore
/// (a style pack for the outing style, a tile region per area). The live map
/// uses the same default TileStore, so saved tiles are used automatically when
/// there is no network.
@MainActor
final class OfflineMaps: ObservableObject {
    enum Job: Equatable {
        case idle
        case estimating
        case downloading(name: String, fraction: Double, bytes: Int64)
        case failed(String)
        case finished(name: String, bytes: Int64)
    }

    @Published private(set) var areas: [OfflineArea] = []
    @Published private(set) var loaded = false
    @Published private(set) var job: Job = .idle
    @Published private(set) var stylePackReady = false

    static let shared = OfflineMaps()

    private let tileStore = TileStore.default
    private lazy var offline = OfflineManager()
    private var cancelables: [Cancelable] = []

    var usedBytes: Int64 { areas.reduce(0) { $0 + $1.bytes } }

    // MARK: list

    func reload() {
        tileStore.allTileRegions { [weak self] result in
            let regions = (try? result.get()) ?? []
            Task { @MainActor in await self?.build(regions) }
        }
        offline.stylePack(for: OutingMapboxView.styleURI) { [weak self] r in
            var ok = false
            if case let .success(p) = r { ok = p.requiredResourceCount > 0 && p.completedResourceCount >= p.requiredResourceCount }
            let ready = ok
            Task { @MainActor in self?.stylePackReady = ready }
        }
    }

    private func build(_ regions: [TileRegion]) async {
        var out: [OfflineArea] = []
        for r in regions where r.id.hasPrefix("sary-") {
            let meta = await metadata(r.id)
            var box: OfflinePlan.Box?
            if let b = meta["box"] as? [Double], b.count == 4 { box = .init(west: b[0], south: b[1], east: b[2], north: b[3]) }
            let layers = Set(((meta["layers"] as? [String]) ?? ["satellite"]).compactMap(MapLayer.init))
            out.append(OfflineArea(id: r.id, name: meta["name"] as? String ?? "منطقة", box: box, outingName: meta["outing"] as? String,
                                   createdAt: (meta["created"] as? Double).map { Date(timeIntervalSince1970: $0) },
                                   bytes: Int64(r.completedResourceSize), completed: r.completedResourceCount, required: r.requiredResourceCount, expires: r.expires,
                                   layers: layers.isEmpty ? [.satellite] : layers))
        }
        areas = out.sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
        loaded = true
    }

    private func metadata(_ id: String) async -> [String: Any] {
        await withCheckedContinuation { c in
            tileStore.tileRegionMetadata(forId: id) { r in
                c.resume(returning: ((try? r.get()) as? [String: Any]) ?? [:])
            }
        }
    }

    // MARK: download

    /// Complete areas that also hold the topographic layer.
    var topoAreas: Int { areas.filter { $0.isComplete && $0.layers.contains(.topo) }.count }
    var completeAreas: Int { areas.filter(\.isComplete).count }

    private func descriptors(topo: Bool) -> [TilesetDescriptor] {
        let opts = TilesetDescriptorOptions(styleURI: OutingMapboxView.styleURI, zoomRange: OfflinePlan.minZoom...OfflinePlan.maxZoom,
                                            tilesets: OfflinePlan.extraTilesets)
        var out = [offline.createTilesetDescriptor(for: opts)]
        if topo {
            /* Mapbox Outdoors: its own tilesets (streets + terrain-v2 contours & hillshade) for the same zooms. */
            let t = TilesetDescriptorOptions(styleURI: MapLayer.topo.styleURI, zoomRange: OfflinePlan.minZoom...OfflinePlan.maxZoom, tilesets: nil)
            out.append(offline.createTilesetDescriptor(for: t))
        }
        return out
    }

    private func loadOptions(_ box: OfflinePlan.Box, name: String, outing: String?, topo: Bool = false) -> TileRegionLoadOptions? {
        let poly = Polygon([[
            CLLocationCoordinate2D(latitude: box.south, longitude: box.west),
            CLLocationCoordinate2D(latitude: box.south, longitude: box.east),
            CLLocationCoordinate2D(latitude: box.north, longitude: box.east),
            CLLocationCoordinate2D(latitude: box.north, longitude: box.west),
            CLLocationCoordinate2D(latitude: box.south, longitude: box.west),
        ]])
        var meta: [String: Any] = ["name": name, "box": [box.west, box.south, box.east, box.north], "created": Date().timeIntervalSince1970,
                                   "layers": topo ? ["satellite", "topo"] : ["satellite"]]
        if let outing { meta["outing"] = outing }
        return TileRegionLoadOptions(geometry: .polygon(poly), descriptors: descriptors(topo: topo), metadata: meta, acceptExpired: true)
    }

    /// Storage the area would take (Mapbox's own estimate), or nil when it cannot tell (offline).
    func estimate(_ box: OfflinePlan.Box, topo: Bool = false) async -> Int64? {
        guard let o = loadOptions(box, name: "", outing: nil, topo: topo) else { return nil }
        return await withCheckedContinuation { c in
            let done = Locked(false)
            let cancel = tileStore.estimateTileRegion(forId: "sary-estimate", loadOptions: o, progress: { _ in }) { r in
                guard done.take() else { return }
                c.resume(returning: (try? r.get()).map { Int64($0.storageSize) })
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
                guard done.take() else { return }
                cancel.cancel()
                c.resume(returning: nil)
            }
        }
    }

    /// Style pack (once) + the tile region. Progress is published in `job`.
    func download(_ box: OfflinePlan.Box, name: String, outing: String?, topo: Bool = false) {
        guard let o = loadOptions(box, name: name, outing: outing, topo: topo) else { job = .failed("تعذّر تجهيز المنطقة."); return }
        job = .downloading(name: name, fraction: 0, bytes: 0)
        let packOpts = StylePackLoadOptions(glyphsRasterizationMode: .ideographsRasterizedLocally, metadata: ["app": "sary"], acceptExpired: true)!
        let pack = offline.loadStylePack(for: OutingMapboxView.styleURI, loadOptions: packOpts) { [weak self] r in
            let ok = (try? r.get()) != nil
            Task { @MainActor in self?.stylePackReady = ok || (self?.stylePackReady ?? false) }
        }
        var packs: [Cancelable] = [pack]
        if topo {
            packs.append(offline.loadStylePack(for: MapLayer.topo.styleURI, loadOptions: packOpts) { _ in })
        }
        let id = OfflinePlan.regionId()
        let region = tileStore.loadTileRegion(forId: id, loadOptions: o, progress: { [weak self] p in
            let f = p.requiredResourceCount > 0 ? Double(p.completedResourceCount) / Double(p.requiredResourceCount) : 0
            let bytes = Int64(p.completedResourceSize)
            Task { @MainActor in
                guard let self, case .downloading = self.job else { return }
                self.job = .downloading(name: name, fraction: f, bytes: bytes)
            }
        }) { [weak self] r in
            Task { @MainActor in
                guard let self else { return }
                switch r {
                case let .success(region):
                    self.job = .finished(name: name, bytes: Int64(region.completedResourceSize))
                    // «دروب البر» offline too: keep the national route tiles of this area on disk.
                    let area = DesertGrid.BBox(s: box.south, w: box.west, n: box.north, e: box.east)
                    Task.detached(priority: .utility) { await DesertTileStore.shared.prefetch(area) }
                case let .failure(e):
                    if case .canceled? = e as? TileRegionError { self.job = .idle } else {
                        self.job = .failed(Self.arabic(e))
                    }
                }
                self.reload()
            }
        }
        cancelables = packs + [region]
    }

    func cancel() {
        cancelables.forEach { $0.cancel() }
        cancelables = []
        job = .idle
    }

    func clearJob() { if case .downloading = job { return }; job = .idle }

    func delete(_ id: String) {
        tileStore.removeRegion(forId: id) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
        areas.removeAll { $0.id == id }
    }

    /// Everything, including the style pack (when the list is emptied; «احذف حسابي» keeps downloaded areas).
    func deleteAll() {
        for a in areas { tileStore.removeRegion(forId: a.id) { _ in } }
        offline.removeStylePack(for: OutingMapboxView.styleURI)
        offline.removeStylePack(for: MapLayer.topo.styleURI)
        areas = []
        stylePackReady = false
    }

    static func arabic(_ e: Error) -> String {
        if let t = e as? TileRegionError {
            switch t {
            case .tileCountExceeded: return "المنطقة كبيرة مرة. صغّرها."
            case .diskFull: return "ما فيه مساحة كافية في الجوال."
            default: break
            }
        }
        return "انقطع التنزيل. تأكد من الإنترنت وأعد المحاولة — ما نزل يبقى ويُستكمل."
    }
}

/// One-shot flag shared by a continuation's two possible resumers.
private final class Locked: @unchecked Sendable {
    private var value: Bool
    private let lock = NSLock()
    init(_ v: Bool) { value = v }
    /// True the first time only.
    func take() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if value { return false }
        value = true
        return true
    }
}

extension OfflinePlan.Box {
    init(_ b: CoordinateBounds) {
        self.init(west: b.southwest.longitude, south: b.southwest.latitude, east: b.northeast.longitude, north: b.northeast.latitude)
    }
}
