import MapboxMaps
import UIKit

/// What the CarPlay map draws, as plain values (built by `CarPlayCoordinator`).
struct CarPlayMapContent: Equatable {
    var cars: [CarPlayMapCar] = []
    /// My trail: recorded runs (solid) and unrecorded stretches (dashed).
    var trailSolid: [[LngLat]] = []
    var trailGaps: [[LngLat]] = []
    var start: LngLat?
    var rally: (position: LngLat, label: String)?
    var destination: (position: LngLat, label: String)?
    /// A road route from the turn-by-turn provider, when one is active.
    var routeLine: [LngLat] = []
    /// «طريق العودة» is on: the trail is drawn stronger.
    var highlightTrail = false

    static func == (a: CarPlayMapContent, b: CarPlayMapContent) -> Bool {
        a.cars == b.cars && a.trailSolid == b.trailSolid && a.trailGaps == b.trailGaps && a.start == b.start
            && a.rally?.position == b.rally?.position && a.rally?.label == b.rally?.label
            && a.destination?.position == b.destination?.position && a.destination?.label == b.destination?.label
            && a.routeLine == b.routeLine && a.highlightTrail == b.highlightTrail
    }
}

/// The Mapbox map inside the CarPlay window (the root view controller of the `CPWindow`).
/// Heading-up while following my car; the camera padding is the CarPlay safe area, so my
/// car is never under the nav bar, the map buttons or the guidance card.
final class CarPlayMapViewController: UIViewController {
    private(set) var mapView: MapView!
    private var styleReady = false
    private var content = CarPlayMapContent()
    private var cancelables = Set<AnyCancelable>()
    private var light: SunLight.Preset?
    /// Night from CarPlay's own appearance (the car's headlights / its setting).
    var night = false { didSet { if night != oldValue { applyLight() } } }
    /// «موقعي»: the camera follows my car, heading-up.
    private(set) var following = true
    var zoom: CGFloat = 14.5

    private static let src = (cars: "cp-cars", trail: "cp-trail", points: "cp-points", route: "cp-route")

    override func viewDidLoad() {
        super.viewDidLoad()
        let camera = CameraOptions(center: CLLocationCoordinate2D(latitude: 24.7136, longitude: 46.6753), zoom: zoom, bearing: 0, pitch: 0)
        let map = MapView(frame: view.bounds, mapInitOptions: MapInitOptions(cameraOptions: camera, styleURI: ArabicBasemap.cachedJSON == nil ? OutingMapboxView.styleURI : nil))
        if let json = ArabicBasemap.cachedJSON { map.mapboxMap.loadStyle(json) }
        map.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        map.ornaments.options.scaleBar.visibility = .hidden
        map.ornaments.options.compass.visibility = .hidden
        /* CarPlay: no touches reach the map except through the template (pan / zoom buttons). */
        map.gestures.options.panEnabled = false
        map.gestures.options.pinchEnabled = false
        map.gestures.options.rotateEnabled = false
        map.gestures.options.pitchEnabled = false
        map.accessibilityIdentifier = "carplay.map"
        view.addSubview(map)
        mapView = map
        map.mapboxMap.onStyleLoaded.observe { [weak self] _ in self?.styleLoaded() }.store(in: &cancelables)
        ArabicBasemap.load { json in if let json { map.mapboxMap.loadStyle(json) } }
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        if following { followNow(animated: false) }
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        night = traitCollection.userInterfaceStyle == .dark
    }

    /// The camera keeps my car (and the trip target) clear of CarPlay's chrome.
    private var padding: UIEdgeInsets {
        let s = view.safeAreaInsets
        return UIEdgeInsets(top: s.top + 24, left: s.left + 24, bottom: s.bottom + 24, right: s.right + 24)
    }

    // MARK: content

    func show(_ c: CarPlayMapContent) {
        let changed = c != content
        content = c
        if changed { draw() }
        if following { followNow(animated: true) }
        applyLight()
    }

    private func styleLoaded() {
        styleReady = true
        light = nil
        addLayers()
        draw()
        applyLight()
    }

    private func applyLight() {
        guard styleReady, let map = mapView else { return }
        let at = content.cars.first(where: \.isMe)?.position
        let sun = at.map { SunLight.preset(Date(), lat: $0.lat, lng: $0.lng) } ?? .day
        let preset: SunLight.Preset = night ? .night : (sun == .night ? .dusk : sun)
        guard preset != light else { return }
        light = preset
        try? map.mapboxMap.setStyleImportConfigProperty(for: "basemap", config: "lightPreset", value: preset.rawValue)
    }

