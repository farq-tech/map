import Foundation

// «مساري» on the real streets: map-matching.
//
// The smoothed trail (Kalman) is shown at once, offline. In the background, when
// there is internet, stretches of it are sent to a map-matching service which
// returns the road geometry actually driven; confident matches replace the
// smoothed line on the map and for «طريق العودة». Off-road (desert) there is no
// confident match and the smoothed line stays — that is the right answer there.
//
// PRIVACY (owner decision, 2026-11): trail coordinates now leave the phone ONLY to
// the map-matching provider (Mapbox today; the company's Valhalla `trace_route`
// later), never to our server or the live channel. The switch «طابق مساري مع
// الطرق» turns it off.

/// One point sent to the matcher.
struct MatchInput: Equatable {
    var lat: Double
    var lng: Double
    /// ms since 1970 (must increase).
    var t: Double
    /// Search radius, m (from the fix accuracy).
    var radiusM: Double
}

/// One confident piece of road geometry for consecutive inputs `first...last`.
struct MatchedPiece: Equatable {
    var first: Int
    var last: Int
    /// Road geometry, start to end.
    var coords: [LngLat]
    /// Where each matched input (by time) landed on `coords` (vertex index).
    var anchors: [(t: Double, index: Int)]
    var confidence: Double

    static func == (a: MatchedPiece, b: MatchedPiece) -> Bool {
        a.first == b.first && a.last == b.last && a.coords == b.coords && a.confidence == b.confidence
            && a.anchors.map(\.t) == b.anchors.map(\.t) && a.anchors.map(\.index) == b.anchors.map(\.index)
    }
}

enum TrailMatchError: Error, Equatable {
    case offline
    case http(Int)
    case badResponse
}

/// A road matcher. Mapbox Map Matching today; Valhalla `trace_route` can stand in
/// (same inputs: points + times + radii; same output: road geometry per input run).
protocol TrailMatchingService: Sendable {
    /// Up to `maxPoints` inputs. Returns only pieces worth showing (low confidence dropped by the caller).
    func match(_ pts: [MatchInput]) async throws -> [MatchedPiece]
    var maxPoints: Int { get }
}

// MARK: - Mapbox Map Matching v5

/// `GET https://api.mapbox.com/matching/v5/mapbox/driving/{coords}` with timestamps,
/// radiuses from accuracy, `tidy=true`, `geometries=polyline6`, ≤ 100 coordinates.
/// Pricing (Mapbox, 2026): 100,000 Map Matching requests free each month, then billed
/// per 1,000 (see mapbox.com/pricing — "Map Matching API").
struct MapboxTrailMatching: TrailMatchingService {
    let token: String
    var session: URLSession = .shared
    var maxPoints: Int { 100 }

    /// The app's public token (Info.plist `MBXAccessToken`); nil without one.
    static func fromBundle(_ b: Bundle = .main) -> MapboxTrailMatching? {
        guard let t = (b.object(forInfoDictionaryKey: "MBXAccessToken") as? String)?.trimmingCharacters(in: .whitespaces),
              t.hasPrefix("pk.") else { return nil }
        return MapboxTrailMatching(token: t)
    }

    /// Mapbox allows radiuses 0…50 m.
    static func radius(_ accuracy: Double?) -> Double {
        guard let a = accuracy, a.isFinite, a > 0 else { return 25 }
        return max(5, min(50, (a * 1.5).rounded()))
    }

    func url(_ pts: [MatchInput]) -> URL? {
        let coords = pts.map { String(format: "%.6f,%.6f", $0.lng, $0.lat) }.joined(separator: ";")
        var c = URLComponents(string: "https://api.mapbox.com/matching/v5/mapbox/driving/\(coords)")
        c?.queryItems = [
            URLQueryItem(name: "geometries", value: "polyline6"),
            URLQueryItem(name: "overview", value: "full"),
            URLQueryItem(name: "tidy", value: "true"),
            URLQueryItem(name: "timestamps", value: pts.map { String(Int64(($0.t / 1000).rounded())) }.joined(separator: ";")),
            URLQueryItem(name: "radiuses", value: pts.map { String(Int($0.radiusM)) }.joined(separator: ";")),
            /* Only the ends are legs: no artificial stops along the drive. */
            URLQueryItem(name: "waypoints", value: "0;\(pts.count - 1)"),
            URLQueryItem(name: "access_token", value: token),
        ]
        return c?.url
    }

