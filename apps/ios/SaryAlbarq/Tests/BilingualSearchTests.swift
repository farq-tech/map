import MapKit
import XCTest
@testable import SaryAlbarq

/// «ستاربكس» ≡ "Starbucks": normalisation, the lexicon, cross-language merging, and parity — an Arabic
/// query and its English twin give the same places in the same order (stubbed sources, no network).
final class BilingualSearchTests: XCTestCase {
    // MARK: normalisation

    func testNormalisation() {
        let n = PlaceSearch.normalize
        XCTAssertEqual(n("أإآا"), "اااا")
        XCTAssertEqual(n("مدرسة"), n("مدرسه"))
        XCTAssertEqual(n("مستشفى"), n("مستشفي"))
        XCTAssertEqual(n("الــريـاض"), "الرياض", "tatweel")
        XCTAssertEqual(n("مَطْعَمٌ"), "مطعم", "tashkeel")
        XCTAssertEqual(n("مخرج ١٥"), "مخرج 15", "Arabic-Indic digits")
        XCTAssertEqual(n("مخرج ۱۵"), "مخرج 15", "Eastern Arabic-Indic digits")
        XCTAssertEqual(n("  Starbucks   COFFEE "), "starbucks coffee")
        XCTAssertEqual(n("Café"), "cafe")
        XCTAssertEqual(n("McDonald’s"), "mcdonalds")
        XCTAssertEqual(n("کافی"), n("كافي"), "Persian kaf / yeh")
    }

    func testKeysDropTheArticle() {
        XCTAssertEqual(SearchLexicon.key("النهدي"), "نهدي")
        XCTAssertEqual(SearchLexicon.key("al"), "")
        XCTAssertEqual(SearchLexicon.aliasKey("Al-Nahdi"), "nahdi")
        XCTAssertEqual(SearchLexicon.aliasKey("ال"), "ال", "too short to be an article")
    }

    // MARK: lexicon

    func testLexiconHasNoCollisions() {
        XCTAssertEqual(SearchLexicon.collisions, [], "one alias, one meaning")
        XCTAssertGreaterThan(SearchLexicon.entries.count, 150)
    }

    func testBrandsAndCategoriesExpandBothWays() {
        XCTAssertEqual(SearchLexicon.plan("ستاربكس").forms, ["ستاربكس", "Starbucks"])
        XCTAssertEqual(SearchLexicon.plan("starbucks").forms, ["ستاربكس", "Starbucks"])
        XCTAssertEqual(SearchLexicon.plan("ستار بكس").forms, ["ستاربكس", "Starbucks"], "a spelling variant")
        XCTAssertEqual(SearchLexicon.plan("صيدلية النهدي").forms, ["صيدلية النهدي", "Nahdi Pharmacy"])
        XCTAssertEqual(SearchLexicon.plan("Al Nahdi pharmacy").forms, ["صيدلية النهدي", "Nahdi Pharmacy"])
        XCTAssertEqual(SearchLexicon.plan("محطة بنزين").forms, ["محطة بنزين", "Gas station"])
        XCTAssertEqual(SearchLexicon.plan("المطارات").forms, ["مطار", "Airport"], "plural airport query resolves to the airport category")
        XCTAssertEqual(SearchLexicon.plan("petrol station").forms, ["محطة بنزين", "Gas station"])
        XCTAssertEqual(SearchLexicon.plan("مستشفى الملك فيصل").forms, ["مستشفى الملك فيصل", "King Faisal Hospital"], "head last in English")
        XCTAssertEqual(SearchLexicon.plan("king faisal hospital").forms, ["مستشفى الملك فيصل", "King Faisal Hospital"], "head first in Arabic")
        XCTAssertEqual(SearchLexicon.plan("روضة خريم").forms, ["روضة خريم", "Rawdat Khuraim"], "a toponym stays in front")
        XCTAssertEqual(SearchLexicon.plan("Rawdah Khuraym").forms, ["روضة خريم", "Rawdat Khuraim"])
        XCTAssertEqual(SearchLexicon.plan("عبد العزيز").forms, SearchLexicon.plan("abdulaziz").forms)
        XCTAssertEqual(SearchLexicon.plan("مستشفى الملك فيصل التخصصي").forms, ["مستشفى الملك فيصل التخصصي", "King Faisal Specialist Hospital"],
                       "a named landmark beats its words")
    }

