@_spi(Experimental) import MapboxMaps
import os
import UIKit

/// What the visuals pack reads from the live map each tick (the map's coordinator fills it).
struct MapVisualInputs {
    /// My shown position (sun, light and sky are for where I am); nil before the first fix.
    var me: LngLat?
    /// Guidance, motion or drive mode: the safety rules apply (no flight, no extra colour, true heights).
    var driving = false
    var exploring = false
    var terrain3D = false
    /// The design system's night mode (forced, or auto after sunset): it wins over the sun.
    var night = false
    var layer: MapLayer = .satellite
    var chrome: UIEdgeInsets = .zero
    /// Routes / tracks on the map, for «انحدار تقريبي».
    var routes: [[LngLat]] = []
}

/// «المؤثرات البصرية» on the live map, all from real data computed or cached on the phone:
/// terrain exaggeration that follows the pitch, a hillshade lit from the real sun, fog and sky
/// from the sun altitude and the weather layer's cached forecast, a steady glow under routes,
/// «انحدار تقريبي» from the DEM, and the drone orbit. Owned by the map's coordinator; every
/// layer it adds is prefixed `wow-` and is re-added after each style load.
final class MapVisualsDirector: NSObject {
    private weak var map: MapView?
    private var inputs: () -> MapVisualInputs = { MapVisualInputs() }
    private var takeCamera: () -> Void = {}
    private var cancelables = Set<AnyCancelable>()
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?
    private var styleReady = false

    private(set) var settings = VisualEffectsSettings.current
    private(set) var effective: EffectiveVisuals
    /// The exaggeration we set last (nil: never set — the coordinator's legacy value stands).
    private(set) var appliedExaggeration: Double?
    private var lastInputs = MapVisualInputs()
    private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled

    private var sun: SunPosition?
    private var sunAt: CFTimeInterval = 0
    private var appliedPreset: SunLight.Preset?
    private var appliedSky: SkyAtmosphere?
    private var fogSet = false
    private var appliedHillshade: HillshadeLight?
    private var appliedScene: SceneLight?
    private var prefetch: DronePrefetch?
    /// The flight waits at the orbit's start (≤ 3 s) until the orbit's tiles are in.
    private var holdUntil: CFTimeInterval = 0
    private var lastStep: CFTimeInterval = 0
    private var weather: SkyWeather?
    private var weatherCell: WeatherArea?
    private var weatherAt: CFTimeInterval = -1_000
    private var slopeKey: String?
    private var slopeAt: CFTimeInterval = 0
    private var slopeSegments: [SlopeProfile.Segment] = []
    /// The buildings' opacity we set last (nil: no buildings layer).
    private var appliedBuildingsOpacity: Double?
    /// `SandGrade`'s `sarySand` last set on the imported satellite basemap.
    private var appliedSand: Double?
    private let overlay = VisualsSourceView()
    /// «تفاصيل الرمال» (`SandDetail`): natural micro-relief over the desert imagery up close.
    private let sandDetail = SandDetailLayer()

    private var flight: DroneOrbit?
    private var flightStart: CFTimeInterval = 0
    private var link: CADisplayLink?
    private var frameTimes: [CFTimeInterval] = []
    private var touchStop: TouchStopRecognizer?

    static let log = OSSignposter(subsystem: "sa.sary.albarq", category: "MapVisuals")
    static let hillshadeSource = "wow-hillshade-dem"
    static let hillshadeLayer = "wow-hillshade"
    /// The broad pass: the same DEM capped at z11, so the big dune forms shade softly at any zoom.
    static let hillshadeBroadSource = "wow-hillshade-dem-broad"
    static let hillshadeBroadLayer = "wow-hillshade-broad"
    static let ambientLight = "wow-ambient"
    static let directionalLight = "wow-directional"
    static let buildingsSource = "wow-buildings-streets"
    static let buildingsLayer = "wow-buildings-3d"
    static let slopeSource = "wow-slope"
    static let slopeLayer = "wow-slope-line"
    static let glowPrefix = "wow-glow-"
    /// Line layers that get the glow, and the layer that means "already glowing" (skip then).
    static let glowTargets: [(id: String, skipIf: String?)] = [
        ("sary-track-mine-line", "sary-track-mine-glow"),
        ("sary-track-follow-line", "sary-track-follow-glow"),
        ("sary-explore-tracks-line", nil),
        ("sary-nav-main", nil),
        ("sary-plan-line", nil),
    ]

    override init() {
        effective = VisualBudget.resolve(settings, VisualContext())
        super.init()
        /* «تخفيف الزحمة» ٦: the source line folds away after a few seconds; the overlay shrinks with it. */
        overlay.onExpire = { [weak self] in self?.layoutOverlay() }
    }

    /// The light preset and sky are ours (the coordinator's own `applyLight` stands aside).
    var ownsLight: Bool { effective.managed && effective.sky }

    /// The terrain exaggeration in force (the coordinator undoes it for real elevations).
    func exaggeration(legacy: Double) -> Double { appliedExaggeration ?? legacy }

    // MARK: lifecycle

