import Foundation

/// THE registration point (docs/ONE-MAP-UNIFICATION.md §5.2): to add a layer, add one
/// `MapLayerDescriptor` here. No sheet, screen or map view changes.
enum MapLayerCatalog {
    static let all: [MapLayerDescriptor] = base + weather + data + imagery

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

    /// The ONE key of the Qibla ray on the map (it used to be spelled out in three views).
    static let qiblaVisibleKey = "sary.map.qibla.visible.v1"
    static let weatherKey = "sary.map.weather.v1"
    static let campSitesKey = "sary.map.campSites.v1"
    static let osmTracksKey = "sary.map.osmTracks.v1"
    static let hiResKey = "sary.hires.user.v1"

    static let weatherKinds: [WeatherOverlayKind] = [.clouds, .rain, .wind, .green]
    static func weatherID(_ k: WeatherOverlayKind) -> MapLayerID { MapLayerID(rawValue: "weather.\(k.rawValue)") }
    /// The weather kind of a weather layer (nil for any other layer).
    static func weatherKind(_ id: MapLayerID) -> WeatherOverlayKind? { weatherKinds.first { weatherID($0) == id } }

    /// Weather overlays are drawn by the exploration map only (`WeatherOverlayRequest.active`), so the sheet offers them there.
    static let weather: [MapLayerDescriptor] = weatherKinds.map { k in
        MapLayerDescriptor(
            id: weatherID(k), title: k.label, detail: k.detail, systemImage: k.systemImage, category: .overlay,
            conflicts: Set(weatherKinds.filter { $0 != k }.map(weatherID)),
            persistence: .optionalChoice(key: weatherKey, value: k.rawValue, off: WeatherOverlayKind.none.rawValue),
            availableIn: [.explore], needsNetwork: true, groupTitle: "الطقس", accessibilityID: "weather.layer.\(k.rawValue)")
    }

    static let camp = MapLayerDescriptor(
        id: "data.camp", title: "أماكن مقترحة للكشتة", detail: "نقاط برتقالية على الخريطة", systemImage: "tent.fill", category: .data,
        persistence: .flag(key: campSitesKey), availableIn: [.explore, .outing, .navigate], accessibilityID: "explore-camp-sites")
    static let osmTracks = MapLayerDescriptor(
        id: "data.osmTracks", title: "مسارات البر (OSM)", detail: "طبعات الطرق الترابية مثل OsmAnd",
        systemImage: "point.topleft.down.to.point.bottomright.curvepath.fill", category: .data, defaultOn: true,
        persistence: .flag(key: osmTracksKey), availableIn: [.explore, .outing, .navigate], accessibilityID: "explore-osm-tracks")
    /// The Qibla ray: ONE registration for the three views that used to read the key separately.
    static let qibla = MapLayerDescriptor(
        id: "data.qibla", title: "اتجاه القبلة", detail: "خط القبلة من موقعك على الخريطة (يختفي أثناء التوجيه)",
        systemImage: "location.north.fill", category: .data, defaultOn: true,
        persistence: .flag(key: qiblaVisibleKey), availableIn: [.home, .explore, .outing], accessibilityID: "explore-qibla")
    static let data: [MapLayerDescriptor] = [camp, osmTracks, qibla]

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

    static func baseID(_ l: MapLayer) -> MapLayerID { MapLayerID(rawValue: "base.\(l.rawValue)") }

    /// The legacy value of a base layer (nil for any other layer).
    static func legacy(_ id: MapLayerID) -> MapLayer? { MapLayer.allCases.first { baseID($0) == id } }
}
