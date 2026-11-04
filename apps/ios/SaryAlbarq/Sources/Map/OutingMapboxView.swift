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
    /// m/s when known (road snapping widens its search for a car that is clearly driving).
    var speedMps: Double? = nil
    /// Time of this fix, ms (for the glide length between fixes).
    var atMs: Double
    var note: String?
    var isMe: Bool
    /// Design-system name chip; nil hides the name (names «عند اللمس», or drive mode for others).
    var chip: NameChipUI? = nil
    /// Note bubble over the car; nil in drive mode or with no live note.
    var bubble: NoteBubbleUI? = nil
    /// This position came phone to phone, not from the server.
    var viaNearby = false

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

/// «مساري» and the friends' recent trails, as plain data for the map.
struct MapTrails: Equatable {
    struct Line: Equatable {
        var id: String
        var color: UInt32
        var opacity: Double = 1
        /// Recorded runs.
        var solid: [[LngLat]]
        /// Unrecorded stretches: straight, dashed, never a path we pretend to know.
        var gaps: [[LngLat]]
    }

    var mine: Line?
    /// «نقطة البداية»: the first point of my trail (where I entered).
    var start: LngLat?
    var friends: [Line] = []
    /// «طريق العودة» is on: my trail is drawn wider, with a glow.
    var highlight = false
    /// Where to say «لم يُسجَّل هذا الجزء» (the longest gaps only).
    var gapLabels: [LngLat] = []
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
        /// Frame these points (my trail and me, for «طريق العودة»).
        case fit([LngLat])
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
    var trails = MapTrails()
    var camera: MapCameraRequest? = nil
    /// Screen area covered by the host's chrome: top = bottom edge of the top bar, bottom = height of the bottom panel.
    var chrome: UIEdgeInsets = .zero
    /// The resolved design-system theme (chips, rally flag, night light).
    var theme: SaryTheme = .default
    /// While true, a tap on empty map reports its coordinate («حدد نقطة تجمع»).
    var picking = false
    /// «موقعي» is on: the camera follows my car until the map is moved by hand.
    var following = false
    var onMemberTap: (String) -> Void = { _ in }
    var onRallyTap: () -> Void = {}
    var onMapTap: (LngLat) -> Void = { _ in }
    /// Screen points of every car and the rally flag, after each camera move or glide step.
    var onProjection: (MapProjection) -> Void = { _ in }
    /// The person moved the map by hand (keep-group is off until «المجموعة»).
    var onUserGesture: () -> Void = {}
    /// Shared waypoints (pins join the chip declutter, see `WaypointLayout`).
    var waypoints: [MapWaypoint] = []
    var onWaypointTap: (String) -> Void = { _ in }
    /// «تخطيط الطلعة»: planned route (dashed), destination and the long-pressed point.
    var plan = MapPlan()
    /// The only long press on the map: the coordinate and its screen point (the point card,
    /// which offers «أضف نقطة», «الوجهة», «نقطة التجمع»…); not while picking a rally point.
    var onLongPress: (LngLat, CGPoint) -> Void = { _, _ in }
    /// Watercourses (wadi / stream / river…) in the loaded Streets tiles, after the camera settles (weather: flood hint).
    var onWaterways: ([WaterwayLine]) -> Void = { _ in }
    /// «الملاحة»: routes, the off-road remainder, the target and the guidance camera (see `NavMapDrawer`).
    var nav = MapNavDrawing()
    /// An alternative's time label was tapped.
    var onSelectRoute: (String) -> Void = { _ in }

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
        c.waypointPins.onTap = onWaypointTap
        c.onLongPress = onLongPress
        c.onWaterways = onWaterways
        c.picking = picking
        c.following = following
        c.navDrawer.onSelectRoute = onSelectRoute
        if c.theme != theme {
            c.theme = theme
            c.themeChanged()
        }
        c.setChrome(chrome)
        c.sync(members)
        c.setRally(rally)
        c.setWaypoints(waypoints)
        c.setTrails(trails)
        c.setPlan(plan)
        c.setNav(nav)
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
            case let .fit(pts):
                c.fit(pts)
            }
        }
    }

    static func dismantleUIView(_ map: MapView, coordinator: Coordinator) {
        coordinator.detach()
    }

    // MARK: -

    final class Coordinator: NSObject, GestureManagerDelegate {
        private(set) weak var map: MapView?
        private var cancelables = Set<AnyCancelable>()
        private(set) var styleReady = false
        let planDrawing = LivePlanDrawing()
        var onLongPress: (LngLat, CGPoint) -> Void = { _, _ in }
        private var addedModels = Set<String>()
        private var recs: [String: Rec] = [:]
        private var lastCars: [MapMember] = []
        private var link: CADisplayLink?
        private var chrome: UIEdgeInsets = .zero
        private var roads: [RoadSnap.RoadLine] = []
        private var lastRoadRefresh: CFTimeInterval = 0
        private var roadQuery: Cancelable?
        private var tapInteraction: Cancelable?
        let waypointPins = WaypointPins()
        private var lastWaypoints: [MapWaypoint] = []
        private var light: SunLight.Preset?
        private var fitting = false
        private var fittedIds = Set<String>()
        var onCarTap: (String) -> Void = { _ in }
        var onRallyTap: () -> Void = {}
        var onMapTap: (LngLat) -> Void = { _ in }
        var onProjection: (MapProjection) -> Void = { _ in }
        var onUserGesture: () -> Void = {}
        var onWaterways: ([WaterwayLine]) -> Void = { _ in }
        private var waterQuery: Cancelable?
        let navDrawer = NavMapDrawer()
        var picking = false
        var following = false
        private var lastFollowAt: CFTimeInterval = 0
        var theme: SaryTheme = .default
        var lastCamera = -1
        private var rallyPin: (point: MapRallyPoint, annotation: ViewAnnotation, host: UIHostingController<RallyPin>)?
        private var trails = MapTrails()
        private var trailLayerKey: String?
        private var startPin: (point: LngLat, annotation: ViewAnnotation, host: UIHostingController<TrailStartPin>)?
        /// «نقطة البداية» drops its label (icon only) while a car's chip would sit on it.
        private var startCompact = false
        private var gapPins: [(point: LngLat, annotation: ViewAnnotation, host: UIHostingController<TrailGapLabel>)] = []
        private var lastProjectionAt: CFTimeInterval = 0
        /* Note bubbles only once zoomed in: at city scale they would cover each other's names. */
        private var bubblesOn = true
        static let bubbleMinZoom = 13.5
        private var projectionPending = false
        private let overlay = ChipOverlayView()
        private var groupBoxes: [String: HostBox<MapGroupChip>] = [:]
        /// Members the person spread out (their group tapped while parked together).
        private var expandedGroups = Set<String>()
        private var lastLayout: ChipLayout.Result?
        private var ornamentSpot: String?
        private var ornamentCheckedAt: CFTimeInterval = 0
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
            /// Name chip and note bubble, drawn in the declutter overlay (see `ChipLayout`).
            var chipBox: HostBox<MapChip>?
            var noteBox: HostBox<MapNote>?

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
            map.mapboxMap.onMapIdle.observe { [weak self] _ in
                self?.refreshRoads()
                self?.refreshWaterways()
            }.store(in: &cancelables)
            map.mapboxMap.onCameraChanged.observe { [weak self] _ in
                self?.layoutChips()
                self?.project()
            }.store(in: &cancelables)
            /* Chips live in our own overlay (over the map, under Mapbox's ornaments) so the
             * declutter layout can move, stack and fold them in the same frame as the camera. */
            overlay.frame = map.bounds
            overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            map.insertSubview(overlay, at: min(1, map.subviews.count))
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
            waypointPins.onClusterTap = { [weak self] pts in
                guard let self else { return }
                self.keepGroup = false
                self.onUserGesture()
                self.frame(pts)
            }
            /* The ONE long-press handler: the point card («تخطيط الطلعة»), whose «أضف نقطة»
               opens the shared-waypoint composer. */
            installLongPress(map)
            navDrawer.attach(map)
        }

        func setWaypoints(_ list: [MapWaypoint]) {
            guard list != lastWaypoints || waypointTheme != theme else { return }
            lastWaypoints = list
            waypointTheme = theme
            waypointPins.set(list, theme: theme, in: overlay)
            layoutChips()
        }
        private var waypointTheme: SaryTheme?

        /// Navigation drawing + camera; while guidance owns the camera, group framing and «موقعي» stand aside.
        func setNav(_ d: MapNavDrawing) {
            navDrawer.theme = theme
            if d.camera != nil { keepGroup = false }
            navTick(d)
        }

        private func navTick(_ d: MapNavDrawing? = nil) {
            let me = lastCars.first(where: \.isMe)
            let heading = me.flatMap { recs[$0.id]?.heading }
            navDrawer.update(d ?? navLast, chrome: chrome, me: me.map { recs[$0.id]?.shown ?? $0.position }, heading: heading)
            if let d { navLast = d }
        }
        private var navLast = MapNavDrawing()

        func detach() {
            planDrawing.longPress?.cancel()
            link?.invalidate()
            link = nil
            roadQuery?.cancel()
            waterQuery?.cancel()
            tapInteraction?.cancel()
            cancelables.removeAll()
        }

        func setChrome(_ insets: UIEdgeInsets) {
            guard insets != chrome, let map else { return }
            let moved = abs(insets.bottom - chrome.bottom) > 40 || abs(insets.top - chrome.top) > 40
            chrome = insets
            /* The sheet or the alert lane changed size: keep everyone clear of it. */
            if moved, keepGroup, !lastCars.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                    guard let self, self.keepGroup else { return }
                    self.fitGroup()
                }
            }
            map.ornaments.options.compass.margins = CGPoint(x: 8, y: insets.top + 8)
            ornamentSpot = nil
            placeOrnaments(force: true)
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
            trailLayerKey = nil
            drawTrails()
            drawPlan(force: true)
            navDrawer.styleLoaded()
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
                    "id": RoadSnap.probeLayer, "type": "line", "source": RoadSnap.source, "source-layer": "road", "minzoom": 12,
                    "filter": RoadSnap.drivableFilter, "paint": ["line-opacity": 0, "line-width": 1],
                ], layerPosition: nil)
            }
            /* Same source: an invisible waterway layer so watercourse tiles load too (weather's wadi hint). */
            if !m.layerExists(withId: Self.waterProbeLayer) {
                try? m.addLayer(with: [
                    "id": Self.waterProbeLayer, "type": "line", "source": RoadSnap.source, "source-layer": "waterway", "minzoom": 9,
                    "filter": WadiProximity.filter, "paint": ["line-opacity": 0, "line-width": 1],
                ], layerPosition: nil)
            }
        }

        static let waterProbeLayer = "sary-waterway-probe"

        /// Watercourses in the loaded tiles (roughly what is on screen), for the wadi flood hint.
        private func refreshWaterways() {
            guard styleReady, let m = map?.mapboxMap else { return }
            waterQuery?.cancel()
            waterQuery = m.querySourceFeatures(for: RoadSnap.source, options: SourceQueryOptions(sourceLayerIds: ["waterway"], filter: WadiProximity.filter)) { [weak self] result in
                guard let self, case let .success(feats) = result else { return }
                var lines: [WaterwayLine] = []
                for q in feats {
                    let f = q.queriedFeature.feature
                    let props = f.properties ?? [:]
                    func str(_ k: String) -> String? {
                        if case let .string(s)?? = props[k] { return s }
                        return nil
                    }
                    let cls = str("class") ?? str("type") ?? ""
                    guard WadiProximity.isWatercourse(cls) || str("type") == "wadi" else { continue }
                    let name = str("name_ar") ?? str("name")
                    switch f.geometry {
                    case let .lineString(l)?: lines.append(.init(cls: cls, name: name, coords: l.coordinates.map { Geo.LatLng(lat: $0.latitude, lng: $0.longitude) }))
                    case let .multiLineString(ml)?:
                        for l in ml.coordinates { lines.append(.init(cls: cls, name: name, coords: l.map { Geo.LatLng(lat: $0.latitude, lng: $0.longitude) })) }
                    default: break
                    }
                }
                DispatchQueue.main.async { self.onWaterways(lines) }
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
                let changed = lines.count != self.roads.count || lines.first?.coords != self.roads.first?.coords
                self.roads = lines
                guard changed else { return }
                /* A car drawn before its street loaded gets matched now. */
                for r in self.recs.values where r.matcher.road == nil && !r.matcher.offRoad {
                    r.matcher.reset()
                }
                self.sync(self.lastCars)
            }
        }

        // MARK: cars

        func sync(_ cars: [MapMember]) {
            lastCars = cars
            guard let map else { return }
            /* While following a moving car the map is never idle: refresh the streets every few seconds too. */
            let t = CACurrentMediaTime()
            if t - lastRoadRefresh > 3 { lastRoadRefresh = t; refreshRoads() }
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
                /* In town the car is on the street: also a 60–100 m city-canyon fix while clearly driving
                 * (build 4 left those, and every «تقريبي» one, on the roofs). Parked/approximate: where measured. */
                var matched: RoadSnap.Match?
                let driving = (v.speedMps ?? 0) >= RoadSnap.drivingMps && course != nil
                if v.approximate && !driving {
                    rec.matcher.reset()
                } else {
                    matched = rec.matcher.match(raw, RoadSnap.nearby(roads, raw), course: course, speed: v.speedMps, accuracy: v.accuracyM, atMs: v.atMs)
                    if matched?.key == nil { matched = nil }
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
            if navDrawer.ownsCamera { navTick() } else { keepGroupInView(newcomers: Set(cars.map(\.id)).subtracting(fittedIds)) }
            followMe()
            layoutChips()
            project()
        }

        /// «موقعي»: keep my car centred (gently, at most once a second).
        private func followMe() {
            guard following, !navDrawer.ownsCamera, let map, let me = lastCars.first(where: \.isMe) else { return }
            keepGroup = false
            let now = CACurrentMediaTime()
            guard now - lastFollowAt > 1 else { return }
            lastFollowAt = now
            let pad = UIEdgeInsets(top: chrome.top, left: 0, bottom: chrome.bottom, right: 0)
            map.camera.ease(to: CameraOptions(center: me.position.coordinate, padding: pad), duration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.9)
        }

        func themeChanged() {
            light = nil
            applyLight()
            drawTrails()
            if let p = startPin?.point {
                startPin?.annotation.remove()
                startPin = nil
                placeStart(p)
            }
            drawPlan(force: true)
            for r in recs.values { remove(chipsOf: r) }
            for g in groupBoxes.values { g.removeFromSuperview() }
            groupBoxes = [:]
            if let map { for r in recs.values { drawChip(r, on: map) } }
            layoutChips()
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
            let cam = m.cameraState
            let wantBubbles = cam.zoom >= Self.bubbleMinZoom
            if wantBubbles != bubblesOn {
                bubblesOn = wantBubbles
                for r in recs.values { drawChip(r, on: map) }
                layoutChips()
            }
            let anchor = m.point(for: cam.center)
            /* Mapbox answers (-1, -1) for anything off the viewport; an off-screen
             * friend still needs a direction, so project those ourselves (Web Mercator, 512-pt tiles). */
            func screen(_ c: CLLocationCoordinate2D) -> CGPoint {
                let p = m.point(for: c)
                if p.x >= 0 && p.y >= 0 { return p }
                return ScreenProjection.point(c, center: cam.center, centerPoint: anchor, zoom: cam.zoom, bearing: cam.bearing)
            }
            for r in recs.values { pts[r.item.id] = screen(r.shown.coordinate) }
            let rally = rallyPin.map { screen($0.point.position.coordinate) }
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
            r.chipBox?.removeFromSuperview()
            r.noteBox?.removeFromSuperview()
            r.chipBox = nil
            r.noteBox = nil
        }

        private func remove(chipsOf r: Rec) {
            r.chipBox?.removeFromSuperview()
            r.noteBox?.removeFromSuperview()
            r.chipBox = nil
            r.noteBox = nil
        }

        /// The chip's and bubble's content; where they go is `layoutChips()`.
        private func drawChip(_ r: Rec, on map: MapView) {
            let id = r.item.id
            if let chip = r.item.chip {
                let view = MapChip(chip: chip, noteWaiting: false, theme: theme) { [weak self] in self?.onCarTap(id) }
                if let box = r.chipBox { box.update(view) } else {
                    let box = HostBox(view)
                    overlay.addSubview(box)
                    r.chipBox = box
                }
            } else {
                r.chipBox?.removeFromSuperview()
                r.chipBox = nil
            }
            if bubblesOn, let bubble = r.item.bubble {
                let view = MapNote(bubble: bubble, theme: theme) { [weak self] in self?.onCarTap(id) }
                if let box = r.noteBox { box.update(view) } else {
                    let box = HostBox(view)
                    overlay.addSubview(box)
                    r.noteBox = box
                }
            } else {
                r.noteBox?.removeFromSuperview()
                r.noteBox = nil
            }
        }

        /// Declutter: stack close chips with leader lines, fold crowds into a group chip,
        /// collapse notes that have no room. Runs with every camera frame and glide step.
        func layoutChips() {
            guard let map, map.bounds.width > 0 else { return }
            let m: MapboxMap = map.mapboxMap!
            let cam = m.cameraState
            let anchorPt = m.point(for: cam.center)
            func screen(_ c: CLLocationCoordinate2D) -> CGPoint {
                let p = m.point(for: c)
                if p.x >= 0 && p.y >= 0 { return p }
                return ScreenProjection.point(c, center: cam.center, centerPoint: anchorPt, zoom: cam.zoom, bearing: cam.bearing)
            }
            var items: [ChipLayout.Item] = []
            for r in recs.values {
                let hasNote = r.item.bubble != nil
                guard r.chipBox != nil || r.noteBox != nil else { continue }
                /* The waiting-note dot is part of the chip's size, so measure the chip as it would be drawn with it. */
                let chipSize = r.chipBox?.measure(noteWaiting: hasNote) ?? .zero
                let prio = r.item.presence == .live ? 2 : (r.item.presence == .recent ? 1 : 0)
                items.append(ChipLayout.Item(id: r.item.id, anchor: screen(r.shown.coordinate), chip: chipSize,
                                             note: r.noteBox?.ideal, isMe: r.item.isMe, priority: prio))
            }
            var opts = ChipLayout.Options(bounds: map.bounds.inset(by: UIEdgeInsets(top: chrome.top, left: 0, bottom: 0, right: 0)))
            opts.expanded = expandedGroups
            if theme.drive { opts.maxStack = 2 }
            let result = ChipLayout.solve(items, opts)
            lastLayout = result
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let leaders = CGMutablePath()
            for p in result.chips {
                guard let r = recs[p.id] else { continue }
                let hasNote = r.item.bubble != nil
                if let box = r.chipBox {
                    box.setNoteWaiting(hasNote && (p.noteCollapsed || r.noteBox == nil))
                    box.isHidden = false
                    box.frame = p.frame
                    overlay.bringSubviewToFront(box)
                }
                if let nb = r.noteBox {
                    if let nf = p.noteFrame {
                        nb.isHidden = false
                        nb.frame = nf
                        overlay.bringSubviewToFront(nb)
                    } else {
                        nb.isHidden = true
                    }
                }
                if p.leader {
                    let attach = CGPoint(x: p.frame.midX, y: p.frame.maxY <= p.anchor.y ? p.frame.maxY : p.frame.minY)
                    leaders.move(to: p.anchor)
                    leaders.addLine(to: attach)
                }
            }
            let grouped = Set(result.groups.flatMap(\.ids))
            for id in grouped {
                recs[id]?.chipBox?.isHidden = true
                recs[id]?.noteBox?.isHidden = true
            }
            var liveGroups = Set<String>()
            for g in result.groups {
                liveGroups.insert(g.key)
                let view = MapGroupChip(count: g.ids.count, colors: g.ids.compactMap { recs[$0]?.item.color }, theme: theme) { [weak self] in self?.openGroup(g.key) }
                let box: HostBox<MapGroupChip>
                if let b = groupBoxes[g.key] { b.update(view); box = b } else {
                    box = HostBox(view)
                    overlay.addSubview(box)
                    groupBoxes[g.key] = box
                }
                box.frame = CGRect(x: g.frame.midX - box.ideal.width / 2, y: g.frame.maxY - box.ideal.height, width: box.ideal.width, height: box.ideal.height)
                for id in g.ids {
                    if let r = recs[id] {
                        leaders.move(to: screen(r.shown.coordinate))
                        leaders.addLine(to: CGPoint(x: box.frame.midX, y: box.frame.maxY))
                    }
                }
            }
            for (k, b) in groupBoxes where !liveGroups.contains(k) {
                b.removeFromSuperview()
                groupBoxes[k] = nil
            }
            /* «أنت» on top of everything. */
            if let me = recs.values.first(where: \.item.isMe) {
                if let b = me.noteBox, !b.isHidden { overlay.bringSubviewToFront(b) }
                if let b = me.chipBox { overlay.bringSubviewToFront(b) }
            }
            overlay.leaders.path = leaders
            overlay.leaders.strokeColor = UIColor(theme.palette.textPrimary.opacity(0.75)).cgColor
            overlay.leaderHalo.path = leaders
            overlay.leaderHalo.strokeColor = UIColor(theme.palette.chromeOpaque.opacity(0.85)).cgColor
            /* Waypoint pins fit around what the cars' chips took. */
            var taken = result.chips.map(\.frame) + result.chips.compactMap(\.noteFrame) + result.groups.map(\.frame)
            /* «نقطة البداية»: its label folds away (icon only) where a chip would cover it or it would
             * cover a chip; the pin itself joins the obstacles so waypoint labels keep off it. */
            if let sp = startPin {
                let r = StartPinLayout.rects(anchor: screen(sp.point.coordinate))
                let crowded = StartPinLayout.crowded(label: r.label, chips: taken, wasCompact: startCompact)
                if crowded != startCompact {
                    startCompact = crowded
                    placeStart(sp.point, force: true)
                }
                /* A car's chip right on the pin itself: the chip wins (the trail line still starts there). */
                let covered = taken.contains { $0.intersects(r.icon.insetBy(dx: 4, dy: 4)) }
                startPin?.host.view.isHidden = covered
                if !covered { taken.append(crowded ? r.icon : r.icon.union(r.label)) }
            }
            waypointPins.layout(screen: screen, bounds: opts.bounds, obstacles: taken)
            CATransaction.commit()
            placeOrnaments(force: false)
        }

        /// A group chip was tapped: list its cars in a column, and zoom in when that separates them.
        private func openGroup(_ key: String) {
            guard let map, let g = lastLayout?.groups.first(where: { $0.key == key }) else { return }
            let pts = g.ids.compactMap { recs[$0]?.shown }
            guard !pts.isEmpty else { return }
            let zoom = map.mapboxMap.cameraState.zoom
            keepGroup = false
            onUserGesture()
            /* Always spread them into a column (tied to their cars by lines), and zoom in
             * toward them: far apart, the zoom separates them; parked together, it moves
             * the other cars away so the column is not folded again with newcomers (the
             * plan's route and destination can keep the map zoomed out). */
            expandedGroups.formUnion(g.ids)
            layoutChips()
            if zoom < GroupFraming.maxZoom - 0.5 { frame(pts) }
        }

        /// Mapbox's logo and attribution: kept together in a free spot of the map (never
        /// hidden — Mapbox's terms), away from the rally label, chips and our controls.
        private func placeOrnaments(force: Bool) {
            guard let map, map.bounds.width > 0 else { return }
            let now = CACurrentMediaTime()
            if !force && now - ornamentCheckedAt < 0.5 { return }
            ornamentCheckedAt = now
            let logo = map.ornaments.logoView.intrinsicContentSize
            let info = map.ornaments.attributionButton.intrinsicContentSize
            let lw = max(logo.width, 80), lh = max(logo.height, 20)
            let iw = max(info.width, 22)
            let w = lw + 4 + iw, h = max(lh, info.height, 22)
            let bounds = map.bounds
            let clearBottom = bounds.maxY - chrome.bottom - 6
            let left = max(8, chrome.left + 4), right = bounds.maxX - max(8, chrome.right + 4)
            let cands: [OrnamentSpot.Candidate] = [
                .init(rect: CGRect(x: bounds.midX - w / 2, y: clearBottom - h, width: w, height: h), name: "bottom-center"),
                .init(rect: CGRect(x: left, y: clearBottom - h, width: w, height: h), name: "bottom-left"),
                .init(rect: CGRect(x: right - w, y: clearBottom - h, width: w, height: h), name: "bottom-right"),
                .init(rect: CGRect(x: left, y: chrome.top + 6, width: w, height: h), name: "top-left"),
                .init(rect: CGRect(x: right - w, y: chrome.top + 6, width: w, height: h), name: "top-right"),
            ]
            var avoid: [CGRect] = []
            if let rp = rallyPin {
                let p = map.mapboxMap.point(for: rp.point.position.coordinate)
                let s = rp.host.view.frame.size
                avoid.append(CGRect(x: p.x - s.width / 2, y: p.y - s.height, width: s.width, height: s.height).insetBy(dx: -6, dy: -6))
            }
            if let l = lastLayout {
                avoid += l.chips.map(\.frame) + l.chips.compactMap(\.noteFrame) + l.groups.map(\.frame)
            }
            avoid += waypointPins.frames
            /* Keep the current spot while it is still free: no hopping around as cars move. */
            if !force, let cur = cands.first(where: { $0.name == ornamentSpot }), !avoid.contains(where: { $0.intersects(cur.rect) }) { return }
            guard let spot = OrnamentSpot.choose(cands, avoid: avoid), spot.name != ornamentSpot || force else { return }
            ornamentSpot = spot.name
            let safe = map.safeAreaInsets
            let y = bounds.maxY - safe.bottom - spot.rect.maxY
            if spot.name.hasPrefix("top") {
                map.ornaments.options.logo.position = .topLeft
                map.ornaments.options.attributionButton.position = .topLeft
                map.ornaments.options.logo.margins = CGPoint(x: spot.rect.minX - safe.left, y: spot.rect.minY - safe.top)
                map.ornaments.options.attributionButton.margins = CGPoint(x: spot.rect.minX + lw + 4 - safe.left, y: spot.rect.minY - safe.top)
            } else {
                map.ornaments.options.logo.position = .bottomLeft
                map.ornaments.options.attributionButton.position = .bottomLeft
                map.ornaments.options.logo.margins = CGPoint(x: spot.rect.minX - safe.left, y: y)
                map.ornaments.options.attributionButton.margins = CGPoint(x: spot.rect.minX + lw + 4 - safe.left, y: y)
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

        // MARK: «مساري» (on-device trail) and friends' recent trails

        static let trailMine = "sary-trail-mine"
        static let trailFriends = "sary-trail-friends"
        private static var trailLayerIds: [String] {
            ["\(trailFriends)-casing", "\(trailFriends)-line", "\(trailFriends)-gap",
             "\(trailMine)-glow", "\(trailMine)-casing", "\(trailMine)-line", "\(trailMine)-gap-casing", "\(trailMine)-gap"]
        }

        func setTrails(_ t: MapTrails) {
            guard t != trails else { return }
            trails = t
            drawTrails()
        }

        /// Contrasting casing: dark around a light line, white around a dark one (reads on sand and at night).
        static func casing(for rgb: UInt32) -> String {
            SaryContrast.luminance(rgb) > 0.32 ? "#16110b" : "#ffffff"
        }

        private func drawTrails() {
            guard styleReady, let map else { return }
            let m: MapboxMap = map.mapboxMap!
            let myColor = trails.mine?.color ?? 0xE8862E
            let key = "\(theme.drive)|\(theme.night)|\(trails.highlight)|\(myColor)"
            if key != trailLayerKey || !m.layerExists(withId: "\(Self.trailMine)-line") {
                addTrailLayers(m, myColor: myColor)
                trailLayerKey = key
            }
            m.updateGeoJSONSource(withId: Self.trailMine, geoJSON: .featureCollection(Self.collection(trails.mine.map { [$0] } ?? [])))
            m.updateGeoJSONSource(withId: Self.trailFriends, geoJSON: .featureCollection(Self.collection(trails.friends)))
            placeStart(trails.start)
            placeGapLabels(trails.gapLabels)
        }

        static func collection(_ lines: [MapTrails.Line]) -> FeatureCollection {
            var feats: [Feature] = []
            for l in lines {
                let props: (String) -> JSONObject = { k in ["k": .string(k), "c": .string("#" + Vehicle.hex(l.color)), "o": .number(l.opacity), "id": .string(l.id)] }
                for run in l.solid where run.count >= 2 {
                    var f = Feature(geometry: .lineString(LineString(run.map(\.coordinate))))
                    f.properties = props("s")
                    feats.append(f)
                }
                for g in l.gaps where g.count >= 2 {
                    var f = Feature(geometry: .lineString(LineString(g.map(\.coordinate))))
                    f.properties = props("g")
                    feats.append(f)
                }
            }
            return FeatureCollection(features: feats)
        }

        private func addTrailLayers(_ m: MapboxMap, myColor: UInt32) {
            for id in Self.trailLayerIds where m.layerExists(withId: id) { try? m.removeLayer(withId: id) }
            for src in [Self.trailFriends, Self.trailMine] where !m.sourceExists(withId: src) {
                var s = GeoJSONSource(id: src)
                s.data = .featureCollection(FeatureCollection(features: []))
                try? m.addSource(s)
            }
            /* Under every car, chip and pin: the cars are the newest layers, so go just below the first one
             * (and under a navigation route, which must stay readable over an old trail). */
            let ids = m.allLayerIdentifiers.map(\.id)
            let below = ids.first { $0.hasPrefix("sary-nav-") } ?? ids.first { $0.hasPrefix("sary-vehicle") }
            let pos: LayerPosition? = below.map { .below($0) }
            let w = (theme.drive ? 7.0 : 5.0) + (trails.highlight ? 2.5 : 0)
            func width(_ k: Double) -> [Any] { ["interpolate", ["linear"], ["zoom"], 9, k * 0.45, 14, k, 18, k * 1.35] }
            let solid: [Any] = ["==", ["get", "k"], "s"]
            let gap: [Any] = ["==", ["get", "k"], "g"]
            let roundLine: [String: Any] = ["line-join": "round", "line-cap": "round"]
            let casing = Self.casing(for: myColor)
            let mine = "#" + Vehicle.hex(myColor)
            var layers: [[String: Any]] = [
                ["id": "\(Self.trailFriends)-casing", "type": "line", "source": Self.trailFriends, "filter": solid, "layout": roundLine,
                 "paint": ["line-color": theme.night ? "#ffffff" : "#16110b", "line-width": width(w * 0.55 + 2.5),
                           "line-opacity": ["*", ["get", "o"], 0.55], "line-emissive-strength": 1] as [String: Any]],
                ["id": "\(Self.trailFriends)-line", "type": "line", "source": Self.trailFriends, "filter": solid, "layout": roundLine,
                 "paint": ["line-color": ["get", "c"], "line-width": width(w * 0.55), "line-opacity": ["get", "o"], "line-emissive-strength": 1] as [String: Any]],
                ["id": "\(Self.trailFriends)-gap", "type": "line", "source": Self.trailFriends, "filter": gap, "layout": ["line-join": "round"],
                 "paint": ["line-color": ["get", "c"], "line-width": width(w * 0.45), "line-opacity": ["*", ["get", "o"], 0.8],
                           "line-dasharray": [1, 2.2], "line-emissive-strength": 1] as [String: Any]],
            ]
            if trails.highlight {
                layers.append(["id": "\(Self.trailMine)-glow", "type": "line", "source": Self.trailMine, "layout": roundLine,
                               "paint": ["line-color": mine, "line-width": width(w + 14), "line-opacity": 0.35, "line-blur": 6, "line-emissive-strength": 1] as [String: Any]])
            }
            layers += [
                ["id": "\(Self.trailMine)-casing", "type": "line", "source": Self.trailMine, "filter": solid, "layout": roundLine,
                 "paint": ["line-color": casing, "line-width": width(w + 4.5), "line-opacity": 0.92, "line-emissive-strength": 1] as [String: Any]],
                ["id": "\(Self.trailMine)-line", "type": "line", "source": Self.trailMine, "filter": solid, "layout": roundLine,
                 "paint": ["line-color": mine, "line-width": width(w), "line-emissive-strength": 1] as [String: Any]],
                ["id": "\(Self.trailMine)-gap-casing", "type": "line", "source": Self.trailMine, "filter": gap, "layout": roundLine,
                 "paint": ["line-color": casing, "line-width": width(w * 0.7 + 3), "line-opacity": 0.85, "line-emissive-strength": 1] as [String: Any]],
                ["id": "\(Self.trailMine)-gap", "type": "line", "source": Self.trailMine, "filter": gap, "layout": ["line-join": "round"],
                 "paint": ["line-color": mine, "line-width": width(w * 0.7), "line-dasharray": [1.2, 1.6], "line-emissive-strength": 1] as [String: Any]],
            ]
            for l in layers { try? m.addLayer(with: l, layerPosition: pos) }
        }

        private func placeStart(_ p: LngLat?, force: Bool = false) {
            guard let map else { return }
            if p == startPin?.point && !force { return }
            startPin?.annotation.remove()
            startPin = nil
            guard let p else { return }
            let host = UIHostingController(rootView: TrailStartPin(theme: theme, compact: startCompact))
            host.view.backgroundColor = .clear
            host.safeAreaRegions = []
            /* Exactly the pin's own size, so its foot (the anchor) is on the first trail point. */
            host.view.frame = CGRect(origin: .zero, size: host.sizeThatFits(in: CGSize(width: CGFloat.infinity, height: CGFloat.infinity)))
            let a = ViewAnnotation(coordinate: p.coordinate, view: host.view)
            a.variableAnchors = [ViewAnnotationAnchorConfig(anchor: .bottom)]
            a.allowOverlap = true
            a.priority = 100
            map.viewAnnotations.add(a)
            startPin = (p, a, host)
        }

        private func placeGapLabels(_ pts: [LngLat]) {
            guard let map else { return }
            if pts == gapPins.map(\.point) { return }
            gapPins.forEach { $0.annotation.remove() }
            gapPins = []
            for p in pts {
                let host = UIHostingController(rootView: TrailGapLabel(theme: theme))
                host.view.backgroundColor = .clear
                host.safeAreaRegions = []
                host.view.frame = CGRect(origin: .zero, size: host.sizeThatFits(in: CGSize(width: CGFloat.infinity, height: CGFloat.infinity)))
                host.view.isUserInteractionEnabled = false
                let a = ViewAnnotation(coordinate: p.coordinate, view: host.view)
                /* Beside the dashed line, not on it: the line itself must stay visible. */
                a.variableAnchors = [ViewAnnotationAnchorConfig(anchor: .bottom, offsetY: 14), ViewAnnotationAnchorConfig(anchor: .top, offsetY: -14)]
                a.allowOverlap = false
                a.priority = 5
                map.viewAnnotations.add(a)
                gapPins.append((p, a, host))
            }
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
                if styleReady, r.layersReady { setPosition(r, on: m) }
            }
            layoutChips()
            project()
            if !moving {
                link?.invalidate()
                link = nil
            }
        }

        // MARK: camera

        /// What our chrome leaves clear, plus room above for a name and a note over a car.
        private var framePadding: UIEdgeInsets {
            UIEdgeInsets(top: chrome.top + GroupFraming.noteRoom, left: max(110, chrome.left + 60), bottom: chrome.bottom + 24, right: max(110, chrome.right + 60))
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

        /// Frame arbitrary points (my trail and me).
        func fit(_ pts: [LngLat]) {
            keepGroup = false
            frame(pts)
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
            /* Frame the group when positions first arrive, and again each time someone new appears —
             * unless the person is looking somewhere on purpose (moved the map, «أظهره», «موقعي»). */
            if !newcomers.isEmpty {
                if keepGroup || fittedIds.isEmpty {
                    keepGroup = true
                    fitGroup()
                } else {
                    fittedIds.formUnion(newcomers)
                }
                return
            }
            guard keepGroup, !fitting, lastCars.count >= 2 else { return }
            /* While keeping the group: if anyone (you included) drifts out of the clear area, reframe. */
            let p = UIEdgeInsets(top: chrome.top + GroupFraming.noteRoom * 0.75, left: max(8, chrome.left), bottom: chrome.bottom, right: max(8, chrome.right))
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
                if !expandedGroups.isEmpty {
                    expandedGroups.removeAll()
                    layoutChips()
                }
            }
        }
        func gestureManager(_ gestureManager: GestureManager, didEnd gestureType: GestureType, willAnimate: Bool) {}
        func gestureManager(_ gestureManager: GestureManager, didEndAnimatingFor gestureType: GestureType) {}
    }
}

