@_spi(Experimental) import MapboxMaps
import Combine
import ObjectiveC
import SwiftUI
import UIKit

/// What the host map asks of the weather overlay on each `updateUIView`.
struct WeatherOverlayRequest: Equatable {
    /// Exploration is on (the overlays belong to «الطبقات» of exploration).
    var active = false
    /// The screen's chrome (top bar, sheet): the legend card stays clear of it.
    var chrome: UIEdgeInsets = .zero
    /// Where «السحاب الآن» tells the cloud's direction and arrival: the chosen destination, else the
    /// person's own position (nil = no estimate).
    var point: LngLat?
    var pointIsDestination = false
}

/// The weather overlays on one `MapView`: raster sources served by our API, re-added after
/// every style load, and a small legend card (title, time / period, colour key, the licence's
/// credit line). «السحاب الآن» animates its frames (the last ~2 h) by switching layer opacity.
///
/// Hosts call `WeatherOverlay.of(map).update(request)` from `updateUIView`; nothing else.
@MainActor
final class WeatherOverlay {
    static let prefix = "sary-weather-"
    static let opacity: Double = 0.95
    /// How much the basemap is darkened under the cloud layer.
    static let scrimOpacity: Double = 0.38

    private weak var map: MapView?
    private let layers: WeatherLayers
    private var request = WeatherOverlayRequest()
    private var cancelables = Set<AnyCancelable>()
    private var bag = Set<AnyCancellable>()
    private var styleReady = false
    private var applyScheduled = false
    /// What is drawn now (to skip identical re-installs).
    private var drawn: Drawn?
    private var frames: [CloudFramesResponse.Frame] = []
    private var framesFetchedAt: Date?
    private var framesTask: Task<Void, Never>?
    private var timer: Timer?
    private var outlookTask: Task<Void, Never>?
    private var outlookRetried = false
    private var outlookFor: (point: LngLat, at: Date, kind: WeatherOverlayKind, subject: CloudOutlookSubject)?
    private var windTask: Task<Void, Never>?
    private var windFetchedAt: Date?
    private var frameIndex = 0
    private var pauseTicks = 0
    let legend = WeatherLegendModel()
    private var legendHost: UIHostingController<WeatherLegendCard>?
    private var flowHost: UIHostingController<CloudFlowHost>?
    /// The legend card's frame on the map (nil while it is hidden). The host's own overlays
    /// (the name chips, the edge arrows) keep clear of it; `onCardFrame` tells them when it changes.
    private(set) var cardFrame: CGRect?
    var onCardFrame: ((CGRect?) -> Void)?

    private struct Drawn: Equatable {
        var kind: WeatherOverlayKind
        var key: String
    }

