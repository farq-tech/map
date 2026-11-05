import Combine
import Foundation

/// Loading state of the plan or the checklist. `unavailable` = the server has no
/// such endpoint yet (404/405): said honestly as «غير متاح بعد», never as an error.
enum PlanPhase: Equatable {
    case loading
    case loaded
    case unavailable
    case failed(String)
}

/// Live events for the plan, routed from the outing's socket (`OutingSession`) to its model.
enum PlanEvents {
    static let name = Notification.Name("sary.plan.event")

    static func post(outing: String, _ e: LiveEvent) {
        NotificationCenter.default.post(name: name, object: outing, userInfo: ["event": e])
    }
}

/// One outing's plan + checklist: loaded from the server, edited optimistically,
/// kept current by live events (`plan_updated`, `checklist_updated`) and, where no
/// socket is open (the details screen before the start), by a gentle poll.
@MainActor
final class PlanModel: ObservableObject {
    let outingId: String
    private let backend: PlanBackend

    @Published private(set) var plan: TripPlan = .empty
    @Published private(set) var planPhase: PlanPhase = .loading
    @Published private(set) var checklist = ChecklistState()
    @Published private(set) var checklistPhase: PlanPhase = .loading
    @Published private(set) var saving = false
    @Published var errorText: String?
    /// «اتبع الخطة» is on (this device only).
    @Published var following = false
    /// The destination lives only on this phone (the server has no plan endpoint yet);
    /// it is sent the first time the plan loads from the server. Members do not see it until then.
    @Published private(set) var destinationLocalOnly = false
    private let defaults: UserDefaults

    private var follower = FollowPlan(points: [])
    private var observer: NSObjectProtocol?
    private var pollTask: Task<Void, Never>?
    private var pollers = 0
    /* Mutations in flight: a poll that lands meanwhile must not undo them on screen. */
    private var pendingWrites = 0

    static let pollSeconds: UInt64 = 15

