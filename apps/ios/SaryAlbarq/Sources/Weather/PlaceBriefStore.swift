import CoreLocation
import Foundation

/// The place brief's weather per ≈ 1 km cell: in memory and on disk, provider-agnostic
/// (it stores the parsed report and who gave it), so the desert shows the last reading with its real age.
final class PlaceWeatherCache: @unchecked Sendable {
    static let shared = PlaceWeatherCache()

    let directory: URL
    private var memory: [String: PlaceWeather] = [:]
    private let lock = NSLock()
    /// Same as the area cache: a 48 h forecast is over by then.
    static let keepS: TimeInterval = WeatherCache.keepS

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
            self.directory = base.appendingPathComponent("place-weather", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    private func file(_ a: WeatherArea) -> URL { directory.appendingPathComponent("\(a.key).json") }

    func load(_ a: WeatherArea) -> PlaceWeather? {
        lock.lock()
        if let m = memory[a.key] { lock.unlock(); return m }
        lock.unlock()
        let dec = JSONDecoder()
        guard let d = try? Data(contentsOf: file(a)), let w = try? dec.decode(PlaceWeather.self, from: d), w.report.area == a else { return nil }
        lock.lock(); memory[a.key] = w; lock.unlock()
        return w
    }

    func save(_ w: PlaceWeather) {
        lock.lock(); memory[w.report.area.key] = w; lock.unlock()
        if let d = try? JSONEncoder().encode(w) { try? d.write(to: file(w.report.area), options: .atomic) }
    }

    func prune(now: Date) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for f in files {
            guard let d = try? Data(contentsOf: f), let w = try? JSONDecoder().decode(PlaceWeather.self, from: d) else { try? FileManager.default.removeItem(at: f); continue }
            if now.timeIntervalSince(w.report.fetchedAt) > Self.keepS {
                try? FileManager.default.removeItem(at: f)
                lock.lock(); memory[w.report.area.key] = nil; lock.unlock()
            }
        }
    }
}

/// When the network may be asked again for a cell (shared by every card).
@MainActor
final class PlaceWeatherLimiter {
    static let shared = PlaceWeatherLimiter()
    private var failedAt: [String: Date] = [:]
    private var inFlight: Set<String> = []

    func mayFetch(_ a: WeatherArea, cached: PlaceWeather?, now: Date, force: Bool) -> Bool {
        if inFlight.contains(a.key) { return false }
        if force { return true }
        if let c = cached, now.timeIntervalSince(c.report.fetchedAt) < WeatherThresholds.refetchS { return false }
        if let f = failedAt[a.key], now.timeIntervalSince(f) < WeatherStore.retryS { return false }
        return true
    }

    func begin(_ a: WeatherArea) { inFlight.insert(a.key) }
    func end(_ a: WeatherArea, failed: Bool, now: Date) {
        inFlight.remove(a.key)
        failedAt[a.key] = failed ? now : nil
    }
    func reset() { failedAt = [:]; inFlight = [] }
}

/// Names a spot: a saved place nearby, the map's own label, else Apple's reverse geocoder (Arabic).
protocol PlaceNaming: Sendable {
    func name(for p: LngLat) async -> PlaceName?
}

struct AppleReverseGeocoder: PlaceNaming {
    func name(for p: LngLat) async -> PlaceName? {
        let g = CLGeocoder()
        guard let pm = try? await g.reverseGeocodeLocation(CLLocation(latitude: p.lat, longitude: p.lng), preferredLocale: Locale(identifier: "ar")).first else { return nil }
        return Self.name(areaOfInterest: pm.areasOfInterest?.first, subLocality: pm.subLocality, locality: pm.locality, admin: pm.administrativeArea)
    }

    /// A named place when there is one; otherwise the town / region, said as «قرب …».
    static func name(areaOfInterest: String?, subLocality: String?, locality: String?, admin: String?) -> PlaceName? {
        func clean(_ s: String?) -> String? { s.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 } }
        if let a = clean(areaOfInterest) { return PlaceName(text: a, source: .geocoder) }
        let parts = [clean(subLocality), clean(locality), clean(admin)].compactMap { $0 }
        var uniq: [String] = []
        for x in parts where !uniq.contains(x) { uniq.append(x) }
        guard !uniq.isEmpty else { return nil }
        return PlaceName(text: uniq.prefix(2).joined(separator: "، "), source: .geocoder, approximate: true)
    }
}

