import CoreLocation
import Foundation

/// «أماكن سابقة» بأسماء حقيقية: a point picked on the map or typed as a coordinate gets the nearest
/// meaningful name instead of a bare «نقطة على الخريطة»:
///
/// 1. a landmark Apple knows there (area of interest),
/// 2. the district and town («العليا، الرياض») or the street and town,
/// 3. in the desert: the nearest named place from OpenStreetMap (bundled, works offline), said
///    as a direction and distance — «شمال الثمامة بـ ١٢ كم» — or «قرب …» when it is right there,
/// 4. otherwise keep the pin generic instead of assigning a distant town or feature.
///
/// Answers are cached per ≈ 11 m cell on this phone, so a name is looked up once.
enum PlaceLabel {
    static let mapPoint = "نقطة على الخريطة"

    /// A name that says nothing about the place: empty, «نقطة على الخريطة», «الوجهة», or a coordinate.
    static func isGeneric(_ name: String) -> Bool {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if n.isEmpty || n == mapPoint || n == "الوجهة" || n == "نقطة" || n == "مكان محفوظ" { return true }
        return CoordinateParser.parse(n) != nil
    }

    /// «شمال الثمامة بـ ١٢ كم» / «قرب الثمامة»: a position, not a place name (an outing is not named after it).
    static func isRelative(_ name: String) -> Bool {
        name.hasPrefix("قرب ") || PlaceNamer.directions.contains { name.hasPrefix($0 + " ") && name.contains(" بـ ") }
    }
}

/// What the reverse geocoder said about a point.
struct GeocodeParts: Equatable {
    var areaOfInterest: String?
    var thoroughfare: String?
    var subLocality: String?
    var locality: String?
    var admin: String?
}

enum GeocodeAnswer: Equatable {
    case found(GeocodeParts)
    /// The geocoder answered: nothing there (the open desert).
    case nothing
    /// No answer (offline, rate-limited): try again another time.
    case failed
}

protocol ReverseGeocoding: Sendable {
    func lookup(_ p: LngLat) async -> GeocodeAnswer
}

/// Apple's reverse geocoder, in Arabic. Only the coordinate leaves the phone.
struct AppleReverseLookup: ReverseGeocoding {
    func lookup(_ p: LngLat) async -> GeocodeAnswer {
        let geocoder = CLGeocoder()
        return await withTaskCancellationHandler {
            do {
                let pms = try await geocoder.reverseGeocodeLocation(CLLocation(latitude: p.lat, longitude: p.lng), preferredLocale: Locale(identifier: "ar"))
                guard let pm = pms.first else { return .nothing }
                return .found(GeocodeParts(areaOfInterest: pm.areasOfInterest?.first, thoroughfare: pm.thoroughfare, subLocality: pm.subLocality,
                                           locality: pm.locality, admin: pm.administrativeArea))
            } catch let e as CLError where e.code == .geocodeFoundNoResult || e.code == .geocodeFoundPartialResult {
                return .nothing
            } catch {
                return .failed
            }
        } onCancel: {
            geocoder.cancelGeocode()
        }
    }
}

/// Named, offline desert places already bundled for «دليل البر». Reusing the canonical gazetteer
/// avoids shipping a second copy with weaker provenance or a different geographic boundary.
struct Gazetteer {
    struct Entry: Equatable {
        var name: String
        var point: LngLat
    }

    let entries: [Entry]

    static let shared = Gazetteer(entries: DesertGazetteer.bundled.places
        .filter { $0.kind != .camp && !$0.title.isEmpty }
        .map { Gazetteer.Entry(name: $0.title, point: $0.point) })

    init(entries: [Entry]) { self.entries = entries }

