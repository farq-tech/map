import Foundation
import MapKit

/// Place search for «ابحث أو أدخل إحداثية» and «وين رايحين؟».
///
/// Two sources, asked together:
/// - **Apple Maps (MKLocalSearch)**: businesses and points of interest: «ماكدونالدز»,
///   «شاليهات», «محطة بنزين», «مستشفى»… Asked twice when we know where you are: once
///   around you (so a chain answers with its nearest branches) and once across Saudi Arabia.
/// - **Mapbox Geocoding v6**: districts, towns, roads, addresses and named areas (the source
///   this search always had; it carries no businesses, which is why «ماكدونالدز» found nothing).
///
/// Arabic and English are one search (`SearchLexicon`): «ستاربكس» and "Starbucks" ask the sources the same
/// two questions (the Arabic and the English form) and get the same list; a place is shown by its Arabic name
/// with the English one beside it when it differs.
///
/// Results near you come first, nearest first; then the rest of the Kingdom; then the world.
/// The query never carries who you are.
enum PlaceSearch {
    struct Place: Equatable, Identifiable {
        var id: String
        var name: String
        var detail: String?
        var point: LngLat
        /// «مطعم», «فندق»… (Apple's category, in Arabic) when known.
        var category: String? = nil
        /// SF Symbol for the row.
        var icon: String = "mappin"
        /// ISO country code when the source said so ("SA").
        var country: String? = nil
        /// The name in the other language ("Starbucks" beside «ستاربكس») when known and different.
        var altName: String? = nil
        /// Desert gazetteer area metadata; points retain the ordinary place-search behavior.
        var areaPolygon: [[LngLat]]? = nil
        var areaDistanceM: Double? = nil
        var areaApproach: LngLat? = nil

        /// «Starbucks · مقهى · العليا، الرياض».
        var subtitle: String? {
            let parts = [altName, category, detail].compactMap { $0?.isEmpty == false ? $0 : nil }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }

        /// The result row's detail line WITHOUT the other-language name (that one has its own small
        /// line, Build 36 item 11: Arabic and English mixed in one line): «مقهى · العليا، الرياض».
        var rowDetail: String? {
            let parts = [category, detail].compactMap { $0?.isEmpty == false ? $0 : nil }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }

        /// The name in the other language, shown small under the Arabic one; nil when the same.
        var secondaryName: String? {
            guard let a = altName?.trimmingCharacters(in: .whitespacesAndNewlines), !a.isEmpty,
                  PlaceSearch.normalize(a) != PlaceSearch.normalize(name) else { return nil }
            return a
        }

        /// Metres from `me` as the rows show it: to the nearest edge for an area (sand sea), else to the point.
        func meters(from me: LngLat?) -> Double? {
            areaDistanceM ?? me.map { PlanGeo.meters($0, point) }
        }
    }

    /// How a result list is ordered (the row of choices above it).
    enum ListOrder: String, CaseIterable, Equatable, Hashable {
        /// `rank`'s order: what you typed by name first, then near you, then the Kingdom.
        case relevance
        /// Nearest first.
        case nearest
        /// Grouped by kind («مقهى», «روضة»…), the kind with the nearest place first, nearest first inside.
        case kind

        var title: String {
            switch self {
            case .relevance: return "الأنسب"
            case .nearest: return "الأقرب"
            case .kind: return "حسب النوع"
            }
        }
    }

    /// The list in `order`. Stable: equal distances (and places with no distance, kept last) keep their
    /// relevance order. Without a position only `.kind` changes anything (groups in relevance order).
    static func ordered(_ places: [Place], by order: ListOrder, near: LngLat?) -> [Place] {
        let indexed: [(i: Int, p: Place, d: Double)] = places.enumerated().map { (i: $0.offset, p: $0.element, d: $0.element.meters(from: near) ?? .infinity) }
        func closer(_ a: (i: Int, p: Place, d: Double), _ b: (i: Int, p: Place, d: Double)) -> Bool {
            a.d == b.d ? a.i < b.i : a.d < b.d
        }
        switch order {
        case .relevance:
            return places
        case .nearest:
            return indexed.sorted(by: closer).map { $0.p }
        case .kind:
            /* Places with no kind form one group, always last. */
            var groups: [String: [(i: Int, p: Place, d: Double)]] = [:]
            var none: [(i: Int, p: Place, d: Double)] = []
            for x in indexed {
                if let c = x.p.category?.trimmingCharacters(in: .whitespacesAndNewlines), !c.isEmpty { groups[c, default: []].append(x) } else { none.append(x) }
            }
            let sortedGroups = groups.values.map { $0.sorted(by: closer) }.sorted { a, b in closer(a[0], b[0]) }
            return (sortedGroups.flatMap { $0 } + none.sorted(by: closer)).map { $0.p }
        }
    }

