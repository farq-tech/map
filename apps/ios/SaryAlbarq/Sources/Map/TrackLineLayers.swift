@_spi(Experimental) import MapboxMaps
import UIKit

/// How a track is drawn (build 10): one style for my live trail, «طريق العودة», «اسلك هذا
/// المسار», the trip summary, the story preview and GPX tracks.
struct TrackLineStyle: Equatable {
    /// Line width at zoom 14, points (scaled with the zoom).
    var width = 5.5
    /// The colour when the track has no speeds (GPX), or `speedColours` is off.
    var color: UInt32 = 0xE5772A
    /// Colour by speed (slow light → fast deep) where the track knows its speeds.
    var speedColours = true
    var casing = "#140d06"
    /// Round start / end dots (my live trail ends at my car and has its own start pin).
    var showEnds = true
    /// A soft glow under it (the track being followed).
    var glow = false
    var opacity = 1.0

    static let width = 5.5
}

/// Draws one `TrackLine` as Mapbox layers: a darker casing, the line itself with a
/// `line-gradient` on `line-progress` (source with `lineMetrics`), dashed unrecorded
/// stretches and the start / end dots. Re-created after every style load.
final class TrackLineDrawer {
    let id: String
    private var drawnLine: TrackLine?
    private var drawnStyle: TrackLineStyle?

    init(id: String) { self.id = id }

    private var grad: String { id }
    private var solid: String { "\(id)-solid" }
    private var gapSrc: String { "\(id)-gaps" }
    private var ends: String { "\(id)-ends" }
    var layerIds: [String] { ["\(id)-glow", "\(id)-casing", "\(id)-line", "\(id)-gap-casing", "\(id)-gap", "\(id)-ends"] }
    var lineLayerId: String { "\(id)-line" }

    /// The style was (re)loaded: everything must be added again.
    func styleLoaded() {
        drawnLine = nil
        drawnStyle = nil
    }

    func remove(_ m: MapboxMap) {
        for l in layerIds where m.layerExists(withId: l) { try? m.removeLayer(withId: l) }
        drawnLine = nil
        drawnStyle = nil
    }

    /// - Parameter below: put the layers under this one (cars, navigation route). Only evaluated
    ///   when the layers are (re)added: finding it walks the style's whole layer list.
    func update(_ m: MapboxMap, line: TrackLine?, style: TrackLineStyle, below: @autoclosure () -> String?) {
        guard let line, line.isDrawable else {
            if drawnLine != nil || m.layerExists(withId: lineLayerId) { clear(m) }
            drawnLine = nil
            return
        }
        if style != drawnStyle || !m.layerExists(withId: lineLayerId) {
            addLayers(m, style: style, below: below())
            drawnStyle = style
            drawnLine = nil
        }
        guard line != drawnLine else { return }
        drawnLine = line
        let runs = line.runs
        var whole = Feature(geometry: .lineString(LineString(line.points.map(\.coordinate))))
        whole.properties = [:]
        m.updateGeoJSONSource(withId: grad, geoJSON: .feature(whole))
        m.updateGeoJSONSource(withId: solid, geoJSON: .featureCollection(FeatureCollection(features: runs.solid.map {
            Feature(geometry: .lineString(LineString($0.map(\.coordinate))))
        })))
        m.updateGeoJSONSource(withId: gapSrc, geoJSON: .featureCollection(FeatureCollection(features: runs.gaps.map {
            Feature(geometry: .lineString(LineString($0.map(\.coordinate))))
        })))
        var endFeats: [Feature] = []
        if style.showEnds, let a = line.start, let b = line.end {
            var s = Feature(geometry: .point(Point(a.coordinate)))
            s.properties = ["k": .string("s")]
            var e = Feature(geometry: .point(Point(b.coordinate)))
            e.properties = ["k": .string("e")]
            endFeats = [s, e]
        }
        m.updateGeoJSONSource(withId: ends, geoJSON: .featureCollection(FeatureCollection(features: endFeats)))
        let uniform = style.speedColours ? nil : "#" + Vehicle.hex(style.color)
        let stops = TrackGradient.stops(line, uniform: uniform) ?? TrackGradient.stops(line, uniform: "#" + Vehicle.hex(style.color))
        if let stops {
            try? m.setLayerProperty(for: lineLayerId, property: "line-gradient", value: TrackGradient.expression(stops))
        }
    }

    private func clear(_ m: MapboxMap) {
        let empty = GeoJSONObject.featureCollection(FeatureCollection(features: []))
        for s in [solid, gapSrc, ends] where m.sourceExists(withId: s) { m.updateGeoJSONSource(withId: s, geoJSON: empty) }
        if m.sourceExists(withId: grad) { m.updateGeoJSONSource(withId: grad, geoJSON: empty) }
    }