    func attach(_ map: MapView, inputs: @escaping () -> MapVisualInputs, takeCamera: @escaping () -> Void) {
        self.map = map
        self.inputs = inputs
        self.takeCamera = takeCamera
        map.mapboxMap.onStyleLoaded.observe { [weak self] _ in self?.styleLoaded() }.store(in: &cancelables)
        map.mapboxMap.onCameraChanged.observe { [weak self] _ in self?.cameraChanged() }.store(in: &cancelables)
        map.mapboxMap.onMapIdle.observe { [weak self] _ in self?.idle() }.store(in: &cancelables)
        overlay.translatesAutoresizingMaskIntoConstraints = true
        overlay.isUserInteractionEnabled = false
        map.addSubview(overlay)
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            let s = VisualEffectsSettings.current
            if s != self.settings { self.settings = s; self.refresh(force: true) }
        })
        observers.append(nc.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
            self?.refresh(force: true)
        })
        observers.append(nc.addObserver(forName: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refresh(force: true)
        })
        observers.append(nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.stopDrone()
        })
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = 0.3
        RunLoop.main.add(t, forMode: .common)
        timer = t
        MapVisualsHub.shared.director = self
        #if DEBUG
        VisualsDemo.prepare()
        #endif
    }

    func detach() {
        stopDrone()
        timer?.invalidate()
        timer = nil
        cancelables.removeAll()
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers = []
        overlay.removeFromSuperview()
        if MapVisualsHub.shared.director === self { MapVisualsHub.shared.director = nil }
    }

    // MARK: inputs → effects

    private func context(_ i: MapVisualInputs, pitch: Double, zoom: Double, center: CLLocationCoordinate2D) -> VisualContext {
        VisualContext(driving: i.driving, exploring: i.exploring, terrain3D: i.terrain3D, flying: flight != nil, lowPower: lowPower,
                      reduceMotion: UIAccessibility.isReduceMotionEnabled, layer: i.layer, pitch: pitch, zoom: zoom,
                      urban: UrbanAreas.weight(lat: center.latitude, lng: center.longitude))
    }

    private func tick() {
        let i = inputs()
        let changed = i.driving != lastInputs.driving || i.layer != lastInputs.layer || i.night != lastInputs.night
            || i.exploring != lastInputs.exploring || i.terrain3D != lastInputs.terrain3D || i.chrome != lastInputs.chrome
        lastInputs = i
        if MapVisualsHub.shared.driving != i.driving { MapVisualsHub.shared.driving = i.driving }
        if i.driving, flight != nil { stopDrone() }
        let now = CACurrentMediaTime()
        refresh(force: changed || now - sunAt > 30)
    }

    /// Recompute what is on and apply what changed. Cheap when nothing did.
    private func refresh(force: Bool) {
        guard let map else { return }
        let i = inputs()
        lastInputs = i
        let st = map.mapboxMap.cameraState
        let e = VisualBudget.resolve(settings, context(i, pitch: st.pitch, zoom: st.zoom, center: st.center))
        let was = effective
        effective = e
        guard styleReady else { return }
        let state = Self.log.beginInterval("apply")
        defer { Self.log.endInterval("apply", state) }
        applyExaggeration()
        if force || e != was {
            updateSun(force: true)
            updateWeatherIfDue(force: e.atmosphere != was.atmosphere)
            applyLight()
            applyHillshade()
            applyFog()
            ensureGlow()
            if !e.slope { clearSlope() }
            layoutOverlay()
        }
        applyBuildings(pitch: st.pitch)
        applySand(st)
        applySandDetail()
        publishCityTilt(st)
    }

    private func styleLoaded() {
        guard let map else { return }
        styleReady = true
        appliedPreset = nil
        appliedSky = nil
        appliedHillshade = nil
        appliedScene = nil
        fogSet = false
        slopeKey = nil
        appliedExaggeration = nil
        appliedBuildingsOpacity = nil
        appliedSand = nil
        sandDetail.styleLoaded()
        let m: MapboxMap = map.mapboxMap
        /* Terrain changes glide (none with Reduce Motion). */
        try? m.setTerrainProperty("exaggeration-transition", value: ["duration": UIAccessibility.isReduceMotionEnabled ? 0 : 400, "delay": 0])
        refresh(force: true)
        #if DEBUG
        VisualsDemo.styleLoaded(self)
        #endif
    }

    private func cameraChanged() {
        guard styleReady, let map else { return }
        let st = map.mapboxMap.cameraState
        let c = context(lastInputs, pitch: st.pitch, zoom: st.zoom, center: st.center)
        if effective.managed, settings.terrain {
            effective.exaggeration = VisualBudget.exaggeration(c)
            applyExaggeration()
        }
        /* Panning into / out of a city: the buildings come and go with it. */
        let b = VisualBudget.buildings(settings, c)
        if b != effective.buildings { effective.buildings = b }
        applyBuildings(pitch: st.pitch)
        applySand(st)
        publishCityTilt(st)
    }

    // MARK: sand detail

    /// «تفاصيل الرمال»: on with the budget, lit from the sun over the map centre (the hillshade's light).
    private func applySandDetail() {
        guard styleReady, let map else { return }
        let c = map.mapboxMap.cameraState.center
        let here = sun.map { _ in SunPosition.at(clock, lat: c.latitude, lng: c.longitude) }
        var on = effective.sandDetail
        #if DEBUG
        /* Before / after shots: `-SarySandDetail off`. */
        let a = ProcessInfo.processInfo.arguments
        if let i = a.firstIndex(of: "-SarySandDetail"), i + 1 < a.count, a[i + 1] == "off" { on = false }
        #endif
        sandDetail.apply(on, map: map, light: SandDetail.Light.from(here, night: lastInputs.night),
                         scale: VisualBudget.sandDetailScale(driving: lastInputs.driving))
    }

    // MARK: sand grade

    /// The imagery's warm sand grade (`SandGrade`) at full strength in the open desert, faded out
    /// over a city (`UrbanAreas`, smooth at its edge). Independent of «المؤثرات البصرية»: it is the
    /// satellite picture's own colour correction.
    private func applySand(_ st: CameraState) {
        guard styleReady, lastInputs.layer == .satellite, let m = map?.mapboxMap else { return }
        let v = SandGrade.sand(urban: UrbanAreas.weight(lat: st.center.latitude, lng: st.center.longitude))
        guard v != appliedSand else { return }
        appliedSand = v
        try? m.setStyleImportConfigProperty(for: "basemap", config: SandGrade.configKey, value: v)
    }

    // MARK: city buildings

    /// Neutral 3D buildings from Mapbox Streets' footprints and heights, over the satellite imagery
    /// in a city. Sand walls, light roofs, ambient occlusion at their feet and the real sun's shadows
    /// (the scene's directional light casts them) — they stand where the draped photo only smears.
    /// Faded in with the tilt, so the 2D map looking down is the imagery as before.
    private func applyBuildings(pitch: Double) {
        guard styleReady, let m = map?.mapboxMap else { return }
        guard effective.buildings else {
            if appliedBuildingsOpacity != nil || m.layerExists(withId: Self.buildingsLayer) {
                if m.layerExists(withId: Self.buildingsLayer) { try? m.removeLayer(withId: Self.buildingsLayer) }
                appliedBuildingsOpacity = nil
            }
            return
        }
        /* Steps of 0.05: a gesture does not restyle the layer every frame. */
        let opacity = (VisualBudget.buildingsOpacity(pitch: pitch) * 20).rounded() / 20
        if !m.layerExists(withId: Self.buildingsLayer) {
            if !m.sourceExists(withId: Self.buildingsSource) {
                try? m.addSource(withId: Self.buildingsSource, properties: ["type": "vector", "url": "mapbox://mapbox.mapbox-streets-v8"])
            }
            var layer = CityBuildings.layer(id: Self.buildingsLayer, source: Self.buildingsSource, opacity: opacity)
            if lastInputs.layer.isImport { layer["slot"] = "middle" }
            try? m.addLayer(with: layer, layerPosition: nil)
            appliedBuildingsOpacity = opacity
            return
        }
        guard opacity != appliedBuildingsOpacity else { return }
        appliedBuildingsOpacity = opacity
        try? m.setLayerProperty(for: Self.buildingsLayer, property: "fill-extrusion-opacity", value: opacity)
    }

    /// «اعرضها بالوضع الواقعي»: tilted over a city, the photoreal view is one tap away.
    private func publishCityTilt(_ st: CameraState) {
        let on = CityBuildings.offerRealistic(pitch: st.pitch, zoom: st.zoom,
                                              urban: UrbanAreas.weight(lat: st.center.latitude, lng: st.center.longitude))
        if MapVisualsHub.shared.cityTilt != on { MapVisualsHub.shared.cityTilt = on }
    }

    /// The live camera as «الوضع الواقعي» frames it (same centre, heading, tilt and distance).
    func realisticCamera() -> RealisticRules.Camera? {
        guard let map else { return nil }
        let st = map.mapboxMap.cameraState
        return RealisticRules.camera(fromMapbox: LngLat(lng: st.center.longitude, lat: st.center.latitude), zoom: st.zoom,
                                     pitch: st.pitch, bearing: st.bearing, viewHeight: Double(map.bounds.height))
    }

    private func applyExaggeration() {
        guard styleReady, let m = map?.mapboxMap else { return }
        guard effective.managed else {
            if appliedExaggeration != nil {
                appliedExaggeration = nil
                try? m.setTerrainProperty("exaggeration", value: effective.exaggeration)
            }
            return
        }
        let ex = (effective.exaggeration * 100).rounded() / 100
        if let a = appliedExaggeration, abs(a - ex) < 0.015 { return }
        appliedExaggeration = ex
        try? m.setTerrainProperty("exaggeration", value: ex)
    }

    private func idle() {
        guard styleReady else { return }
        refresh(force: false)
        updateSun(force: false)
        updateWeatherIfDue(force: false)
        ensureGlow()
        refreshSlope()
    }

    // MARK: sun & light

    private var clock: Date {
        #if DEBUG
        return VisualsDemo.now()
        #else
        return Date()
        #endif
    }

    private func updateSun(force: Bool) {
        guard let map else { return }
        let now = CACurrentMediaTime()
        guard force || now - sunAt > 30 || sun == nil else { return }
        sunAt = now
        let c = map.mapboxMap.cameraState.center
        let at = lastInputs.me ?? LngLat(lng: c.longitude, lat: c.latitude)
        sun = SunPosition.at(clock, lat: at.lat, lng: at.lng)
        applyLight()
        applyHillshade()
        applyFog()
        ensureGlow(restyle: true)
        applySandDetail()
    }

    /// The sun the sky is drawn for: the real one, unless night mode is forced on.
    private var skySun: SunPosition? {
        guard var s = sun else { return nil }
        if lastInputs.night, s.altitudeDeg > -12 { s.altitudeDeg = -12; s.rising = false }
        return s
    }

    private func applyLight() {
        guard styleReady, lastInputs.layer.isImport, let m = map?.mapboxMap else { return }
        guard ownsLight, let s = skySun else {
            /* Handed back: Standard's own lights for the preset the coordinator sets. */
            if appliedScene != nil, let s = skySun {
                appliedScene = nil
                setScene(SceneLight.standard(lastInputs.night ? .night : s.preset), m)
            }
            return
        }
        let p = s.preset
        if p != appliedPreset {
            appliedPreset = p
            /* The preset still themes Standard's roads, labels and 3D objects; the light itself is ours. */
            try? m.setStyleImportConfigProperty(for: "basemap", config: "lightPreset", value: p.rawValue)
        }
        let scene = SceneLight.from(s)
        guard scene != appliedScene else { return }
        appliedScene = scene
        setScene(scene, m)
    }

    private func setScene(_ l: SceneLight, _ m: MapboxMap) {
        let t = StyleTransition(duration: Double(effective.transitionMs) / 1000, delay: 0)
        var a = AmbientLight(id: Self.ambientLight)
        a.color = .constant(StyleColor(l.ambient.uiColor))
        a.colorTransition = t
        a.intensity = .constant(l.ambientIntensity)
        a.intensityTransition = t
        var d = DirectionalLight(id: Self.directionalLight)
        d.color = .constant(StyleColor(l.directional.uiColor))
        d.colorTransition = t
        d.intensity = .constant(l.directionalIntensity)
        d.intensityTransition = t
        d.direction = .constant(l.direction)
        d.directionTransition = t
        d.castShadows = .constant(true)
        d.shadowIntensity = .constant(l.shadowIntensity)
        try? m.setLights(ambient: a, directional: d)
    }

    private func applyHillshade() {
        guard styleReady, let map else { return }
        let m: MapboxMap = map.mapboxMap
        guard effective.hillshade, let sunNow = sun else {
            for id in [Self.hillshadeLayer, Self.hillshadeBroadLayer] where m.layerExists(withId: id) { try? m.removeLayer(withId: id) }
            appliedHillshade = nil
            return
        }
        /* The light comes from the sun over the map centre (where the relief is being looked at). */
        let c = m.cameraState.center
        var here = SunPosition.at(clock, lat: c.latitude, lng: c.longitude)
        if lastInputs.night || sunNow.altitudeDeg <= -12 { here.altitudeDeg = min(here.altitudeDeg, -12) }
        let h = HillshadeLight.from(here, satellite: lastInputs.layer == .satellite)
        /* Their own sources (Mapbox advises not sharing the terrain's), same tiles: cached / offline alike. */
        if !m.sourceExists(withId: Self.hillshadeSource) {
            try? m.addSource(withId: Self.hillshadeSource, properties: ["type": "raster-dem", "url": "mapbox://mapbox.mapbox-terrain-dem-v1",
                                                                        "tileSize": 512, "maxzoom": 14])
        }
        if !m.sourceExists(withId: Self.hillshadeBroadSource) {
            try? m.addSource(withId: Self.hillshadeBroadSource, properties: ["type": "raster-dem", "url": "mapbox://mapbox.mapbox-terrain-dem-v1",
                                                                             "tileSize": 512, "maxzoom": 11])
        }
        let broad = h.broad
        /* Detail pass: crisper as you come closer (the ~30 m DEM's ridges and slip faces). */
        let detailEx: [Any] = ["interpolate", ["linear"], ["zoom"], 9, h.exaggeration * 0.6, 12, h.exaggeration, 15, min(1, h.exaggeration * 1.12)]
        let broadEx: [Any] = ["interpolate", ["linear"], ["zoom"], 8, broad.exaggeration, 15, broad.exaggeration * 0.75]
        put(Self.hillshadeBroadLayer, source: Self.hillshadeBroadSource, light: broad, exaggeration: broadEx, below: nil, m, changed: h != appliedHillshade)
        put(Self.hillshadeLayer, source: Self.hillshadeSource, light: h, exaggeration: detailEx, below: nil, m, changed: h != appliedHillshade)
        appliedHillshade = h
    }

    private func put(_ id: String, source: String, light h: HillshadeLight, exaggeration: [Any], below: String?, _ m: MapboxMap, changed: Bool) {
        let t: [String: Any] = ["duration": effective.transitionMs, "delay": 0]
        let paint: [String: Any] = [
            "hillshade-illumination-anchor": "map", "hillshade-illumination-direction": h.direction,
            "hillshade-exaggeration": exaggeration,
            "hillshade-shadow-color": h.shadow.css, "hillshade-shadow-color-transition": t,
            "hillshade-highlight-color": h.highlight.css, "hillshade-highlight-color-transition": t,
            "hillshade-accent-color": h.accent.css, "hillshade-accent-color-transition": t,
            /* Our colours are already the sun's: not re-tinted by the scene light. */
            "hillshade-emissive-strength": 1,
        ]
        if !m.layerExists(withId: id) {
            var layer: [String: Any] = ["id": id, "type": "hillshade", "source": source, "paint": paint]
            if lastInputs.layer.isImport { layer["slot"] = "bottom" }
            try? m.addLayer(with: layer, layerPosition: nil)
        } else if changed {
            for (k, v) in paint { try? m.setLayerProperty(for: id, property: k, value: v) }
        }
    }

    // MARK: weather → fog

    private func updateWeatherIfDue(force: Bool) {
        guard effective.atmosphere, let map else {
            if weather != nil { weather = nil; applyFog() }
            return
        }
        let c = map.mapboxMap.cameraState.center
        let at = lastInputs.me ?? LngLat(lng: c.longitude, lat: c.latitude)
        let cell = WeatherArea(around: at.lat, lng: at.lng)
        let now = CACurrentMediaTime()
        guard force || cell != weatherCell || now - weatherAt > 60 else { return }
        weatherCell = cell
        weatherAt = now
        let date = clock
        let centre = WeatherArea(around: c.latitude, lng: c.longitude)
        /* The weather layer's own cache on disk (no request is ever made for the visuals). */
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var report: WeatherReport?
            #if DEBUG
            report = WeatherDemo.report(for: cell, now: date)
            #endif
            if report == nil {
                let cache = WeatherCache()
                report = cache.report(cell) ?? (centre != cell ? cache.report(centre) : nil)
            }
            let w = SkyWeather.from(report, now: date)
            DispatchQueue.main.async {
                guard let self, w != self.weather else { return }
                self.weather = w
                self.applyFog()
            }
        }
    }

    private func applyFog() {
        guard styleReady, let m = map?.mapboxMap else { return }
        guard effective.managed, effective.sky || effective.atmosphere, let s = skySun else {
            if fogSet { try? m.removeAtmosphere(); fogSet = false; appliedSky = nil }
            overlay.set(source: nil, slope: overlay.slopeShown ? SlopeProfile.legend : nil)
            layoutOverlay()
            return
        }
        /* The sun alone when «السماء والإضاءة» is off but the weather is on: a neutral day sky. */
        let alt = effective.sky ? s.altitudeDeg : 30
        var sky = SkyAtmosphere.make(sunAltitude: alt, weather: effective.atmosphere ? weather : nil, now: clock)
        if !effective.stars { sky.starIntensity = 0 }
        if sky != appliedSky {
            appliedSky = sky
            try? m.setAtmosphere(properties: sky.properties(transitionMs: effective.transitionMs))
            fogSet = true
        }
        overlay.set(source: lastInputs.driving ? nil : sky.sourceLine, slope: overlay.slopeShown ? SlopeProfile.legend : nil)
        layoutOverlay()
    }

    // MARK: glow

    private func ensureGlow(restyle: Bool = false) {
        guard styleReady, let m = map?.mapboxMap else { return }
        let state = Self.log.beginInterval("glow")
        defer { Self.log.endInterval("glow", state) }
        let night = (skySun?.altitudeDeg ?? 30) < -4
        for t in Self.glowTargets {
            let gid = Self.glowPrefix + t.id
            let want = effective.managed && effective.glow && m.layerExists(withId: t.id) && !(t.skipIf.map { m.layerExists(withId: $0) } ?? false)
            if !want {
                if m.layerExists(withId: gid) { try? m.removeLayer(withId: gid) }
                continue
            }
            guard let props = try? m.layerProperties(for: t.id), let source = props["source"] as? String else { continue }
            let paint = props["paint"] as? [String: Any] ?? [:]
            if !m.layerExists(withId: gid) {
                var layer: [String: Any] = ["id": gid, "type": "line", "source": source,
                                            "layout": ["line-join": "round", "line-cap": "round"],
                                            "paint": Self.glowPaint(colour: paint["line-color"], gradient: paint["line-gradient"], night: night)]
                if let f = props["filter"] { layer["filter"] = f }
                if let sl = props["source-layer"] { layer["source-layer"] = sl }
                let casing = t.id.hasSuffix("-line") ? String(t.id.dropLast(5)) + "-casing" : t.id + "-casing"
                let below = m.layerExists(withId: casing) ? casing : t.id
                try? m.addLayer(with: layer, layerPosition: .below(below))
            } else {
                /* Track colours follow the data (the speed gradient is rewritten with each new line). */
                if let g = paint["line-gradient"] { try? m.setLayerProperty(for: gid, property: "line-gradient", value: g) }
                if restyle { try? m.setLayerProperty(for: gid, property: "line-opacity", value: night ? 0.42 : 0.24) }
            }
        }
    }

    /// Wide, blurred, emissive (reads the same at night) and steady: never animated.
    static func glowPaint(colour: Any?, gradient: Any?, night: Bool) -> [String: Any] {
        var p: [String: Any] = [
            "line-width": ["interpolate", ["exponential", 1.5], ["zoom"], 8, 6, 12, 11, 16, 22, 20, 34],
            "line-blur": ["interpolate", ["linear"], ["zoom"], 8, 4, 16, 10, 20, 14],
            "line-opacity": night ? 0.42 : 0.24,
            "line-emissive-strength": 1,
        ]
        if let gradient { p["line-gradient"] = gradient } else { p["line-color"] = colour ?? "#ffb35c" }
        return p
    }

    // MARK: slope

    private func refreshSlope() {
        guard styleReady, effective.slope, let map else { clearSlope(); return }
        let routes = lastInputs.routes.filter { $0.count >= 2 }
        guard !routes.isEmpty else { clearSlope(); return }
        let now = CACurrentMediaTime()
        let st = map.mapboxMap.cameraState
        /* The DEM answers only where its tiles are loaded: recompute as the camera settles elsewhere. */
        let key = "\(routes.map { "\($0.count):\($0.first!.lng):\($0.last!.lat)" }.joined(separator: "|"))@\(Int(st.zoom))/\(Int(st.center.latitude * 200))/\(Int(st.center.longitude * 200))"
        guard key != slopeKey, now - slopeAt > 1.5 else { return }
        slopeKey = key
        slopeAt = now
        let state = Self.log.beginInterval("slope")
        let m: MapboxMap = map.mapboxMap
        let ex = appliedExaggeration ?? effective.exaggeration
        var segs: [SlopeProfile.Segment] = []
        var budget = SlopeProfile.maxSamples
        for r in routes where budget > 50 {
            let samples = SlopeProfile.resample(r, maxSamples: budget)
            budget -= samples.count
            /* Mapbox returns heights × the exaggeration: undo it for real metres. */
            let elev = samples.map { p in m.elevation(at: p.coordinate).map { $0 / max(ex, 0.01) } }
            segs += SlopeProfile.steep(samples: samples, elevations: elev)
        }
        Self.log.endInterval("slope", state)
        slopeSegments = segs
        drawSlope(m)
    }

    private func drawSlope(_ m: MapboxMap) {
        let fc = FeatureCollection(features: slopeSegments.map { s in
            var f = Feature(geometry: .lineString(LineString(s.points.map(\.coordinate))))
            f.properties = ["g": .number(s.maxGradePct), "s": .number(s.maxGradePct >= SlopeProfile.verySteepPct ? 2 : 1)]
            return f
        })
        if !m.sourceExists(withId: Self.slopeSource) {
            var s = GeoJSONSource(id: Self.slopeSource)
            s.data = .featureCollection(fc)
            try? m.addSource(s)
        } else {
            m.updateGeoJSONSource(withId: Self.slopeSource, geoJSON: .featureCollection(fc))
        }
        if !m.layerExists(withId: Self.slopeLayer) {
            let below = m.allLayerIdentifiers.first { $0.id.hasPrefix("sary-vehicle") }?.id
            try? m.addLayer(with: [
                "id": Self.slopeLayer, "type": "line", "source": Self.slopeSource,
                "layout": ["line-join": "round", "line-cap": "round"],
                "paint": ["line-color": ["match", ["get", "s"], 2, "#FF5A3C", "#F5B83D"],
                          "line-width": ["interpolate", ["exponential", 1.5], ["zoom"], 8, 1.5, 14, 3.5, 18, 6],
                          "line-opacity": 0.95, "line-emissive-strength": 1] as [String: Any],
            ], layerPosition: below.map { .below($0) })
        }
        overlay.slopeShown = !slopeSegments.isEmpty
        overlay.set(source: overlay.sourceText, slope: overlay.slopeShown ? SlopeProfile.legend : nil)
        layoutOverlay()
    }

    private func clearSlope() {
        guard let m = map?.mapboxMap else { return }
        slopeKey = nil
        slopeSegments = []
        if m.layerExists(withId: Self.slopeLayer) { try? m.removeLayer(withId: Self.slopeLayer) }
        if overlay.slopeShown {
            overlay.slopeShown = false
            overlay.set(source: overlay.sourceText, slope: nil)
            layoutOverlay()
        }
    }

    // MARK: drone

    func startDrone(at p: LngLat) {
        guard let map else { return }
        let i = inputs()
        guard DroneOrbit.allowed(driving: i.driving) else { return }
        stopDrone()
        takeCamera()
        let st = map.mapboxMap.cameraState
        let from = DroneOrbit.Frame(center: LngLat(lng: st.center.longitude, lat: st.center.latitude), zoom: st.zoom, bearing: st.bearing, pitch: st.pitch)
        var orbit = DroneOrbit(center: p, from: from)
        /* A little lower and less steep than before: closer dunes, less far horizon to stream. */
        orbit.zoom = max(15.0, min(16.2, st.zoom < 12 ? 15.6 : 15.8))
        orbit.pitch = DroneOrbit.defaultPitch
        if UIAccessibility.isReduceMotionEnabled {
            /* Reduce Motion: the same low, tilted view — still, no circling. */
            map.mapboxMap.setCamera(to: CameraOptions(center: p.coordinate, zoom: orbit.zoom, bearing: st.bearing, pitch: orbit.pitch))
            UIAccessibility.post(notification: .announcement, argument: "عرض مائل ثابت فوق النقطة (تقليل الحركة مفعّل)")
            return
        }
        flight = orbit
        flightStart = CACurrentMediaTime()
        lastStep = flightStart
        /* Prefetch the orbit's terrain (a temporary tile region, removed after) and hold at the orbit's
           start until it is in (≤ 3 s), so the circle never flies over white, unloaded ground. */
        let pf = DronePrefetch(center: p)
        prefetch = pf
        holdUntil = flightStart + orbit.approachS + 3
        pf.start()
        frameTimes = []
        MapVisualsHub.shared.setFlying(true)
        refresh(force: false)
        let l = CADisplayLink(target: WeakTarget(self), selector: #selector(WeakTarget.step))
        let fps = Float(effective.maxFps)
        l.preferredFrameRateRange = CAFrameRateRange(minimum: min(30, fps), maximum: fps, preferred: fps)
        l.add(to: .main, forMode: .common)
        link = l
        /* Any touch anywhere (map, sheet, buttons) ends the flight at once. */
        if let w = map.window {
            let r = TouchStopRecognizer { [weak self] in self?.stopDrone() }
            w.addGestureRecognizer(r)
            touchStop = r
        }
        flightSignpost = Self.log.beginInterval("droneFlight")
        /* Says so to VoiceOver and UI tests: the camera is flying, not the person. */
        map.accessibilityValue = "طيران درون"
        UIAccessibility.post(notification: .announcement, argument: "بدأ طيران الدرون. المس الشاشة للإيقاف")
    }

    private var flightSignpost: OSSignpostIntervalState?

    fileprivate func step() {
        guard let flight, let map else { stopDrone(); return }
        let now = CACurrentMediaTime()
        frameTimes.append(now)
        if now - flightStart > flight.approachS, now < holdUntil, prefetch?.done == false {
            /* Hover at the orbit's start: the flight's clock waits for the tiles. */
            flightStart += now - lastStep
        }
        lastStep = now
        guard let f = flight.frame(at: now - flightStart) else { stopDrone(); return }
        map.mapboxMap.setCamera(to: CameraOptions(center: f.center.coordinate, zoom: f.zoom, bearing: f.bearing, pitch: f.pitch))
    }

    func stopDrone() {
        guard flight != nil || link != nil else { return }
        link?.invalidate()
        link = nil
        flight = nil
        prefetch?.finish()
        prefetch = nil
        if let r = touchStop { r.view?.removeGestureRecognizer(r) }
        touchStop = nil
        if let s = flightSignpost { Self.log.endInterval("droneFlight", s) }
        flightSignpost = nil
        let stats = FramePacing.summary(frameTimes)
        frameTimes = []
        MapVisualsHub.shared.lastFlightStats = stats
        if !stats.isEmpty { Logger(subsystem: "sa.sary.albarq", category: "MapVisuals").info("drone flight: \(stats, privacy: .public)") }
        MapVisualsHub.shared.setFlying(false)
        map?.accessibilityValue = nil
        refresh(force: false)
    }

    #if DEBUG
    /// Screenshot scenarios only (`VisualsDemo`): put the camera somewhere and keep it there.
    func demoCamera(_ c: CameraOptions) {
        takeCamera()
        map?.mapboxMap.setCamera(to: c)
    }
    #endif

    // MARK: overlay

    private func layoutOverlay() {
        guard let map else { return }
        let size = overlay.fit(maxWidth: map.bounds.width - 32)
        overlay.frame = CGRect(x: (map.bounds.width - size.width) / 2, y: lastInputs.chrome.top + 6, width: size.width, height: size.height)
        overlay.isHidden = size.height == 0 || lastInputs.driving
        if !overlay.isHidden && map.window != nil { overlay.armFold() }
    }
}

