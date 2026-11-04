@_spi(Experimental) import MapboxMaps
import SwiftUI
import UIKit

/// One member on the map, as plain data (no network or session types), so any screen can embed the map.
struct MapMember: Equatable, Identifiable {
    var id: String
    /// Where the member really is (the last real fix; never an estimate).
    var position: LngLat
    var color: UInt32
    var name: String
    /// How fresh the fix is (live / last known / lost) — decided by Policy, never guessed here.
    var presence: Policy.Freshness
    /// Reported course, already trusted (nil when parked or not live).
    var heading: Double?
    var accuracyM: Double?
    /// Time of this fix, ms (for the glide length between fixes).
    var atMs: Double
    var note: String?
    var isMe: Bool
    /// Design-system name chip; nil hides the name (names «عند اللمس», or drive mode for others).
    var chip: NameChipUI? = nil
    /// Note bubble over the car; nil in drive mode or with no live note.
    var bubble: NoteBubbleUI? = nil

    /// Worse than 60 m: drawn as an approximate spot, never as a car, never animated (as on the web).
    var approximate: Bool { (accuracyM ?? 0) > Policy.weakAccuracyM }

    /// «أنت» for me; the name otherwise, with its state said in words, not only colour.
    var chipLabel: String {
        let base = isMe ? "أنت" : name
        switch presence {
        case .recent: return base + " · آخر موقع"
        case .lost: return base + " · انقطع"
        case .live: return approximate ? base + " · تقريبي" : base
        }
    }
}

/// The owner's meeting point, if one is set.
struct MapRallyPoint: Equatable {
    var position: LngLat
    var label: String
}

/// A one-shot camera request; a new `id` asks again.
struct MapCameraRequest: Equatable {
    enum Kind: Equatable {
        /// Frame everyone (the web's «المجموعة») and keep them framed until the map is moved by hand.
        case group
        /// Frame me together with this member.
        case withMember(String)
        /// Centre on my own car («موقعي»).
        case me
        /// Centre on a point (rally point, a station, an SOS fix).
        case point(LngLat)
    }

    var kind: Kind
    var id: Int
}

/// The live-outing map on the Mapbox Maps SDK, set up like the web's outing map
/// (`FarqMap` in outdoor mode over `standard-satellite`): every member is the same
/// generated 3D 4×4 in their own colour, a name chip and note bubble float over it,
/// cars are drawn on the street they drive along, and the camera keeps the group
/// on screen clear of the top bar and the bottom panel.
///
/// Self-contained: it takes plain data (members, rally point, camera requests, the
/// screen area our own chrome covers) and reports taps, so any screen design can embed it.
struct OutingMapboxView: UIViewRepresentable {
    var members: [MapMember]
    var rally: MapRallyPoint? = nil
    var camera: MapCameraRequest? = nil
    /// Screen area covered by the host's chrome: top = bottom edge of the top bar, bottom = height of the bottom panel.
    var chrome: UIEdgeInsets = .zero
    /// The resolved design-system theme (chips, rally flag, night light).
    var theme: SaryTheme = .default
    /// While true, a tap on empty map reports its coordinate («حدد نقطة تجمع»).
    var picking = false
    var onMemberTap: (String) -> Void = { _ in }
    var onRallyTap: () -> Void = {}
    var onMapTap: (LngLat) -> Void = { _ in }
    /// Screen points of every car and the rally flag, after each camera move or glide step.
    var onProjection: (MapProjection) -> Void = { _ in }
    /// The person moved the map by hand (keep-group is off until «المجموعة»).
    var onUserGesture: () -> Void = {}

    static let styleURI = StyleURI(rawValue: "mapbox://styles/mapbox/standard-satellite")!

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MapView {
        let camera = CameraOptions(center: CLLocationCoordinate2D(latitude: 24.7136, longitude: 46.6753), zoom: 12.15, bearing: 0, pitch: 0)
        let map = MapView(frame: .zero, mapInitOptions: MapInitOptions(cameraOptions: camera, styleURI: ArabicBasemap.cachedJSON == nil ? Self.styleURI : nil))
        if let json = ArabicBasemap.cachedJSON { map.mapboxMap.loadStyle(json) }
        map.accessibilityIdentifier = "outing.map"
        map.ornaments.options.scaleBar.visibility = .hidden
        map.ornaments.options.compass.visibility = .adaptive
        context.coordinator.theme = theme
        context.coordinator.attach(map)
        ArabicBasemap.load { json in
            /* Same style with place names in Arabic; English labels only if it cannot be fetched. */
            if let json { map.mapboxMap.loadStyle(json) }
        }
        return map
    }

