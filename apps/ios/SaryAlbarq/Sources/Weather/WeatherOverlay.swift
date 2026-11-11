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
}

/// The weather overlays on one `MapView`: raster sources served by our API, re-added after
/// every style load, and a small legend card (title, time / period, colour key, the licence's
/// credit line). «السحاب الآن» animates its frames (the last ~2 h) by switching layer opacity.
///
/// Hosts call `WeatherOverlay.of(map).update(request)` from `updateUIView`; nothing else.
@MainActor
final class WeatherOverlay {
    static let prefix = "sary-weather-"
    static let opacity: Double = 0.85

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
    private var frameIndex = 0
    private var pauseTicks = 0
    let legend = WeatherLegendModel()
    private var legendHost: UIHostingController<WeatherLegendCard>?

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
        styleReady = map.mapboxMap.isStyleLoaded
        map.mapboxMap.onStyleLoaded.observe { [weak self] _ in
            guard let self else { return }
            self.styleReady = true
            self.drawn = nil
            self.apply()
        }.store(in: &cancelables)
        layers.$kind.combineLatest(layers.$rainDays).dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.apply() }.store(in: &bag)
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
        let chromeOnly = r.active == request.active
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

    private func apply() {
        let kind = effectiveKind
        legend.kind = kind
        legend.days = layers.rainDays
        legend.attribution = kind.attribution()
        legend.items = WeatherLegend.items(kind)
        if kind != .clouds { stopAnimation(); framesTask?.cancel(); framesTask = nil }
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
        case .green:
            install(m, kind: .green, key: "green", sources: [("green", WeatherLayerAPI.greenTiles())], min: 4, max: 12, bounds: [34, 16, 56, 33])
            legend.time = "آخر ٨ أيام مقارنة بالصيف"
        case .clouds:
            refreshFrames()
            if !frames.isEmpty {
                let key = "clouds-" + frames.map(\.id).joined(separator: ",")
                let fresh = drawn != Drawn(kind: .clouds, key: key)
                install(m, kind: .clouds, key: key,
                        sources: frames.map { ("cloud-\($0.id)", WeatherLayerAPI.absolute($0.tile_url)) }, min: 3, max: 9, bounds: [25, 8, 65, 40],
                        visibleIndex: frames.count - 1)
                if fresh {
                    /* New frames (first open or a refresh): show the newest and play. A plain
                     * re-apply (chrome/layout) must not disturb a paused or scrubbed frame. */
                    legend.playing = true
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
        for (i, (id, url)) in sources.enumerated() {
            var src = RasterSource(id: Self.prefix + id)
            src.tiles = [url]
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
        guard show else { return }
        let width = min(map.bounds.width - 24, 360)
        let size = host.sizeThatFits(in: CGSize(width: width, height: 400))
        host.view.frame = CGRect(x: (map.bounds.width - width) / 2, y: request.chrome.top + 8, width: width, height: size.height)
    }
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
    var onTogglePlay: () -> Void = {}
    var onScrub: (Int) -> Void = { _ in }
}

/// «السحاب الآن · الساعة ٢:٠٠ م» + colour key + the source's credit line.
struct WeatherLegendCard: View {
    @ObservedObject var model: WeatherLegendModel
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: model.kind.systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(p.accentText)
                Text(model.kind.label).saryText(.subhead, weight: .bold).foregroundStyle(p.textPrimary)
                Spacer(minLength: 4)
                Text(model.time).saryText(.footnote, weight: .bold).foregroundStyle(p.textSecondary)
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .accessibilityIdentifier("weather.legend.time")
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
        .accessibilityElement(children: .contain)
    }
}
