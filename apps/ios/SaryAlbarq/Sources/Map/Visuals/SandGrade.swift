import Foundation
import MapboxMaps
import ObjectiveC

/// The satellite imagery's colour grade: the Nafud, the Dahna and the Empty Quarter read as the
/// warm red-orange sand they are, cities stay as the photo shows them. Colour correction of the
/// real pixels only, through Mapbox's own raster paint (saturation, contrast, hue, brightness,
/// emissive): nothing is invented, no AI, so it carries no label.
///
/// Region-aware: the imported basemap gets a config option (`sarySand`, 0…1) that the paint
/// reads; `MapVisualsDirector` sets it from `UrbanAreas` (1 in the open, 0 in a city, smooth at
/// the edge). Zoom-aware: the mosaic seen from afar is already rich, the close-up imagery is
/// paler, so the grade grows with the zoom.
enum SandGrade {
    static let configKey = "sarySand"
    static let satelliteSource = "mapbox://mapbox.satellite"

    /// One raster paint value: the city value and the open-desert value at a zoom.
    struct Stop: Equatable {
        var zoom: Double
        var city: Double
        var desert: Double
    }

    struct Look: Equatable {
        var saturation: [Stop]
        var contrast: [Stop]
        var hueRotate: [Stop]
        var brightnessMin: [Stop]
        var brightnessMax: [Stop]
        /// How much the imagery ignores the scene light (the visuals pack's real-sun light grades the rest).
        var emissive: Double
    }

    /// «معتدل»: warm and clear, the cyan cast of the source pulled back to sand.
    static let mild = Look(
        saturation: [Stop(zoom: 8, city: 0.04, desert: 0.12), Stop(zoom: 13, city: 0.05, desert: 0.2), Stop(zoom: 16, city: 0.06, desert: 0.26)],
        contrast: [Stop(zoom: 8, city: 0.08, desert: 0.1), Stop(zoom: 16, city: 0.1, desert: 0.14)],
        hueRotate: [Stop(zoom: 8, city: 0, desert: -4)],
        brightnessMin: [Stop(zoom: 8, city: 0.02, desert: 0.02)],
        brightnessMax: [Stop(zoom: 8, city: 1, desert: 0.98)],
        emissive: 0.3)

    /// «أقوى»: closer to the App Store / Lovable red-orange, still the real picture.
    static let strong = Look(
        saturation: [Stop(zoom: 8, city: 0.04, desert: 0.18), Stop(zoom: 13, city: 0.05, desert: 0.26), Stop(zoom: 16, city: 0.06, desert: 0.29)],
        contrast: [Stop(zoom: 8, city: 0.08, desert: 0.12), Stop(zoom: 16, city: 0.1, desert: 0.17)],
        hueRotate: [Stop(zoom: 8, city: 0, desert: -7)],
        brightnessMin: [Stop(zoom: 8, city: 0.02, desert: 0.02)],
        brightnessMax: [Stop(zoom: 8, city: 1, desert: 0.96)],
        emissive: 0.3)

    static var shipped: Look {
        #if DEBUG
        /* Screenshots: `-SarySandGrade mild|strong`. */
        let a = ProcessInfo.processInfo.arguments
        if let i = a.firstIndex(of: "-SarySandGrade"), i + 1 < a.count {
            switch a[i + 1] {
            case "mild": return mild
            /* Build 19's grade (desaturated), for before / after shots. */
            case "legacy": return Look(saturation: [Stop(zoom: 8, city: -0.26, desert: -0.26)], contrast: [Stop(zoom: 8, city: 0.18, desert: 0.18)],
                                       hueRotate: [Stop(zoom: 8, city: 0, desert: 0)], brightnessMin: [Stop(zoom: 8, city: 0.03, desert: 0.03)],
                                       brightnessMax: [Stop(zoom: 8, city: 1, desert: 1)], emissive: 0.3)
            default: return strong
            }
        }
        #endif
        return strong
    }

    /// `city + sarySand × (desert − city)`, interpolated in zoom when there is more than one stop.
    static func expression(_ stops: [Stop]) -> Any {
        func at(_ s: Stop) -> Any {
            if s.city == s.desert { return s.city }
            return ["+", s.city, ["*", ["config", configKey], s.desert - s.city]] as [Any]
        }
        guard stops.count > 1 else { return at(stops[0]) }
        var e: [Any] = ["interpolate", ["linear"], ["zoom"]]
        for s in stops { e.append(s.zoom); e.append(at(s)) }
        return e
    }

