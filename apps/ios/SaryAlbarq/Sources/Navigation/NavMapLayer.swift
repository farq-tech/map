import MapboxMaps
import SwiftUI
import UIKit

/// What the live map draws for navigation: routes (the chosen one on top),
/// the honest dashed straight line of an off-road last leg, the target flag,
/// time/distance labels on alternatives, and the guidance camera.
struct MapNavDrawing: Equatable {
    struct Line: Equatable {
        var id: String
        var coordinates: [LngLat]
        var selected: Bool
        /// The remaining route in traffic bands (nil: one plain colour).
        var traffic: [NavTrafficRun]? = nil
        /// Known asphalt / unpaved / predicted terrain runs, when the provider can distinguish them.
        var surfaces: [NavSurfaceRun] = []
    }

    struct Label: Equatable {
        var id: String
        var at: LngLat
        var text: String
        var selected: Bool
    }

    /// The guidance camera's one-shot framings. Following my car («باتجاهي») is the map's
    /// own follow camera (`FollowCamera.swift`), driven every frame from the smoothed car.
    enum Camera: Equatable {
        /// Fit these points (the remaining route / the planning preview).
        case fit([LngLat], bottomShare: Double)
    }

    var routes: [Line] = []
    /// From the road's end to the target (straight, dashed). Never a road.
    var offRoad: [LngLat]? = nil
    var target: LngLat? = nil
    var targetName = ""
    /// «آخر موقع معروف · قبل ١٤ د» under the name for a last-known target (never shown as live).
    var targetNote: String? = nil
    var labels: [Label] = []
    /// True only while a navigation leg is active. A route preview can fit the camera without
    /// putting the map into the driving state.
    var guidanceActive = false
    var camera: Camera? = nil
    /// Bumps to re-run a one-shot `fit`.
    var cameraKey = 0

    var isEmpty: Bool { routes.isEmpty && offRoad == nil && target == nil }
}

/// Draws `MapNavDrawing` on the outing's `MapView`; owned by the map's coordinator (main thread, like it).
final class NavMapDrawer {
    private weak var map: MapView?
    private var drawing = MapNavDrawing()
    private var styleReady = false
    private var targetPin: (point: LngLat, annotation: ViewAnnotation, host: UIHostingController<NavTargetPin>)?
    private var labelPins: [String: (label: MapNavDrawing.Label, annotation: ViewAnnotation, host: UIHostingController<NavRouteLabel>)] = [:]
    private var lastCameraKey = -1
    var theme: SaryTheme = .default
    var onSelectRoute: (String) -> Void = { _ in }

    static let source = "sary-nav-routes"
    static let offSource = "sary-nav-offroad"
    static let layerIds = ["sary-nav-alt-casing", "sary-nav-alt", "sary-nav-main-casing", "sary-nav-main",
                           "sary-nav-dirt-casing", "sary-nav-dirt", "sary-nav-dirt-ruts",
                           "sary-nav-terrain-casing", "sary-nav-terrain",
                           "sary-nav-rough-casing", "sary-nav-rough", "sary-nav-rough-ticks",
                           "sary-nav-grid-snap-casing", "sary-nav-grid-snap", "sary-nav-off-casing", "sary-nav-off"]
    /// Surface styles on the chosen route — three readable "materials", never a colour alone
    /// (each also differs in pattern, so it reads in sunlight and for colour-blind drivers):
    /// asphalt = solid blue with a white casing; dirt track = sand line with dark-earth edges and
    /// pale wheel-rut dashes; open terrain = amber dots; rough ground = red-ochre dashes with ticks.
    enum SurfaceStyle {
        static let dirtRGB: UInt32 = 0xD6A15A, dirtEdgeRGB: UInt32 = 0x5B3A1C, dirtRutsRGB: UInt32 = 0xF6E2B8
        static let terrainRGB: UInt32 = 0xF2C14E, terrainEdgeRGB: UInt32 = 0x3A2913
        static let roughRGB: UInt32 = 0xD9502F, roughEdgeRGB: UInt32 = 0x2A0E07, roughTicksRGB: UInt32 = 0xFFD9C9
        static func hex(_ rgb: UInt32) -> String { String(format: "#%06X", rgb) }
        static let dirt = hex(dirtRGB), dirtEdge = hex(dirtEdgeRGB), dirtRuts = hex(dirtRutsRGB)
        static let terrain = hex(terrainRGB), terrainEdge = hex(terrainEdgeRGB)
        static let rough = hex(roughRGB), roughEdge = hex(roughEdgeRGB), roughTicks = hex(roughTicksRGB)
    }
    /// `SaryPalette.navBlueDay` as a style colour ("#2B7BF0").
    static let routeBlue = String(format: "#%06X", SaryPalette.navBlueDay)
    /// Traffic bands on the chosen route: free (blue), slow (orange), heavy (red), standstill (dark red).
    static let trafficColors = ["#F08A24", "#E0362C", "#8E1B1B"]

