import Foundation

// «اقترح لي مكان كشتة» / «أماكن مقترحة للكشتة»: candidate camp sites from open satellite data,
// ranked on the phone with tonight's wind (scripts/camp-sites/README.md).
//
// The sites come from `scripts/camp-sites/build.py`: a transparent rule model over ESA
// WorldCover, Copernicus DEM GLO-30, Sentinel-2 L2A and OpenStreetMap — never Mapbox imagery
// (its terms forbid deriving data from the tiles; docs/AI-SATELLITE.md). Every hard exclusion
// (wadi beds and their flood buffer, ponding hollows, sabkha, steep ground, water, built-up,
// military, too remote) is applied there: an excluded cell never reaches the app.
// Here: tonight's wind (Open-Meteo) re-ranks them — the owner: «الريح عامل مؤثر جدًا».

/// One bundled candidate (a GeoJSON point feature).
struct CampSite: Identifiable, Equatable, Decodable {
    var id: String
    var region: String
    var lat: Double
    var lng: Double
    /// Static axes 0…1. Safety is a gate first (hard exclusions), then a scale.
    var safety: Double
    var comfort: Double
    var beauty: Double
    var access: Double
    /// Shelter 0…1 when the wind comes FROM N, NE, E, SE, S, SW, W, NW.
    var shelter: [Double]
    /// Static reason codes, strongest first (`CampReason`).
    var reasons: [String]
    /// Height above the nearest drainage channel, metres.
    var handM: Double
    var dChannelM: Double
    var dTrackM: Double
    var ground: String
    var nearName: String?
    var protected: String?

    var position: LngLat { LngLat(lng: lng, lat: lat) }

    private enum K: String, CodingKey { case geometry, properties }
    private enum G: String, CodingKey { case coordinates }
    private enum P: String, CodingKey {
        case id, region, safety, comfort, beauty, access, shelter, reasons, ground, protected
        case handM = "hand_m", dChannelM = "d_channel_m", dTrackM = "d_track_m", nearName = "near_name"
    }

    init(id: String, region: String = "test", lat: Double, lng: Double, safety: Double = 1, comfort: Double = 0.7, beauty: Double = 0.6,
         access: Double = 0.8, shelter: [Double] = Array(repeating: 0, count: 8), reasons: [String] = [], handM: Double = 5,
         dChannelM: Double = 800, dTrackM: Double = 600, ground: String = "sand", nearName: String? = nil, protected: String? = nil) {
        self.id = id; self.region = region; self.lat = lat; self.lng = lng
        self.safety = safety; self.comfort = comfort; self.beauty = beauty; self.access = access
        self.shelter = shelter; self.reasons = reasons; self.handM = handM; self.dChannelM = dChannelM; self.dTrackM = dTrackM
        self.ground = ground; self.nearName = nearName; self.protected = protected
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        let coords = try c.nestedContainer(keyedBy: G.self, forKey: .geometry).decode([Double].self, forKey: .coordinates)
        guard coords.count >= 2 else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "point")) }
        lng = coords[0]
        lat = coords[1]
        let p = try c.nestedContainer(keyedBy: P.self, forKey: .properties)
        id = try p.decode(String.self, forKey: .id)
        region = try p.decode(String.self, forKey: .region)
        safety = try p.decode(Double.self, forKey: .safety)
        comfort = try p.decode(Double.self, forKey: .comfort)
        beauty = try p.decode(Double.self, forKey: .beauty)
        access = try p.decode(Double.self, forKey: .access)
        shelter = try p.decode([Double].self, forKey: .shelter)
        reasons = try p.decode([String].self, forKey: .reasons)
        handM = try p.decode(Double.self, forKey: .handM)
        dChannelM = try p.decode(Double.self, forKey: .dChannelM)
        dTrackM = try p.decode(Double.self, forKey: .dTrackM)
        ground = try p.decodeIfPresent(String.self, forKey: .ground) ?? "bare"
        nearName = try p.decodeIfPresent(String.self, forKey: .nearName)
        protected = try p.decodeIfPresent(String.self, forKey: .protected)
    }
}

