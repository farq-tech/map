import Combine
import CoreLocation
import Foundation
import os
import UIKit
import UserNotifications

/// What a session needs from the outside world, injectable for tests.
struct SessionEnv {
    var makeSocket: (URL) -> LiveSocket = { URLSessionLiveSocket(url: $0) }
    var scheduler: Scheduler = MainScheduler()
    /// True while the app is on screen. Off screen, positions go out only with «دائمًا» (SendGate), over HTTP.
    var isForeground: @MainActor () -> Bool = { UIApplication.shared.applicationState != .background }
    /// Background sends (`POST /:id/positions`). nil = the real API. Tests inject a fake.
    var postPosition: ((String, WireFix) async throws -> Void)?
    var lowPower: () -> Bool = { ProcessInfo.processInfo.isLowPowerModeEnabled }
    /// Wall clock, ms (background cadence and fix ages). Tests move it forward.
    var now: () -> Double = { Date().timeIntervalSince1970 * 1000 }
    /// Keeps the app running until one request finishes (UIKit background task); no-op in tests.
    var keepAlive: @MainActor () -> () -> Void = { BackgroundPositionSender.backgroundTask() }
    var defaults: UserDefaults = .standard
    /// Repeating timers (age ticks, link heartbeat). Off in unit tests.
    var timers = true
    /// Tests only: stands in for iOS location permission.
    var authorizationOverride: Bool?
    /// Tests only: stands in for «دائمًا» (screen-locked trail).
    var alwaysOverride: Bool?
    /// Where «مساري» is kept on this device (tests use a temporary folder).
    var trailDirectory: URL? = TrailStore.directory
    /// The phone-to-phone link (`NearbyMesh`). Needs `timers` too, so unit tests never touch the radios.
    var nearbyMesh = true
    /// Road matcher for «مساري» (Mapbox Map Matching with the app's public token). Runs only with `timers`.
    var trailMatching: TrailMatchingService? = MapboxTrailMatching.fromBundle()
    /// Tests only: stands in for "iOS keeps a When-In-Use app's updates alive with the screen locked" (iOS 17+).
    var lockedScreenTrailOverride: Bool?
    /// «المحادثات»: nil = the real API. Tests inject a fake.
    var chatBackend: ChatBackend?
    /// «رسالة صوتية»: nil = the real API. Tests inject a fake.
    var voiceNoteBackend: VoiceNoteBackend?
    /// Offline backfill upload (outingId, fixes, upToMs) → started. nil = `BackfillUploader` (background URLSession).
    var postBackfill: ((String, [WireFix], Double) -> Bool)?
    /// Tests only: stands in for «أثناء الاستخدام» + the background activity session.
    var backgroundSessionOverride: Bool?
    /// Presence hint heartbeat (outingId, hint, lowPower). nil = the real API.
    var postHint: ((String, PresenceHint, Bool) async -> Void)?
    /// Server requests of actions already applied on the phone (leave, rally, «أنا بخير»…), sent in
    /// the background (#173). nil = the session builds its own over `api` (tests); the app passes
    /// its one shared outbox (`AppModel.outbox`), so a leave keeps going after the screen closed.
    var outbox: OutingActionOutbox?
}

/// One open outing: the live channel, the reducer's picture, and — only when
/// you said so — your shared position: on screen over the socket, and with
/// «دائمًا» also off screen over HTTP (`BackgroundPositionSender`).
///
/// Every position goes through `gate` (`SendGate`), which `LiveChannel` and
/// `BackgroundPositionSender` ask again at the last step before the wire. The
/// server's `sharing` flag alone never sends anything: the server turns it on at join.
@MainActor
final class OutingSession: ObservableObject, Identifiable {
    nonisolated let id: String
    let myUserId: String
    @Published private(set) var view: OutingView?
    @Published private(set) var link: LiveChannel.State = .connecting
    /// The live link's health for the channel sheet's diagnostics line.
    @Published private(set) var linkDiag = LiveChannel.Diagnostics()
    @Published private(set) var closedReason: LiveCloseReason?
    @Published private(set) var wantsToShare = false
    /// The server's last answer to a sent fix. Not published: nothing on screen reads it, and an
    /// ack comes back for every shared fix (publishing it redrew the whole live screen each time).
    private(set) var lastAck: (ok: Bool, reason: String?)?
    @Published var mode: ShareMode {
        didSet {
            env.defaults.set(mode.rawValue, forKey: Self.modeKey)
            location.setMode(mode)
        }
    }
    @Published var errorText: String?
    /// Bumped once a second so ages and freshness re-render.
    /* Internal timer cadence only; no view observes it, so don't publish a whole-session update
     * every second while the live map is open. */
    private(set) var tick = 0
    /// A member waiting for the leader can refresh the server's authoritative status.
    @Published private(set) var refreshingWaitingStatus = false
    /// The 1 s SOS hold finished and the alert is on its way.
    @Published private(set) var sosSending = false
    @Published private(set) var busy: Set<String> = []
    /// Every live event after the reducer applied it (waypoints are kept outside the snapshot).
    let events = PassthroughSubject<LiveEvent, Never>()
    /// «شارك البطارية»: off unless the person turns it on (per device).
    @Published var batterySharing: Bool {
        didSet { env.defaults.set(batterySharing, forKey: Self.batteryKey) }
    }
    /// «مساري»: my breadcrumb trail for this outing. On this device only — never sent.
    @Published private(set) var trail = Trail()
    /// The GPS is kept on with the screen locked, for the trail only.
    @Published private(set) var recordingInBackground = false

    /// Where this session's outing lives.
    /// - `server`: a real outing; everything goes through `api` and the live channel.
    /// - `demo`: `-demo`, seeded friends and canned replies, on this phone only.
    /// - `solo`: «اتجه» on my own (docs/SOLO-OUTING.md), one member (me), on this phone only.
    enum Kind: Equatable, Sendable {
        case server, demo, solo

        /// No server: nothing is sent, every action applies on this phone.
        var isLocal: Bool { self != .server }
        /// Demo data and demo behaviour (seeded members, «أبو فهد» answering, auto-nav off…).
        var isDemo: Bool { self == .demo }
    }

    nonisolated let kind: Kind
    /// `-demo` data or behaviour. For "is there a server?" ask `isLocal`.
    nonisolated var isDemo: Bool { kind.isDemo }
    /// No server behind this session (demo or solo): never send, apply locally.
    nonisolated var isLocal: Bool { kind.isLocal }
    /// «اتجه» on my own (docs/SOLO-OUTING.md): one member, on this phone only. Group-only UI hides.
    nonisolated var isSolo: Bool { kind == .solo }
    let location: LocationSharer
    /// Return-timer and «غرّزت» events for `SafetyController`.
    let safetyEvents = PassthroughSubject<SafetyEvent, Never>()
    /// The server side of the safety pack (nil in the demo: all local).
    var safetyBackend: SafetyBackend? { isLocal ? nil : api }
    /// Internal so the per-person invites model (Sources/Invites) shares this client.
    let api: OutingsAPI
    private let token: String
    /// Positions that could not go out (no network): uploaded in one batch when it is back.
    private(set) var offlineQueue = OfflineFixQueue()
    /// Actions already applied here whose server request is still owed (#173, docs/RESPONSIVENESS.md).
    let outbox: OutingActionOutbox
    private var outboxSink: AnyCancellable?
    /// A deferred action could not reach the server yet, or the server refused it: one line for
    /// the live screen (a toast). Never a reason to resume sharing.
    var onDeferredNotice: (String) -> Void = { _ in }
    private let env: SessionEnv
    private var channel: LiveChannel?
    private var backgroundSender: BackgroundPositionSender?
    private var lastSent: Policy.LastSent?
    private var timers: [Timer] = []
    private var visible = true
    /// The person pressed stop while offline: tell the server once we can.
    private var pendingServerStop = false
    private var trailSavedAt = Date.distantPast
    private var trailUnsaved = 0
    /// Raw fixes not yet appended to the outing's raw log.
    private var rawPending: [RawFix] = []
    /// The last few minutes of raw fixes (for «الدقة ±٨ م · ١٢ نقطة/دقيقة»).
    private(set) var recentRaw: [RawFix] = []
    /// Road matching of my trail (nil: no token / switched off).
    private(set) var matcher: TrailMatchCoordinator?
    /// `displayTrail`, kept until the trail or the matcher's cache changes (read several times per render).
    private var displayTrailMemo = DisplayTrailMemo()
    /// Cars of the same outing nearby, phone to phone, when the internet is gone.
    let mesh: NearbyMesh
    /// «قناة الطلعة»: the live walkie-talkie (replaces the «اضغط وتكلم» clips).
    let walkie: OutingWalkieTalkie
    private var walkieSink: AnyCancellable?
    /// «رسالة صوتية»: the walkie-talkie as voice notes (Sources/VoiceNotes), the default mode.
    let voiceNotes: VoiceNoteCenter
    private var voiceNotesSink: AnyCancellable?
    /// «المحادثات»: the trip's group chat and direct chats (Sources/Chat).
    let chat: ChatStore
    private var chatSink: AnyCancellable?
    private var meshActivation = MeshActivation()
    private var meshSink: AnyCancellable?
    /// «غرّزت» marks from the live screen's SafetyController, for the Live Activity.
    var stuckMarks: [StuckMark] = []
    /// «سرعة المركبة» from the live screen's SpeedModel, for the Live Activity.
    var speedSnapshot: () -> SpeedModel.Snapshot? = { nil }
    /// «الرحلة» from the live screen (for the Live Activity), when it is open.
    var tripSnapshot: () -> TripPanelUI? = { nil }
    /// «الملاحة»'s next manoeuvre from the live screen (for the Live Activity), while guiding.
    var navSnapshot: () -> NavActivityLine? = { nil }
    /// A friend's «غرّزت» / SOS heard over the nearby link (the screen shows a card).
    var onNearbyEvent: (MeshEvent) -> Void = { _ in }
    #if DEBUG
    /// `-SaryMeshTest`: two simulators, no server — consent + share + nearby link forced on.
    static var meshTest: Bool { ProcessInfo.processInfo.arguments.contains("-SaryMeshTest") }
    /// `-SaryOffline`: behave as if there were no internet (the live channel never starts).
    static var forcedOffline: Bool { ProcessInfo.processInfo.arguments.contains("-SaryOffline") }
    #endif