    /// Guidance owns the camera (the group framing and «موقعي» stand aside).
    var ownsCamera: Bool { drawing.camera != nil }

    func attach(_ map: MapView) { self.map = map }

    func styleLoaded() {
        styleReady = true
        addLayers()
        targetPin?.annotation.remove()
        targetPin = nil
        for l in labelPins.values { l.annotation.remove() }
        labelPins = [:]
        draw()
    }

    func update(_ d: MapNavDrawing, chrome: UIEdgeInsets, me: LngLat?, heading: Double?) {
        let changed = d != drawing
        drawing = d
        if changed { draw() }
        camera(chrome: chrome, me: me, heading: heading)
    }

    private func addLayers() {
        guard styleReady, let m = map?.mapboxMap else { return }
        for id in Self.layerIds where m.layerExists(withId: id) { try? m.removeLayer(withId: id) }
        for src in [Self.source, Self.offSource] where !m.sourceExists(withId: src) {
            var s = GeoJSONSource(id: src)
            s.data = .featureCollection(FeatureCollection(features: []))
            try? m.addSource(s)
        }
        /* Under every car, chip and pin (cars are the newest layers), above the trails. */
        let below = m.allLayerIdentifiers.first { $0.id.hasPrefix("sary-vehicle") }?.id
        let pos: LayerPosition? = below.map { .below($0) }
        func width(_ k: Double) -> [Any] { ["interpolate", ["linear"], ["zoom"], 8, k * 0.4, 14, k, 18, k * 1.6] }
        let round: [String: Any] = ["line-join": "round", "line-cap": "round"]
        let sel: [Any] = ["==", ["get", "s"], 1]
        let alt: [Any] = ["==", ["get", "s"], 0]
        let knownSurface: [Any] = ["all", sel, ["!", ["has", "k"]]]
        func kind(_ k: NavSurfaceKind) -> [Any] { ["all", sel, ["==", ["get", "k"], k.rawValue]] }
        /* Asphalt (and routes without surface data) keep the classic solid blue line. */
        let asphalt: [Any] = ["any", knownSurface, kind(.paved)]
        let gridSnap: [Any] = ["all", sel, ["==", ["get", "k"], NavSurfaceKind.gridSnap.rawValue]]
        let layers: [[String: Any]] = [
            ["id": "sary-nav-alt-casing", "type": "line", "source": Self.source, "filter": alt, "layout": round,
             "paint": ["line-color": "#1b2a44", "line-width": width(9), "line-opacity": 0.55, "line-emissive-strength": 1] as [String: Any]],
            ["id": "sary-nav-alt", "type": "line", "source": Self.source, "filter": alt, "layout": round,
             "paint": ["line-color": "#9db8e6", "line-width": width(6), "line-opacity": 0.9, "line-emissive-strength": 1] as [String: Any]],
            ["id": "sary-nav-main-casing", "type": "line", "source": Self.source, "filter": asphalt, "layout": round,
             "paint": ["line-color": "#ffffff", "line-width": width(12), "line-occlusion-opacity": 0.8, "line-emissive-strength": 1] as [String: Any]],
            ["id": "sary-nav-main", "type": "line", "source": Self.source, "filter": asphalt, "layout": round,
             /* Still visible behind 3D buildings (Olaya towers would hide the turn otherwise). */
             "paint": ["line-color": ["match", ["coalesce", ["get", "c"], 0], 1, Self.trafficColors[0], 2, Self.trafficColors[1], 3, Self.trafficColors[2], Self.routeBlue] as [Any],
                       "line-width": width(8), "line-occlusion-opacity": 0.8, "line-emissive-strength": 1] as [String: Any]],
            /* Dirt track («ترابي»): a sand-coloured road with dark-earth edges and two pale wheel ruts. */
            ["id": "sary-nav-dirt-casing", "type": "line", "source": Self.source, "filter": kind(.unpaved), "layout": round,
             "paint": ["line-color": SurfaceStyle.dirtEdge, "line-width": width(11), "line-opacity": 0.9,
                       "line-occlusion-opacity": 0.6, "line-emissive-strength": 1] as [String: Any]],
            ["id": "sary-nav-dirt", "type": "line", "source": Self.source, "filter": kind(.unpaved), "layout": round,
             "paint": ["line-color": SurfaceStyle.dirt, "line-width": width(7.5), "line-occlusion-opacity": 0.6,
                       "line-emissive-strength": 1] as [String: Any]],
            ["id": "sary-nav-dirt-ruts", "type": "line", "source": Self.source, "filter": kind(.unpaved), "layout": ["line-cap": "butt", "line-join": "round"],
             "paint": ["line-color": SurfaceStyle.dirtRuts, "line-width": width(1.4), "line-gap-width": width(2.6),
                       "line-dasharray": [3, 2], "line-opacity": 0.85, "line-emissive-strength": 1] as [String: Any]],
            /* Open terrain («بر مفتوح»): a chain of amber dots over a soft dark halo — a predicted way, not a road. */
            ["id": "sary-nav-terrain-casing", "type": "line", "source": Self.source, "filter": kind(.terrain), "layout": round,
             "paint": ["line-color": SurfaceStyle.terrainEdge, "line-width": width(9), "line-opacity": 0.45,
                       "line-blur": 1.5, "line-emissive-strength": 1] as [String: Any]],
            ["id": "sary-nav-terrain", "type": "line", "source": Self.source, "filter": kind(.terrain), "layout": round,
             "paint": ["line-color": SurfaceStyle.terrain, "line-width": width(6.5),
                       "line-dasharray": [0.01, 1.7], "line-emissive-strength": 1] as [String: Any]],
            /* Rough ground («وعر»: طعوس، صخر، سبخة، شعيب): bold red-ochre dashes with pale cross-ticks. */
            ["id": "sary-nav-rough-casing", "type": "line", "source": Self.source, "filter": kind(.rough), "layout": round,
             "paint": ["line-color": SurfaceStyle.roughEdge, "line-width": width(10.5), "line-opacity": 0.8,
                       "line-emissive-strength": 1] as [String: Any]],
            ["id": "sary-nav-rough", "type": "line", "source": Self.source, "filter": kind(.rough), "layout": ["line-cap": "butt", "line-join": "round"],
             "paint": ["line-color": SurfaceStyle.rough, "line-width": width(7),
                       "line-dasharray": [1.6, 0.7], "line-emissive-strength": 1] as [String: Any]],
            ["id": "sary-nav-rough-ticks", "type": "line", "source": Self.source, "filter": kind(.rough), "layout": ["line-cap": "butt"],
             "paint": ["line-color": SurfaceStyle.roughTicks, "line-width": width(7), "line-dasharray": [0.12, 1.1],
                       "line-opacity": 0.9, "line-emissive-strength": 1] as [String: Any]],
            /* The road-to-grid cell-center join is approximate by definition, never a solid road. */
            ["id": "sary-nav-grid-snap-casing", "type": "line", "source": Self.source, "filter": gridSnap, "layout": round,
             "paint": ["line-color": "#21180d", "line-width": width(7), "line-opacity": 0.8,
                       "line-dasharray": [1.2, 1.4], "line-emissive-strength": 1] as [String: Any]],
            ["id": "sary-nav-grid-snap", "type": "line", "source": Self.source, "filter": gridSnap, "layout": round,
             "paint": ["line-color": "#F2D18A", "line-width": width(3.5), "line-dasharray": [1.2, 1.4],
                       "line-emissive-strength": 1] as [String: Any]],
            /* The off-road remainder: dashed, amber, thin — visibly NOT a road. */
            ["id": "sary-nav-off-casing", "type": "line", "source": Self.offSource, "layout": ["line-cap": "round"],
             "paint": ["line-color": "#16110b", "line-width": width(6), "line-opacity": 0.7, "line-dasharray": [1.4, 1.4], "line-emissive-strength": 1] as [String: Any]],
            ["id": "sary-nav-off", "type": "line", "source": Self.offSource, "layout": ["line-cap": "round"],
             "paint": ["line-color": "#F5B83D", "line-width": width(3.5), "line-dasharray": [1.4, 1.4], "line-emissive-strength": 1] as [String: Any]],
        ]
        for l in layers { try? m.addLayer(with: l, layerPosition: pos) }
    }

