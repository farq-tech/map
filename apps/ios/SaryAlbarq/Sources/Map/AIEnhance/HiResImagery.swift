@_spi(Experimental) import MapboxMaps
import Combine
import ObjectiveC
import os
import UIKit

/// «صور عالية الوضوح» on one `MapView`: a Mapbox `CustomRasterSource` over the satellite
/// imagery (slot `bottom`, under roads, labels and our own layers) that only answers for
/// over-zoom tiles (`HiResZoom.plan`); everything else stays exactly as Mapbox draws it.
///
/// - Async: the original tile shows until the enhanced one is ready, then the raster
///   fade (`raster-fade-duration`) crossfades it in. Inference runs on one serial
///   `.utility` queue, newest visible tile first; tiles that leave the view are dropped.
/// - RAM only: enhanced tiles and raw parents live in `HiResTileCache` (no disk, the
///   parent fetch uses an ephemeral session with no URL cache). Memory warnings purge both.
/// - Gated by `HiResPolicy` (navigation / follow / SOS / > 15 km/h / remote kill / user off
///   remove the layer; Low Power Mode or a hot device pause new work).
/// - The «مُحسّنة» badge shows while enhanced tiles are on screen; holding it shows the original.
///
/// Hosts call `HiResImagery.of(map).update(request)` from `updateUIView`; nothing else.
final class HiResImagery: NSObject {
    static let sourceId = "sary-hires-source"
    static let layerId = "sary-hires-layer"

    private weak var map: MapView?
    private var cancelables = Set<AnyCancelable>()
    private var bag = Set<AnyCancellable>()
    private var request = HiResRequest.off
    private(set) var decision: HiResDecision = .off(.surface)
    private var installed = false
    /// The style finished loading (our own flag: `isStyleLoaded` also waits for every source's tiles).
    private var styleReady = false
    private let settings: HiResSettings

    /* Shared across worker threads: guarded by `lock`. */
    private let lock = NSLock()
    private var visible = HiResVisibleSet()
    private var pending: [HiResTileID: UInt64] = [:]
    private var order: UInt64 = 0
    private var fetching = Set<HiResTileID>()
    private var working = false
    private var enhancesNew = false
    private var generation = 0

    /// Process-wide: the same tile is never enhanced twice while it is in RAM.
    static let enhanced = HiResTileCache<UIImage>(limitBytes: 40 << 20)
    static let raw = HiResTileCache<Data>(limitBytes: 8 << 20)
    private static let queue = DispatchQueue(label: "sary.hires.inference", qos: .utility)
    private static var enhancer: HiResEnhancer?
    private static var modelFailed = HiResEnhancer.bundledURL == nil
    static let log = Logger(subsystem: "sa.sary.albarq", category: "hires")

    private let badge = HiResBadgeView()

    private static var key: UInt8 = 0
    /// The controller for this map (created on first use).
    static func of(_ map: MapView, settings: HiResSettings = .shared) -> HiResImagery {
        if let c = objc_getAssociatedObject(map, &key) as? HiResImagery { return c }
        let c = HiResImagery(map: map, settings: settings)
        objc_setAssociatedObject(map, &key, c, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return c
    }

    private init(map: MapView, settings: HiResSettings) {
        self.map = map
        self.settings = settings
        super.init()
        settings.start()
        styleReady = map.mapboxMap.isStyleLoaded
        map.mapboxMap.onStyleLoaded.observe { [weak self] _ in
            self?.styleReady = true
            self?.installed = false
            self?.lock.withLock { self?.visible.reset() }
            self?.apply()
        }.store(in: &cancelables)
        settings.$userOn.combineLatest(settings.$remoteOn).dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.apply() }.store(in: &bag)
        let nc = NotificationCenter.default
        for n in [ProcessInfo.thermalStateDidChangeNotification, Notification.Name.NSProcessInfoPowerStateDidChange] {
            nc.publisher(for: n).receive(on: DispatchQueue.main).sink { [weak self] _ in self?.apply() }.store(in: &bag)
        }
        nc.publisher(for: UIApplication.didReceiveMemoryWarningNotification).sink { _ in
            Self.enhanced.removeAll()
            Self.raw.removeAll()
        }.store(in: &bag)
        badge.onHold = { [weak self] holding in self?.showOriginal(holding) }
        badge.isHidden = true
        map.addSubview(badge)
        #if DEBUG
        debugCamera(map)
        #endif
    }