    private func addLayers() {
        guard let m = mapView?.mapboxMap else { return }
        for id in [Self.src.route, Self.src.trail, Self.src.points, Self.src.cars] where !m.sourceExists(withId: id) {
            var s = GeoJSONSource(id: id)
            s.data = .featureCollection(FeatureCollection(features: []))
            try? m.addSource(s)
        }
        if let arrow = UIImage(systemName: "location.north.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 30, weight: .bold))?
            .withTintColor(.white, renderingMode: .alwaysOriginal) {
            try? m.addImage(arrow, id: "cp-arrow", sdf: true)
        }
        let layers: [[String: Any]] = [
            ["id": "cp-route", "type": "line", "source": Self.src.route,
             "layout": ["line-cap": "round", "line-join": "round"],
             "paint": ["line-color": "#2F80ED", "line-width": 8, "line-opacity": 0.9]],
            ["id": "cp-trail-casing", "type": "line", "source": Self.src.trail, "filter": ["==", ["get", "k"], "s"],
             "layout": ["line-cap": "round", "line-join": "round"],
             "paint": ["line-color": "#04342F", "line-width": ["get", "w2"], "line-opacity": 0.7]],
            ["id": "cp-trail", "type": "line", "source": Self.src.trail, "filter": ["==", ["get", "k"], "s"],
             "layout": ["line-cap": "round", "line-join": "round"],
             "paint": ["line-color": ["get", "c"], "line-width": ["get", "w"]]],
            ["id": "cp-trail-gap", "type": "line", "source": Self.src.trail, "filter": ["==", ["get", "k"], "g"],
             "paint": ["line-color": ["get", "c"], "line-width": 4, "line-dasharray": [1.5, 1.5], "line-opacity": 0.85]],
            ["id": "cp-points", "type": "circle", "source": Self.src.points,
             "paint": ["circle-radius": 10, "circle-color": ["get", "c"], "circle-stroke-color": "#FFFFFF", "circle-stroke-width": 3]],
            ["id": "cp-points-label", "type": "symbol", "source": Self.src.points,
             "layout": ["text-field": ["get", "label"], "text-size": 17, "text-offset": [0, 1.4], "text-anchor": "top", "text-allow-overlap": true],
             "paint": ["text-color": "#FFFFFF", "text-halo-color": "#04342F", "text-halo-width": 2]],
            ["id": "cp-cars", "type": "circle", "source": Self.src.cars,
             "paint": ["circle-radius": ["case", ["get", "me"], 13, 11], "circle-color": ["get", "c"],
                       "circle-opacity": ["case", ["get", "live"], 1, 0.45],
                       "circle-stroke-color": ["case", ["get", "live"], "#FFFFFF", "#9AA3A8"], "circle-stroke-width": 3,
                       "circle-stroke-opacity": ["case", ["get", "live"], 1, 0.6]]],
            ["id": "cp-cars-arrow", "type": "symbol", "source": Self.src.cars, "filter": ["has", "h"],
             "layout": ["icon-image": "cp-arrow", "icon-size": 0.5, "icon-rotate": ["get", "h"], "icon-rotation-alignment": "map",
                        "icon-allow-overlap": true, "icon-ignore-placement": true],
             "paint": ["icon-color": "#FFFFFF"]],
            ["id": "cp-cars-label", "type": "symbol", "source": Self.src.cars,
             "layout": ["text-field": ["get", "label"], "text-size": 16, "text-offset": [0, 1.5], "text-anchor": "top",
                        "text-allow-overlap": false, "symbol-sort-key": ["case", ["get", "me"], 0, 1]],
             "paint": ["text-color": "#FFFFFF", "text-halo-color": "#04342F", "text-halo-width": 2.5,
                       "text-opacity": ["case", ["get", "live"], 1, 0.75]]],
        ]
        for var l in layers {
            guard let id = l["id"] as? String, !m.layerExists(withId: id) else { continue }
            /* The Standard style lights custom layers too: keep ours at full colour, day and night. */
            var paint = l["paint"] as? [String: Any] ?? [:]
            switch l["type"] as? String {
            case "line": paint["line-emissive-strength"] = 1
            case "circle": paint["circle-emissive-strength"] = 1
            case "symbol": paint["icon-emissive-strength"] = 1; paint["text-emissive-strength"] = 1
            default: break
            }
            l["paint"] = paint
            try? m.addLayer(with: l, layerPosition: nil)
        }
    }

    private func draw() {
        guard styleReady, let m = mapView?.mapboxMap else { return }
        let myColor = "#" + Vehicle.hex(content.cars.first(where: \.isMe)?.color ?? Vehicle.mySpotHex)
        var trail: [Feature] = []
        let w: Double = content.highlightTrail ? 8 : 5
        for run in content.trailSolid where run.count >= 2 {
            var f = Feature(geometry: .lineString(LineString(run.map(\.coordinate))))
            f.properties = ["k": .string("s"), "c": .string(myColor), "w": .number(w), "w2": .number(w + 4)]
            trail.append(f)
        }
        for g in content.trailGaps where g.count >= 2 {
            var f = Feature(geometry: .lineString(LineString(g.map(\.coordinate))))
            f.properties = ["k": .string("g"), "c": .string(myColor)]
            trail.append(f)
        }
        m.updateGeoJSONSource(withId: Self.src.trail, geoJSON: .featureCollection(FeatureCollection(features: trail)))

        var pts: [Feature] = []
        func pin(_ p: LngLat, _ label: String, _ color: String) {
            var f = Feature(geometry: .point(Point(p.coordinate)))
            f.properties = ["label": .string(label), "c": .string(color)]
            pts.append(f)
        }
        if let s = content.start { pin(s, "نقطة البداية", "#18A66A") }
        if let r = content.rally { pin(r.position, r.label, "#FFCA3A") }
        if let d = content.destination { pin(d.position, d.label, "#E5484D") }
        m.updateGeoJSONSource(withId: Self.src.points, geoJSON: .featureCollection(FeatureCollection(features: pts)))

        let route = content.routeLine.count >= 2 ? [Feature(geometry: .lineString(LineString(content.routeLine.map(\.coordinate))))] : []
        m.updateGeoJSONSource(withId: Self.src.route, geoJSON: .featureCollection(FeatureCollection(features: route)))

        /* Me last, so my car draws on top. */
        let cars = content.cars.sorted { !$0.isMe && $1.isMe }.map { c -> Feature in
            var f = Feature(geometry: .point(Point(c.position.coordinate)))
            var p: JSONObject = ["label": .string(c.label), "c": .string("#" + Vehicle.hex(c.isMe ? Vehicle.mySpotHex : c.color)),
                                 "live": .boolean(c.live), "me": .boolean(c.isMe)]
            if let h = c.heading { p["h"] = .number(h) }
            f.properties = p
            return f
        }
        m.updateGeoJSONSource(withId: Self.src.cars, geoJSON: .featureCollection(FeatureCollection(features: cars)))
    }

    // MARK: camera

    private var me: CarPlayMapCar? { content.cars.first(where: \.isMe) }

    func follow() {
        following = true
        followNow(animated: true)
    }

    private func followNow(animated: Bool) {
        guard let map = mapView, let me else { return }
        /* Heading-up only with a trusted course (moving); parked, the map keeps its rotation. */
        let bearing = me.heading ?? map.mapboxMap.cameraState.bearing
        let cam = CameraOptions(center: me.position.coordinate, padding: padding, zoom: zoom, bearing: bearing, pitch: 0)
        if animated && !UIAccessibility.isReduceMotionEnabled { map.camera.ease(to: cam, duration: 0.8) } else { map.mapboxMap.setCamera(to: cam) }
    }

    /// «المجموعة»: everyone (and the trip's points) in view, north-up.
    func fitGroup(extra: [LngLat] = []) {
        following = false
        guard let map = mapView else { return }
        let pts = content.cars.map(\.position) + extra
        guard !pts.isEmpty else { return }
        if pts.count == 1 {
            map.camera.ease(to: CameraOptions(center: pts[0].coordinate, padding: padding, zoom: 14, bearing: 0), duration: 0.8)
            return
        }
        if let cam = try? map.mapboxMap.camera(for: pts.map(\.coordinate), camera: CameraOptions(bearing: 0, pitch: 0), coordinatesPadding: padding, maxZoom: 16, offset: nil) {
            map.camera.ease(to: cam, duration: 0.8)
        }
    }

    func zoom(by delta: CGFloat) {
        guard let map = mapView else { return }
        zoom = max(3, min(19, map.mapboxMap.cameraState.zoom + delta))
        map.camera.ease(to: CameraOptions(zoom: zoom), duration: 0.3)
    }

    /// CPMapTemplate panning (buttons or a drag on a touch screen). Stops following.
    func pan(dx: CGFloat, dy: CGFloat, animated: Bool = true) {
        following = false
        guard let map = mapView else { return }
        let c = CGPoint(x: map.bounds.midX + dx, y: map.bounds.midY + dy)
        let coord = map.mapboxMap.coordinate(for: c)
        if animated { map.camera.ease(to: CameraOptions(center: coord), duration: 0.3) } else { map.mapboxMap.setCamera(to: CameraOptions(center: coord)) }
    }

    func center(on p: LngLat) {
        following = false
        mapView?.camera.ease(to: CameraOptions(center: p.coordinate, padding: padding, zoom: max(zoom, 15)), duration: 0.8)
    }
}
