import Foundation

/// THE registration point (docs/ONE-MAP-UNIFICATION.md §5.2): to add a layer, add one
/// `MapLayerDescriptor` here. No sheet, screen or map view changes.
enum MapLayerCatalog {
    static let all: [MapLayerDescriptor] = base + weather + data + imagery + imageryGrade

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

    // MARK: Data layers (S3). Registered with the keys the app already used, so stored choices carry over unchanged;
    // how each one draws is untouched (its own overlay/hub reads the same key).

    /// LEGACY, no-op: the Qibla ray and its button were removed (owner decision, 2026-11-13). Nothing reads this key any more, so a stored
    /// «on» can never bring the line back; it stays only so old installs' value is recognised and `AccountDeletion` can still clear it.
    static let qiblaVisibleKey = "sary.map.qibla.visible.v1"
    static let weatherKey = "sary.map.weather.v1"
    static let campSitesKey = "sary.map.campSites.v1"
    static let osmTracksKey = "sary.map.osmTracks.v1"
    static let hiResKey = "sary.hires.user.v1"

    static let weatherKinds: [WeatherOverlayKind] = [.clouds, .rain, .wind, .green]
    static func weatherID(_ k: WeatherOverlayKind) -> MapLayerID { MapLayerID(rawValue: "weather.\(k.rawValue)") }
    /// The weather kind of a weather layer (nil for any other layer).
    static func weatherKind(_ id: MapLayerID) -> WeatherOverlayKind? { weatherKinds.first { weatherID($0) == id } }

    /// Weather overlays are drawn on the live map in every mode (exploration, the outing, guidance: `WeatherOverlayRequest.active`), so the sheet offers them there.
    static let weather: [MapLayerDescriptor] = weatherKinds.map { k in
        MapLayerDescriptor(
            id: weatherID(k), title: k.label, detail: k.detail, systemImage: k.systemImage, category: .overlay,
            conflicts: Set(weatherKinds.filter { $0 != k }.map(weatherID)),
            persistence: .optionalChoice(key: weatherKey, value: k.rawValue, off: WeatherOverlayKind.none.rawValue),
            availableIn: [.explore, .outing, .navigate], needsNetwork: true, groupTitle: "الطقس", accessibilityID: "weather.layer.\(k.rawValue)")
    }

    static let camp = MapLayerDescriptor(
        id: "data.camp", title: "أماكن مقترحة للكشتة", detail: "نقاط برتقالية على الخريطة", systemImage: "tent.fill", category: .data,
        persistence: .flag(key: campSitesKey), availableIn: [.explore, .outing, .navigate], accessibilityID: "explore-camp-sites")
    static let osmTracks = MapLayerDescriptor(
        id: "data.osmTracks", title: "مسارات البر (OSM)", detail: "طبعات الطرق الترابية مثل OsmAnd",
        systemImage: "point.topleft.down.to.point.bottomright.curvepath.fill", category: .data, defaultOn: true,
        persistence: .flag(key: osmTracksKey), availableIn: [.explore, .outing, .navigate], accessibilityID: "explore-osm-tracks")
    static let data: [MapLayerDescriptor] = [camp, osmTracks]

    static let hiRes = MapLayerDescriptor(
        id: "imagery.hires", title: "صور عالية الوضوح", detail: "قد تتضمن الصورة تفاصيل تقديرية عند التقريب",
        systemImage: "photo.fill", category: .terrain, defaultOn: true,
        persistence: .flag(key: hiResKey), availableIn: [.explore, .outing, .navigate], needsNetwork: true, accessibilityID: "explore-hires")
    /// 3D terrain is a per-screen camera state of the live map (it resets when exploration opens), so it is a session layer.
    static let terrain = MapLayerDescriptor(
        id: "terrain.3d", title: "عرض ثلاثي الأبعاد", detail: "يميل الخريطة ويبرز الجبال والطعوس",
        systemImage: "mountain.2.fill", category: .terrain, persistence: .session(name: "terrain3D"),
        availableIn: [.explore, .outing], accessibilityID: "explore-terrain3d")
    static let imagery: [MapLayerDescriptor] = [hiRes, terrain]

    static let imageryGradeGroup = "ألوان الصور"
    static func gradeID(_ c: SandGrade.Choice) -> MapLayerID { MapLayerID(rawValue: "imagery.grade.\(c.rawValue)") }
    /// «ألوان الصور»: how the satellite picture is coloured (`SandGrade`). One choice of three, stored under
    /// `SandGrade.choiceKey`; the basemap, the high-res layer and CarPlay follow it live.
    static let imageryGrade: [MapLayerDescriptor] = SandGrade.Choice.allCases.map { c in
        MapLayerDescriptor(
            id: gradeID(c), title: c.label, detail: c.detail, systemImage: c.systemImage, category: .terrain,
            defaultOn: c == SandGrade.defaultChoice, conflicts: Set(SandGrade.Choice.allCases.filter { $0 != c }.map(gradeID)),
            persistence: .choice(key: SandGrade.choiceKey, value: c.rawValue), availableIn: [.home, .explore, .outing, .navigate],
            groupTitle: imageryGradeGroup, accessibilityID: "imagery.grade.\(c.rawValue)")
    }

    static func baseID(_ l: MapLayer) -> MapLayerID { MapLayerID(rawValue: "base.\(l.rawValue)") }

    /// The legacy value of a base layer (nil for any other layer).
    static func legacy(_ id: MapLayerID) -> MapLayer? { MapLayer.allCases.first { baseID($0) == id } }
}