/// Transparent to touches except on its chips, so the map underneath still pans and taps.
final class ChipOverlayView: UIView {
    /// Leader lines from a car to its moved chip (a dark halo under a light line, or the reverse).
    let leaderHalo = CAShapeLayer()
    let leaders = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        for (l, w) in [(leaderHalo, 3.5), (leaders, 1.5)] as [(CAShapeLayer, CGFloat)] {
            l.fillColor = nil
            l.lineWidth = w
            l.lineCap = .round
            layer.addSublayer(l)
        }
        accessibilityIdentifier = "map.chips"
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        leaderHalo.frame = bounds
        leaders.frame = bounds
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}

/// A SwiftUI view hosted at its own ideal size (measured once per content change).
final class HostBox<Content: View & Equatable>: UIView {
    private let host: UIHostingController<Content>
    private(set) var ideal: CGSize = .zero
    private var waitingSize: CGSize?

    init(_ content: Content) {
        host = UIHostingController(rootView: content)
        /* Never inset by the screen's safe area: these sit anywhere on the map, near the notch too. */
        host.safeAreaRegions = []
        super.init(frame: .zero)
        backgroundColor = .clear
        host.view.backgroundColor = .clear
        addSubview(host.view)
        ideal = host.sizeThatFits(in: CGSize(width: 240, height: 600))
        frame.size = ideal
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(_ content: Content) {
        guard host.rootView != content else { return }
        host.rootView = content
        ideal = host.sizeThatFits(in: CGSize(width: 240, height: 600))
        waitingSize = nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        host.view.frame = bounds
    }
}

extension HostBox where Content == MapChip {
    /// The chip's size as drawn with (or without) the waiting-note dot.
    func measure(noteWaiting: Bool) -> CGSize {
        guard noteWaiting else { return ideal }
        if let s = waitingSize { return s }
        var v = host.rootView
        v.noteWaiting = true
        let probe = UIHostingController(rootView: v)
        probe.safeAreaRegions = []
        let s = probe.sizeThatFits(in: CGSize(width: 240, height: 600))
        waitingSize = s
        return s
    }