    /// The host's state; call on every `updateUIView`.
    func update(_ r: HiResRequest) {
        guard r != request else { return }
        request = r
        apply()
    }

    // MARK: gate

    private func apply() {
        guard let map else { return }
        let d = HiResPolicy.decide(request, userOn: settings.userOn, remoteOn: settings.remoteOn,
                                   device: .current, modelAvailable: !Self.modelFailed)
        let changed = d != decision
        decision = d
        lock.withLock { enhancesNew = d.enhancesNew }
        if changed {
            Self.log.debug("decision \(String(describing: d), privacy: .public)")
            #if DEBUG
            HiResStats.note("decision \(d) surface=\(request.surface) speed=\(request.speedMps.map { String($0) } ?? "-")")
            #endif
        }
        guard styleReady else { return }
        if d.drawsLayer { install(map) } else { uninstall(map) }
        if d.enhancesNew { kick() }
        refreshBadge()
    }

    private func install(_ map: MapView) {
        let m: MapboxMap = map.mapboxMap
        guard !installed || !m.sourceExists(withId: Self.sourceId) else { return }
        let gen = lock.withLock { () -> Int in generation += 1; return generation }
        let client = CustomRasterSourceClient.fromCustomRasterSourceTileStatusChangedCallback { [weak self] id, status in
            self?.tileStatus(HiResTileID(z: id.z, x: id.x, y: id.y), status, gen: gen)
        }
        let options = CustomRasterSourceOptions(clientCallback: client, minZoom: HiResZoom.sourceMinZoom,
                                                maxZoom: HiResZoom.sourceMaxZoom, tileSize: 512)
        do {
            if m.layerExists(withId: Self.layerId) { try m.removeLayer(withId: Self.layerId) }
            if m.sourceExists(withId: Self.sourceId) { try m.removeSource(withId: Self.sourceId) }
            try m.addSource(CustomRasterSource(id: Self.sourceId, options: options))
            var layer = RasterLayer(id: Self.layerId, source: Self.sourceId)
            layer.slot = .bottom
            layer.rasterFadeDuration = .constant(250)
            layer.rasterResampling = .constant(.linear)
            layer.rasterOpacity = .constant(1)
            try m.addLayer(layer)
            /* The same colour grade as the imagery it covers (`SandGrade`: warm sand in the open,
               neutral in a city), so an enhanced tile never changes colour as it fades in. */
            let c = m.cameraState.center
            try? m.setLayerProperties(for: Self.layerId, properties: SandGrade.paint(sand: SandGrade.sand(urban: UrbanAreas.weight(lat: c.latitude, lng: c.longitude))))
            installed = true
            #if DEBUG
            HiResStats.note("installed gen \(gen)")
            #endif
        } catch {
            #if DEBUG
            HiResStats.note("install failed \(error)")
            #endif
            Self.log.error("install failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func uninstall(_ map: MapView) {
        let m: MapboxMap = map.mapboxMap
        lock.withLock {
            generation += 1
            pending.removeAll()
            visible.reset()
        }
        installed = false
        if m.layerExists(withId: Self.layerId) { try? m.removeLayer(withId: Self.layerId) }
        if m.sourceExists(withId: Self.sourceId) { try? m.removeSource(withId: Self.sourceId) }
    }

    private func showOriginal(_ on: Bool) {
        guard let m = map?.mapboxMap, m.layerExists(withId: Self.layerId) else { return }
        try? m.setLayerProperty(for: Self.layerId, property: "raster-opacity", value: on ? 0 : 1)
    }

    // MARK: tiles (Mapbox worker threads)

    private func tileStatus(_ t: HiResTileID, _ status: CustomRasterSourceTileStatus, gen: Int) {
        guard lock.withLock({ gen == generation }) else { return }
        switch status {
        case .required:
            lock.withLock { visible.required(t) }
            if let img = Self.enhanced.get(t) { deliver(t, img, gen: gen); return }
            guard let plan = HiResZoom.plan(t) else { deliver(t, nil, gen: gen); return }
            enqueue(plan, gen: gen)
        case .optional:
            if let img = Self.enhanced.get(t) {
                lock.withLock { visible.required(t) }
                deliver(t, img, gen: gen)
            } else {
                drop(t)
            }
        case .notNeeded:
            drop(t)
            deliver(t, nil, gen: gen)
        @unknown default:
            break
        }
        DispatchQueue.main.async { [weak self] in self?.refreshBadge() }
    }

    private func drop(_ t: HiResTileID) {
        lock.withLock {
            pending.removeValue(forKey: t)
            visible.notNeeded(t)
        }
    }

    private func enqueue(_ plan: HiResTilePlan, gen: Int) {
        let parent = plan.parent
        let needFetch: Bool = lock.withLock {
            order += 1
            pending[plan.tile] = order
            guard !Self.raw.contains(parent), !fetching.contains(parent) else { return false }
            fetching.insert(parent)
            return true
        }
        if needFetch { fetch(parent, gen: gen) } else { kick() }
    }

    /// The parent tile straight from Mapbox's raster tiles API, RAM only.
    private func fetch(_ p: HiResTileID, gen: Int) {
        guard let token = MapboxOptions.accessToken.nilIfEmpty,
              let url = URL(string: "https://api.mapbox.com/v4/mapbox.satellite/\(p.z)/\(p.x)/\(p.y)@2x.jpg90?access_token=\(token)") else {
            lock.withLock { _ = fetching.remove(p) }
            return
        }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        req.networkServiceType = .responsiveData
        Self.session.dataTask(with: req) { [weak self] data, resp, _ in
            guard let self else { return }
            let ok = (resp as? HTTPURLResponse)?.statusCode == 200
            if ok, let data { Self.raw.set(p, data, cost: data.count) }
            var failed: [HiResTileID] = []
            self.lock.withLock {
                self.fetching.remove(p)
                if !ok {
                    failed = self.pending.keys.filter { HiResZoom.plan($0)?.parent == p }
                    for t in failed { self.pending.removeValue(forKey: t) }
                }
            }
            for t in failed { self.deliver(t, nil, gen: gen) }
            self.kick()
        }.resume()
    }

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: c)
    }()