    func updateUIView(_ map: MapView, context: Context) {
        let c = context.coordinator
        c.onCarTap = onMemberTap
        c.onRallyTap = onRallyTap
        c.onMapTap = onMapTap
        c.onProjection = onProjection
        c.onUserGesture = onUserGesture
        c.picking = picking
        if c.theme != theme {
            c.theme = theme
            c.themeChanged()
        }
        c.setChrome(chrome)
        c.sync(members)
        c.setRally(rally)
        if let req = camera, req.id != c.lastCamera {
            c.lastCamera = req.id
            switch req.kind {
            case .group:
                c.keepGroup = true
                c.fitGroup()
            case let .withMember(id):
                c.fitWith(id)
            case .me:
                c.centerOnMe()
            case let .point(p):
                c.center(p)
            }
        }
    }

    static func dismantleUIView(_ map: MapView, coordinator: Coordinator) {
        coordinator.detach()
    }

    // MARK: -

    final class Coordinator: NSObject, GestureManagerDelegate {
        private weak var map: MapView?
        private var cancelables = Set<AnyCancelable>()
        private var styleReady = false
        private var addedModels = Set<String>()
        private var recs: [String: Rec] = [:]
        private var lastCars: [MapMember] = []
        private var link: CADisplayLink?
        private var chrome: UIEdgeInsets = .zero
        private var roads: [RoadSnap.RoadLine] = []
        private var roadQuery: Cancelable?
        private var tapInteraction: Cancelable?
        private var light: SunLight.Preset?
        private var fitting = false
        private var fittedIds = Set<String>()
        var onCarTap: (String) -> Void = { _ in }
        var onRallyTap: () -> Void = {}
        var onMapTap: (LngLat) -> Void = { _ in }
        var onProjection: (MapProjection) -> Void = { _ in }
        var onUserGesture: () -> Void = {}
        var picking = false
        var theme: SaryTheme = .default
        var lastCamera = -1
        private var rallyPin: (point: MapRallyPoint, annotation: ViewAnnotation, host: UIHostingController<RallyPin>)?
        private var lastProjectionAt: CFTimeInterval = 0
        private var projectionPending = false
        /// "Keep everyone on screen": on by default, off once you move the map yourself, back on with the group button.
        var keepGroup = true

        final class Rec {
            var item: MapMember
            var shown: LngLat
            var from: LngLat
            var to: LngLat
            var start: CFTimeInterval = 0
            var duration: Double = 0
            var lastAt: Double
            var heading: Double?
            var anchor: LngLat
            let matcher = RoadSnap.Matcher()
            var model = false
            var layersReady = false
            var annotation: ViewAnnotation?
            var host: UIHostingController<MapChip>?
            var box: ChipBox?

            init(_ item: MapMember, at p: LngLat) {
                self.item = item
                shown = p
                from = p
                to = p
                lastAt = item.atMs
                heading = item.heading
                anchor = item.position
            }

            var key: String { item.isMe ? "" : Vehicle.carKey(item.id) }
        }

        func attach(_ map: MapView) {
            self.map = map
            map.gestures.delegate = self
            map.mapboxMap.onStyleLoaded.observe { [weak self] _ in self?.styleLoaded() }.store(in: &cancelables)
            /* Road tiles arrive as the camera settles: refresh the street lines cars are matched to. */
            map.mapboxMap.onMapIdle.observe { [weak self] _ in self?.refreshRoads() }.store(in: &cancelables)
            map.mapboxMap.onCameraChanged.observe { [weak self] _ in self?.project() }.store(in: &cancelables)
            /* Tapping the car itself does what tapping its name does; in pick mode an empty spot is the answer. */
            tapInteraction = map.mapboxMap.addInteraction(TapInteraction { [weak self] ctx in
                guard let self else { return false }
                if let id = self.car(at: ctx.point) {
                    self.onCarTap(id)
                    return true
                }
                if self.picking {
                    self.onMapTap(LngLat(lng: ctx.coordinate.longitude, lat: ctx.coordinate.latitude))
                    return true
                }
                return false
            })
        }