    private func draw() {
        guard styleReady, let map else { return }
        let m: MapboxMap = map.mapboxMap
        if !m.layerExists(withId: "sary-nav-main") { addLayers() }
        var feats: [Feature] = []
        /* Alternatives first, the chosen route last (drawn on top by its own layer anyway). */
        for r in drawing.routes.sorted(by: { !$0.selected && $1.selected }) where r.coordinates.count >= 2 {
            if r.selected, !r.surfaces.isEmpty, r.traffic?.isEmpty != false {
                for run in r.surfaces where run.coordinates.count >= 2 {
                    var f = Feature(geometry: .lineString(LineString(run.coordinates.map(\.coordinate))))
                    f.properties = ["s": .number(1), "id": .string(r.id), "k": .string(run.kind.rawValue)]
                    feats.append(f)
                }
                continue
            }
            if r.selected, let runs = r.traffic, !runs.isEmpty {
                /* One feature per traffic band («c»); the casing still sees one continuous line. */
                for run in runs where run.coordinates.count >= 2 {
                    var f = Feature(geometry: .lineString(LineString(run.coordinates.map(\.coordinate))))
                    f.properties = ["s": .number(1), "id": .string(r.id), "c": .number(Double(run.band))]
                    feats.append(f)
                }
                continue
            }
            var f = Feature(geometry: .lineString(LineString(r.coordinates.map(\.coordinate))))
            f.properties = ["s": .number(r.selected ? 1 : 0), "id": .string(r.id)]
            feats.append(f)
        }
        m.updateGeoJSONSource(withId: Self.source, geoJSON: .featureCollection(FeatureCollection(features: feats)))
        var off: [Feature] = []
        if let o = drawing.offRoad, o.count >= 2 { off.append(Feature(geometry: .lineString(LineString(o.map(\.coordinate))))) }
        m.updateGeoJSONSource(withId: Self.offSource, geoJSON: .featureCollection(FeatureCollection(features: off)))
        placeTarget()
        placeLabels()
    }