    /// Wakes the serial inference loop.
    private func kick() {
        let start: Bool = lock.withLock {
            guard !working, enhancesNew, !pending.isEmpty else { return false }
            working = true
            return true
        }
        guard start else { return }
        Self.queue.async { [weak self] in self?.work() }
    }

    private func work() {
        while true {
            /* Newest still-needed tile whose parent is in RAM. */
            let next: (HiResTilePlan, Int)? = lock.withLock {
                guard enhancesNew else { return nil }
                let ready = pending.filter { Self.raw.contains(HiResZoom.plan($0.key)?.parent ?? $0.key) }
                guard let t = ready.max(by: { $0.value < $1.value })?.key, let plan = HiResZoom.plan(t) else { return nil }
                pending.removeValue(forKey: t)
                return (plan, generation)
            }
            guard let (plan, gen) = next else { break }
            if let img = Self.enhanced.get(plan.tile) { deliver(plan.tile, img, gen: gen); continue }
            guard let data = Self.raw.get(plan.parent), let parent = HiResEnhancer.decode(data), let e = loadModel() else {
                deliver(plan.tile, nil, gen: gen)
                continue
            }
            let t0 = CFAbsoluteTimeGetCurrent()
            let img = autoreleasepool { e.enhance(parent: parent, plan: plan) }
            let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            Self.log.debug("tile \(plan.tile.description, privacy: .public) x\(plan.factor) \(Int(ms))ms")
            #if DEBUG
            HiResStats.record(tileMs: ms, inferenceMs: e.recentMs.last ?? ms)
            #endif
            guard let img else { deliver(plan.tile, nil, gen: gen); continue }
            Self.enhanced.set(plan.tile, img, cost: HiResEnhancer.outputSize * HiResEnhancer.outputSize * 4)
            let still = lock.withLock { visible.needed.contains(plan.tile) }
            if still { deliver(plan.tile, img, gen: gen) }
        }
        lock.withLock { working = false }
        /* Something arrived while we were finishing. */
        if lock.withLock({ !pending.isEmpty && enhancesNew }) { kick() }
    }

