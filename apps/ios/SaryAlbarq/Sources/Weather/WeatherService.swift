import Foundation

/// Fetches bytes; swapped for a fake in tests.
protocol WeatherTransport: Sendable {
    func data(from url: URL) async throws -> Data
}

struct URLSessionWeatherTransport: WeatherTransport {
    func data(from url: URL) async throws -> Data {
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let (d, resp) = try await URLSession.shared.data(for: req)
        guard let h = resp as? HTTPURLResponse, (200..<300).contains(h.statusCode) else { throw URLError(.badServerResponse) }
        return d
    }
}

/// W-4 (docs/UNIFIED-SURFACES.md): ONE fetch path for every weather reader. The outing area, the destination,
/// a picked point («الجو هناك») and the place brief each keep their own model, but when two of them ask Open-Meteo
/// for the very same URL at the same moment they share ONE request (no result is kept afterwards: a refresh is
/// always a real refresh, and the on-disk `WeatherCache` stays the offline memory). Nothing different is sent.
actor WeatherFetchCoalescer {
    static let shared = WeatherFetchCoalescer()
    private var inflight: [URL: Task<Data, Error>] = [:]

    func data(from url: URL, base: any WeatherTransport) async throws -> Data {
        if let running = inflight[url] { return try await running.value }
        let task = Task { try await base.data(from: url) }
        inflight[url] = task
        defer { inflight[url] = nil }
        return try await task.value
    }
}

/// The shared transport the stores and the place brief use by default (tests inject their own fake).
struct CoalescingWeatherTransport: WeatherTransport {
    var base: any WeatherTransport = URLSessionWeatherTransport()
    func data(from url: URL) async throws -> Data { try await WeatherFetchCoalescer.shared.data(from: url, base: base) }
}

/// The last good response per area, on disk, so the desert (no signal) still
/// shows the last forecast — with its real age.
final class WeatherCache: @unchecked Sendable {
    struct Entry: Codable {
        var area: WeatherArea
        var fetchedAt: Date
        var forecast: Data
        var air: Data?
    }

    let directory: URL
    /// Entries older than this are deleted (the 48 h forecast is over by then).
    static let keepS: TimeInterval = 3 * 86_400

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
            self.directory = base.appendingPathComponent("weather", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    private func file(_ a: WeatherArea) -> URL { directory.appendingPathComponent("\(a.key).json") }

    func save(_ e: Entry) {
        guard let d = try? JSONEncoder().encode(e) else { return }
        try? d.write(to: file(e.area), options: .atomic)
    }

    func load(_ a: WeatherArea) -> Entry? {
        guard let d = try? Data(contentsOf: file(a)) else { return nil }
        return try? JSONDecoder().decode(Entry.self, from: d)
    }

    func prune(now: Date) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for f in files {
            guard let d = try? Data(contentsOf: f), let e = try? JSONDecoder().decode(Entry.self, from: d) else { try? FileManager.default.removeItem(at: f); continue }
            if now.timeIntervalSince(e.fetchedAt) > Self.keepS { try? FileManager.default.removeItem(at: f) }
        }
    }

    func report(_ a: WeatherArea) -> WeatherReport? {
        guard let e = load(a) else { return nil }
        return try? OpenMeteo.parse(forecast: e.forecast, air: e.air, area: e.area, fetchedAt: e.fetchedAt)
    }
}

/// One forecast (the outing area, the destination, or a searched point):
/// cached, refreshed at most every 30 min, never pretending old data is current.
@MainActor
final class WeatherStore: ObservableObject {
    @Published private(set) var report: WeatherReport?
    @Published private(set) var refreshing = false
    /// The last refresh failed (offline, server error): the card says so.
    @Published private(set) var lastFailed = false
    private(set) var area: WeatherArea?

    private let transport: WeatherTransport
    private let cache: WeatherCache
    private let clock: () -> Date
    private var lastAttempt: Date?
    /// After a failure, wait this long before trying the network again.
    static let retryS: TimeInterval = 5 * 60

    init(transport: WeatherTransport = CoalescingWeatherTransport(), cache: WeatherCache = WeatherCache(), clock: @escaping () -> Date = Date.init) {
        self.transport = transport
        self.cache = cache
        self.clock = clock
    }

    /// Point the store at `area` (shows the cached report at once) and refresh if due.
    func update(_ a: WeatherArea, force: Bool = false) async {
        let now = clock()
        if area != a {
            area = a
            report = cache.report(a)
            lastAttempt = nil
            lastFailed = false
        }
        #if DEBUG
        if let demo = WeatherDemo.report(for: a, now: now) {
            report = demo
            return
        }
        #endif
        if !force, let r = report, now.timeIntervalSince(r.fetchedAt) < WeatherThresholds.refetchS { return }
        if !force, lastFailed, let t = lastAttempt, now.timeIntervalSince(t) < Self.retryS { return }
        guard !refreshing else { return }
        refreshing = true
        lastAttempt = now
        defer { refreshing = false }
        do {
            async let f = transport.data(from: OpenMeteo.forecastURL(a))
            async let air: Data? = try? transport.data(from: OpenMeteo.airURL(a))
            let (fd, ad) = try await (f, air)
            let at = clock()
            let parsed = try OpenMeteo.parse(forecast: fd, air: ad, area: a, fetchedAt: at)
            /* Encoding, the write and the prune (which reads and decodes every cached area) used to
             * run on the main thread after each refresh. Awaited, so the file is there on return. */
            let entry = WeatherCache.Entry(area: a, fetchedAt: at, forecast: fd, air: ad)
            await Task.detached(priority: .utility) { [cache] in
                cache.save(entry)
                cache.prune(now: at)
            }.value
            /* The area may have changed while we waited. */
            guard area == a else { return }
            report = parsed
            lastFailed = false
        } catch {
            if area == a { lastFailed = true }
        }
    }
}
