import Foundation
import MapboxMaps

/// Farq's own map layers over the satellite imagery (`apps/tiles` in this repository): streets from
/// OpenStreetMap rebuilt every week (Mapbox's lag months behind in the Kingdom), and Farq Atlas places
/// and buildings.
///
/// Safe by default: the app keeps Mapbox's roads until `check()` has read the server's TileJSON. A build
/// without `FARQ_TILES_URL`, or a server that is down, is exactly the map as before. Once it answered,
/// Mapbox's roads and road names are hidden on the satellite layer and ours are drawn instead, road
/// snapping follows our streets, and the city buildings come from Atlas when the archive carries them.
enum FarqTiles {
    static let source = "farq"
    static let roadsLayer = "roads"
    static let placesLayer = "places"
    static let buildingsLayer = "buildings"

    /// Layer ids (all ours start with «farq-»).
    static let placeCircleId = "farq-places"
    static let placeLabelId = "farq-place-labels"
    static let roadLabelId = "farq-road-labels"
    static let roadClasses = ["path", "track", "service", "minor", "tertiary", "secondary", "primary", "trunk", "motorway"]

    /// What the server said: its TileJSON URL and which layers the archive has.
    struct Status: Equatable {
        var tileJSON: String
        var layers: Set<String>
        var builtAt: String?
    }

    /// Posted (main thread) when `check()` succeeded: a map that is already showing switches over.
    static let didBecomeAvailable = Notification.Name("sary.farqTiles.available")

    /// nil until `check()` succeeded; the map draws nothing of ours before that.
    private(set) static var status: Status?
    static var available: Bool { status != nil }
    static var hasBuildings: Bool { status?.layers.contains(buildingsLayer) == true }
    static var hasPlaces: Bool { status?.layers.contains(placesLayer) == true }

    /// `FarqTilesURL` in Info.plist (from `FARQ_TILES_URL` in Config/*.xcconfig): the TileJSON, e.g.
    /// `https://tiles.example.sa/farq.json`. Only https.
    static var configuredURL: String? {
        let raw = (Bundle.main.object(forInfoDictionaryKey: "FarqTilesURL") as? String)?.trimmingCharacters(in: .whitespaces)
        guard let raw, !raw.isEmpty, !raw.hasPrefix("$("), let u = URL(string: raw), u.scheme == "https", u.host != nil else { return nil }
        return raw
    }

