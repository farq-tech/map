import Foundation

/// «أبي أي رابط جوجل، أي عنوان، يلقى اللوكيشن»: anything pasted into the search box becomes a point.
///
/// A. Local parse (`CoordinateParser`): decimal / DMS / plus codes / links that carry coordinates.
/// B. A link on a known maps host: short links (`maps.app.goo.gl`, `goo.gl/maps`, `g.co/kgs`) are followed
///    through their redirects (https only, known hosts only, 5 hops, 6 s in all, nothing sent but the URL);
///    the final URL is parsed, and a link that only names a place (`/maps/place/<Name>/`, `q=<text>`) has
///    that name geocoded with the app's own place search, biased by the last known position.
/// C. Free-text addresses are not handled here: they go to `PlaceSearch` exactly as before.
/// Saudi National Address codes («RARA6498») are recognised but cannot be resolved without the SPL service.
///
/// The pasted text is never logged. The network layer and the geocoder are injected so tests need no network.
enum LinkResolver {
    struct Resolved: Equatable {
        var point: LngLat
        /// The place name found in the link (or by the geocoder), when there is one.
        var name: String?
    }

    enum Failure: Error, Equatable {
        /// Not a link we are allowed to open, or a link with nothing to find.
        case unresolved
        /// «RARA6498»: needs the national address service (not available without a key).
        case nationalAddress

        var arabic: String {
            switch self {
            case .unresolved: return "ما قدرت أحدد الموقع من هذا الرابط"
            case .nationalAddress: return "هذا رمز عنوان وطني، لا أستطيع حلّه دون خدمة العناوين"
            }
        }
    }

    /// One redirect step: where does `url` send us next (nil = this is the final page)?
    protocol Network {
        func nextHop(from url: URL, timeout: TimeInterval) async throws -> URL?
    }

    typealias Geocode = (_ query: String, _ near: LngLat?) async throws -> [PlaceSearch.Place]

    static let maxHops = 5
    static let totalTimeout: TimeInterval = 6

    // MARK: classification

