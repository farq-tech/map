@_spi(Experimental) import MapboxMaps
import Foundation

/// «مسارات البر (OSM)»: desert tracks drawn the way OsmAnd does — clear dashed tan lines
/// with a dark casing, so they read on satellite imagery.
///
/// From Mapbox Streets v8 (OpenStreetMap data), the source the map already loads for
/// road snapping. What v8 gives: `class` track / path / street…, `type` = the OSM highway
/// value, and `surface` reduced to `paved` / `unpaved`. Checked against the live tiles
/// (Tilequery, Riyadh / Nafud / Red Sands, Nov 2026): tracks come as `type: "track"` only —
/// OSM `tracktype` (grade1…5) and the finer surface (sand / gravel / dirt) are NOT in v8.
/// The grade layers stay ready for an OSM-derived source that has them (our own tiles,
/// later); today the plain-track dash and the paved / unpaved colour carry the styling.
enum OffroadTracks {
    static let source = RoadSnap.source
    static let minZoom = 11.0
    static let casingLayer = "sary-osm-tracks-casing"

    /// Dash pattern by OSM tracktype: grade1 (solid, firm) → grade5 (finest dashes, soft).
    static let grades: [(id: String, filter: [Any], dash: [Double]?)] = [
        ("grade1", ["==", ["get", "type"], "track:grade1"], nil),
        ("grade2", ["==", ["get", "type"], "track:grade2"], [5, 1.4]),
        ("grade3", ["==", ["get", "type"], "track:grade3"], [3.2, 1.8]),
        ("grade4", ["==", ["get", "type"], "track:grade4"], [2, 2]),
        ("grade5", ["==", ["get", "type"], "track:grade5"], [1, 2.2]),
        ("track", ["all", ["==", ["get", "class"], "track"], ["!", ["in", "grade", ["to-string", ["get", "type"]]]]], [2.6, 1.8]),
        ("path", ["all", ["==", ["get", "class"], "path"], ["match", ["get", "type"], ["path", "bridleway", "track"], true, false]], [0.8, 1.6]),
        ("unpaved", ["all", ["match", ["get", "class"], ["street", "street_limited", "service", "tertiary", "secondary"], true, false],
                     ["==", ["get", "surface"], "unpaved"]], nil),
    ]

    static var layerIds: [String] { [casingLayer] + grades.map { "sary-osm-tracks-\($0.id)" } }

    /// Every feature these layers draw.
    static var anyFilter: [Any] { ["any"] + grades.map(\.filter) }

    /// Unpaved: tan; paved: pale; unknown: a darker sand.
    static var color: [Any] {
        ["match", ["get", "surface"], "unpaved", "#d9ad6c", "paved", "#efe6d2", "#c99a5a"]
    }

    static func width(_ k: Double) -> [Any] {
        ["interpolate", ["linear"], ["zoom"], 11, 0.7 * k, 14, 1.5 * k, 17, 2.8 * k, 20, 4 * k]
    }

    /// Add (or re-add after a style load) under `below`. Hidden until `setVisible`.
    static func add(_ m: MapboxMap, below: String?, visible: Bool) {
        guard m.sourceExists(withId: source) else { return }
        for id in layerIds where m.layerExists(withId: id) { try? m.removeLayer(withId: id) }
        let pos: LayerPosition? = below.map { .below($0) }
        let vis = visible ? "visible" : "none"
        let round: [String: Any] = ["line-join": "round", "line-cap": "round", "visibility": vis]
        FXLog.add(m, [
            "id": casingLayer, "type": "line", "source": source, "source-layer": "road", "minzoom": minZoom,
            "filter": anyFilter, "layout": round,
            "paint": ["line-color": "#2e1e0f", "line-width": casingWidth,
                      "line-opacity": ["interpolate", ["linear"], ["zoom"], 11, 0.35, 14, 0.6] as [Any],
                      "line-emissive-strength": 1] as [String: Any],
        ], layerPosition: pos)
        for g in grades {
            var layout: [String: Any] = ["line-join": "round", "visibility": vis]
            layout["line-cap"] = g.dash == nil ? "round" : "butt"
            var paint: [String: Any] = ["line-color": color, "line-width": width(g.id == "path" ? 0.75 : 1),
                                        "line-opacity": ["interpolate", ["linear"], ["zoom"], 11, 0.6, 14, 0.95] as [Any],
                                        "line-emissive-strength": 1]
            if let d = g.dash { paint["line-dasharray"] = d }
            FXLog.add(m, [
                "id": "sary-osm-tracks-\(g.id)", "type": "line", "source": source, "source-layer": "road", "minzoom": minZoom,
                "filter": g.filter, "layout": layout, "paint": paint,
            ], layerPosition: pos)
        }
    }

    /// Casing: the line plus ~1.5 px each side.
    static var casingWidth: [Any] {
        ["interpolate", ["linear"], ["zoom"], 11, 2.4, 14, 4.2, 17, 6.4, 20, 8.5]
    }

    static func setVisible(_ m: MapboxMap, _ on: Bool) {
        for id in layerIds where m.layerExists(withId: id) {
            try? m.setLayerProperty(for: id, property: "visibility", value: on ? "visible" : "none")
        }
    }

    /// Shown in exploration and while my car is off-road, if the person left it on.
    static func visible(pref: Bool, exploring: Bool, offRoad: Bool) -> Bool { pref && (exploring || offRoad) }

    /// Which style group a Streets v8 road feature falls in (mirrors the layer filters; tests).
    static func group(class cls: String, type: String?, surface: String?) -> String? {
        let t = type ?? ""
        if t.hasPrefix("track:grade"), let g = t.split(separator: ":").last { return String(g) }
        if cls == "track" { return "track" }
        if cls == "path", ["path", "bridleway", "track"].contains(t) { return "path" }
        if ["street", "street_limited", "service", "tertiary", "secondary"].contains(cls), surface == "unpaved" { return "unpaved" }
        return nil
    }

    static let attribution = "© OpenStreetMap contributors"
}