    func match(_ pts: [MatchInput]) async throws -> [MatchedPiece] {
        guard pts.count >= 2, pts.count <= maxPoints, let u = url(pts) else { return [] }
        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await session.data(from: u)
        } catch {
            throw TrailMatchError.offline
        }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        /* 422 / NoMatch / NoSegment: nothing drivable near these points (desert): an answer, not an error. */
        if code == 422 { return [] }
        guard code == 200 else { throw TrailMatchError.http(code) }
        return try Self.parse(data, inputs: pts)
    }

    /// Matchings → pieces, with each tracepoint's place on the geometry.
    static func parse(_ data: Data, inputs: [MatchInput]) throws -> [MatchedPiece] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw TrailMatchError.badResponse }
        guard (root["code"] as? String) == "Ok" else { return [] }
        let matchings = root["matchings"] as? [[String: Any]] ?? []
        let tps = root["tracepoints"] as? [Any] ?? []
        var pieces: [MatchedPiece] = []
        for (k, m) in matchings.enumerated() {
            guard let g = m["geometry"] as? String else { continue }
            let coords = Polyline.decode(g, precision: 1e6)
            guard coords.count >= 2 else { continue }
            var idx: [Int] = []
            var locs: [LngLat] = []
            for (i, tp) in tps.enumerated() {
                guard let o = tp as? [String: Any], (o["matchings_index"] as? Int) == k,
                      let l = o["location"] as? [Double], l.count == 2 else { continue }
                idx.append(i)
                locs.append(LngLat(lng: l[0], lat: l[1]))
            }
            guard let first = idx.first, let last = idx.last, last < inputs.count else { continue }
            var anchors: [(t: Double, index: Int)] = []
            var from = 0
            for (j, i) in idx.enumerated() {
                let v = TrailMatchGeometry.nearestVertex(locs[j], in: coords, from: from)
                anchors.append((inputs[i].t, v))
                from = v
            }
            pieces.append(MatchedPiece(first: first, last: last, coords: coords, anchors: anchors, confidence: m["confidence"] as? Double ?? 0))
        }
        return pieces
    }
}

/// Valhalla `trace_route` (the company's own routing) — the same contract; the gateway
/// currently blocks `/trace_route`, so this is not wired in yet.
struct ValhallaTrailMatching: TrailMatchingService {
    let endpoint: URL
    var maxPoints: Int { 100 }
    func match(_ pts: [MatchInput]) async throws -> [MatchedPiece] {
        /* POST {"shape":[{lat,lon,time,radius}], "costing":"auto", "shape_match":"map_snap", "trace_options":{"search_radius":…}}
         * → trip.legs[].shape (polyline6) + matched_points[]. Enabled once the gateway allows it. */
        throw TrailMatchError.http(403)
    }
}

// MARK: - geometry helpers

enum Polyline {
    static func decode(_ s: String, precision: Double = 1e6) -> [LngLat] {
        var out: [LngLat] = []
        let b = Array(s.utf8)
        var i = 0, lat = 0, lng = 0
        func next() -> Int? {
            var result = 0, shift = 0
            while i < b.count {
                let c = Int(b[i]) - 63
                i += 1
                result |= (c & 0x1F) << shift
                shift += 5
                if c < 0x20 { return (result & 1) != 0 ? ~(result >> 1) : (result >> 1) }
            }
            return nil
        }
        while i < b.count {
            guard let dlat = next(), let dlng = next() else { break }
            lat += dlat
            lng += dlng
            out.append(LngLat(lng: Double(lng) / precision, lat: Double(lat) / precision))
        }
        return out
    }

    static func encode(_ pts: [LngLat], precision: Double = 1e6) -> String {
        var out = ""
        var plat = 0, plng = 0
        func put(_ v: Int) {
            var x = v < 0 ? ~(v << 1) : (v << 1)
            while x >= 0x20 {
                out.append(Character(UnicodeScalar(UInt8((0x20 | (x & 0x1F)) + 63))))
                x >>= 5
            }
            out.append(Character(UnicodeScalar(UInt8(x + 63))))
        }
        for p in pts {
            let la = Int((p.lat * precision).rounded()), ln = Int((p.lng * precision).rounded())
            put(la - plat)
            put(ln - plng)
            plat = la
            plng = ln
        }
        return out
    }
}