        func detach() {
            link?.invalidate()
            link = nil
            roadQuery?.cancel()
            tapInteraction?.cancel()
            cancelables.removeAll()
        }

        func setChrome(_ insets: UIEdgeInsets) {
            guard insets != chrome, let map else { return }
            chrome = insets
            /* Mapbox's logo and attribution stay visible, just above the bottom panel. */
            map.ornaments.options.logo.margins = CGPoint(x: 8, y: insets.bottom + 4)
            map.ornaments.options.attributionButton.margins = CGPoint(x: 8, y: insets.bottom + 4)
            map.ornaments.options.compass.margins = CGPoint(x: 8, y: insets.top + 8)
        }

        // MARK: style

        private func styleLoaded() {
            guard let map else { return }
            styleReady = true
            addedModels.removeAll()
            let m: MapboxMap = map.mapboxMap!
            /* Same Standard config as the web's applyBasemap() for the outing map. */
            for (k, v) in [("show3dObjects", true), ("showPointOfInterestLabels", false), ("showTransitLabels", false), ("showRoadLabels", false)] as [(String, Bool)] {
                try? m.setStyleImportConfigProperty(for: "basemap", config: k, value: v)
            }
            light = nil
            applyLight()
            if let r = rallyPin?.point {
                rallyPin?.annotation.remove()
                rallyPin = nil
                setRally(r)
            }
            /* Terrain like the web's setSaryTerrain (the web only skips it on Safari, for a WebKit bug). */
            if !m.sourceExists(withId: "mapbox-dem") {
                try? m.addSource(withId: "mapbox-dem", properties: ["type": "raster-dem", "url": "mapbox://mapbox.mapbox-terrain-dem-v1", "tileSize": 512, "maxzoom": 14])
            }
            try? m.setTerrain(properties: ["source": "mapbox-dem", "exaggeration": 1.15])
            ensureRoadProbe()
            for r in recs.values {
                r.layersReady = false
                r.model = false
            }
            sync(lastCars)
        }

        private func applyLight() {
            guard styleReady, let map else { return }
            let at = lastCars.first(where: \.isMe)?.position ?? lastCars.first?.position
            /* Night mode (forced or after sunset) is the night light; otherwise the sun decides. */
            let preset: SunLight.Preset = theme.night ? .night : (at.map { SunLight.preset(Date(), lat: $0.lat, lng: $0.lng) } ?? .day)
            guard preset != light else { return }
            light = preset
            try? map.mapboxMap.setStyleImportConfigProperty(for: "basemap", config: "lightPreset", value: preset.rawValue)
        }

        /// Invisible, but drawn, so Mapbox Streets' road tiles load where the camera is (as on the web).
        private func ensureRoadProbe() {
            guard let m = map?.mapboxMap else { return }
            if !m.sourceExists(withId: RoadSnap.source) {
                try? m.addSource(withId: RoadSnap.source, properties: ["type": "vector", "url": "mapbox://mapbox.mapbox-streets-v8"])
            }
            if !m.layerExists(withId: RoadSnap.probeLayer) {
                try? m.addLayer(with: [
                    "id": RoadSnap.probeLayer, "type": "line", "source": RoadSnap.source, "source-layer": "road", "minzoom": 13,
                    "filter": RoadSnap.drivableFilter, "paint": ["line-opacity": 0, "line-width": 1],
                ], layerPosition: nil)
            }
        }