/// The bundled per-region files (`Resources/CampSites/camp-sites-<region>.geojson`).
enum CampSiteCatalog {
    static let regions = ["thumamah", "dahna", "nafud"]

    struct File: Decodable { var features: [CampSite] }

    static func decode(_ data: Data) -> [CampSite] {
        (try? JSONDecoder().decode(File.self, from: data))?.features ?? []
    }

    /// Every bundled site (read once).
    static let all: [CampSite] = regions.flatMap { r -> [CampSite] in
        guard let url = Bundle.main.url(forResource: "camp-sites-\(r)", withExtension: "geojson"),
              let data = try? Data(contentsOf: url) else { return [] }
        return decode(data)
    }

    static func url(_ region: String) -> URL? { Bundle.main.url(forResource: "camp-sites-\(region)", withExtension: "geojson") }
}

// MARK: - Tonight's wind

/// Tonight at the place: from now until 06:00 (at least 8 hours), from an Open-Meteo report.
struct CampNight: Equatable {
    var windKmh: Double
    var gustKmh: Double
    /// Where the wind comes FROM (vector mean, weighted by speed), degrees.
    var fromDeg: Double
    var rainProbability: Double
    var rainMm: Double
    /// µg/m³, nil when the air-quality call failed (never "no dust").
    var dust: Double?
    var pm10: Double?
    var sunset: Date?

    static let gustWarnKmh = 35.0
    static let gustNoKmh = 50.0

    enum Verdict: Equatable {
        case fine
        /// Gusts ≥ 35 km/h or dust: sheltered places first.
        case windy
        /// Gusts ≥ 50 km/h: not in the open tonight.
        case notTonight
    }

    var verdict: Verdict {
        if gustKmh >= Self.gustNoKmh { return .notTonight }
        if gustKmh >= Self.gustWarnKmh || dusty { return .windy }
        return .fine
    }

    var dusty: Bool { (dust ?? 0) >= 150 || (pm10 ?? 0) >= 300 }
    var rainy: Bool { rainProbability >= 40 || rainMm >= 1 }

    /// The hours of the report from `now` to the next 06:00 (at least 8 h).
    static func from(_ r: WeatherReport, now: Date, lat: Double, lng: Double, calendar: Calendar = .current) -> CampNight? {
        var cal = calendar
        cal.timeZone = TimeZone(identifier: "Asia/Riyadh") ?? .current
        let six = cal.nextDate(after: now, matching: DateComponents(hour: 6), matchingPolicy: .nextTime) ?? now.addingTimeInterval(12 * 3600)
        /* Until the morning, and at least the next 8 hours (a late question still gets a real night). */
        let morning = max(six, now.addingTimeInterval(8 * 3600))
        var hours = r.hours.filter { $0.time >= now.addingTimeInterval(-3600) && $0.time <= morning }
        if hours.isEmpty, let c = r.current { hours = [c] }
        guard !hours.isEmpty else { return nil }
        let speeds = hours.compactMap(\.windKmh)
        let gusts = hours.compactMap { $0.gustKmh ?? $0.windKmh }
        var u = 0.0, v = 0.0
        for h in hours {
            guard let d = h.windFromDeg else { continue }
            let w = max(h.windKmh ?? 1, 0.5)
            u += w * sin(d * .pi / 180)
            v += w * cos(d * .pi / 180)
        }
        let from = (atan2(u, v) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
        return CampNight(
            windKmh: speeds.isEmpty ? 0 : speeds.reduce(0, +) / Double(speeds.count),
            gustKmh: gusts.max() ?? 0, fromDeg: from,
            rainProbability: hours.compactMap(\.precipitationProbability).max() ?? 0,
            rainMm: hours.compactMap(\.precipitationMm).reduce(0, +),
            dust: r.airAvailable ? hours.compactMap(\.dust).max() : nil,
            pm10: r.airAvailable ? hours.compactMap(\.pm10).max() : nil,
            sunset: SunTimes.sunset(near: now, lat: lat, lng: lng))
    }
}

// MARK: - Ranking (mirrors scripts/camp-sites/model.py `total_score`)

enum CampRanker {
    static let weights = (comfort: 0.25, beauty: 0.35, access: 0.15)
    /// Rain tonight: only ground this high above the nearest channel, this far from it.
    static let rainHandM = 2.0
    static let rainChannelM = 300.0

