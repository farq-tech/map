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

        /// «مطعم · العليا، الرياض».
        var subtitle: String? {
            let parts = [category, detail].compactMap { $0?.isEmpty == false ? $0 : nil }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
    }

    enum SearchError: Error, Equatable {
        case noToken
        case network
        case http(Int)

        var arabic: String {
            switch self {
            case .noToken: return "البحث عن الأماكن غير مفعّل في هذه النسخة. أدخل إحداثية بدلًا منه."
            case .network: return "لا يوجد اتصال بالإنترنت. تقدر تدخل إحداثية بدون إنترنت."
            case .http: return "تعذّر البحث الآن. أعد المحاولة."
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
            let detail = (props["place_formatted"] as? String) ?? (props["full_address"] as? String).flatMap { $0 == name ? nil : $0 }
            let id = (f["id"] as? String) ?? (props["mapbox_id"] as? String) ?? "\(lat),\(lng)"
            let ctx = props["context"] as? [String: Any]
            let country = ((ctx?["country"] as? [String: Any])?["country_code"] as? String)?.uppercased()
            return Place(id: id, name: name, detail: detail, point: LngLat(lng: lng, lat: lat),
                         icon: icon(mapboxType: props["feature_type"] as? String), country: country)
        }
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
        let table: [(MKPointOfInterestCategory, [String])] = [
            (.gasStation, ["محطه بنزين", "محطات بنزين", "محطه وقود", "محطات وقود", "بنزين", "بنزينه", "وقود",
                           "gas station", "gas", "petrol", "petrol station", "fuel"]),
            (.pharmacy, ["صيدليه", "صيدليات", "pharmacy"]),
            (.hospital, ["مستشفي", "مستشفيات", "مستوصف", "طوارئ", "hospital"]),
            (.cafe, ["مقهي", "مقاهي", "كافيه", "كوفي", "قهوه", "cafe", "coffee"]),
            (.restaurant, ["مطعم", "مطاعم", "restaurant"]),
            (.hotel, ["فندق", "فنادق", "hotel"]),
            (.atm, ["صراف", "صراف الي", "atm"]),
            (.parking, ["موقف", "مواقف", "parking"]),
            (.foodMarket, ["بقاله", "تموينات", "سوبرماركت", "supermarket", "grocery"]),
        ]
        return table.first { $0.1.contains(q) }?.0
    }

    static let appleSearch: LocalSearch = { query, scope in
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        if case let .around(p) = scope, let cat = PlaceSearch.poiCategory(forQuery: q) {
            let poi = MKLocalPointsOfInterestRequest(center: CLLocationCoordinate2D(latitude: p.lat, longitude: p.lng),
                                                     radius: min(PlaceSearch.nearbyRadiusM / 2, MKLocalPointsOfInterestRequest.maxRadius))
            poi.pointOfInterestFilter = MKPointOfInterestFilter(including: [cat])
            if let resp = try? await MKLocalSearch(request: poi).start() {
                let found = resp.mapItems.compactMap { PlaceSearch.place(from: $0) }
                if !found.isEmpty { return found }
            }
        }
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = String(q.prefix(256))
        req.resultTypes = [.pointOfInterest, .address]
        req.region = PlaceSearch.region(scope)
        do {
            let resp = try await MKLocalSearch(request: req).start()
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
        guard let hit = table[c] else { return nil }
        return (hit.0, hit.1)
    }

    // MARK: - Together

    /// Apple (around you + the Kingdom) and Mapbox, asked at the same time. One source
    /// failing is fine; only when every source failed is it an error (Mapbox's, which says why).
    static func search(_ query: String, near: LngLat?, token: String? = PlaceSearch.token,
                       fetch: @escaping Fetch = PlaceSearch.liveFetch,
                       local: LocalSearch? = PlaceSearch.appleSearch) async throws -> [Place] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        let here = near.flatMap { PlanGeo.valid(lat: $0.lat, lng: $0.lng) ? $0 : nil }

        async let aroundR = apple(local, q, here.map { AppleScope.around($0) })
        async let saudiR = apple(local, q, .saudi)
        async let mapboxR = attempt { try await mapbox(q, near: here, token: token, fetch: fetch) }
        let (aroundRes, saudiRes, mb) = await (aroundR, saudiR, mapboxR)

        let appleAnswered = [aroundRes, saudiRes].contains { r in if case .success(_)? = r { return true } else { return false } }
        if !appleAnswered, case let .failure(e) = mb {
            /* Every source failed. */
            throw (e as? SearchError) ?? SearchError.network
        }
        return rank(query: q,
                    around: (try? aroundRes?.get()) ?? [],
                    saudi: (try? saudiRes?.get()) ?? [],
                    mapbox: (try? mb.get()) ?? [],
                    near: here)
    }

    /// nil when there is no Apple search or no scope to ask it in.
    private static func apple(_ local: LocalSearch?, _ q: String, _ scope: AppleScope?) async -> Result<[Place], Error>? {
        guard let local, let scope else { return nil }
        return await attempt { try await local(q, scope) }
    }

    private static func attempt(_ run: () async throws -> [Place]) async -> Result<[Place], Error> {
        do { return .success(try await run()) } catch { return .failure(error) }
    }

    /// One list, Google-Maps-like:
    /// 1. an exact name match (what you typed is the place's name), nearest first;
    /// 2. everything within `nearbyRadiusM` of you, nearest first;
    /// 3. the rest in Saudi Arabia, in the sources' own relevance order (Apple, then Mapbox);
    /// 4. outside Saudi Arabia last.
    /// Duplicates (the same name within 150 m) are dropped, keeping the first (Apple's, which has the category).
    static func rank(query: String, around: [Place], saudi: [Place], mapbox: [Place], near: LngLat?, limit: Int = PlaceSearch.maxResults) -> [Place] {
        var all: [Place] = []
        for p in stackedDropped(around + saudi) + mapbox where !all.contains(where: { duplicate($0, p) }) { all.append(p) }

        let nq = normalize(query)
        func dist(_ p: Place) -> Double { near.map { PlanGeo.meters($0, p.point) } ?? .infinity }
        func abroad(_ p: Place) -> Bool { p.country != nil && p.country != "SA" }

        let indexed = Array(all.enumerated())
        let exact = indexed.filter { !abroad($0.element) && !nq.isEmpty && normalize($0.element.name) == nq }
        let exactIds = Set(exact.map { $0.element.id })
        let rest = indexed.filter { !exactIds.contains($0.element.id) }
        let nearby = rest.filter { !abroad($0.element) && dist($0.element) <= nearbyRadiusM }
        let nearbyIds = Set(nearby.map { $0.element.id })
        let kingdom = rest.filter { !nearbyIds.contains($0.element.id) && !abroad($0.element) }
        let world = rest.filter { abroad($0.element) }

        let byDistance: ((offset: Int, element: Place), (offset: Int, element: Place)) -> Bool = {
            let a = dist($0.element), b = dist($1.element)
            return a == b ? $0.offset < $1.offset : a < b
        }
        let ordered = exact.sorted(by: byDistance) + nearby.sorted(by: byDistance) + kingdom + world
        return Array(ordered.map { $0.element }.prefix(limit))
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

    static func duplicate(_ a: Place, _ b: Place) -> Bool {
        if a.id == b.id { return true }
        let d = PlanGeo.meters(a.point, b.point)
        return d < 150 && normalize(a.name) == normalize(b.name)
    }

    /// Arabic-aware comparison key: no diacritics or tatweel, one alef, ة→ه, ى→ي, lowercase Latin.
    static func normalize(_ s: String) -> String {
        var out = ""
        for ch in s.folding(options: [.caseInsensitive, .widthInsensitive], locale: nil).unicodeScalars {
            switch ch.value {
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