        private func refreshRoads() {
            guard styleReady, let m = map?.mapboxMap else { return }
            roadQuery?.cancel()
            roadQuery = m.querySourceFeatures(for: RoadSnap.source, options: SourceQueryOptions(sourceLayerIds: ["road"], filter: RoadSnap.drivableFilter)) { [weak self] result in
                guard let self, case let .success(feats) = result else { return }
                var lines: [RoadSnap.RoadLine] = []
                for q in feats {
                    let f = q.queriedFeature.feature
                    let props = f.properties ?? [:]
                    func str(_ k: String) -> String {
                        if case let .string(s)?? = props[k] { return s }
                        return ""
                    }
                    /* A road cut at a tile edge comes back as two features with the same id. */
                    let key: String
                    switch f.identifier {
                    case let .string(s)?: key = "id:\(s)"
                    case let .number(n)?: key = "id:\(n)"
                    default: key = "\(str("class")):\(str("name").isEmpty ? str("ref") : str("name"))"
                    }
                    switch f.geometry {
                    case let .lineString(l)?: lines.append(.init(key: key, coords: l.coordinates.map { [$0.longitude, $0.latitude] }))
                    case let .multiLineString(ml)?: for l in ml.coordinates { lines.append(.init(key: key, coords: l.map { [$0.longitude, $0.latitude] })) }
                    default: break
                    }
                }
                self.roads = lines
                /* A car drawn before its street loaded gets matched now. */
                for r in self.recs.values where r.matcher.road == nil && !r.item.approximate {
                    r.matcher.reset()
                }
                self.sync(self.lastCars)
            }
        }

        // MARK: cars

        func sync(_ cars: [MapMember]) {
            lastCars = cars
            guard let map else { return }
            applyLight()
            let now = CACurrentMediaTime()
            let reduce = UIAccessibility.isReduceMotionEnabled
            var seen = Set<String>()
            for v in cars {
                seen.insert(v.id)
                let raw = v.position
                let existing = recs[v.id]
                /* Course for matching: the reported one, or real movement since the last anchor. */
                let course: Double? = v.heading ?? existing.flatMap { r in Vehicle.distanceMeters(r.anchor, raw) >= 12 ? Vehicle.bearing(r.anchor, raw) : nil }
                let rec = existing ?? Rec(v, at: raw)
                /* A confident fix in town is drawn on the street it drives along; an approximate one stays where measured. */
                var matched: RoadSnap.Match?
                if v.approximate {
                    rec.matcher.reset()
                } else {
                    matched = rec.matcher.match(raw, RoadSnap.nearby(roads, raw), course: course, maxM: RoadSnap.snapRadius(v.accuracyM))
                }
                let target = matched?.point ?? raw
                if existing == nil {
                    rec.shown = target
                    rec.from = target
                    rec.to = target
                    recs[v.id] = rec
                } else if target != rec.to {
                    let gap = v.atMs - rec.lastAt
                    rec.from = rec.shown
                    rec.to = target
                    rec.start = now
                    /* Only a confident, live fix glides; anything else is placed exactly where it was measured. */
                    rec.duration = v.approximate || v.presence != .live ? 0 : Motion.tweenMs(gapMs: gap, distanceM: Vehicle.distanceMeters(rec.shown, target), reducedMotion: reduce)
                    rec.lastAt = v.atMs
                    if rec.duration == 0 { rec.shown = target }
                }
                /* Direction: the reported course, else real movement ≥ 12 m; kept while parked. */
                if let h = v.heading {
                    rec.heading = h
                    rec.anchor = raw
                } else if Vehicle.distanceMeters(rec.anchor, raw) >= 12 {
                    rec.heading = Vehicle.bearing(rec.anchor, raw)
                    rec.anchor = raw
                }
                /* Moving along a matched road: the car points down the road. */
                if course != nil, let h = matched?.heading { rec.heading = h }
                let colorChanged = rec.item.color != v.color
                rec.item = v
                if colorChanged { rec.layersReady = false }
                drawCar(rec, on: map)
                drawChip(rec, on: map)
            }
            for (id, rec) in recs where !seen.contains(id) {
                remove(rec, on: map)
                recs[id] = nil
            }
            if recs.values.contains(where: { $0.duration > 0 }) { startLink() }
            keepGroupInView(newcomers: Set(cars.map(\.id)).subtracting(fittedIds))
            project()
        }

        func themeChanged() {
            light = nil
            applyLight()
            for r in recs.values { r.host = nil; r.annotation?.remove(); r.annotation = nil; r.box = nil }
            if let map { for r in recs.values { drawChip(r, on: map) } }
            if let p = rallyPin?.point {
                rallyPin?.annotation.remove()
                rallyPin = nil
                setRally(p)
            }
        }