    static let modeKey = "sary.outings.mode.v1"
    static let batteryKey = "sary.outings.battery.v1"

    /// `demo`: the local session's own picture (no server sends one). `kind`: nil = `.demo` with a
    /// `demo` view, `.server` without; `.solo` comes from `OutingSession.solo(...)`.
    init(id: String, myUserId: String, api: OutingsAPI, token: String, location: LocationSharer, demo: OutingView? = nil, kind: Kind? = nil, env: SessionEnv = SessionEnv()) {
        let resolved: Kind = kind ?? (demo != nil ? .demo : .server)
        assert(resolved.isLocal == (demo != nil), "a local session starts from its own view; a server session from the server's")
        self.id = id
        self.myUserId = myUserId
        self.api = api
        self.token = token
        self.location = location
        self.env = env
        self.kind = resolved
        self.view = demo
        if let shared = env.outbox {
            outbox = shared
        } else {
            let own = OutingActionOutbox.live(api: api, defaults: env.defaults, keepAlive: env.keepAlive)
            own.currentUser = { [myUserId] in myUserId }
            outbox = own
        }
        self.mode = ShareMode(rawValue: env.defaults.string(forKey: Self.modeKey) ?? "") ?? .balanced
        self.batterySharing = env.defaults.bool(forKey: Self.batteryKey)
        self.mesh = NearbyMesh(outingId: id, me: myUserId, members: Set(demo?.members.keys.map { $0 } ?? []), serverKey: demo?.snapshot.mesh_key)
        walkie = OutingWalkieTalkie(
            outingId: id,
            me: myUserId,
            tokenBackend: resolved.isLocal ? nil : api,
            demo: resolved.isDemo,
            demoCanCreatePrivate: resolved.isDemo && demo?.snapshot.me.role == "owner",
            defaults: env.defaults
        )
        if resolved == .solo {
            /* Solo: nobody to send a note to, and nobody answers. */
            voiceNotes = VoiceNoteCenter(outingId: id, me: myUserId, backend: LocalVoiceNoteBackend(), walkie: walkie, defaults: env.defaults)
        } else if let demo {
            /* The demo has no server: «أبو فهد» (or the first friend) answers each note with the same recording. */
            let friend = demo.members.keys.sorted().first { $0 != myUserId } ?? "demo-friend"
            let b = DemoVoiceNoteBackend(friendId: friend, me: myUserId)
            voiceNotes = VoiceNoteCenter(outingId: id, me: myUserId, backend: b, walkie: walkie, defaults: env.defaults)
            b.deliver = { [weak voiceNotes] n in voiceNotes?.receive(n) }
        } else {
            voiceNotes = VoiceNoteCenter(outingId: id, me: myUserId, backend: env.voiceNoteBackend ?? api, walkie: walkie, defaults: env.defaults)
        }
        if resolved == .solo {
            /* Solo: no chat (the store reads it as "not here" and hides it calmly). */
            chat = ChatStore(outingId: id, me: myUserId, backend: LocalChatBackend(), defaults: env.defaults)
        } else if let demo {
            let friends = Dictionary(demo.members.values.filter { $0.user_id != myUserId }.map { ($0.user_id, $0.display_name) }, uniquingKeysWith: { a, _ in a })
            let backend = DemoChatBackend(outingId: id, me: myUserId, friends: friends)
            chat = ChatStore(outingId: id, me: myUserId, backend: backend, defaults: env.defaults)
            backend.emit = { [weak chat] f in chat?.receive(f) }
        } else {
            chat = ChatStore(outingId: id, me: myUserId, backend: env.chatBackend ?? api, defaults: env.defaults)
        }
        if demo != nil { link = .live }
        trail = TrailStore.load(id, in: env.trailDirectory) ?? Trail()
        /* Whatever happened since the last kept point (app closed, phone restarted) was not seen. */
        trail.markGap()
        /* Road matching runs for real outings and solo (as on a real trip); the demo only with -SaryTrailMatch. */
        if !resolved.isDemo || ProcessInfo.processInfo.arguments.contains("-SaryTrailMatch"), let svc = env.trailMatching {
            let m = TrailMatchCoordinator(outingId: id, dir: env.trailDirectory, service: svc)
            matcher = m
        }
        #if DEBUG
        if resolved.isDemo, Self.forcedOffline { link = .offline }
        #endif
        mesh.myFix = { [weak self] in
            guard let self, self.gate.allowsPosition else { return nil }
            return self.location.lastFix
        }
        mesh.onEvents = { [weak self] evs in self?.nearbyEvents(evs) }
        meshSink = mesh.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        walkie.nameOf = { [weak self] uid in self?.view?.members[uid]?.display_name }
        walkie.outingName = { [weak self] in self?.view?.snapshot.outing.name ?? "" }
        /* «ترددات»: private channels over REST; the demo keeps them on this phone (its owner is the leader). */
        walkie.channelBackend = resolved.isLocal ? nil : api
        walkie.demoLeader = { [weak self] in self?.view?.snapshot.me.role == "owner" }
        walkieSink = walkie.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        voiceNotes.nameOf = { [weak self] uid in self?.view?.members[uid]?.display_name }
        voiceNotes.colorOf = { [weak self] uid in self?.view?.colors[uid] ?? 0xFFFFFF }
        /* The talk button follows the recording / playing state (whole seconds only: the meter has its own object). */
        voiceNotesSink = voiceNotes.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        chat.configure(.init(
            sendFrame: { [weak self] f in self?.channel?.sendChat(f) ?? false },
            isLive: { [weak self] in self?.channel?.isLive ?? false },
            myName: { [weak self] in self?.view?.me?.display_name }
        ))
        chat.snapshot(unread: demo?.snapshot.chat_unread)
        chatSink = chat.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        if !resolved.isLocal {
            outboxSink = outbox.reports.filter { [id] r in r.action.outing == id }.sink { [weak self] r in self?.outboxReport(r) }
        }
    }

    // MARK: the privacy gate

    var gate: SendGate {
        SendGate(
            consent: ShareMemory.hasConsent(user: myUserId, outing: id, defaults: env.defaults),
            osAuthorized: env.authorizationOverride ?? location.canLocate,
            userWantsShare: wantsToShare,
            serverSharing: view?.snapshot.me.sharing == true,
            outingActive: view?.status == .active,
            foreground: visible && env.isForeground(),
            closed: closedReason != nil,
            alwaysAuthorized: sharesInBackground,
            /* A «أخفِ موقعي» still on its way to the server already hides me here (#173). */
            hidden: view?.me?.hidden == true || pendingHide
        )
    }

    var hasConsent: Bool { ShareMemory.hasConsent(user: myUserId, outing: id, defaults: env.defaults) }

    /// «أخفِ موقعي» pressed here and not confirmed by the server yet.
    private var pendingHide: Bool { !isLocal && outbox.has(user: myUserId, outing: id, kind: .hide) }

    /// Sharing for real: the gate is open and the GPS is running for it.
    var isSharingNow: Bool { gate.allowsPosition && (location.isSharing || isDemo) }

    // MARK: lifecycle