    static func paint(_ look: Look = shipped) -> [String: Any] {
        [
            "raster-saturation": expression(look.saturation),
            "raster-contrast": expression(look.contrast),
            "raster-hue-rotate": expression(look.hueRotate),
            "raster-brightness-min": expression(look.brightnessMin),
            "raster-brightness-max": expression(look.brightnessMax),
            "raster-emissive-strength": look.emissive,
        ]
    }

    /// The same look with `sarySand` fixed (a layer outside the imported basemap, e.g. the
    /// enhanced «صور عالية الوضوح» tiles, which must match the imagery they cover).
    static func paint(_ look: Look = shipped, sand: Double) -> [String: Any] {
        func fixed(_ stops: [Stop]) -> Any {
            let v = stops.map { Stop(zoom: $0.zoom, city: $0.city + sand * ($0.desert - $0.city), desert: $0.city + sand * ($0.desert - $0.city)) }
            guard v.count > 1 else { return v[0].city }
            var e: [Any] = ["interpolate", ["linear"], ["zoom"]]
            for s in v { e.append(s.zoom); e.append(s.city) }
            return e
        }
        return [
            "raster-saturation": fixed(look.saturation), "raster-contrast": fixed(look.contrast), "raster-hue-rotate": fixed(look.hueRotate),
            "raster-brightness-min": fixed(look.brightnessMin), "raster-brightness-max": fixed(look.brightnessMax),
            "raster-emissive-strength": look.emissive,
        ]
    }

    /// `sarySand` for a camera centre: 1 in the open, 0 in a city (steps of 0.05, so panning
    /// does not restyle the map every frame).
    static func sand(urban: Double) -> Double { ((1 - min(1, max(0, urban))) * 20).rounded() / 20 }

    static let schemaOption: [String: Any] = ["default": 1, "type": "number", "minValue": 0, "maxValue": 1]

    /// Sets the grade on the Mapbox satellite raster layer of a style JSON (and of its imports'
    /// inline styles) and declares `sarySand` in that style's schema. Overrides what an older
    /// cached copy carried; idempotent and deterministic (sorted keys); the style comes back
    /// unchanged when it cannot be read.
    static func apply(_ style: String, look: Look = shipped) -> String {
        guard let data = style.data(using: .utf8), var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return style }
        guard grade(&root, paint(look)), let out = try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]),
              let s = String(data: out, encoding: .utf8) else { return style }
        return s
    }

    @discardableResult
    private static func grade(_ style: inout [String: Any], _ paint: [String: Any]) -> Bool {
        var changed = false
        if var layers = style["layers"] as? [[String: Any]] {
            var found = false
            for i in layers.indices where layers[i]["type"] as? String == "raster" && layers[i]["source"] as? String == satelliteSource {
                var p = layers[i]["paint"] as? [String: Any] ?? [:]
                for (k, v) in paint { p[k] = v }
                layers[i]["paint"] = p
                found = true
            }
            if found {
                style["layers"] = layers
                var schema = style["schema"] as? [String: Any] ?? [:]
                schema[configKey] = schemaOption
                style["schema"] = schema
                changed = true
            }
        }
        if var imports = style["imports"] as? [[String: Any]] {
            for i in imports.indices {
                guard var inner = imports[i]["data"] as? [String: Any] else { continue }
                if grade(&inner, paint) { imports[i]["data"] = inner; changed = true }
            }
            style["imports"] = imports
        }
        return changed
    }

    // MARK: maps without the visuals director (plan, offline preview, CarPlay)

    private static var followKey: UInt8 = 0

    /// Keeps `sarySand` in step with the camera centre (on style load and when the map comes to
    /// rest) for a map that has no `MapVisualsDirector`. Once per map; harmless on another style.
    static func follow(_ map: MapView) {
        guard objc_getAssociatedObject(map, &followKey) == nil else { return }
        var last: Double?
        let set: (MapView, Bool) -> Void = { map, force in
            let c = map.mapboxMap.cameraState.center
            let v = sand(urban: UrbanAreas.weight(lat: c.latitude, lng: c.longitude))
            guard force || v != last else { return }
            last = v
            try? map.mapboxMap.setStyleImportConfigProperty(for: "basemap", config: configKey, value: v)
        }
        let bag = [
            map.mapboxMap.onStyleLoaded.observe { [weak map] _ in if let map { set(map, true) } },
            map.mapboxMap.onMapIdle.observe { [weak map] _ in if let map { set(map, false) } },
        ]
        objc_setAssociatedObject(map, &followKey, bag, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
}