        /// Report where every car (and the flag) is on screen, at most ~30 times a second.
        func project() {
            let now = CACurrentMediaTime()
            if now - lastProjectionAt < 1.0 / 30 {
                guard !projectionPending else { return }
                projectionPending = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 30) { [weak self] in
                    self?.projectionPending = false
                    self?.project()
                }
                return
            }
            lastProjectionAt = now
            guard let map, map.bounds.width > 0 else { return }
            let m: MapboxMap = map.mapboxMap!
            var pts: [String: CGPoint] = [:]
            for r in recs.values { pts[r.item.id] = m.point(for: r.shown.coordinate) }
            let rally = rallyPin.map { m.point(for: $0.point.position.coordinate) }
            onProjection(MapProjection(points: pts, rally: rally, bearing: m.cameraState.bearing, size: map.bounds.size))
        }

        private func drawCar(_ r: Rec, on map: MapView) {
            guard styleReady else { return }
            let m: MapboxMap = map.mapboxMap!
            let ids = Vehicle.ids(r.key)
            let wantModel = !r.item.approximate
            if !r.layersReady || r.model != wantModel {
                removeLayers(r, on: map)
                var src = GeoJSONSource(id: ids.source)
                src.data = .geometry(.point(Point(r.shown.coordinate)))
                try? m.addSource(src)
                let spot = r.item.isMe ? Vehicle.mySpotHex : r.item.color
                try? m.addLayer(with: [
                    "id": ids.spot, "type": "circle", "source": ids.source,
                    "paint": [
                        "circle-radius": r.item.approximate ? 9 : 6, "circle-color": "#" + Vehicle.hex(spot),
                        "circle-stroke-color": "#ffffff", "circle-stroke-width": 2.5,
                        "circle-pitch-alignment": "map", "circle-emissive-strength": 1,
                    ] as [String: Any],
                ], layerPosition: nil)
                if wantModel, ensureModel(r.item.color, on: m) {
                    try? m.addLayer(with: [
                        "id": ids.layer, "type": "model", "source": ids.source,
                        "layout": ["model-id": Vehicle.modelId(r.item.color)],
                        "paint": [
                            "model-type": "common-3d", "model-scale": Vehicle.scaleExpression,
                            "model-rotation": Vehicle.rotation(r.heading), "model-cast-shadows": true,
                            "model-receive-shadows": true, "model-emissive-strength": 0.6, "model-opacity": 1,
                        ] as [String: Any],
                    ], layerPosition: nil)
                    r.model = true
                } else {
                    r.model = false
                }
                r.layersReady = true
            }
            setPosition(r, on: m)
            if r.model {
                try? m.setLayerProperty(for: ids.layer, property: "model-opacity", value: Vehicle.opacity(r.item.presence))
            }
            try? m.setLayerProperty(for: ids.spot, property: "circle-opacity", value: Vehicle.opacity(r.item.presence))
        }

        private func setPosition(_ r: Rec, on m: MapboxMap) {
            let ids = Vehicle.ids(r.key)
            m.updateGeoJSONSource(withId: ids.source, geoJSON: .geometry(.point(Point(r.shown.coordinate))))
            if r.model {
                try? m.setLayerProperty(for: ids.layer, property: "model-rotation", value: Vehicle.rotation(r.heading))
            }
            r.annotation?.annotatedFeature = .geometry(Point(r.shown.coordinate))
        }

        private func ensureModel(_ color: UInt32, on m: MapboxMap) -> Bool {
            let id = Vehicle.modelId(color)
            if addedModels.contains(id) { return true }
            guard let url = SuvModel.fileURL(body: color) else { return false }
            do {
                try m.addStyleModel(modelId: id, modelUri: url.absoluteString)
                addedModels.insert(id)
                return true
            } catch {
                return false
            }
        }

        private func removeLayers(_ r: Rec, on map: MapView) {
            let m: MapboxMap = map.mapboxMap!
            let ids = Vehicle.ids(r.key)
            for l in [ids.layer, ids.spot] where m.layerExists(withId: l) { try? m.removeLayer(withId: l) }
            if m.sourceExists(withId: ids.source) { try? m.removeSource(withId: ids.source) }
        }