    /// "RARA6498" / "RARA 6498" / "RARA6498 حي الربيع الرياض": four letters then four digits, optional district/city.
    static func nationalAddress(_ raw: String) -> (code: String, rest: String)? {
        let s = CoordinateParser.normalize(raw)
        guard let m = CoordinateParser.match(#"^\s*([A-Za-z]{4})\s?(\d{4})(?:[\s,،]+(.+))?\s*$"#, s) else { return nil }
        return ((m[1] + m[2]).uppercased(), m[3])
    }

    /// The first link in the text (people paste «اسم المكان\nhttps://maps.app.goo.gl/…»), https-upgraded.
    static func extractURL(_ raw: String) -> URL? {
        let s = CoordinateParser.normalize(raw)
        guard s.count <= 2048 else { return nil }
        var token: String?
        if let m = CoordinateParser.match(#"(https?://[^\s<>"']+)"#, s) {
            token = m[1]
        } else if let m = CoordinateParser.match(#"((?:maps\.app\.goo\.gl|goo\.gl/maps|g\.co/kgs|(?:www\.|maps\.)?google\.[a-z.]+/maps|(?:ul\.|www\.)?waze\.com)[^\s<>"']*)"#, s) {
            token = "https://" + m[1]
        }
        guard var t = token else { return nil }
        while let last = t.last, ".,;:)»".contains(last) { t.removeLast() }
        if t.hasPrefix("http://") { t = "https://" + t.dropFirst(7) }
        return URL(string: t)
    }

    /// True when the search box should hand this text to `resolve` instead of the plain place search.
    static func needsResolution(_ raw: String) -> Bool {
        let s = CoordinateParser.normalize(raw)
        guard !s.isEmpty, s.count <= 2048 else { return false }
        if CoordinateParser.parse(s) != nil { return false }
        return nationalAddress(s) != nil || extractURL(s) != nil
    }

    /// Hosts we may open: Google (all country domains), goo.gl, maps.app.goo.gl, g.co, Waze.
    static func isAllowed(host: String?) -> Bool {
        guard let h = host?.lowercased(), !h.isEmpty else { return false }
        if ["goo.gl", "maps.app.goo.gl", "g.co", "waze.com"].contains(h) { return true }
        if h.hasSuffix(".waze.com") { return true }
        return CoordinateParser.match(#"^(?:[a-z0-9-]+\.)*google\.(?:com(?:\.[a-z]{2})?|co\.[a-z]{2}|[a-z]{2,3})$"#, h) != nil
    }

    private static func isShort(host: String?) -> Bool {
        guard let h = host?.lowercased() else { return false }
        return h == "goo.gl" || h == "maps.app.goo.gl" || h == "g.co"
    }

    private static func allowedHTTPS(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && isAllowed(host: url.host)
    }

    // MARK: name from a link

    /// `/maps/place/<Name>/…`, `/maps/search/<text>`, or `q=` / `query=` / `destination=` / `daddr=` / `address=` text.
    static func placeName(in url: URL) -> String? {
        func clean(_ v: String) -> String? {
            let t = v.replacingOccurrences(of: "+", with: " ").removingPercentEncoding?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard t.count >= 2, t.count <= 200, !t.hasPrefix("@"), CoordinateParser.parse(t) == nil else { return nil }
            return t
        }
        let path = url.path
        for marker in ["/maps/place/", "/maps/search/", "/place/", "/dir/"] {
            if let r = path.range(of: marker) {
                let tail = path[r.upperBound...]
                /* /dir/<from>/<to>: the destination is the last text segment. */
                let segs = tail.split(separator: "/").map(String.init).filter { !$0.hasPrefix("@") && !$0.hasPrefix("data=") }
                if let seg = (marker == "/dir/" ? segs.last : segs.first), let n = clean(seg) { return n }
            }
        }
        if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            for key in ["q", "query", "destination", "daddr", "address", "name"] {
                if let v = comps.queryItems?.first(where: { $0.name == key })?.value, let n = clean(v) { return n }
            }
        }
        return nil
    }

    // MARK: resolve

    static func resolve(_ raw: String, near: LngLat?, network: Network, geocode: Geocode) async -> Result<Resolved, Failure> {
        let s = CoordinateParser.normalize(raw)
        if extractURL(s) == nil, let p = CoordinateParser.parse(s) { return .success(Resolved(point: p.point, name: nil)) }
        if nationalAddress(s) != nil { return .failure(.nationalAddress) }
        guard var url = extractURL(s) else { return .failure(.unresolved) }
        guard allowedHTTPS(url) else { return .failure(.unresolved) }
        let deadline = Date().addingTimeInterval(totalTimeout)

        func local(_ u: URL) -> Resolved? {
            guard let p = CoordinateParser.parse(u.absoluteString) else { return nil }
            return Resolved(point: p.point, name: placeName(in: u))
        }
        if let r = local(url) { return .success(r) }

        /* Follow redirects only when the link can have any: short links, or nothing to geocode in it. */
        if isShort(host: url.host) || placeName(in: url) == nil {
            var hops = 0
            while true {
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else { return .failure(.unresolved) }
                let next: URL?
                do { next = try await network.nextHop(from: url, timeout: remaining) } catch { return .failure(.unresolved) }
                guard let n = next else { break }
                hops += 1
                guard hops <= maxHops else { return .failure(.unresolved) }
                var target = n
                /* EU consent wall: the real destination is in `continue`. */
                if target.host?.lowercased() == "consent.google.com",
                   let c = URLComponents(url: target, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "continue" })?.value,
                   let cu = URL(string: c) { target = cu }
                guard allowedHTTPS(target) else { return .failure(.unresolved) }
                url = target
                if let r = local(url) { return .success(r) }
            }
        }

        guard let name = placeName(in: url) else { return .failure(.unresolved) }
        guard let hit = (try? await geocode(name, near))?.first else { return .failure(.unresolved) }
        return .success(Resolved(point: hit.point, name: hit.name.isEmpty ? name : hit.name))
    }
}

// MARK: - live network

/// Follows one redirect at a time: the session never follows by itself, so every hop is checked by the resolver.
struct LiveLinkNetwork: LinkResolver.Network {
    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }

    func nextHop(from url: URL, timeout: TimeInterval) async throws -> URL? {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpCookieStorage = nil
        cfg.httpShouldSetCookies = false
        cfg.urlCredentialStorage = nil
        cfg.urlCache = nil
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: cfg, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "GET"
        req.setValue("Mozilla/5.0 (compatible)", forHTTPHeaderField: "User-Agent")
        let (_, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (300...399).contains(http.statusCode),
              let loc = http.value(forHTTPHeaderField: "Location"), let next = URL(string: loc, relativeTo: url)?.absoluteURL else { return nil }
        return next
    }
}

// MARK: - search-box glue (old UI and NewUI share it)

extension LinkResolver {
    static let rowLabel = "الموقع من الرابط"

    /// The rows for a pasted link / code, or the Arabic error to show. Never throws, never silent.
    static func lookup(_ raw: String, near: LngLat?,
                       network: Network = LiveLinkNetwork(),
                       geocode: @escaping Geocode = { q, n in try await PlaceSearch.search(q, near: n) }) async -> (places: [PlaceSearch.Place], error: String?) {
        switch await resolve(raw, near: near, network: network, geocode: geocode) {
        case .success(let r):
            let coords = CoordinateShare.displayDecimal(r.point)
            let place = PlaceSearch.Place(id: "link.\(coords)", name: r.name ?? coords, detail: r.name == nil ? nil : coords,
                                          point: r.point, category: rowLabel, icon: "link")
            return ([place], nil)
        case .failure(let f):
            return ([], f.arabic)
        }
    }
}
