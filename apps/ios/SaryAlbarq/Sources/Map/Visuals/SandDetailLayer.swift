@_spi(Experimental) import MapboxMaps
import os
import UIKit

/// «تفاصيل الرمال» on the live map: a Mapbox `CustomRasterSource` whose tiles are
/// `SandDetail.render` (procedural, on the phone, no network), drawn in slot `bottom` right over
/// the satellite imagery (and over «صور عالية الوضوح» when that is on), under the hillshade,
/// roads, labels and our own layers. Owned by `MapVisualsDirector` (layer ids are `wow-`).
///
/// - Tiles are made on one serial `.utility` queue, newest request first (≈5–10 ms each on an
///   M-class / A17 CPU in Release), kept in a RAM LRU (24 MB ≈ 24 tiles) and re-delivered when
///   Mapbox asks again (it does not keep custom tiles itself). No disk: they cost less to
///   remake than to read back.
/// - Budget: no new tiles while the device is hot (`.serious`+) or in Low Power Mode (the
///   director already drops the layer there); a tile Mapbox no longer needs is never made.
/// - The sun moves the light every ~20°: the visible tiles are remade in place.
final class SandDetailLayer {
    static let sourceId = "wow-sand-detail-source"
    static let layerId = "wow-sand-detail"

    private weak var map: MapView?
    private var light = SandDetail.Light(azimuthDeg: 180, strength: 0.6, night: false)
    private var scale = 1.0
    private var generation = 0

    private let lock = NSLock()
    private var pending: [HiResTileID: UInt64] = [:]
    private var needed = Set<HiResTileID>()
    private var order: UInt64 = 0
    private var working = false

    private let cache = HiResTileCache<UIImage>(limitBytes: 24 << 20)
    private static let queue = DispatchQueue(label: "sary.sand-detail", qos: .utility)
    static let log = Logger(subsystem: "sa.sary.albarq", category: "sand-detail")

    #if DEBUG
    /// Per-tile generation times (ms), for the performance notes.
    static var recentMs: [Double] = []
    #endif

