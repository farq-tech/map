import Combine
import Foundation
import UIKit

/// Shared waypoints and convoy mode for one open outing: the list (server, live
/// events, then the on-device cache when offline), the add / delete flows, and
/// the convoy alerts computed on this phone from live positions only.
@MainActor
final class OutingFeaturesModel: ObservableObject {
    enum Phase: Equatable {
        case loading
        case loaded
        /// No network: the last list this device saw.
        case cached(savedAt: Date)
        /// The server has no waypoint routes yet (404/405): said as «غير متاح بعد».
        case notDeployed
        case failed(String)
    }

    enum Modal: Identifiable, Equatable {
        case compose(LngLat)
        case waypoint(String)
        case convoy
        case past

        var id: String {
            switch self {
            case let .compose(p): return "compose:\(p.lat),\(p.lng)"
            case let .waypoint(id): return "wp:\(id)"
            case .convoy: return "convoy"
            case .past: return "past"
            }
        }
    }

    @Published private(set) var waypoints: [Waypoint] = []
    @Published private(set) var phase: Phase = .loading
    @Published var modal: Modal?
    @Published private(set) var saving = false
    @Published private(set) var deleting: Set<String> = []
    @Published var composeError: String?
    @Published private(set) var convoySaving = false
    @Published var convoyError: String?
    /// The latest convoy check (for the sheet's honest status line).
    @Published private(set) var convoyCheck: ConvoyMath.Evaluation?

    let outingId: String
    private let backend: OutingFeaturesBackend
    private weak var session: OutingSession?
    private var bag = Set<AnyCancellable>()
    private var gate = ConvoyAlertGate()
    private var lastConvoy: ConvoyInfo?

