@_spi(Experimental) import MapboxMaps
import SwiftUI
import UIKit

/// The «كاميرات الرصد» layer: a plain camera glyph on a coloured disc at each
/// camera, drawn during navigation and while browsing. Self-contained — its own
/// GeoJSON source and layer ids, nothing shared with `NavMapDrawer`. A map
/// coordinator shows it with one call (`CameraMapLayer.ensure` then `.update`);
/// see the PR notes for the single read-only hook that wires it into the live map.
///
/// A simple symbol only: no program name, branding, or official colours.
enum CameraMapLayer {
    static let source = "sary-cameras"
    static let disc = "sary-cameras-disc"
    static let icon = "sary-cameras-icon"
    static let iconImage = "sary-camera-glyph"

    /// Disc colour by kind (a camera glyph sits on top in white).
    private static let discColor: [Any] = [
        "match", ["get", "kind"],
        "red_light", "#E5484D",
        "avg_speed", "#8E5BE8",
        "mobile", "#F2A20C",
        /* fixed + default */ "#2B7BF0",
    ]
    /// Fainter when we are less sure the camera is really there.
    private static let byConfidence: [Any] = ["interpolate", ["linear"], ["get", "conf"], 0.0, 0.45, 0.85, 1.0]

    /// Register the glyph and add the layers once per style load.
    static func ensure(_ m: MapboxMap) {
        if m.imageExists(withId: iconImage) == false, let img = glyph() {
            try? m.addImage(img, id: iconImage)
        }
        if !m.sourceExists(withId: source) {
            var s = GeoJSONSource(id: source)
            s.data = .featureCollection(FeatureCollection(features: []))
            try? m.addSource(s)
        }
        if !m.layerExists(withId: disc) {
            try? m.addLayer(with: [
                "id": disc, "type": "circle", "source": source,
                "paint": [
                    "circle-radius": ["interpolate", ["linear"], ["zoom"], 8, 5, 14, 9, 17, 13],
                    "circle-color": discColor,
                    "circle-opacity": byConfidence,
                    "circle-stroke-color": "#ffffff",
                    "circle-stroke-width": 2,
                    "circle-pitch-alignment": "map",
                    "circle-emissive-strength": 1,
                ] as [String: Any],
            ], layerPosition: nil)
        }
        if !m.layerExists(withId: icon) {
            try? m.addLayer(with: [
                "id": icon, "type": "symbol", "source": source,
                "layout": [
                    "icon-image": iconImage,
                    "icon-size": ["interpolate", ["linear"], ["zoom"], 8, 0.45, 14, 0.7, 17, 0.9],
                    "icon-allow-overlap": true,
                    "icon-ignore-placement": true,
                ] as [String: Any],
                "paint": ["icon-opacity": byConfidence] as [String: Any],
            ], layerPosition: nil)
        }
    }

    /// Replace the drawn cameras.
    static func update(_ m: MapboxMap, cameras: [SpeedCamera]) {
        let feats: [Feature] = cameras.map { c in
            var f = Feature(geometry: .point(Point(c.position.coordinate)))
            f.properties = ["kind": .string(c.kind.rawValue), "conf": .number(c.confidence), "id": .string(c.id)]
            return f
        }
        m.updateGeoJSONSource(withId: source, geoJSON: .featureCollection(FeatureCollection(features: feats)))
    }

    /// A white camera glyph on transparent, drawn from SF Symbols (no third-party art).
    private static func glyph(size: CGFloat = 44) -> UIImage? {
        let cfg = UIImage.SymbolConfiguration(pointSize: size * 0.62, weight: .bold)
        guard let base = UIImage(systemName: "camera.fill", withConfiguration: cfg) else { return nil }
        let tinted = base.withTintColor(.white, renderingMode: .alwaysOriginal)
        let r = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        return r.image { _ in
            let p = (size - tinted.size.width) / 2
            tinted.draw(in: CGRect(x: p, y: (size - tinted.size.height) / 2, width: tinted.size.width, height: tinted.size.height))
        }
    }
}
