import Foundation

/// «دليل البر»: the bundled, offline gazetteer of desert places (sand seas, rawdahs, faydahs and
/// suggested camp spots), built from open data by `scripts/desert-gazetteer` (OSM ODbL, GeoNames
/// CC BY 4.0, scripts/camp-sites). Read-only, on the phone; never asks a server.
///
/// The `id` is the identity of a place for everyone (other services take it as input):
/// `osm:<type>/<id>`, `geonames:<id>` or `camp:<site id>`, stable from one build to the next.
enum DesertKind: String, Codable, CaseIterable {
    case nafud, rawda, fayda, camp

    var arabic: String {
        switch self {
        case .nafud: return "نفود"
        case .rawda: return "روضة"
        case .fayda: return "فيضة"
        case .camp: return "كشتة مقترحة"
        }
    }

    var systemImage: String {
        switch self {
        case .nafud: return "mountain.2.fill"
        case .rawda: return "leaf.fill"
        case .fayda: return "drop.fill"
        case .camp: return "tent.fill"
        }
    }
}

struct DesertPlace: Identifiable, Equatable, Decodable {
    struct Source: Equatable, Decodable {
        var id: String
        var licence: String
    }

    var id: String
    var kind: DesertKind
    var nameAr: String?
    var nameEn: String?
    var alt: [String] = []
    var point: LngLat
    /// [west, south, east, north] when the source has an outline.
    var bbox: [Double]?
    /// Outer rings (simplified), when the source has an outline.
    var polygon: [[LngLat]]?
    var sources: [Source] = []
    /// Camp spots: the region and the rank in scripts/camp-sites.
    var region: String?
    var rank: Int?

    /// Arabic first; the Latin name when no source has an Arabic one.
    var title: String { nameAr ?? nameEn ?? "" }
    /// The other language under the title.
    var secondary: String? {
        if kind == .camp { return region.flatMap { Self.campRegions[$0] }.map { "مقترحة · \($0)" } }
        return nameAr != nil ? nameEn : nil
    }

    static let campRegions = ["thumamah": "الثمامة", "dahna": "الدهناء", "nafud": "النفود الكبير"]

    private enum K: String, CodingKey { case id, kind, alt, point, bbox, polygon, sources, region, rank, nameAr = "name_ar", nameEn = "name_en" }

    init(id: String, kind: DesertKind, nameAr: String?, nameEn: String? = nil, alt: [String] = [], point: LngLat,
         polygon: [[LngLat]]? = nil, sources: [Source] = [], region: String? = nil, rank: Int? = nil) {
        self.id = id; self.kind = kind; self.nameAr = nameAr; self.nameEn = nameEn; self.alt = alt; self.point = point
        self.polygon = polygon; self.sources = sources; self.region = region; self.rank = rank
        bbox = polygon.flatMap { DesertGeo.bbox($0) }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decode(DesertKind.self, forKey: .kind)
        nameAr = try c.decodeIfPresent(String.self, forKey: .nameAr)
        nameEn = try c.decodeIfPresent(String.self, forKey: .nameEn)
        alt = try c.decodeIfPresent([String].self, forKey: .alt) ?? []
        let p = try c.decode([Double].self, forKey: .point)
        guard p.count >= 2, PlanGeo.valid(lat: p[1], lng: p[0]) else {
            throw DecodingError.dataCorruptedError(forKey: .point, in: c, debugDescription: "point")
        }
        point = LngLat(lng: p[0], lat: p[1])
        bbox = try c.decodeIfPresent([Double].self, forKey: .bbox)
        polygon = try c.decodeIfPresent([[[Double]]].self, forKey: .polygon)?
            .map { ring in ring.compactMap { $0.count >= 2 ? LngLat(lng: $0[0], lat: $0[1]) : nil } }
            .filter { $0.count >= 3 }
        if polygon?.isEmpty == true { polygon = nil }
        sources = try c.decodeIfPresent([Source].self, forKey: .sources) ?? []
        region = try c.decodeIfPresent(String.self, forKey: .region)
        rank = try c.decodeIfPresent(Int.self, forKey: .rank)
    }

    /// Metres from `me` to this place: to the nearest edge of its outline (0 inside it), else to its point.
    func distance(from me: LngLat) -> Double {
        if let polygon { return DesertGeo.distanceToEdge(me, polygon) }
        return PlanGeo.meters(me, point)
    }

    /// Where a trip to it goes: the nearest point of the outline (a sand sea is reached at its
    /// edge), else its point.
    func approach(from me: LngLat) -> LngLat {
        guard let polygon, !DesertGeo.inside(me, polygon) else { return point }
        return DesertGeo.nearestOnEdge(me, polygon) ?? point
    }
}

/// Plane geometry around a point (equirectangular, fine at the scale of a country for "nearest").
enum DesertGeo {
    static let earth = 6_371_008.8

