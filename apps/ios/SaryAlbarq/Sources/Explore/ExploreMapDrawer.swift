@_spi(Experimental) import MapboxMaps
import UIKit

/// What exploration draws on the live map: shown GPX tracks and «أماكني المحفوظة».
struct MapExplore: Equatable {
    struct Track: Equatable {
        var id: String
        var name: String
        var points: [LngLat]
    }

    struct Place: Equatable {
        var id: String
        var name: String
        var position: LngLat
    }

    /// Exploration mode is on (the camera stops keeping the group in view).
    var active = false
    /// EM4: exploration's capabilities are on (`MapCapabilityRules`) without the mode: weather overlays, desert tracks,
    /// the saved places and tracks drawn. Unlike `active` it never stops the camera keeping the group in view.
    var capabilities = false
    var tracks: [Track] = []
    var places: [Place] = []

    /// The shown GPX tracks as routes for the visuals pack (the slope overlay): when exploration is on OR its capabilities are.
    var visualRoutes: [[LngLat]] { (active || capabilities) ? tracks.map(\.points) : [] }
}

/// Draws `MapExplore` as GeoJSON layers; re-added after every style load (layer switch).
final class ExploreMapDrawer {
    static let tracksSource = "sary-explore-tracks"
    static let placesSource = "sary-explore-places"
    static let endsSource = "sary-explore-track-ends"
    static let chevronLayer = "sary-explore-tracks-chevrons"
    static let layerIds = ["sary-explore-tracks-casing", "sary-explore-tracks-line", "sary-explore-track-ends", "sary-explore-places-dot", "sary-explore-places-label"]

    fileprivate(set) var last = MapExplore()
    private var drawn: MapExplore?

    func styleLoaded(_ m: MapboxMap) {
        drawn = nil
        update(m, last)
    }

    func update(_ m: MapboxMap, _ d: MapExplore) {
        last = d
        guard d != drawn else { return }
        ensureLayers(m)
        /* Build 10: the same display rules as every track (Douglas–Peucker 2.5 m), start / end dots. */
        let lines = ((d.active || d.capabilities) ? d.tracks : []).map { ($0, TrackDisplay.line(plain: $0.points)) }.filter { $0.1.isDrawable }
        let tracks = FeatureCollection(features: lines.map { t, line in
            var f = Feature(geometry: .lineString(LineString(line.points.map(\.coordinate))))
            f.properties = ["id": .string(t.id), "name": .string(t.name)]
            return f
        })
        let ends = FeatureCollection(features: lines.flatMap { _, line -> [Feature] in
            var a = Feature(geometry: .point(Point(line.points[0].coordinate)))
            a.properties = ["k": .string("s")]
            var b = Feature(geometry: .point(Point(line.points[line.points.count - 1].coordinate)))
            b.properties = ["k": .string("e")]
            return [a, b]
        })
        let pins = FeatureCollection(features: ((d.active || d.capabilities) ? d.places : []).map { p in
            var f = Feature(geometry: .point(Point(p.position.coordinate)))
            f.properties = ["id": .string(p.id), "name": .string(p.name)]
            return f
        })
        m.updateGeoJSONSource(withId: Self.tracksSource, geoJSON: .featureCollection(tracks))
        m.updateGeoJSONSource(withId: Self.placesSource, geoJSON: .featureCollection(pins))
        m.updateGeoJSONSource(withId: Self.endsSource, geoJSON: .featureCollection(ends))
        drawn = d
    }

    private func ensureLayers(_ m: MapboxMap) {
        for src in [Self.tracksSource, Self.placesSource, Self.endsSource] where !m.sourceExists(withId: src) {
            var s = GeoJSONSource(id: src)
            s.data = .featureCollection(FeatureCollection(features: []))
            try? m.addSource(s)
        }
        guard !m.layerExists(withId: Self.layerIds[0]) else { return }
        /* Under the cars and the navigation route, like the trails. */
        let ids = m.allLayerIdentifiers.map(\.id)
        let below = ids.first { $0.hasPrefix("sary-nav-") } ?? ids.first { $0.hasPrefix("sary-vehicle") }
        let pos: LayerPosition? = below.map { .below($0) }
        let round: [String: Any] = ["line-join": "round", "line-cap": "round"]
        /* GPX tracks shown in exploration are GPS tracks: the shared thin style (`GPSTrackStyle`). */
        GPSTrackStyle.addImages(m)
        let k = GPSTrackStyle.coreWidth
        let layers: [[String: Any]] = [
            ["id": Self.layerIds[0], "type": "line", "source": Self.tracksSource, "layout": round,
             "paint": ["line-color": GPSTrackStyle.edge, "line-width": GPSTrackStyle.width(k + GPSTrackStyle.edgeExtra),
                       "line-opacity": GPSTrackStyle.edgeOpacity, "line-emissive-strength": 1] as [String: Any]],
            ["id": Self.layerIds[1], "type": "line", "source": Self.tracksSource, "layout": round,
             "paint": ["line-color": GPSTrackStyle.core, "line-width": GPSTrackStyle.width(k),
                       "line-opacity": GPSTrackStyle.coreOpacity, "line-emissive-strength": 1] as [String: Any]],
            GPSTrackStyle.chevronLayer(id: Self.chevronLayer, source: Self.tracksSource),
            ["id": Self.layerIds[2], "type": "circle", "source": Self.endsSource,
             "paint": ["circle-radius": ["interpolate", ["linear"], ["zoom"], 8, 4, 14, 7, 18, 9],
                       "circle-color": ["match", ["get", "k"], "s", "#ffffff", GPSTrackStyle.core],
                       "circle-stroke-color": GPSTrackStyle.edge,
                       "circle-stroke-width": 2, "circle-pitch-alignment": "map", "circle-emissive-strength": 1] as [String: Any]],
            ["id": Self.layerIds[3], "type": "circle", "source": Self.placesSource,
             "paint": ["circle-radius": 7, "circle-color": "#ff3b6b", "circle-stroke-color": "#ffffff", "circle-stroke-width": 2.5,
                       "circle-pitch-alignment": "map", "circle-emissive-strength": 1] as [String: Any]],
            ["id": Self.layerIds[4], "type": "symbol", "source": Self.placesSource,
             "layout": ["text-field": ["get", "name"], "text-size": 13, "text-offset": [0, 1.3], "text-anchor": "top",
                        "text-font": ["DIN Pro Bold", "Arial Unicode MS Bold"], "text-optional": true] as [String: Any],
             "paint": ["text-color": "#ffffff", "text-halo-color": "#1b1206", "text-halo-width": 1.6, "text-emissive-strength": 1] as [String: Any]],
        ]
        for l in layers { try? m.addLayer(with: l, layerPosition: pos) }
    }
}

extension ExploreMapDrawer {
    /// Remember what to draw until the style is ready (`styleLoaded` draws it).
    func styleLoadedPending(_ d: MapExplore) { last = d }
}

/// One reading of the map centre (the exploration crosshair).
struct MapCenterReading: Equatable {
    var center: LngLat
    /// Metres above sea level from Mapbox Terrain-DEM at the centre; nil when its tiles are not loaded.
    var elevationM: Double?
    var zoom: Double
    /// Where that centre is on screen (the crosshair), in the map view's points.
    var screenPoint: CGPoint = .zero
    /// The camera came to rest (map idle), not a frame in the middle of a gesture.
    var settled: Bool
}
