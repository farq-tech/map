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
    var labels: [Label] = []
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
    static let layerIds = ["sary-nav-alt-casing", "sary-nav-alt", "sary-nav-main-casing", "sary-nav-main", "sary-nav-off-casing", "sary-nav-off"]
    static let routeBlue = "#2B7BF0"

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
        let layers: [[String: Any]] = [
            ["id": "sary-nav-alt-casing", "type": "line", "source": Self.source, "filter": alt, "layout": round,
             "paint": ["line-color": "#1b2a44", "line-width": width(9), "line-opacity": 0.55, "line-emissive-strength": 1] as [String: Any]],
            ["id": "sary-nav-alt", "type": "line", "source": Self.source, "filter": alt, "layout": round,
             "paint": ["line-color": "#9db8e6", "line-width": width(6), "line-opacity": 0.9, "line-emissive-strength": 1] as [String: Any]],
            ["id": "sary-nav-main-casing", "type": "line", "source": Self.source, "filter": sel, "layout": round,
             "paint": ["line-color": "#ffffff", "line-width": width(12), "line-occlusion-opacity": 0.8, "line-emissive-strength": 1] as [String: Any]],
            ["id": "sary-nav-main", "type": "line", "source": Self.source, "filter": sel, "layout": round,
             /* Still visible behind 3D buildings (Olaya towers would hide the turn otherwise). */
             "paint": ["line-color": Self.routeBlue, "line-width": width(8), "line-occlusion-opacity": 0.8, "line-emissive-strength": 1] as [String: Any]],
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
        if drawing.target == targetPin?.point, targetPin?.host.rootView.name == drawing.targetName { return }
        targetPin?.annotation.remove()
        targetPin = nil
        guard let p = drawing.target else { return }
        let host = UIHostingController(rootView: NavTargetPin(name: drawing.targetName, theme: theme))
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
            a.allowOverlap = false
            a.priority = l.selected ? 80 : 70
            map.viewAnnotations.add(a)
            labelPins[id] = (l, a, host)
        }
    }

    // MARK: camera

    private func camera(chrome: UIEdgeInsets, me: LngLat?, heading: Double?) {
        guard let map, map.bounds.height > 0, let cam = drawing.camera else { return }
        let reduce = UIAccessibility.isReduceMotionEnabled
        switch cam {
        case let .fit(pts, share):
            guard drawing.cameraKey != lastCameraKey, let b = GroupFraming.bounds(pts) else { return }
            lastCameraKey = drawing.cameraKey
            let coords = [CLLocationCoordinate2D(latitude: b.south, longitude: b.west), CLLocationCoordinate2D(latitude: b.north, longitude: b.east)]
            let bottom = max(chrome.bottom, map.bounds.height * share) + 24
            let pad = UIEdgeInsets(top: chrome.top + 70, left: 50, bottom: bottom, right: 50)
            guard var c = try? map.mapboxMap.camera(for: coords, camera: CameraOptions(padding: .zero, bearing: 0, pitch: 0),
                                                    coordinatesPadding: pad, maxZoom: 16.5, offset: nil) else { return }
            c.padding = nil
            map.camera.ease(to: c, duration: reduce ? 0 : 0.9)
        }
    }
}

/// The target flag at the end of the route.
struct NavTargetPin: View {
    var name: String
    var theme: SaryTheme

    var body: some View {
        let p = theme.palette
        VStack(spacing: 2) {
            Text(name.isEmpty ? "الوجهة" : name)
                .saryText(.caption, weight: .bold)
                .foregroundStyle(p.textPrimary)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(p.chromeOpaque))
                .overlay(Capsule().stroke(Color(rgb: 0x2B7BF0), lineWidth: 2))
            Image(systemName: "flag.circle.fill")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(Color.white, Color(rgb: 0x2B7BF0))
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
                .foregroundStyle(selected ? Color.white : p.textPrimary)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(selected ? Color(rgb: 0x2B7BF0) : p.chromeOpaque))
                .overlay(Capsule().stroke(selected ? Color.white : Color(rgb: 0x9DB8E6), lineWidth: 2))
                .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
        }
        .buttonStyle(.plain)
        .saryTheme(theme)
        .environment(\.layoutDirection, .rightToLeft)
        .accessibilityIdentifier(selected ? "map.navLabel.selected" : "map.navLabel")
    }
}
