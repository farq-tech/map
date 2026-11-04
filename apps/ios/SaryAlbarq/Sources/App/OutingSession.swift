import CoreLocation
import Foundation
import UIKit
import UserNotifications

/// What a session needs from the outside world, injectable for tests.
struct SessionEnv {
    var makeSocket: (URL) -> LiveSocket = { URLSessionLiveSocket(url: $0) }
    var scheduler: Scheduler = MainScheduler()
    /// True while the app is on screen. Nothing is sent when this is false.
    var isForeground: @MainActor () -> Bool = { UIApplication.shared.applicationState != .background }
    var defaults: UserDefaults = .standard
    /// Repeating timers (age ticks, link heartbeat). Off in unit tests.
    var timers = true
    /// Tests only: stands in for iOS location permission.
    var authorizationOverride: Bool?
    /// Tests only: stands in for «دائمًا» (screen-locked trail).
    var alwaysOverride: Bool?
    /// Where «مساري» is kept on this device (tests use a temporary folder).
    var trailDirectory: URL? = TrailStore.directory
}

/// One open outing: the live channel, the reducer's picture, and — only when
/// you said so and the app is on screen — your shared position.
///
/// Every position goes through `gate` (`SendGate`), which `LiveChannel` asks
/// again at the last step before the wire. The server's `sharing` flag alone
/// never sends anything: the server turns it on at join.
@MainActor
final class OutingSession: ObservableObject, Identifiable {
    nonisolated let id: String
    let myUserId: String
    @Published private(set) var view: OutingView?
    @Published private(set) var link: LiveChannel.State = .connecting
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
    private let api: OutingsAPI
    private let token: String
    private let env: SessionEnv
    private var channel: LiveChannel?
    private var lastSent: Policy.LastSent?
    private var timers: [Timer] = []
    private var visible = true
    /// The person pressed stop while offline: tell the server once we can.
    private var pendingServerStop = false
    private var trailSavedAt = Date.distantPast
    private var trailUnsaved = 0

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
        if demo != nil { link = .live }
        trail = TrailStore.load(id, in: env.trailDirectory) ?? Trail()
        /* Whatever happened since the last kept point (app closed, phone restarted) was not seen. */
        trail.markGap()
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
            closed: closedReason != nil
        )
    }

    var hasConsent: Bool { ShareMemory.hasConsent(user: myUserId, outing: id, defaults: env.defaults) }

    /// Sharing for real: the gate is open and the GPS is running for it.
    var isSharingNow: Bool { gate.allowsPosition && (location.isSharing || isDemo) }

    // MARK: lifecycle

    func open() {
        visible = env.isForeground()
        location.onTrailFix = { [weak self] f in self?.trailFix(f) }
        /* Your own dot, for distances and directions. Nothing is sent until you choose to share. */
        Task {
            _ = await location.requestWhenInUse()
            if self.visible { location.watchForeground() }
        }
        if env.timers {
            let t = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.visible else { return }
                    self.tick &+= 1
                }
            }
            timers.append(t)
        }
        guard !isDemo else { return }
        let ch = LiveChannel(outingId: id, token: token, deps: .init(
            makeSocket: env.makeSocket,
            poll: { [api] in try await api.poll($0) },
            post: { [api] in try await api.sendPosition($0, fix: $1) },
            beat: { [api] in try await api.heartbeat($0, gps: $1, battery: $2) },
            scheduler: env.scheduler,
            canSendPosition: { [weak self] in
                MainActor.assumeIsolated { self?.gate.allowsPosition ?? false }
            }
        ))
        ch.handlers = .init(
            onSnapshot: { [weak self] s in MainActor.assumeIsolated { self?.applySnapshot(s) } },
            onEvent: { [weak self] e in MainActor.assumeIsolated { self?.apply(e) } },
            onState: { [weak self] s in MainActor.assumeIsolated { self?.linkChanged(s) } },
            onClosed: { [weak self] r in MainActor.assumeIsolated { self?.closed(r) } },
            onAck: { [weak self] ok, reason in MainActor.assumeIsolated { self?.ack(ok, reason) } },
            onServerNow: { [weak self] now in MainActor.assumeIsolated { self?.syncClock(now) } }
        )
        channel = ch
        ch.start()
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

    func close() {
        stopBackgroundTrail()
        saveTrail()
        location.onTrailFix = { _ in }
        stopSharingLocally()
        channel?.stop()
        channel = nil
        timers.forEach { $0.invalidate() }
        timers = []
        location.stopWatchingForeground()
    }

    /// The app came to / left the screen. Leaving stops the GPS and drops any
    /// fix waiting for the network; the share intent stays, so it resumes on return.
    func foreground(_ active: Bool) {
        visible = active
        if active {
            location.watchForeground()
            stopBackgroundTrail()
            channel?.setAway(false)
            channel?.reconnectNow()
            reconcileSharing()
        } else {
            channel?.dropPendingFix()
            /* The trail keeps going with the screen locked only with «دائمًا» and the switch on;
             * otherwise the stretch until we are back is an honest gap. Sending stops either way. */
            if canRecordTrailInBackground {
                recordingInBackground = true
                location.startBackgroundTrail()
            } else {
                trail.markGap()
            }
            saveTrail()
            location.stopSharing()
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
            errorText = "المشاركة تبدأ عندما يبدأ صاحب الطلعة الطلعة."
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

    /// You pressed stop: nothing more leaves the phone, the server deletes your fix.
    func stopSharing() async {
        stopSharingLocally()
        guard !isDemo else { return }
        do {
            _ = try await api.setSharing(id, sharing: false)
            view?.apply(.memberSharing(userId: myUserId, sharing: false))
            pendingServerStop = false
        } catch {
            pendingServerStop = true
        }
    }

    private func stopSharingLocally() {
        wantsToShare = false
        lastSent = nil
        channel?.dropPendingFix()
        if ShareMemory.activeShare(user: myUserId, defaults: env.defaults) == id {
            ShareMemory.setActiveShare(user: myUserId, outing: nil, defaults: env.defaults)
        }
        location.stopSharing()
    }

    /// Resume after a relaunch only if THIS identity was sharing THIS outing with consent.
    func resumeIfPreviouslySharing() {
        if ShareMemory.activeShare(user: myUserId, defaults: env.defaults) == id, hasConsent {
            wantsToShare = true
            reconcileSharing()
        }
    }

    private func reconcileSharing() {
        /* Ended, left, removed, switch off: the screen-locked trail stops at once. */
        if recordingInBackground && !canRecordTrailInBackground { stopBackgroundTrail() }
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
        objectWillChange.send()
    }

    /// Every fix from the GPS while sharing. Internal for tests.
    func handleFix(_ f: DeviceFix) {
        guard gate.allowsPosition, location.isSharing || isDemo else { return }
        /* My own totals for «ملخص رحلتي»: on this device only, never points. */
        if !isDemo { TripLogStore.update(id, defaults: env.defaults) { $0.add(lat: f.lat, lng: f.lng, accuracy: f.accuracy, speed: f.speed, atMs: f.atMs) } }
        let now = Date().timeIntervalSince1970 * 1000
        let m = location.effectiveMode
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

    /// The screen-locked trail may run: «دائمًا», both switches on, and an outing I am recording.
    var canRecordTrailInBackground: Bool {
        TrailPrefs.background(env.defaults) && hasAlwaysPermission && trailRecordingAllowed
    }

    /// Every GPS fix, foreground or (with «دائمًا») background. It goes into the trail on this
    /// phone and nowhere else: this path never reaches `handleFix`, `LiveChannel` or the API.
    func trailFix(_ f: DeviceFix) {
        guard trailRecordingAllowed else { return }
        guard visible || recordingInBackground else { return }
        guard trail.add(f) else { return }
        trailUnsaved += 1
        if trailUnsaved >= 5 || Date().timeIntervalSince(trailSavedAt) > 5 { saveTrail() }
    }

    func saveTrail() {
        guard trailUnsaved > 0 || trail.isEmpty == false else { return }
        TrailStore.save(trail, outingId: id, in: env.trailDirectory)
        trailSavedAt = Date()
        trailUnsaved = 0
    }

    /// «امسح مساري لهذه الطلعة».
    func clearTrail() {
        trail = Trail()
        TrailStore.delete(id, in: env.trailDirectory)
        trailUnsaved = 0
    }

    /// «سجّل مساري» switch.
    func setTrailRecording(_ on: Bool) {
        env.defaults.set(on, forKey: TrailPrefs.recordKey)
        /* Off and on again: what happened in between was not recorded. */
        trail.markGap()
        if !on { stopBackgroundTrail(); saveTrail() }
        objectWillChange.send()
    }

    /// «سجّل مساري والشاشة مقفلة» switch (asking iOS for «دائمًا» is the caller's, after the explainer).
    func setBackgroundTrail(_ on: Bool) {
        env.defaults.set(on, forKey: TrailPrefs.backgroundKey)
        if !on { stopBackgroundTrail() }
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
        link = s
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
        switch e {
        case let .memberNote(uid, note?) where uid != v.myId && before.members[uid]?.note != note:
            Notifier.post(title: v.members[uid]?.display_name ?? "ملاحظة جديدة", body: note.text, outingId: id, kind: "note")
        case let .sos(uid, sos?, refresh) where uid != v.myId && !refresh:
            Notifier.post(title: "طوارئ: \(v.members[uid]?.display_name ?? "")", body: sos.fix == nil ? "يطلب المساعدة (بدون موقع)" : "يطلب المساعدة الآن", outingId: id, kind: "sos")
        case let .memberLeft(uid) where uid == v.myId:
            closed(.left)
        case .outingStatus, .memberSharing:
            reconcileSharing()
        default:
            break
        }
    }

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
        if !ok, reason == "sharing_off" || reason == "outing_paused" || reason == "outing_ended" {
            if reason == "outing_paused" { view?.apply(.outingStatus(.paused)) }
            if reason == "sharing_off", let me = view?.myId { view?.apply(.memberSharing(userId: me, sharing: false)) }
            reconcileSharing()
        }
    }

    private func syncClock(_ serverNow: String) {
        guard let d = ISODate.parse(serverNow) else { return }
        view?.clockOffsetMs = (d.timeIntervalSince1970 - Date().timeIntervalSince1970) * 1000
    }

    private func closed(_ r: LiveCloseReason) {
        guard closedReason == nil else { return }
        closedReason = r
        stopBackgroundTrail()
        saveTrail()
        stopSharingLocally()
        if r == .outingEnded { view?.apply(.outingStatus(.ended)) }
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
        return await run("note") {
            let n = try await api.note(id, text: clean)
            if let me = view?.myId { view?.apply(.memberNote(userId: me, note: n)) }
        }
    }

    func setStatus(_ action: String) async {
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
        if isDemo {
            view?.apply(.sos(userId: me, sos: SosInfo(at: ISODate.string(Date()), fix: nil), refresh: false))
            return
        }
        _ = await run("sos") {
            let s = try await api.raiseSos(id, fix: wire)
            view?.apply(.sos(userId: me, sos: s, refresh: false))
        }
    }

    func cancelSOS() async {
        guard let me = view?.myId else { return }
        if isDemo { view?.apply(.sos(userId: me, sos: nil, refresh: false)); return }
        _ = await run("sos") {
            try await api.cancelSos(id)
            view?.apply(.sos(userId: me, sos: nil, refresh: false))
        }
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
        if kind == "sos" { c.interruptionLevel = .timeSensitive } else { c.interruptionLevel = .passive; c.sound = nil }
        let r = UNNotificationRequest(identifier: "\(kind)-\(outingId)-\(UUID().uuidString)", content: c, trigger: nil)
        UNUserNotificationCenter.current().add(r)
    }
}