/// CADisplayLink retains its target: this breaks the cycle.
private final class WeakTarget: NSObject {
    weak var owner: MapVisualsDirector?
    init(_ o: MapVisualsDirector) { owner = o }
    @objc func step() { owner?.step() }
}

/// Fails at once (never steals the touch) but reports that a finger came down.
final class TouchStopRecognizer: UIGestureRecognizer {
    private let onTouch: () -> Void
    init(_ onTouch: @escaping () -> Void) {
        self.onTouch = onTouch
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        onTouch()
        state = .failed
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
}

/// Frame pacing of a flight: average fps, the 95th-percentile frame and hitches (> 25 ms).
enum FramePacing {
    static func summary(_ t: [CFTimeInterval]) -> String {
        guard t.count > 10 else { return "" }
        let dts = zip(t.dropFirst(), t).map { $0 - $1 }.sorted()
        let avg = Double(dts.count) / (t.last! - t.first!)
        let p95 = dts[min(dts.count - 1, Int(Double(dts.count) * 0.95))] * 1000
        let hitches = dts.filter { $0 > 0.025 }.count
        return String(format: "frames=%d avg=%.1ffps p95=%.1fms hitches=%d", dts.count + 1, avg, p95, hitches)
    }
}

/// The tiny source line(s) under the top bar: «الأجواء من الطقس: …» and the slope legend.
final class VisualsSourceView: UIView {
    private let stack = UIStackView()
    private let source = UILabel()
    private let slope = UILabel()
    private(set) var sourceText: String?
    var slopeShown = false
    /// «الأجواء من الطقس: …» shows for this long when it appears or changes, then folds away
    /// (the attribution stays in the weather and layers sheets: CC‑BY kept).
    static let sourceSeconds: TimeInterval = 5
    var onExpire: (() -> Void)?
    private var shownKey: String?
    private var expired = false
    private var hideWork: DispatchWorkItem?
    private var visibleSource: String? { expired ? nil : sourceText }