    private func loadModel() -> HiResEnhancer? {
        if let e = Self.enhancer { return e }
        guard !Self.modelFailed, let url = HiResEnhancer.bundledURL else { return nil }
        do {
            let t0 = CFAbsoluteTimeGetCurrent()
            Self.enhancer = try HiResEnhancer(url: url)
            Self.log.info("model loaded in \(Int((CFAbsoluteTimeGetCurrent() - t0) * 1000))ms")
        } catch {
            Self.modelFailed = true
            Self.log.error("model failed: \(error.localizedDescription, privacy: .public)")
            DispatchQueue.main.async { [weak self] in self?.apply() }
        }
        return Self.enhancer
    }

    private func deliver(_ t: HiResTileID, _ image: UIImage?, gen: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let m = self.map?.mapboxMap, self.lock.withLock({ gen == self.generation }),
                  m.sourceExists(withId: Self.sourceId) else { return }
            try? m.setCustomRasterSourceTileData(forSourceId: Self.sourceId,
                                                 tiles: [CustomRasterSourceTileData(tileId: CanonicalTileID(z: t.z, x: t.x, y: t.y), image: image)])
            if image != nil { self.lock.withLock { self.visible.delivered(t) } }
            self.refreshBadge()
        }
    }

    // MARK: badge

    /// «تخفيف الزحمة» ٧: the badge says «مُحسّنة» for 3 s when enhanced tiles arrive, then
    /// steps aside (the state stays in «الطبقات» → «صور عالية الوضوح»).
    static let badgeSeconds: TimeInterval = 3
    private var badgeExpired = false
    private var badgeTimer: DispatchWorkItem?

    private func refreshBadge() {
        guard let map else { return }
        let wanted = decision.drawsLayer && lock.withLock { visible.badge }
        if !wanted {
            badgeExpired = false
            badgeTimer?.cancel()
            badgeTimer = nil
        } else if badgeTimer == nil && !badgeExpired {
            let w = DispatchWorkItem { [weak self] in
                self?.badgeExpired = true
                self?.refreshBadge()
            }
            badgeTimer = w
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.badgeSeconds, execute: w)
        }
        let show = wanted && !badgeExpired
        if badge.isHidden == show {
            UIView.animate(withDuration: 0.2) { self.badge.alpha = show ? 1 : 0 } completion: { _ in self.badge.isHidden = !show }
            if show { badge.isHidden = false }
        }
        badge.place(in: map)
    }

    /// For tests: is the badge showing?
    var badgeShown: Bool { !badge.isHidden && badge.alpha > 0 }

    #if DEBUG
    /// `-SaryHiResCam lat,lng,zoom`: put the camera on a test spot once the map is up (screenshots, UI tests).
    private func debugCamera(_ map: MapView) {
        let a = ProcessInfo.processInfo.arguments
        guard let i = a.firstIndex(of: "-SaryHiResCam"), i + 1 < a.count else { return }
        let n = a[i + 1].split(separator: ",").compactMap { Double($0) }
        guard n.count == 3 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak map] in
            map?.mapboxMap.setCamera(to: CameraOptions(center: CLLocationCoordinate2D(latitude: n[0], longitude: n[1]), zoom: n[2], bearing: 0, pitch: 0))
        }
    }
    #endif
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// The small «مُحسّنة» capsule over the map; hold it to see the original imagery.
final class HiResBadgeView: UIView {
    var onHold: (Bool) -> Void = { _ in }
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
        blur.frame = bounds
        blur.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        blur.isUserInteractionEnabled = false
        addSubview(blur)
        label.text = "مُحسّنة"
        label.font = UIFont(name: "Tajawal-Bold", size: 13) ?? .boldSystemFont(ofSize: 13)
        label.textColor = .white
        label.textAlignment = .center
        addSubview(label)
        layer.cornerRadius = 13
        layer.masksToBounds = true
        accessibilityLabel = "مُحسّنة"
        accessibilityHint = "المس مطولاً لعرض الصورة الأصلية"
        accessibilityTraits = .staticText
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(held(_:)))
        hold.minimumPressDuration = 0.15
        addGestureRecognizer(hold)
        syncAccessibility()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// VoiceOver (and UI tests) see the badge only while it is really on screen: the badge stays
    /// in the hierarchy between decisions, and a hidden view that keeps its identifier still
    /// shows up in the accessibility snapshot as «hires.badge».
    override var isHidden: Bool { didSet { syncAccessibility() } }
    override var alpha: CGFloat { didSet { syncAccessibility() } }

    private func syncAccessibility() {
        let shown = !isHidden && alpha > 0.01
        isAccessibilityElement = shown
        accessibilityIdentifier = shown ? "hires.badge" : nil
        accessibilityElementsHidden = !shown
    }

    @objc private func held(_ g: UILongPressGestureRecognizer) {
        switch g.state {
        case .began: onHold(true); label.text = "الأصلية"
        case .ended, .cancelled, .failed: onHold(false); label.text = "مُحسّنة"
        default: break
        }
    }

    /// Top centre, under the host's top chrome (the compass margin carries it) and the safe area.
    func place(in map: MapView) {
        let w: CGFloat = 76, h: CGFloat = 26
        let top = max(map.safeAreaInsets.top + 8, map.ornaments.options.compass.margins.y)
        frame = CGRect(x: (map.bounds.width - w) / 2, y: top, width: w, height: h)
        label.frame = bounds
        map.bringSubviewToFront(self)
    }
}

