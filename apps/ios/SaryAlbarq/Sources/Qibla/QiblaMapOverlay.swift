@_spi(Experimental) import MapboxMaps
import CoreLocation
import ObjectiveC
import UIKit

/// The live map's direction-to-Kaaba line. It is geometry on the map, so it stays aligned
/// when the camera rotates or tilts and remains attached to the latest accepted GPS fix.
@MainActor
final class QiblaMapOverlay {
    static let sourceID = "sary-qibla-source"
    static let casingID = "sary-qibla-casing"
    static let lineID = "sary-qibla-line"

    private weak var map: MapView?
    private var origin: LngLat?
    private var styleReady = false
    private var styleObserver: AnyCancelable?

    private static var associationKey: UInt8 = 0

    static func of(_ map: MapView) -> QiblaMapOverlay {
        if let overlay = objc_getAssociatedObject(map, &associationKey) as? QiblaMapOverlay { return overlay }
        let overlay = QiblaMapOverlay(map: map)
        objc_setAssociatedObject(map, &associationKey, overlay, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return overlay
    }

    private init(map: MapView) {
        self.map = map
        styleReady = map.mapboxMap.isStyleLoaded
        styleObserver = map.mapboxMap.onStyleLoaded.observe { [weak self] _ in
            guard let self else { return }
            self.styleReady = true
            self.apply()
        }
    }

    func update(origin: LngLat?) {
        guard !Self.same(origin, self.origin) else { return }
        self.origin = origin
        apply()
    }

    private func apply() {
        guard styleReady, let map, let m = map.mapboxMap else { return }
        ensureLayers(m)
        let features: [Feature]
        if let origin {
            let points = Qibla.greatCirclePoints(from: origin.coordinate)
            features = points.count >= 2
                ? [Feature(geometry: .lineString(LineString(points)))]
                : []
        } else {
            features = []
        }
        m.updateGeoJSONSource(withId: Self.sourceID,
                              geoJSON: .featureCollection(FeatureCollection(features: features)))
    }

    private func ensureLayers(_ m: MapboxMap) {
        if !m.sourceExists(withId: Self.sourceID) {
            var source = GeoJSONSource(id: Self.sourceID)
            source.data = .featureCollection(FeatureCollection(features: []))
            try? m.addSource(source)
        }
        if m.layerExists(withId: Self.casingID), m.layerExists(withId: Self.lineID) { return }

        if m.layerExists(withId: Self.casingID) { try? m.removeLayer(withId: Self.casingID) }
        if m.layerExists(withId: Self.lineID) { try? m.removeLayer(withId: Self.lineID) }

        var casing = LineLayer(id: Self.casingID, source: Self.sourceID)
        casing.lineColor = .constant(StyleColor(UIColor(white: 0.04, alpha: 0.9)))
        casing.lineWidth = .constant(6)
        casing.lineOpacity = .constant(0.78)
        casing.lineJoin = .constant(.round)
        casing.lineCap = .constant(.round)
        casing.lineEmissiveStrength = .constant(1)

        var line = LineLayer(id: Self.lineID, source: Self.sourceID)
        line.lineColor = .constant(StyleColor(UIColor(rgb: 0xE8AD3A)))
        line.lineWidth = .constant(3)
        line.lineOpacity = .constant(0.95)
        line.lineDasharray = .constant([1.2, 1.4])
        line.lineJoin = .constant(.round)
        line.lineCap = .constant(.round)
        line.lineEmissiveStrength = .constant(1)

        let below = m.allLayerIdentifiers.first {
            $0.id.hasPrefix("sary-nav-") || $0.id.hasPrefix("sary-vehicle")
        }?.id
        let position = below.map { LayerPosition.below($0) }
        try? m.addLayer(casing, layerPosition: position)
        try? m.addLayer(line, layerPosition: position)
    }

    private static func same(_ a: LngLat?, _ b: LngLat?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a?, b?): return a.lat == b.lat && a.lng == b.lng
        default: return false
        }
    }
}