    private static var key: UInt8 = 0
    static func of(_ map: MapView, layers: WeatherLayers? = nil) -> WeatherOverlay {
        if let c = objc_getAssociatedObject(map, &key) as? WeatherOverlay { return c }
        let c = WeatherOverlay(map: map, layers: layers ?? .shared)
        objc_setAssociatedObject(map, &key, c, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return c
    }

    private init(map: MapView, layers: WeatherLayers) {
        self.map = map
        self.layers = layers
        legend.onTogglePlay = { [weak self] in self?.togglePlay() }
        legend.onScrub = { [weak self] i in self?.seek(to: i) }
        legend.onClose = { [weak self] in self?.layers.kind = .none }
        /* Looking around with no destination/fix: re-estimate for the new middle of the map (25 km / 10 min rules apply). */
        map.mapboxMap.onMapIdle.observe { [weak self] _ in
            guard let self, self.request.point == nil, self.effectiveKind == .clouds else { return }
            self.refreshOutlook()
        }.store(in: &cancelables)
        styleReady = map.mapboxMap.isStyleLoaded
        map.mapboxMap.onStyleLoaded.observe { [weak self] _ in
            guard let self else { return }
            self.styleReady = true
            self.drawn = nil
            self.apply()
        }.store(in: &cancelables)
        legend.$outlook.dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.layoutLegend() }.store(in: &bag)
        legend.$cardMode.dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.layoutLegend() }.store(in: &bag)
        layers.$kind.combineLatest(layers.$rainDays).dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.apply() }.store(in: &bag)
        /* Streaks first (under the legend card), full-size, never takes a touch. */
        let flow = UIHostingController(rootView: CloudFlowHost(model: legend))
        flow.view.backgroundColor = .clear
        flow.view.isUserInteractionEnabled = false
        flow.view.isHidden = true
        map.addSubview(flow.view)
        flowHost = flow
        let host = UIHostingController(rootView: WeatherLegendCard(model: legend))
        host.view.backgroundColor = .clear
        host.view.isHidden = true
        host.view.accessibilityIdentifier = "weather.legend"
        map.addSubview(host.view)
        legendHost = host
        #if DEBUG
        /* Screenshots: `-SaryWeatherCam 24.7,46.7,5` (after exploration's own camera moves). */
        let a = ProcessInfo.processInfo.arguments
        if let i = a.firstIndex(of: "-SaryWeatherCam"), i + 1 < a.count {
            let n = a[i + 1].split(separator: ",").compactMap { Double($0) }
            if n.count == 3 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak map] in
                    map?.camera.ease(to: CameraOptions(center: CLLocationCoordinate2D(latitude: n[0], longitude: n[1]), zoom: n[2]), duration: 0.3)
                }
            }
        }
        #endif
    }

    func update(_ r: WeatherOverlayRequest) {
        guard r != request else { return }
        let chromeOnly = r.active == request.active && r.point == request.point && r.pointIsDestination == request.pointIsDestination
        request = r
        if chromeOnly {
            layoutLegend()
        } else {
            scheduleApply()
        }
    }

    /// `update(_:)` is called by `UIViewRepresentable.updateUIView`. Applying the overlay
    /// also publishes legend state, so defer that work until SwiftUI has finished updating.
    private func scheduleApply() {
        guard !applyScheduled else { return }
        applyScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.applyScheduled = false
            self.apply()
        }
    }

    /// The kind actually drawn: none outside exploration.
    var effectiveKind: WeatherOverlayKind { request.active ? layers.kind : .none }

    // MARK: install

    #if DEBUG
    private var debugCameraDone = false
    /// Screenshots: `-SaryWeatherCamera 24.5,45,5` frames the map (lat,lng,zoom) a few seconds after the layer opens.
    private func debugCamera() {
        guard !debugCameraDone, effectiveKind != .none, styleReady else { return }
        let a = ProcessInfo.processInfo.arguments
        guard let i = a.firstIndex(of: "-SaryWeatherCamera"), i + 1 < a.count else { return }
        let n = a[i + 1].split(separator: ",").compactMap { Double($0) }
        guard n.count == 3 else { return }
        debugCameraDone = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            self?.map?.mapboxMap.setCamera(to: CameraOptions(center: CLLocationCoordinate2D(latitude: n[0], longitude: n[1]), zoom: n[2]))
        }
    }
    #endif

    private func apply() {
        #if DEBUG
        defer { debugCamera() }
        #endif
        let kind = effectiveKind
        legend.kind = kind
        legend.days = layers.rainDays
        legend.attribution = kind.attribution()
        legend.items = WeatherLegend.items(kind)
        if kind != .clouds { stopAnimation(); framesTask?.cancel(); framesTask = nil }
        if kind != .wind { windTask?.cancel(); windTask = nil }
        refreshOutlook()
        guard let map, styleReady else { layoutLegend(); return }
        let m: MapboxMap = map.mapboxMap
        switch kind {
        case .none:
            removeAll(m)
            drawn = nil
        case .rain:
            install(m, kind: .rain, key: "rain-\(layers.rainDays)",
                    sources: [("rain", WeatherLayerAPI.rainTiles(days: layers.rainDays))], min: 3, max: 11, bounds: [34, 16, 56, 33])
            legend.time = WeatherLayers.daysLabel(layers.rainDays)
        case .wind:
            if drawn?.kind != .wind { removeAll(m); drawn = Drawn(kind: .wind, key: "wind-pending"); windFetchedAt = nil }
            installWind(m)
            legend.time = "الريح الحين · نموذج"
        case .green:
            install(m, kind: .green, key: "green", sources: [("green", WeatherLayerAPI.greenTiles())], min: 4, max: 12, bounds: [34, 16, 56, 33])
            legend.time = "آخر ٨ أيام مقارنة بالصيف"
        case .clouds:
            refreshFrames()
            if !frames.isEmpty {
                let key = "clouds-" + frames.map(\.id).joined(separator: ",")
                let fresh = drawn != Drawn(kind: .clouds, key: key)
                install(m, kind: .clouds, key: key,
                        sources: frames.map { ("cloud-\($0.id)", WeatherLayerAPI.absolute($0.tile_url)) }, min: 0, max: 9, bounds: [25, 8, 65, 40],
                        visibleIndex: frames.count - 1)
                if fresh {
                    /* New frames (first open or a refresh): show the newest and play. A plain
                     * re-apply (chrome/layout) must not disturb a paused or scrubbed frame. */
                    legend.playing = true
                    #if DEBUG
                    /* Comparison aid: `-SaryCloudPaused` freezes the newest frame (one variable per screenshot). */
                    if ProcessInfo.processInfo.arguments.contains("-SaryCloudPaused") { legend.playing = false }
                    #endif
                    startAnimation()
                } else if legend.playing, timer == nil {
                    startTimer()
                }
            } else {
                legend.time = "نجيب آخر صور السحاب…"
            }
        }
        layoutLegend()
    }

    private func install(_ m: MapboxMap, kind: WeatherOverlayKind, key: String, sources: [(String, String)],
                         min: Double, max: Double, bounds: [Double], visibleIndex: Int? = nil) {
        let d = Drawn(kind: kind, key: key)
        guard d != drawn || !m.layerExists(withId: Self.prefix + sources[0].0) else { return }
        removeAll(m)
        let below = firstLabelLayer(m)
        /* Clouds: dim the earth under them so white cloud tops stand out from the bright satellite basemap. */
        if kind == .clouds {
            var scrim = BackgroundLayer(id: Self.prefix + "scrim")
            scrim.backgroundColor = .constant(StyleColor(.black))
            scrim.backgroundOpacity = .constant(Self.scrimOpacity)
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-SaryNoScrim") { scrim.backgroundOpacity = .constant(0) }
            #endif
            do {
                if let middle = Slot.middle, m.allSlotIdentifiers.contains(middle) {
                    scrim.slot = middle
                    try m.addLayer(scrim)
                } else if let below {
                    try m.addLayer(scrim, layerPosition: .below(below))
                } else {
                    try m.addLayer(scrim)
                }
            } catch {
                #if DEBUG
                print("[weather] add scrim failed: \(error)")
                #endif
            }
        }
        for (i, (id, url)) in sources.enumerated() {
            var src = RasterSource(id: Self.prefix + id)
            var tileURL = url
            #if DEBUG
            /* Comparison aid: `-SaryCloudTileStyle legacy` asks the server for the Build 41–43 look. */
            if kind == .clouds, let i = ProcessInfo.processInfo.arguments.firstIndex(of: "-SaryCloudTileStyle"),
               i + 1 < ProcessInfo.processInfo.arguments.count, ProcessInfo.processInfo.arguments[i + 1] == "legacy" {
                tileURL += (tileURL.contains("?") ? "&" : "?") + "style=legacy"
            }
            #endif
            src.tiles = [tileURL]
            src.tileSize = 256
            src.minzoom = min
            src.maxzoom = max
            src.bounds = bounds
            src.attribution = kind.attribution()
            var layer = RasterLayer(id: Self.prefix + id, source: Self.prefix + id)
            let shown = visibleIndex.map { $0 == i } ?? true
            layer.rasterOpacity = .constant(shown ? Self.opacity : 0)
            /* Progressive loading (clouds): only the shown frame is visible at install, so the other
             * frames fetch no tiles until the loop — or the scrubber — reaches them. */
            if visibleIndex != nil { layer.visibility = .constant(shown ? .visible : .none) }
            layer.rasterFadeDuration = .constant(0)
            /* Clouds: frames dissolve into each other (0.5 s) instead of snapping. */
            if visibleIndex != nil { layer.rasterOpacityTransition = StyleTransition(duration: 0.5, delay: 0) }
            layer.rasterResampling = .constant(.linear)
            do {
                try m.addSource(src)
                if let middle = Slot.middle, m.allSlotIdentifiers.contains(middle) {
                    layer.slot = middle
                    try m.addLayer(layer)
                } else if let below {
                    try m.addLayer(layer, layerPosition: .below(below))
                } else {
                    try m.addLayer(layer)
                }
            } catch {
                #if DEBUG
                print("[weather] add \(id) failed: \(error)")
                #endif
            }
        }
        drawn = d
    }

    /// Classic styles (topographic): put the overlay under the first label layer.
    private func firstLabelLayer(_ m: MapboxMap) -> String? {
        m.allLayerIdentifiers.first { $0.type == .symbol && !$0.id.hasPrefix("sary-") }?.id
    }

    private func removeAll(_ m: MapboxMap) {
        for l in m.allLayerIdentifiers where l.id.hasPrefix(Self.prefix) { try? m.removeLayer(withId: l.id) }
        for s in m.allSourceIdentifiers where s.id.hasPrefix(Self.prefix) { try? m.removeSource(withId: s.id) }
    }

    // MARK: clouds

    private func refreshFrames() {
        if let at = framesFetchedAt, Date().timeIntervalSince(at) < 300, !frames.isEmpty { return }
        guard framesTask == nil else { return }
        framesTask = Task { [weak self] in
            let r = try? await WeatherLayerAPI.cloudFrames()
            guard let self else { return }
            self.framesTask = nil
            if let r, r.ok, !r.frames.isEmpty {
                self.frames = r.frames
                self.framesFetchedAt = Date()
                self.apply()
            } else if self.effectiveKind == .clouds {
                self.legend.time = "صور السحاب ما وصلت، نحاول بعد شوي"
            }
        }
    }

    /// The row under the legend, per layer: «السحاب الآن» → cloud direction + arrival (phase 2),
    /// «وين نزل مطر» → which way the observed rain was moving, «اتجاه الرياح» → wind at the point.
    /// Refreshed when the point moves ≥ 25 km or the estimate is older than 10 min. Any failure or low
    /// confidence hides the row.
    private func refreshOutlook(isRetry: Bool = false) {
        var point = request.point
        var subject: CloudOutlookSubject = request.pointIsDestination ? .destination : .me
        #if DEBUG
        /* Screenshots: `-SaryCloudPoint 17.5,44.0` pins the estimate to a point (the simulator has no real position). */
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-SaryCloudPoint"), i + 1 < args.count {
            let n = args[i + 1].split(separator: ",").compactMap { Double($0) }
            if n.count == 2 { point = LngLat(lng: n[1], lat: n[0]) }
        }
        #endif
        let kind = effectiveKind
        /* No destination and no fix: the middle of the map being looked at, while it is over the Kingdom's box. */
        if point == nil, kind == .clouds, let c = map?.mapboxMap.cameraState.center,
           (16...33).contains(c.latitude), (34...56).contains(c.longitude) {
            point = LngLat(lng: c.longitude, lat: c.latitude)
            subject = .mapCenter
        }
        guard kind == .clouds || kind == .rain || kind == .wind, let p = point else {
            outlookTask?.cancel(); outlookTask = nil; outlookFor = nil
            legend.outlook = nil; legend.outlookLoading = false
            return
        }
        if let last = outlookFor, last.kind == kind, Date().timeIntervalSince(last.at) < 600,
           Self.km(last.point, p) < 25, last.subject == subject { return }
        /* A new place or layer (not a refresh of the same one): never keep showing the old row. */
        if outlookFor.map({ $0.kind != kind || Self.km($0.point, p) >= 25 || $0.subject != subject }) ?? true { legend.outlook = nil }
        outlookTask?.cancel()
        /* The one-retry allowance belongs to a request: a new place or layer starts with a fresh one. */
        if !isRetry { outlookRetried = false }
        outlookFor = (p, Date(), kind, subject)
        legend.outlookLoading = true
        legend.outlookLoadingText = kind == .wind ? "نجيب الرياح…" : kind == .rain ? "نقدّر اتجاه المطر…" : "نقدّر اتجاه السحاب…"
        outlookTask = Task { [weak self] in
            var failed = false
            let display: CloudOutlookPresenter.Display?
            switch kind {
            case .wind:
                let w = try? await WeatherLayerAPI.windAt(lat: p.lat, lng: p.lng)
                failed = w == nil
                display = w.flatMap { WindRainPresenter.wind($0, subject: subject) }
            case .rain:
                let r = try? await WeatherLayerAPI.rainMotion(lat: p.lat, lng: p.lng)
                failed = r == nil
                display = r.flatMap { WindRainPresenter.rain($0, subject: subject) }
            default:
                let o = try? await WeatherLayerAPI.cloudOutlook(lat: p.lat, lng: p.lng)
                failed = o == nil
                display = o.flatMap { CloudOutlookPresenter.display($0, subject: subject) }
            }
            guard let self, !Task.isCancelled else { return }
            self.legend.outlookLoading = false
            self.legend.outlook = display
            if failed {
                self.outlookFor = nil
                /* One quiet retry a minute later (the server may have finished reading by then). */
                if !self.outlookRetried {
                    self.outlookRetried = true
                    try? await Task.sleep(nanoseconds: 60_000_000_000)
                    if !Task.isCancelled { self.refreshOutlook(isRetry: true) }
                }
            } else {
                self.outlookRetried = false
            }
        }
    }

    // MARK: wind

    /// «اتجاه الرياح»: flow lines (GeoJSON from our API) drawn thin and half-transparent, so the map shows through.
    private func installWind(_ m: MapboxMap) {
        let id = Self.prefix + "wind"
        let have = m.sourceExists(withId: id) && m.layerExists(withId: id)
        if have, let at = windFetchedAt, Date().timeIntervalSince(at) < 1800 { return }
        guard windTask == nil else { return }
        windTask = Task { [weak self] in
            let r = try? await WeatherLayerAPI.windLines()
            guard let self else { return }
            self.windTask = nil
            guard !Task.isCancelled, self.effectiveKind == .wind, let map = self.map, let r, r.ok else {
                if self.effectiveKind == .wind { self.legend.time = "الرياح ما وصلت، نحاول بعد شوي" }
                return
            }
            let m: MapboxMap = map.mapboxMap
            let fc = FeatureCollection(features: r.features)
            self.windFetchedAt = Date()
            if m.sourceExists(withId: id) {
                m.updateGeoJSONSource(withId: id, geoJSON: .featureCollection(fc))
                return
            }
            self.removeAll(m)
            var src = GeoJSONSource(id: id)
            src.data = .featureCollection(fc)
            /* Thin, half-transparent white with a faint dark edge so it reads on bright desert and dark sea. */
            var casing = LineLayer(id: id + "-casing", source: id)
            casing.lineColor = .constant(StyleColor(.black))
            casing.lineOpacity = .constant(0.3)
            casing.lineWidth = .constant(3.4)
            casing.lineBlur = .constant(1.5)
            casing.lineEmissiveStrength = .constant(1)
            casing.lineCap = .constant(.round)
            casing.lineJoin = .constant(.round)
            var line = LineLayer(id: id, source: id)
            line.lineColor = .constant(StyleColor(.white))
            line.lineOpacity = .constant(0.9)
            line.lineWidth = .expression(Exp(.interpolate) {
                Exp(.linear)
                Exp(.get) { "speed_ms" }
                0; 1.0
                12; 2.2
            })
            /* The Standard style lights its slots; full emissive keeps the lines white at night too. */
            line.lineEmissiveStrength = .constant(1)
            line.lineCap = .constant(.round)
            line.lineJoin = .constant(.round)
            do {
                try m.addSource(src)
                if let middle = Slot.middle, m.allSlotIdentifiers.contains(middle) {
                    casing.slot = middle; line.slot = middle
                    try m.addLayer(casing); try m.addLayer(line)
                } else if let below = self.firstLabelLayer(m) {
                    try m.addLayer(casing, layerPosition: .below(below)); try m.addLayer(line, layerPosition: .below(below))
                } else {
                    try m.addLayer(casing); try m.addLayer(line)
                }
                self.drawn = Drawn(kind: .wind, key: "wind")
            } catch {
                #if DEBUG
                print("[weather] add wind failed: \(error)")
                #endif
            }
        }
    }

    private static func km(_ a: LngLat, _ b: LngLat) -> Double {
        let dLat = (a.lat - b.lat) * 111.2
        let dLng = (a.lng - b.lng) * 111.2 * cos(a.lat * .pi / 180)
        return (dLat * dLat + dLng * dLng).squareRoot()
    }

    private func startAnimation() {
        frameIndex = frames.count - 1
        showFrame(frameIndex)
        legend.frameCount = frames.count
        if legend.playing { startTimer() }
    }

    /// Start (or resume) the frame loop from the current frame. Newest picture plays by default.
    private func startTimer() {
        legend.playing = true
        legend.frameCount = frames.count
        guard timer == nil, frames.count > 1 else { return }
        let t = Timer(timeInterval: 0.55, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopAnimation() {
        timer?.invalidate()
        timer = nil
    }

    /// «تشغيل / إيقاف» the cloud loop (the legend's play/pause button).
    func togglePlay() {
        guard effectiveKind == .clouds, frames.count > 1 else { return }
        if timer == nil { startTimer() } else { legend.playing = false; stopAnimation() }
    }

    /// The timeline scrubber dragged to frame `i`: pause the loop and show that frame.
    func seek(to i: Int) {
        guard effectiveKind == .clouds, frames.indices.contains(i) else { return }
        legend.playing = false
        stopAnimation()
        pauseTicks = 0
        showFrame(i)
    }

    private func tick() {
        guard effectiveKind == .clouds, !frames.isEmpty else { stopAnimation(); return }
        /* Hold the newest picture a little longer, then replay from the oldest. */
        if frameIndex == frames.count - 1 {
            pauseTicks += 1
            if pauseTicks < 4 { return }
            pauseTicks = 0
        }
        let next = (frameIndex + 1) % frames.count
        showFrame(next)
        if next == frames.count - 1, framesFetchedAt.map({ Date().timeIntervalSince($0) > 300 }) == true { refreshFrames() }
    }

    private func showFrame(_ i: Int) {
        guard let m = map?.mapboxMap, frames.indices.contains(i) else { return }
        /* Progressive + flicker-free: make this frame (and the next) visible so their tiles are
         * already loading, raise the new frame's opacity, then drop the previous one. */
        ensureVisible(m, i)
        ensureVisible(m, (i + 1) % frames.count)
        let old = frameIndex
        frameIndex = i
        try? m.setLayerProperty(for: Self.prefix + "cloud-" + frames[i].id, property: "raster-opacity", value: Self.opacity)
        if old != i, frames.indices.contains(old) {
            try? m.setLayerProperty(for: Self.prefix + "cloud-" + frames[old].id, property: "raster-opacity", value: 0)
        }
        legend.frameIndex = i
        legend.frameCount = frames.count
        legend.age = Self.ageLabel(frames[i].time)
        legend.time = "الساعة \(frames[i].label_ar)" + (i == frames.count - 1 ? " · آخر صورة" : "")
        legend.progress = frames.count > 1 ? Double(i) / Double(frames.count - 1) : 1
    }

    /// Make a cloud frame's layer visible so Mapbox begins fetching its tiles (deferred until now).
    private func ensureVisible(_ m: MapboxMap, _ i: Int) {
        guard frames.indices.contains(i) else { return }
        let id = Self.prefix + "cloud-" + frames[i].id
        guard m.layerExists(withId: id) else { return }
        try? m.setLayerProperty(for: id, property: "visibility", value: "visible")
    }

    /// «قبل ساعة ونصف»: how old the frame's satellite picture is (the licence delays it ≥ 1 h).
    static func ageLabel(_ iso: String) -> String {
        let withFrac = ISO8601DateFormatter(); withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let d = withFrac.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) else { return "" }
        let mins = Swift.max(0, Int(Date().timeIntervalSince(d) / 60))
        if mins < 1 { return "الآن" }
        if mins < 60 { return "قبل \(SaryFormat.number(mins)) دقيقة" }
        let h = mins / 60, m = mins % 60
        if m == 0 { return "قبل \(SaryFormat.number(h)) ساعة" }
        if m == 30 { return "قبل \(SaryFormat.number(h)) ساعة ونصف" }
        return "قبل \(SaryFormat.number(h)) ساعة و\(SaryFormat.number(m)) دقيقة"
    }

    // MARK: legend

    private func layoutLegend() {
        guard let map, let host = legendHost else { return }
        let show = effectiveKind != .none
        host.view.isHidden = !show
        if let flow = flowHost {
            flow.view.frame = map.bounds
            var off = legend.flow == nil
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-SaryNoFlow") { off = true }
            #endif
            flow.view.isHidden = off
        }
        guard show else { setCardFrame(nil); return }
        let width = min(map.bounds.width - 24, 360)
        let size = host.sizeThatFits(in: CGSize(width: width, height: 400))
        var y = request.chrome.top + 8
        /* Never over the bottom chrome (the trip bar, the mic): slide up on a short screen. */
        let floor = map.bounds.height - request.chrome.bottom - 8
        if request.chrome.bottom > 0, y + size.height > floor { y = max(8, floor - size.height) }
        if legend.cardMode == .hidden {
            /* Just the restore button, on the leading edge (clear of the right-hand tool column). */
            host.view.frame = CGRect(x: 12, y: y, width: size.width, height: size.height)
        } else {
            host.view.frame = CGRect(x: (map.bounds.width - width) / 2, y: y, width: width, height: size.height)
        }
        setCardFrame(host.view.frame)
    }

    private func setCardFrame(_ f: CGRect?) {
        guard f != cardFrame else { return }
        cardFrame = f
        onCardFrame?(f)
    }
}

