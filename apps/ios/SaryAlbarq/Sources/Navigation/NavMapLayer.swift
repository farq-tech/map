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
    /// The next turn drawn on the route: a short white arrow along the line through the
    /// maneuver point (`NavManeuverArrow.shaft`), nil when the next step is not a turn.
    var maneuver: [LngLat]? = nil
    /// True only while a navigation leg is active. A route preview can fit the camera without
    /// putting the map into the driving state.
    var guidanceActive = false
    /// The chosen route's geometry revision (`NavRoute.geometryRevision`): a new value is a new
    /// route on the map (`NavRouteReveal`). Not the drawn coordinates, which shrink with every fix.
    var revealKey: String? = nil
    var camera: Camera? = nil
    /// Bumps to re-run a one-shot `fit`.
    var cameraKey = 0

    var isEmpty: Bool { routes.isEmpty && offRoad == nil && target == nil }
}

/// Which navigation GeoJSON sources must be sent again (pure, unit-tested). During guidance the
/// drawing changes with nearly every fix (the off-road remainder, the turn arrow, the target's
/// «قبل … د» note), but the routes — thousands of points — rarely; only changed sources are re-sent.
struct NavSourceChanges: Equatable {
    var routes: Bool
    var offRoad: Bool
    var maneuver: Bool

    static let all = NavSourceChanges(routes: true, offRoad: true, maneuver: true)

    /// `drawn`: what the sources hold now; nil when unknown (new style, new layers): everything.
    static func between(drawn: MapNavDrawing?, next: MapNavDrawing) -> NavSourceChanges {
        guard let drawn else { return .all }
        return NavSourceChanges(routes: drawn.routes != next.routes, offRoad: drawn.offRoad != next.offRoad,
                                maneuver: drawn.maneuver != next.maneuver)
    }
}

/// How a new route arrives on the map (pure, unit-tested in `NavigationTests`). The style's own
/// paint transitions do the animating (two property writes, no per-frame updates): the chosen
/// route fades in on its first appearance, a reroute fades in faster with a brief darker halo,
/// and the next-turn arrow fades in when the maneuver changes. Reduce Motion: none of it.
enum NavRouteReveal: Equatable {
    case none
    /// The first route on the map (the options, or guidance started without a preview).
    case reveal
    /// A new route while guiding.
    case reroute

    static func kind(previous: String?, next: String?, wasGuiding: Bool, isGuiding: Bool) -> NavRouteReveal {
        guard let next, next != previous else { return .none }
        guard previous != nil else { return .reveal }
        /* Picking another option, or starting guidance on the previewed route, is not a new line. */
        return wasGuiding && isGuiding ? .reroute : .none
    }

    /// The fade-in, in ms (the style transition's `duration`).
    static func fadeMs(_ k: NavRouteReveal, reduceMotion: Bool) -> Int {
        guard !reduceMotion else { return 0 }
        switch k {
        case .none: return 0
        case .reveal: return 600
        case .reroute: return 350
        }
    }

    /// The next-turn arrow fades in when it moves to a new maneuver (not when it goes away).
    static func maneuverFades(previous: [LngLat]?, next: [LngLat]?, reduceMotion: Bool) -> Bool {
        guard !reduceMotion, let next, next.count >= 2 else { return false }
        return next != previous
    }

    /// The reroute's emphasis: the halo darkens for a moment, then settles back.
    static let rerouteHaloOpacity = 0.9
    static let rerouteHoldS = 0.6
}

/// Draws `MapNavDrawing` on the outing's `MapView`; owned by the map's coordinator (main thread, like it).
final class NavMapDrawer {
    private weak var map: MapView?
    private var drawing = MapNavDrawing()
    private var styleReady = false
    private var targetPin: (point: LngLat, annotation: ViewAnnotation, host: UIHostingController<NavTargetPin>)?
    private var labelPins: [String: (label: MapNavDrawing.Label, annotation: ViewAnnotation, host: UIHostingController<NavRouteLabel>)] = [:]
    private var lastCameraKey = -1
    /// What the GeoJSON sources hold (nil: unknown, send everything).
    private var drawnSources: MapNavDrawing?
    var theme: SaryTheme = .default
    var onSelectRoute: (String) -> Void = { _ in }