    private func addLayers(_ m: MapboxMap, style: TrackLineStyle, below: String?) {
        for l in layerIds where m.layerExists(withId: l) { try? m.removeLayer(withId: l) }
        if !m.sourceExists(withId: grad) {
            var s = GeoJSONSource(id: grad)
            /* `line-progress` (and so `line-gradient`) needs the line metrics. */
            s.lineMetrics = true
            s.data = .featureCollection(FeatureCollection(features: []))
            try? m.addSource(s)
        }
        for src in [solid, gapSrc, ends] where !m.sourceExists(withId: src) {
            var s = GeoJSONSource(id: src)
            s.data = .featureCollection(FeatureCollection(features: []))
            try? m.addSource(s)
        }
        let w = style.width
        func width(_ k: Double) -> [Any] { ["interpolate", ["exponential", 1.5], ["zoom"], 8, k * 0.45, 14, k, 18, k * 1.45, 20, k * 1.8] }
        let round: [String: Any] = ["line-join": "round", "line-cap": "round"]
        let colour = "#" + Vehicle.hex(style.color)
        let pos: LayerPosition? = below.flatMap { m.layerExists(withId: $0) ? .below($0) : nil }
        var layers: [[String: Any]] = []
        if style.glow {
            layers.append(["id": "\(id)-glow", "type": "line", "source": solid, "layout": round,
                           "paint": ["line-color": colour, "line-width": width(w + 12), "line-opacity": 0.32 * style.opacity, "line-blur": 6,
                                     "line-emissive-strength": 1] as [String: Any]])
        }
        layers += [
            ["id": "\(id)-casing", "type": "line", "source": solid, "layout": round,
             "paint": ["line-color": style.casing, "line-width": width(w + 3.5), "line-opacity": 0.9 * style.opacity,
                       "line-emissive-strength": 1] as [String: Any]],
            ["id": lineLayerId, "type": "line", "source": grad, "layout": round,
             "paint": ["line-width": width(w), "line-opacity": style.opacity, "line-emissive-strength": 1,
                       "line-gradient": ["interpolate", ["linear"], ["line-progress"], 0, colour, 1, colour]] as [String: Any]],
            ["id": "\(id)-gap-casing", "type": "line", "source": gapSrc, "layout": round,
             "paint": ["line-color": style.casing, "line-width": width(w * 0.7 + 3), "line-opacity": 0.8 * style.opacity,
                       "line-emissive-strength": 1] as [String: Any]],
            ["id": "\(id)-gap", "type": "line", "source": gapSrc, "layout": ["line-join": "round"],
             "paint": ["line-color": colour, "line-width": width(w * 0.7), "line-dasharray": [1.2, 1.6], "line-opacity": style.opacity,
                       "line-emissive-strength": 1] as [String: Any]],
            ["id": "\(id)-ends", "type": "circle", "source": ends,
             "paint": ["circle-radius": ["interpolate", ["linear"], ["zoom"], 8, 4, 14, 7, 18, 9],
                       "circle-color": ["match", ["get", "k"], "s", "#ffffff", "#7a2408"],
                       "circle-stroke-color": ["match", ["get", "k"], "s", style.casing, "#ffffff"],
                       "circle-stroke-width": 3, "circle-pitch-alignment": "map", "circle-opacity": style.opacity,
                       "circle-stroke-opacity": style.opacity, "circle-emissive-strength": 1] as [String: Any]],
        ]
        for l in layers { try? m.addLayer(with: l, layerPosition: pos) }
    }
}

/// «قمر صناعي نظيف»: Standard Satellite's own label switches (the imagery stays as it is).
enum SatelliteLabels {
    /// A recorded / selected track is the subject: no POI, transit, place or road labels.
    case clean
    /// Driving / navigation: road and place names help.
    case driving
    /// The live map's long-standing default: place names only.
    case standard

    var config: [(String, Bool)] {
        switch self {
        case .clean: return [("showPointOfInterestLabels", false), ("showTransitLabels", false), ("showPlaceLabels", false), ("showRoadLabels", false)]
        case .driving: return [("showPointOfInterestLabels", false), ("showTransitLabels", false), ("showPlaceLabels", true), ("showRoadLabels", true)]
        case .standard: return [("showPointOfInterestLabels", false), ("showTransitLabels", false), ("showPlaceLabels", true), ("showRoadLabels", false)]
        }
    }

    /// The satellite imagery's sharp maximum over the Kingdom (the live map's zoom limit).
    static let imageryMaxZoom = 18.0
    /// With «صور عالية الوضوح» on, one level more: the enhanced z19 tiles are worth zooming into.
    static let hiResMaxZoom = 19.0
    static func imageryMaxZoom(hiRes: Bool) -> Double { hiRes ? hiResMaxZoom : imageryMaxZoom }
    /// Framing a track: never closer than the imagery stays sharp.
    static let trackMaxZoom = imageryMaxZoom

    func apply(_ m: MapboxMap) {
        for (k, v) in config { try? m.setStyleImportConfigProperty(for: "basemap", config: k, value: v) }
    }
}