    /// The TileJSON's layer ids, or nil when it is not a usable TileJSON.
    static func parse(_ data: Data) -> (layers: Set<String>, builtAt: String?)? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tiles = obj["tiles"] as? [String], !tiles.isEmpty,
              let vl = obj["vector_layers"] as? [[String: Any]] else { return nil }
        let ids = Set(vl.compactMap { $0["id"] as? String })
        guard ids.contains(roadsLayer) else { return nil }
        return (ids, obj["version"] as? String)
    }

    typealias Fetch = (URLRequest) async throws -> (Data, Int)

    /// Read the TileJSON once (at launch). Failure leaves `status` nil: Mapbox's roads stay.
    @discardableResult
    static func check(url: String? = FarqTiles.configuredURL,
                      fetch: Fetch = { req in
                          let (d, r) = try await URLSession.shared.data(for: req)
                          return (d, (r as? HTTPURLResponse)?.statusCode ?? 0)
                      }) async -> Status? {
        guard let url, let u = URL(string: url) else { return nil }
        var req = URLRequest(url: u, timeoutInterval: 8)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let res = try? await fetch(req), (200..<300).contains(res.1), let parsed = parse(res.0) else { return nil }
        let s = Status(tileJSON: url, layers: parsed.layers, builtAt: parsed.builtAt)
        await MainActor.run {
            status = s
            NotificationCenter.default.post(name: didBecomeAvailable, object: nil)
        }
        return s
    }

    #if DEBUG
    static func setStatusForTests(_ s: Status?) { status = s }
    #endif

    // MARK: style

    /// Our layers on a freshly loaded style. Only on the satellite layer: «عادي» and «طبوغرافي» are
    /// Mapbox's vector maps, where its own streets are the map itself.
    static func install(_ m: MapboxMap, layer: MapLayer, labels: SatelliteLabels) {
        guard let s = status, layer == .satellite else { return }
        if !m.sourceExists(withId: source) {
            try? m.addSource(withId: source, properties: ["type": "vector", "url": s.tileJSON])
        }
        /* Mapbox's own (older) streets and their names go; ours replace them. */
        try? m.setStyleImportConfigProperty(for: "basemap", config: "showRoadsAndTransit", value: false)
        try? m.setStyleImportConfigProperty(for: "basemap", config: "showRoadLabels", value: false)
        for l in roadLayers() where !m.layerExists(withId: l["id"] as! String) {
            try? m.addLayer(with: l, layerPosition: nil)
        }
        if !m.layerExists(withId: roadLabelId) { try? m.addLayer(with: roadLabelLayer(), layerPosition: nil) }
        if s.layers.contains(placesLayer) {
            if !m.layerExists(withId: placeCircleId) { try? m.addLayer(with: placeCircleLayer(), layerPosition: nil) }
            if !m.layerExists(withId: placeLabelId) { try? m.addLayer(with: placeLabelLayer(), layerPosition: nil) }
        }
        applyLabels(m, labels)
    }

    /// Our street and place names follow the same «labels» rule as the style's (`SatelliteLabels`):
    /// road names while driving, nothing over a recorded track.
    static func applyLabels(_ m: MapboxMap, _ labels: SatelliteLabels) {
        guard available else { return }
        try? m.setStyleImportConfigProperty(for: "basemap", config: "showRoadLabels", value: false)
        let roads = labels == .driving ? "visible" : "none"
        let places = labels == .clean ? "none" : "visible"
        if m.layerExists(withId: roadLabelId) { try? m.setLayerProperty(for: roadLabelId, property: "visibility", value: roads) }
        for id in [placeCircleId, placeLabelId] where m.layerExists(withId: id) {
            try? m.setLayerProperty(for: id, property: "visibility", value: places)
        }
    }

    static func width(_ cls: String) -> [Any] {
        let stops: (Double, Double, Double) // (from zoom, width there, width at z18)
        switch cls {
        case "motorway": stops = (5, 1.2, 26)
        case "trunk": stops = (5, 1.0, 22)
        case "primary": stops = (7, 0.8, 18)
        case "secondary": stops = (9, 0.6, 15)
        case "tertiary": stops = (10, 0.5, 13)
        case "minor": stops = (12, 0.4, 10)
        case "service": stops = (14, 0.3, 6)
        case "track": stops = (11, 0.4, 4)
        default: stops = (14, 0.3, 3)
        }
        return ["interpolate", ["exponential", 1.5], ["zoom"], stops.0, stops.1, 18, stops.2]
    }

    static func color(_ cls: String) -> String {
        switch cls {
        case "motorway": return "hsl(28, 85%, 66%)"
        case "trunk": return "hsl(40, 85%, 66%)"
        case "primary": return "hsl(46, 95%, 76%)"
        case "track": return "hsl(36, 45%, 62%)"
        case "path", "service": return "hsl(0, 0%, 85%)"
        default: return "hsl(0, 0%, 98%)"
        }
    }

    /// One line layer per class, minor first so major roads draw on top; tracks dashed (desert).
    static func roadLayers() -> [[String: Any]] {
        roadClasses.map { cls in
            var paint: [String: Any] = [
                "line-color": color(cls),
                "line-width": width(cls),
                /* Over imagery a road must read without hiding it: strong in town, softer far out. */
                "line-opacity": ["interpolate", ["linear"], ["zoom"], 5, 0.75, 14, 0.9],
            ]
            if cls == "track" { paint["line-dasharray"] = [2, 1.5] }
            return [
                "id": "farq-road-\(cls)", "type": "line", "source": source, "source-layer": roadsLayer, "slot": "middle",
                "filter": ["==", ["get", "class"], cls],
                "layout": ["line-cap": "round", "line-join": "round"],
                "paint": paint,
            ]
        }
    }

    static func roadLabelLayer() -> [String: Any] {
        [
            "id": roadLabelId, "type": "symbol", "source": source, "source-layer": roadsLayer, "slot": "top", "minzoom": 12,
            "filter": ["any", ["has", "name_ar"], ["has", "name_en"]],
            "layout": [
                "symbol-placement": "line",
                "text-field": ["coalesce", ["get", "name_ar"], ["get", "name_en"]],
                "text-size": ["interpolate", ["linear"], ["zoom"], 12, 10, 18, 14],
                "text-max-angle": 30,
                "symbol-sort-key": ["-", 10, ["coalesce", ["get", "rank"], 0]],
            ] as [String: Any],
            "paint": ["text-color": "hsl(0, 0%, 100%)", "text-halo-color": "hsla(0, 0%, 0%, 0.85)", "text-halo-width": 1.4],
        ]
    }

    static func placeCircleLayer() -> [String: Any] {
        [
            "id": placeCircleId, "type": "circle", "source": source, "source-layer": placesLayer, "slot": "top", "minzoom": 15,
            "paint": [
                "circle-radius": ["interpolate", ["linear"], ["zoom"], 15, 3, 18, 6],
                "circle-color": ["case", ["boolean", ["get", "temp_closed"], false], "hsl(0, 0%, 60%)", "hsl(203, 90%, 58%)"],
                "circle-stroke-color": "hsl(0, 0%, 100%)", "circle-stroke-width": 1,
            ] as [String: Any],
        ]
    }

    static func placeLabelLayer() -> [String: Any] {
        [
            "id": placeLabelId, "type": "symbol", "source": source, "source-layer": placesLayer, "slot": "top", "minzoom": 16,
            "layout": [
                "text-field": ["coalesce", ["get", "name_ar"], ["get", "name_en"]],
                "text-size": 11, "text-offset": [0, 1.0], "text-anchor": "top", "text-max-width": 8,
                "text-optional": true,
            ] as [String: Any],
            "paint": ["text-color": "hsl(203, 100%, 90%)", "text-halo-color": "hsla(0, 0%, 0%, 0.85)", "text-halo-width": 1.2],
        ]
    }

    // MARK: road snapping (RoadSnap)

    /// Drivable classes in our roads (tracks are off-road: a car in the desert stays where GPS put it).
    static let drivable = ["motorway", "trunk", "primary", "secondary", "tertiary", "minor", "service"]
    static var drivableFilter: [Any] { ["match", ["get", "class"], drivable, true, false] }

    /// Where the road probe reads streets from: ours once the server answered, else Mapbox Streets.
    static var probe: (source: String, url: String, sourceLayer: String, filter: [Any]) {
        if let s = status { return (source, s.tileJSON, roadsLayer, drivableFilter) }
        return (RoadSnap.source, "mapbox://mapbox.mapbox-streets-v8", "road", RoadSnap.drivableFilter)
    }

    // MARK: buildings (MapVisualsDirector)

    /// Atlas buildings for the city 3D layer, when the archive carries them; else Mapbox Streets'.
    static var buildingSource: (source: String, url: String, sourceLayer: String, atlas: Bool) {
        if let s = status, s.layers.contains(buildingsLayer) { return (source, s.tileJSON, buildingsLayer, true) }
        return ("wow-buildings-streets", "mapbox://mapbox.mapbox-streets-v8", "building", false)
    }
}
