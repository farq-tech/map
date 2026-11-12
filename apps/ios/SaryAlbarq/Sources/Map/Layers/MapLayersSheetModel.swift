import Foundation

/// One generated row of the layers sheet. Pure data: the sheet only draws it.
struct MapLayerRow: Identifiable, Equatable {
    let id: MapLayerID
    let title: String
    let detail: String
    let systemImage: String
    let isSelected: Bool
    /// Accessibility identifier (`layer.<legacy value>` for the base layers, so existing UI tests keep working).
    let testID: String
    /// Offline caveat shown under the detail; nil when the layer has none.
    let note: String?
    let noteIsPositive: Bool
}

/// Generates the sheet's rows from the registry (docs/ONE-MAP-UNIFICATION.md §6): nothing is written by hand.
enum MapLayersSheetModel {
    static func baseRows(registry: MapLayerRegistry, mode: MapLayerMode, areas: Int, topoAreas: Int) -> [MapLayerRow] {
        registry.layers(in: mode, category: .base).map { d in
            let legacy = MapLayerCatalog.legacy(d.id)
            return MapLayerRow(
                id: d.id, title: d.title, detail: d.detail, systemImage: d.systemImage, isSelected: registry.isActive(d.id),
                testID: "layer.\(legacy?.rawValue ?? d.id.rawValue)",
                note: legacy.map { ExploreRules.offlineNote($0, areas: areas, topoAreas: topoAreas) },
                noteIsPositive: legacy.map { $0.canBeOffline && ($0 == .satellite ? areas : topoAreas) > 0 } ?? false)
        }
    }

    /// Independent (flag) layers of the other categories, shown as switches. Empty until S3 registers data layers.
    static func switchLayers(registry: MapLayerRegistry, mode: MapLayerMode) -> [MapLayerDescriptor] {
        registry.layers(in: mode).filter { $0.category != .base }
    }
}

#if DEBUG
enum MapLayersSheetFlag {
    /// `-SaryLegacyLayersSheet`: open the old `ExploreLayersSheet` for before/after comparison (DEBUG only).
    static var useLegacy: Bool { ProcessInfo.processInfo.arguments.contains("-SaryLegacyLayersSheet") }
}
#else
enum MapLayersSheetFlag { static var useLegacy: Bool { false } }
#endif
