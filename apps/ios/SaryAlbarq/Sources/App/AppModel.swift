import Combine
import Foundation
import Network
import SwiftUI
import UIKit

/// Loading state of «طلعاتي».
enum ListPhase: Equatable {
    case loading
    case loaded
    case failed(String)
}

/// The app's state outside the live map: identity, my outings, invites, recovery,
/// trip summaries and notifications. Screens read it and call its methods; it is
/// the only place that talks to `OutingsAPI` for them.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var identity: Identity?
    @Published private(set) var current: [OutingSummary] = []
    @Published private(set) var history: [OutingSummary] = []
    @Published private(set) var listPhase: ListPhase = .loading
    @Published var session: OutingSession?
    /// An invite that arrived by link and waits for the join sheet.
    @Published var pendingInvite: String?
    @Published var errorText: String?
    @Published var loading = false
    /// The device has a network path (NWPathMonitor).
    @Published private(set) var online = true
    /// Launch splash is still up.
    @Published private(set) var launching = true
    /// Whether this identity has a recovery code saved (GET /me), nil = unknown.
    @Published private(set) var recovery: OutingsAPI.RecoveryStatus?
    /// After a first join: offer notifications with our explainer (never at launch).
    @Published var offerNotifications = false
    /// «ابدأ الطلعة» at the end of «طلعة جديدة»: the live screen starts this outing when it opens.
    @Published var pendingStart: String?

    let api: OutingsAPI
    let location: LocationSharer
    let push: PushRegistrar
    /// The outing's Live Activity (Lock Screen + Dynamic Island), follows `session`.
    let activity: OutingActivityCoordinator
    let isDemo: Bool
    /// «تخطيط الطلعة»: one plan + checklist model per outing (demo data under `-demo`).
    lazy var plans = PlanCenter(backend: isDemo ? DemoPlanBackend() : api)
    private let monitor = NWPathMonitor()
    private var observers: [NSObjectProtocol] = []
    private var pushSink: AnyCancellable?
    private var sessionSink: AnyCancellable?

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        let api = OutingsAPI(tokenProvider: { IdentityStore.load()?.token })
        self.api = api
        location = LocationSharer()
        push = PushRegistrar(backend: api)
        activity = OutingActivityCoordinator(location: location)
        activity.stuck = { $0.stuckMarks }
        activity.speed = { $0.speedSnapshot() }
        isDemo = arguments.contains("-demo")
        if arguments.contains("-resetState") {
            IdentityStore.save(nil)
            ShareMemory.forgetAll()
            TripLogStore.forgetAll()
            WaypointCache.wipeAll()
            TrailStore.forgetAll()
            LocalDestinationStore.forgetAll()
            RecentPlaces.forget()
            /* Everything account deletion wipes, plus test-only state (dev settings, local API base). */
            LocalAccountData.wipe()
            for k in [OutingSession.modeKey, OutingSession.batteryKey, PushRegistrar.explainedKey, PushRegistrar.tokenKey, OnboardingProgress.key,
                      "sary.dev.unlocked"] + TrailPrefs.keys + SpeedPrefs.keys {
                UserDefaults.standard.removeObject(forKey: k)
            }
            #if DEBUG
            /* A remembered -SaryAPIBase must not leak into the next test (it is set again by its own argument). */
            if !arguments.contains("-SaryAPIBase") { UserDefaults.standard.removeObject(forKey: Endpoints.debugKey) }
            #endif
        }
        /* v1 consent was not tied to an identity: never honour it. */
        ShareMemory.dropLegacy()
        if isDemo {
            identity = Identity(token: "", user: PublicUser(id: DemoData.currentMe, display_name: "أنا", avatar: nil, phone: nil))
        } else {
            identity = IdentityStore.load()
        }
        api.onUnauthorized = { [weak self] in
            Task { @MainActor in self?.signedOutByServer() }
        }
        let forcedOffline = arguments.contains("-SaryOffline")
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                let now = forcedOffline ? false : path.status == .satisfied
                if now && !self.online { self.session?.networkBack() }
                self.online = now
            }
        }
        if forcedOffline { online = false }
        monitor.start(queue: DispatchQueue(label: "sary.net"))
        /* Screens observe the model; the registrar's state is part of it. */
        pushSink = push.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        sessionSink = $session.sink { [activity] in activity.attach($0) }
        observers.append(NotificationCenter.default.addObserver(forName: .saryOpenOuting, object: nil, queue: .main) { [weak self] n in
            guard let id = n.object as? String else { return }
            Task { @MainActor in self?.open(id) }
        })
        #if DEBUG
        if let i = arguments.firstIndex(of: "-SaryScreen"), i + 1 < arguments.count { debugScreen = arguments[i + 1] }
        /* Local end-to-end lab (with -SaryAPIBase): `-SaryLabIdentity "<token>|<user id>|<name>"` signs in as
         * a test identity made against the local API, `-SaryLabOuting <id>` opens that outing at once. */
        if !isDemo, let i = arguments.firstIndex(of: "-SaryLabIdentity"), i + 1 < arguments.count {
            let p = arguments[i + 1].split(separator: "|").map(String.init)
            if p.count >= 3 {
                let lab = Identity(token: p[0], user: PublicUser(id: p[1], display_name: p[2], avatar: nil, phone: nil))
                IdentityStore.save(lab)
                identity = lab
            }
        }
        #endif
        if isDemo && debugScreen == nil { openDemo() } else if isDemo { seedDemoLists() } else { resumeActiveShare() }
        #if DEBUG
        if !isDemo, let i = arguments.firstIndex(of: "-SaryLabOuting"), i + 1 < arguments.count { open(arguments[i + 1]) }
        #endif
        #if canImport(PushToTalk) && !targetEnvironment(simulator)
        /* «قناة الطلعة»: Apple wants the channel manager up as early as possible, so a channel the
         * system kept is restored and a pushtotalk push that launched us in the background is delivered. */
        Task { @MainActor [weak self] in
            await PTTSystemRoute.shared.setUp()
            PTTSystemRoute.shared.onWokenByPush = { outingId, _ in
                guard let self else { return }
                if self.session?.id != outingId { self.open(outingId) }
                self.session?.walkie.wokenByPush()
            }
        }
        #endif
        activity.endOrphans()
        #if DEBUG
        if let i = arguments.firstIndex(of: "-SaryActivity"), i + 1 < arguments.count {
            let name = arguments[i + 1]
            /* ActivityKit starts one only from the foreground: wait for the scene. */
            Task { try? await Task.sleep(nanoseconds: 1_500_000_000); activity.debugStart(name) }
        }
        #endif
        Task {
            /* A short branded beat, never a wait: the list loads behind it. */
            try? await Task.sleep(nanoseconds: arguments.contains("-SaryHoldSplash") ? 60_000_000_000 : 650_000_000)
            launching = false
        }
        Task {
            await push.refresh(signedIn: identity != nil)
            #if DEBUG
            if isDemo, push.state != .denied, push.state != .notAsked, push.state != .off { push.debugShow(.serverNotReady) }
            #endif
        }
    }

    /// DEBUG screenshot hook: `-SaryScreen <name>` opens one screen with demo data.
    @Published var debugScreen: String?

    var signedIn: Bool { identity != nil }

    /// Waypoints / convoy: the real API, or the demo's in-memory one.
    var featuresBackend: OutingFeaturesBackend { isDemo ? DemoFeatures.backend : api }

    // MARK: identity

    func createIdentity(name: String, phone: String, avatar: String? = nil) async -> Bool {
        guard let clean = ServerRules.cleanText(name, max: ServerRules.nameMax) else {
            errorText = OutingAPIError(code: "invalid_name", status: 400).arabic
            return false
        }
        let p = phone.trimmingCharacters(in: .whitespaces)
        if !p.isEmpty && ServerRules.normalizePhone(p) == nil {
            errorText = OutingAPIError(code: "invalid_phone", status: 400).arabic
            return false
        }
        loading = true
        defer { loading = false }
        do {
            var id = try await api.createIdentity(name: clean, avatar: avatar)
            IdentityStore.save(id)
            if let e164 = ServerRules.normalizePhone(p) {
                id.user = try await api.updateProfile(phone: e164)
                IdentityStore.save(id)
            }
            identity = id
            recovery = .init(active: false, created_at: nil)
            Task { await refresh() }
            return true
        } catch let e as OutingAPIError { errorText = e.arabic } catch {}
        return false
    }

    /// nil arguments are left unchanged; `""` clears phone / photo.
    func updateProfile(name: String? = nil, phone: String? = nil, avatar: String? = nil) async -> Bool {
        var e164: String?
        if let phone {
            let p = phone.trimmingCharacters(in: .whitespaces)
            e164 = p.isEmpty ? "" : ServerRules.normalizePhone(p)
            if e164 == nil {
                errorText = OutingAPIError(code: "invalid_phone", status: 400).arabic
                return false
            }
        }
        if let name, ServerRules.cleanText(name, max: ServerRules.nameMax) == nil {
            errorText = OutingAPIError(code: "invalid_name", status: 400).arabic
            return false
        }
        if isDemo { return true }
        do {
            let u = try await api.updateProfile(name: name, phone: e164, avatar: avatar)
            if var id = identity {
                id.user = u
                IdentityStore.save(id)
                identity = id
            }
            return true
        } catch let e as OutingAPIError { errorText = e.arabic } catch {}
        return false
    }

    /// GET /me: refresh my profile and whether a recovery code is saved.
    func loadMe() async {
        guard identity != nil, !isDemo else { return }
        if let r = try? await api.me() {
            recovery = r.recovery
            if var id = identity, id.user != r.user {
                id.user = r.user
                IdentityStore.save(id)
                identity = id
            }
        }
    }

    /// «احفظ رمز الاسترجاع»: a new code (replaces the old one), shown once.
    func makeRecoveryCode() async -> OutingsAPI.RecoveryCode? {
        if isDemo { return .init(code: "7K3Q-M9XD-2HPA-VR6T-WC4N-8B1F-ZJ5E", created_at: ISODate.string(Date())) }
        do {
            let c = try await api.createRecoveryCode()
            recovery = .init(active: true, created_at: c.created_at)
            return c
        } catch let e as OutingAPIError { errorText = e.arabic } catch {}
        return nil
    }

    /// Restore on this device with a code from the old one. Returns the restored name.
    func recover(code: String) async throws -> String {
        let id = try await api.recover(code: code)
        IdentityStore.save(id)
        identity = id
        recovery = .init(active: false, created_at: nil)
        OnboardingProgress.done = true
        Task { await refresh() }
        Task { await push.refresh(signedIn: true) }
        return id.user.display_name
    }

    /// «تسجيل الخروج من هذا الجهاز»: stop sharing, remove this device's push token, forget the identity here.
    func signOut() async {
        await push.unregister()
        signedOutLocally()
    }

    /// After «احذف حسابي»: what happened, shown once over the onboarding screen.
    @Published var accountNotice: AccountDeletionOutcome?

    /// «احذف حسابي» (App Store 5.1.1(v)). DELETE /api/outings/me; on success forget the
    /// push token and everything about the person on this device — downloaded map areas
    /// stay — and go back to onboarding. If the server has no DELETE /me yet (404/405):
    /// the older partial wipe, said honestly. On any other error nothing is deleted.
    func deleteAccount() async -> AccountDeletionOutcome {
        guard identity != nil else { return .failed(OutingAPIError(code: "unauthorized", status: 401).arabic) }
        let outcome: AccountDeletionOutcome
        if isDemo {
            outcome = .deleted
            push.forgetDevice()
            wipeAccountLocally()
        } else {
            outcome = await AccountDeleter(
                backend: api,
                myUserId: identity?.user.id,
                forgetPush: { [push] in push.forgetDevice() },
                unregisterPushOnServer: { [push] in await push.unregister() },
                wipeLocal: { [weak self] in self?.wipeAccountLocally() }
            ).run()
        }
        if outcome.notice != nil {
            #if DEBUG
            debugScreen = nil
            #endif
            accountNotice = outcome
        }
        return outcome
    }

    private func wipeAccountLocally() {
        signedOutLocally()
        LocalAccountData.wipe()
    }

    private func signedOutByServer() {
        /* The token no longer works (restored on another device): nothing to tell the server. */
        UserDefaults.standard.removeObject(forKey: PushRegistrar.tokenKey)
        signedOutLocally()
        errorText = OutingAPIError(code: "unauthorized", status: 401).arabic
    }

    private func signedOutLocally() {
        if let u = identity?.user.id { ShareMemory.setActiveShare(user: u, outing: nil) }
        session?.close()
        session = nil
        IdentityStore.save(nil)
        TripLogStore.forgetAll()
        /* Outing data of this identity (shared waypoints read offline) goes with it. */
        WaypointCache.wipeAll()
        /* «مساري» is about where I went: it goes with the identity. */
        TrailStore.forgetAll()
        identity = nil
        recovery = nil
        current = []
        history = []
        listPhase = .loading
        OnboardingProgress.done = false
    }

    // MARK: outings

    func refresh() async {
        guard identity != nil, !isDemo else { if isDemo { listPhase = .loaded }; return }
        if current.isEmpty && history.isEmpty, case .failed = listPhase { listPhase = .loading }
        do {
            let r = try await api.list()
            current = r.current
            history = r.history
            listPhase = .loaded
        } catch let e as OutingAPIError {
            /* Keep what we have on screen; only an empty list turns into an error page. */
            if current.isEmpty && history.isEmpty { listPhase = .failed(e.arabic) } else { listPhase = .loaded }
        } catch {}
    }

    /// Creates the outing (and keeps its invite token on this phone). `openNow: false`
    /// leaves the map closed: «طلعة جديدة» shows the invite step first.
    func createOuting(name: String, openNow: Bool = true) async -> String? {
        guard let clean = ServerRules.cleanText(name, max: ServerRules.outingNameMax) else {
            errorText = OutingAPIError(code: "invalid_outing_name", status: 400).arabic
            return nil
        }
        if isDemo {
            /* `-demo`: no server. The demo outing stands in (its link is a clearly fake demo link). */
            if openNow { open(DemoData.outingId) }
            return DemoData.outingId
        }
        do {
            let r = try await api.create(name: clean)
            InviteTokenStore.save(r.outing_id, r.invite.token)
            await refresh()
            if openNow {
                /* The quick create (no wizard): the creator joins it, same default as «انضم». */
                consentByJoining(r.outing_id)
                open(r.outing_id)
                startSharingAfterJoin(r.outing_id)
            }
            return r.outing_id
        } catch let e as OutingAPIError { errorText = e.arabic } catch {}
        return nil
    }

    /// Joining (or creating) is the consent: stored for this identity + outing now.
    func consentByJoining(_ outingId: String) {
        guard let me = identity?.user.id else { return }
        ShareMemory.consentByJoining(user: me, outing: outingId)
    }

    /// Right after joining: the open session asks iOS for the location and shares by itself
    /// (the «دائمًا» explainer follows once When-In-Use is granted; a refusal shows the fix).
    func startSharingAfterJoin(_ outingId: String) {
        guard let s = session, s.id == outingId else { return }
        s.joinedJustNow = true
        s.resumeIfPreviouslySharing()
    }

    /// The invite link for an outing this phone created (`-demo`: a demo link that joins nothing).
    func inviteURL(_ outingId: String) -> URL? {
        if let t = InviteTokenStore.load(outingId) { return InviteLink.url(for: t) }
        return isDemo ? InviteLink.url(for: "demo-invite") : nil
    }

    func preview(_ token: String) async throws -> InvitePreview { try await api.preview(token: token) }

    func join(_ token: String) async -> Bool {
        do {
            let r = try await api.join(token: token)
            pendingInvite = nil
            /* Tapping «انضم» (under ShareMemory.joinStatement) is the consent: share by default. */
            consentByJoining(r.outing_id)
            await refresh()
            open(r.outing_id)
            startSharingAfterJoin(r.outing_id)
            if !push.explained { offerNotifications = true }
            return true
        } catch let e as OutingAPIError { errorText = e.arabic } catch {}
        return false
    }

    /// The outing as the server has it now (details, history summary).
    func snapshot(_ id: String) async throws -> OutingSnapshot {
        if isDemo { return DemoData.endedSnapshot(id: id) }
        return try await api.get(id)
    }

    func leave(_ id: String) async -> Bool {
        if isDemo { return true }
        do {
            try await api.leave(id)
            if session?.id == id { closeSession() }
            await refresh()
            return true
        } catch let e as OutingAPIError { errorText = e.arabic } catch {}
        return false
    }

    /// My own totals for this outing, from this device (nil when I never shared here).
    func myTrip(_ id: String) -> TripTotals? {
        if isDemo { return TripTotals(distanceM: 48_300, durationS: 3 * 3600 + 12 * 60, movingS: 2 * 3600 + 5 * 60) }
        return TripLogStore.load(id)?.totals
    }

    /// My trail for this outing, from this device only (never sent).
    func myTrailPoints(_ id: String) -> Trail? {
        if isDemo { return id == "demo-old" || id == DemoData.outingId ? DemoTrail.mine(now: Date()) : nil }
        if let s = session, s.id == id { return s.trail }
        return TrailStore.load(id)
    }

    /// My trail for this outing, from this device only (for «قصة الطلعة»): the same
    /// «مساري» the details page draws (live session in memory, else trails-v1/<id>.json).
    func storyTrail(_ id: String) -> [StoryPoint] {
        if isDemo {
            #if DEBUG
            return StoryFixtures.trail(start: Date().addingTimeInterval(-(86400 * 3 + 4 * 3600) + 10 * 60))
            #else
            return []
            #endif
        }
        return myTrailPoints(id).map(StoryTrailSource.points) ?? []
    }

    /// Shared waypoints for the story (icons only), from the device's waypoint cache.
    func storyWaypoints(_ id: String) -> [StoryWaypoint] {
        #if DEBUG
        if isDemo { return StoryFixtures.waypoints() }
        #endif
        return (WaypointCache.load(id)?.waypoints ?? []).map { StoryWaypoint(kind: $0.kind.rawValue, lat: $0.lat, lng: $0.lng) }
    }

    func shareSummary(_ id: String) async -> TripShare? {
        guard let t = myTrip(id) else { return nil }
        if isDemo { return TripShare(user_id: DemoData.currentMe, display_name: "أنا", distance_m: Double(t.distanceM), duration_s: Double(t.durationS), moving_s: Double(t.movingS), shared_at: ISODate.string(Date())) }
        do { return try await api.shareSummary(id, t) } catch let e as OutingAPIError { errorText = e.arabic } catch {}
        return nil
    }

    func withdrawSummary(_ id: String) async -> Bool {
        if isDemo { return true }
        do { try await api.withdrawSummary(id); return true } catch let e as OutingAPIError { errorText = e.arabic } catch {}
        return false
    }

    func open(_ outingId: String) {
        if isDemo {
            if outingId == DemoData.outingId { openDemoSession() }
            return
        }
        guard let id = identity else { return }
        if session?.id == outingId { return }
        session?.close()
        let s = OutingSession(id: outingId, myUserId: id.user.id, api: api, token: id.token, location: location)
        session = s
        s.open()
    }

    func closeSession() {
        session?.close()
        session = nil
        Task { await refresh() }
    }

    func handle(url: URL) {
        /* A tap on the Live Activity: back to that outing. */
        if let id = OutingActivityState.outingId(from: url) { return open(id) }
        if let t = InviteLink.token(from: url) { pendingInvite = t }
    }

    func foreground(_ active: Bool) {
        phoneActive = active
        session?.foreground(active || CarPlayHub.active)
        if active {
            Task { await refresh() }
            Task { await push.refresh(signedIn: signedIn && !isDemo) }
        }
    }

    /// The phone's own screen is up (SwiftUI scene phase).
    private var phoneActive = true

    /// CARPLAY HOOK: the CarPlay screen showing the app counts as the app being open in
    /// front of you (the driver sees the live map there), so the session stays "visible"
    /// while CarPlay shows it even with the phone locked. Sharing still needs every other
    /// `SendGate` condition (consent, «شارك موقعي», active outing). See docs/CARPLAY-ENTITLEMENT.md.
    func carPlayVisible(_ on: Bool) {
        session?.foreground(phoneActive || on)
    }

    /// The app restarted mid-share — by the person, or by iOS in the background after a
    /// significant location change / region exit: pick the share back up (this identity,
    /// this outing, consent given). Off screen it sends only with «دائمًا» (SendGate).
    private func resumeActiveShare() {
        guard let me = identity?.user.id, let id = ShareMemory.activeShare(user: me) else { return }
        open(id)
        session?.resumeIfPreviouslySharing()
    }

    private func seedDemoLists() {
        if ProcessInfo.processInfo.arguments.contains("-demoEmpty") {
            listPhase = .loaded
            return
        }
        current = [
            OutingSummary(id: DemoData.outingId, name: "طلعة الثمامة (عرض تجريبي)", status: .active, role: "owner", my_status: "active", member_count: 4, created_at: nil, started_at: ISODate.string(Date().addingTimeInterval(-3000)), ended_at: nil),
            OutingSummary(id: "demo-paused", name: "مشوار العارض", status: .paused, role: "member", my_status: "active", member_count: 3, created_at: nil, started_at: nil, ended_at: nil),
            OutingSummary(id: "demo-new", name: "كشتة الخميس", status: .created, role: "owner", my_status: "active", member_count: 1, created_at: ISODate.string(Date().addingTimeInterval(-600)), started_at: nil, ended_at: nil),
        ]
        history = [OutingSummary(id: "demo-old", name: "كشتة نفود الثويرات", status: .ended, role: "member", my_status: "active", member_count: 6, created_at: nil,
                                 started_at: ISODate.string(Date().addingTimeInterval(-86400 * 3 - 4 * 3600)), ended_at: ISODate.string(Date().addingTimeInterval(-86400 * 3)))]
        listPhase = .loaded
    }

    private func openDemo() {
        seedDemoLists()
        openDemoSession()
    }

    private func openDemoSession() {
        let crowd = ProcessInfo.processInfo.arguments.contains("-demoCrowd")
        let silent = ProcessInfo.processInfo.arguments.contains("-demoSilent")
        let demo = DemoData.view(crowd: crowd, me: DemoData.currentMe, silent: silent)
        let s = OutingSession(id: DemoData.outingId, myUserId: DemoData.currentMe, api: api, token: "", location: location,
                              demo: ProcessInfo.processInfo.arguments.contains("-demoConvoy") ? DemoFeatures.convoyView(demo) : demo)
        session = s
        s.open()
        #if DEBUG
        /* Screenshots: the demo outing already shared (consent given), e.g. for the «دائمًا» hint. */
        if ProcessInfo.processInfo.arguments.contains("-demoSharing") {
            ShareMemory.recordConsent(user: DemoData.meId, outing: DemoData.outingId)
            ShareMemory.setActiveShare(user: DemoData.meId, outing: DemoData.outingId)
            s.resumeIfPreviouslySharing()
        }
        if silent { DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak s] in s?.seedDemoSilence() } }
        #endif
    }
}