/// One card's brief: debounced, cached, honest about age and connectivity.
@MainActor
final class PlaceBriefModel: ObservableObject {
    @Published private(set) var weather: PlaceWeather?
    @Published private(set) var loading = false
    @Published private(set) var failure: WeatherFetchFailure?
    @Published private(set) var name: PlaceName?
    @Published private(set) var terrain = TerrainSample.unavailable
    private(set) var area: WeatherArea?
    private(set) var point: LngLat?

    private let provider: FallbackWeatherProvider
    private let cache: PlaceWeatherCache
    private let limiter: PlaceWeatherLimiter
    private let namer: PlaceNaming
    private let clock: () -> Date
    private let debounceNs: UInt64
    private var job: Task<Void, Never>?
    private static var names: [String: PlaceName] = [:]

    init(provider: FallbackWeatherProvider = WeatherProviders.placeBrief, cache: PlaceWeatherCache = .shared, limiter: PlaceWeatherLimiter? = nil,
         namer: PlaceNaming = AppleReverseGeocoder(), clock: @escaping () -> Date = Date.init, debounceNs: UInt64 = 350_000_000) {
        self.provider = provider
        self.cache = cache
        self.limiter = limiter ?? .shared
        self.namer = namer
        self.clock = clock
        self.debounceNs = debounceNs
    }

    /// Point the brief at `p`: cached values at once, then (after the debounce) the network if due.
    func load(_ p: LngLat, knownName: String?, saved: [SavedPlace] = [], force: Bool = false) {
        let a = WeatherArea(cell: p.lat, lng: p.lng)
        point = p
        if area != a {
            area = a
            weather = cache.load(a)
            failure = nil
        }
        terrain = MapTerrainProbe.sample(p)
        name = Self.knownName(knownName, saved: saved, at: p) ?? Self.names[Self.nameKey(p)]
        var demo = false
        #if DEBUG
        if let r = WeatherDemo.report(for: a, now: clock()) {
            weather = PlaceWeather(report: r, provider: .openMeteo)
            demo = true
        }
        #endif
        job?.cancel()
        let needName = name == nil
        job = Task { [weak self] in
            guard let self else { return }
            if self.debounceNs > 0 { try? await Task.sleep(nanoseconds: self.debounceNs) }
            guard !Task.isCancelled else { return }
            async let n: PlaceName? = needName ? self.namer.name(for: p) : nil
            if !demo { await self.fetchIfDue(a, force: force) }
            if let got = await n, !Task.isCancelled, self.point == p {
                Self.names[Self.nameKey(p)] = got
                self.name = got
            }
        }
    }

    /// For tests: wait for the pending debounce + fetch.
    func settle() async { await job?.value }

    private func fetchIfDue(_ a: WeatherArea, force: Bool) async {
        let now = clock()
        guard limiter.mayFetch(a, cached: weather, now: now, force: force) else { return }
        limiter.begin(a)
        loading = true
        defer { loading = false }
        do {
            let w = try await provider.fetch(a, now: clock())
            limiter.end(a, failed: false, now: clock())
            cache.save(w)
            cache.prune(now: clock())
            guard area == a else { return }
            weather = w
            failure = nil
        } catch {
            limiter.end(a, failed: true, now: clock())
            if area == a { failure = WeatherFetchFailure.of(error) }
        }
    }

    /// A name the caller already had (search result, POI label), else a saved place within 150 m.
    nonisolated static func knownName(_ known: String?, saved: [SavedPlace], at p: LngLat) -> PlaceName? {
        if let k = known?.trimmingCharacters(in: .whitespaces), !k.isEmpty { return PlaceName(text: k, source: .map) }
        let near = saved.map { ($0, PlanGeo.meters($0.position, p)) }.filter { $0.1 <= PlaceBriefThresholds.savedPlaceNameM }.min { $0.1 < $1.1 }
        return near.map { PlaceName(text: $0.0.name, source: .saved) }
    }

    private static func nameKey(_ p: LngLat) -> String { String(format: "%.3f,%.3f", p.lat, p.lng) }
}

/// The live map registers itself so a card can read Terrain-DEM at a spot (main thread).
protocol TerrainSampling: AnyObject {
    func terrain(at p: LngLat) -> TerrainSample
}

/// Main thread only (the map and the cards both live there).
enum MapTerrainProbe {
    static weak var source: TerrainSampling?
    /// UI tests / screenshots: a fixed reading.
    static var override: TerrainSample?

    static func sample(_ p: LngLat) -> TerrainSample {
        if let override { return override }
        return source?.terrain(at: p) ?? .unavailable
    }
}