    private func placeTarget() {
        guard let map else { return }
        if drawing.target == targetPin?.point, targetPin?.host.rootView.name == drawing.targetName,
           targetPin?.host.rootView.note == drawing.targetNote { return }
        targetPin?.annotation.remove()
        targetPin = nil
        guard let p = drawing.target else { return }
        let host = UIHostingController(rootView: NavTargetPin(name: drawing.targetName, note: drawing.targetNote, theme: theme))
        host.view.backgroundColor = .clear
        host.safeAreaRegions = []
        host.view.frame = CGRect(origin: .zero, size: host.sizeThatFits(in: CGSize(width: CGFloat.infinity, height: CGFloat.infinity)))
        host.view.isUserInteractionEnabled = false
        let a = ViewAnnotation(coordinate: p.coordinate, view: host.view)
        a.variableAnchors = [ViewAnnotationAnchorConfig(anchor: .bottom)]
        a.allowOverlap = true
        a.priority = 90
        map.viewAnnotations.add(a)
        targetPin = (p, a, host)
    }

    private func placeLabels() {
        guard let map else { return }
        let want = Dictionary(drawing.labels.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for (id, pin) in labelPins where want[id] != pin.label {
            pin.annotation.remove()
            labelPins[id] = nil
        }
        for (id, l) in want where labelPins[id] == nil {
            let host = UIHostingController(rootView: NavRouteLabel(text: l.text, selected: l.selected, theme: theme) { [weak self] in self?.onSelectRoute(id) })
            host.view.backgroundColor = .clear
            host.safeAreaRegions = []
            host.view.frame = CGRect(origin: .zero, size: host.sizeThatFits(in: CGSize(width: CGFloat.infinity, height: CGFloat.infinity)))
            let a = ViewAnnotation(coordinate: l.at.coordinate, view: host.view)
            a.variableAnchors = [.init(anchor: .bottom, offsetY: 6), .init(anchor: .top, offsetY: -6), .init(anchor: .left, offsetX: 6), .init(anchor: .right, offsetX: -6)]
            /* Both route times always show (like Google: «١٢ د» on each route): a couple of labels, never a crowd. */
            a.allowOverlap = true
            a.priority = l.selected ? 80 : 70
            map.viewAnnotations.add(a)
            labelPins[id] = (l, a, host)
        }
    }

    // MARK: camera

    /// The padding that fits the routes in the map left visible by the header (`chrome.top`) and
    /// the sheet (`bottomShare` of the height, or `chrome.bottom` if taller). Always leaves at least
    /// `minVisibleShare` of the height and of the width for the routes (top and bottom shrink in proportion).
    static let minVisibleShare: CGFloat = 0.2

    static func fitPadding(size: CGSize, chrome: UIEdgeInsets, bottomShare: Double) -> UIEdgeInsets {
        var top = chrome.top + 70
        var bottom = max(chrome.bottom, size.height * bottomShare) + 24
        let room = size.height * (1 - minVisibleShare)
        if top + bottom > room, top + bottom > 0 {
            let k = room / (top + bottom)
            top *= k
            bottom *= k
        }
        let side = min(50, size.width * (1 - minVisibleShare) / 2)
        return UIEdgeInsets(top: top, left: side, bottom: bottom, right: side)
    }

    private func camera(chrome: UIEdgeInsets, me: LngLat?, heading: Double?) {
        guard let map, map.bounds.height > 0, let cam = drawing.camera else { return }
        let reduce = UIAccessibility.isReduceMotionEnabled
        switch cam {
        case let .fit(pts, share):
            guard drawing.cameraKey != lastCameraKey, let b = GroupFraming.bounds(pts) else { return }
            let coords = [CLLocationCoordinate2D(latitude: b.south, longitude: b.west), CLLocationCoordinate2D(latitude: b.north, longitude: b.east)]
            let pad = Self.fitPadding(size: map.bounds.size, chrome: chrome, bottomShare: share)
            /* Build 18+: the header and the options sheet together could pad more than the map is tall;
             * Mapbox then threw, the error was swallowed and the key spent — the map stayed at city zoom. */
            guard var c = try? map.mapboxMap.camera(for: coords, camera: CameraOptions(padding: .zero, bearing: 0, pitch: 0),
                                                    coordinatesPadding: pad, maxZoom: 16.5, offset: nil) else { return }
            lastCameraKey = drawing.cameraKey
            c.padding = nil
            map.camera.ease(to: c, duration: reduce ? 0 : 0.9)
        }
    }
}

/// The target flag at the end of the route.
struct NavTargetPin: View {
    var name: String
    var note: String? = nil
    var theme: SaryTheme