    init() {
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil) { [weak self] _ in
            self?.cache.removeAll()
        }
    }

    var installed: Bool { map?.mapboxMap.layerExists(withId: Self.layerId) ?? false }

    /// Turns the layer on or off and sets its light and strength (call on every visuals refresh; cheap).
    func apply(_ on: Bool, map: MapView, light newLight: SandDetail.Light, scale newScale: Double) {
        self.map = map
        let m: MapboxMap = map.mapboxMap
        guard on else { remove(m); return }
        if !m.sourceExists(withId: Self.sourceId) || !m.layerExists(withId: Self.layerId) {
            light = newLight
            scale = newScale
            install(m)
            return
        }
        if newScale != scale {
            scale = newScale
            try? m.setLayerProperty(for: Self.layerId, property: "raster-opacity", value: SandDetail.opacityExpression(scale: scale))
        }
        if newLight != light {
            light = newLight
            relight()
        }
    }

    /// The style was replaced: our source and layer went with it.
    func styleLoaded() {
        lock.withLock {
            generation += 1
            pending.removeAll()
            needed.removeAll()
        }
    }

    private func install(_ m: MapboxMap) {
        let gen = lock.withLock { () -> Int in
            generation += 1
            pending.removeAll()
            needed.removeAll()
            return generation
        }
        let client = CustomRasterSourceClient.fromCustomRasterSourceTileStatusChangedCallback { [weak self] id, status in
            self?.tileStatus(HiResTileID(z: id.z, x: id.x, y: id.y), status, gen: gen)
        }
        let options = CustomRasterSourceOptions(clientCallback: client, minZoom: UInt8(SandDetail.minZoom),
                                                maxZoom: UInt8(SandDetail.maxZoom), tileSize: UInt16(SandDetail.tileSize))
        do {
            if m.layerExists(withId: Self.layerId) { try m.removeLayer(withId: Self.layerId) }
            if m.sourceExists(withId: Self.sourceId) { try m.removeSource(withId: Self.sourceId) }
            try m.addSource(CustomRasterSource(id: Self.sourceId, options: options))
            var layer = RasterLayer(id: Self.layerId, source: Self.sourceId)
            layer.slot = .bottom
            layer.rasterFadeDuration = .constant(300)
            layer.rasterResampling = .constant(.linear)
            /* Lit like the imagery under it (`SandGrade`'s emissive), so it dims with the scene at night. */
            layer.rasterEmissiveStrength = .constant(SandGrade.shipped.emissive)
            /* Over «صور عالية الوضوح» when that is there (enhanced tiles get the same micro-relief). */
            let position: LayerPosition? = m.layerExists(withId: HiResImagery.layerId) ? .above(HiResImagery.layerId) : nil
            try m.addLayer(layer, layerPosition: position)
            try m.setLayerProperty(for: Self.layerId, property: "raster-opacity", value: SandDetail.opacityExpression(scale: scale))
        } catch {
            Self.log.error("install failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func remove(_ m: MapboxMap) {
        lock.withLock {
            generation += 1
            pending.removeAll()
            needed.removeAll()
        }
        if m.layerExists(withId: Self.layerId) { try? m.removeLayer(withId: Self.layerId) }
        if m.sourceExists(withId: Self.sourceId) { try? m.removeSource(withId: Self.sourceId) }
    }

    /// New light: forget the made tiles and remake the visible ones (the old ones stay until then).
    private func relight() {
        cache.removeAll()
        let gen = lock.withLock { () -> Int in
            for t in needed { order += 1; pending[t] = order }
            return generation
        }
        kick()
    }

    // MARK: tiles (Mapbox worker threads)

    private func tileStatus(_ t: HiResTileID, _ status: CustomRasterSourceTileStatus, gen: Int) {
        guard lock.withLock({ gen == generation }) else { return }
        switch status {
        case .required:
            lock.withLock { _ = needed.insert(t) }
            if let img = cache.get(t) { deliver(t, img, gen: gen); return }
            lock.withLock { order += 1; pending[t] = order }
            kick()
        case .optional:
            if let img = cache.get(t) { deliver(t, img, gen: gen) }
        case .notNeeded:
            lock.withLock {
                needed.remove(t)
                pending.removeValue(forKey: t)
            }
        @unknown default:
            break
        }
    }

    private func kick() {
        let start: Bool = lock.withLock {
            guard !working, !pending.isEmpty else { return false }
            working = true
            return true
        }
        guard start else { return }
        Self.queue.async { [weak self] in self?.work() }
    }

    private static var hot: Bool {
        let p = ProcessInfo.processInfo
        return p.isLowPowerModeEnabled || p.thermalState == .serious || p.thermalState == .critical
    }

    private func work() {
        while true {
            let next: (HiResTileID, Int, SandDetail.Light)? = lock.withLock {
                guard !Self.hot, let t = pending.max(by: { $0.value < $1.value })?.key else { return nil }
                pending.removeValue(forKey: t)
                return (t, generation, light)
            }
            guard let (t, gen, l) = next else { break }
            let t0 = CFAbsoluteTimeGetCurrent()
            let img: UIImage? = autoreleasepool {
                SandDetail.render(z: Int(t.z), x: Int(t.x), y: Int(t.y), light: l).flatMap(Self.image)
            }
            let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            #if DEBUG
            lock.withLock {
                Self.recentMs.append(ms)
                if Self.recentMs.count > 128 { Self.recentMs.removeFirst() }
            }
            SandDetailStats.write()
            #endif
            /* A light change while this one was being made: it goes round again. */
            guard lock.withLock({ gen == generation && l == light }) else { continue }
            if let img { cache.set(t, img, cost: SandDetail.tileSize * SandDetail.tileSize * 4) }
            if lock.withLock({ needed.contains(t) }) { deliver(t, img, gen: gen) }
        }
        lock.withLock { working = false }
        if lock.withLock({ !pending.isEmpty && !Self.hot }) { kick() }
    }

    private func deliver(_ t: HiResTileID, _ image: UIImage?, gen: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let m = self.map?.mapboxMap, self.lock.withLock({ gen == self.generation }),
                  m.sourceExists(withId: Self.sourceId) else { return }
            try? m.setCustomRasterSourceTileData(forSourceId: Self.sourceId,
                                                 tiles: [CustomRasterSourceTileData(tileId: CanonicalTileID(z: t.z, x: t.x, y: t.y), image: image)])
        }
    }

    /// Premultiplied RGBA8 → UIImage.
    static func image(_ t: SandDetail.Tile) -> UIImage? {
        let data = Data(t.rgba) as CFData
        guard let provider = CGDataProvider(data: data),
              let cg = CGImage(width: t.size, height: t.size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: t.size * 4,
                               space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

#if DEBUG
/// DEBUG only: tile generation timing and the thermal state, as numbers, to tmp/sand-detail-stats.json.
enum SandDetailStats {
    static func write() {
        let a = SandDetailLayer.recentMs.sorted()
        guard !a.isEmpty else { return }
        let json: [String: Any] = ["count": a.count, "medianMs": a[a.count / 2], "p90Ms": a[min(a.count - 1, Int(Double(a.count) * 0.9))],
                                   "thermal": ProcessInfo.processInfo.thermalState.rawValue, "footprintMB": HiResStats.footprintMB()]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sand-detail-stats.json")
        try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]).write(to: url)
    }
}
#endif