        private func remove(_ r: Rec, on map: MapView) {
            if styleReady { removeLayers(r, on: map) }
            r.annotation?.remove()
            r.annotation = nil
        }

        private func drawChip(_ r: Rec, on map: MapView) {
            let id = r.item.id
            let chip = MapChip(chip: r.item.chip, bubble: r.item.bubble, theme: theme) { [weak self] in self?.onCarTap(id) }
            if let host = r.host {
                if host.rootView != chip {
                    host.rootView = chip
                    r.box?.fit()
                    r.annotation?.setNeedsUpdateSize()
                }
            } else {
                let host = UIHostingController(rootView: chip)
                host.view.backgroundColor = .clear
                let box = ChipBox(host)
                let a = ViewAnnotation(coordinate: r.shown.coordinate, view: box)
                /* Bottom of the chip just over the car, so a note bubble grows upward, never over it. */
                a.variableAnchors = [ViewAnnotationAnchorConfig(anchor: .bottom, offsetY: 24)]
                /* Every car always shows: a friend is never hidden because two labels overlap. */
                a.allowOverlap = true
                a.priority = r.item.isMe ? 100 : (r.item.presence == .live ? 50 : 10)
                map.viewAnnotations.add(a)
                r.host = host
                r.box = box
                r.annotation = a
            }
        }


        private func car(at p: CGPoint) -> String? {
            guard let map else { return nil }
            let m: MapboxMap = map.mapboxMap!
            let state = m.cameraState
            let mpp = Projection.metersPerPoint(for: state.center.latitude, zoom: state.zoom)
            let cars = recs.values.map { r -> (id: String, x: Double, y: Double) in
                let pt = m.point(for: r.shown.coordinate)
                return (r.item.id, Double(pt.x), Double(pt.y))
            }
            return CarHit.nearest((Double(p.x), Double(p.y)), cars, radius: CarHit.radius(zoom: state.zoom, metersPerPoint: mpp))
        }

        // MARK: rally point

        func setRally(_ rally: MapRallyPoint?) {
            guard let map else { return }
            if rally == rallyPin?.point { return }
            rallyPin?.annotation.remove()
            rallyPin = nil
            guard let rally else { return }
            let host = UIHostingController(rootView: RallyPin(label: rally.label, theme: theme) { [weak self] in self?.onRallyTap() })
            host.view.backgroundColor = .clear
            let size = host.sizeThatFits(in: CGSize(width: 200, height: 120))
            host.view.frame = CGRect(origin: .zero, size: size)
            let a = ViewAnnotation(coordinate: rally.position.coordinate, view: host.view)
            a.variableAnchors = [ViewAnnotationAnchorConfig(anchor: .bottom)]
            a.allowOverlap = true
            a.priority = 120
            map.viewAnnotations.add(a)
            rallyPin = (rally, a, host)
            project()
        }

        // MARK: glide between fixes