    func open() {
        visible = env.isForeground()
        /* «المحادثات»: the conversation list and badges, then whatever waited in the outbox. */
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(1)) { [weak self] in
            guard let self, self.closedReason == nil else { return }
            Task { await self.chat.refresh() }
        }
        location.setOffScreen(!visible)
        location.onTrailFix = { [weak self] f in self?.trailFix(f) }
        matcher?.onChange = { [weak self] in
            guard let self else { return }
            self.updateRoadMode()
            self.objectWillChange.send()
        }
        matcher?.accuracyAt = { [weak self] t in self?.recentRaw.last(where: { abs($0.t - t) < 1500 })?.acc }
        /* Offline-first: whatever was recorded but not matched yet (offline, app closed) is caught up now. */
        if env.timers, TrailMatchPrefs.enabled(env.defaults) { matcher?.tick(trail, force: true) }
        location.onAuthorizationChange = { [weak self] in self?.reconcileSharing() }
        /* Your own dot, for distances and directions. Nothing is sent until you choose to share. */
        Task {
            _ = await location.requestWhenInUse()
            if self.visible { location.watchForeground() }
            self.syncTrailGPS()
        }
        if env.timers {
            let t = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                /* Timer callbacks run on the main run loop; queue observable mutations for the
                 * next turn so they cannot publish inside SwiftUI's current view update. */
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.visible else { return }
                    self.tick &+= 1
                    self.updateMesh()
                    /* A missed live status frame must not leave a joined member waiting forever.
                     * Reconcile frequently while waiting; stop as soon as the server starts it. */
                    if self.tick % 15 == 0, self.view?.status == .created {
                        Task { @MainActor [weak self] in
                            guard let self, self.tick % 15 == 0, self.view?.status == .created else { return }
                            await self.refreshWaitingStatus()
                        }
                    }
                }
            }
            timers.append(t)
        }
        #if DEBUG
        if Self.meshTest, isDemo {
            ShareMemory.recordConsent(user: myUserId, outing: id, defaults: env.defaults)
            Task { await self.beginSharing() }
        }
        if Self.forcedOffline, !isLocal {
            link = .offline
            location.onFix = { [weak self] f in self?.handleFix(f) }
            return
        }
        #endif
        voiceNotes.attach()
        /* A local session (demo, solo) has no server: no live channel, no background sender, no heartbeat. */
        guard !isLocal else {
            /* The demo's walkie-talkie still works phone to phone (two simulators, -SaryMeshTest). */
            if isDemo {
                walkie.attach(channel: nil, mesh: mesh)
                debugKeepDemoFixLive()
                debugAutoTalk()
            }
            return
        }
        let ch = LiveChannel(outingId: id, token: token, deps: .init(
            makeSocket: env.makeSocket,
            poll: { [api] in try await api.poll($0) },
            post: { [api] in try await api.sendPosition($0, fix: $1) },
            beat: { [api] in try await api.heartbeat($0, gps: $1, battery: $2) },
            scheduler: env.scheduler,
            canSendPosition: { [weak self] in
                /* The socket is for the screen only; off screen the HTTP sender takes over. */
                MainActor.assumeIsolated { self.map { $0.gate.allowsPosition && $0.gate.foreground } ?? false }
            }
        ))
        let outing = id
        let post = env.postPosition ?? { [api] in try await api.sendPosition($0, fix: $1) }
        let sender = BackgroundPositionSender(deps: .init(
            post: { try await post(outing, $0) },
            scheduler: env.scheduler,
            canSend: { [weak self] in MainActor.assumeIsolated { self?.gate.allowsBackgroundPosition ?? false } },
            now: env.now,
            lowPower: env.lowPower,
            keepAlive: { [env] in MainActor.assumeIsolated { env.keepAlive() } }
        ))
        sender.onResult = { [weak self] r in self?.backgroundResult(r) }
        sender.onUndelivered = { [weak self] f, m in self?.queueOffline(f, mode: m) }
        backgroundSender = sender
        offlineQueue = OfflineFixQueue.load(user: myUserId, outing: id, defaults: env.defaults)
        if env.postBackfill == nil {
            BackfillUploader.shared.onDone = { [weak self] outing, upTo, ok in MainActor.assumeIsolated { self?.backfillDone(outing, upToMs: upTo, ok: ok) } }
            BackfillUploader.shared.resume()
        }
        ch.handlers = .init(
            onSnapshot: { [weak self] s in MainActor.assumeIsolated { self?.applySnapshot(s) } },
            onEvent: { [weak self] e in MainActor.assumeIsolated { self?.apply(e) } },
            onState: { [weak self] s in MainActor.assumeIsolated { self?.linkChanged(s) } },
            onClosed: { [weak self] r in MainActor.assumeIsolated { self?.closed(r) } },
            onAck: { [weak self] ok, reason in MainActor.assumeIsolated { self?.ack(ok, reason) } },
            onServerNow: { [weak self] now in MainActor.assumeIsolated { self?.syncClock(now) } },
            onPTT: { [weak self] sig in MainActor.assumeIsolated { self?.walkie.receive(sig) } },
            onPTTOnChannel: { [weak self] sig, c in MainActor.assumeIsolated { self?.walkie.receive(sig, channel: c) } },
            onPTTChannel: { [weak self] e in MainActor.assumeIsolated { self?.walkie.receiveChannel(e) } },
            onAudio: { [weak self] d in MainActor.assumeIsolated { self?.walkie.receiveAudio(d) } },
            onDiagnostics: { [weak self] d in MainActor.assumeIsolated { if self?.linkDiag != d { self?.linkDiag = d } } },
            onChat: { [weak self] f in MainActor.assumeIsolated { self?.chat.receive(f) } }
        )
        channel = ch
        PTTDiagnosticsLog.shared.add("session", "open (visible=\(visible))")
        walkie.attach(channel: ch, mesh: mesh)
        ch.start()
        debugAutoTalk()
        if !visible { ch.setAway(true) }
        if env.timers {
            /* Connection heartbeat, no coordinates: lets others tell "no GPS" from "no network". */
            let hb = Timer.scheduledTimer(withTimeInterval: Policy.linkHeartbeatMs / 1000, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.beat() }
            }
            timers.append(hb)
        }
        location.onFix = { [weak self] f in self?.handleFix(f) }
    }

    /// UI tests: `-SaryDemoKeepLive` re-sends «أبو فهد»'s demo fix every few seconds (as his phone
    /// would), so «live» checks do not race the ~15 s freshness window on a slow simulator.
    private func debugKeepDemoFixLive() {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("-SaryDemoKeepLive") else { return }
        let uid = "00000000-0000-4000-8000-000000000002"
        Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] t in
            Task { @MainActor in
                guard let self, var p = self.view?.positions[uid] else { t.invalidate(); return }
                p.recorded_at = ISODate.string(Date())
                self.debugApply(.position(p))
            }
        }
        #endif
    }

    private func debugAutoTalk() {
        #if DEBUG
        /* Lab: `-SaryPTTAutoTalk "<after s>,<for s>"` holds the walkie-talkie button by itself (with -SaryPTTTone). */
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-SaryPTTAutoTalk"), i + 1 < args.count {
            let t = args[i + 1].split(separator: ",").compactMap { Double($0) }
            if t.count == 2 {
                DispatchQueue.main.asyncAfter(deadline: .now() + t[0]) { [weak self] in
                    PTTAudioEngine.log.notice("[PTT] lab: press")
                    self?.walkie.pressBegan()
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + t[0] + t[1]) { [weak self] in
                    PTTAudioEngine.log.notice("[PTT] lab: release")
                    self?.walkie.pressEnded()
                }
            }
        }
        #endif
    }

    /// `close()` ran: nothing of this session runs any more.
    private(set) var didClose = false

    func close() {
        didClose = true
        backgroundSender?.stop()
        stopBackgroundTrail()
        location.stopTrail()
        saveTrail()
        /* The last stretch, matched once more now the outing is over (cached for the details page). */
        if env.timers, TrailMatchPrefs.enabled(env.defaults) { matcher?.tick(trail, force: true) }
        location.onTrailFix = { _ in }
        mesh.setRunning(false)
        /* Back to «طلعاتي» as a member keeps the share armed (it resumes when the trip opens again). */
        stopSharingLocally(forget: !keepShareOnClose)
        walkie.detach(leftOuting: closedReason != nil)
        voiceNotes.close(leftOuting: closedReason != nil)
        channel?.stop()
        channel = nil
        timers.forEach { $0.invalidate() }
        timers = []
        location.stopWatchingForeground()
    }

    /// The app came to / left the screen. With «دائمًا» sharing keeps going off
    /// screen (HTTP, `BackgroundPositionSender`); without it, leaving stops the
    /// GPS and drops any fix waiting for the network, and the share intent stays,
    /// so it resumes on return.
    func foreground(_ active: Bool) {
        /* A closed session owns no GPS: coming back to the screen must not re-arm the foreground watch
         * (nothing would ever stop it again — the status-bar location arrow stayed on, issue #163). */
        guard !didClose else { return }
        visible = active
        location.setOffScreen(!active)
        sendPresenceHint(foreground: active)
        if active {
            backgroundSender?.stop()
            location.watchForeground()
            stopBackgroundTrail()
            syncTrailGPS()
            channel?.setAway(false)
            /* Back on screen: a live socket is proven with a ping (replaced if it went quiet), a
             * handshaking one is left alone, none at all reconnects now. */
            channel?.ensureLive(reason: "foreground")
            chat.flushOutbox()
            reconcileSharing()
        } else {
            channel?.dropPendingFix()
            /* The trail keeps going with the screen locked when it may (switch on; «دائمًا» or the
             * iOS 17+ activity session); otherwise the stretch until we are back is an honest gap.
             * Positions off screen go out only through SendGate.allowsBackgroundPosition («دائمًا»). */
            if canRecordTrailInBackground {
                recordingInBackground = true
                location.startBackgroundTrail()
            } else {
                trail.markGap()
            }
            saveTrail()
            /* «أثناء الاستخدام» only: sending pauses off screen. That is the moment «دائمًا» means
             * something, so the live screen offers it when the person is back (once per device). */
            if wantsToShare && view?.status == .active && !hasAlwaysPermission && (env.authorizationOverride ?? location.canLocate) {
                askAlwaysOnReturn = true
            }
            if gate.allowsBackgroundPosition && (location.isSharing || isDemo) {
                /* «دائمًا» or «أثناء الاستخدام» + activity session: keep sharing off screen, over HTTP. */
                backgroundSender?.start()
            } else {
                backgroundSender?.stop()
                location.stopSharing()
            }
            location.stopWatchingForeground()
            channel?.setAway(true)
            objectWillChange.send()
        }
    }

    private func beat() {
        guard visible else { return }
        channel?.heartbeat(gps: location.gpsState, battery: batterySharing ? Self.batteryNow() : nil,
                           hint: currentHint(foreground: true), lowPower: env.lowPower())
    }

    // MARK: «ليش مو مباشر؟» — presence hints and the offline backfill

    /// What I tell the others about myself now (server presence.js).
    func currentHint(foreground: Bool) -> PresenceHint {
        PresenceHint.forState(foreground: foreground, canLocate: env.authorizationOverride ?? location.canLocate, always: sharesInBackground)
    }

    /// Leaving / returning to the screen: one heartbeat with the hint, over HTTP (the socket is
    /// about to be suspended), so the others read «الموقع «أثناء الاستخدام» بس» right away
    /// instead of «انقطع» ten minutes later.
    func sendPresenceHint(foreground: Bool) {
        guard !isLocal, wantsToShare, view?.status == .active, closedReason == nil else { return }
        let hint = currentHint(foreground: foreground), low = env.lowPower(), outing = id
        if let post = env.postHint {
            Task { await post(outing, hint, low) }
            return
        }
        let gps = location.gpsState
        let done = env.keepAlive()
        Task { [api] in
            defer { done() }
            try? await api.heartbeat(outing, gps: gps, hint: hint, lowPower: low)
        }
    }

    /// iOS is closing the app (swiped away, or terminated while running): say so in the seconds left.
    /// With «دائمًا» iOS relaunches it on the next significant move and sharing resumes by itself.
    func appWillTerminate() {
        saveOfflineQueue()
        guard !isLocal, wantsToShare, view?.status == .active, closedReason == nil, env.postHint == nil else { return }
        api.heartbeatTerminatingNow(id, gps: location.gpsState)
    }

    /// A fix that could not reach the server: kept (thinned, capped, persisted) for the batch.
    func queueOffline(_ f: DeviceFix, mode: ShareMode) {
        guard !isLocal, gate.allowsPosition || gate.allowsBackgroundPosition else { return }
        if offlineQueue.enqueue(f, mode: mode) { saveOfflineQueue() }
    }

    private func saveOfflineQueue() {
        offlineQueue.save(user: myUserId, outing: id, defaults: env.defaults)
    }

    /// The network is back (socket live, a background POST went through): upload what waited, once.
    func flushBackfill() {
        guard !isLocal, !offlineQueue.isEmpty, view?.status == .active || view == nil, closedReason == nil, hasConsent else { return }
        let now = env.now()
        offlineQueue.prune(nowMs: now)
        guard let b = offlineQueue.batch(nowMs: now) else { return saveOfflineQueue() }
        if let post = env.postBackfill {
            if post(id, b.fixes, b.upToMs) { backfillDone(id, upToMs: b.upToMs, ok: true) }
            return
        }
        BackfillUploader.shared.upload(outingId: id, fixes: b.fixes, upToMs: b.upToMs, token: token, base: api.base)
    }

    func backfillDone(_ outing: String, upToMs: Double, ok: Bool) {
        guard outing == id, ok else { return }
        offlineQueue.ack(upToMs: upToMs)
        saveOfflineQueue()
    }

    static func batteryNow() -> BatteryInfo? {
        let d = UIDevice.current
        guard d.batteryLevel >= 0 else { return nil }
        return BatteryInfo(level: (Double(d.batteryLevel) * 100).rounded() / 100, charging: d.batteryState == .charging || d.batteryState == .full, at: nil)
    }

    // MARK: sharing

    /// Call after the consent sheet was accepted. Consent is recorded only once
    /// iOS permission is really granted, and only for this identity.
    func beginSharing() async {
        /* A solo outing has nobody to share with: no consent, no active share, the gate stays shut. */
        guard kind != .solo else { return }
        guard let v = view, v.status == .active else {
            errorText = "المشاركة تبدأ عندما يبدأ أمير الطلعة الطلعة."
            return
        }
        let st = await location.requestWhenInUse()
        guard st == .authorizedWhenInUse || st == .authorizedAlways else {
            errorText = "لم تسمح بالوصول إلى موقعك. فعّله من الإعدادات ← سَرى البارق ← الموقع."
            return
        }
        ShareMemory.recordConsent(user: myUserId, outing: id, defaults: env.defaults)
        pendingServerStop = false
        if !v.snapshot.me.sharing, !isLocal {
            do { _ = try await api.setSharing(id, sharing: true) } catch let e as OutingAPIError {
                errorText = e.arabic
                return
            } catch {}
            view?.apply(.memberSharing(userId: v.myId, sharing: true))
        }
        wantsToShare = true
        ShareMemory.setActiveShare(user: myUserId, outing: id, defaults: env.defaults)
        reconcileSharing()
    }

    /// Opened right after «انضم» / creating (the one-step join already asked iOS for the location).
    @Published var joinedJustNow = false

    /// Opened right after an invite join (build 21): the live screen frames me, the convoy and the
    /// destination once a good fix comes, and shows the one-time welcome (`InviteeArrival`).
    var arrivedByInvite = false

    /// The app left the screen while sharing with «أثناء الاستخدام» only: on return, the live
    /// screen explains «دائمًا» (the contextual upgrade; Apple does not let us force it at join).
    @Published var askAlwaysOnReturn = false

    /// The app is on screen (or CarPlay shows it).
    var isVisible: Bool { visible }

    /// Set by «ارجع للقائمة»: closing keeps the share armed for this member.
    var keepShareOnClose = false

    /// The share was resumed before the snapshot came: re-assert the server's flag then.
    private var reassertOnSnapshot = false
    /// PATCH sharing:true in flight (an older build's «أوقف» left it off): keep the intent meanwhile.
    private var reassertingServerShare = false

    /// You pressed stop: nothing more leaves the phone, the server deletes your fix.
    func stopSharing() async {
        /* Tell nearby cars too, so a relay never keeps showing where you were. */
        mesh.stop(farewell: .stop)
        stopSharingLocally()
        guard !isLocal else { return }
        /* Off screen (e.g. from the lock screen / CarPlay later): finish telling the server. */
        let done = env.keepAlive()
        defer { done() }
        do {
            _ = try await api.setSharing(id, sharing: false)
            view?.apply(.memberSharing(userId: myUserId, sharing: false))
            pendingServerStop = false
        } catch {
            pendingServerStop = true
        }
    }

    /// Internal for tests (the stop path without the network). `forget: false` keeps the armed
    /// share on disk (back to the list while still a member).
    func stopSharingLocally(forget: Bool = true) {
        wantsToShare = false
        lastSent = nil
        if forget { offlineQueue.clear(); saveOfflineQueue() }
        channel?.dropPendingFix()
        backgroundSender?.stop()
        if forget, ShareMemory.activeShare(user: myUserId, defaults: env.defaults) == id {
            ShareMemory.setActiveShare(user: myUserId, outing: nil, defaults: env.defaults)
        }
        location.stopSharing()
    }

    /// Resume after a relaunch only if THIS identity was sharing THIS outing with consent.
    /// Relaunched off screen by iOS (significant change / region exit) with «دائمًا»: the GPS
    /// starts at once (keeps the app alive) and the outing is fetched over HTTP; nothing is
    /// sent until that snapshot confirms the outing is active and sharing is on for me.
    func resumeIfPreviouslySharing() {
        guard ShareMemory.activeShare(user: myUserId, defaults: env.defaults) == id, hasConsent else { return }
        wantsToShare = true
        if let v = view { reassertServerShare(v) } else { reassertOnSnapshot = true }
        if !visible && hasAlwaysPermission && !isLocal && view == nil {
            if env.authorizationOverride ?? location.canLocate { location.startSharing(mode: mode) }
            let done = env.keepAlive()
            Task { [weak self, api, id] in
                defer { done() }
                if let snap = try? await api.poll(id) { self?.applySnapshot(snap) }
            }
        }
        reconcileSharing()
    }

    /// Forced sharing (build 14): a member whose server flag is off (an older build's «أوقف») is
    /// switched back on when the trip opens. Once only per open: a later «off» from the server is
    /// respected (the gate closes) — it can only come from elsewhere.
    private func reassertServerShare(_ v: OutingView) {
        guard !isLocal, !v.snapshot.me.sharing, v.status != .ended, closedReason == nil, !reassertingServerShare else { return }
        reassertingServerShare = true
        Task { [weak self] in
            guard let self else { return }
            if (try? await self.api.setSharing(self.id, sharing: true)) != nil {
                self.view?.apply(.memberSharing(userId: self.myUserId, sharing: true))
            }
            self.reassertingServerShare = false
            self.reconcileSharing()
        }
    }

    /// The network came back: a fix waiting off screen goes now (if still fresh).
    func networkBack() { backgroundSender?.networkBack() }

    private func backgroundResult(_ r: BackgroundPositionSender.Outcome) {
        #if DEBUG
        ShareLog.log.notice("background send: \(String(describing: r))")
        #endif
        switch r {
        case .sent:
            lastAck = (true, nil)
            flushBackfill()
        case let .refused(reason): ack(false, reason)
        case .notAMember: closed(.notAMember)
        case .unauthorized: closed(.unauthorized)
        }
    }

    private func reconcileSharing() {
        let wasAuthorized = location.canLocate
        let wasSharing = location.isSharing
        let wasWantsToShare = wantsToShare
        let wasRecordingInBackground = recordingInBackground
        let wasBackgroundSending = backgroundSender?.running == true
        /* Ended, left, removed, switch off: the screen-locked trail stops at once. */
        if recordingInBackground && !canRecordTrailInBackground { stopBackgroundTrail() }
        syncTrailGPS()
        guard let v = view else { return }
        /* Ended / sharing switched off elsewhere: the intent ends too. Paused keeps it (the gate
         * closes while paused, and sharing comes back by itself on resume: no toggle to press). */
        if wantsToShare && !reassertingServerShare && (v.status == .ended || !v.snapshot.me.sharing) {
            stopSharingLocally()
        }
        let allowed = gate.allowsPosition
        if allowed && !location.isSharing {
            location.startSharing(mode: mode)
            /* Only a fix from the last few seconds; an old one is never sent as "now". */
            if let f = location.lastFix, Date().timeIntervalSince1970 * 1000 - f.atMs < 10_000 { handleFix(f) }
        } else if !allowed && location.isSharing {
            location.stopSharing()
            channel?.dropPendingFix()
        }
        if gate.allowsBackgroundPosition {
            if backgroundSender?.running == false { backgroundSender?.start() }
        } else if backgroundSender?.running == true {
            backgroundSender?.stop()
        }
        updateMesh()
        /* Authorization callbacks may repeat the same state during the first SwiftUI update.
         * Publish only if this reconciliation actually changed session-visible sharing state. */
        if wasAuthorized != location.canLocate || wasSharing != location.isSharing ||
            wasWantsToShare != wantsToShare || wasRecordingInBackground != recordingInBackground ||
            wasBackgroundSending != (backgroundSender?.running == true) {
            objectWillChange.send()
        }
    }

    // MARK: nearby (phone to phone)

    /// The server's picture with what nearby cars said laid over it (newest wins).
    var displayView: OutingView? { meshOverlay.view }

    var meshOverlay: (view: OutingView?, viaNearby: Set<String>) {
        guard let v = view else { return (nil, []) }
        guard !mesh.store.fixes.isEmpty || !mesh.store.events.isEmpty else { return (v, []) }
        let o = mesh.overlay(v)
        return (o.view, o.viaNearby)
    }

    /// Same consent as sharing (`SendGate`); on only while needed.
    func updateMesh() {
        guard env.nearbyMesh, env.timers else { return }
        if let v = view { mesh.setMembers(Set(v.members.keys)) }
        let now = Date()
        var friendLost = false
        if let v = view {
            for m in v.members.values where m.user_id != v.myId && m.sharing {
                if v.freshness(of: m.user_id, deviceNow: now) == .lost { friendLost = true; break }
            }
        }
        var forced = false
        #if DEBUG
        forced = Self.meshTest
        #endif
        let on = meshActivation.update(gateOpen: gate.allowsPosition, linkHealthy: link == .live || link == .polling,
                                       friendLost: friendLost, forced: forced, nowMs: now.timeIntervalSince1970 * 1000)
        mesh.setRunning(on)
    }

    private func nearbyEvents(_ evs: [MeshEvent]) {
        guard let v = displayView else { return }
        for e in evs where e.u != v.myId {
            let name = v.members[e.u]?.display_name ?? ""
            switch e.k {
            case .sos:
                Notifier.post(title: "طوارئ: \(name)", body: "يحتاج مساعدة · عبر الأجهزة القريبة", outingId: id, kind: "sos")
            case .stuck:
                Notifier.post(title: "\(name) غرّز", body: e.text.map { "\($0) · عبر الأجهزة القريبة" } ?? "عبر الأجهزة القريبة", outingId: id, kind: "sos")
            default:
                break
            }
            onNearbyEvent(e)
        }
    }

    /// A send to the server failed but nearby cars got it: not an error to show.
    private func deliveredNearby() {
        if mesh.running && mesh.nearbyCars > 0, errorText != nil { errorText = nil }
    }

    /// Every fix from the GPS while sharing. Internal for tests.
    func handleFix(_ f: DeviceFix) {
        #if DEBUG
        ShareLog.log.notice("fix age=\(Int(Date().timeIntervalSince1970 * 1000 - f.atMs))ms acc=\(f.accuracy ?? -1) gate=\(self.gate.allowsPosition) fg=\(self.gate.foreground) bg=\(self.gate.allowsBackgroundPosition) gps=\(self.location.isSharing)")
        #endif
        guard gate.allowsPosition, location.isSharing || isDemo else { return }
        /* My own totals for «ملخص رحلتي»: on this device only, never points. */
        if !isDemo { TripLogStore.update(id, defaults: env.defaults) { $0.add(lat: f.lat, lng: f.lng, accuracy: f.accuracy, speed: f.speed, atMs: f.atMs, speedAccuracy: f.speedAccuracy) } }
        let now = Date().timeIntervalSince1970 * 1000
        let m = location.effectiveMode
        if !gate.foreground {
            /* Off screen («دائمًا»): the HTTP sender keeps only the latest fix and decides when. */
            guard ServerRules.check(Policy.wireFix(f, mode: m, nowMs: now)) == .ok, !isLocal else { return }
            backgroundSender?.offer(f, mode: m)
            return
        }
        guard Policy.shouldSend(f, last: lastSent, mode: m, nowMs: now) else { return }
        guard ServerRules.check(Policy.wireFix(f, mode: m, nowMs: now)) == .ok else { return }
        lastSent = .init(fix: f, sentAtMs: now)
        if isLocal { return }
        /* No link at all (dead zone): keep it for the batch upload when the network is back. */
        if link == .offline || link == .connecting { queueOffline(f, mode: m) }
        channel?.sendFix(f, mode: m)
    }

    // MARK: «مساري» — the on-device trail

    /// Recording is on (switch), the outing is active or paused, I am in it, and it is not closed.
    var trailRecordingAllowed: Bool {
        guard TrailPrefs.record(env.defaults), closedReason == nil, let v = view, v.me != nil else { return false }
        return v.status == .active || v.status == .paused
    }

    var hasAlwaysPermission: Bool { env.alwaysOverride ?? location.hasAlways }

    /// Sharing may keep going off screen: «دائمًا», or «أثناء الاستخدام» with the iOS 17+
    /// background activity session taken on screen (LocationSharer.sharesInBackground).
    var sharesInBackground: Bool { hasAlwaysPermission || (env.backgroundSessionOverride ?? location.sharesInBackground) }

    /// iOS keeps the trail running with the screen locked: «دائمًا», or (iOS 17+) «أثناء الاستخدام»
    /// with the background activity session taken while on screen.
    var lockedScreenTrailPossible: Bool {
        hasAlwaysPermission || (env.lockedScreenTrailOverride ?? (env.authorizationOverride ?? location.canLocate))
    }

    /// The screen-locked trail may run: both switches on, iOS allows it, and an outing I am recording.
    var canRecordTrailInBackground: Bool {
        TrailPrefs.background(env.defaults) && lockedScreenTrailPossible && trailRecordingAllowed
    }

    /// The GPS at its best while «مساري» records on screen; back to normal when it may not.
    func syncTrailGPS() {
        if trailRecordingAllowed && visible {
            location.startTrail(background: TrailPrefs.background(env.defaults))
        } else if !trailRecordingAllowed {
            location.stopTrail()
        }
    }

    /// My fix as the map draws «أنت»: the Kalman-smoothed position (and speed) for this very fix
    /// when «مساري» is recording, else `LocationSharer.displayFix` (anchored at a camp, lightly
    /// smoothed on the move) for this fix. Display only — never what is sent, never SOS.
    func smoothedFix(_ f: DeviceFix?) -> DeviceFix? {
        guard var f, let k = trail.filter, k.started, abs(k.tMs - f.atMs) < 1500 else {
            if let f, let d = location.displayFix, d.atMs == f.atMs { return d }
            return f
        }
        let p = k.position
        f.lat = p.lat
        f.lng = p.lng
        if f.speed == nil { f.speed = k.speedMps }
        /* A crawling car's course points anywhere: no arrow rather than a wrong one. */
        f.heading = HeadingChooser.course(f)
        return f
    }

    /// What the map draws and «طريق العودة» follows: road-matched where confident, smoothed elsewhere.
    var displayTrail: [TrailPoint] {
        guard TrailMatchPrefs.enabled(env.defaults) else { return trail.points }
        return displayTrailMemo.value(points: trail.points, cache: matcher?.cache, compose: TrailDisplay.compose)
    }

    /// «الدقة ±٨ م · ١٢ نقطة/دقيقة» and what to fix.
    var trailHealth: TrailHealth {
        TrailHealth.compute(raw: recentRaw, nowMs: Date().timeIntervalSince1970 * 1000,
                            preciseOff: location.preciseOff, whenInUseOnly: location.canLocate && !hasAlwaysPermission,
                            lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)
    }

    /// On roads the GPS uses iOS's automotive model; where the matcher finds no road lately, the generic one.
    private func updateRoadMode() {
        guard let last = trail.points.last, let m = matcher else { return }
        let matchedRecently = m.cache.spans.last.map { last.t - $0.endT < 5 * 60_000 } ?? false
        let triedRecently = last.t - m.cache.doneUpToT < 5 * 60_000
        if triedRecently { location.onRoad = matchedRecently }
    }

    /// Every GPS fix, foreground or (with «دائمًا») background. It goes into the trail on this
    /// phone and nowhere else: this path never reaches `handleFix`, `LiveChannel` or the API.
    func trailFix(_ f: DeviceFix) {
        guard trailRecordingAllowed else { return }
        guard visible || recordingInBackground else { return }
        /* Every raw fix is kept (compact, capped): the drawn trail is derived from them. */
        let raw = RawFix(f)
        rawPending.append(raw)
        recentRaw.append(raw)
        if recentRaw.count > 400 { recentRaw.removeFirst(recentRaw.count - 300) }
        let added = trail.add(raw)
        if added { trailUnsaved += 1 }
        /* Solo: «ملخص رحلتي» (distance, time) from the trail's own fixes — `handleFix` never runs
         * there, its gate stays closed (nothing is shared). On this device only, like the trail. */
        if kind == .solo {
            TripLogStore.update(id, defaults: env.defaults) { $0.add(lat: f.lat, lng: f.lng, accuracy: f.accuracy, speed: f.speed, atMs: f.atMs, speedAccuracy: f.speedAccuracy) }
        }
        if rawPending.count >= 30 || (added && (trailUnsaved >= 5 || Date().timeIntervalSince(trailSavedAt) > 5)) { saveTrail() }
        if added, env.timers, TrailMatchPrefs.enabled(env.defaults) { matcher?.tick(trail) }
    }

    func saveTrail() {
        if !rawPending.isEmpty {
            TrailRawLog.append(rawPending, outingId: id, in: env.trailDirectory)
            rawPending = []
        }
        guard trailUnsaved > 0 || trail.isEmpty == false else { return }
        TrailStore.save(trail, outingId: id, in: env.trailDirectory)
        trailSavedAt = Date()
        trailUnsaved = 0
    }

    /// «امسح مساري لهذه الطلعة».
    func clearTrail() {
        trail = Trail()
        TrailStore.delete(id, in: env.trailDirectory)
        matcher?.clear()
        rawPending = []
        recentRaw = []
        trailUnsaved = 0
    }

    /// «سجّل مساري» switch.
    func setTrailRecording(_ on: Bool) {
        env.defaults.set(on, forKey: TrailPrefs.recordKey)
        /* Off and on again: what happened in between was not recorded. */
        trail.markGap()
        if !on { stopBackgroundTrail(); saveTrail() }
        syncTrailGPS()
        objectWillChange.send()
    }

    /// «سجّل مساري والشاشة مقفلة» switch (asking iOS for «دائمًا» is the caller's, after the explainer).
    func setBackgroundTrail(_ on: Bool) {
        env.defaults.set(on, forKey: TrailPrefs.backgroundKey)
        if !on { stopBackgroundTrail() }
        syncTrailGPS()
        objectWillChange.send()
    }

    private func stopBackgroundTrail() {
        guard recordingInBackground || location.backgroundTrail else { return }
        recordingInBackground = false
        location.stopBackgroundTrail()
        /* If we are still off screen, from here on nothing is recorded. */
        if !visible { trail.markGap() }
    }

    #if DEBUG
    /// Screenshots / UI tests: a plausible trail into the demo outing (DEBUG builds only).
    func seedDemoTrail(_ t: Trail) { trail = t }

    /// Screenshots and UI tests (`-SaryFriendSOS <s>`): a friend in the demo outing raises SOS.
    func demoFriendSOS() {
        guard isDemo, let v = view, let uid = v.positions.keys.sorted().first(where: { $0 != v.myId }) else { return }
        view?.apply(.sos(userId: uid, sos: SosInfo(at: ISODate.string(Date()), fix: nil), refresh: false))
    }
    #endif

    // MARK: inbound

    private func linkChanged(_ s: LiveChannel.State) {
        let was = link
        if s != was { link = s }
        if s == .live, was != .live {
            chat.linkLive()
            voiceNotes.linkLive()
        }
        if s == .live || s == .polling { flushBackfill() }
        updateMesh()
        walkie.linkChanged()
        if s == .live || s == .polling, pendingServerStop {
            Task { await self.retryServerStop() }
        }
    }

    private func retryServerStop() async {
        guard pendingServerStop, !wantsToShare else { return }
        if (try? await api.setSharing(id, sharing: false)) != nil {
            pendingServerStop = false
            view?.apply(.memberSharing(userId: myUserId, sharing: false))
        }
    }

    private func applySnapshot(_ s: OutingSnapshot) {
        let previous = view
        var next = OutingView.merge(view, s)
        /* The server's picture may predate what this phone already did (#173): keep that on top. */
        reapplyPending(&next)
        view = next
        chat.snapshot(unread: s.chat_unread)
        mesh.setServerKey(s.mesh_key, outingId: id)
        if let previous { notifyChanges(from: previous) }
        if s.outing.status == .ended { closed(.outingEnded) }
        if reassertOnSnapshot, let v = view {
            reassertOnSnapshot = false
            if wantsToShare { reassertServerShare(v) }
        }
        reconcileSharing()
    }

    /// Reconcile the waiting state with the authoritative outing snapshot.
    /// This is also exposed through the waiting banner as an immediate recovery action.
    func refreshWaitingStatus() async {
        guard !isLocal, view?.status == .created, !refreshingWaitingStatus else { return }
        refreshingWaitingStatus = true
        defer { refreshingWaitingStatus = false }
        guard let snapshot = try? await api.poll(id) else { return }
        applySnapshot(snapshot)
    }

    #if DEBUG
    /// Demo / screenshots only: feed one live event as if the server sent it.
    func debugApply(_ e: LiveEvent) {
        guard isDemo else { return }
        apply(e)
    }
    #endif

    private func apply(_ e: LiveEvent) {
        guard var v = view else { return }
        let before = v
        v.apply(e)
        reapplyPending(&v)
        view = v
        events.send(e)
        switch e {
        case let .memberNote(uid, note?) where uid != v.myId && before.members[uid]?.note != note:
            Notifier.post(title: v.members[uid]?.display_name ?? "ملاحظة جديدة", body: note.text, outingId: id, kind: "note")
        case let .sos(uid, sos?, refresh) where uid != v.myId && !refresh:
            Notifier.post(title: "طوارئ: \(v.members[uid]?.display_name ?? "")", body: sos.fix == nil ? "يحتاج مساعدة (بدون موقع)" : "يحتاج مساعدة الحين", outingId: id, kind: "sos")
        case let .sos(uid, nil, _):
            mesh.serverClearedSOS(uid)
        case let .memberLeft(uid) where uid == v.myId:
            closed(.left)
        case .outingStatus, .memberSharing:
            reconcileSharing()
        case let .safety(s):
            safetyEvents.send(s)
        case .planUpdated, .checklistUpdated:
            PlanEvents.post(outing: id, e)
        default:
            break
        }
    }

    /// The server's answer to a feature call (convoy), applied like the live event that echoes it.
    func applyLocal(_ e: LiveEvent) { apply(e) }

    private func notifyChanges(from prev: OutingView) {
        guard let v = view else { return }
        for (uid, m) in v.members where uid != v.myId {
            if let n = m.note, prev.members[uid]?.note != n {
                Notifier.post(title: m.display_name, body: n.text, outingId: id, kind: "note")
            }
        }
    }

    private func ack(_ ok: Bool, _ reason: String?) {
        lastAck = (ok, reason)
        if !ok, reason == "sharing_off" || reason == "outing_paused" || reason == "outing_ended" || reason == "not_allowed" || reason == "outing_created" {
            if reason == "outing_paused" { view?.apply(.outingStatus(.paused)) }
            if reason == "outing_created" { view?.apply(.outingStatus(.created)) }
            /* not_allowed: the server's database says I am not sharing there (changed elsewhere). */
            if reason == "sharing_off" || reason == "not_allowed", let me = view?.myId { view?.apply(.memberSharing(userId: me, sharing: false)) }
            if reason == "outing_ended" { return closed(.outingEnded) }
            reconcileSharing()
        }
    }

    private func syncClock(_ serverNow: String) {
        guard let d = ISODate.parse(serverNow) else { return }
        view?.clockOffsetMs = (d.timeIntervalSince1970 - Date().timeIntervalSince1970) * 1000
    }

    private func closed(_ r: LiveCloseReason) {
        guard closedReason == nil else { return }
        PTTDiagnosticsLog.shared.add("session", "closed for good: \(r.rawValue)")
        closedReason = r
        stopBackgroundTrail()
        /* «مساري» stops recording now (its best-accuracy GPS and the iOS 17 activity session that keeps
         * the blue arrow): the socket's 4410 / an `outing_ended` ack / «removed» reach here without
         * `reconcileSharing`, and the screen may stay open on the ended trip for a long time. */
        syncTrailGPS()
        saveTrail()
        stopSharingLocally()
        if r == .outingEnded { view?.apply(.outingStatus(.ended)) }
        walkie.detach(leftOuting: true)
        voiceNotes.close(leftOuting: true)
        channel?.stop()
    }

    // MARK: actions

    private func run(_ key: String, _ work: () async throws -> Void) async -> Bool {
        busy.insert(key)
        defer { busy.remove(key) }
        do {
            try await work()
            return true
        } catch let e as OutingAPIError {
            errorText = e.arabic
        } catch {
            errorText = OutingAPIError(code: "network", status: 0).arabic
        }
        return false
    }

    // MARK: instant actions (#173, docs/RESPONSIVENESS.md)
    //
    // One pattern for every action that is safe to apply before the server answers:
    //   (a) the screen changes at once (< 100 ms: no network on the way);
    //   (b) what is safe locally happens now — sharing stops, the screen closes, the picture changes;
    //   (c) the request goes through `outbox` (persisted, retried with backoff, again when the
    //       network is back, survives the app being killed);
    //   (d) a failure shows one line («نكمل … لما يرجع النت») and never resumes sharing.
    // Local sessions (demo, solo) apply on this phone and queue nothing.
    // Deliberately NOT here: raising SOS (its delivery must be confirmed), ending / starting /
    // pausing the outing (everyone's state; one confirmation, then the server decides), showing my
    // location again and turning sharing on (they open sharing: only once the server agreed).

    /// Queue the server half of an action already applied here.
    private func sendLater(_ kind: PendingOutingAction.Kind, member: String? = nil, on: Bool? = nil, lat: Double? = nil, lng: Double? = nil,
                           label: String? = nil, text: String? = nil, trace: ActionTrace.Interval) {
        guard !isLocal else { return ActionTrace.acked(trace, ok: true) }
        outbox.enqueue(PendingOutingAction(user: myUserId, outing: id, kind: kind, member: member, on: on, lat: lat, lng: lng,
                                           label: label, text: text, createdMs: env.now()), trace: trace)
    }

    /// What the outbox heard back for this outing.
    private func outboxReport(_ r: OutingActionOutbox.Report) {
        guard closedReason == nil, r.action.user == myUserId else { return }
        switch r.outcome {
        case .sent:
            break
        case .willRetry:
            /* Once per action, at its first failure; the outbox keeps trying by itself. */
            if r.action.attempts == 0 { onDeferredNotice(PendingActionCopy.toast(r.action.kind)) }
        case let .dropped(e):
            onDeferredNotice(e?.arabic ?? SaryCopy.genericError)
            /* Refused for good: the server's picture wins again. Except «أخفِ موقعي»: a refusal
             * never shows my location again on its own (privacy; I can press «أظهر موقعي»). */
            guard r.action.kind != .hide else { return }
            Task { [weak self, api, id] in
                if let snap = try? await api.poll(id) { self?.applySnapshot(snap) }
            }
        }
    }

    /// Lay what this phone did and the server has not confirmed yet over `v` (a snapshot or event
    /// from before it must not undo it on screen — above all a queued «أخفِ موقعي»).
    private func reapplyPending(_ v: inout OutingView) {
        guard !isLocal else { return }
        let pending = outbox.queue.pending(user: myUserId, outing: id)
        guard !pending.isEmpty else { return }
        for a in pending {
            let at = ISODate.string(Date(timeIntervalSince1970: a.createdMs / 1000))
            switch a.kind {
            case .hide:
                if v.me?.hidden != true { v.apply(.memberHidden(userId: myUserId, hidden: true, since: at, reason: "self")) }
            case .setRally:
                if let lat = a.lat, let lng = a.lng { v.apply(.rally(RallyInfo(lat: lat, lng: lng, label: a.label, set_at: at, set_by: myUserId))) }
            case .clearRally:
                v.apply(.rally(nil))
            case .cancelSOS:
                if v.members[myUserId]?.sos != nil { v.apply(.sos(userId: myUserId, sos: nil, refresh: false)) }
            case .coLeader:
                if let m = a.member, v.members[m] != nil { v.apply(.memberRole(userId: m, coLeader: a.on ?? false)) }
            case .removeMember:
                if let m = a.member, v.members[m] != nil { v.apply(.memberLeft(userId: m)) }
            case .note:
                let t = a.text ?? ""
                v.apply(.memberNote(userId: myUserId, note: t.isEmpty ? nil : MemberNote(text: t, at: at)))
            case .leave:
                break
            }
        }
    }

    /// «رسالة فوق سيارتي». `deferred` (the note sheet): shown at once and sent through the outbox.
    /// Without it (broadcasts whose caller says «وصل…»): true only once the server or nearby cars got it.
    @discardableResult
    func sendNote(_ text: String, deferred: Bool = false) async -> Bool {
        let clean = text.isEmpty ? "" : (ServerRules.cleanText(text, max: ServerRules.noteMax) ?? "")
        let t = ActionTrace.begin("note")
        if isLocal || deferred {
            if let me = view?.myId { view?.apply(.memberNote(userId: me, note: clean.isEmpty ? nil : MemberNote(text: clean, at: ISODate.string(Date())))) }
            ActionTrace.uiShown(t)
            if !isLocal { mesh.announce(.note, text: clean) }
            sendLater(.note, text: clean, trace: t)
            return true
        }
        mesh.announce(.note, text: clean)
        let ok = await run("note") {
            let n = try await api.note(id, text: clean)
            if let me = view?.myId { view?.apply(.memberNote(userId: me, note: n)) }
        }
        ActionTrace.uiShown(t)
        ActionTrace.acked(t, ok: ok)
        if !ok { deliveredNearby() }
        return ok || mesh.nearbyCars > 0
    }

    /// Start / pause / resume / end — everyone's state, so the server decides (deliberately not
    /// instant, #173). The caller shows «جاري…» at once; success is never faked.
    func setStatus(_ action: String) async {
        let t = ActionTrace.begin("status-\(action)")
        defer { ActionTrace.uiShown(t) }
        if isLocal {
            /* `-demo`: no server; the demo outing changes state on this phone only. */
            let st: OutingStatus = action == "end" ? .ended : action == "pause" ? .paused : .active
            view?.apply(.outingStatus(st))
            reconcileSharing()
            if st == .ended { closed(.outingEnded) }
            ActionTrace.acked(t, ok: true)
            return
        }
        let ok = await run("status") {
            let o = try await api.setStatus(id, action: action)
            view?.apply(.outingStatus(o.status))
            reconcileSharing()
            if o.status == .ended { closed(.outingEnded) }
        }
        ActionTrace.acked(t, ok: ok)
    }

    /// Leave the outing (also after it ended). Instant (#173): sharing stops, nearby cars are told
    /// and the session closes on this phone now; `POST /leave` goes through the persisted outbox
    /// and is retried until the server agrees. A failed or pending request never resumes sharing:
    /// on this phone I have left. Always true (kept for callers that read it).
    @discardableResult
    func leave() -> Bool {
        let t = ActionTrace.begin("leave")
        mesh.stop(farewell: .stop)
        stopSharingLocally()
        closed(.left)
        ActionTrace.uiShown(t)
        sendLater(.leave, trace: t)
        return true
    }

    // MARK: «أخفِ موقعي»

    /// When I hid my location in this trip (nil: shown).
    var hiddenSince: Date? {
        guard view?.me?.hidden == true else { return nil }
        return view?.me?.hidden_at.flatMap(ISODate.parse) ?? Date()
    }

    /// Hide / show my location. Hidden: still in the trip (voice notes, radio, chat); nothing is
    /// sent (SendGate.hidden), whatever waited offline is dropped, a reminder comes at 30 min.
    /// Hiding is instant (#173: it only closes the gate); showing again opens sharing, so it waits
    /// for the server — unless the hide never reached it, then there is nothing to undo there.
    @discardableResult
    func setHidden(_ on: Bool) async -> Bool {
        guard let me = view?.myId, view?.status != .ended else { return false }
        let t = ActionTrace.begin(on ? "hide" : "show")
        let ok: Bool
        if isLocal || on {
            view?.apply(.memberHidden(userId: me, hidden: on, since: on ? ISODate.string(Date()) : nil, reason: "self"))
            ActionTrace.uiShown(t)
            if on { sendLater(.hide, trace: t) } else { ActionTrace.acked(t, ok: true) }
            ok = true
        } else if outbox.discard(user: myUserId, outing: id, kind: .hide) {
            view?.apply(.memberHidden(userId: me, hidden: false, since: nil, reason: "self"))
            ActionTrace.uiShown(t)
            ActionTrace.acked(t, ok: true)
            ok = true
        } else {
            /* A hide already on the wire must land first, or it would hide me again after this. */
            await outbox.waitUntilNotInFlight(user: myUserId, outing: id, kind: .hide, timeoutMs: 15_000)
            ok = await run("hidden") {
                let r = try await api.setHidden(id, hidden: on)
                view?.apply(.memberHidden(userId: me, hidden: r.hidden, since: r.since, reason: "self"))
            }
            ActionTrace.uiShown(t)
            ActionTrace.acked(t, ok: ok)
        }
        if ok && on {
            channel?.dropPendingFix()
            offlineQueue.clear()
            saveOfflineQueue()
        }
        HideReminder.sync(outingId: id, since: hiddenSince)
        objectWillChange.send()
        return ok
    }

    /// «نبّهه» (leader): nil when sent, else the line to show. Not queued: a nudge that arrives
    /// late is wrong, and the specific refusals (hidden, too soon) are the answer the leader wants.
    func nudge(_ uid: String) async -> String? {
        if isLocal { return nil }
        let t = ActionTrace.begin("nudge")
        defer { ActionTrace.uiShown(t) }
        do {
            try await api.nudge(id, member: uid)
            ActionTrace.acked(t, ok: true)
            return nil
        } catch let e as OutingAPIError {
            ActionTrace.acked(t, ok: false)
            switch e.code {
            case "member_hidden": return "مخفي موقعه بإرادته — ما نرسل له تنبيه"
            case "too_frequent", "rate_limited": return "نبّهته قبل شوي — انتظر دقايق"
            case "leader_only": return "التنبيه للأمير ونائبه بس"
            default: return "ما قدرنا نرسل التنبيه — حاول مرة ثانية"
            }
        } catch {
            ActionTrace.acked(t, ok: false)
            return "ما قدرنا نرسل التنبيه — حاول مرة ثانية"
        }
    }

    /// SOS after the 1 s hold. Carries my real fix whenever iOS allows — even with «أخفِ موقعي»
    /// on (SendGate.allowsSosFix), and then my location is shown again (true is returned).
    /// Deliberately not instant (#173): the alert's delivery is confirmed (`sosSending` meanwhile).
    @discardableResult
    func raiseSOS() async -> Bool {
        guard let me = view?.myId else { return false }
        let t = ActionTrace.begin("sos")
        defer { ActionTrace.uiShown(t) }
        let wasHidden = view?.me?.hidden == true
        defer {
            if wasHidden {
                view?.apply(.memberHidden(userId: me, hidden: false, since: nil, reason: "sos"))
                HideReminder.sync(outingId: id, since: nil)
            }
        }
        sosSending = true
        defer { sosSending = false }
        var wire: WireFix?
        if gate.allowsSosFix, let f = location.lastFix {
            let w = Policy.wireFix(f, mode: .precise, nowMs: Date().timeIntervalSince1970 * 1000)
            if w.age_ms <= 25 * 60_000, (f.accuracy ?? 0) <= ServerRules.maxAccuracyM { wire = w }
        }
        mesh.announce(.sos, sosFix: wire == nil ? nil : location.lastFix)
        if isLocal {
            view?.apply(.sos(userId: me, sos: SosInfo(at: ISODate.string(Date()), fix: nil), refresh: false))
            ActionTrace.acked(t, ok: true)
            return wasHidden
        }
        /* A «أنا بخير» still queued from before must not land after this SOS and cancel it. One
         * already on the wire can't be taken back: the SOS goes now, and is raised again once
         * that request is done (below), so it can never end up cancelled. */
        outbox.discard(user: myUserId, outing: id, kind: .cancelSOS)
        let racingCancel = outbox.isInFlight(user: myUserId, outing: id, kind: .cancelSOS)
        let racingHide = wasHidden && outbox.isInFlight(user: myUserId, outing: id, kind: .hide)
        /* The SOS shows me again (the server does the same): a queued hide must not undo that. */
        if wasHidden { outbox.discard(user: myUserId, outing: id, kind: .hide) }
        let ok = await run("sos") {
            let s = try await api.raiseSos(id, fix: wire)
            view?.apply(.sos(userId: me, sos: s, refresh: false))
        }
        if ok, racingCancel {
            await outbox.waitUntilNotInFlight(user: myUserId, outing: id, kind: .cancelSOS, timeoutMs: 15_000)
            _ = await run("sos") {
                let s = try await api.raiseSos(id, fix: wire)
                view?.apply(.sos(userId: me, sos: s, refresh: false))
            }
        }
        if ok, racingHide {
            await outbox.waitUntilNotInFlight(user: myUserId, outing: id, kind: .hide, timeoutMs: 15_000)
            _ = await run("hidden") {
                let r = try await api.setHidden(id, hidden: false)
                view?.apply(.memberHidden(userId: me, hidden: r.hidden, since: r.since, reason: "self"))
            }
        }
        ActionTrace.acked(t, ok: ok)
        if !ok {
            deliveredNearby()
            /* The server did not hear the SOS: still show my location again, as promised. */
            if wasHidden { Task { [api, id] in _ = try? await api.setHidden(id, hidden: false) } }
        }
        return wasHidden
    }

    /// «أنا بخير»: instant (#173). The nearby cars hear it at once, my screen drops the alert, and
    /// `DELETE /sos` goes through the outbox. Until it lands the others still see my SOS — the safe
    /// side of a failure.
    func cancelSOS() async {
        guard let me = view?.myId else { return }
        let t = ActionTrace.begin("sos-cancel")
        mesh.announce(.sosClear)
        view?.apply(.sos(userId: me, sos: nil, refresh: false))
        ActionTrace.uiShown(t)
        sendLater(.cancelSOS, trace: t)
    }

    /// Drop or move the meeting point: instant (#173). True once applied here.
    @discardableResult
    func setRally(lat: Double, lng: Double, label: String?) async -> Bool {
        let t = ActionTrace.begin("rally-set")
        view?.apply(.rally(RallyInfo(lat: lat, lng: lng, label: label, set_at: ISODate.string(Date()), set_by: myUserId)))
        ActionTrace.uiShown(t)
        sendLater(.setRally, lat: lat, lng: lng, label: label, trace: t)
        return true
    }

    func clearRally() async {
        let t = ActionTrace.begin("rally-clear")
        view?.apply(.rally(nil))
        ActionTrace.uiShown(t)
        sendLater(.clearRally, trace: t)
    }

    /// «نائب الأمير»: instant (#173). A refusal brings the server's picture back.
    func setCoLeader(_ member: String, on: Bool) async {
        let t = ActionTrace.begin("co-leader")
        view?.apply(.memberRole(userId: member, coLeader: on))
        ActionTrace.uiShown(t)
        sendLater(.coLeader, member: member, on: on, trace: t)
    }

    /// Remove a member: instant on this screen (#173); the server is told through the outbox.
    func removeMember(_ member: String) async {
        let t = ActionTrace.begin("remove-member")
        view?.apply(.memberLeft(userId: member))
        ActionTrace.uiShown(t)
        sendLater(.removeMember, member: member, trace: t)
    }

    /// The invite link this device created, if any. The server keeps only its hash.
    func storedInviteURL() -> URL? {
        InviteTokenStore.load(id).map(InviteLink.url(for:))
    }

    /// Owner only: a new link. This revokes every earlier link, so it is never automatic.
    /// Not instant (#173): the link is made by the server; the screen shows «جاري…» meanwhile.
    func newInviteURL() async -> URL? {
        let t = ActionTrace.begin("invite")
        var out: URL?
        let ok = await run("invite") {
            let inv = try await api.rotateInvite(id)
            InviteTokenStore.save(id, inv.token)
            out = InviteLink.url(for: inv.token)
        }
        ActionTrace.uiShown(t)
        ActionTrace.acked(t, ok: ok)
        return out
    }

    /// Push-to-talk upload. Returns the clip on success.
    func sendClip(_ audio: Data, durationMs: Int) async -> VoiceClip? {
        if isLocal { return nil }
        var out: VoiceClip?
        _ = await run("clip") { out = try await api.uploadClip(id, audio: audio, durationMs: durationMs) }
        return out
    }

    func clipAudio(_ clip: VoiceClip) async throws -> Data { try await api.fetchClip(clip) }
}