    func setNoteWaiting(_ on: Bool) {
        guard host.rootView.noteWaiting != on else { return }
        var v = host.rootView
        v.noteWaiting = on
        host.rootView = v
    }
}

extension LngLat {
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lng) }
}

/// The name chip over a car, from the design system. `noteWaiting` adds the
/// small note indicator when the member's bubble has no room (crowded, or zoomed out).
struct MapChip: View, Equatable {
    let chip: NameChipUI
    var noteWaiting: Bool
    let theme: SaryTheme
    var onTap: () -> Void

    static func == (a: MapChip, b: MapChip) -> Bool { a.chip == b.chip && a.noteWaiting == b.noteWaiting && a.theme == b.theme }

    var body: some View {
        SaryNameChip(chip: chip, noteWaiting: noteWaiting, tapped: onTap, id: chip.isMe ? "car.chip.me" : "car.chip")
            .padding(2)
            .saryTheme(theme)
    }
}

/// A member's note bubble, placed above their chip when there is room.
struct MapNote: View, Equatable {
    let bubble: NoteBubbleUI
    let theme: SaryTheme
    var onTap: () -> Void

    static func == (a: MapNote, b: MapNote) -> Bool { a.bubble == b.bubble && a.theme == b.theme }

    var body: some View {
        Button(action: onTap) { SaryNoteBubble(bubble: bubble) }
            .buttonStyle(.plain)
            .padding(.horizontal, 2)
            .saryTheme(theme)
            .accessibilityIdentifier("car.note")
    }
}

