import Foundation
import CoreGraphics

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

    /// Height of the strip at the sheet's bottom that the floating SOS disc owns (`SOSOverlayWindow`: disc + 16 pt, `space(.s)` above the
    /// home-indicator inset). The sheet's scroll area ends above it.
    static func sosReserve(disc: CGFloat, small: CGFloat) -> CGFloat { disc + 16 + small }

    /// Which rows the live map's sheet offers: exploration, guidance, or the outing otherwise.
    static func mode(exploring: Bool, navigating: Bool) -> MapLayerMode {
        exploring ? .explore : (navigating ? .navigate : .outing)
    }

    /// Registered non-base layers, as one flat list (kept for callers that only need "is anything else registered").
    static func switchLayers(registry: MapLayerRegistry, mode: MapLayerMode) -> [MapLayerDescriptor] {
        registry.layers(in: mode).filter { $0.category != .base }
    }

    /// The sheet below the base-map cards, generated from the catalog (§6): single-select groups (weather), then
    /// extra overlays, data layers, imagery and terrain. Empty sections are left out.
    static func sections(registry: MapLayerRegistry, mode: MapLayerMode) -> [MapLayerSection] {
        func row(_ d: MapLayerDescriptor) -> MapLayerSwitchRow {
            MapLayerSwitchRow(id: d.id, title: d.title, detail: d.detail, systemImage: d.systemImage,
                              isOn: registry.isActive(d.id), testID: d.accessibilityID, needsNetwork: d.needsNetwork)
        }
        let others = registry.layers(in: mode).filter { $0.category != .base }
        var out: [MapLayerSection] = []
        // 1) single-select groups (weather), in catalog order of their first member
        var groupTitles: [String] = []
        for d in others { if let t = d.groupTitle, !groupTitles.contains(t) { groupTitles.append(t) } }
        for t in groupTitles {
            let members = others.filter { $0.groupTitle == t }
            /* Only a group that may be off (weather) offers «بدون»; a plain choice (image colours) always has one chosen. */
            let mayBeOff = members.contains { if case .optionalChoice = $0.persistence { return true } else { return false } }
            let none = mayBeOff ? MapLayerOffRow(title: WeatherOverlayKind.none.label, detail: WeatherOverlayKind.none.detail,
                                                 systemImage: WeatherOverlayKind.none.systemImage, testID: "weather.layer.none",
                                                 isSelected: !members.contains { registry.isActive($0.id) }) : nil
            out.append(MapLayerSection(id: "group.\(t)", title: t, style: .singleSelect, rows: members.map(row), off: none))
        }
        // 2) the rest by category, independent switches
        let plain = others.filter { $0.groupTitle == nil }
        for (cat, title) in [(MapLayerCategory.overlay, "طبقات إضافية"), (.data, "طبقات البيانات"), (.terrain, "الصورة والتضاريس")] {
            let rows = plain.filter { $0.category == cat }.map(row)
            if !rows.isEmpty { out.append(MapLayerSection(id: "category.\(cat.rawValue)", title: title, style: .switches, rows: rows, off: nil)) }
        }
        return out
    }
}

/// One switch of the sheet (a data layer).
struct MapLayerSwitchRow: Identifiable, Equatable {
    let id: MapLayerID
    let title: String
    let detail: String
    let systemImage: String
    let isOn: Bool
    let testID: String
    let needsNetwork: Bool
}

/// The «بدون» row of a single-select group.
struct MapLayerOffRow: Equatable {
    let title: String
    let detail: String
    let systemImage: String
    let testID: String
    let isSelected: Bool
}

struct MapLayerSection: Identifiable, Equatable {
    enum Style { case singleSelect, switches }
    let id: String
    let title: String
    let style: Style
    let rows: [MapLayerSwitchRow]
    let off: MapLayerOffRow?
}

#if DEBUG
enum MapLayersSheetFlag {
    /// `-SaryLegacyLayersSheet`: open the old `ExploreLayersSheet` for before/after comparison (DEBUG only).
    static var useLegacy: Bool { ProcessInfo.processInfo.arguments.contains("-SaryLegacyLayersSheet") }
}
#else
enum MapLayersSheetFlag { static var useLegacy: Bool { false } }
#endif
