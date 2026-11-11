import Foundation
import MetricKit
import os

/// «أداء التطبيق» (docs/METRICS.md): MetricKit's daily metrics and diagnostics (hangs, crashes,
/// CPU exceptions, disk writes) from real phones, kept on the phone as a small JSON ring buffer.
/// Nothing is uploaded: the owner reads Xcode Organizer, or the person shares the file from
/// «الإعدادات › متقدم › تشخيص». MetricKit carries no personal data and we add none.
final class MetricsCollector: NSObject, MXMetricManagerSubscriber {
    static let shared = MetricsCollector()

    /// All parsing and file work happens here, never on the main thread.
    private let queue = DispatchQueue(label: "sa.sary.albarq.metrics", qos: .utility)
    private let makeStore: () -> MetricsStore
    /// Resolved on `queue` the first time it is needed (not at launch: no file-system lookups there).
    private lazy var store: MetricsStore = makeStore()
    private var started = false

    init(store: @escaping () -> MetricsStore = { .standard }) {
        makeStore = store
        super.init()
    }

    /// Once, at launch: registering is the only main-thread cost (no disk, no parsing).
    func start() {
        guard !started else { return }
        started = true
        MXMetricManager.shared.add(self)
    }

    // MARK: MXMetricManagerSubscriber (called by the system on a background queue)

    func didReceive(_ payloads: [MXMetricPayload]) {
        let blobs = payloads.map { $0.jsonRepresentation() }
        queue.async { [self] in
            let now = Date()
            let summaries = blobs.compactMap(Self.object).map { MetricsExtract.daily($0, receivedAt: now) }
            if !summaries.isEmpty { store.append(summaries) }
        }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let blobs = payloads.map { $0.jsonRepresentation() }
        queue.async { [self] in
            let now = Date()
            let summaries = blobs.compactMap(Self.object).map { MetricsExtract.diagnostic($0, receivedAt: now) }
            if !summaries.isEmpty { store.append(summaries) }
        }
    }

    private static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // MARK: reading (the diagnostics page)

    /// The stored summaries, newest last. Call off the main thread.
    func load(_ done: @escaping ([MetricsSummary]) -> Void) {
        queue.async { [self] in done(store.load()) }
    }

    /// The JSON file to share, or nil when nothing has arrived yet.
    func exportFile(_ done: @escaping (URL?) -> Void) {
        queue.async { [self] in
            done(FileManager.default.fileExists(atPath: store.file.path) ? store.file : nil)
        }
    }
}

// MARK: - signposts

/// Our key intervals, logged with MetricKit's `mxSignpost` so their durations arrive in the daily
/// payload (`signpostMetrics`) and in Organizer. One os_signpost per edge; no strings, no data.
enum PerfInterval: CaseIterable {
    /// App launch (didFinishLaunching) → the first map's style is loaded (home or live map).
    case launchToMap
    /// The live outing screen appears → the first car layer is drawn on its map.
    case liveFirstCar
    /// «دروب البر» asked → the route options are shown (or none found).
    case desertRoute
    /// A search runs (after the typing pause) → its results are shown.
    case search

    var name: StaticString {
        switch self {
        case .launchToMap: return "launch_to_map"
        case .liveFirstCar: return "live_first_car"
        case .desertRoute: return "desert_route"
        case .search: return "search"
        }
    }
}

enum PerfSignpost {
    static let log: OSLog = MXMetricManager.makeLogHandle(category: "sary")

    private static let lock = NSLock()
    private static var open: [PerfInterval: OSSignpostID] = [:]

    /// A begun interval; `end()` closes it (once).
    struct Token {
        let interval: PerfInterval
        let id: OSSignpostID
        func end() { PerfSignpost.end(self) }
    }

    /// Begins `interval`. Its token ends it locally; `end(_ interval:)` ends it from another place.
    /// A second begin before the end replaces the first (the earlier one is simply never closed).
    @discardableResult
    static func begin(_ interval: PerfInterval) -> Token {
        let id = OSSignpostID(log: log)
        lock.lock()
        open[interval] = id
        lock.unlock()
        mxSignpost(.begin, log: log, name: interval.name, signpostID: id)
        return Token(interval: interval, id: id)
    }

    /// Ends the open `interval`, if any (later calls do nothing: "first map", "first car").
    static func end(_ interval: PerfInterval) {
        lock.lock()
        let id = open.removeValue(forKey: interval)
        lock.unlock()
        guard let id else { return }
        mxSignpost(.end, log: log, name: interval.name, signpostID: id)
    }

    static func end(_ token: Token) {
        lock.lock()
        if open[token.interval]?.rawValue == token.id.rawValue { open[token.interval] = nil }
        lock.unlock()
        mxSignpost(.end, log: log, name: token.interval.name, signpostID: token.id)
    }
}