    /// The alert lane (wired to `LiveOutingController.pushAlert`).
    var pushAlert: (LiveAlertUI, TimeInterval) -> Void = { _, _ in }
    var dismissAlert: (String) -> Void = { _ in }
    var haptic: () -> Void = { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
    var toast: (String) -> Void = { _ in }

    init(session: OutingSession, backend: OutingFeaturesBackend) {
        outingId = session.id
        self.session = session
        self.backend = backend
        session.events.sink { [weak self] e in self?.handle(e) }.store(in: &bag)
    }

    var view: OutingView? { session?.view }
    var myId: String? { view?.myId }
    var iLead: Bool { view?.iLead == true }
    var convoy: ConvoyInfo? { view?.convoy }

    // MARK: waypoints

    /// Show the cache at once, then ask the server.
    func start() {
        if let c = WaypointCache.load(outingId) {
            waypoints = c.waypoints
            phase = .cached(savedAt: ISODate.parse(c.saved_at) ?? Date())
        }
        Task { await reload() }
    }

    func reload() async {
        if waypoints.isEmpty, phase != .loaded { phase = .loading }
        do {
            let list = try await backend.waypoints(outingId)
            waypoints = Self.sorted(list)
            phase = .loaded
            persist()
        } catch let e where FeatureAvailability.notDeployed(e) {
            phase = .notDeployed
        } catch {
            if let c = WaypointCache.load(outingId) {
                waypoints = c.waypoints
                phase = .cached(savedAt: ISODate.parse(c.saved_at) ?? Date())
            } else {
                phase = .failed(FeatureAvailability.arabic(error))
            }
        }
    }

    func handle(_ e: LiveEvent) {
        switch e {
        case let .waypointAdded(w):
            upsert(w)
            if w.user_id != myId {
                let name = creatorName(w)
                pushAlert(LiveAlertUI(id: "waypoint:\(w.id)", kind: .toast("\(name) أضاف نقطة: \(w.kind.label) · \(w.title)")), 6)
            }
        case let .waypointRemoved(id):
            waypoints.removeAll { $0.id == id }
            if case .waypoint(id)? = modal { modal = nil }
            persist()
        case .convoy:
            gate.reset()
        default:
            break
        }
    }

    private func upsert(_ w: Waypoint) {
        waypoints.removeAll { $0.id == w.id }
        waypoints = Self.sorted(waypoints + [w])
        if phase == .loading { phase = .loaded }
        persist()
    }

    private func persist() {
        WaypointCache.save(outingId, name: view?.snapshot.outing.name ?? "", waypoints)
    }

    nonisolated static func sorted(_ l: [Waypoint]) -> [Waypoint] { l.sorted { $0.created_at > $1.created_at } }

    /// «أضف نقطة» from the sheet: at my position when I have a live fix; otherwise
    /// we never guess one — the person long-presses the map instead.
    func composeAtMe(_ fix: DeviceFix?, now: Date = Date()) {
        guard let f = fix, now.timeIntervalSince1970 * 1000 - f.atMs <= LiveOutingPresenter.myLiveMaxAgeMs else {
            toast("ما عندنا موقع حي لك الآن · اضغط مطولًا على الخريطة في مكان النقطة")
            return
        }
        compose(at: LngLat(lng: f.lng, lat: f.lat))
    }

    func compose(at p: LngLat) {
        composeError = nil
        modal = .compose(p)
    }

    /// POST; on success the point shows at once (the server's `waypoint_added` echo is idempotent).
    @discardableResult
    func add(_ draft: WaypointDraft) async -> Bool {
        let clean: WaypointDraft
        switch WaypointRules.validate(draft) {
        case let .success(d): clean = d
        case let .failure(p):
            composeError = p.arabic
            return false
        }
        saving = true
        defer { saving = false }
        do {
            let w = try await backend.addWaypoint(outingId, clean)
            upsert(w)
            composeError = nil
            modal = nil
            toast("أُضيفت النقطة لكل أعضاء الطلعة")
            return true
        } catch {
            if FeatureAvailability.notDeployed(error) { phase = .notDeployed }
            composeError = FeatureAvailability.arabic(error)
            return false
        }
    }

    func canDelete(_ w: Waypoint) -> Bool {
        guard let me = myId else { return false }
        return WaypointRules.canDelete(w, myId: me, iLead: iLead)
    }

    @discardableResult
    func delete(_ id: String) async -> Bool {
        deleting.insert(id)
        defer { deleting.remove(id) }
        do {
            try await backend.deleteWaypoint(outingId, id: id)
        } catch let e as OutingAPIError where e.code == "waypoint_not_found" {
            /* Already gone: same end result. */
        } catch {
            toast(FeatureAvailability.arabic(error))
            return false
        }
        waypoints.removeAll { $0.id == id }
        persist()
        if case .waypoint(id)? = modal { modal = nil }
        return true
    }

    func creatorName(_ w: Waypoint) -> String {
        if w.user_id == myId { return "أنت" }
        return view?.members[w.user_id]?.display_name ?? w.display_name ?? "عضو غادر الطلعة"
    }

    // MARK: convoy

    @discardableResult
    func saveConvoy(_ c: ConvoyInfo) async -> Bool {
        convoySaving = true
        defer { convoySaving = false }
        do {
            let saved = try await backend.setConvoy(outingId, c)
            session?.applyLocal(.convoy(saved ?? (c.isOn ? c : nil)))
            convoyError = nil
            modal = nil
            toast(c.isOn ? "تم ضبط القافلة" : "أُوقف وضع القافلة")
            return true
        } catch {
            convoyError = FeatureAvailability.arabic(error)
            return false
        }
    }

    /// Live cars for the convoy check. Only `.live` positions — a stale or lost
    /// car is left out, so it can neither raise nor silence an alert.
    nonisolated static func liveCars(_ members: [MapMember]) -> [ConvoyCar] {
        members.filter { $0.presence == .live && !$0.approximate }.map {
            ConvoyCar(id: $0.id, position: Geo.LatLng(lat: $0.position.lat, lng: $0.position.lng), heading: $0.heading)
        }
    }

    /// Called by the controller on every session / GPS change.
    func evaluateConvoy(members: [MapMember], now: Date = Date()) {
        guard let v = view, let c = v.convoy, c.isOn, v.status == .active else {
            if convoyCheck != nil { convoyCheck = nil }
            if lastConvoy != nil { clearConvoyAlerts() }
            lastConvoy = nil
            return
        }
        if c != lastConvoy {
            clearConvoyAlerts()
            gate.reset()
            lastConvoy = c
        }
        let ev = ConvoyMath.evaluate(c, live: Self.liveCars(members))
        if ev != convoyCheck { convoyCheck = ev }
        let (fire, buzz) = gate.admit(ev.alerts, now: now)
        for a in fire { pushAlert(LiveAlertUI(id: a.key, kind: .convoy(alertUI(a, view: v))), 45) }
        if buzz { haptic() }
    }

    private func clearConvoyAlerts() {
        for k in gate.lastFired.keys { dismissAlert(k) }
    }

    func alertUI(_ a: ConvoyAlert, view v: OutingView) -> ConvoyAlertUI {
        let colors = v.colors
        func name(_ id: String) -> String { id == v.myId ? "أنت" : v.members[id]?.display_name ?? "" }
        switch a {
        case let .behindTail(u, m): return ConvoyAlertUI(kind: .behindTail, userId: u, name: name(u), color: colors[u] ?? 0xFFFFFF, meters: m)
        case let .aheadOfLead(u, m): return ConvoyAlertUI(kind: .aheadOfLead, userId: u, name: name(u), color: colors[u] ?? 0xFFFFFF, meters: m)
        case let .tailFarBehindLead(m):
            let t = v.convoy?.tail_user_id ?? ""
            return ConvoyAlertUI(kind: .tailFar, userId: t, name: name(t), color: colors[t] ?? 0xFFFFFF, meters: m)
        }
    }

    /// The badge for a member's chip and row.
    func convoyRole(_ uid: String) -> ConvoyRole? { convoy?.role(of: uid) }
}
