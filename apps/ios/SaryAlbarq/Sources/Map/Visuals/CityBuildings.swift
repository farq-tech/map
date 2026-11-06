import Foundation

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