    /// 0.25 in calm air → 0.6 at gusts of 50 km/h and more.
    static func windWeight(gustKmh: Double) -> Double {
        0.25 + 0.35 * min(1, max(0, (gustKmh - 15) / 35))
    }

    /// The 8-direction shelter interpolated to the wind's actual direction.
    static func shelter(_ s: [Double], fromDeg: Double) -> Double {
        guard s.count == 8 else { return 0 }
        let f = ((fromDeg.truncatingRemainder(dividingBy: 360)) + 360).truncatingRemainder(dividingBy: 360) / 45
        let i0 = Int(f.rounded(.down)) % 8
        let w = f - f.rounded(.down)
        return (1 - w) * s[i0] + w * s[(i0 + 1) % 8]
    }

    static func score(_ s: CampSite, night: CampNight?) -> Double {
        let base = weights.comfort + weights.beauty + weights.access
        let rest = (weights.comfort * s.comfort + weights.beauty * s.beauty + weights.access * s.access) / base
        /* No forecast means no defensible wind direction or gust estimate: do not quietly
         * assume a 20 km/h northerly and let that guessed shelter decide the order. */
        guard let night else { return rest * (0.7 + 0.3 * s.safety) }
        let ww = windWeight(gustKmh: night.gustKmh)
        let from = night.fromDeg
        let total = (1 - ww) * rest + ww * shelter(s.shelter, fromDeg: from)
        return total * (0.7 + 0.3 * s.safety)
    }

    /// Rain tonight («السيل يجي من مطر بعيد»): only the higher ground away from channels.
    static func allowed(_ s: CampSite, night: CampNight?) -> Bool {
        /* If the forecast failed, we cannot assert that distant rain is absent. Apply the
         * rain gate as a precaution and tell the person why the list is shorter. */
        guard night?.rainy == true || night == nil else { return true }
        return s.handM >= rainHandM && s.dChannelM >= rainChannelM
    }

    struct Ranked: Identifiable, Equatable {
        var site: CampSite
        var score: Double
        var distanceM: Double
        var id: String { site.id }
    }

    /// Inside a protected area (royal reserve, national park): never suggested, not merely warned.
    /// The build marks each site with the OSM protected polygon its cell falls in (`protected`); the
    /// polygons themselves are not bundled, so a margin around their edge cannot be applied on the phone.
    static func inProtectedArea(_ s: CampSite) -> Bool { s.protected != nil }

    /// Sites inside the radius that are skipped only because they lie in a protected area.
    static func protectedCount(_ sites: [CampSite], near me: LngLat, radiusKm: Double) -> Int {
        sites.filter { inProtectedArea($0) && Vehicle.distanceMeters(me, $0.position) <= radiusKm * 1000 }.count
    }

