@_spi(Experimental) import MapboxMaps
import Foundation

/// The live map's base layer («الطبقة»), chosen in exploration (docs/IA-REDESIGN.md §6, stage 4).
/// Every layer is a real Mapbox style; nothing is drawn from invented data.
enum MapLayer: String, CaseIterable, Identifiable, Codable {
    /// Mapbox Standard Satellite — the outing map since build 1.
    case satellite
    /// Mapbox Standard (vector streets, 3D buildings).
    case standard
    /// Mapbox Outdoors: contour lines + hillshade from Mapbox Terrain (mapbox-terrain-v2).
    case topo

    var id: String { rawValue }

    var label: String {
        switch self {
        case .satellite: return "قمر صناعي"
        case .standard: return "عادي"
        case .topo: return "طبوغرافي"
        }
    }

    var detail: String {
        switch self {
        case .satellite: return "صور الأقمار الصناعية مع الطرق"
        case .standard: return "شوارع ومبانٍ، أوضح في المدن"
        case .topo: return "خطوط كنتور وتظليل التضاريس، الارتفاع بالمتر"
        }
    }

    var systemImage: String {
        switch self {
        case .satellite: return "globe.asia.australia.fill"
        case .standard: return "map.fill"
        case .topo: return "mountain.2.fill"
        }
    }

    var styleURI: StyleURI {
        switch self {
        case .satellite: return StyleURI(rawValue: "mapbox://styles/mapbox/standard-satellite")!
        case .standard: return .standard
        case .topo: return .outdoors
        }
    }

    /// The style's id in the Styles API (`/styles/v1/mapbox/<id>`).
    var styleId: String {
        switch self {
        case .satellite: return "standard-satellite"
        case .standard: return "standard"
        case .topo: return "outdoors-v12"
        }
    }

    /// Standard and Standard Satellite are loaded as the "basemap" import (light preset, 3D
    /// objects); Outdoors is a classic style and is loaded as it is.
    var isImport: Bool { self != .topo }

    /// Offline packs this app can download for the layer (OfflineMaps): satellite always, the
    /// topographic layer when the area was saved with it; «عادي» is never packed (honest note).
    var canBeOffline: Bool { self != .standard }

    static let key = "sary.map.layer.v1"
    static var saved: MapLayer {
        get { UserDefaults.standard.string(forKey: key).flatMap(MapLayer.init) ?? .satellite }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}

/// Contour labels of the topographic layer: metres with Arabic-Indic digits («٦٢٠ م»).
/// Mapbox's `number-format` formats with the platform's number formatter for the locale.
enum TopoLabels {
    static let contourLabelLayer = "contour-label"
    static let textField: [Any] = ["concat", ["number-format", ["get", "ele"], ["locale": "ar-SA", "max-fraction-digits": 0] as [String: Any]], " م"]
}