enum WeatherCardMode: String {
    case collapsed, expanded, hidden

    static let key = "sary.map.weather.card.v1"

    static func stored(_ d: UserDefaults = .standard) -> WeatherCardMode {
        #if DEBUG
        let a = ProcessInfo.processInfo.arguments
        if let i = a.firstIndex(of: "-SaryWeatherCard"), i + 1 < a.count, let m = WeatherCardMode(rawValue: a[i + 1]) { return m }
        #endif
        return d.string(forKey: key).flatMap(WeatherCardMode.init) ?? .collapsed
    }

    static func store(_ m: WeatherCardMode, _ d: UserDefaults = .standard) { d.set(m.rawValue, forKey: key) }
}

/// The legend card's state (driven by `WeatherOverlay`).
@MainActor
final class WeatherLegendModel: ObservableObject {
    @Published var kind: WeatherOverlayKind = .none
    @Published var days = 3
    @Published var time = ""
    @Published var progress: Double = 1
    @Published var items: [WeatherLegendItem] = []
    @Published var attribution = ""
    /// «السحاب الآن» animation controls (play/pause + timeline scrubber + the frame's age).
    @Published var playing = true
    @Published var frameIndex = 0
    @Published var frameCount = 0
    @Published var age = ""
    /// Phase 2: the cloud's direction + arrival line (nil = hidden: low confidence, no point, no data).
    @Published var outlook: CloudOutlookPresenter.Display?
    @Published var outlookLoading = false
    @Published var outlookLoadingText = ""
    /// The on-map streaks: only for a confident cloud estimate that has a direction.
    var flow: CloudFlow? {
        guard kind == .clouds, let o = outlook, let b = o.arrowDegrees, let s = o.speedKmh else { return nil }
        return CloudFlow(bearing: b, speedKmh: s)
    }
    /// The card's size: a one-line strip by default, the full card on demand, or just a small restore button.
    /// Hiding the card never turns the layer off (that is «إيقاف الطبقة» / «الطبقات» → «الطقس»).
    @Published var cardMode: WeatherCardMode = WeatherCardMode.stored() {
        didSet { WeatherCardMode.store(cardMode) }
    }
    /// «إيقاف الطبقة»: turns the weather layer off (back on from «الطبقات» → «الطقس»).
    var onClose: () -> Void = {}
    var onTogglePlay: () -> Void = {}
    var onScrub: (Int) -> Void = { _ in }
}

