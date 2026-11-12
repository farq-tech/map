import Foundation

/// THE registration point (docs/ONE-MAP-UNIFICATION.md §5.2): to add a layer, add one
/// `MapLayerDescriptor` here. No sheet, screen or map view changes.
enum MapLayerCatalog {
    static let all: [MapLayerDescriptor] = base

    /// Satellite / standard / topographic. Built from `MapLayer` (the legacy enum stays the
    /// source of the titles and icons until S4 removes it) and stored under its key
    /// `sary.map.layer.v1` with its `rawValue`, so the stored data does not change.
    static let base: [MapLayerDescriptor] = MapLayer.allCases.map { l in
        MapLayerDescriptor(
            id: baseID(l), title: l.label, detail: l.detail, systemImage: l.systemImage, category: .base,
            defaultOn: l == .satellite,
            conflicts: Set(MapLayer.allCases.filter { $0 != l }.map(baseID)),
            persistence: .choice(key: MapLayer.key, value: l.rawValue),
            // The base map is offered in every mode; the offline caveat is a row note, not a hiding rule.
            availableIn: Set(MapLayerMode.allCases), needsNetwork: false)
    }

    static func baseID(_ l: MapLayer) -> MapLayerID { MapLayerID(rawValue: "base.\(l.rawValue)") }

    /// The legacy value of a base layer (nil for any other layer).
    static func legacy(_ id: MapLayerID) -> MapLayer? { MapLayer.allCases.first { baseID($0) == id } }
}