enum TrailMatchGeometry {
    /// Index of the vertex of `line` nearest to `p`, searching from `from` on.
    static func nearestVertex(_ p: LngLat, in line: [LngLat], from: Int = 0) -> Int {
        var best = max(0, min(from, line.count - 1)), bestD = Double.infinity
        for i in best..<line.count {
            let d = Vehicle.distanceMeters(p, line[i])
            if d < bestD { bestD = d; best = i }
        }
        return best
    }
}

// MARK: - planning: which points, in which chunks

enum TrailMatchPlanner {
    /// Points this close (and not a gap end) are skipped: Mapbox recommends sparse, well-spread inputs.
    static let minSpacingM = 20.0
    /// Each chunk repeats the previous chunk's last points, so the seam is cut in the middle of both.
    static let overlap = 10

    /// The inputs to send: trail points after `fromT`, thinned to `minSpacingM`, gap ends kept.
    static func inputs(_ pts: [TrailPoint], fromT: Double = -.infinity, accuracy: (Double) -> Double? = { _ in nil }) -> [MatchInput] {
        var out: [MatchInput] = []
        var last: TrailPoint?
        let sel = pts.filter { $0.t >= fromT }
        for (i, p) in sel.enumerated() {
            let isEnd = i == sel.count - 1
            if let l = last, !p.gap, !isEnd, Vehicle.distanceMeters(l.position, p.position) < minSpacingM { continue }
            if let l = last, p.t <= l.t { continue }
            out.append(MatchInput(lat: p.lat, lng: p.lng, t: p.t, radiusM: MapboxTrailMatching.radius(accuracy(p.t))))
            last = p
        }
        return out
    }

    /// Index ranges of at most `size` inputs, consecutive ranges sharing `overlap` inputs.
    static func chunks(count: Int, size: Int = 100, overlap: Int = overlap) -> [Range<Int>] {
        guard count >= 2 else { return [] }
        let step = max(1, size - overlap)
        var out: [Range<Int>] = []
        var s = 0
        while true {
            let e = min(count, s + size)
            out.append(s..<e)
            if e >= count { break }
            s += step
        }
        return out
    }
}

// MARK: - the cache of matched road geometry

/// One stretch of road geometry covering inputs from `startT` to `endT`.
struct MatchedSpan: Codable, Equatable {
    var startT: Double
    var endT: Double
    /// [lng, lat] pairs.
    var coords: [[Double]]
    /// Input times and the vertex each landed on (same length).
    var anchorT: [Double]
    var anchorI: [Int]
    var confidence: Double

    var line: [LngLat] { coords.map { LngLat(lng: $0[0], lat: $0[1]) } }

    init(piece p: MatchedPiece) {
        startT = p.anchors.first?.t ?? 0
        endT = p.anchors.last?.t ?? 0
        coords = p.coords.map { [($0.lng * 1e6).rounded() / 1e6, ($0.lat * 1e6).rounded() / 1e6] }
        anchorT = p.anchors.map(\.t)
        anchorI = p.anchors.map(\.index)
        confidence = p.confidence
    }

    /// Only the part from the anchor at/after `t` on (re-indexed).
    func from(_ t: Double) -> MatchedSpan? {
        guard let k = anchorT.firstIndex(where: { $0 >= t }) else { return nil }
        var s = self
        let cut = anchorI[k]
        s.coords = Array(coords[cut...])
        s.anchorT = Array(anchorT[k...])
        s.anchorI = anchorI[k...].map { $0 - cut }
        s.startT = s.anchorT[0]
        return s.coords.count >= 2 && s.anchorT.count >= 2 ? s : nil
    }

    /// Only the part up to the anchor at/before `t`.
    func upTo(_ t: Double) -> MatchedSpan? {
        guard let k = anchorT.lastIndex(where: { $0 <= t }) else { return nil }
        var s = self
        s.coords = Array(coords[...anchorI[k]])
        s.anchorT = Array(anchorT[...k])
        s.anchorI = Array(anchorI[...k])
        s.endT = s.anchorT.last!
        return s.coords.count >= 2 && s.anchorT.count >= 2 ? s : nil
    }
}

struct TrailMatchCache: Codable, Equatable {
    var spans: [MatchedSpan] = []
    /// Inputs up to this time have been sent (matched or found off-road).
    var doneUpToT: Double = -.infinity