    /// «أحلى ٥» within the radius, best first.
    static func top(_ sites: [CampSite], near me: LngLat, radiusKm: Double, night: CampNight?, count: Int = 5) -> [Ranked] {
        sites.compactMap { s -> Ranked? in
            let d = Vehicle.distanceMeters(me, s.position)
            guard d <= radiusKm * 1000, !inProtectedArea(s), allowed(s, night: night) else { return nil }
            return Ranked(site: s, score: score(s, night: night), distanceM: d)
        }
        .sorted { $0.score != $1.score ? $0.score > $1.score : $0.distanceM < $1.distanceM }
        .prefix(count).map { $0 }
    }
}

// MARK: - Najdi wording

enum CampReason {
    static let text: [String: String] = [
        "flat": "أرض مستوية",
        "drains": "أرض أعلى شوي تصرّف الماء",
        "far_wadi": "بعيد عن مجرى السيل",
        "firm": "أرض صلبة قريبة توقف عليها السيارات",
        "soft": "رمل ناعم للفرشة",
        "sunset": "الغروب مفتوح",
        "view": "مطل على امتداد",
        "dark": "بعيد عن الأنوار، النجوم واضحة",
        "green": "قريب من خضرة",
        "quiet": "هادي، بعيد عن الخط والعزب",
        "track": "قريب من درب",
        "fame": "مكان معروف للكشتات",
    ]