    static func bbox(_ rings: [[LngLat]]) -> [Double]? {
        let all = rings.flatMap { $0 }
        guard let f = all.first else { return nil }
        var b = [f.lng, f.lat, f.lng, f.lat]
        for p in all { b[0] = min(b[0], p.lng); b[1] = min(b[1], p.lat); b[2] = max(b[2], p.lng); b[3] = max(b[3], p.lat) }
        return b
    }

    static func inside(_ p: LngLat, ring: [LngLat]) -> Bool {
        var c = false
        var j = ring.count - 1
        for i in 0..<ring.count {
            let a = ring[i], b = ring[j]
            if (a.lat > p.lat) != (b.lat > p.lat), p.lng < (b.lng - a.lng) * (p.lat - a.lat) / (b.lat - a.lat) + a.lng { c.toggle() }
            j = i
        }
        return c
    }

    static func inside(_ p: LngLat, _ rings: [[LngLat]]) -> Bool { rings.contains { inside(p, ring: $0) } }

    /// The nearest point of the rings' edges to `p`, and its distance in metres.
    static func nearestEdge(_ p: LngLat, _ rings: [[LngLat]]) -> (point: LngLat, meters: Double)? {
        let k = cos(p.lat * .pi / 180)
        var best: (LngLat, Double)?
        for r in rings where r.count >= 2 {
            for i in 0..<r.count {
                let a = r[i], b = r[(i + 1) % r.count]
                let ax = (a.lng - p.lng) * k, ay = a.lat - p.lat
                let bx = (b.lng - p.lng) * k, by = b.lat - p.lat
                let dx = bx - ax, dy = by - ay
                let len = dx * dx + dy * dy
                let t = len == 0 ? 0 : max(0, min(1, -(ax * dx + ay * dy) / len))
                let x = ax + t * dx, y = ay + t * dy
                let d = (x * x + y * y).squareRoot()
                if best == nil || d < best!.1 { best = (LngLat(lng: p.lng + x / k, lat: p.lat + y), d) }
            }
        }
        return best.map { ($0.0, $0.1 * .pi / 180 * earth) }
    }

    static func distanceToEdge(_ p: LngLat, _ rings: [[LngLat]]) -> Double {
        if inside(p, rings) { return 0 }
        return nearestEdge(p, rings)?.meters ?? .infinity
    }

    static func nearestOnEdge(_ p: LngLat, _ rings: [[LngLat]]) -> LngLat? { nearestEdge(p, rings)?.point }
}

/// One result: the place and how far it is (to its edge for an outline).
struct DesertHit: Equatable, Identifiable {
    var place: DesertPlace
    var meters: Double
    var id: String { place.id }
    var inside: Bool { meters == 0 }
}

struct DesertGazetteer {
    var places: [DesertPlace] { didSet { searchNames = Self.normalizedNames(places) } }
    var attribution: [String] = []
    /// Each place's names, normalized once (`DesertName.normalize`) when the gazetteer is built, in
    /// the order of `places`; empty for camp suggestions (not names). Free text reads these.
    private(set) var searchNames: [[String]]

    init(places: [DesertPlace], attribution: [String] = []) {
        self.places = places
        self.attribution = attribution
        searchNames = Self.normalizedNames(places)
    }

    static func normalizedNames(_ places: [DesertPlace]) -> [[String]] {
        places.map { p in
            p.kind == .camp ? [] : ([p.nameAr, p.nameEn].compactMap { $0 } + p.alt).map(DesertName.normalize).filter { !$0.isEmpty }
        }
    }

    private struct File: Decodable {
        var version: Int
        var attribution: [String]?
        var entries: [Lossy]
    }

    /// One bad entry does not drop the file.
    private struct Lossy: Decodable {
        var place: DesertPlace?
        init(from decoder: Decoder) throws { place = try? DesertPlace(from: decoder) }
    }

    static func decode(_ data: Data) -> DesertGazetteer? {
        guard let f = try? JSONDecoder().decode(File.self, from: data), f.version == 1 else { return nil }
        return DesertGazetteer(places: f.entries.compactMap(\.place), attribution: f.attribution ?? [])
    }

    static let fileName = "desert-gazetteer"

    /// The bundled file, read once (empty when missing).
    static let bundled: DesertGazetteer = {
        guard let url = Bundle.main.url(forResource: fileName, withExtension: "json"),
              let data = try? Data(contentsOf: url), let g = decode(data) else { return DesertGazetteer(places: []) }
        return g
    }()