        private func startLink() {
            guard link == nil else { return }
            let l = CADisplayLink(target: self, selector: #selector(step))
            l.add(to: .main, forMode: .common)
            link = l
        }

        @objc private func step() {
            guard let m = map?.mapboxMap else { return }
            let now = CACurrentMediaTime()
            var moving = false
            for r in recs.values where r.duration > 0 {
                let t = (now - r.start) * 1000 / r.duration
                if t >= 1 {
                    r.shown = r.to
                    r.duration = 0
                } else {
                    r.shown = Motion.lerp(r.from, r.to, t)
                    moving = true
                }
                if styleReady, r.layersReady { setPosition(r, on: m) } else { r.annotation?.annotatedFeature = .geometry(Point(r.shown.coordinate)) }
            }
            project()
            if !moving {
                link?.invalidate()
                link = nil
            }
        }

        // MARK: camera

        /// What our chrome leaves clear, plus room above for a name and a note over a car.
        private var framePadding: UIEdgeInsets {
            UIEdgeInsets(top: chrome.top + GroupFraming.noteRoom, left: 32, bottom: chrome.bottom + 24, right: 32)
        }

        private func points(only: String? = nil) -> [LngLat] {
            lastCars.filter { only == nil || $0.id == only || $0.isMe }.map(\.position)
        }

        func fitGroup() {
            fittedIds = Set(lastCars.map(\.id))
            frame(points())
        }

        /// You and one friend, together on screen.
        func fitWith(_ id: String) {
            keepGroup = false
            frame(points(only: id))
        }

        func centerOnMe() {
            guard let me = lastCars.first(where: \.isMe) else { return }
            keepGroup = false
            center(me.position, zoom: max(map?.mapboxMap.cameraState.zoom ?? 15, 15))
        }

        /// Centre a point inside the area our chrome leaves clear.
        func center(_ p: LngLat, zoom: Double? = nil) {
            guard let map else { return }
            keepGroup = false
            let pad = UIEdgeInsets(top: chrome.top, left: 0, bottom: chrome.bottom, right: 0)
            let cam = CameraOptions(center: p.coordinate, padding: pad, zoom: zoom ?? max(map.mapboxMap.cameraState.zoom, 14))
            map.camera.ease(to: cam, duration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.8)
        }

        private func frame(_ pts: [LngLat]) {
            guard let map, let b = GroupFraming.bounds(pts), map.bounds.height > 0 else { return }
            let coords = [CLLocationCoordinate2D(latitude: b.south, longitude: b.west), CLLocationCoordinate2D(latitude: b.north, longitude: b.east)]
            let state = map.mapboxMap.cameraState
            guard var cam = try? map.mapboxMap.camera(for: coords, camera: CameraOptions(padding: .zero, bearing: state.bearing, pitch: state.pitch),
                                                       coordinatesPadding: framePadding, maxZoom: GroupFraming.maxZoom, offset: nil) else { return }
            cam.padding = nil
            fitting = true
            map.camera.ease(to: cam, duration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.9) { [weak self] _ in self?.fitting = false }
        }

        private func keepGroupInView(newcomers: Set<String>) {
            guard let map, !lastCars.isEmpty, map.bounds.height > 0 else { return }
            /* Frame the group when positions first arrive, and again each time someone new appears. */
            if !newcomers.isEmpty {
                keepGroup = true
                fitGroup()
                return
            }
            guard keepGroup, !fitting, lastCars.count >= 2 else { return }
            /* While keeping the group: if anyone (you included) drifts out of the clear area, reframe. */
            let p = UIEdgeInsets(top: chrome.top + GroupFraming.noteRoom * 0.75, left: 8, bottom: chrome.bottom, right: 8)
            let rect = map.bounds.inset(by: p)
            guard rect.width > 0, rect.height > 0 else { return }
            let bb = map.mapboxMap.coordinateBounds(for: rect)
            let view = GroupFraming.Bounds(west: bb.southwest.longitude, south: bb.southwest.latitude, east: bb.northeast.longitude, north: bb.northeast.latitude)
            if GroupFraming.anyOffScreen(points(), view: view, insetX: 0, insetY: 0) { fitGroup() }
        }

        /// A finger on the map means "let me look": stop reframing until asked.
        func gestureManager(_ gestureManager: GestureManager, didBegin gestureType: GestureType) {
            /* A tap (on a car, a name, or empty map) is not "let me look"; drag, pinch, rotate and tilt are. */
            if gestureType != .singleTap {
                keepGroup = false
                onUserGesture()
            }
        }
        func gestureManager(_ gestureManager: GestureManager, didEnd gestureType: GestureType, willAnimate: Bool) {}
        func gestureManager(_ gestureManager: GestureManager, didEndAnimatingFor gestureType: GestureType) {}
    }
}

/// Holds a chip at its own ideal size. Mapbox measures annotation views with
/// `systemLayoutSizeFitting`, which a bare hosting view answers with the space it is
/// offered (or squeezes to nothing); this box answers with what SwiftUI wants.
final class ChipBox: UIView {
    private let host: UIHostingController<MapChip>

    init(_ host: UIHostingController<MapChip>) {
        self.host = host
        super.init(frame: .zero)
        backgroundColor = .clear
        host.view.backgroundColor = .clear
        addSubview(host.view)
        fit()
    }

    required init?(coder: NSCoder) { fatalError() }

