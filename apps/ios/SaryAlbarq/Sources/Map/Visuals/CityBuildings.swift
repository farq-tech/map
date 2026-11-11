import Foundation
import MapboxMaps

/// Cities on the satellite map (`MapVisualsDirector.applyBuildings`): neutral 3D buildings from
/// Mapbox Streets' own footprints and heights (OSM), and when to offer «الوضع الواقعي».
///
/// Why not the style's own 3D: Standard Satellite has no 3D buildings or landmarks (its schema has
/// no `show3dObjects`), and Mapbox Standard's 3D landmark models do not cover the Kingdom — its
/// Makkah is the same footprint extrusions, on a vector map instead of the imagery.
enum CityBuildings {
    /// From here in (a city block reads; Mapbox Streets' building layer starts at z13).
    static let minZoom = 14.0
    /// «اعرضها بالوضع الواقعي» from this tilt in a city.
    static let offerPitch = 35.0
    static let offerMinZoom = 13.0
    /// Metres: from five floors up a building leans visibly in an off-nadir photo.
    static let minHeight = 15.0

    /// Tilted over a city, close enough to see it.
    static func offerRealistic(pitch: Double, zoom: Double, urban: Double) -> Bool {
        urban >= 0.5 && pitch >= offerPitch && zoom >= offerMinZoom
    }

    /// The fill-extrusion layer: sand walls (lighter stone for towers), light roofs (the sun lights
    /// the tops, a vertical gradient grounds the walls), soft ambient occlusion where walls meet
    /// the ground, grown in over half a zoom level so nothing pops.
    /// `atlas`: Farq Atlas footprints (`FarqTiles`, layer «buildings»: `height` in metres, no `extrude` /
    /// `underground` flags); otherwise Mapbox Streets' «building» layer.
    static func layer(id: String, source: String, opacity: Double, sourceLayer: String = "building", atlas: Bool = false) -> [String: Any] {
        [
            "id": id,
            "type": "fill-extrusion",
            "source": source,
            "source-layer": sourceLayer,
            "minzoom": minZoom,
            /* Only what stands tall: low-rise blocks barely lean in the photo and read better as imagery
               (as boxes they bury whole districts in sand-coloured slabs). */
            "filter": atlas ? [">=", ["coalesce", ["get", "height"], 0], minHeight] as [Any]
                : ["all", ["==", ["get", "extrude"], "true"], ["==", ["get", "underground"], "false"],
                   [">=", ["coalesce", ["get", "height"], 0], minHeight]] as [Any],
            "layout": ["fill-extrusion-edge-radius": 0.3],
            "paint": [
                "fill-extrusion-color": ["interpolate", ["linear"], ["coalesce", ["get", "height"], 0],
                                         15, "hsl(32, 30%, 74%)", 40, "hsl(35, 26%, 80%)", 150, "hsl(38, 18%, 86%)"],
                "fill-extrusion-height": ["get", "height"],
                "fill-extrusion-base": ["coalesce", ["get", "min_height"], 0],
                "fill-extrusion-opacity": opacity,
                "fill-extrusion-vertical-gradient": true,
                "fill-extrusion-ambient-occlusion-intensity": 0.5,
                "fill-extrusion-ambient-occlusion-radius": 4,
                "fill-extrusion-ambient-occlusion-ground-radius": 6,
                "fill-extrusion-vertical-scale": ["interpolate", ["linear"], ["zoom"], minZoom, 0, minZoom + 0.5, 1],
                "fill-extrusion-cutoff-fade-range": 0.5,
            ] as [String: Any],
        ]
    }
}

/// Every building as a light, flat footprint on the satellite map — the home map and the live map —
/// from a neighbourhood zoom in, so the city reads even looking straight down (the 3D layer above
/// only raises tall buildings, and only when the map is tilted). Farq Atlas footprints when the
/// Farq archive carries them (`FarqTiles.buildingSource`), else Mapbox Streets'.
enum BuildingFootprints {
    static let layerId = "sary-building-footprints"
    /// A city block reads from here; fully drawn half a level later.
    static let minZoom = 14.5

    static func layer(source: String, sourceLayer: String, atlas: Bool) -> [String: Any] {
        var l: [String: Any] = [
            "id": layerId,
            "type": "fill",
            "source": source,
            "source-layer": sourceLayer,
            "minzoom": minZoom,
            /* Under the roads, routes and pins: a hint of the city, never a slab over the imagery. */
            "slot": "bottom",
            "paint": [
                "fill-color": "hsl(36, 45%, 92%)",
                "fill-outline-color": "hsl(32, 28%, 58%)",
                "fill-opacity": ["interpolate", ["linear"], ["zoom"], minZoom, 0, minZoom + 0.5, 0.22, 17, 0.32] as [Any],
                "fill-emissive-strength": 0.6,
            ] as [String: Any],
        ]
        if !atlas { l["filter"] = ["!=", ["get", "underground"], "true"] as [Any] }
        return l
    }

    /// Adds the footprints to a freshly loaded satellite style (idempotent).
    static func install(_ m: MapboxMap) {
        guard !m.layerExists(withId: layerId) else { return }
        let src = FarqTiles.buildingSource
        if !m.sourceExists(withId: src.source) {
            try? m.addSource(withId: src.source, properties: ["type": "vector", "url": src.url])
        }
        try? m.addLayer(with: layer(source: src.source, sourceLayer: src.sourceLayer, atlas: src.atlas), layerPosition: nil)
    }
}