    enum SearchError: Error, Equatable {
        case noToken
        case network
        case http(Int)

        var arabic: String {
            switch self {
            case .noToken: return "البحث عن الأماكن مو شغال في هذي النسخة. اكتب إحداثية بداله."
            case .network: return "ما فيه إنترنت. تقدر تدخل إحداثية بدونه."
            case .http: return "البحث متعطّل من طرفنا الحين. جرّب بعد شوي، أو اضغط مطوّلًا على الخريطة."
            }
        }
    }

    /// Results within this distance of you are «قريب منك» and sorted by distance.
    static let nearbyRadiusM = 50_000.0
    static let maxResults = 15

    // MARK: - Mapbox (areas, towns, addresses)

    static let endpoint = URL(string: "https://api.mapbox.com/search/geocode/v6/forward")!

    static var token: String? {
        let t = (Bundle.main.object(forInfoDictionaryKey: "MBXAccessToken") as? String)?.trimmingCharacters(in: .whitespaces)
        guard let t, !t.isEmpty, !t.hasPrefix("$(") else { return nil }
        return t
    }

    /// The request URL. `saudiOnly` adds `country=sa` (the first pass).
    static func request(query: String, proximity: LngLat?, saudiOnly: Bool, token: String, limit: Int = 8) -> URLRequest? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return nil }
        var c = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = [
            .init(name: "q", value: String(q.prefix(256))),
            .init(name: "language", value: "ar"),
            .init(name: "limit", value: String(min(10, max(1, limit)))),
            .init(name: "autocomplete", value: "true"),
        ]
        if let p = proximity, PlanGeo.valid(lat: p.lat, lng: p.lng) {
            items.append(.init(name: "proximity", value: String(format: "%.4f,%.4f", p.lng, p.lat)))
        }
        if saudiOnly { items.append(.init(name: "country", value: "sa")) }
        items.append(.init(name: "access_token", value: token))
        c.queryItems = items
        guard let url = c.url else { return nil }
        var r = URLRequest(url: url, timeoutInterval: 10)
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        return r
    }

    /// GeoJSON FeatureCollection → places (features without a usable point are skipped).
    static func parse(_ data: Data) -> [Place] {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let feats = obj["features"] as? [[String: Any]] else { return [] }
        return feats.compactMap { f in
            let props = f["properties"] as? [String: Any] ?? [:]
            var lng: Double?, lat: Double?
            if let coords = props["coordinates"] as? [String: Any] {
                lng = coords["longitude"] as? Double
                lat = coords["latitude"] as? Double
            }
            if lng == nil, let g = f["geometry"] as? [String: Any], let c = g["coordinates"] as? [Double], c.count >= 2 {
                lng = c[0]; lat = c[1]
            }
            guard let lng, let lat, PlanGeo.valid(lat: lat, lng: lng) else { return nil }
            let name = (props["name_preferred"] as? String) ?? (props["name"] as? String) ?? (props["full_address"] as? String) ?? ""
            guard !name.isEmpty else { return nil }
            /* Mapbox leaves an empty part's separator in front («، الرياض، السعودية»). */
            let detail = ((props["place_formatted"] as? String) ?? (props["full_address"] as? String).flatMap { $0 == name ? nil : $0 })
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "،,").union(.whitespacesAndNewlines)) }
                .flatMap { $0.isEmpty ? nil : $0 }
            let id = (f["id"] as? String) ?? (props["mapbox_id"] as? String) ?? "\(lat),\(lng)"
            let ctx = props["context"] as? [String: Any]
            let country = ((ctx?["country"] as? [String: Any])?["country_code"] as? String)?.uppercased()
            let category = mapboxCategory(props)
            return Place(id: id, name: name, detail: detail, point: LngLat(lng: lng, lat: lat),
                         category: category, icon: icon(mapboxType: props["feature_type"] as? String), country: country)
        }
    }

    /// Mapbox's POI category has appeared as either `poi_category` or `category` across response versions.
    private static func mapboxCategory(_ properties: [String: Any]) -> String? {
        for key in ["poi_category", "category", "poi_category_ids"] {
            if let value = properties[key] as? String, !value.isEmpty { return value }
            if let values = properties[key] as? [String], let first = values.first(where: { !$0.isEmpty }) { return first }
        }
        return nil
    }

    static func icon(mapboxType: String?) -> String {
        switch mapboxType {
        case "address", "street": return "signpost.right"
        case "neighborhood", "locality": return "building.2"
        case "place", "district", "region": return "building.columns"
        default: return "mappin"
        }
    }

    typealias Fetch = (URLRequest) async throws -> (Data, Int)

    static let liveFetch: Fetch = { req in
        let (d, r) = try await URLSession.shared.data(for: req)
        return (d, (r as? HTTPURLResponse)?.statusCode ?? 0)
    }

    /// Mapbox: Saudi Arabia first; worldwide only when that found nothing.
    static func mapbox(_ query: String, near: LngLat?, token: String?, fetch: Fetch) async throws -> [Place] {
        guard let token else { throw SearchError.noToken }
        for saudi in [true, false] {
            try Task.checkCancellation()
            guard let req = request(query: query, proximity: near, saudiOnly: saudi, token: token) else { return [] }
            let data: Data, status: Int
            do { (data, status) = try await fetch(req) } catch { throw SearchError.network }
            guard (200..<300).contains(status) else { throw SearchError.http(status) }
            var found = parse(data)
            if saudi { found = found.map { var p = $0; p.country = p.country ?? "SA"; return p } }
            if !found.isEmpty { return found }
        }
        return []
    }

    // MARK: - Apple Maps (businesses and points of interest)

    enum AppleScope: Equatable {
        /// Around you (the nearest branches of a chain, the chalets near you).
        case around(LngLat)
        /// The whole Kingdom.
        case saudi
    }

    /// (query, scope) → places. Injected so tests never touch Apple's servers.
    typealias LocalSearch = (String, AppleScope) async throws -> [Place]

    /// Saudi Arabia's bounding region (roughly 16°–32.2° N, 34.5°–55.7° E).
    static let saudiRegion = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 24.1, longitude: 45.1),
                                                span: MKCoordinateSpan(latitudeDelta: 16.5, longitudeDelta: 21.5))

    static func region(_ scope: AppleScope) -> MKCoordinateRegion {
        switch scope {
        case let .around(p):
            return MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: p.lat, longitude: p.lng),
                                      latitudinalMeters: nearbyRadiusM * 1.2, longitudinalMeters: nearbyRadiusM * 1.2)
        case .saudi:
            return saudiRegion
        }
    }

    /// A query that names a kind of place («محطة بنزين», «صيدلية»…) rather than a place: Apple's natural-language
    /// search matches it against names (and answered «محطة بنزين» with a station in Kuwait), so around you it
    /// is asked as a category instead.
    static func poiCategory(forQuery query: String) -> MKPointOfInterestCategory? {
        let q = normalize(query)
        var table: [(MKPointOfInterestCategory, [String])] = [
            (.gasStation, ["محطه بنزين", "محطات بنزين", "محطه وقود", "محطات وقود", "بنزين", "بنزينه", "وقود",
                           "gas station", "gas", "petrol", "petrol station", "fuel"]),
            (.pharmacy, ["صيدليه", "صيدليات", "pharmacy"]),
            (.hospital, ["مستشفي", "مستشفيات", "مستوصف", "طوارئ", "hospital"]),
            (.cafe, ["مقهي", "مقاهي", "كافيه", "كوفي", "قهوه", "cafe", "coffee"]),
            (.restaurant, ["مطعم", "مطاعم", "restaurant"]),
            (.hotel, ["فندق", "فنادق", "hotel"]),
            (.airport, ["مطار", "مطارات", "airport", "airports"]),
            (.atm, ["صراف", "صراف الي", "atm"]),
            (.parking, ["موقف", "مواقف", "parking"]),
            (.foodMarket, ["بقاله", "تموينات", "سوبرماركت", "supermarket", "grocery"]),
        ]
        if #available(iOS 18.0, *) {
            table.append((.spa, ["سبا", "مساج", "تدليك", "spa", "massage", "day spa", "wellness"]))
        }
        return table.first { $0.1.contains(q) }?.0
    }

    static let appleSearch: LocalSearch = { query, scope in
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        if case let .around(p) = scope, let cat = PlaceSearch.poiCategory(forQuery: q) {
            let poi = MKLocalPointsOfInterestRequest(center: CLLocationCoordinate2D(latitude: p.lat, longitude: p.lng),
                                                     radius: min(PlaceSearch.nearbyRadiusM / 2, MKLocalPointsOfInterestRequest.maxRadius))
            poi.pointOfInterestFilter = MKPointOfInterestFilter(including: [cat])
            let poiSearch = MKLocalSearch(request: poi)
            if let resp = try? await withTaskCancellationHandler(operation: { try await poiSearch.start() },
                                                                  onCancel: { poiSearch.cancel() }) {
                let found = resp.mapItems.compactMap { PlaceSearch.place(from: $0) }
                if !found.isEmpty { return found }
            }
        }
        try Task.checkCancellation()
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = String(q.prefix(256))
        req.resultTypes = [.pointOfInterest, .address]
        req.region = PlaceSearch.region(scope)
        do {
            let search = MKLocalSearch(request: req)
            let resp = try await withTaskCancellationHandler(operation: { try await search.start() },
                                                              onCancel: { search.cancel() })
            return resp.mapItems.compactMap { PlaceSearch.place(from: $0) }
        } catch let e as MKError where e.code == .placemarkNotFound {
            return []
        } catch let e as MKError where e.code == .loadingThrottled {
            /* Apple rate-limits a device that types fast; Mapbox still answers. */
            return []
        } catch {
            throw PlaceSearch.SearchError.network
        }
    }

    static func place(from item: MKMapItem) -> Place? {
        let pm = item.placemark
        let c = pm.coordinate
        guard PlanGeo.valid(lat: c.latitude, lng: c.longitude), !(c.latitude == 0 && c.longitude == 0) else { return nil }
        let name = (item.name ?? pm.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        /* «حي العليا، الرياض» — short, without the country. */
        var parts: [String] = []
        for s in [pm.subLocality, pm.locality ?? pm.administrativeArea] {
            if let s, !s.isEmpty, s != name, !parts.contains(s) { parts.append(s) }
        }
        let cat = category(item.pointOfInterestCategory)
        return Place(id: "apple:\(String(format: "%.5f,%.5f", c.latitude, c.longitude)):\(name)",
                     name: name,
                     detail: parts.isEmpty ? nil : parts.joined(separator: "، "),
                     point: LngLat(lng: c.longitude, lat: c.latitude),
                     category: cat?.label,
                     icon: cat?.icon ?? (item.pointOfInterestCategory == nil ? "signpost.right" : "mappin"),
                     country: pm.isoCountryCode?.uppercased())
    }

    /// Apple's POI category → (Arabic label, SF Symbol). Unknown categories keep the plain pin.
    static func category(_ c: MKPointOfInterestCategory?) -> (label: String, icon: String)? {
        guard let c else { return nil }
        let table: [MKPointOfInterestCategory: (String, String)] = [
            .restaurant: ("مطعم", "fork.knife"),
            .cafe: ("مقهى", "cup.and.saucer.fill"),
            .bakery: ("مخبز", "birthday.cake"),
            .foodMarket: ("تموينات", "cart.fill"),
            .hotel: ("فندق وسكن", "bed.double.fill"),
            .campground: ("مخيم", "tent.fill"),
            .beach: ("شاطئ", "beach.umbrella.fill"),
            .park: ("حديقة", "tree.fill"),
            .nationalPark: ("متنزه وطني", "mountain.2.fill"),
            .gasStation: ("محطة وقود", "fuelpump.fill"),
            .evCharger: ("شاحن كهربائي", "bolt.car.fill"),
            .parking: ("موقف", "parkingsign"),
            .hospital: ("مستشفى", "cross.case.fill"),
            .pharmacy: ("صيدلية", "pills.fill"),
            .police: ("شرطة", "shield.lefthalf.filled"),
            .fireStation: ("دفاع مدني", "flame.fill"),
            .airport: ("مطار", "airplane"),
            .publicTransport: ("نقل عام", "bus.fill"),
            .carRental: ("تأجير سيارات", "car.fill"),
            .store: ("متجر", "bag.fill"),
            .bank: ("بنك", "banknote.fill"),
            .atm: ("صراف", "creditcard.fill"),
            .school: ("مدرسة", "graduationcap.fill"),
            .university: ("جامعة", "graduationcap.fill"),
            .museum: ("متحف", "building.columns.fill"),
            .stadium: ("ملعب", "sportscourt.fill"),
            .fitnessCenter: ("نادي رياضي", "figure.run"),
            .amusementPark: ("ملاهي", "ferriswheel"),
            .theater: ("مسرح", "theatermasks.fill"),
            .movieTheater: ("سينما", "film.fill"),
            .marina: ("مرسى", "sailboat.fill"),
            .zoo: ("حديقة حيوان", "pawprint.fill"),
            .postOffice: ("بريد", "envelope.fill"),
            .laundry: ("مغسلة", "washer.fill"),
        ]
        if #available(iOS 18.0, *), c == .spa { return ("سبا", "sparkles") }
        guard let hit = table[c] else { return nil }
        return (hit.0, hit.1)
    }

    // MARK: - Together

    /// Apple (around you + the Kingdom) and Mapbox, asked at the same time, for every form of the query
    /// (`SearchLexicon.plan`: the Arabic and the English one when every word is known). One source failing
    /// is fine; only when every source failed is it an error (Mapbox's, which says why).
    static func search(_ query: String, near: LngLat?, token: String? = PlaceSearch.token,
                       fetch: @escaping Fetch = PlaceSearch.liveFetch,
                       local: LocalSearch? = PlaceSearch.appleSearch) async throws -> [Place] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        let here = near.flatMap { PlanGeo.valid(lat: $0.lat, lng: $0.lng) ? $0 : nil }
        let forms = SearchLexicon.plan(q).forms

        /* Around you a kind of place is one category request whatever the language: ask it once. */
        var categories: Set<String> = []
        let aroundForms = forms.filter { f in poiCategory(forQuery: f).map { categories.insert($0.rawValue).inserted } ?? true }

        async let aroundR = gather(here.map { p in aroundForms.map { f in AppleJob(local, f, .around(p)) } } ?? [])
        async let saudiR = gather(forms.map { AppleJob(local, $0, .saudi) })
        async let mapboxR = gatherMapbox(forms) { f in try await mapbox(f, near: here, token: token, fetch: fetch) }
        let (aroundRes, saudiRes, mb) = await (aroundR, saudiR, mapboxR)

        let appleAnswered = (aroundRes + saudiRes).contains { if case .success = $0 { return true } else { return false } }
        let mapboxAnswered = mb.contains { if case .success = $0 { return true } else { return false } }
        if !appleAnswered, !mapboxAnswered, case let .failure(e)? = mb.first {
            /* Every source failed. */
            throw (e as? SearchError) ?? SearchError.network
        }
        func ok(_ r: [Result<[Place], Error>]) -> [Place] { r.flatMap { (try? $0.get()) ?? [] } }
        return rank(query: q, forms: forms, around: ok(aroundRes), saudi: ok(saudiRes), mapbox: ok(mb), near: here)
    }

    /// One Apple question; nil `local` (tests without Apple) asks nothing.
    private struct AppleJob {
        let local: LocalSearch?
        let query: String
        let scope: AppleScope
        init(_ local: LocalSearch?, _ query: String, _ scope: AppleScope) { self.local = local; self.query = query; self.scope = scope }
    }

    /// Runs the jobs together; answers come back in the jobs' order (so the list never depends on which
    /// source answered first).
    private static func gather(_ jobs: [AppleJob]) async -> [Result<[Place], Error>] {
        let live = jobs.filter { $0.local != nil }
        return await withTaskGroup(of: (Int, Result<[Place], Error>).self) { g in
            for (i, j) in live.enumerated() {
                g.addTask {
                    guard !Task.isCancelled else { return (i, .failure(CancellationError())) }
                    return (i, await attempt { try await j.local!(j.query, j.scope) })
                }
            }
            var out = [Result<[Place], Error>?](repeating: nil, count: live.count)
            for await (i, r) in g { out[i] = r }
            return out.compactMap { $0 }
        }
    }

    private static func gatherMapbox(_ forms: [String], _ run: @escaping @Sendable (String) async throws -> [Place]) async -> [Result<[Place], Error>] {
        await withTaskGroup(of: (Int, Result<[Place], Error>).self) { g in
            for (i, f) in forms.enumerated() {
                g.addTask {
                    guard !Task.isCancelled else { return (i, .failure(CancellationError())) }
                    return (i, await attempt { try await run(f) })
                }
            }
            var out = [Result<[Place], Error>?](repeating: nil, count: forms.count)
            for await (i, r) in g { out[i] = r }
            return out.compactMap { $0 }
        }
    }

    private static func attempt(_ run: () async throws -> [Place]) async -> Result<[Place], Error> {
        do { return .success(try await run()) } catch { return .failure(error) }
    }

    /// One list, Google-Maps-like:
    /// 1. an exact name match (what you typed is the place's name, in either language, or a branch of the chain
    ///    you typed), nearest first;
    /// 2. everything within `nearbyRadiusM` of you, nearest first;
    /// 3. the rest in Saudi Arabia, in the sources' own relevance order (Apple, then Mapbox);
    /// 4. outside Saudi Arabia last.
    /// Duplicates (`duplicate`: the same place in either language) are merged into the first (Apple's, which
    /// has the category), which keeps the other's name in the other language.
    /// `forms`: what the sources were asked (`SearchLexicon.plan`); an exact match is a match on any of them.
    static func rank(query: String, forms: [String]? = nil, around: [Place], saudi: [Place], mapbox: [Place], near: LngLat?,
                     limit: Int = PlaceSearch.maxResults) -> [Place] {
        let intent = SearchLexicon.categoryIntent(query)
        var all: [Place] = []
        var keys: [NameKeys] = []
        let candidates = (stackedDropped(around + saudi) + mapbox).map(localized).filter { p in
            guard let intent else { return true }
            return matches(p, intent: intent)
        }
        for p in candidates {
            let k = NameKeys(p)
            if let i = all.indices.first(where: { duplicate(all[$0], keys[$0], p, k) }) {
                all[i] = merged(all[i], p); keys[i] = NameKeys(all[i])
            } else { all.append(p); keys.append(k) }
        }

        let asked = forms ?? SearchLexicon.plan(query).forms
        let wanted = Set(asked.map(normalize)).subtracting([""])
        /* A chain's every branch is what you asked for («ستاربكس» finds "Starbucks Olaya" as much as «ستاربكس»). */
        let wantedBrands = Set(asked.compactMap { SearchLexicon.segments($0).count == 1 ? SearchLexicon.brandId($0) : nil })
        func containsWholeQuery(_ query: String, in name: String) -> Bool {
            guard query.count >= 3 else { return false }
            return name == query || name.hasPrefix(query + " ") || name.hasSuffix(" " + query) || name.contains(" " + query + " ")
        }
        let exactIds = Set(zip(all, keys).filter { _, k in
            !wantedBrands.isDisjoint(with: k.brands) || k.names.contains { name in wanted.contains { containsWholeQuery($0, in: name) } }
        }.map { $0.0.id })
        func isExact(_ p: Place) -> Bool { exactIds.contains(p.id) }
        func dist(_ p: Place) -> Double { near.map { PlanGeo.meters($0, p.point) } ?? .infinity }
        func abroad(_ p: Place) -> Bool { p.country != nil && p.country != "SA" }

        let indexed = Array(all.enumerated())
        let exact = indexed.filter { !abroad($0.element) && isExact($0.element) }
        let rest = indexed.filter { !(isExact($0.element) && !abroad($0.element)) }
        let nearby = rest.filter { !abroad($0.element) && dist($0.element) <= nearbyRadiusM }
        let nearbyIds = Set(nearby.map { $0.element.id })
        let kingdom = rest.filter { !nearbyIds.contains($0.element.id) && !abroad($0.element) }
        let world = rest.filter { abroad($0.element) }

        let byDistance: ((offset: Int, element: Place), (offset: Int, element: Place)) -> Bool = {
            let a = dist($0.element), b = dist($1.element)
            return a == b ? $0.offset < $1.offset : a < b
        }
        let categoryOnly = intent != nil && SearchLexicon.segments(query).count == 1
        let ordered: [(offset: Int, element: Place)]
        if categoryOnly {
            /* A category search is a local assistant: nearest matching place first, even when a farther
               result's name happens to repeat the category word. */
            ordered = indexed.filter { !abroad($0.element) }.sorted(by: byDistance) + world
        } else {
            ordered = exact.sorted(by: byDistance) + nearby.sorted(by: byDistance)
                + kingdom.sorted(by: byDistance) + world
        }
        return Array(ordered.map { $0.element }.prefix(limit))
    }

    /// Category searches are strict. Use structured source categories when present; for a result
    /// without category metadata (common in Mapbox geocoding), require the category in its name.
    private static func matches(_ place: Place, intent: SearchLexicon.Entry) -> Bool {
        let labels = SearchLexicon.categoryLabels(for: intent).map(normalize)
        if let category = place.category, !category.isEmpty {
            let actual = normalize(category)
            return labels.contains { label in
                actual == label || actual.hasPrefix(label + " ") || actual.hasSuffix(" " + label)
            }
        }
        let names = [place.name, place.altName].compactMap { $0 }.map(normalize)
        return labels.contains { label in
            names.contains { name in
                name == label || name.hasPrefix(label + " ") || name.hasSuffix(" " + label) || name.contains(" " + label + " ")
            }
        }
    }

    /// Apple puts businesses it cannot locate on a city's centre point: in Riyadh five «petrol stations» sat on
    /// exactly 24.7136,46.6753, shown as «٥ م» from you. Three or more differently named Apple places on one
    /// spot (~10 m) are that pile, not places: they are left out.
    static func stackedDropped(_ places: [Place]) -> [Place] {
        func cell(_ p: Place) -> String { String(format: "%.4f,%.4f", p.point.lat, p.point.lng) }
        var names: [String: Set<String>] = [:]
        for p in places { names[cell(p), default: []].insert(normalize(p.name)) }
        return places.filter { (names[cell($0)]?.count ?? 0) < 3 }
    }

    /// The same place: the same id; the same name, or the same words in the other language, within 150 m; or, within 60 m, the same
    /// brand («ستاربكس» / "Starbucks Olaya") or the same transliteration skeleton («ماكدونالدز» / "McDonald's").
    static func duplicate(_ a: Place, _ b: Place) -> Bool { duplicate(a, NameKeys(a), b, NameKeys(b)) }

    /// What a place's names compare by, worked out once per place.
    struct NameKeys {
        let names: Set<String>, concepts: Set<String>, brands: Set<String>, skeletons: Set<String>
        init(_ p: Place) {
            let all = [p.name, p.altName].compactMap { $0 }
            names = Set(all.map(PlaceSearch.normalize))
            brands = Set(all.compactMap(SearchLexicon.brandId))
            /* A chain's name is the same words at every branch: branches merge only within 60 m (brands).
               Don't let a type word turn a brand query ("Nahdi pharmacy") into a 150 m concept match. */
            concepts = Set(all.compactMap { name in
                let segments = SearchLexicon.segments(name)
                let containsBrand = segments.contains { segment in
                    if case let .known(entry) = segment { return entry.role == .brand }
                    return false
                }
                return containsBrand ? nil : SearchLexicon.conceptKey(name)
            })
            skeletons = Set(all.map(SearchLexicon.skeleton).filter { $0.count >= 4 })
        }
    }

    static func duplicate(_ a: Place, _ ka: NameKeys, _ b: Place, _ kb: NameKeys) -> Bool {
        if a.id == b.id { return true }
        let d = PlanGeo.meters(a.point, b.point)
        guard d < 150 else { return false }
        if !ka.names.isDisjoint(with: kb.names) { return true }
        /* «روضة خريم» and "Rawdat Khuraim": the same words in two languages. */
        if !ka.concepts.isDisjoint(with: kb.concepts) { return true }
        guard d < crossLanguageRadiusM else { return false }
        return !ka.brands.isDisjoint(with: kb.brands) || !ka.skeletons.isDisjoint(with: kb.skeletons)
    }

    /// Two names for one spot in two languages are one place within this distance.
    static let crossLanguageRadiusM = 60.0

    /// `keep` with what `other` knows that it does not: the name in the other language, the category.
    static func merged(_ keep: Place, _ other: Place) -> Place {
        var p = keep
        if p.altName == nil {
            p.altName = [other.name, other.altName].compactMap { $0 }
                .first { isArabic($0) != isArabic(p.name) && normalize($0) != normalize(p.name) }
        }
        if p.category == nil, let c = other.category { p.category = c; p.icon = other.icon }
        if p.country == nil { p.country = other.country }
        return localized(p)
    }

    /// Arabic name first, the English one beside it; a chain named only in English gets its Arabic name
    /// («Starbucks» → «ستاربكس» · Starbucks).
    static func localized(_ place: Place) -> Place {
        var p = place
        if p.altName == nil, let other = SearchLexicon.brandCounterpart(p.name) { p.altName = other }
        if !isArabic(p.name), let alt = p.altName, isArabic(alt) { p.altName = p.name; p.name = alt }
        if let alt = p.altName, normalize(alt) == normalize(p.name) { p.altName = nil }
        return p
    }

    static func isArabic(_ s: String) -> Bool { s.unicodeScalars.contains { (0x0600...0x06FF).contains($0.value) || (0xFB50...0xFEFF).contains($0.value) } }

    /// Arabic-aware comparison key: no diacritics or tatweel, one alef, ة→ه, ى→ي, Western digits,
    /// lowercase Latin without accents or apostrophes ("McDonald's" = "mcdonalds", "Café" = "cafe").
    static func normalize(_ s: String) -> String {
        var out = ""
        let latinFolded = s.unicodeScalars.contains { $0.value < 0x0250 && $0.properties.isAlphabetic && $0.value > 0x7F }
            ? s.folding(options: [.diacriticInsensitive], locale: nil) : s
        for ch in latinFolded.folding(options: [.caseInsensitive, .widthInsensitive], locale: nil).unicodeScalars {
            switch ch.value {
            case 0x0027, 0x2019, 0x02BC, 0x0060: continue // apostrophes: "McDonald's"
            case 0x0660...0x0669: out.unicodeScalars.append(Unicode.Scalar(ch.value - 0x0660 + 0x30)!) // ٠-٩
            case 0x06F0...0x06F9: out.unicodeScalars.append(Unicode.Scalar(ch.value - 0x06F0 + 0x30)!) // ۰-۹
            case 0x06A9: out.unicodeScalars.append("ك") // Persian kaf
            case 0x06CC: out.unicodeScalars.append("ي") // Persian yeh
            case 0x064B...0x065F, 0x0670, 0x0640: continue // tashkeel, superscript alef, tatweel
            case 0x0622, 0x0623, 0x0625, 0x0671: out.unicodeScalars.append("ا")
            case 0x0629: out.unicodeScalars.append("ه")
            case 0x0649: out.unicodeScalars.append("ي")
            case 0x0624: out.unicodeScalars.append("و")
            case 0x0626: out.unicodeScalars.append("ي")
            default: out.unicodeScalars.append(ch)
            }
        }
        return out.split(whereSeparator: { $0.isWhitespace || $0.isPunctuation }).joined(separator: " ")
    }
}
