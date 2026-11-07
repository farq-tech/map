@_spi(Experimental) import MapboxMaps
import UIKit

/// What the home map draws for a desert chip: each result's outline (sand tint) and a numbered
/// marker with its name; the selected one stronger.
struct DesertOverlay: Equatable {
    var items: [DesertCategoryItem]
    var selected: String? = nil
}

/// Mapbox layers for `DesertOverlay` (one GeoJSON source, fill + outline + marker + label).
enum DesertGazetteerMapLayer {
    static let source = "sary-desert-gazetteer"
    static let fill = "sary-desert-gazetteer-fill"
    static let outline = "sary-desert-gazetteer-outline"
    static let marker = "sary-desert-gazetteer-marker"
    static let label = "sary-desert-gazetteer-label"
    static let number = "sary-desert-gazetteer-number"

    static let sand = "#d98a2b"
    static let green = "#3f9b4a"
    static let blue = "#2b7bd9"

    static func color(_ icon: String) -> String {
        switch icon {
        case DesertKind.rawda.systemImage: return green
        case DesertKind.fayda.systemImage: return blue
        default: return sand
        }
    }

    /// Features: polygons (`t` = "a") and points (`t` = "p", `n` its number, `s` selected).
    static func collection(_ o: DesertOverlay?) -> FeatureCollection {
        guard let o else { return FeatureCollection(features: []) }
        var fs: [Feature] = []
        for (i, it) in o.items.enumerated() {
            let sel = it.id == o.selected
            let c = color(it.systemImage)
            if let rings = it.polygon, !rings.isEmpty {
                let polys = rings.map { r in Polygon([r.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lng) } + [CLLocationCoordinate2D(latitude: r[0].lat, longitude: r[0].lng)]]) }
                var f = Feature(geometry: .multiPolygon(MultiPolygon(polys)))
                f.properties = ["t": .string("a"), "id": .string(it.id), "s": .boolean(sel), "c": .string(c)]
                fs.append(f)
            }
            var p = Feature(geometry: .point(Point(CLLocationCoordinate2D(latitude: it.point.lat, longitude: it.point.lng))))
            p.properties = ["t": .string("p"), "id": .string(it.id), "s": .boolean(sel), "c": .string(c),
                            "n": .string(SaryFormat.number(i + 1)), "name": .string(it.title), "k": .number(Double(o.items.count - i))]
            fs.append(p)
        }
        return FeatureCollection(features: fs)
    }

    static func apply(_ m: MapboxMap, _ o: DesertOverlay?) {
        if !m.sourceExists(withId: source) {
            var s = GeoJSONSource(id: source)
            s.data = .featureCollection(FeatureCollection(features: []))
            try? m.addSource(s)
        }
        if !m.layerExists(withId: fill) {
            FXLog.add(m, [
                "id": fill, "type": "fill", "source": source, "filter": ["==", ["get", "t"], "a"],
                "paint": ["fill-color": ["get", "c"], "fill-opacity": ["case", ["get", "s"], 0.28, 0.16] as [Any],
                          "fill-emissive-strength": 1] as [String: Any],
            ], layerPosition: nil)
        }
        if !m.layerExists(withId: outline) {
            FXLog.add(m, [
                "id": outline, "type": "line", "source": source, "filter": ["==", ["get", "t"], "a"],
                "layout": ["line-join": "round"],
                "paint": ["line-color": ["get", "c"], "line-width": ["case", ["get", "s"], 3.5, 2] as [Any],
                          "line-dasharray": [2, 1.2], "line-emissive-strength": 1] as [String: Any],
            ], layerPosition: nil)
        }
        if !m.layerExists(withId: marker) {
            FXLog.add(m, [
                "id": marker, "type": "circle", "source": source, "filter": ["==", ["get", "t"], "p"],
                "layout": ["circle-sort-key": ["get", "k"]] as [String: Any],
                "paint": ["circle-color": ["get", "c"], "circle-radius": ["case", ["get", "s"], 15, 12] as [Any],
                          "circle-stroke-color": "#ffffff", "circle-stroke-width": 2.5, "circle-emissive-strength": 1] as [String: Any],
            ], layerPosition: nil)
        }
        if !m.layerExists(withId: number) {
            FXLog.add(m, [
                "id": number, "type": "symbol", "source": source, "filter": ["==", ["get", "t"], "p"],
                "layout": ["text-field": ["get", "n"], "text-font": ["DIN Pro Bold", "Arial Unicode MS Bold"], "text-size": 12,
                           "text-allow-overlap": true, "text-ignore-placement": true, "symbol-sort-key": ["get", "k"]] as [String: Any],
                "paint": ["text-color": "#ffffff", "text-emissive-strength": 1] as [String: Any],
            ], layerPosition: nil)
        }
        if !m.layerExists(withId: label) {
            FXLog.add(m, [
                "id": label, "type": "symbol", "source": source, "filter": ["==", ["get", "t"], "p"],
                "layout": ["text-field": ["get", "name"], "text-font": ["DIN Pro Bold", "Arial Unicode MS Bold"], "text-size": 13,
                           "text-offset": [0, 1.3], "text-anchor": "top", "symbol-sort-key": ["get", "k"],
                           "text-max-width": 9, "text-optional": true] as [String: Any],
                "paint": ["text-color": "#1d1d1f", "text-halo-color": "#ffffff", "text-halo-width": 1.6, "text-emissive-strength": 1] as [String: Any],
            ], layerPosition: nil)
        }
        m.updateGeoJSONSource(withId: source, geoJSON: .featureCollection(collection(o)))
    }
}