    /// The nearest named place, within `maxM` when given.
    func nearest(_ p: LngLat, maxM: Double? = nil) -> (entry: Entry, meters: Double)? {
        var best: (Entry, Double)?
        for e in entries {
            /* Cheap reject before the exact distance: 1° of latitude ≈ 111 km. */
            if let b = best, abs(e.point.lat - p.lat) * 110_000 > b.1 { continue }
            let d = Vehicle.distanceMeters(p, e.point)
            if best == nil || d < best!.1 { best = (e, d) }
        }
        guard let best, maxM.map({ best.1 <= $0 }) ?? true else { return nil }
        return best
    }
}

enum PlaceNamer {
    /// A nearby named desert place is the reference («شمال الثمامة بـ ١٢ كم»); farther pins stay generic.
    static let landmarkRadiusM = 40_000.0
    /// Closer than this it is simply «قرب …».
    static let nearM = 1_500.0

    static let directions = ["شمال", "شمال شرق", "شرق", "جنوب شرق", "جنوب", "جنوب غرب", "غرب", "شمال غرب"]

    /// Compass bearing (0 = north) → one of eight Arabic directions.
    static func direction(_ bearing: Double) -> String {
        let b = (bearing.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        return directions[Int((b + 22.5) / 45) % 8]
    }

    /// Where `p` is from a named place: «قرب الثمامة» or «شمال الثمامة بـ ١٢ كم».
    static func relative(_ e: Gazetteer.Entry, to p: LngLat) -> String {
        let d = Vehicle.distanceMeters(e.point, p)
        if d < nearM { return "قرب \(e.name)" }
        let km = max(2, Int((d / 1000).rounded()))
        return "\(direction(Vehicle.bearing(e.point, p))) \(e.name) بـ \(SaryFormat.number(km)) كم"
    }

    /// The best name for `p` from what the geocoder said (nil: it said nothing) and the bundled places.
    static func compose(_ g: GeocodeParts?, at p: LngLat, gazetteer: Gazetteer) -> String? {
        func clean(_ s: String?) -> String? {
            guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
            /* A bare number or a plus code is not a name. */
            if t.allSatisfy({ $0.isNumber || $0 == "-" || $0 == " " }) || t.contains("+") { return nil }
            return t
        }
        func join(_ a: String, _ b: String?) -> String {
            guard let b, b != a, !a.contains(b) else { return a }
            return "\(a)، \(b)"
        }
        /* Apple sometimes puts the region («إمارة منطقة حائل») where the town goes: that is no town. */
        func region(_ s: String?) -> Bool { s.map { $0.contains("منطقة") || $0.contains("إمارة") || $0.contains("امارة") } ?? false }
        let locality = region(g?.locality) ? nil : clean(g?.locality)
        let town = locality ?? (region(g?.admin) ? nil : clean(g?.admin))
        if let a = clean(g?.areaOfInterest) { return a }
        if let s = clean(g?.subLocality) { return join(s, town) }
        if let t = clean(g?.thoroughfare) { return join(t, town) }
        if let town { return town }
        if let near = gazetteer.nearest(p, maxM: landmarkRadiusM) { return relative(near.entry, to: p) }
        return region(g?.admin) ? nil : clean(g?.admin)
    }
}

/// Races an async lookup against a timeout without making the caller wait for a non-cooperative child.
private actor PlaceNameTimeoutRace {
    private var continuation: CheckedContinuation<String, Never>?
    private var lookupTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?

    func wait(seconds: Double, fallback: String, lookup: @escaping @Sendable () async -> String) async -> String {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                lookupTask = Task {
                    let value = await lookup()
                    await self.finish(value)
                }
                timerTask = Task {
                    let delay = seconds.isFinite ? min(60, max(0, seconds)) : 0
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    await self.finish(fallback)
                }
            }
        } onCancel: {
            Task { await self.finish(fallback) }
        }
    }

    private func finish(_ value: String) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: value)
        lookupTask?.cancel()
        timerTask?.cancel()
        lookupTask = nil
        timerTask = nil
    }
}

