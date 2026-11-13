@_spi(Experimental) import MapboxMaps
import Foundation
import SwiftUI

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

    /// The closest the map may zoom. Satellite: Mapbox imagery over the Kingdom's cities is sharp
    /// to about z18; past it the tiles are only magnified (build 11 showed a blurry parking lot at
    /// ~z21). With «صور عالية الوضوح» on (person + server), z19 — the enhanced tiles (desert z17+,
    /// cities z19) need it. The vector layers stay crisp further in.
    var maxZoom: Double { maxZoom(hiRes: HiResSettings.shared.userOn && HiResSettings.shared.remoteOn) }

    func maxZoom(hiRes: Bool) -> Double {
        switch self {
        case .satellite: return SatelliteLabels.imageryMaxZoom(hiRes: hiRes)
        case .standard, .topo: return 20
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

/// Satellite clarity (build 12, the owner's top priority): the Standard Satellite imagery
/// layer, tuned only through Mapbox's own raster paint properties — a little more contrast
/// and colour so dusty desert and wadis read, shadows lifted slightly, linear resampling and a
/// short fade so tiles do not flicker in. Applied to the style document we already load
/// (`ArabicBasemap`), in one place; the values stay natural (no oversaturated look).
enum SatelliteImagery {
    static let paint: [String: Any] = [
        "raster-contrast": 0.12,
        "raster-saturation": 0.08,
        "raster-brightness-min": 0.03,
        "raster-brightness-max": 1.0,
        "raster-resampling": "linear",
        "raster-fade-duration": 120,
    ]
    /// Mapbox's defaults: the untuned picture (before / after comparisons).
    static let neutral: [String: Any] = [
        "raster-contrast": 0, "raster-saturation": 0, "raster-brightness-min": 0, "raster-brightness-max": 1,
        "raster-resampling": "linear", "raster-fade-duration": 300,
    ]

    /// Sets `paint` on every raster layer of a style JSON (and of its imports' inline styles).
    /// Idempotent and deterministic (sorted keys: the cached copy compares equal next launch);
    /// the style comes back unchanged when it cannot be read. `keepExisting`: a value the style
    /// already sets wins (the live map: «المؤثرات البصرية»'s grading from `ArabicBasemap.tune`
    /// — contrast, saturation, emissive — stays; this adds resampling, fade and lifted shadows).
    static func tune(_ style: String, paint: [String: Any] = paint, keepExisting: Bool = false) -> String {
        guard let data = style.data(using: .utf8), var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return style }
        guard apply(&root, paint, keepExisting), let out = try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]),
              let s = String(data: out, encoding: .utf8) else { return style }
        return s
    }

    @discardableResult
    private static func apply(_ style: inout [String: Any], _ paint: [String: Any], _ keepExisting: Bool) -> Bool {
        var changed = false
        if var layers = style["layers"] as? [[String: Any]] {
            for i in layers.indices where layers[i]["type"] as? String == "raster" {
                var p = layers[i]["paint"] as? [String: Any] ?? [:]
                p.merge(paint) { old, new in keepExisting ? old : new }
                layers[i]["paint"] = p
                changed = true
            }
            style["layers"] = layers
        }
        if var imports = style["imports"] as? [[String: Any]] {
            for i in imports.indices {
                guard var inner = imports[i]["data"] as? [String: Any] else { continue }
                if apply(&inner, paint, keepExisting) { imports[i]["data"] = inner; changed = true }
            }
            style["imports"] = imports
        }
        return changed
    }
}

#if DEBUG
/// `-demo -SaryScreen imagery -SaryImageryAt 25.12,46.10,16 [-SaryImageryRaw]`: the satellite
/// style alone at a point and zoom, tuned or not (before / after screenshots).
struct SatelliteImageryProbe: UIViewRepresentable {
    func makeUIView(context: Context) -> MapView {
        let a = ProcessInfo.processInfo.arguments
        let at = a.firstIndex(of: "-SaryImageryAt").flatMap { $0 + 1 < a.count ? a[$0 + 1] : nil }?
            .split(separator: ",").compactMap { Double($0) } ?? []
        let center = at.count > 1 ? CLLocationCoordinate2D(latitude: at[0], longitude: at[1]) : MapOpening.center().coordinate
        let map = MapView(frame: .zero, mapInitOptions: MapInitOptions(cameraOptions: CameraOptions(center: center, zoom: at.count > 2 ? at[2] : 16)))
        try? map.mapboxMap.setCameraBounds(with: CameraBoundsOptions(maxZoom: MapLayer.satellite.maxZoom))
        let raw = a.contains("-SaryImageryRaw")
        let show: (String) -> Void = { json in
            map.mapboxMap.loadStyle(SatelliteImagery.tune(json, paint: raw ? SatelliteImagery.neutral : SatelliteImagery.paint))
        }
        if let json = ArabicBasemap.cached(.satellite) { show(json) } else { map.mapboxMap.loadStyle(MapLayer.satellite.styleURI) }
        ArabicBasemap.load(.satellite) { json in if let json { show(json) } }
        map.mapboxMap.onStyleLoaded.observe { _ in
            for (k, v) in SatelliteLabels.clean.config { try? map.mapboxMap.setStyleImportConfigProperty(for: "basemap", config: k, value: v) }
        }.store(in: &context.coordinator.bag)
        return map
    }

    func updateUIView(_ map: MapView, context: Context) {}
    func makeCoordinator() -> Bag { Bag() }
    final class Bag { var bag = Set<AnyCancelable>() }
}
#endif