/// Several friends folded into one chip («٣ سيارات»); tap to spread them out.
struct MapGroupChip: View, Equatable {
    let count: Int
    let colors: [UInt32]
    let theme: SaryTheme
    var onTap: () -> Void

    static func == (a: MapGroupChip, b: MapGroupChip) -> Bool { a.count == b.count && a.colors == b.colors && a.theme == b.theme }

    var body: some View {
        SaryGroupChip(count: count, colors: colors, tapped: onTap)
            .accessibilityIdentifier("car.group")
            .padding(2)
            .saryTheme(theme)
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

/// Where «نقطة البداية» draws on screen (anchor = the pin's foot on the first trail point), and
/// when its label gives way to the cars' chips. Pure, tested.
enum StartPinLayout {
    static let iconSize = CGSize(width: 34, height: 34)
    static let labelSize = CGSize(width: 104, height: 24)

    static func rects(anchor a: CGPoint) -> (icon: CGRect, label: CGRect) {
        let icon = CGRect(x: a.x - iconSize.width / 2, y: a.y - iconSize.height, width: iconSize.width, height: iconSize.height)
        let label = CGRect(x: a.x - labelSize.width / 2, y: icon.minY - 2 - labelSize.height, width: labelSize.width, height: labelSize.height)
        return (icon, label)
    }

    /// Fold the label when any chip touches it; unfold only with a clear margin (no flicker as cars move).
    static func crowded(label: CGRect, chips: [CGRect], wasCompact: Bool) -> Bool {
        let margin: CGFloat = wasCompact ? 10 : 2
        let zone = label.insetBy(dx: -margin, dy: -margin)
        return chips.contains { $0.intersects(zone) }
    }
}

/// «نقطة البداية»: where I entered (the first point of my trail).
struct TrailStartPin: View {
    let theme: SaryTheme
    /// Icon only: a car's chip is right there (see `StartPinLayout`).
    var compact = false

    var body: some View {
        let p = theme.palette
        VStack(spacing: 2) {
            if !compact {
            Text("نقطة البداية")
                .saryText(.caption, weight: .bold)
                .foregroundStyle(p.textPrimary)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(p.chromeOpaque))
                .overlay(Capsule().stroke(p.stroke, lineWidth: 1))
                .dynamicTypeSize(...DynamicTypeSize.xxLarge)
            }
            Image(systemName: "figure.walk.departure")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Color.white)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color(rgb: 0x16110B)))
                .overlay(Circle().stroke(Color.white, lineWidth: 2.5))
        }
        .padding(2)
        .fixedSize()
        .compositingGroup()
        .shadow(color: .black.opacity(0.3), radius: 3, y: 2)
        .saryTheme(theme)
        .environment(\.layoutDirection, .rightToLeft)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("نقطة البداية، حيث دخلت"))
        .accessibilityIdentifier("map.trailStart")
    }
}