    func testUnknownWordsAreAskedAsTyped() {
        let p = SearchLexicon.plan("مطعم ابو زيد")
        XCTAssertFalse(p.complete)
        XCTAssertEqual(p.forms, ["مطعم ابو زيد", "ابو زيد"], "keep the full query and also search the named place without its type")
        XCTAssertEqual(SearchLexicon.plan("  ").forms, [])
    }

    func testMallQueryAddsPlaceOnlyFallback() {
        let plan = SearchLexicon.plan("الأندلس مول")
        XCTAssertEqual(plan.forms, ["الأندلس مول", "الأندلس"])
        XCTAssertFalse(plan.complete, "the proper place name is not in our dictionary")
    }

    func testCategoryIntentIsPreservedAlongsideAPlaceName() {
        XCTAssertEqual(SearchLexicon.categoryIntent("مساج")?.id, "spa")
        XCTAssertEqual(SearchLexicon.categoryIntent("spa")?.id, "spa")
        XCTAssertEqual(SearchLexicon.categoryIntent("بقالة")?.id, "supermarket")
        XCTAssertEqual(SearchLexicon.categoryIntent("مطار")?.id, "airport")
        XCTAssertEqual(SearchLexicon.categoryIntent("مطعم ابو زيد")?.id, "restaurant")
        XCTAssertNil(SearchLexicon.categoryIntent("مطعم مقهى"), "two categories are ambiguous")
    }

    func testCategoryIntentFiltersOutUnrelatedResults() {
        let spa = Self.poi("سبا الورد", 24.72, 46.68, category: "سبا")
        let massage = Self.poi("مركز مساج", 24.73, 46.69, category: "مساج")
        let restaurant = Self.poi("مطعم قريب", 24.714, 46.676, category: "مطعم")
        let spaResults = PlaceSearch.rank(query: "مساج", around: [restaurant, massage], saudi: [], mapbox: [spa], near: Self.me)
        XCTAssertEqual(Set(spaResults.map(\.name)), Set(["سبا الورد", "مركز مساج"]))

        let grocery = Self.poi("بقالة الحي", 24.72, 46.68, category: "تموينات")
        let shop = Self.poi("متجر قريب", 24.714, 46.676, category: "متجر")
        let groceryResults = PlaceSearch.rank(query: "بقالة", around: [shop, grocery], saudi: [], mapbox: [], near: Self.me)
        XCTAssertEqual(groceryResults.map(\.name), ["بقالة الحي"])
    }

    func testCategoryResultsAreNearestFirstAcrossSaudiArabia() {
        let far = PlaceSearch.Place(id: "far", name: "مطار الملك خالد", point: LngLat(lng: 46.6988, lat: 24.9576), category: "مطار", country: "SA")
        let near = PlaceSearch.Place(id: "near", name: "مطار محلي", point: LngLat(lng: 46.70, lat: 24.72), category: "مطار", country: "SA")
        let results = PlaceSearch.rank(query: "مطار", around: [], saudi: [far, near], mapbox: [], near: Self.me)
        XCTAssertEqual(results.map(\.id), ["near", "far"])
    }

    func testBrandCounterpartOnlyForAWholeBrandName() {
        XCTAssertEqual(SearchLexicon.brandCounterpart("Starbucks"), "ستاربكس")
        XCTAssertEqual(SearchLexicon.brandCounterpart("البيك"), "Al Baik")
        XCTAssertNil(SearchLexicon.brandCounterpart("Starbucks Olaya"))
        XCTAssertNil(SearchLexicon.brandCounterpart("صيدلية"), "a kind of place is not a name")
        XCTAssertEqual(SearchLexicon.brandId("Starbucks Olaya"), "starbucks")
    }