    static let source = "sary-nav-routes"
    static let offSource = "sary-nav-offroad"
    static let maneuverSource = "sary-nav-maneuver"
    static let maneuverHeadImage = "sary-nav-maneuver-head"
    static let haloLayer = "sary-nav-halo"
    static let layerIds = ["sary-nav-alt-casing", "sary-nav-alt", haloLayer, "sary-nav-main-casing", "sary-nav-main",
                           "sary-nav-dirt-casing", "sary-nav-dirt", "sary-nav-dirt-ruts",
                           "sary-nav-terrain-casing", "sary-nav-terrain",
                           "sary-nav-rough-casing", "sary-nav-rough", "sary-nav-rough-ticks",
                           "sary-nav-grid-snap-casing", "sary-nav-grid-snap", "sary-nav-off-casing", "sary-nav-off",
                           "sary-nav-maneuver-casing", "sary-nav-maneuver", "sary-nav-maneuver-head"]

    /// One faded paint property and the value it rests at (the same values as in `addLayers`).
    struct Fade: Equatable {
        var layer: String
        var property: String
        var rest: Double
    }

    /// The chosen route's layers, faded in by `NavRouteReveal` (alternatives stay as they are).
    static let routeFades: [Fade] = [
        Fade(layer: haloLayer, property: "line-opacity", rest: haloOpacity),
        Fade(layer: "sary-nav-main-casing", property: "line-opacity", rest: 1),
        Fade(layer: "sary-nav-main", property: "line-opacity", rest: 1),
        Fade(layer: "sary-nav-dirt-casing", property: "line-opacity", rest: 0.9),
        Fade(layer: "sary-nav-dirt", property: "line-opacity", rest: 1),
        Fade(layer: "sary-nav-dirt-ruts", property: "line-opacity", rest: 0.85),
        Fade(layer: "sary-nav-terrain-casing", property: "line-opacity", rest: 0.6),
        Fade(layer: "sary-nav-terrain", property: "line-opacity", rest: 1),
        Fade(layer: "sary-nav-rough-casing", property: "line-opacity", rest: 0.8),
        Fade(layer: "sary-nav-rough", property: "line-opacity", rest: 1),
        Fade(layer: "sary-nav-rough-ticks", property: "line-opacity", rest: 0.9),
        Fade(layer: "sary-nav-grid-snap-casing", property: "line-opacity", rest: 0.8),
        Fade(layer: "sary-nav-grid-snap", property: "line-opacity", rest: 1),
    ]

    /// The next-turn arrow, faded in when it moves to a new maneuver.
    static let maneuverFades: [Fade] = [
        Fade(layer: "sary-nav-maneuver-casing", property: "line-opacity", rest: 0.85),
        Fade(layer: "sary-nav-maneuver", property: "line-opacity", rest: 1),
        Fade(layer: "sary-nav-maneuver-head", property: "icon-opacity", rest: 1),
    ]
    static let maneuverFadeMs = 300

    /// The route key and guidance state the map last showed (`NavRouteReveal.kind`).
    private var revealedKey: String?
    private var revealedGuiding = false

    /// Line width by zoom for a route layer of nominal width `k` (pt at z14). Build 36 grew it
    /// only 1.6× by z18, so at the guidance zooms (z15–17, tilted: the far half shrinks further)
    /// the line was thin over busy desert imagery; it now grows ~1.15× at z15 and 1.5× at z17.
    static func width(_ k: Double) -> [Any] {
        ["interpolate", ["linear"], ["zoom"], 8.0, k * 0.4, 13.0, k * 0.85, 15.0, k * 1.15, 17.0, k * 1.5, 19.0, k * 1.9]
    }