#if DEBUG
/// DEBUG builds only: the share path in the unified log (`log stream --predicate 'category == "share"'`), for simulator verification.
enum ShareLog {
    static let log = Logger(subsystem: "sa.sary.albarq", category: "share")
}
#endif

/// Local notifications for notes and SOS.
enum Notifier {
    static func post(title: String, body: String, outingId: String, kind: String) {
        /* The in-app switch («التنبيهات») covers these too. */
        guard UserDefaults.standard.object(forKey: PushRegistrar.enabledKey) as? Bool ?? true else { return }
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        c.threadIdentifier = "outing-\(outingId)"
        c.userInfo = ["outing_id": outingId, "type": kind]
        if kind == "sos" || kind == "voice_note" { c.interruptionLevel = .timeSensitive } else if kind == "ptt" { c.interruptionLevel = .active; c.sound = nil } else { c.interruptionLevel = .passive; c.sound = nil }
        let r = UNNotificationRequest(identifier: "\(kind)-\(outingId)-\(UUID().uuidString)", content: c, trigger: nil)
        UNUserNotificationCenter.current().add(r)
    }
}

/// Memo for `OutingSession.displayTrail`. Composing the road-matched trail walks every point, and
/// the live screen reads it several times per render (map trails, trip progress). Arrays compare
/// by storage identity first, so an unchanged trail and cache make a hit O(1).
struct DisplayTrailMemo {
    private var points: [TrailPoint]?
    private var cache: TrailMatchCache?
    private var result: [TrailPoint] = []
    /// How many times `compose` actually ran (tests).
    private(set) var composeCount = 0

