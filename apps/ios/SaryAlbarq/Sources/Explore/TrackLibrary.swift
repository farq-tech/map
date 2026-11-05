import Foundation

/// GPX tracks the person imported or exported (the plan's GPX import/export, `RouteFile`),
/// kept on this device so exploration can list them and draw them on the map.
struct SavedTrack: Codable, Equatable, Identifiable {
    enum Origin: String, Codable { case imported, exported }

    var id: String
    var name: String
    var origin: Origin
    var points: [LngLat]
    var createdAt: Date

    /// Length along the points, metres.
    var lengthM: Double {
        zip(points, points.dropFirst()).reduce(0) { $0 + PlanGeo.meters($1.0, $1.1) }
    }
}

enum TrackRules {
    static let maxTracks = 50

    static func cleanName(_ s: String?, origin: SavedTrack.Origin) -> String {
        let t = (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return String(t.prefix(60)) }
        return origin == .imported ? "مسار مستورد" : "مسار مصدَّر"
    }

    /// The same points saved twice (export the same plan again) is one entry.
    static func sameTrack(_ a: [LngLat], _ b: [LngLat]) -> Bool {
        guard a.count == b.count else { return false }
        return zip(a, b).allSatisfy { abs($0.lat - $1.lat) < 1e-6 && abs($0.lng - $1.lng) < 1e-6 }
    }
}

@MainActor
final class TrackLibrary: ObservableObject {
    static let shared = TrackLibrary()

    @Published private(set) var tracks: [SavedTrack] = []
    /// Tracks drawn on the map in exploration (this device).
    @Published var shown: Set<String> = [] {
        didSet { UserDefaults.standard.set(Array(shown), forKey: Self.shownKey) }
    }

    private static let shownKey = "sary.tracks.shown.v1"
    private let url: URL?

    init(fileName: String = "tracks-v1.json") {
        url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent(fileName)
        shown = Set(UserDefaults.standard.stringArray(forKey: Self.shownKey) ?? [])
        load()
    }

    private func load() {
        guard let url, let d = try? Data(contentsOf: url) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        tracks = (try? dec.decode([SavedTrack].self, from: d)) ?? []
    }

    private func save() {
        guard let url else { return }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? enc.encode(tracks).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// Adds (or refreshes) a track; returns its id. Points must be ≥ 2 (the importer guarantees it).
    @discardableResult
    func add(name: String?, origin: SavedTrack.Origin, points: [LngLat], now: Date = Date()) -> String? {
        guard points.count >= 2 else { return nil }
        if let i = tracks.firstIndex(where: { $0.origin == origin && TrackRules.sameTrack($0.points, points) }) {
            tracks[i].createdAt = now
            tracks[i].name = TrackRules.cleanName(name, origin: origin)
            let t = tracks.remove(at: i)
            tracks.insert(t, at: 0)
            save()
            return t.id
        }
        let t = SavedTrack(id: UUID().uuidString, name: TrackRules.cleanName(name, origin: origin), origin: origin, points: points, createdAt: now)
        tracks.insert(t, at: 0)
        if tracks.count > TrackRules.maxTracks {
            for old in tracks.suffix(tracks.count - TrackRules.maxTracks) { shown.remove(old.id) }
            tracks.removeLast(tracks.count - TrackRules.maxTracks)
        }
        save()
        return t.id
    }

    func delete(_ id: String) {
        tracks.removeAll { $0.id == id }
        shown.remove(id)
        save()
    }

    func toggleShown(_ id: String) {
        if shown.contains(id) { shown.remove(id) } else { shown.insert(id) }
    }

    func wipe() {
        tracks = []
        shown = []
        if let url { try? FileManager.default.removeItem(at: url) }
    }
}

extension RouteFile {
    /// A GPX 1.1 track of saved points (exploration's «شارك» for a library track).
    static func gpx(name: String, points: [LngLat]) -> String {
        var s = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="Sary Albarq" xmlns="http://www.topografix.com/GPX/1/1">
          <metadata><name>\(escape(name))</name></metadata>
          <trk>
            <name>\(escape(name))</name>
            <trkseg>

        """
        for p in points { s += "      <trkpt lat=\"\(String(format: "%.6f", p.lat))\" lon=\"\(String(format: "%.6f", p.lng))\"/>\n" }
        s += "    </trkseg>\n  </trk>\n</gpx>\n"
        return s
    }

    static func exportFile(name: String, points: [LngLat], dir: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let safe = name.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>\n")).joined().trimmingCharacters(in: .whitespaces)
        let url = dir.appendingPathComponent("\(safe.isEmpty ? "مسار" : safe).gpx")
        try gpx(name: name, points: points).write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

/// Stored as `{"lng":…, "lat":…}` in the on-device track file.
extension LngLat: Codable {
    private enum K: String, CodingKey { case lng, lat }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        self.init(lng: try c.decode(Double.self, forKey: .lng), lat: try c.decode(Double.self, forKey: .lat))
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        try c.encode(lng, forKey: .lng)
        try c.encode(lat, forKey: .lat)
    }
}