/// Names already found, per ≈ 11 m cell (this phone only; wiped with the account).
final class PlaceNameCache: @unchecked Sendable {
    static let key = "sary.placeNames.v1"
    static let max = 300

    private let defaults: UserDefaults
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    static func cell(_ p: LngLat) -> String { String(format: "%.4f,%.4f", p.lat, p.lng) }

    private var rows: [[String]] { defaults.array(forKey: Self.key) as? [[String]] ?? [] }

    func get(_ p: LngLat) -> String? {
        lock.lock(); defer { lock.unlock() }
        let c = Self.cell(p)
        return rows.last { $0.count == 2 && $0[0] == c }?[1]
    }

    func set(_ p: LngLat, _ name: String) {
        lock.lock(); defer { lock.unlock() }
        let c = Self.cell(p)
        var all = rows.filter { $0.count == 2 && $0[0] != c }
        all.append([c, name])
        defaults.set(Array(all.suffix(Self.max)), forKey: Self.key)
    }

    func forget() { defaults.removeObject(forKey: Self.key) }
}

/// Looks a point's name up once: the cache, else the geocoder plus the bundled places.
final class PlaceNameResolver: @unchecked Sendable {
    static let shared = PlaceNameResolver()

    let geocoder: ReverseGeocoding
    let cache: PlaceNameCache
    let gazetteer: Gazetteer

    init(geocoder: ReverseGeocoding = AppleReverseLookup(), cache: PlaceNameCache = PlaceNameCache(), gazetteer: Gazetteer = .shared) {
        self.geocoder = geocoder
        self.cache = cache
        self.gazetteer = gazetteer
    }

    /// The name for `p`; offline it still answers from the bundled places (and asks again next time).
    func name(for p: LngLat) async -> String {
        if let c = cache.get(p) { return c }
        let answer = await geocoder.lookup(p)
        var parts: GeocodeParts?
        if case let .found(g) = answer { parts = g }
        let text = PlaceNamer.compose(parts, at: p, gazetteer: gazetteer) ?? PlaceLabel.mapPoint
        if answer != .failed, text != PlaceLabel.mapPoint { cache.set(p, text) }
        return text
    }

    /// The same, but never longer than `seconds` (a slow network falls back to the bundled places).
    func name(for p: LngLat, within seconds: Double) async -> String {
        if let c = cache.get(p) { return c }
        let fallback = PlaceNamer.compose(nil, at: p, gazetteer: gazetteer) ?? PlaceLabel.mapPoint
        return await PlaceNameTimeoutRace().wait(seconds: seconds, fallback: fallback) { await self.name(for: p) }
    }
}

extension RecentPlaces {
    /// Gives every «نقطة على الخريطة» in the list its real name (looked up once, then cached) and
    /// saves it. Returns the list as it is now.
    @discardableResult
    static func resolveNames(defaults: UserDefaults = .standard, resolver: PlaceNameResolver = .shared) async -> [OutingDestination] {
        let generic = load(defaults: defaults).filter { PlaceLabel.isGeneric($0.name) }
        guard !generic.isEmpty else { return load(defaults: defaults) }
        var named: [(OutingDestination, String)] = []
        for d in generic {
            let n = await resolver.name(for: LngLat(lng: d.lng, lat: d.lat), within: 5)
            if !PlaceLabel.isGeneric(n) { named.append((d, n)) }
        }
        /* Re-read: a place may have been added meanwhile; rename only the entries that are still bare. */
        var all = load(defaults: defaults)
        for i in all.indices where PlaceLabel.isGeneric(all[i].name) {
            if let hit = named.first(where: { $0.0.lat == all[i].lat && $0.0.lng == all[i].lng }) {
                all[i].name = String(hit.1.prefix(TripPlan.destinationNameMax))
            }
        }
        if let d = try? JSONEncoder().encode(all) { defaults.set(d, forKey: key) }
        return all
    }
}
