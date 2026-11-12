import Combine
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
    /// Style option holding the index of the look in force (`looks`); 0 is the default («طبيعي»).
    static let gradeKey = "saryGrade"
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

    /// «طبيعي» (the default since the Build 44 report «ليه الألوان سيئة»): the photo as it is, a little
    /// warmer and clearer. Saturation never above +0.10 in the open desert, so the pale inter-dune
    /// patches do not turn neon green. Mapbox raster paint has no per-hue control (a green guard is not
    /// possible), so the guard is this lower global saturation.
    static let naturalWarm = Look(
        saturation: [Stop(zoom: 8, city: 0, desert: 0.04), Stop(zoom: 13, city: 0.02, desert: 0.07), Stop(zoom: 16, city: 0.03, desert: 0.1)],
        contrast: [Stop(zoom: 8, city: 0.04, desert: 0.06), Stop(zoom: 16, city: 0.05, desert: 0.08)],
        hueRotate: [Stop(zoom: 8, city: 0, desert: -3)],
        brightnessMin: [Stop(zoom: 8, city: 0.02, desert: 0.02)],
        brightnessMax: [Stop(zoom: 8, city: 1, desert: 0.98)],
        emissive: 0.3)

    /// «دافئ»: warm and clear, the cyan cast of the source pulled back to sand (Build 36 to 44 default was `strong`).
    static let mild = Look(
        saturation: [Stop(zoom: 8, city: 0.04, desert: 0.12), Stop(zoom: 13, city: 0.05, desert: 0.2), Stop(zoom: 16, city: 0.06, desert: 0.26)],
        contrast: [Stop(zoom: 8, city: 0.08, desert: 0.1), Stop(zoom: 16, city: 0.1, desert: 0.14)],
        hueRotate: [Stop(zoom: 8, city: 0, desert: -4)],
        brightnessMin: [Stop(zoom: 8, city: 0.02, desert: 0.02)],
        brightnessMax: [Stop(zoom: 8, city: 1, desert: 0.98)],
        emissive: 0.3)

    /// «قوي»: the old look (red-orange, the Build 36 to 44 default), still the real picture.
    static let strong = Look(
        saturation: [Stop(zoom: 8, city: 0.04, desert: 0.18), Stop(zoom: 13, city: 0.05, desert: 0.26), Stop(zoom: 16, city: 0.06, desert: 0.29)],
        contrast: [Stop(zoom: 8, city: 0.08, desert: 0.12), Stop(zoom: 16, city: 0.1, desert: 0.17)],
        hueRotate: [Stop(zoom: 8, city: 0, desert: -7)],
        brightnessMin: [Stop(zoom: 8, city: 0.02, desert: 0.02)],
        brightnessMax: [Stop(zoom: 8, city: 1, desert: 0.96)],
        emissive: 0.3)

    #if DEBUG
    /// No grade at all: the source pixels (screenshots, `-SarySandGrade natural`).
    static let ungraded = Look(saturation: [Stop(zoom: 8, city: 0, desert: 0)], contrast: [Stop(zoom: 8, city: 0, desert: 0)],
                               hueRotate: [Stop(zoom: 8, city: 0, desert: 0)], brightnessMin: [Stop(zoom: 8, city: 0, desert: 0)],
                               brightnessMax: [Stop(zoom: 8, city: 1, desert: 1)], emissive: 0.3)
    /// Build 19's grade (desaturated), for before / after shots (`-SarySandGrade legacy`).
    static let legacy = Look(saturation: [Stop(zoom: 8, city: -0.26, desert: -0.26)], contrast: [Stop(zoom: 8, city: 0.18, desert: 0.18)],
                             hueRotate: [Stop(zoom: 8, city: 0, desert: 0)], brightnessMin: [Stop(zoom: 8, city: 0.03, desert: 0.03)],
                             brightnessMax: [Stop(zoom: 8, city: 1, desert: 1)], emissive: 0.3)
    #endif

    // MARK: the user's choice («ألوان الصور»)

    /// The three choices of the setting, in the order of the `saryGrade` config index (0, 1, 2).
    enum Choice: String, CaseIterable {
        case natural, warm, strong
        var look: Look { switch self { case .natural: return SandGrade.naturalWarm; case .warm: return SandGrade.mild; case .strong: return SandGrade.strong } }
        var label: String { switch self { case .natural: return "طبيعي"; case .warm: return "دافئ"; case .strong: return "قوي" } }
        var detail: String {
            switch self {
            case .natural: return "ألوان قريبة من الصورة الحقيقية، دفء خفيف للرمل"
            case .warm: return "رمل أدفأ وأوضح"
            case .strong: return "برتقالي أحمر مشبع (اللون القديم)"
            }
        }
        var systemImage: String { switch self { case .natural: return "leaf.fill"; case .warm: return "sun.max.fill"; case .strong: return "flame.fill" } }
    }

    /// `UserDefaults` key of the choice (registered in `MapLayerCatalog`).
    static let choiceKey = "sary.map.imageryGrade.v1"
    static let defaultChoice = Choice.natural

    static func choice(_ defaults: UserDefaults = .standard) -> Choice {
        defaults.string(forKey: choiceKey).flatMap(Choice.init(rawValue:)) ?? defaultChoice
    }

    /// Every look the style carries, in `saryGrade` index order. The paint of the satellite layer picks one
    /// with the `saryGrade` style option, so a change of the setting is one config write, no style reload.
    static var looks: [Look] {
        var all = Choice.allCases.map(\.look)
        #if DEBUG
        /* The review-only looks join the style only when a screenshot run asks for one. */
        if ProcessInfo.processInfo.arguments.contains("-SarySandGrade") { all += [ungraded, legacy] }
        #endif
        return all
    }

    /// Index into `looks` of the grade in force.
    static var gradeIndex: Int {
        #if DEBUG
        /* Screenshots: `-SarySandGrade natural|naturalwarm|legacy|mild|strong`. */
        let a = ProcessInfo.processInfo.arguments
        if let i = a.firstIndex(of: "-SarySandGrade"), i + 1 < a.count {
            switch a[i + 1] {
            case "natural": return 3
            case "legacy": return 4
            case "naturalwarm": return 0
            case "mild": return 1
            case "strong": return 2
            default: break
            }
        }
        #endif
        return Choice.allCases.firstIndex(of: choice()) ?? 0
    }

    static var shipped: Look { looks[gradeIndex] }

    /// Fires (on the main queue) with the grade index whenever the setting changes.
    static var gradeChanges: AnyPublisher<Int, Never> {
        MapLayerRegistry.shared.$active.receive(on: DispatchQueue.main).map { _ in gradeIndex }.removeDuplicates().eraseToAnyPublisher()
    }

    /// Writes the grade in force to a map's imported basemap (a map whose style has no `saryGrade` option ignores it).
    static func pushGrade(_ map: MapboxMap) {
        try? map.setStyleImportConfigProperty(for: "basemap", config: gradeKey, value: Double(gradeIndex))
    }

    // MARK: paint

    private static func value(_ stops: [Stop], at z: Double) -> (city: Double, desert: Double) {
        guard let f = stops.first else { return (0, 0) }
        if z <= f.zoom { return (f.city, f.desert) }
        for (a, b) in zip(stops, stops.dropFirst()) where z <= b.zoom {
            let t = (z - a.zoom) / (b.zoom - a.zoom)
            return (a.city + t * (b.city - a.city), a.desert + t * (b.desert - a.desert))
        }
        let l = stops[stops.count - 1]
        return (l.city, l.desert)
    }

    /// `city + sarySand × (desert − city)`, one value per look chosen by `saryGrade`, interpolated in zoom
    /// when any look has more than one stop. `zoom` stays the input of the top-level `interpolate`.
    static func expression(_ path: KeyPath<Look, [Stop]>, of looks: [Look]) -> Any {
        func at(_ v: (city: Double, desert: Double)) -> Any {
            if v.city == v.desert { return v.city }
            return ["+", v.city, ["*", ["config", configKey], v.desert - v.city]] as [Any]
        }
        func out(_ z: Double) -> Any {
            let vs = looks.map { value($0[keyPath: path], at: z) }
            if vs.allSatisfy({ $0 == vs[0] }) || vs.count == 1 { return at(vs[0]) }
            var e: [Any] = ["step", ["config", gradeKey], at(vs[0])]
            for i in 1..<vs.count { e.append(Double(i)); e.append(at(vs[i])) }
            return e
        }
        let zooms = Set(looks.flatMap { $0[keyPath: path].map(\.zoom) }).sorted()
        guard zooms.count > 1 else { return out(zooms.first ?? 0) }
        var e: [Any] = ["interpolate", ["linear"], ["zoom"]]
        for z in zooms { e.append(z); e.append(out(z)) }
        return e
    }

    /// The satellite layer's paint: every look, chosen live by `saryGrade` and faded by `sarySand`.
    static func paint(_ looks: [Look] = SandGrade.looks) -> [String: Any] {
        [
            "raster-saturation": expression(\.saturation, of: looks),
            "raster-contrast": expression(\.contrast, of: looks),
            "raster-hue-rotate": expression(\.hueRotate, of: looks),
            "raster-brightness-min": expression(\.brightnessMin, of: looks),
            "raster-brightness-max": expression(\.brightnessMax, of: looks),
            "raster-emissive-strength": looks[0].emissive,
        ]
    }

    /// One look with `sarySand` fixed (a layer outside the imported basemap, e.g. the enhanced
    /// «صور عالية الوضوح» tiles, which must match the imagery they cover). Default: the grade in force.
    static func paint(_ look: Look = shipped, sand: Double) -> [String: Any] {
        func fixed(_ stops: [Stop]) -> Any {
            let v = stops.map { $0.city + sand * ($0.desert - $0.city) }
            guard v.count > 1 else { return v[0] }
            var e: [Any] = ["interpolate", ["linear"], ["zoom"]]
            for (s, x) in zip(stops, v) { e.append(s.zoom); e.append(x) }
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
    static var gradeSchemaOption: [String: Any] { ["default": 0, "type": "number", "minValue": 0, "maxValue": looks.count - 1] }

    /// Sets the grade on the Mapbox satellite raster layer of a style JSON (and of its imports'
    /// inline styles) and declares `sarySand` in that style's schema. Overrides what an older
    /// cached copy carried; idempotent and deterministic (sorted keys); the style comes back
    /// unchanged when it cannot be read.
    static func apply(_ style: String, looks: [Look] = SandGrade.looks) -> String {
        guard let data = style.data(using: .utf8), var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return style }
        guard grade(&root, paint(looks)), let out = try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]),
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
                schema[gradeKey] = gradeSchemaOption
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
        let bag: [Any] = [
            map.mapboxMap.onStyleLoaded.observe { [weak map] _ in if let map { set(map, true); pushGrade(map.mapboxMap) } },
            map.mapboxMap.onMapIdle.observe { [weak map] _ in if let map { set(map, false) } },
            gradeChanges.sink { [weak map] _ in if let map { pushGrade(map.mapboxMap) } },
        ]
        objc_setAssociatedObject(map, &followKey, bag, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
}