    func testSkeletonCrossesScripts() {
        XCTAssertEqual(SearchLexicon.skeleton("ستاربكس"), SearchLexicon.skeleton("Starbucks"))
        XCTAssertEqual(SearchLexicon.skeleton("ماكدونالدز"), SearchLexicon.skeleton("McDonald's"))
        XCTAssertEqual(SearchLexicon.skeleton("هرفي"), SearchLexicon.skeleton("Herfy"))
        XCTAssertNotEqual(SearchLexicon.skeleton("هرفي"), SearchLexicon.skeleton("Kudu"))
    }

    // MARK: merging

    static let me = LngLat(lng: 46.6753, lat: 24.7136)
    static func poi(_ name: String, _ lat: Double, _ lng: Double, category: String? = "مقهى") -> PlaceSearch.Place {
        PlaceSearch.Place(id: "apple:\(lat),\(lng):\(name)", name: name, detail: nil, point: LngLat(lng: lng, lat: lat),
                          category: category, icon: "mappin", country: "SA")
    }

    func testSameBranchInTwoLanguagesIsOneRowArabicFirst() {
        let ar = Self.poi("ستاربكس", 24.7180, 46.6800)
        let en = Self.poi("Starbucks", 24.71802, 46.68003) // ~3 m
        let other = Self.poi("Starbucks", 24.7200, 46.6830) // ~370 m: another branch
        let r = PlaceSearch.rank(query: "Starbucks", around: [en, ar, other], saudi: [], mapbox: [], near: Self.me)
        XCTAssertEqual(r.count, 2)
        XCTAssertEqual(r[0].name, "ستاربكس", "Arabic name first")
        XCTAssertEqual(r[0].altName, "Starbucks")
        XCTAssertEqual(r[0].subtitle, "Starbucks · مقهى")
        XCTAssertEqual(r[1].name, "ستاربكس", "an English-only branch gets its Arabic name from the lexicon")
        /* Build 36 item 11: the row keeps the languages apart — the English name on its own small line. */
        XCTAssertEqual(r[0].secondaryName, "Starbucks")
        XCTAssertEqual(r[0].rowDetail, "مقهى", "no English in the detail line")
    }

    // MARK: result rows and their order (Build 36 item 11)

    func testRowFieldsKeepTheLanguagesApart() {
        var p = PlaceSearch.Place(id: "1", name: "روضة خريم", detail: "أقرب طرف منك", point: Self.me, category: "روضة", altName: "Rawdat Khuraim")
        XCTAssertEqual(p.secondaryName, "Rawdat Khuraim")
        XCTAssertEqual(p.rowDetail, "روضة · أقرب طرف منك")
        XCTAssertEqual(p.subtitle, "Rawdat Khuraim · روضة · أقرب طرف منك", "the older one-line subtitle is unchanged")
        p.altName = "روضه خريم"
        XCTAssertNil(p.secondaryName, "the same name twice is not shown")
        p.altName = "  "
        XCTAssertNil(p.secondaryName)
        p.areaDistanceM = 1200
        XCTAssertEqual(p.meters(from: Self.me), 1200, "an area's distance is to its edge")
        p.areaDistanceM = nil
        XCTAssertNil(p.meters(from: nil))
    }