    /// The chosen route's outer shadow: a dark, soft band under the white casing. Over pale sand
    /// a white casing alone has almost no contrast (white on cream), so the blue line read as a
    /// faint stroke; the dark band gives every surface style an edge on light ground, the white
    /// casing on dark ground and at night.
    static let haloColor = "#06101F"
    static let haloOpacity = 0.55
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
        drawnSources = nil
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
        for src in [Self.source, Self.offSource, Self.maneuverSource] where !m.sourceExists(withId: src) {
            var s = GeoJSONSource(id: src)
            s.data = .featureCollection(FeatureCollection(features: []))
            try? m.addSource(s)
        }
        /* Same id again replaces the image (addLayers runs once per style load). */
        try? m.addImage(Self.arrowHead(), id: Self.maneuverHeadImage)
        /* Under every car, chip and pin (cars are the newest layers), above the trails. */
        let below = m.allLayerIdentifiers.first { $0.id.hasPrefix("sary-vehicle") }?.id
        let pos: LayerPosition? = below.map { .below($0) }
        func width(_ k: Double) -> [Any] { Self.width(k) }
        let round: [String: Any] = ["line-join": "round", "line-cap": "round"]
        let sel: [Any] = ["==", ["get", "s"], 1]
        let alt: [Any] = ["==", ["get", "s"], 0]
        let knownSurface: [Any] = ["all", sel, ["!", ["has", "k"]]]
        func kind(_ k: NavSurfaceKind) -> [Any] { ["all", sel, ["==", ["get", "k"], k.rawValue]] }
        /* Asphalt (and routes without surface data) keep the classic solid blue line. */
        let asphalt: [Any] = ["any", knownSurface, kind(.paved)]
        let gridSnap: [Any] = ["all", sel, ["==", ["get", "k"], NavSurfaceKind.gridSnap.rawValue]]
        let shaftFilter: [Any] = ["==", ["get", "t"], "s"]
        let headFilter: [Any] = ["==", ["get", "t"], "h"]
        let layers: [[String: Any]] = [
            ["id": "sary-nav-alt-casing", "type": "line", "source": Self.source, "filter": alt, "layout": round,
             "paint": ["line-color": "#1b2a44", "line-width": width(9), "line-opacity": 0.55, "line-emissive-strength": 1] as [String: Any]],
            ["id": "sary-nav-alt", "type": "line", "source": Self.source, "filter": alt, "layout": round,
             "paint": ["line-color": "#9db8e6", "line-width": width(6), "line-opacity": 0.9, "line-emissive-strength": 1] as [String: Any]],
            /* Under the whole chosen route, whatever its surface: a dark soft edge on light sand. */
            ["id": Self.haloLayer, "type": "line", "source": Self.source, "filter": sel, "layout": round,
             "paint": ["line-color": Self.haloColor, "line-width": width(15.5), "line-opacity": Self.haloOpacity,
                       "line-blur": ["interpolate", ["linear"], ["zoom"], 10, 1, 16, 2.5] as [Any],
                       "line-occlusion-opacity": 0.5, "line-emissive-strength": 1] as [String: Any]],
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
             "paint": ["line-color": SurfaceStyle.terrainEdge, "line-width": width(9), "line-opacity": 0.6,
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
            /* The next turn: a white arrow along the route through the maneuver (dark edge for sand,
               white body for night), on top of every surface style. */
            ["id": "sary-nav-maneuver-casing", "type": "line", "source": Self.maneuverSource, "filter": shaftFilter,
             "layout": round,
             "paint": ["line-color": "#0B1220", "line-width": width(7.5), "line-opacity": 0.85,
                       "line-occlusion-opacity": 0.6, "line-emissive-strength": 1] as [String: Any]],
            ["id": "sary-nav-maneuver", "type": "line", "source": Self.maneuverSource, "filter": shaftFilter,
             "layout": round,
             "paint": ["line-color": "#FFFFFF", "line-width": width(4.5), "line-occlusion-opacity": 0.6,
                       "line-emissive-strength": 1] as [String: Any]],
            ["id": "sary-nav-maneuver-head", "type": "symbol", "source": Self.maneuverSource, "filter": headFilter,
             "layout": ["icon-image": Self.maneuverHeadImage, "icon-rotate": ["get", "b"] as [Any],
                        "icon-rotation-alignment": "map", "icon-pitch-alignment": "map",
                        "icon-allow-overlap": true, "icon-ignore-placement": true,
                        "icon-size": ["interpolate", ["linear"], ["zoom"], 12, 0.5, 15, 0.75, 17, 1.0, 19, 1.25] as [Any]] as [String: Any],
             "paint": ["icon-emissive-strength": 1] as [String: Any]],
        ]
        for l in layers { try? m.addLayer(with: l, layerPosition: pos) }
    }

    /// The arrowhead at the end of the turn arrow: white, dark edge, pointing north (the
    /// symbol layer turns it by the last segment's bearing, aligned to the map).
    static func arrowHead() -> UIImage {
        let s: CGFloat = 40
        return UIGraphicsImageRenderer(size: CGSize(width: s, height: s)).image { _ in
            let p = UIBezierPath()
            p.move(to: CGPoint(x: s / 2, y: 3))
            p.addLine(to: CGPoint(x: s - 4, y: s - 7))
            p.addLine(to: CGPoint(x: s / 2, y: s - 14))
            p.addLine(to: CGPoint(x: 4, y: s - 7))
            p.close()
            p.lineJoinStyle = .round
            p.lineWidth = 4
            UIColor(red: 0.04, green: 0.07, blue: 0.13, alpha: 0.9).setStroke()
            p.stroke()
            UIColor.white.setFill()
            p.fill()
        }
    }

