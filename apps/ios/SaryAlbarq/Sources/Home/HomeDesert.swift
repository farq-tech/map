import Foundation

/// Pure rules of the desert chips and of «دليل البر» in the home search (unit-tested in
/// DesertGazetteerTests).
enum HomeDesertRules {
    /// Markers drawn on the map for a chip (the list holds more).
    static let onMap = 12
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
        g.search(q, near: near, limit: limit).map { h in
            let p = h.place
            return PlaceSearch.Place(id: "gazetteer:\(p.id)", name: p.title, detail: p.secondary, point: p.point,
                                     category: p.kind.arabic, icon: p.kind.systemImage, country: "SA")
        }
    }

    /// The gazetteer's rows first, then the place search's without the same place twice
    /// (same name, or within 2 km of a gazetteer point with a name that contains it).
    static func merge(desert: [PlaceSearch.Place], places: [PlaceSearch.Place], limit: Int = PlaceSearch.maxResults) -> [PlaceSearch.Place] {
        let names = Set(desert.map { DesertName.normalize($0.name) })
        let rest = places.filter { p in
            let n = DesertName.normalize(p.name)
            if names.contains(n) { return false }
            return !desert.contains { PlanGeo.meters($0.point, p.point) < 2000 && DesertName.normalize($0.name).contains(n) }
        }
        return Array((desert + rest).prefix(limit))
    }
}