    /// «شمالية»، «جنوبية غربية»… (the wind tonight).
    static func windAdjective(_ fromDeg: Double) -> String {
        let names = ["شمالية", "شمالية شرقية", "شرقية", "جنوبية شرقية", "جنوبية", "جنوبية غربية", "غربية", "شمالية غربية"]
        let d = (fromDeg.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        return names[Int((d + 22.5) / 45) % 8]
    }

    /// «الشمال»، «الجنوب الغربي»… (where the shelter faces).
    static func fromSide(_ fromDeg: Double) -> String {
        let names = ["الشمال", "الشمال الشرقي", "الشرق", "الجنوب الشرقي", "الجنوب", "الجنوب الغربي", "الغرب", "الشمال الغربي"]
        let d = (fromDeg.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        return names[Int((d + 22.5) / 45) % 8]
    }

    /// «في ظل طعس من الشمال» when tonight's wind is blocked here; nil otherwise.
    static func shelterLine(_ s: CampSite, night: CampNight?) -> String? {
        let from = night?.fromDeg ?? 0
        guard CampRanker.shelter(s.shelter, fromDeg: from) >= 0.5 else { return nil }
        let what = s.ground == "sand" ? "في ظل طعس" : "محمي بمرتفع"
        return "\(what) من \(fromSide(from))"
    }

    /// The card's top three: tonight's shelter first (when there is one), then the static ones.
    static func top3(_ s: CampSite, night: CampNight?) -> [String] {
        var out: [String] = []
        if let w = shelterLine(s, night: night) { out.append(w) }
        for c in s.reasons {
            guard var t = text[c] else { continue }
            if c == "fame", let n = s.nearName { t = "مكان معروف للكشتات (\(n))" }
            out.append(t)
            if out.count == 3 { break }
        }
        return out
    }

    /// «الريح الليلة: شمالية ٢٥ كم/س • المكان في ظل طعس من الشمال».
    static func windLine(_ s: CampSite, night: CampNight) -> String {
        var t = "الريح الليلة: \(windAdjective(night.fromDeg)) \(SaryFormat.number(Int(night.windKmh.rounded()))) كم/س"
        if night.gustKmh >= night.windKmh + 8 { t += "، هبّات \(SaryFormat.number(Int(night.gustKmh.rounded())))" }
        if let w = shelterLine(s, night: night) { t += " • المكان \(w)" } else { t += " • المكان مكشوف لها" }
        return t
    }

    static func verdictLine(_ n: CampNight) -> String? {
        switch n.verdict {
        case .notTonight: return "ريح قوية الليلة (هبّات \(SaryFormat.number(Int(n.gustKmh.rounded()))) كم/س): ما ننصح بالكشتة الليلة في المكشوف"
        case .windy: return n.dusty ? "فيه غبار الليلة: قدّمنا لك الأماكن المحمية من الريح" : "ريح نشطة الليلة: قدّمنا لك الأماكن المحمية من الريح"
        case .fine: return nil
        }
    }

    static func rainLine(_ n: CampNight) -> String? {
        n.rainy ? "فيه احتمال مطر: نعرض لك الأرض المرتفعة البعيدة عن الشعبان بس. لا تخيّم في وادي، السيل يجي من مطر بعيد" : nil
    }

    static let estimateNote = "تقدير من صور الأقمار، تأكد بعينك"
    static let weatherUnavailableNote = "ما وصلنا طقس بعض المناطق الليلة؛ ترتيبها بلا حساب الريح، واستبعدنا الأرض المنخفضة والقريبة من مجاري الأودية احتياطًا. تجنّب الأودية وتحقق من الطقس قبل الطلعة."
    static let legalNote = "الاحتطاب ممنوع، ولا تخيّم فوق النبات"
    static func protectedNote(_ name: String) -> String { "\(name): محمية، تأكد من التصريح قبل التخييم" }
}

// MARK: - The site's own name («روضة نورة»، «نفود الثمامة»)

/// What a camp card is called. Built by `CampNaming.resolve` (pure: a position + the gazetteer's
/// places ⇒ the words); never an invented name — a place with none stays «موقع كشتة».
struct CampPlaceName: Equatable {
    enum Relation: Equatable {
        /// Inside the place's outline («في نفود الثمامة»).
        case inside
        /// On the edge of the outline, within `CampNaming.edgeMeters` («على طرف نفود الثمامة»).
        case edge
        /// Near a gazetteer place, `meters` away («قرب روضة نورة • ٣ كم»).
        case near(meters: Double)
        /// The build's own `near_name` (a famous camping place within 4 km of the cell).
        case famous
        /// No name within reach: «موقع كشتة» + region + coordinates.
        case unnamed
    }

    var relation: Relation
    /// The place's own name; nil when `relation == .unnamed`.
    var name: String?
    /// The kind in words («روضة»، «نفود»، «فيضة»), when the name does not already say it.
    var kind: String?
    /// The region's Arabic name («الثمامة»), for the unnamed case.
    var region: String?
    var lat: Double
    var lng: Double

    /// The card's title: «في نفود الثمامة»، «قرب روضة نورة • ٣ كم»، «موقع كشتة».
    var title: String {
        switch relation {
        case .unnamed: return "موقع كشتة"
        default: return "\(routeTitle)\(distanceSuffix)"
        }
    }

    /// The same without the distance — what «اتجه» / «دروب البر» / the outing carry as the destination.
    var routeTitle: String {
        guard let name else { return "موقع كشتة" }
        switch relation {
        case .inside: return "في \(name)"
        case .edge: return "على طرف \(name)"
        case .near, .famous: return "قرب \(name)"
        case .unnamed: return "موقع كشتة"
        }
    }

    /// The bare destination for «اتجه» / «دروب البر» («إلى روضة نورة»): the name, else «موقع كشتة».
    var destinationName: String { name ?? "موقع كشتة" }

    private var distanceSuffix: String {
        guard case .near(let m) = relation else { return "" }
        let km = Int((m / 1000).rounded())
        /* RLM around the dot keeps it between the name and the digits in an RTL line. */
        let sep = " \u{200F}•\u{200F} "
        return km < 1 ? "\(sep)أقل من ١ كم" : "\(sep)\(SaryFormat.number(km)) كم"
    }

    /// The small line under the title when there is something to add (the kind; or, for an
    /// unnamed site, why it has no name: the region and the short coordinates).
    var subtitle: String? {
        if relation == .unnamed {
            let c = "\(SaryFormat.digits(String(format: "%.3f", lat)))، \(SaryFormat.digits(String(format: "%.3f", lng)))"
            return "ما له اسم معروف" + (region.map { " • \($0)" } ?? "") + " • \(c)"
        }
        return kind
    }
}

enum CampNaming {
    /// How far a place still names a site, per kind (m). Rawdahs are wide and few; a faydah is a
    /// small basin; sand ridges / sand seas name the ground you are on, so they must be close.
    static func reach(_ kind: DesertKind) -> Double {
        switch kind {
        case .rawda: return 15_000
        case .fayda: return 8_000
        case .nafud: return 5_000
        case .camp: return 0
        }
    }

    /// Within this of an outline's edge the site is «على طرف» it, not «قرب».
    static let edgeMeters = 300.0
    /// The build's `near_name` is within 4 km of the cell: it beats a gazetteer place farther than this.
    static let famousMeters = 4_000.0

    /// The words that already say what a name is («روضة نورة» says روضة).
    private static let kindWords = ["روضة", "رياض", "فيضة", "فياض", "نفود", "عرق", "عروق", "طعس", "طعوس", "نازية", "نوازي", "زبارة",
                                    "خيط", "خيوط", "نقا", "رملة", "شعيب", "خشم", "خشوم", "حرة", "قرية", "هجرة"]

    /// Names that only say the kind («فيضة») are not names.
    private static func isNamed(_ p: DesertPlace) -> Bool {
        guard let n = p.nameAr?.trimmingCharacters(in: .whitespaces), !n.isEmpty else { return false }
        return !(kindWords + [DesertKind.nafud.arabic, DesertKind.rawda.arabic, DesertKind.fayda.arabic]).contains(n)
    }

    private static func kindLabel(_ p: DesertPlace) -> String? {
        let n = p.nameAr ?? ""
        if kindWords.contains(where: { n.hasPrefix($0) }) { return nil }
        return p.kind.arabic
    }

    private static func area(_ p: DesertPlace) -> Double {
        guard let b = p.bbox, b.count == 4 else { return 0 }
        return (b[2] - b[0]) * (b[3] - b[1])
    }

    /// The best gazetteer place for a point: inside an outline first (the smallest one: the most
    /// specific), then the nearest within its kind's reach; ties by kind (rawda, nafud, fayda), then id.
    static func bestPlace(_ p: LngLat, in places: [DesertPlace]) -> DesertHit? {
        var hits: [DesertHit] = []
        for q in places where q.kind != .camp && isNamed(q) {
            let reach = reach(q.kind)
            if let b = q.bbox, b.count == 4, q.polygon != nil, p.lng < b[0] - 0.2 || p.lng > b[2] + 0.2 || p.lat < b[1] - 0.2 || p.lat > b[3] + 0.2 { continue }
            let m = DesertGazetteer.lowerBound(q, from: p) <= reach ? q.distance(from: p) : .infinity
            if m <= reach { hits.append(DesertHit(place: q, meters: m)) }
        }
        let rank: [DesertKind: Int] = [.rawda: 0, .nafud: 1, .fayda: 2, .camp: 3]
        let inside = hits.filter(\.inside).sorted { (area($0.place), rank[$0.place.kind]!, $0.place.id) < (area($1.place), rank[$1.place.kind]!, $1.place.id) }
        if let h = inside.first { return h }
        return hits.sorted { ($0.meters, rank[$0.place.kind]!, $0.place.id) < ($1.meters, rank[$1.place.kind]!, $1.place.id) }.first
    }

    /// (أ) the gazetteer's nearest name, (ب) the build's `near_name`, (د) the region + coordinates.
    /// There is no local list of towns/villages (OSM places are not bundled), so «قرب بلدة» is not offered.
    static func resolve(_ s: CampSite, places: [DesertPlace]) -> CampPlaceName {
        let region = DesertPlace.campRegions[s.region]
        func make(_ r: CampPlaceName.Relation, _ name: String?, _ kind: String?) -> CampPlaceName {
            CampPlaceName(relation: r, name: name, kind: kind, region: region, lat: s.lat, lng: s.lng)
        }
        let hit = bestPlace(s.position, in: places)
        let famous = s.nearName?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        if let h = hit, h.inside || h.meters <= famousMeters || famous == nil {
            let r: CampPlaceName.Relation = h.inside ? .inside : (h.place.polygon != nil && h.meters <= edgeMeters ? .edge : .near(meters: h.meters))
            return make(r, h.place.nameAr, kindLabel(h.place))
        }
        if let f = famous { return make(.famous, f, nil) }
        return make(.unnamed, nil, nil)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