    var body: some View {
        let p = theme.palette
        VStack(spacing: 2) {
            VStack(spacing: 0) {
                Text(name.isEmpty ? "الوجهة" : name)
                    .saryText(.caption, weight: .bold)
                    .foregroundStyle(p.textPrimary)
                    .lineLimit(1)
                if let note {
                    Text(note).saryText(.micro, weight: .bold).foregroundStyle(p.warningText).lineLimit(1)
                        .accessibilityIdentifier("map.navTarget.stale")
                }
            }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(p.chromeOpaque))
                .overlay(Capsule().stroke(p.navBlue, lineWidth: 2))
            Image(systemName: "flag.circle.fill")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(p.onNavBlue, p.navBlue)
                .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
        }
        .frame(maxWidth: 180)
        .saryTheme(theme)
        .environment(\.layoutDirection, .rightToLeft)
        .accessibilityIdentifier("map.navTarget")
    }
}

/// «١٢ د · ٨٫٤ كم» on an alternative; tap to choose it.
struct NavRouteLabel: View {
    var text: String
    var selected: Bool
    var theme: SaryTheme
    var tap: () -> Void

    var body: some View {
        let p = theme.palette
        Button(action: tap) {
            Text(text)
                .saryNumber(.footnote, weight: .bold)
                .foregroundStyle(selected ? p.onNavBlue : p.textPrimary)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(selected ? p.navBlue : p.chromeOpaque))
                .overlay(Capsule().stroke(selected ? p.onNavBlue : Color(rgb: 0x9DB8E6), lineWidth: 2))
                .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
        }
        .buttonStyle(.plain)
        .saryTheme(theme)
        .environment(\.layoutDirection, .rightToLeft)
        .accessibilityIdentifier(selected ? "map.navLabel.selected" : "map.navLabel")
    }
}