    private var ideal: CGSize { host.sizeThatFits(in: CGSize(width: 240, height: 600)) }

    func fit() {
        let s = ideal
        frame.size = s
        host.view.frame = CGRect(origin: .zero, size: s)
    }

    override func systemLayoutSizeFitting(_ targetSize: CGSize) -> CGSize { ideal }
    override func sizeThatFits(_ size: CGSize) -> CGSize { ideal }
    override var intrinsicContentSize: CGSize { ideal }

    override func layoutSubviews() {
        super.layoutSubviews()
        host.view.frame = bounds
    }
}

extension LngLat {
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lng) }
}

/// The chip over a car, from the design system: note bubble (if any) over the
/// name chip. Drawn inside a Mapbox view annotation so it tracks the car
/// natively (no SwiftUI frame lag), and themed like the rest of the chrome.
struct MapChip: View, Equatable {
    let chip: NameChipUI?
    let bubble: NoteBubbleUI?
    let theme: SaryTheme
    var onTap: () -> Void

    static func == (a: MapChip, b: MapChip) -> Bool { a.chip == b.chip && a.bubble == b.bubble && a.theme == b.theme }

    var body: some View {
        VStack(spacing: 2) {
            if let bubble { SaryNoteBubble(bubble: bubble) }
            if let chip { SaryNameChip(chip: chip, tapped: onTap) }
        }
        .padding(3)
        .saryTheme(theme)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("car.chip")
    }
}

/// The rally point: the design system's flag with its label.
struct RallyPin: View {
    let label: String
    let theme: SaryTheme
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            SaryRallyFlag(marker: .init(label: label.isEmpty ? "نقطة التجمع" : label))
        }
        .buttonStyle(.plain)
        .saryTheme(theme)
        .accessibilityLabel(label.isEmpty ? "نقطة التجمع" : label)
        .accessibilityIdentifier("map.rally")
    }
}

/// Where things are on screen right now (physical points, top-left origin).
struct MapProjection: Equatable {
    var points: [String: CGPoint]
    var rally: CGPoint?
    var bearing: Double
    var size: CGSize
}

/// Mapbox Standard Satellite with place names in Arabic. Standard reads
/// `name_en`; we fetch the same style once, point its labels at `name_ar`
/// (falling back to the local `name`), and load it as the "basemap" import so
/// its config (light preset, 3D objects) works as before.
enum ArabicBasemap {
    private(set) static var cachedJSON: String?
    private static var loading = false
    private static var waiters: [(String?) -> Void] = []

    static func transform(_ style: String) -> String {
        style.replacingOccurrences(of: "[\"get\", \"name_en\"]", with: "[\"coalesce\", [\"get\", \"name_ar\"], [\"get\", \"name\"]]")
            .replacingOccurrences(of: "[\"get\",\"name_en\"]", with: "[\"coalesce\",[\"get\",\"name_ar\"],[\"get\",\"name\"]]")
    }

    static func wrap(_ style: String) -> String {
        "{\"version\":8,\"imports\":[{\"id\":\"basemap\",\"url\":\"\",\"data\":\(style)}],\"sources\":{},\"layers\":[]}"
    }

    static func load(_ done: @escaping (String?) -> Void) {
        /* Already fetched: the map was created with it. */
        if cachedJSON != nil { return }
        waiters.append(done)
        guard !loading else { return }
        loading = true
        guard let token = Bundle.main.object(forInfoDictionaryKey: "MBXAccessToken") as? String, !token.isEmpty,
              let url = URL(string: "https://api.mapbox.com/styles/v1/mapbox/standard-satellite?access_token=\(token)") else {
            return finish(nil)
        }
        URLSession.shared.dataTask(with: url) { data, resp, _ in
            var out: String?
            if let data, (resp as? HTTPURLResponse)?.statusCode == 200, let s = String(data: data, encoding: .utf8), s.contains("name_en") {
                out = wrap(transform(s))
            }
            DispatchQueue.main.async { finish(out) }
        }.resume()
    }

    private static func finish(_ json: String?) {
        loading = false
        if let json { cachedJSON = json }
        let w = waiters
        waiters = []
        w.forEach { $0(json) }
    }
}

private struct NoteTail: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}