    private func draw() {
        guard styleReady, let map else { return }
        let m: MapboxMap = map.mapboxMap
        if !m.layerExists(withId: "sary-nav-main") {
            addLayers()
            drawnSources = nil
        }
        let before = drawnSources
        let changes = NavSourceChanges.between(drawn: drawnSources, next: drawing)
        drawnSources = drawing
        let reveal = NavRouteReveal.kind(previous: revealedKey, next: drawing.revealKey,
                                         wasGuiding: revealedGuiding, isGuiding: drawing.guidanceActive)
        revealedKey = drawing.revealKey
        revealedGuiding = drawing.guidanceActive
        if changes.routes { drawRoutes(m) }
        if reveal != .none { revealRoute(reveal, m) }
        if changes.maneuver, NavRouteReveal.maneuverFades(previous: before?.maneuver, next: drawing.maneuver, reduceMotion: theme.reduceMotion) {
            fadeIn(Self.maneuverFades, ms: Self.maneuverFadeMs, m)
        }
        if changes.offRoad {
            var off: [Feature] = []
            if let o = drawing.offRoad, o.count >= 2 { off.append(Feature(geometry: .lineString(LineString(o.map(\.coordinate))))) }
            m.updateGeoJSONSource(withId: Self.offSource, geoJSON: .featureCollection(FeatureCollection(features: off)))
        }
        if changes.maneuver {
            m.updateGeoJSONSource(withId: Self.maneuverSource, geoJSON: .featureCollection(FeatureCollection(features: maneuverFeatures())))
        }
        placeTarget()
        placeLabels()
    }