/// The one `AppModel`, created on first use: by SwiftUI at a normal launch, or by the
/// app delegate when iOS relaunches the app in the background for location (no UI then),
/// so an active share resumes either way.
@MainActor
enum AppBoot {
    static let model = AppModel()
}

/// Onboarding finished on this device (name saved AND the location step seen).
enum OnboardingProgress {
    static let key = "sary.onboarding.done.v1"
    static var done: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

/// A fixed outing for screenshots and UI tests (`-demo` launch argument). Clearly
/// labelled in the UI; never talks to the server.
enum DemoData {
    static let meId = "00000000-0000-4000-8000-000000000001"
    static let outingId = "00000000-0000-4000-8000-0000000000aa"

    /// The demo identity. DEBUG `-SaryDemoMe <user id>` plays another member of
    /// the same demo outing (two simulators testing the nearby link).
    static var currentMe: String {
        #if DEBUG
        let a = ProcessInfo.processInfo.arguments
        if let i = a.firstIndex(of: "-SaryDemoMe"), i + 1 < a.count { return a[i + 1] }
        #endif
        return meId
    }

    /// `crowd`: three more friends parked right next to «سلطان» (the chip declutter case).
    /// `silent`: «نورة»'s last fix is 11 min old (paired with the `-demoSilent` event).
    static func view(now: Date = Date(), crowd: Bool = false, me: String = meId, silent: Bool = false) -> OutingView {
        func ago(_ s: Double) -> String { ISODate.string(now.addingTimeInterval(-s)) }
        var members: [Member] = [
            Member(user_id: meId, display_name: me == meId ? "أنا" : "راشد", phone: nil, role: "owner", sharing: true, joined_at: "2026-11-03T10:00:00.000Z", online: true, last_seen_at: ago(1)),
            Member(user_id: "00000000-0000-4000-8000-000000000002", display_name: "أبو فهد", phone: "+966500000001", role: "member", sharing: true, joined_at: "2026-11-03T10:01:00.000Z", online: true, last_seen_at: ago(2), note: MemberNote(text: "بوقف عند المحطة", at: ago(30))),
            Member(user_id: "00000000-0000-4000-8000-000000000003", display_name: "سلطان", phone: nil, role: "member", sharing: true, joined_at: "2026-11-03T10:02:00.000Z", online: true, last_seen_at: ago(20)),
            Member(user_id: "00000000-0000-4000-8000-000000000004", display_name: "نورة", phone: "+966500000002", role: "member", sharing: true, joined_at: "2026-11-03T10:03:00.000Z", online: false, last_seen_at: ago(silent ? 660 : 240)),
        ]
        var positions: [Position] = [
            Position(user_id: members[1].user_id, lat: 24.7128, lng: 46.67395, accuracy: 8, heading: 340, speed: 22, mode: .balanced, recorded_at: ago(3)),
            Position(user_id: members[2].user_id, lat: 24.7105, lng: 46.6747, accuracy: 15, heading: nil, speed: 0, mode: .balanced, recorded_at: ago(95)),
            Position(user_id: members[3].user_id, lat: 24.7119, lng: 46.6770, accuracy: 25, heading: 180, speed: 10, mode: .saver, recorded_at: ago(silent ? 660 : 300)),
        ]
        if crowd {
            for (i, name) in ["سعد", "ريم", "خالد"].enumerated() {
                let id = "00000000-0000-4000-8000-00000000001\(i)"
                members.append(Member(user_id: id, display_name: name, phone: nil, role: "member", sharing: true, joined_at: "2026-11-03T10:0\(4 + i):00.000Z", online: true, last_seen_at: ago(2),
                                      note: i == 0 ? MemberNote(text: "خلونا نتجمع هنا", at: ago(20)) : nil))
                positions.append(Position(user_id: id, lat: 24.71052 + Double(i) * 0.00004, lng: 46.67478 + Double(i) * 0.00005, accuracy: 6, heading: nil, speed: 0, mode: .balanced, recorded_at: ago(4)))
            }
        }
        #if DEBUG
        /* Screenshots: `-SaryDemoShift "dLat,dLng"` moves the demo group (e.g. next to a mapped wadi). */
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-SaryDemoShift"), i + 1 < args.count {
            let d = args[i + 1].split(separator: ",").compactMap { Double($0) }
            if d.count == 2 { positions = positions.map { var p = $0; p.lat += d[0]; p.lng += d[1]; return p } }
        }
        #endif
        let snap = OutingSnapshot(
            outing: OutingInfo(id: outingId, name: "طلعة الثمامة (عرض تجريبي)", status: .active, owner_id: meId, created_at: ago(3600), started_at: ago(3000), ended_at: nil),
            me: SnapshotMe(user_id: me, role: me == meId ? "owner" : "member", sharing: true),
            members: members, positions: positions.filter { $0.user_id != me }, invite: InviteState(active: true, expires_at: nil),
            server_now: ISODate.string(now)
        )
        return OutingView(snap, deviceNow: now)
    }
}