    /// The line is on screen: the 5 s start now (not while the map is still loading behind the sheet).
    func armFold() {
        guard sourceText != nil, !expired, hideWork == nil else { return }
        #if DEBUG
        /* Screenshots of the sky (VisualsUITests) keep the line to read it. */
        if ProcessInfo.processInfo.arguments.contains("-SaryKeepSource") { return }
        #endif
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.expired = true
            self.source.text = nil
            self.source.isHidden = true
            self.accessibilityLabel = self.slopeShown ? self.slope.attributedText?.string : nil
            self.onExpire?()
        }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.sourceSeconds, execute: w)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.black.withAlphaComponent(0.42)
        layer.cornerRadius = 9
        layer.cornerCurve = .continuous
        stack.axis = .vertical
        stack.spacing = 2
        stack.alignment = .center
        for l in [source, slope] {
            l.font = .systemFont(ofSize: 11, weight: .semibold)
            l.adjustsFontForContentSizeCategory = false
            l.textColor = UIColor.white.withAlphaComponent(0.92)
            l.textAlignment = .center
            l.numberOfLines = 1
            l.adjustsFontSizeToFitWidth = true
            l.minimumScaleFactor = 0.8
            stack.addArrangedSubview(l)
        }
        addSubview(stack)
        semanticContentAttribute = .forceRightToLeft
        isAccessibilityElement = true
        accessibilityIdentifier = "visuals.source"
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(source s: String?, slope sl: String?) {
        sourceText = s
        if s != shownKey {
            shownKey = s
            expired = false
            hideWork?.cancel()
            hideWork = nil
        }
        let shown = visibleSource
        source.text = shown
        source.isHidden = shown == nil
        let attr = NSMutableAttributedString()
        if let sl {
            attr.append(NSAttributedString(string: "▬ ", attributes: [.foregroundColor: UIColor(red: 0.96, green: 0.72, blue: 0.24, alpha: 1)]))
            attr.append(NSAttributedString(string: sl))
        }
        slope.attributedText = attr
        slope.isHidden = sl == nil
        accessibilityLabel = [shown, sl].compactMap { $0 }.joined(separator: "، ")
    }