    init(outingId: String, backend: PlanBackend, defaults: UserDefaults = .standard) {
        self.outingId = outingId
        self.backend = backend
        self.defaults = defaults
        if let local = LocalDestinationStore.load(outingId, defaults: defaults), local.pending {
            plan.destination = local.destination
            destinationLocalOnly = true
        }
        observer = NotificationCenter.default.addObserver(forName: PlanEvents.name, object: outingId, queue: .main) { [weak self] n in
            guard let e = n.userInfo?["event"] as? LiveEvent else { return }
            MainActor.assumeIsolated { self?.apply(e) }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        pollTask?.cancel()
    }

    var routeLengthM: Double { PlanGeo.length(plan.points) }
    var etaSeconds: Int { PlanETA.seconds(meters: routeLengthM) }

    // MARK: load

    func load() async {
        async let p: Void = loadPlan()
        async let c: Void = loadChecklist()
        _ = await (p, c)
    }

    func loadPlan() async {
        do {
            let p = try await backend.plan(outingId)
            if pendingWrites == 0 { setPlan(p) }
            planPhase = .loaded
            await syncLocalDestination(server: p)
        } catch {
            if PlanAvailability.notDeployed(error) { planPhase = .unavailable } else if planPhase != .loaded { planPhase = .failed(Self.text(error)) }
        }
    }

    /// The server answers the plan now: send the destination kept on this phone.
    /// If the server already has a destination (set after the endpoint went live), the server wins.
    private func syncLocalDestination(server p: TripPlan) async {
        guard let local = LocalDestinationStore.load(outingId, defaults: defaults), local.pending else { return }
        if p.destination != nil {
            LocalDestinationStore.clear(outingId, defaults: defaults)
            destinationLocalOnly = false
            return
        }
        var withDest = p
        withDest.destination = local.destination
        pendingWrites += 1
        defer { pendingWrites -= 1 }
        do {
            setPlan(try await backend.putPlan(outingId, withDest.cleanedForUpload()))
            LocalDestinationStore.clear(outingId, defaults: defaults)
            destinationLocalOnly = false
        } catch {
            /* Still not accepted: keep it on the phone and show it. */
            var keep = plan
            keep.destination = local.destination
            setPlan(keep)
        }
    }

    func loadChecklist() async {
        do {
            let items = try await backend.checklist(outingId)
            if pendingWrites == 0 { checklist.items = items }
            checklistPhase = .loaded
        } catch {
            if PlanAvailability.notDeployed(error) { checklistPhase = .unavailable } else if checklistPhase != .loaded { checklistPhase = .failed(Self.text(error)) }
        }
    }

    /// The details screen asks for updates while it is on screen (no socket there yet).
    func startPolling() {
        pollers += 1
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.pollSeconds * 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                if self.planPhase != .unavailable { await self.loadPlan() }
                if self.checklistPhase != .unavailable { await self.loadChecklist() }
            }
        }
    }

    func stopPolling() {
        pollers = max(0, pollers - 1)
        if pollers == 0 {
            pollTask?.cancel()
            pollTask = nil
        }
    }

    // MARK: live events

    func apply(_ e: LiveEvent) {
        switch e {
        case let .planUpdated(p?):
            setPlan(p)
            planPhase = .loaded
        case .planUpdated(nil):
            Task { await loadPlan() }
        case let .checklistUpdated(items):
            guard pendingWrites == 0 else { return }
            checklist.items = items
            checklistPhase = .loaded
        default:
            break
        }
    }

    private func setPlan(_ p: TripPlan) {
        plan = p
        follower = FollowPlan(points: p.points)
        if !p.hasRoute { following = false }
    }

    // MARK: plan (leader / co-leader)

    /// Saves route + notes + destination. Returns false (and says why) if the server refused.
    @discardableResult
    func save(_ p: TripPlan) async -> Bool {
        let clean = p.cleanedForUpload()
        let before = plan
        setPlan(clean)
        saving = true
        pendingWrites += 1
        defer { saving = false; pendingWrites -= 1 }
        do {
            setPlan(try await backend.putPlan(outingId, clean))
            planPhase = .loaded
            if destinationLocalOnly {
                LocalDestinationStore.clear(outingId, defaults: defaults)
                destinationLocalOnly = false
            }
            return true
        } catch {
            setPlan(before)
            if PlanAvailability.notDeployed(error) {
                planPhase = .unavailable
                errorText = "حفظ الخطة غير متاح بعد على الخادم."
            } else {
                errorText = Self.text(error)
            }
            return false
        }
    }

    /// Sets (or clears) the destination. If the server has no plan endpoint yet, it is
    /// kept on this phone (`destinationLocalOnly`) and sent once the endpoint answers.
    func setDestination(_ d: OutingDestination?) async -> Bool {
        var p = plan
        p.destination = d
        if await save(p) { return true }
        guard planPhase == .unavailable else { return false }
        errorText = nil
        var local = plan
        local.destination = p.cleanedForUpload().destination
        setPlan(local)
        if let dest = local.destination {
            LocalDestinationStore.save(outingId, .init(destination: dest, pending: true, savedAt: Date()), defaults: defaults)
            destinationLocalOnly = true
        } else {
            LocalDestinationStore.clear(outingId, defaults: defaults)
            destinationLocalOnly = false
        }
        return true
    }

    // MARK: checklist (any member)

    func add(_ title: String, me: String?) async -> Bool {
        guard let t = ChecklistState.cleanTitle(title) else {
            errorText = "اكتب اسم الغرض."
            return false
        }
        if checklist.contains(title: t) {
            errorText = "«\(t)» موجود في القائمة."
            return false
        }
        let temp = ChecklistItem(id: "local-\(UUID().uuidString)", title: t, created_by: me, created_at: ISODate.string(Date()))
        checklist.items.append(temp)
        return await mutate(rollback: { $0.remove(temp.id) }) {
            let r = try await self.backend.addItem(self.outingId, title: t)
            self.checklist.remove(temp.id)
            return r
        }
    }

    func toggle(_ id: String) async {
        guard let item = checklist.items.first(where: { $0.id == id }) else { return }
        checklist.setDone(id, !item.done)
        _ = await mutate(rollback: { $0.setDone(id, item.done) }) {
            try await self.backend.patchItem(self.outingId, id, done: !item.done, assignee: nil)
        }
    }

    func assign(_ id: String, to user: String?) async {
        guard let item = checklist.items.first(where: { $0.id == id }) else { return }
        checklist.assign(id, to: user)
        _ = await mutate(rollback: { $0.assign(id, to: item.assignee_user_id) }) {
            try await self.backend.patchItem(self.outingId, id, done: nil, assignee: user.map(AssigneeChange.set) ?? .clear)
        }
    }

    func delete(_ id: String) async {
        guard let i = checklist.items.firstIndex(where: { $0.id == id }) else { return }
        let item = checklist.items[i]
        checklist.remove(id)
        _ = await mutate(rollback: { s in s.items.insert(item, at: min(i, s.items.count)) }) {
            try await self.backend.deleteItem(self.outingId, id)
        }
    }

    private func mutate(rollback: (inout ChecklistState) -> Void, _ op: () async throws -> ChecklistReply) async -> Bool {
        pendingWrites += 1
        defer { pendingWrites -= 1 }
        do {
            let r = try await op()
            if let items = r.items { checklist.items = items } else if let item = r.item { checklist.upsert(item) }
            checklistPhase = .loaded
            return true
        } catch {
            rollback(&checklist)
            if PlanAvailability.notDeployed(error) {
                checklistPhase = .unavailable
                errorText = "قائمة التجهيز غير متاحة بعد على الخادم."
            } else {
                errorText = Self.text(error)
            }
            return false
        }
    }

    // MARK: «اتبع الخطة»

    func followStatus(fix: DeviceFix?, now: Date = Date()) -> FollowPlanStatus {
        let me = fix.map { LngLat(lng: $0.lng, lat: $0.lat) }
        let age = fix.map { max(0, now.timeIntervalSince1970 - $0.atMs / 1000) } ?? .infinity
        return follower.update(me: me, fixAgeS: age, accuracyM: fix?.accuracy)
    }

    // MARK: rally («نقطة تجمع» from search)

    func setRally(_ p: LngLat, label: String?) async -> Bool {
        do {
            _ = try await backend.setRally(outingId, lat: p.lat, lng: p.lng, label: label)
            return true
        } catch {
            errorText = Self.text(error)
            return false
        }
    }

    static func text(_ e: Error) -> String {
        if let e = e as? OutingAPIError {
            if e.code == "leader_only" || e.code == "owner_only" { return "تعديل الخطة لأمير الرحلة أو نائبه فقط." }
            if e.code == "invalid_route" { return "المسار غير صالح." }
            if e.code == "invalid_title" { return "اكتب اسمًا أقصر للغرض." }
            return e.arabic
        }
        return "حدث خطأ. أعد المحاولة."
    }
}

/// One `PlanModel` per outing for the app's lifetime (details screen, live screen and editor share it).
@MainActor
final class PlanCenter {
    private let backend: PlanBackend
    private var models: [String: PlanModel] = [:]

    init(backend: PlanBackend) { self.backend = backend }

    func model(_ outingId: String) -> PlanModel {
        if let m = models[outingId] { return m }
        let m = PlanModel(outingId: outingId, backend: backend)
        models[outingId] = m
        return m
    }

    func forgetAll() { models = [:] }
}