    /// A new route: the chosen line fades in; a reroute also darkens the halo for a moment.
    private func revealRoute(_ kind: NavRouteReveal, _ m: MapboxMap) {
        let ms = NavRouteReveal.fadeMs(kind, reduceMotion: theme.reduceMotion)
        guard ms > 0 else { return }
        let reroute = kind == .reroute
        fadeIn(Self.routeFades, ms: ms, m, haloPeak: reroute ? NavRouteReveal.rerouteHaloOpacity : nil)
        guard reroute else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.fadeHopS + NavRouteReveal.rerouteHoldS) { [weak self] in
            guard let m = self?.map?.mapboxMap, m.layerExists(withId: Self.haloLayer) else { return }
            try? m.setLayerProperty(for: Self.haloLayer, property: "line-opacity-transition", value: ["duration": 600, "delay": 0])
            try? m.setLayerProperty(for: Self.haloLayer, property: "line-opacity", value: Self.haloOpacity)
        }
    }

    /// Long enough for the map to draw one frame at 0 before the fade starts (a 0 and its rest value
    /// set before the same frame would cancel out).
    static let fadeHopS = 0.05

    /// Two writes per property: to 0 at once, then (a frame later) back to rest with the style's own
    /// `-transition`, which Mapbox animates on its render thread. `haloPeak`: the halo rests there
    /// until `revealRoute` settles it.
    private func fadeIn(_ fades: [Fade], ms: Int, _ m: MapboxMap, haloPeak: Double? = nil) {
        for f in fades where m.layerExists(withId: f.layer) {
            try? m.setLayerProperty(for: f.layer, property: f.property + "-transition", value: ["duration": 0, "delay": 0])
            try? m.setLayerProperty(for: f.layer, property: f.property, value: 0.0)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.fadeHopS) { [weak self] in
            guard let m = self?.map?.mapboxMap else { return }
            for f in fades where m.layerExists(withId: f.layer) {
                let rest = f.layer == Self.haloLayer ? (haloPeak ?? f.rest) : f.rest
                try? m.setLayerProperty(for: f.layer, property: f.property + "-transition", value: ["duration": ms, "delay": 0])
                try? m.setLayerProperty(for: f.layer, property: f.property, value: rest)
            }
        }
    }

    private func drawRoutes(_ m: MapboxMap) {
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
    }

    /// The turn arrow's shaft and its head (turned by the last segment's bearing).
    private func maneuverFeatures() -> [Feature] {
        guard let shaft = drawing.maneuver, shaft.count >= 2, let end = shaft.last,
              let b = NavManeuverArrow.headBearing(shaft) else { return [] }
        var line = Feature(geometry: .lineString(LineString(shaft.map(\.coordinate))))
        line.properties = ["t": .string("s")]
        var head = Feature(geometry: .point(Point(end.coordinate)))
        head.properties = ["t": .string("h"), "b": .number(b)]
        return [line, head]
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

/// The next turn on the map (pure, unit-tested): a short stretch of the route itself through
/// the maneuver point, drawn as a white arrow. Build 36 had nothing on the line at a turn, so
/// at a glance over desert imagery the turn was only in the banner.
enum NavManeuverArrow {
    /// Metres of route drawn before / after the maneuver point.
    static let beforeM = 40.0
    static let afterM = 30.0
    /// A maneuver further than this from the route line is not drawn (stale / other route).
    static let maxOffsetM = 50.0

    /// Turns worth an arrow; «تابع» / a new road name / depart / arrive are not.
    static func shows(_ m: NavManeuver) -> Bool {
        switch m.kind {
        case .depart, .arrive, .continue, .newName, .notification: return false
        case .roundabout, .exitRoundabout: return true
        case .turn, .merge, .onRamp, .offRamp, .fork, .endOfRoad, .useLane:
            return m.direction != nil && m.direction != .straight
        }
    }

    /// The route from `before` m ahead of `at` (projected onto the line) to `after` m past it;
    /// nil when the point is off the route or there is nothing after it to point along.
    static func shaft(_ route: [LngLat], at: LngLat, before: Double = beforeM, after: Double = afterM) -> [LngLat]? {
        guard route.count >= 2 else { return nil }
        let kx = cos(at.lat * .pi / 180) * 111_320, ky = 110_540.0
        func xy(_ p: LngLat) -> (Double, Double) { ((p.lng - at.lng) * kx, (p.lat - at.lat) * ky) }
        var cum = [0.0]
        for i in 1..<route.count { cum.append(cum[i - 1] + Vehicle.distanceMeters(route[i - 1], route[i])) }
        var best: (d: Double, s: Double)?
        for i in 1..<route.count {
            let (ax, ay) = xy(route[i - 1]), (bx, by) = xy(route[i])
            let dx = bx - ax, dy = by - ay
            let len2 = dx * dx + dy * dy
            let t = len2 > 0 ? min(1, max(0, -(ax * dx + ay * dy) / len2)) : 0
            let px = ax + t * dx, py = ay + t * dy
            let d = (px * px + py * py).squareRoot()
            if best == nil || d < best!.d { best = (d, cum[i - 1] + t * (cum[i] - cum[i - 1])) }
        }
        guard let b = best, b.d <= maxOffsetM, let total = cum.last else { return nil }
        let from = max(0, b.s - before), to = min(total, b.s + after)
        guard to - b.s >= 5, to - from >= 10 else { return nil }
        return slice(route, cum: cum, from: from, to: to)
    }

    /// The part of `route` between two distances along it (`cum`: cumulative metres per vertex).
    static func slice(_ route: [LngLat], cum: [Double], from a: Double, to b: Double) -> [LngLat] {
        func point(_ s: Double) -> LngLat {
            if s <= 0 { return route[0] }
            if let total = cum.last, s >= total { return route[route.count - 1] }
            guard let i = cum.indices.dropFirst().first(where: { cum[$0] >= s }) else { return route[route.count - 1] }
            let seg = cum[i] - cum[i - 1]
            let u = seg > 0 ? (s - cum[i - 1]) / seg : 0
            let p = route[i - 1], q = route[i]
            return LngLat(lng: p.lng + (q.lng - p.lng) * u, lat: p.lat + (q.lat - p.lat) * u)
        }
        var out = [point(a)]
        for i in route.indices where cum[i] > a && cum[i] < b { out.append(route[i]) }
        out.append(point(b))
        return out
    }

    /// Which way the arrowhead points: the bearing of the shaft's last metres.
    static func headBearing(_ shaft: [LngLat]) -> Double? {
        guard let end = shaft.last else { return nil }
        for p in shaft.dropLast().reversed() where Vehicle.distanceMeters(p, end) > 0.5 {
            return Vehicle.bearing(p, end)
        }
        return nil
    }
}