    func fit(maxWidth: CGFloat) -> CGSize {
        guard visibleSource != nil || slopeShown else { return .zero }
        let inner = stack.systemLayoutSizeFitting(CGSize(width: maxWidth - 20, height: 100))
        let w = min(maxWidth, inner.width + 20), h = inner.height + 8
        stack.frame = CGRect(x: 10, y: 4, width: w - 20, height: inner.height)
        return CGSize(width: w, height: h)
    }
}

extension RGBA {
    var uiColor: UIColor { UIColor(red: r / 255, green: g / 255, blue: b / 255, alpha: a) }
}

/// The drone orbit's terrain, fetched before the circle starts: a temporary TileStore region
/// (DEM, z11–14, ~3 km around the point) that the map reads at once; removed
/// when the flight ends (the tiles stay in the ambient cache). Never listed with the offline
/// areas (those are `sary-`). No network at all when the area is already cached or offline.
final class DronePrefetch {
    static let regionId = "wow-drone-prefetch"
    let center: LngLat
    private(set) var done = false
    private var task: Cancelable?
    private let started = CACurrentMediaTime()

    init(center: LngLat) { self.center = center }

    func start() {
        let dLat = 3.0 / 111.0, dLng = 3.0 / (111.0 * max(0.2, cos(center.lat * .pi / 180)))
        let ring = [(-1.0, -1.0), (1, -1), (1, 1), (-1, 1), (-1, -1)].map {
            CLLocationCoordinate2D(latitude: center.lat + $0.1 * dLat, longitude: center.lng + $0.0 * dLng)
        }
        /* The terrain DEM by name (the style's own sources would need a style pack): a missing DEM tile is
           what tears a white, jagged hole in the 3D ground mid-orbit. Imagery still streaming shows the
           style's sand background (ArabicBasemap.tune), never white. */
        let opts = TilesetDescriptorOptions(styleURI: OutingMapboxView.styleURI, zoomRange: 11...14,
                                            tilesets: ["mapbox://mapbox.mapbox-terrain-dem-v1"])
        let descriptor = OfflineManager().createTilesetDescriptor(for: opts)
        guard let load = TileRegionLoadOptions(geometry: .polygon(Polygon([ring])), descriptors: [descriptor], metadata: ["app": "sary-drone"],
                                               acceptExpired: true) else { done = true; return }
        task = TileStore.default.loadTileRegion(forId: Self.regionId, loadOptions: load) { [weak self] result in
            let outcome: String
            switch result {
            case let .success(r): outcome = "\(r.completedResourceCount)/\(r.requiredResourceCount) tiles"
            case let .failure(e): outcome = "failed: \(e)"
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.done = true
                Logger(subsystem: "sa.sary.albarq", category: "MapVisuals")
                    .info("drone prefetch: \(String(format: "%.1f", CACurrentMediaTime() - self.started), privacy: .public) s, \(outcome, privacy: .public)")
            }
        }
    }

    func finish() {
        if !done { task?.cancel() }
        task = nil
        TileStore.default.removeTileRegion(forId: Self.regionId)
    }
}