    func testOrderNearestAndByKindAreStable() {
        let far = Self.poi("مقهى بعيد", 24.80, 46.70)                       // ~10 km
        let near = Self.poi("مقهى قريب", 24.715, 46.676)                    // ~200 m
        let park = Self.poi("حديقة", 24.72, 46.68, category: "حديقة")      // ~900 m
        let none = Self.poi("مكان", 24.714, 46.6755, category: nil)          // ~40 m, no kind
        let list = [far, park, none, near]
        XCTAssertEqual(PlaceSearch.ordered(list, by: .relevance, near: Self.me).map(\.name), list.map(\.name))
        XCTAssertEqual(PlaceSearch.ordered(list, by: .nearest, near: Self.me).map(\.name), ["مكان", "مقهى قريب", "حديقة", "مقهى بعيد"])
        XCTAssertEqual(PlaceSearch.ordered(list, by: .kind, near: Self.me).map(\.name), ["مقهى قريب", "مقهى بعيد", "حديقة", "مكان"],
                       "the kind with the nearest place first, nearest first inside, no kind last")
        XCTAssertEqual(PlaceSearch.ordered(list, by: .nearest, near: nil).map(\.name), list.map(\.name), "no position: unchanged")
        XCTAssertEqual(PlaceSearch.ListOrder.allCases.map(\.title), ["الأنسب", "الأقرب", "حسب النوع"])
    }

    func testCrossLanguageMergeRules() {
        let a = Self.poi("ماكدونالدز", 24.7250, 46.6900)
        XCTAssertTrue(PlaceSearch.duplicate(a, Self.poi("McDonald's", 24.72502, 46.69004)), "brand, ~4 m")
        XCTAssertFalse(PlaceSearch.duplicate(a, Self.poi("McDonald's", 24.7260, 46.6900)), "brand, ~110 m: another branch")
        XCTAssertTrue(PlaceSearch.duplicate(Self.poi("كرسبي كريم", 24.7, 46.7), Self.poi("Krispy Kreme", 24.70003, 46.70002)), "skeleton, unknown brand")
        XCTAssertTrue(PlaceSearch.duplicate(Self.poi("روضة خريم", 25.38, 47.28), Self.poi("Rawdat Khuraim", 25.3805, 47.2804)), "same words, ~65 m")
        XCTAssertFalse(PlaceSearch.duplicate(Self.poi("هرفي", 24.7, 46.7), Self.poi("Kudu", 24.70001, 46.70001)), "two chains on one corner")
    }

    // MARK: parity (stubbed sources)

    struct Stubs: Decodable {
        struct P: Decodable { let name: String; let lat: Double; let lng: Double; let category: String?; let id: String?; let type: String? }
        let me: [String: Double]
        let pairs: [[String]]
        let apple: [String: [P]]
        let mapbox: [String: [P]]
    }

    static func stubs() throws -> Stubs {
        let url = try XCTUnwrap(Bundle(for: BilingualSearchTests.self).url(forResource: "bilingual-search-stubs", withExtension: "json"))
        return try JSONDecoder().decode(Stubs.self, from: Data(contentsOf: url))
    }

    /// Which stub keys the search asked (under a lock: sources are asked concurrently).
    final class Asked: @unchecked Sendable {
        private let lock = NSLock()
        private var keys: Set<String> = []
        func add(_ k: String) { lock.lock(); keys.insert(k); lock.unlock() }
        var all: Set<String> { lock.lock(); defer { lock.unlock() }; return keys }
    }

