import Combine
import Foundation

/// What «المشاوير» need from the server (`/api/outings/:id/legs`); a local fake in `-demo` and tests.
protocol OutingLegsBackend: AnyObject {
    func legs(_ outingId: String) async throws -> [OutingLeg]
    func startLeg(_ outingId: String, destination: OutingDestination, scope: OutingLeg.Scope, clientId: String) async throws -> OutingLeg
    func arriveLeg(_ outingId: String, legId: String, distanceM: Int?, durationS: Int?) async throws -> OutingLeg
    func cancelLeg(_ outingId: String, legId: String) async throws -> OutingLeg
}

extension OutingsAPI: OutingLegsBackend {
    private struct LegsBox: Decodable { var legs: [OutingLeg] }
    private struct LegBox: Decodable { var leg: OutingLeg }

    func legs(_ outingId: String) async throws -> [OutingLeg] {
        let r: LegsBox = try await call("GET", "/\(outingId)/legs")
        return r.legs
    }

    func startLeg(_ outingId: String, destination: OutingDestination, scope: OutingLeg.Scope, clientId: String) async throws -> OutingLeg {
        struct B: Encodable { var destination: OutingDestination; var scope: String; var client_id: String }
        let r: LegBox = try await call("POST", "/\(outingId)/legs", body: B(destination: destination, scope: scope.rawValue, client_id: clientId))
        return r.leg
    }

    func arriveLeg(_ outingId: String, legId: String, distanceM: Int?, durationS: Int?) async throws -> OutingLeg {
        struct B: Encodable { var distance_m: Int?; var duration_s: Int? }
        let r: LegBox = try await call("POST", "/\(outingId)/legs/\(legId)/arrive", body: B(distance_m: distanceM, duration_s: durationS))
        return r.leg
    }

    func cancelLeg(_ outingId: String, legId: String) async throws -> OutingLeg {
        struct B: Encodable {}
        let r: LegBox = try await call("POST", "/\(outingId)/legs/\(legId)/cancel", body: B())
        return r.leg
    }
}

/// The legs on this phone (UserDefaults): the summary and «سجل الطلعة» offline, and the
/// whole feature against an API that has no legs yet (it then still has the plan's destination).
enum OutingLegStore {
    static let prefix = "sary.outing.legs.v1."

    static func load(_ outingId: String, defaults: UserDefaults = .standard) -> [OutingLeg] {
        defaults.data(forKey: prefix + outingId).flatMap { try? JSONDecoder().decode([OutingLeg].self, from: $0) } ?? []
    }

    static func save(_ outingId: String, _ legs: [OutingLeg], defaults: UserDefaults = .standard) {
        if let d = try? JSONEncoder().encode(legs) { defaults.set(d, forKey: prefix + outingId) }
    }

    static func forgetAll(defaults: UserDefaults = .standard) {
        for k in defaults.dictionaryRepresentation().keys where k.hasPrefix(prefix) { defaults.removeObject(forKey: k) }
    }
}

/// One outing's legs: the server's when it has them, else this phone's (same rules: `LegLifecycle`).
@MainActor
final class OutingLegsCenter: ObservableObject {
    let outingId: String
    private let backend: OutingLegsBackend?
    private let defaults: UserDefaults
    @Published private(set) var legs: [OutingLeg]
    /// «وين رايحين؟» chosen, «ابدأ المشوار» not tapped yet.
    @Published var picked: OutingDestination?
    /// The server answered 404 for /legs (older API): legs live on this phone only.
    @Published private(set) var localOnly: Bool
    /// A new active leg id this phone has not begun yet (the tracker resets its arrival for it).
    var onNewLeg: (OutingLeg) -> Void = { _ in }
    private var seenActive: Set<String> = []
    private var bag = Set<AnyCancellable>()
    private var refreshing = false

    init(outingId: String, backend: OutingLegsBackend?, defaults: UserDefaults = .standard) {
        self.outingId = outingId
        self.backend = backend
        self.defaults = defaults
        let l = OutingLegStore.load(outingId, defaults: defaults)
        legs = l
        localOnly = backend == nil
        seenActive = Set(l.filter(\.isActive).map(\.id))
    }