    mutating func value(points: [TrailPoint], cache: TrailMatchCache?,
                        compose: ([TrailPoint], TrailMatchCache?) -> [TrailPoint]) -> [TrailPoint] {
        if let last = self.points, last == points, self.cache == cache { return result }
        let r = compose(points, cache)
        composeCount += 1
        self.points = points
        self.cache = cache
        result = r
        return r
    }
}

// MARK: - solo («اتجه» on my own, docs/SOLO-OUTING.md)

/// A solo outing: one member (me), on this phone only. Its id is `solo-<uuid>`, which
/// `OutingsAPI` refuses before anything reaches the network.
enum SoloOuting {
    static let idPrefix = "solo-"

    static func newId() -> String { idPrefix + UUID().uuidString.lowercased() }

    static func isSoloId(_ id: String) -> Bool { id.hasPrefix(idPrefix) }

    /// The session's own picture (no server sends one): me alone, owner, active, not sharing,
    /// no positions, no invite. No phone number: it is never put in an outing picture here.
    static func view(id: String, me: PublicUser, name: String, now: Date = Date()) -> OutingView {
        let t = ISODate.string(now)
        let member = Member(user_id: me.id, display_name: me.display_name, avatar: me.avatar, phone: nil, role: "owner", sharing: false,
                            joined_at: t, online: true, last_seen_at: t)
        let snap = OutingSnapshot(
            outing: OutingInfo(id: id, name: name, status: .active, owner_id: me.id, created_at: t, started_at: t, ended_at: nil),
            me: SnapshotMe(user_id: me.id, role: "owner", sharing: false),
            members: [member], positions: [], invite: InviteState(active: false, expires_at: nil),
            server_now: t
        )
        return OutingView(snap, deviceNow: now)
    }
}