    /// Below this, a match is a guess: keep the smoothed line.
    static let minConfidence = 0.25
    /// A match whose road is this far (median) from the smoothed points is not the road we drove.
    static let maxMedianOffsetM = 35.0

    /// Fold in one chunk's result. `cutT` is the seam with the previous chunk (middle of the overlap):
    /// the old geometry is kept up to it and the new from it on.
    mutating func integrate(_ pieces: [MatchedPiece], inputs: [MatchInput], cutT: Double?) {
        if let c = cutT {
            var kept: [MatchedSpan] = []
            for s in spans {
                if s.endT <= c { kept.append(s) } else if s.startT < c, let head = s.upTo(c) { kept.append(head) }
            }
            spans = kept
        }
        for p in pieces where Self.trustworthy(p, inputs: inputs) {
            var s = MatchedSpan(piece: p)
            if let c = cutT, s.startT < c {
                guard let tail = s.from(c) else { continue }
                s = tail
            }
            spans.append(s)
        }
        spans.sort { $0.startT < $1.startT }
        if let last = inputs.last { doneUpToT = max(doneUpToT, last.t) }
    }

    static func trustworthy(_ p: MatchedPiece, inputs: [MatchInput]) -> Bool {
        guard p.confidence >= minConfidence, p.coords.count >= 2, p.anchors.count >= 2 else { return false }
        var offs: [Double] = []
        for a in p.anchors {
            guard let inp = inputs.first(where: { $0.t == a.t }), a.index < p.coords.count else { continue }
            offs.append(Vehicle.distanceMeters(LngLat(lng: inp.lng, lat: inp.lat), p.coords[a.index]))
        }
        guard !offs.isEmpty else { return false }
        offs.sort()
        return offs[offs.count / 2] <= maxMedianOffsetM
    }
}

// MARK: - what the map draws

enum TrailDisplay {
    /// The trail with every confidently matched stretch replaced by its road geometry.
    /// A gap inside a matched stretch stays a gap — drawn dashed, but along the road.
    static func compose(_ pts: [TrailPoint], _ cache: TrailMatchCache?) -> [TrailPoint] {
        guard let cache, !cache.spans.isEmpty, pts.count >= 2 else { return pts }
        var out: [TrailPoint] = []
        var i = 0
        let spans = cache.spans
        var k = 0
        while i < pts.count {
            while k < spans.count, spans[k].endT < pts[i].t { k += 1 }
            guard k < spans.count, spans[k].startT <= pts[i].t, spans[k].endT > spans[k].startT else {
                out.append(pts[i])
                i += 1
                continue
            }
            let s = spans[k]
            /* The original points this span stands for. */
            var j = i
            while j < pts.count, pts[j].t <= s.endT { j += 1 }
            let covered = Array(pts[i..<j])
            let line = s.line
            for (n, c) in line.enumerated() {
                /* Which anchor interval this vertex is in, and was that stretch a gap? */
                var gap = false
                if n > 0 {
                    let a = s.anchorI.firstIndex(where: { $0 >= n }) ?? (s.anchorI.count - 1)
                    let t0 = a > 0 ? s.anchorT[a - 1] : s.startT, t1 = s.anchorT[a]
                    gap = covered.contains { $0.gap && $0.t > t0 && $0.t <= t1 }
                } else if let prev = out.last {
                    /* Joining from the previous part: a gap only if the first covered point said so. */
                    gap = covered.first?.gap == true && Vehicle.distanceMeters(prev.position, c) > 1
                }
                let t = interpolatedTime(n, s)
                if let l = out.last, Vehicle.distanceMeters(l.position, c) < 0.5 { continue }
                out.append(TrailPoint(lat: c.lat, lng: c.lng, t: t, gap: gap))
            }
            i = j
            k += 1
        }
        return out
    }

    private static func interpolatedTime(_ n: Int, _ s: MatchedSpan) -> Double {
        guard let a = s.anchorI.firstIndex(where: { $0 >= n }) else { return s.endT }
        if a == 0 || s.anchorI[a] == n { return s.anchorT[a] }
        let i0 = s.anchorI[a - 1], i1 = s.anchorI[a]
        let u = Double(n - i0) / Double(max(1, i1 - i0))
        return s.anchorT[a - 1] + (s.anchorT[a] - s.anchorT[a - 1]) * u
    }
}

// MARK: - storage next to the trail