/// Said on an unrecorded stretch of the trail (drawn dashed and straight).
struct TrailGapLabel: View {
    let theme: SaryTheme

    var body: some View {
        Text("لم يُسجَّل هذا الجزء")
            .saryText(.micro, weight: .bold)
            .foregroundStyle(theme.palette.textSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(theme.palette.chromeOpaque.opacity(0.92)))
            .fixedSize()
            .saryTheme(theme)
            .environment(\.layoutDirection, .rightToLeft)
            .accessibilityIdentifier("map.trailGap")
    }
}

/// Flat (pitch-free) Web Mercator projection relative to a known on-screen point —
/// good enough to point an arrow at someone who is off the screen.
enum ScreenProjection {
    static func world(_ c: CLLocationCoordinate2D, zoom: Double) -> CGPoint {
        let size = 512 * pow(2, zoom)
        let lat = max(-85.05112878, min(85.05112878, c.latitude)) * .pi / 180
        let x = (c.longitude + 180) / 360 * size
        let y = (1 - log(tan(lat) + 1 / cos(lat)) / .pi) / 2 * size
        return CGPoint(x: x, y: y)
    }

    static func point(_ c: CLLocationCoordinate2D, center: CLLocationCoordinate2D, centerPoint: CGPoint, zoom: Double, bearing: Double) -> CGPoint {
        let a = world(c, zoom: zoom), o = world(center, zoom: zoom)
        let dx = a.x - o.x, dy = a.y - o.y
        let r = -bearing * .pi / 180
        return CGPoint(x: centerPoint.x + dx * cos(r) - dy * sin(r), y: centerPoint.y + dx * sin(r) + dy * cos(r))
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
    /// The last fetched style is kept on disk, so an offline launch draws the same
    /// Arabic style (its tiles, glyphs and sprites then come from the offline TileStore / style pack).
    private(set) static var cachedJSON: String? = {
        guard let u = fileURL, let s = try? String(contentsOf: u, encoding: .utf8), s.contains("name_ar") else { return nil }
        return s
    }()
    private static var fileURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("arabic-basemap-v1.json")
    }
    private static var refreshed = false
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
        /* Already fetched this launch: the map was created with it. A disk copy is refreshed once per launch. */
        if cachedJSON != nil && refreshed { return }
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
        refreshed = true
        if let json, json != cachedJSON {
            cachedJSON = json
            if let u = fileURL {
                try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? json.write(to: u, atomically: true, encoding: .utf8)
            }
        } else if json != nil {
            /* Same style as the one already drawn: nothing to reload. */
            waiters = []
            return
        }
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