extension DemoData {
    /// An ended outing with shared summaries, for the history / trip summary screens.
    static func endedSnapshot(id: String, now: Date = Date()) -> OutingSnapshot {
        if id == outingId { return view(now: now).snapshot }
        func ago(_ s: Double) -> String { ISODate.string(now.addingTimeInterval(-s)) }
        let ended = id == "demo-old"
        let names = ["أنا", "أبو فهد", "سلطان", "نورة", "سعد", "ريم"]
        let members = names.enumerated().map { i, n in
            Member(user_id: i == 0 ? meId : "00000000-0000-4000-8000-0000000002\(i)", display_name: n, phone: nil, role: i == 1 ? "owner" : "member", sharing: true,
                   joined_at: ago(86400 * 3 + 5 * 3600), online: false, last_seen_at: ago(86400 * 3))
        }
        return OutingSnapshot(
            outing: OutingInfo(id: id, name: ended ? "كشتة نفود الثويرات" : (id == "demo-paused" ? "مشوار العارض" : "كشتة الخميس"), status: ended ? .ended : (id == "demo-paused" ? .paused : .created),
                               owner_id: members[1].user_id, created_at: ago(86400 * 3 + 6 * 3600), started_at: ended ? ago(86400 * 3 + 4 * 3600) : nil, ended_at: ended ? ago(86400 * 3) : nil),
            me: SnapshotMe(user_id: meId, role: "member", sharing: true),
            members: Array(members.prefix(ended ? 6 : 3)), positions: [], invite: InviteState(active: !ended, expires_at: nil), server_now: ISODate.string(now),
            summaries: ended ? [
                TripShare(user_id: members[1].user_id, display_name: "أبو فهد", distance_m: 61_200, duration_s: 14_100, moving_s: 9_300),
                TripShare(user_id: members[2].user_id, display_name: "سلطان", distance_m: 57_800, duration_s: 13_900, moving_s: 8_800),
                TripShare(user_id: members[4].user_id, display_name: "سعد", distance_m: 44_100, duration_s: 12_000, moving_s: 7_200),
            ] : nil
        )
    }
}

private extension Member {
    init(user_id: String, display_name: String, phone: String?, role: String, sharing: Bool, joined_at: String, online: Bool, last_seen_at: String, note: MemberNote? = nil) {
        self.init(user_id: user_id, display_name: display_name, avatar: nil, phone: phone, role: role, sharing: sharing, joined_at: joined_at, online: online, away: false, last_seen_at: last_seen_at, gps: .ok, note: note)
    }
}