    static func run(_ query: String, _ s: Stubs, asked: Asked) async throws -> [PlaceSearch.Place] {
        let norm = PlaceSearch.normalize
        let apple = Dictionary(s.apple.map { (k, v) -> (String, (String, [Stubs.P])) in
            let parts = k.components(separatedBy: "|"); return (norm(parts[0]) + "|" + parts[1], (k, v))
        }, uniquingKeysWith: { a, _ in a })
        let mapbox = Dictionary(s.mapbox.map { (norm($0.key), ($0.key, $0.value)) }, uniquingKeysWith: { a, _ in a })
        let near = LngLat(lng: s.me["lng"]!, lat: s.me["lat"]!)
        return try await PlaceSearch.search(query, near: near, token: "T", fetch: { req in
            let items = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let q = items.first { $0.name == "q" }?.value ?? ""
            let saudi = items.contains { $0.name == "country" }
            guard saudi, let (key, ps) = mapbox[norm(q)] else { return (Data(#"{"features":[]}"#.utf8), 200) }
            asked.add("mapbox:" + key)
            let feats = ps.map { p in
                ["id": p.id ?? p.name, "type": "Feature", "geometry": ["type": "Point", "coordinates": [p.lng, p.lat]],
                 "properties": ["name": p.name, "feature_type": p.type ?? "place", "place_formatted": "الرياض، السعودية"]] as [String: Any]
            }
            return (try JSONSerialization.data(withJSONObject: ["type": "FeatureCollection", "features": feats]), 200)
        }, local: { q, scope in
            let tag: String
            switch scope { case .around: tag = "around"; case .saudi: tag = "saudi" }
            guard let (key, ps) = apple[norm(q) + "|" + tag] else { return [] }
            asked.add("apple:" + key)
            return ps.map { p in
                PlaceSearch.Place(id: "apple:\(String(format: "%.5f,%.5f", p.lat, p.lng)):\(p.name)", name: p.name, detail: nil,
                                  point: LngLat(lng: p.lng, lat: p.lat), category: p.category, icon: "mappin", country: "SA")
            }
        })
    }

    func testArabicAndEnglishTwinsGiveTheSameList() async throws {
        let s = try Self.stubs()
        let asked = Asked()
        var report: [String] = []
        for pair in s.pairs {
            let ar = try await Self.run(pair[0], s, asked: asked)
            let en = try await Self.run(pair[1], s, asked: asked)
            XCTAssertFalse(ar.isEmpty, pair[0])
            XCTAssertEqual(ar.map(\.id), en.map(\.id), "«\(pair[0])» ≡ \(pair[1])")
            XCTAssertEqual(ar, en, "«\(pair[0])» ≡ \(pair[1]): names and order too")
            report.append("\(pair[0]) ≡ \(pair[1]): \(ar.count) = \(en.count) \(ar.map(\.id) == en.map(\.id) ? "✓" : "✗") top «\(ar.first?.name ?? "-")»\(ar.first?.altName.map { " / \($0)" } ?? "")")
        }
        print("PARITY\n" + report.joined(separator: "\n"))
        let expected = Set(s.apple.keys.map { "apple:" + $0 } + s.mapbox.keys.map { "mapbox:" + $0 })
        XCTAssertEqual(expected.subtracting(asked.all), [], "every stubbed answer was asked for (the canonical forms are what the fixture says)")
    }

    func testTwinsMergeTheirBranches() async throws {
        let s = try Self.stubs()
        let starbucks = try await Self.run("Starbucks", s, asked: Asked())
        XCTAssertEqual(starbucks.map(\.name), ["ستاربكس", "Starbucks Olaya", "ستاربكس", "ستاربكس"], "every branch by distance; Jeddah last")
        XCTAssertEqual(starbucks.first?.altName, "Starbucks")
        XCTAssertEqual(starbucks.last?.point.lat ?? 0, 21.54, accuracy: 0.01, "two branches in both languages are two rows; Olaya; Jeddah")
        let hospital = try await Self.run("King Faisal hospital", s, asked: Asked())
        XCTAssertEqual(hospital.first?.name, "مستشفى الملك فيصل التخصصي")
        XCTAssertEqual(hospital.first?.altName, "King Faisal Specialist Hospital")
        let rawdah = try await Self.run("روضة خريم", s, asked: Asked())
        XCTAssertEqual(rawdah.map(\.name), ["روضة خريم"], "Apple's and Mapbox's are one place")
        XCTAssertEqual(rawdah.first?.altName, "Rawdat Khuraim")
        let gas = try await Self.run("gas station", s, asked: Asked())
        XCTAssertEqual(gas.map(\.name), ["الدريس", "ساسكو"], "Aldrees (Kingdom-wide, English) is the nearby الدريس")
    }

    /// Around you a kind of place is one category request, not one per language.
    func testCategoryIsAskedOnceAroundYou() async throws {
        let asked = PlaceSearchTests.Scopes()
        _ = try await PlaceSearch.search("صيدلية", near: Self.me, token: nil, fetch: { _ in (Data(), 200) }, local: { _, scope in
            asked.add(scope); return []
        })
        XCTAssertEqual(asked.all.filter { if case .around = $0 { return true } else { return false } }.count, 1)
        XCTAssertEqual(asked.all.filter { $0 == .saudi }.count, 2, "Kingdom-wide in both languages")
    }

    func testMallSearchCanFindAPlaceNamedAsACenter() async throws {
        let asked = Asked()
        let results = try await PlaceSearch.search("الأندلس مول", near: Self.me, token: nil,
                                                   fetch: { _ in (Data(), 200) },
                                                   local: { query, _ in
            asked.add("apple:" + query)
            guard PlaceSearch.normalize(query) == PlaceSearch.normalize("الأندلس") else { return [] }
            return [Self.poi("مركز الأندلس", 24.75, 46.73), Self.poi("مطعم قريب", 24.714, 46.676)]
        })
        XCTAssertTrue(asked.all.contains("apple:الأندلس مول"), "still ask the exact name the person typed")
        XCTAssertTrue(asked.all.contains("apple:الأندلس"), "also ask for the place without its generic type")
        XCTAssertEqual(results.first?.name, "مركز الأندلس", "the matching landmark outranks a closer unrelated result")
    }

    /// The benchmark list in docs/search-benchmark.md: every pair reads as the same query.
    func testBenchmarkPairsReadTheSame() {
        var miss: [String] = []
        for (ar, en) in Self.benchmark where SearchLexicon.plan(ar).forms != SearchLexicon.plan(en).forms {
            miss.append("\(ar) → \(SearchLexicon.plan(ar).forms) / \(en) → \(SearchLexicon.plan(en).forms)")
        }
        print("BENCHMARK plan parity: \(Self.benchmark.count - miss.count)/\(Self.benchmark.count)")
        XCTAssertEqual(miss, [])
    }

    static let benchmark: [(String, String)] = [
        // brands
        ("ستاربكس", "Starbucks"), ("ماكدونالدز", "McDonald's"), ("البيك", "Al Baik"), ("كودو", "Kudu"), ("هرفي", "Herfy"),
        ("صيدلية النهدي", "Nahdi pharmacy"), ("صيدلية الدواء", "Al Dawaa pharmacy"), ("بنده", "Panda"), ("جرير", "Jarir"), ("الدريس", "Aldrees"),
        // categories
        ("محطة بنزين", "gas station"), ("صيدلية", "pharmacy"), ("مستشفى", "hospital"), ("مطعم", "restaurant"), ("مقهى", "cafe"),
        ("فندق", "hotel"), ("صراف", "ATM"), ("مسجد", "mosque"),
        // landmarks
        ("مستشفى الملك فيصل", "King Faisal hospital"), ("مستشفى الملك فيصل التخصصي", "King Faisal Specialist Hospital"),
        ("جامعة الملك سعود", "King Saud University"), ("مطار الملك خالد", "King Khalid airport"), ("برج المملكة", "Kingdom Centre"),
        ("الرياض بارك", "Riyadh Park"), ("بوليفارد", "Boulevard"), ("قصر المصمك", "Masmak"), ("حافة العالم", "Edge of the World"),
        ("جامعة الأميرة نورة", "Princess Nourah University"),
        // desert and nature
        ("روضة خريم", "Rawdat Khuraim"), ("روضة التنهات", "Rawdat Tinhat"), ("نفود الثويرات", "Nafud Thuwayrat"), ("الثمامة", "Thumamah"),
        ("وادي حنيفة", "Wadi Hanifa"), ("جبل طويق", "Jabal Tuwaiq"), ("فيضة", "Faydah"),
        // districts and roads
        ("حي العليا", "Olaya district"), ("حي الملقا", "Malqa district"), ("طريق الملك فهد", "King Fahd Road"), ("شارع التحلية", "Tahlia Street"),
        ("الدائري الشمالي", "Northern Ring Road"),
    ]
}