    var current: OutingLeg? { LegLifecycle.current(legs) }
    var timeline: [OutingLeg] { LegLifecycle.timeline(legs) }

    func listen(_ events: PassthroughSubject<LiveEvent, Never>) {
        events.receive(on: DispatchQueue.main).sink { [weak self] e in
            switch e {
            case .planUpdated, .legUpdated, .outingStatus: Task { await self?.refresh() }
            default: break
            }
        }.store(in: &bag)
    }

    /// The event refreshes legs immediately; a light poll remains a recovery path for dropped
    /// events and keeps «سجل الطلعة» current without depending on the live channel.
    func poll(every s: TimeInterval = 30, while active: @escaping () -> Bool) {
        Timer.publish(every: s, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            guard active() else { return }
            Task { await self?.refresh() }
        }.store(in: &bag)
    }

    func refresh() async {
        guard let backend, !localOnly, !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            set(try await backend.legs(outingId))
        } catch {
            if PlanAvailability.notDeployed(error) { localOnly = true }
        }
    }

    /// «ابدأ المشوار».
    @discardableResult
    func start(_ d: OutingDestination, scope: OutingLeg.Scope, myId: String?, now: Date = Date()) async -> OutingLeg? {
        picked = nil
        if let backend, !localOnly {
            do {
                let leg = try await backend.startLeg(outingId, destination: d, scope: scope, clientId: UUID().uuidString)
                set(LegLifecycle.start(legs.filter { $0.id != leg.id }, leg, now: now).map { $0.id == leg.id ? leg : $0 })
                return leg
            } catch {
                if PlanAvailability.notDeployed(error) { localOnly = true } else { return nil }
            }
        }
        let leg = OutingLeg(id: "local-\(UUID().uuidString)", seq: 0, scope: scope, destination: d, started_at: ISODate.string(now), started_by: myId)
        set(LegLifecycle.start(legs, leg, now: now))
        return legs.last
    }

    /// «وصلنا» (or detected): ends that leg only.
    func arrive(_ legId: String, at: Date = Date(), distanceM: Int?) async {
        set(LegLifecycle.arrive(legs, id: legId, at: at, distanceM: distanceM))
        guard let backend, !localOnly, !legId.hasPrefix("local-") else { return }
        let dur = legs.first { $0.id == legId }?.duration_s
        if let l = try? await backend.arriveLeg(outingId, legId: legId, distanceM: distanceM, durationS: dur) {
            set(legs.map { $0.id == l.id ? l : $0 })
        }
    }

    func cancel(_ legId: String) async {
        set(LegLifecycle.cancel(legs, id: legId))
        guard let backend, !localOnly, !legId.hasPrefix("local-") else { return }
        _ = try? await backend.cancelLeg(outingId, legId: legId)
    }

    /// The outing ended: what was still on the way is closed (the server does the same).
    func outingEnded() {
        picked = nil
        set(LegLifecycle.endOuting(legs))
    }

    private func set(_ l: [OutingLeg]) {
        if l != legs { legs = l }
        OutingLegStore.save(outingId, l, defaults: defaults)
        for leg in l where leg.isActive && !seenActive.contains(leg.id) {
            seenActive.insert(leg.id)
            onNewLeg(leg)
        }
    }
}

/// One center per live outing (like `GroupAudioCenters`), so the controller needs no new stored state.
@MainActor
enum OutingLegsCenters {
    private static var centers: [String: OutingLegsCenter] = [:]

    static func of(_ controller: LiveOutingController) -> OutingLegsCenter {
        let session = controller.session
        if let c = centers[session.id] { return c }
        let c = OutingLegsCenter(outingId: session.id, backend: session.isDemo ? nil : session.api)
        c.listen(session.events)
        centers[session.id] = c
        return c
    }

    /// The summary (after the live screen has gone): this phone's copy.
    static func storedTimeline(_ outingId: String) -> [OutingLeg] {
        LegLifecycle.timeline(centers[outingId]?.legs ?? OutingLegStore.load(outingId))
    }
}