/// «السحاب الآن · الساعة ٢:٠٠ م» + colour key + the source's credit line.
struct WeatherLegendCard: View {
    @ObservedObject var model: WeatherLegendModel
    @Environment(\.sary) private var theme

    var body: some View {
        switch model.cardMode {
        case .hidden: restoreButton
        case .collapsed: strip
        case .expanded: expanded
        }
    }

    private func chip(_ systemImage: String, id: String, label: String, action: @escaping () -> Void) -> some View {
        let p = theme.palette
        return Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .bold)).foregroundStyle(p.textSecondary)
                .frame(width: 30, height: 30).background(Circle().fill(p.sunken))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
        .accessibilityLabel(Text(label))
    }

    /// Swipe the card down to hide it, up to open the full card.
    private var swipe: some Gesture {
        DragGesture(minimumDistance: 18).onEnded { v in
            if v.translation.height > 28 { model.cardMode = .hidden }
            else if v.translation.height < -28, model.cardMode == .collapsed { model.cardMode = .expanded }
        }
    }

    /// The default: one line — what it is, how old the picture is, play/pause, the cloud's direction.
    private var strip: some View {
        let p = theme.palette
        return HStack(spacing: 8) {
            Image(systemName: model.kind.systemImage)
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(p.accentText)
            Text(model.kind.label).saryText(.subhead, weight: .bold).foregroundStyle(p.textPrimary).lineLimit(1)
            Text(model.kind == .clouds && !model.age.isEmpty ? model.age : model.time)
                .saryText(.caption, weight: .bold).foregroundStyle(p.textSecondary)
                .lineLimit(1).minimumScaleFactor(0.7)
                .accessibilityIdentifier("weather.legend.time")
            Spacer(minLength: 2)
            if let deg = model.outlook?.arrowDegrees {
                Image(systemName: "arrow.up").font(.system(size: 14, weight: .bold)).foregroundStyle(p.accentText)
                    .rotationEffect(.degrees(deg)).environment(\.layoutDirection, .leftToRight)
                    .accessibilityIdentifier("weather.legend.strip.arrow")
                    .accessibilityLabel(Text("اتجاه الحركة"))
            }
            if model.kind == .clouds {
                Button { model.onTogglePlay() } label: {
                    Image(systemName: model.playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 12, weight: .bold)).foregroundStyle(p.accentText)
                        .frame(width: 30, height: 30).background(Circle().fill(p.accent.opacity(0.2)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("weather.clouds.playpause")
                .accessibilityLabel(Text(model.playing ? "إيقاف حركة السحاب" : "تشغيل حركة السحاب"))
            }
            chip("chevron.up", id: "weather.legend.expand", label: "تفاصيل الطبقة") { model.cardMode = .expanded }
            chip("xmark", id: "weather.legend.hide", label: "إخفاء البطاقة (الطبقة تبقى على الخريطة)") { model.cardMode = .hidden }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .saryGlass(Capsule(), role: .chrome)
        .environment(\.layoutDirection, .rightToLeft)
        .gesture(swipe)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("weather.legend.strip")
    }

    /// Card hidden: only a small button, so the map is free; the layer stays on.
    private var restoreButton: some View {
        let p = theme.palette
        return Button { model.cardMode = .collapsed } label: {
            Image(systemName: model.kind.systemImage)
                .font(.system(size: 16, weight: .semibold)).foregroundStyle(p.accentText)
                .frame(width: 44, height: 44)
                .saryGlass(Circle(), role: .chrome)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("weather.legend.restore")
        .accessibilityLabel(Text("إظهار بطاقة \(model.kind.label) (الطبقة ما زالت فعّالة)"))
    }

    private var expanded: some View {
        let p = theme.palette
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: model.kind.systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(p.accentText)
                Text(model.kind.label).saryText(.subhead, weight: .bold).foregroundStyle(p.textPrimary)
                Spacer(minLength: 4)
                Text(model.time).saryText(.footnote, weight: .bold).foregroundStyle(p.textSecondary)
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .accessibilityIdentifier("weather.legend.time")
                chip("chevron.down", id: "weather.legend.collapse", label: "تصغير البطاقة") { model.cardMode = .collapsed }
                chip("xmark", id: "weather.legend.hide", label: "إخفاء البطاقة (الطبقة تبقى على الخريطة)") { model.cardMode = .hidden }
            }
            if model.kind == .clouds {
                HStack(spacing: 8) {
                    Button { model.onTogglePlay() } label: {
                        Image(systemName: model.playing ? "pause.fill" : "play.fill")
                            .font(.system(size: 12, weight: .bold)).foregroundStyle(p.accentText)
                            .frame(width: 26, height: 26).background(Circle().fill(p.accent.opacity(0.2)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("weather.clouds.playpause")
                    .accessibilityLabel(Text(model.playing ? "إيقاف حركة السحاب" : "تشغيل حركة السحاب"))
                    if model.frameCount > 1 {
                        Slider(value: Binding(get: { Double(model.frameIndex) },
                                              set: { model.onScrub(Int($0.rounded())) }),
                               in: 0...Double(model.frameCount - 1), step: 1)
                            .tint(p.accent)
                            .environment(\.layoutDirection, .leftToRight)
                            .accessibilityIdentifier("weather.clouds.scrubber")
                    } else {
                        GeometryReader { g in
                            Capsule().fill(p.sunken)
                                .overlay(alignment: .leading) {
                                    Capsule().fill(p.accent).frame(width: max(6, g.size.width * model.progress))
                                }
                        }
                        .frame(height: 4)
                        .environment(\.layoutDirection, .leftToRight)
                    }
                    if !model.age.isEmpty {
                        Text(model.age).saryText(.caption, weight: .bold).foregroundStyle(p.textSecondary)
                            .lineLimit(1).fixedSize()
                            .accessibilityIdentifier("weather.legend.age")
                    }
                }
            }
            if model.kind == .clouds {
                HStack(spacing: 10) {
                    ForEach(model.items, id: \.self) { item in
                        HStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 3).fill(Color(rgb: item.hex)).frame(width: 14, height: 10)
                                .overlay(RoundedRectangle(cornerRadius: 3).stroke(p.textTertiary.opacity(0.6), lineWidth: 0.5))
                            Text(item.label).saryText(.caption).foregroundStyle(p.textSecondary).lineLimit(1).minimumScaleFactor(0.75)
                        }
                    }
                }
            } else {
                HStack(spacing: 0) {
                    ForEach(model.items, id: \.self) { item in
                        VStack(spacing: 2) {
                            Rectangle().fill(Color(rgb: item.hex)).frame(height: 8)
                            Text(item.label).saryText(.caption).foregroundStyle(p.textSecondary).lineLimit(1).minimumScaleFactor(0.7)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            if let o = model.outlook {
                CloudOutlookRow(display: o, arrowLabel: model.kind == .wind ? "اتجاه هبوب الريح" : model.kind == .rain ? "اتجاه حركة المطر" : "اتجاه حركة السحاب")
            } else if model.outlookLoading {
                Text(model.outlookLoadingText).saryText(.caption).foregroundStyle(p.textSecondary)
                    .accessibilityIdentifier("weather.outlook.loading")
            }
            Button { model.onClose() } label: {
                Text("إيقاف الطبقة").saryText(.caption, weight: .bold).foregroundStyle(p.accentText)
                    .padding(.vertical, 4).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("weather.legend.off")
            /* Data attribution over the map: 10 pt semibold, secondary (was 9 pt tertiary). */
            Text(model.attribution)
                .saryGlyph(10, weight: .semibold, maxGrowth: SaryGlyph.tightGrowth)
                .foregroundStyle(p.textSecondary)
                .lineLimit(1).minimumScaleFactor(0.7)
                .environment(\.layoutDirection, .leftToRight)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityIdentifier("weather.legend.attribution")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .saryGlass(RoundedRectangle(cornerRadius: 16, style: .continuous), role: .chrome)
        .environment(\.layoutDirection, .rightToLeft)
        .gesture(swipe)
        .accessibilityElement(children: .contain)
    }
}

/// The arrow (where the cloud moves toward, north up) + the arrival line, with the picture's age.
struct CloudOutlookRow: View {
    let display: CloudOutlookPresenter.Display
    var arrowLabel = "اتجاه حركة السحاب"
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        HStack(alignment: .top, spacing: 10) {
            if let deg = display.arrowDegrees {
                ZStack {
                    Circle().stroke(p.textTertiary.opacity(0.6), lineWidth: 1)
                    Text("ش").saryGlyph(8, weight: .bold, maxGrowth: SaryGlyph.tightGrowth)
                        .foregroundStyle(p.textTertiary).offset(y: -15)
                    Image(systemName: "arrow.up")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(p.accentText)
                        .rotationEffect(.degrees(deg))
                }
                .frame(width: 38, height: 38)
                /* Compass rotation must not mirror with the card's right-to-left layout. */
                .environment(\.layoutDirection, .leftToRight)
                .accessibilityIdentifier("weather.outlook.arrow")
                .accessibilityLabel(Text(arrowLabel))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(display.headline).saryText(.caption, weight: .bold).foregroundStyle(p.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("weather.outlook.headline")
                Text(display.detail).saryText(.footnote, weight: .bold).foregroundStyle(p.accentText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("weather.outlook.detail")
                Text(display.footnote).saryText(.caption).foregroundStyle(p.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("weather.outlook.footnote")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("weather.outlook")
    }
}