#if DEBUG
/// DEBUG only: per-tile timing and the app's memory footprint, written as numbers (never imagery)
/// to tmp/hires-stats.json for the performance notes.
enum HiResStats {
    private static let lock = NSLock()
    private static var tiles: [Double] = []
    private static var inference: [Double] = []

    static func record(tileMs: Double, inferenceMs: Double) {
        lock.withLock {
            tiles.append(tileMs)
            inference.append(inferenceMs)
            func med(_ a: [Double]) -> Double { a.sorted()[a.count / 2] }
            func p90(_ a: [Double]) -> Double { a.sorted()[min(a.count - 1, Int(Double(a.count) * 0.9))] }
            let json: [String: Any] = ["count": tiles.count, "tileMedianMs": med(tiles), "tileP90Ms": p90(tiles),
                                       "inferenceMedianMs": med(inference), "footprintMB": footprintMB(),
                                       "cacheMB": Double(HiResImagery.enhanced.bytes) / 1_048_576, "cacheTiles": HiResImagery.enhanced.count]
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("hires-stats.json")
            try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]).write(to: url)
        }
    }

    /// Appends one line to tmp/hires-events.log (decisions, tile events).
    static func note(_ line: String) {
        lock.withLock {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("hires-events.log")
            let l = "\(Date().timeIntervalSince1970) \(line)\n"
            if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(l.utf8)); try? h.close() } else { try? Data(l.utf8).write(to: url) }
        }
    }

    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }
}
#endif
