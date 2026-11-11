import Foundation

/// Pure rules of the desert chips and of «دليل البر» in the home search (unit-tested in
/// DesertGazetteerTests).
enum HomeDesertRules {
    /// Markers drawn on the map for a chip (the list holds more).
    static let onMap = 12

    /// Issue #161: a city chip or a search listed places but drew nothing on the map. The same
    /// numbered markers as the desert chips, in the list's order (number = row), the first
    /// `onMap`. Google results (`gm:`) are never drawn (not ours to show).
    static func resultPins(_ ordered: [PlaceSearch.Place]) -> [DesertCategoryItem] {
        ordered.lazy.filter { !$0.id.hasPrefix("gm:") }.prefix(onMap).map {
            DesertCategoryItem(id: $0.id, title: $0.name, detail: $0.subtitle, point: $0.point,
                               meters: $0.areaDistanceM, systemImage: $0.icon, polygon: $0.areaPolygon,
                               approach: $0.areaApproach)
        }
    }
    /// Results the map fits on (with you).
    static let fitCount = 5

    static func heading(_ c: HomeCategory) -> String {
        switch c.desertSource {
        case .gazetteer(.nafud)?: return "النفود القريبة منك"
        case .gazetteer(.rawda)?: return "الروضات القريبة منك"
        case .gazetteer(.fayda)?: return "الفياض القريبة منك"
        case .gazetteer(.camp)?: return "أماكن مقترحة للكشتة"
        case .rainGreen?: return "أمطار وربيع قريبة منك"
        case nil: return "\(c.label) قريبة منك"
        }
    }

    static func footnote(_ c: HomeCategory?) -> String {
        switch c?.desertSource {
        case .gazetteer(.camp)?:
            return "\(CampReason.estimateNote). مرشحة من صور أقمار وبيانات مفتوحة (الثمامة، الدهناء، النفود). \(CampReason.legalNote)."
        case .gazetteer(.nafud)?:
            return "المسافة لأقرب طرف من الرمل. دليل البر: © OpenStreetMap (ODbL) · GeoNames (CC BY 4.0)."
        case .rainGreen?:
            return "مطر: NASA GPM IMERG · خضرة: NASA VIIRS · © OpenStreetMap"
        default:
            return "دليل البر: © OpenStreetMap (ODbL) · GeoNames (CC BY 4.0)."
        }
    }

    /// You and the first few results, for the camera.
    static func fitPoints(_ items: [DesertCategoryItem], me: LngLat?) -> [LngLat] {
        (me.map { [$0] } ?? []) + items.prefix(fitCount).map(\.point)
    }

    /// Free text against «دليل البر», as place-search rows.
    static func searchPlaces(_ g: DesertGazetteer, _ q: String, near: LngLat?, limit: Int = 5) -> [PlaceSearch.Place] {
        let hits: [DesertHit]
        if let kind = categoryKind(q) {
            hits = g.nearest(kind, from: near ?? GazetteerCategoryService.fallbackCenter, limit: limit)
        } else {
            hits = g.search(q, near: near, limit: limit)
        }
        return hits.map { h in
            let p = h.place
            let me = near ?? GazetteerCategoryService.fallbackCenter
            /* The other-language name (name_en) is `altName`, shown small on its own line — not mixed into
             * the detail line with the Arabic (Build 36 item 11). `subtitle` still lists it first. */
            let detail: String? = h.inside ? "أنت داخلها" : (p.polygon != nil ? "أقرب طرف منك" : nil)
            return PlaceSearch.Place(id: "gazetteer:\(p.id)", name: p.title, detail: detail, point: p.point,
                                     category: p.kind.arabic, icon: p.kind.systemImage, country: "SA", altName: p.secondary,
                                     areaPolygon: p.polygon, areaDistanceM: p.polygon == nil ? nil : h.meters,
                                     areaApproach: p.polygon.map { _ in p.approach(from: me) })
        }
    }

    /// Category-only desert queries use the local gazetteer's type and edge distance, not text matches
    /// from unrelated geocoders (for example a fuel station whose name happens to include «النفود»).
    static func categoryKind(_ query: String) -> DesertKind? {
        let stop: Set<String> = ["وين", "ابي", "ابغي", "اريد", "ابحث", "عن", "اقرب", "قريب", "مني", "من", "حول", "بالقرب", "عطني", "ورني", "دلني", "على", "where", "find", "show", "closest", "near", "me"]
        let words = SearchLexicon.rawWords(query).map(SearchLexicon.key).filter { !stop.contains($0) }
        guard words.count == 1,
              case let .known(entry)? = SearchLexicon.segments(words[0]).first,
              entry.role == .toponym else { return nil }
        switch entry.id {
        case "nafud": return .nafud
        case "rawdat": return .rawda
        case "faydat": return .fayda
        default: return nil
        }
    }

    /// The gazetteer's rows first, then the place search's without the same place twice
    /// (same name, or within 2 km of a gazetteer point with a name that contains it).
    static func merge(desert: [PlaceSearch.Place], places: [PlaceSearch.Place], limit: Int = PlaceSearch.maxResults,
                      desertOnly: Bool = false) -> [PlaceSearch.Place] {
        if desertOnly { return Array(desert.prefix(limit)) }
        /* Each gazetteer row's name normalized once, not once per place-search row. */
        let desertNames = desert.map { (point: $0.point, name: DesertName.normalize($0.name)) }
        let names = Set(desertNames.map { $0.name })
        let rest = places.filter { p in
            let n = DesertName.normalize(p.name)
            if names.contains(n) { return false }
            return !desertNames.contains { PlanGeo.meters($0.point, p.point) < 2000 && $0.name.contains(n) }
        }
        return Array((desert + rest).prefix(limit))
    }
}