    /// Reads the bundled file on a background thread shortly after launch, so neither the launch
    /// nor the first search pays for it (`static let` is initialised once, thread-safely).
    static func prewarm(afterNanoseconds delay: UInt64 = 1_500_000_000) {
        Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: delay)
            _ = DesertGazetteer.bundled
        }
    }

    static let defaultAttribution = ["© OpenStreetMap contributors (ODbL 1.0)", "GeoNames (geonames.org), CC BY 4.0"]

    /// The places of one kind, nearest first (edge distance for outlines), at most `limit`.
    func nearest(_ kind: DesertKind, from me: LngLat, limit: Int = 30, maxMeters: Double = .infinity) -> [DesertHit] {
        guard limit > 0 else { return [] }
        /* A cheap lower bound first (an outline lies inside its bbox), nearest first, so only the
         * outlines that can still make the list get the exact edge distance. */
        let candidates = places.filter { $0.kind == kind }
            .map { (place: $0, bound: Self.lowerBound($0, from: me)) }
            .filter { $0.bound <= maxMeters }
            .sorted { $0.bound < $1.bound }
        var hits: [DesertHit] = []
        for c in candidates {
            if hits.count >= limit, c.bound > hits[limit - 1].meters { break }
            let meters = c.place.polygon == nil ? c.bound : c.place.distance(from: me)
            guard meters <= maxMeters else { continue }
            hits.append(DesertHit(place: c.place, meters: meters))
            hits.sort { ($0.meters, $0.place.id) < ($1.meters, $1.place.id) }
            if hits.count > limit { hits.removeLast() }
        }
        return hits
    }

    /// Never more than `p.distance(from: me)`: the exact distance for a point; for an outline, the
    /// distance to its bbox in the same plane geometry, less a margin for the bbox's rounding.
    static func lowerBound(_ p: DesertPlace, from me: LngLat) -> Double {
        guard p.polygon != nil else { return p.distance(from: me) }
        guard let b = p.bbox, b.count == 4 else { return 0 }
        let k = cos(me.lat * .pi / 180)
        let x = (min(max(me.lng, b[0]), b[2]) - me.lng) * k
        let y = min(max(me.lat, b[1]), b[3]) - me.lat
        return max(0, (x * x + y * y).squareRoot() * .pi / 180 * DesertGeo.earth - 200)
    }

    /// Free text: a known desert name in Arabic or Latin («الدهناء»، «نفود الثويرات»، «Rawdat Khuraym»).
    /// Whole-name and prefix matches first, then names that contain the words; nearest first within each.
    func search(_ query: String, near me: LngLat?, limit: Int = 6) -> [DesertHit] {
        let q = DesertName.normalize(query)
        guard q.count >= 3 else { return [] }
        var scored: [(Int, DesertHit)] = []
        for (i, p) in places.enumerated() where p.kind != .camp {
            var best = Int.max
            for n in searchNames[i] {
                if n == q { best = min(best, 0) } else if n.hasPrefix(q) { best = min(best, 1) } else if n.contains(q) { best = min(best, 2) }
            }
            guard best < Int.max else { continue }
            scored.append((best, DesertHit(place: p, meters: me.map { p.distance(from: $0) } ?? .infinity)))
        }
        return scored.sorted { ($0.0, $0.1.meters, $0.1.place.id) < ($1.0, $1.1.meters, $1.1.place.id) }.prefix(limit).map(\.1)
    }
}

/// Matching names across spellings: «الروضه» = «روضة», «Nafūd ath Thuwayrāt» = «nafud thuwayrat».
/// Mirrors `norm_ar` / `norm_en` in scripts/desert-gazetteer/gazetteer.py.
enum DesertName {
    private static let foldLocale = Locale(identifier: "en")

    static func normalize(_ s: String) -> String {
        var t = s.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: foldLocale)
        t = t.replacingOccurrences(of: "[\u{064B}-\u{065F}\u{0670}\u{0640}]", with: "", options: .regularExpression)
        for (a, b) in [("أ", "ا"), ("إ", "ا"), ("آ", "ا"), ("ٱ", "ا"), ("ة", "ه"), ("ى", "ي"), ("ؤ", "و"), ("ئ", "ي")] {
            t = t.replacingOccurrences(of: a, with: b)
        }
        t = t.replacingOccurrences(of: "[‘’'`ʿʾ´]", with: "", options: .regularExpression)
        let words = t.split(whereSeparator: { " -_/،,()".contains($0) }).map(String.init)
        let articles: Set<String> = ["al", "an", "ar", "at", "ad", "as", "az", "ash", "ath", "adh"]
        return words.compactMap { w -> String? in
            if articles.contains(w) { return nil }
            var w = w
            if w.hasPrefix("ال"), w.count > 3 { w = String(w.dropFirst(2)) }
            /* «التنهات» and «التنهاة» are spelled both ways. */
            if w.hasSuffix("ات"), w.count > 3 { w = String(w.dropLast()) + "ه" }
            return w
        }.joined(separator: " ")
    }
}