/// What a solo outing says (Najdi; the convoy word is «الأصدقاء», never «الربع»).
enum SoloCopy {
    /// The outing's name: «مشوار إلى روضة الثمامة».
    static func outingName(to place: String) -> String {
        let p = place.trimmingCharacters(in: .whitespacesAndNewlines)
        return p.isEmpty ? "مشوار" : "مشوار إلى \(p)"
    }
    /// The header, in place of the sharing state: nothing leaves the phone.
    static let localOnly = "على جوالك فقط"
    static let localOnlyLong = "على جوالك فقط · ما يوصل لأحد"
    /// «أنهِ الطلعة» in a solo outing.
    static let end = "أنهِ المشوار"
    static let endTitle = "تنهي المشوار؟"
    static let endMessage = "يوقف التوجيه والتسجيل ويطلع ملخص مشوارك. كل شي على جوالك فقط."
    /// The SOS in a solo outing: nobody to send it to, so the call is the help.
    static let sosTitle = "طوارئ"
    static let sosNote = "ما فيه أحد معك يوصله التنبيه. اتصل على ٩١١، أو اطلب إنجاد."
    static let call911 = "اتصل ٩١١"
    /// «طلعة الرجعة» from a solo outing comes in a later build.
    static let returnLater = "«مشوار الرجعة» جاي قريب. للحين استعمل «طريق الرجعة» من «المزيد» يرجّعك على مسارك."
}

