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
    @Published private(set) var lastAck: (ok: Bool, reason: String?)?
    @Published var mode: ShareMode {
        didSet {
            env.defaults.set(mode.rawValue, forKey: Self.modeKey)
            location.setMode(mode)
        }
    }
    @Published var errorText: String?
    /// Bumped once a second so ages and freshness re-render.
    @Published private(set) var tick = 0
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

    let isDemo: Bool
    let location: LocationSharer
    /// Return-timer and «غرّزت» events for `SafetyController`.
    let safetyEvents = PassthroughSubject<SafetyEvent, Never>()
    /// The server side of the safety pack (nil in the demo: all local).
    var safetyBackend: SafetyBackend? { isDemo ? nil : api }
    /// Internal so the per-person invites model (Sources/Invites) shares this client.
    let api: OutingsAPI
    private let token: String
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
    /// Cars of the same outing nearby, phone to phone, when the internet is gone.
    let mesh: NearbyMesh
    /// «قناة الطلعة»: the live walkie-talkie (replaces the «اضغط وتكلم» clips).
    let walkie: OutingWalkieTalkie
    private var walkieSink: AnyCancellable?
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

    init(id: String, myUserId: String, api: OutingsAPI, token: String, location: LocationSharer, demo: OutingView? = nil, env: SessionEnv = SessionEnv()) {
        self.id = id
        self.myUserId = myUserId
        self.api = api
        self.token = token
        self.location = location
        self.env = env
        self.isDemo = demo != nil
        self.view = demo
        self.mode = ShareMode(rawValue: env.defaults.string(forKey: Self.modeKey) ?? "") ?? .balanced
        self.batterySharing = env.defaults.bool(forKey: Self.batteryKey)
        self.mesh = NearbyMesh(outingId: id, me: myUserId, members: Set(demo?.members.keys.map { $0 } ?? []), serverKey: demo?.snapshot.mesh_key)
        walkie = OutingWalkieTalkie(outingId: id, me: myUserId, tokenBackend: demo == nil ? api : nil, defaults: env.defaults)
        if let demo {
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
        if demo == nil || ProcessInfo.processInfo.arguments.contains("-SaryTrailMatch"), let svc = env.trailMatching {
            let m = TrailMatchCoordinator(outingId: id, dir: env.trailDirectory, service: svc)
            matcher = m
        }
        #if DEBUG
        if demo != nil, Self.forcedOffline { link = .offline }
        #endif
        mesh.myFix = { [weak self] in
            guard let self, self.gate.allowsPosition else { return nil }
            return self.location.lastFix
        }
        mesh.onEvents = { [weak self] evs in self?.nearbyEvents(evs) }
        meshSink = mesh.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        walkie.nameOf = { [weak self] uid in self?.view?.members[uid]?.display_name }
        walkie.outingName = { [weak self] in self?.view?.snapshot.outing.name ?? "" }
        walkieSink = walkie.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        chat.configure(.init(
            sendFrame: { [weak self] f in self?.channel?.sendChat(f) ?? false },
            isLive: { [weak self] in self?.channel?.isLive ?? false },
            myName: { [weak self] in self?.view?.me?.display_name }
        ))
        chat.snapshot(unread: demo?.snapshot.chat_unread)
        chatSink = chat.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
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
            alwaysAuthorized: hasAlwaysPermission
        )
    }

    var hasConsent: Bool { ShareMemory.hasConsent(user: myUserId, outing: id, defaults: env.defaults) }

    /// Sharing for real: the gate is open and the GPS is running for it.
    var isSharingNow: Bool { gate.allowsPosition && (location.isSharing || isDemo) }

    // MARK: lifecycle

    func open() {
        visible = env.isForeground()
        /* «المحادثات»: the conversation list and badges, then whatever waited in the outbox. */
        Task { await chat.refresh() }
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
                Task { @MainActor in
                    guard let self, self.visible else { return }
                    self.tick &+= 1
                    self.updateMesh()
                }
            }
            timers.append(t)
        }
        #if DEBUG
        if Self.meshTest, isDemo {
            ShareMemory.recordConsent(user: myUserId, outing: id, defaults: env.defaults)
            Task { await self.beginSharing() }
        }
        if Self.forcedOffline, !isDemo {
            link = .offline
            location.onFix = { [weak self] f in self?.handleFix(f) }
            return
        }
        #endif
        /* The demo has no server: the walkie-talkie still works phone to phone (two simulators, -SaryMeshTest). */
        guard !isDemo else {
            walkie.attach(channel: nil, mesh: mesh)
            return debugAutoTalk()
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
        backgroundSender = sender
        ch.handlers = .init(
            onSnapshot: { [weak self] s in MainActor.assumeIsolated { self?.applySnapshot(s) } },
            onEvent: { [weak self] e in MainActor.assumeIsolated { self?.apply(e) } },
            onState: { [weak self] s in MainActor.assumeIsolated { self?.linkChanged(s) } },
            onClosed: { [weak self] r in MainActor.assumeIsolated { self?.closed(r) } },
            onAck: { [weak self] ok, reason in MainActor.assumeIsolated { self?.ack(ok, reason) } },
            onServerNow: { [weak self] now in MainActor.assumeIsolated { self?.syncClock(now) } },
            onPTT: { [weak self] sig in MainActor.assumeIsolated { self?.walkie.receive(sig) } },
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

    func close() {
        backgroundSender?.stop()
        stopBackgroundTrail()
        location.stopTrail()
        saveTrail()
        /* The last stretch, matched once more now the outing is over (cached for the details page). */
        if env.timers, TrailMatchPrefs.enabled(env.defaults) { matcher?.tick(trail, force: true) }
        location.onTrailFix = { _ in }
        mesh.setRunning(false)
        stopSharingLocally()
        walkie.detach(leftOuting: closedReason != nil)
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
        visible = active
        location.setOffScreen(!active)
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
            if gate.allowsBackgroundPosition && (location.isSharing || isDemo) {
                /* «دائمًا»: keep sharing off screen, over HTTP. */
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
        channel?.heartbeat(gps: location.gpsState, battery: batterySharing ? Self.batteryNow() : nil)
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
        guard let v = view, v.status == .active else {
            errorText = "المشاركة تبدأ عندما يبدأ أمير الرحلة الطلعة."
            return
        }
        let st = await location.requestWhenInUse()
        guard st == .authorizedWhenInUse || st == .authorizedAlways else {
            errorText = "لم تسمح بالوصول إلى موقعك. فعّله من الإعدادات ← سَرى البارق ← الموقع."
            return
        }
        ShareMemory.recordConsent(user: myUserId, outing: id, defaults: env.defaults)
        pendingServerStop = false
        if !v.snapshot.me.sharing, !isDemo {
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

    /// Opened right after «انضم» / creating: the controller follows up with the «دائمًا» explainer
    /// once iOS answered the location prompt (or shows the Settings fix when refused).
    @Published var joinedJustNow = false

    /// You pressed stop: nothing more leaves the phone, the server deletes your fix.
    func stopSharing() async {
        /* Tell nearby cars too, so a relay never keeps showing where you were. */
        mesh.stop(farewell: .stop)
        stopSharingLocally()
        guard !isDemo else { return }
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

    /// Internal for tests (the «أوقف» path without the network).
    func stopSharingLocally() {
        wantsToShare = false
        lastSent = nil
        channel?.dropPendingFix()
        backgroundSender?.stop()
        if ShareMemory.activeShare(user: myUserId, defaults: env.defaults) == id {
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
        if !visible && hasAlwaysPermission && !isDemo && view == nil {
            if env.authorizationOverride ?? location.canLocate { location.startSharing(mode: mode) }
            let done = env.keepAlive()
            Task { [weak self, api, id] in
                defer { done() }
                if let snap = try? await api.poll(id) { self?.applySnapshot(snap) }
            }
        }
        reconcileSharing()
    }

    /// The network came back: a fix waiting off screen goes now (if still fresh).
    func networkBack() { backgroundSender?.networkBack() }

    private func backgroundResult(_ r: BackgroundPositionSender.Outcome) {
        #if DEBUG
        ShareLog.log.notice("background send: \(String(describing: r))")
        #endif
        switch r {
        case .sent: lastAck = (true, nil)
        case let .refused(reason): ack(false, reason)
        case .notAMember: closed(.notAMember)
        case .unauthorized: closed(.unauthorized)
        }
    }

    private func reconcileSharing() {
        /* Ended, left, removed, switch off: the screen-locked trail stops at once. */
        if recordingInBackground && !canRecordTrailInBackground { stopBackgroundTrail() }
        syncTrailGPS()
        guard let v = view else { return }
        /* Paused / ended / sharing switched off elsewhere: the intent ends too. */
        if wantsToShare && (v.status == .paused || v.status == .ended || !v.snapshot.me.sharing) {
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
        objectWillChange.send()
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
                Notifier.post(title: "طوارئ: \(name)", body: "يطلب المساعدة · عبر الأجهزة القريبة", outingId: id, kind: "sos")
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
        if mesh.running && mesh.nearbyCars > 0 { errorText = nil }
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
            guard ServerRules.check(Policy.wireFix(f, mode: m, nowMs: now)) == .ok, !isDemo else { return }
            backgroundSender?.offer(f, mode: m)
            return
        }
        guard Policy.shouldSend(f, last: lastSent, mode: m, nowMs: now) else { return }
        guard ServerRules.check(Policy.wireFix(f, mode: m, nowMs: now)) == .ok else { return }
        lastSent = .init(fix: f, sentAtMs: now)
        if isDemo { return }
        channel?.sendFix(f, mode: m)
    }

    // MARK: «مساري» — the on-device trail

    /// Recording is on (switch), the outing is active or paused, I am in it, and it is not closed.
    var trailRecordingAllowed: Bool {
        guard TrailPrefs.record(env.defaults), closedReason == nil, let v = view, v.me != nil else { return false }
        return v.status == .active || v.status == .paused
    }

    var hasAlwaysPermission: Bool { env.alwaysOverride ?? location.hasAlways }

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
    /// when «مساري» is recording, else the fix itself. Display only — never what is sent.
    func smoothedFix(_ f: DeviceFix?) -> DeviceFix? {
        guard var f, let k = trail.filter, k.started, abs(k.tMs - f.atMs) < 1500 else { return f }
        let p = k.position
        f.lat = p.lat
        f.lng = p.lng
        if f.speed == nil { f.speed = k.speedMps }
        return f
    }

    /// What the map draws and «طريق العودة» follows: road-matched where confident, smoothed elsewhere.
    var displayTrail: [TrailPoint] {
        TrailMatchPrefs.enabled(env.defaults) ? TrailDisplay.compose(trail.points, matcher?.cache) : trail.points
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
    #endif

    // MARK: inbound

    private func linkChanged(_ s: LiveChannel.State) {
        let was = link
        link = s
        if s == .live, was != .live { chat.linkLive() }
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
        view = OutingView.merge(view, s)
        chat.snapshot(unread: s.chat_unread)
        mesh.setServerKey(s.mesh_key, outingId: id)
        if let previous { notifyChanges(from: previous) }
        if s.outing.status == .ended { closed(.outingEnded) }
        reconcileSharing()
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
        view = v
        events.send(e)
        switch e {
        case let .memberNote(uid, note?) where uid != v.myId && before.members[uid]?.note != note:
            Notifier.post(title: v.members[uid]?.display_name ?? "ملاحظة جديدة", body: note.text, outingId: id, kind: "note")
        case let .sos(uid, sos?, refresh) where uid != v.myId && !refresh:
            Notifier.post(title: "طوارئ: \(v.members[uid]?.display_name ?? "")", body: sos.fix == nil ? "يطلب المساعدة (بدون موقع)" : "يطلب المساعدة الآن", outingId: id, kind: "sos")
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
        saveTrail()
        stopSharingLocally()
        if r == .outingEnded { view?.apply(.outingStatus(.ended)) }
        walkie.detach(leftOuting: true)
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

    @discardableResult
    func sendNote(_ text: String) async -> Bool {
        let clean = text.isEmpty ? "" : (ServerRules.cleanText(text, max: ServerRules.noteMax) ?? "")
        if isDemo {
            if let me = view?.myId { view?.apply(.memberNote(userId: me, note: clean.isEmpty ? nil : MemberNote(text: clean, at: ISODate.string(Date())))) }
            return true
        }
        mesh.announce(.note, text: clean)
        let ok = await run("note") {
            let n = try await api.note(id, text: clean)
            if let me = view?.myId { view?.apply(.memberNote(userId: me, note: n)) }
        }
        if !ok { deliveredNearby() }
        return ok || mesh.nearbyCars > 0
    }

    func setStatus(_ action: String) async {
        if isDemo {
            /* `-demo`: no server; the demo outing changes state on this phone only. */
            let st: OutingStatus = action == "end" ? .ended : action == "pause" ? .paused : .active
            view?.apply(.outingStatus(st))
            reconcileSharing()
            if st == .ended { closed(.outingEnded) }
            return
        }
        _ = await run("status") {
            let o = try await api.setStatus(id, action: action)
            view?.apply(.outingStatus(o.status))
            reconcileSharing()
            if o.status == .ended { closed(.outingEnded) }
        }
    }

    /// Leave the outing (also after it ended). True when the server agreed.
    @discardableResult
    func leave() async -> Bool {
        stopSharingLocally()
        if isDemo { closed(.left); return true }
        let ok = await run("leave") { try await api.leave(id) }
        if ok { closed(.left) }
        return ok
    }

    /// SOS after the 1 s hold. Carries my fix only when the send gate is open.
    func raiseSOS() async {
        guard let me = view?.myId else { return }
        sosSending = true
        defer { sosSending = false }
        var wire: WireFix?
        if gate.allowsSosFix, let f = location.lastFix {
            let w = Policy.wireFix(f, mode: .precise, nowMs: Date().timeIntervalSince1970 * 1000)
            if w.age_ms <= 25 * 60_000, (f.accuracy ?? 0) <= ServerRules.maxAccuracyM { wire = w }
        }
        mesh.announce(.sos, sosFix: wire == nil ? nil : location.lastFix)
        if isDemo {
            view?.apply(.sos(userId: me, sos: SosInfo(at: ISODate.string(Date()), fix: nil), refresh: false))
            return
        }
        let ok = await run("sos") {
            let s = try await api.raiseSos(id, fix: wire)
            view?.apply(.sos(userId: me, sos: s, refresh: false))
        }
        if !ok { deliveredNearby() }
    }

    func cancelSOS() async {
        guard let me = view?.myId else { return }
        mesh.announce(.sosClear)
        if isDemo { view?.apply(.sos(userId: me, sos: nil, refresh: false)); return }
        let ok = await run("sos") {
            try await api.cancelSos(id)
            view?.apply(.sos(userId: me, sos: nil, refresh: false))
        }
        if !ok { deliveredNearby() }
    }

    @discardableResult
    func setRally(lat: Double, lng: Double, label: String?) async -> Bool {
        if isDemo { view?.apply(.rally(RallyInfo(lat: lat, lng: lng, label: label, set_at: ISODate.string(Date()), set_by: myUserId))); return true }
        return await run("rally") {
            let r = try await api.setRally(id, lat: lat, lng: lng, label: label)
            view?.apply(.rally(r))
        }
    }

    func clearRally() async {
        if isDemo { view?.apply(.rally(nil)); return }
        _ = await run("rally") {
            try await api.clearRally(id)
            view?.apply(.rally(nil))
        }
    }

    func setCoLeader(_ member: String, on: Bool) async {
        _ = await run("member:\(member)") {
            if !isDemo { try await api.setCoLeader(id, member: member, on: on) }
            view?.apply(.memberRole(userId: member, coLeader: on))
        }
    }

    func removeMember(_ member: String) async {
        _ = await run("member:\(member)") {
            if !isDemo { try await api.removeMember(id, member: member) }
            view?.apply(.memberLeft(userId: member))
        }
    }

    /// The invite link this device created, if any. The server keeps only its hash.
    func storedInviteURL() -> URL? {
        InviteTokenStore.load(id).map(InviteLink.url(for:))
    }

    /// Owner only: a new link. This revokes every earlier link, so it is never automatic.
    func newInviteURL() async -> URL? {
        var out: URL?
        _ = await run("invite") {
            let inv = try await api.rotateInvite(id)
            InviteTokenStore.save(id, inv.token)
            out = InviteLink.url(for: inv.token)
        }
        return out
    }

    /// Push-to-talk upload. Returns the clip on success.
    func sendClip(_ audio: Data, durationMs: Int) async -> VoiceClip? {
        if isDemo { return nil }
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
        if kind == "sos" { c.interruptionLevel = .timeSensitive } else if kind == "ptt" { c.interruptionLevel = .active; c.sound = nil } else { c.interruptionLevel = .passive; c.sound = nil }
        let r = UNNotificationRequest(identifier: "\(kind)-\(outingId)-\(UUID().uuidString)", content: c, trigger: nil)
        UNUserNotificationCenter.current().add(r)
    }
}
