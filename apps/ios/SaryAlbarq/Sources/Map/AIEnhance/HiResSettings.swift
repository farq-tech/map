import Combine
import Foundation
import UIKit

/// The two switches over «صور عالية الوضوح»: the person's toggle (layers sheet, default ON)
/// and the server's kill switch (GET /api/outdoor/app-config → hiResImagery.enabled).
/// The server value is remembered: when the endpoint cannot be reached the last known
/// value stands (initially ON).
final class HiResSettings: ObservableObject {
    static let shared = HiResSettings()

    static let userKey = "sary.hires.user.v1"
    static let remoteKey = "sary.hires.remote.v1"
    static let remoteCheckedKey = "sary.hires.remoteCheckedAt.v1"
    /// At most one fetch per this many seconds (launch + every foreground).
    static let refreshInterval: TimeInterval = 15 * 60

    private let defaults: UserDefaults

    @Published var userOn: Bool { didSet { defaults.set(userOn, forKey: Self.userKey) } }
    @Published private(set) var remoteOn: Bool

    private var bag = Set<AnyCancellable>()
    private var fetching = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        userOn = defaults.object(forKey: Self.userKey) as? Bool ?? true
        remoteOn = defaults.object(forKey: Self.remoteKey) as? Bool ?? true
        #if DEBUG
        /* Screenshots / UI tests: `-SaryHiRes on|off`, `-SaryHiResRemote on|off`. */
        let a = ProcessInfo.processInfo.arguments
        func arg(_ k: String) -> String? { a.firstIndex(of: k).flatMap { $0 + 1 < a.count ? a[$0 + 1] : nil } }
        if let v = arg("-SaryHiRes") { userOn = v != "off" }
        if let v = arg("-SaryHiResRemote") { debugRemote = v != "off"; remoteOn = v != "off" }
        #endif
    }

    #if DEBUG
    private var debugRemote: Bool?
    #endif

    /// Applies a server answer (also the unit tests' entry point).
    func applyRemote(_ enabled: Bool?) {
        #if DEBUG
        if debugRemote != nil { return }
        #endif
        guard let enabled else { return } // unreachable / malformed: keep the last known value
        defaults.set(enabled, forKey: Self.remoteKey)
        defaults.set(Date().timeIntervalSince1970, forKey: Self.remoteCheckedKey)
        if Thread.isMainThread { remoteOn = enabled } else { DispatchQueue.main.async { self.remoteOn = enabled } }
    }

    /// Starts the launch fetch and the foreground refreshes (idempotent).
    func start(base: URL = Endpoints.apiBase, session: URLSession = HiResSettings.flagSession) {
        guard bag.isEmpty else { return }
        NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
            .sink { [weak self] _ in self?.refresh(base: base, session: session) }
            .store(in: &bag)
        refresh(base: base, session: session, force: true)
    }

    func refresh(base: URL = Endpoints.apiBase, session: URLSession = HiResSettings.flagSession, force: Bool = false) {
        let last = defaults.double(forKey: Self.remoteCheckedKey)
        guard force || Date().timeIntervalSince1970 - last > Self.refreshInterval, !fetching else { return }
        fetching = true
        Task.detached(priority: .utility) { [weak self] in
            let v = await Self.fetchRemote(base: base, session: session)
            await MainActor.run {
                self?.fetching = false
                self?.applyRemote(v)
            }
        }
    }

    /// nil = could not tell (network, HTTP error, unknown shape).
    static func fetchRemote(base: URL, session: URLSession) async -> Bool? {
        var req = URLRequest(url: base.appendingPathComponent("api/outdoor/app-config"), timeoutInterval: 10)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await session.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return parse(data)
    }

    static func parse(_ data: Data) -> Bool? {
        struct Flag: Decodable { var enabled: Bool? }
        struct Config: Decodable { var hiResImagery: Flag? }
        return (try? JSONDecoder().decode(Config.self, from: data))?.hiResImagery?.enabled
    }

    static let flagSession: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()
}