extension OutingSession {
    /// «اتجه» without an outing (docs/SOLO-OUTING.md (ب)2): one member (me), no server, nothing
    /// sent. The demo's construction path with a one-member view and `kind: .solo`: no live
    /// channel, no background sender, no heartbeat, walkie-talkie never attached, nearby link off,
    /// and `SendGate` stays closed (no consent, no share press, server flag off).
    /// Nothing calls it yet (the «اتجه» entry point is a later step).
    static func solo(id: String = SoloOuting.newId(), me: PublicUser, name: String, location: LocationSharer, env: SessionEnv = SessionEnv()) -> OutingSession {
        assert(SoloOuting.isSoloId(id), "a solo outing id starts with \(SoloOuting.idPrefix)")
        var env = env
        env.nearbyMesh = false
        /* No token: the client is only here because the session holds one; it refuses `solo-` ids anyway. */
        return OutingSession(id: id, myUserId: me.id, api: OutingsAPI(tokenProvider: { nil }), token: "", location: location,
                             demo: SoloOuting.view(id: id, me: me, name: name), kind: .solo, env: env)
    }
}

/// Solo voice notes: nobody to send to, nobody answers. A 4xx error, so the outbox drops a note
/// instead of retrying (the talk button is not offered in a solo outing).
final class LocalVoiceNoteBackend: VoiceNoteBackend {
    func uploadVoiceNote(_ outingId: String, audio: Data, durationMs: Int, channel: String, clientId: String, ageMs: Int) async throws -> VoiceNote {
        throw OutingAPIError.localOuting
    }

    func listVoiceNotes(_ outingId: String, channel: String) async throws -> [VoiceNote] { [] }

    func fetchVoiceNote(_ note: VoiceNote) async throws -> Data { throw OutingAPIError(code: "clip_gone", status: 404) }
}

/// Solo chat: there is none. Answers like a route the server does not have (405), which
/// `ChatStore` reads as `.notDeployed`: the chat is hidden calmly and nothing is queued.
final class LocalChatBackend: ChatBackend {
    private var noChat: OutingAPIError { OutingAPIError(code: "local_outing", status: 405) }

    func chatOverview(_ outingId: String) async throws -> ChatOverview { throw noChat }
    func chatPage(_ outingId: String, with: ChatWith, before: Int?, after: Int?, limit: Int) async throws -> ChatPage { throw noChat }
    func chatSend(_ outingId: String, draft: ChatDraft) async throws -> ChatMessage { throw noChat }
    func chatRead(_ outingId: String, with: ChatWith, seq: Int) async throws { throw noChat }
    func chatDelete(_ outingId: String, messageId: String) async throws -> ChatMessage { throw noChat }
}