enum TrailMatchStore {
    static func url(_ outingId: String, in dir: URL? = TrailStore.directory) -> URL? {
        dir?.appendingPathComponent(TrailStore.fileName(outingId).replacingOccurrences(of: ".json", with: ".match.json"))
    }

    static func load(_ outingId: String, in dir: URL? = TrailStore.directory) -> TrailMatchCache? {
        guard let u = url(outingId, in: dir), let d = try? Data(contentsOf: u) else { return nil }
        return try? JSONDecoder().decode(TrailMatchCache.self, from: d)
    }

    static func save(_ c: TrailMatchCache, outingId: String, in dir: URL? = TrailStore.directory) {
        guard let dir, let u = url(outingId, in: dir) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? JSONEncoder().encode(c).write(to: u, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func delete(_ outingId: String, in dir: URL? = TrailStore.directory) {
        guard let u = url(outingId, in: dir) else { return }
        try? FileManager.default.removeItem(at: u)
    }
}

/// «مساري» switch: send stretches of my trail to the road matcher (on by default, owner).
enum TrailMatchPrefs {
    static let key = "sary.trail.match.v1"
    static func enabled(_ d: UserDefaults = .standard) -> Bool { d.object(forKey: key) as? Bool ?? true }
}

// MARK: - GPX for diagnosis

enum TrailGPX {
    /// Raw fixes (with accuracy, speed, course), the smoothed trail and the road-matched trail as three tracks.
    static func document(name: String, raw: [RawFix], filtered: [TrailPoint], matched: [TrailPoint]) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func time(_ ms: Double) -> String { iso.string(from: Date(timeIntervalSince1970: ms / 1000)) }
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        var x = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="SaryAlbarq" xmlns="http://www.topografix.com/GPX/1/1" xmlns:sary="https://sary.sa/gpx/1">
        <metadata><name>\(esc(name))</name></metadata>

        """
        x += "<trk><name>raw</name><trkseg>\n"
        for f in raw {
            x += String(format: "<trkpt lat=\"%.7f\" lon=\"%.7f\"><time>%@</time><extensions>", f.lat, f.lng, time(f.t))
            if let a = f.acc { x += String(format: "<sary:acc>%.1f</sary:acc>", a) }
            if let s = f.spd { x += String(format: "<sary:speed>%.2f</sary:speed>", s) }
            if let c = f.crs { x += String(format: "<sary:course>%.1f</sary:course>", c) }
            if let s = f.spdAcc { x += String(format: "<sary:speedAcc>%.2f</sary:speedAcc>", s) }
            x += "</extensions></trkpt>\n"
        }
        x += "</trkseg></trk>\n"
        for (label, pts) in [("filtered", filtered), ("matched", matched)] {
            x += "<trk><name>\(label)</name><trkseg>\n"
            for p in pts {
                if p.gap { x += "</trkseg><trkseg>\n" }
                x += String(format: "<trkpt lat=\"%.7f\" lon=\"%.7f\"><time>%@</time></trkpt>\n", p.lat, p.lng, time(p.t))
            }
            x += "</trkseg></trk>\n"
        }
        x += "</gpx>\n"
        return x
    }

    /// Write the GPX for one outing (trail + raw log + match cache from this device) to a temp file.
    static func export(outingId: String, in dir: URL? = TrailStore.directory) -> URL? {
        let raw = TrailRawLog.load(outingId, in: dir)
        let trail = TrailStore.load(outingId, in: dir) ?? Trail.rebuild(raw)
        guard !raw.isEmpty || !trail.points.isEmpty else { return nil }
        let matched = TrailDisplay.compose(trail.points, TrailMatchStore.load(outingId, in: dir))
        let doc = document(name: "سَرى البارق • \(outingId)", raw: raw, filtered: trail.points, matched: matched)
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("sary-trail-\(TrailStore.fileName(outingId).replacingOccurrences(of: ".json", with: "")).gpx")
        do { try Data(doc.utf8).write(to: u, options: .atomic) } catch { return nil }
        return u
    }

    /// Outings with a trail on this device, newest first.
    static func outings(in dir: URL? = TrailStore.directory) -> [String] {
        TrailIO.drain()
        guard let dir, let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        let trails = files.filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasSuffix(".match.json") }
        let dated = trails.map { u in (u, (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        return dated.sorted { $0.1 > $1.1 }.map { $0.0.deletingPathExtension().lastPathComponent }
    }
}
