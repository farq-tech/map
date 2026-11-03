import CoreLocation
import Foundation
import UIKit
import UserNotifications

/// One open outing: the live channel, the reducer's picture, and — only when
/// you said so — your shared position.
///
/// Sharing runs only while ALL hold: you gave consent for this outing, you
/// pressed share, the outing is `active`, and the server says your sharing is
/// on. The moment one goes false (pause, end, leave, removed, sign-out,
/// permission revoked) location stops and background updates are switched off.
@MainActor
final class OutingSession: ObservableObject, Identifiable {
    nonisolated let id: String
    @Published private(set) var view: OutingView?
    @Published private(set) var link: LiveChannel.State = .connecting
    @Published private(set) var closedReason: LiveCloseReason?
    @Published private(set) var wantsToShare = false
    @Published private(set) var lastAck: (ok: Bool, reason: String?)?
    @Published var mode: ShareMode {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey)
            location.setMode(mode)
        }
    }
    @Published var errorText: String?
    /// Bumped once a second so ages and freshness re-render.
    @Published private(set) var tick = 0

    let isDemo: Bool
    let location: LocationSharer
    private let api: OutingsAPI
    private let token: String
    private var channel: LiveChannel?
    private var lastSent: Policy.LastSent?
    private var timers: [Timer] = []
    /// No need to re-render ages while the screen is off.
    private var visible = true

    static let modeKey = "sary.outings.mode.v1"
    static let activeShareKey = "sary.outings.activeShare.v1"
    static let consentKey = "sary.outings.consent.v1"

    init(id: String, api: OutingsAPI, token: String, location: LocationSharer, demo: OutingView? = nil) {
        self.id = id
        self.api = api
        self.token = token
        self.location = location
        self.isDemo = demo != nil
        self.view = demo
        self.mode = ShareMode(rawValue: UserDefaults.standard.string(forKey: Self.modeKey) ?? "") ?? .balanced
        if demo != nil { link = .live }
    }

    // MARK: lifecycle

    func open() {
        /* Your own dot, for distances and directions. Nothing is sent until you choose to share. */
        Task {
            _ = await location.requestWhenInUse()
            location.watchForeground()
        }
        let t = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.visible else { return }
                self.tick &+= 1
            }
        }
        timers.append(t)
        guard !isDemo else { return }
        let ch = LiveChannel(outingId: id, token: token, deps: .init(
            makeSocket: { URLSessionLiveSocket(url: $0) },
            poll: { [api] in try await api.poll($0) },
            post: { [api] in try await api.sendPosition($0, fix: $1) },
            beat: { [api] in try await api.heartbeat($0, gps: $1) },
            scheduler: MainScheduler()
        ))
        ch.handlers = .init(
            onSnapshot: { [weak self] s in self?.applySnapshot(s) },
            onEvent: { [weak self] e in self?.apply(e) },
            onState: { [weak self] s in self?.link = s },
            onClosed: { [weak self] r in self?.closed(r) },
            onAck: { [weak self] ok, reason in self?.ack(ok, reason) },
            onServerNow: { [weak self] now in self?.syncClock(now) }
        )
        channel = ch
        ch.start()
        /* Connection heartbeat, no coordinates: lets others tell "no GPS" from "no network". */
        let hb = Timer.scheduledTimer(withTimeInterval: Policy.linkHeartbeatMs / 1000, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.channel?.heartbeat(gps: self.location.gpsState)
            }
        }
        timers.append(hb)
        location.onFix = { [weak self] f in self?.onFix(f) }
    }

    func close() {
        stopSharingLocally()
        channel?.stop()
        channel = nil
        timers.forEach { $0.invalidate() }
        timers = []
        location.stopWatchingForeground()
    }

    func foreground(_ active: Bool) {
        visible = active
        channel?.setAway(!active)
        if active { channel?.reconnectNow() }
    }

    // MARK: sharing

    static func hasConsent(for outingId: String) -> Bool {
        (UserDefaults.standard.stringArray(forKey: consentKey) ?? []).contains(outingId)
    }

    static func recordConsent(for outingId: String) {
        var all = UserDefaults.standard.stringArray(forKey: consentKey) ?? []
        if !all.contains(outingId) { all.append(outingId) }
        UserDefaults.standard.set(all, forKey: consentKey)
    }

    /// Call after the consent sheet was accepted.
    func beginSharing() async {
        guard let v = view, v.status == .active else {
            errorText = "المشاركة تبدأ عندما يبدأ صاحب الطلعة الطلعة."
            return
        }
        Self.recordConsent(for: id)
        let st = await location.requestWhenInUse()
        guard st == .authorizedWhenInUse || st == .authorizedAlways else {
            errorText = "لم تسمح بالوصول إلى موقعك. فعّله من الإعدادات ← سَرى البارق ← الموقع."
            return
        }
        if !v.snapshot.me.sharing, !isDemo {
            do { _ = try await api.setSharing(id, sharing: true) } catch let e as OutingAPIError {
                errorText = e.arabic
                return
            } catch {}
            view?.apply(.memberSharing(userId: v.myId, sharing: true))
        }
        wantsToShare = true
        UserDefaults.standard.set(id, forKey: Self.activeShareKey)
        reconcileSharing()
        /* Ask for Always only after they have seen sharing work, with our explanation shown first. */
        location.requestAlways()
    }

    /// You pressed stop: tell the server (it deletes your fix) and switch the GPS off.
    func stopSharing() async {
        stopSharingLocally()
        guard !isDemo else { return }
        _ = try? await api.setSharing(id, sharing: false)
    }

    private func stopSharingLocally() {
        wantsToShare = false
        lastSent = nil
        if UserDefaults.standard.string(forKey: Self.activeShareKey) == id {
            UserDefaults.standard.removeObject(forKey: Self.activeShareKey)
        }
        location.stopSharing()
    }

    /// Resume after a relaunch only if this outing was the one being shared and consent was given.
    func resumeIfPreviouslySharing() {
        if UserDefaults.standard.string(forKey: Self.activeShareKey) == id, Self.hasConsent(for: id) {
            wantsToShare = true
            reconcileSharing()
        }
    }

    var isSharingNow: Bool { location.isSharing && wantsToShare }

    private func reconcileSharing() {
        guard let v = view else { return }
        let allowed = wantsToShare && v.status == .active && v.snapshot.me.sharing && location.canLocate && closedReason == nil
        if allowed && !location.isSharing {
            location.startSharing(mode: mode)
            if let f = location.lastFix { onFix(f) }
        } else if !allowed && location.isSharing {
            location.stopSharing()
        }
        /* Paused / ended / sharing switched off elsewhere: the intent ends too. */
        if wantsToShare && (v.status == .paused || v.status == .ended || !v.snapshot.me.sharing) {
            stopSharingLocally()
        }
        objectWillChange.send()
    }

    private func onFix(_ f: DeviceFix) {
        guard isSharingNow else { return }
        let now = Date().timeIntervalSince1970 * 1000
        let m = location.effectiveMode
        guard Policy.shouldSend(f, last: lastSent, mode: m, nowMs: now) else { return }
        guard ServerRules.check(Policy.wireFix(f, mode: m, nowMs: now)) == .ok else { return }
        lastSent = .init(fix: f, sentAtMs: now)
        if isDemo { return }
        channel?.sendFix(f, mode: m)
    }

    // MARK: inbound

    private func applySnapshot(_ s: OutingSnapshot) {
        let previous = view
        view = OutingView.merge(view, s)
        if let previous { notifyNewNotes(from: previous) }
        if s.outing.status == .ended { closed(.outingEnded) }
        reconcileSharing()
    }

    private func apply(_ e: LiveEvent) {
        guard var v = view else { return }
        let before = v
        v.apply(e)
        view = v
        if case let .memberNote(uid, note?) = e, uid != v.myId, before.members[uid]?.note != note {
            Notifier.note(from: v.members[uid]?.display_name ?? "", text: note.text, outingId: id)
        }
        if case let .memberLeft(uid) = e, uid == v.myId { closed(.left) }
        switch e {
        case .outingStatus, .memberSharing: reconcileSharing()
        default: break
        }
    }

    private func notifyNewNotes(from prev: OutingView) {
        guard let v = view else { return }
        for (uid, m) in v.members where uid != v.myId {
            if let n = m.note, prev.members[uid]?.note != n {
                Notifier.note(from: m.display_name, text: n.text, outingId: id)
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
        stopSharingLocally()
        if r == .outingEnded { view?.apply(.outingStatus(.ended)) }
        channel?.stop()
    }

    // MARK: actions

    func sendNote(_ text: String) async {
        let clean = text.isEmpty ? "" : (ServerRules.cleanText(text, max: ServerRules.noteMax) ?? "")
        if isDemo {
            if let me = view?.myId { view?.apply(.memberNote(userId: me, note: clean.isEmpty ? nil : MemberNote(text: clean, at: ISODate.string(Date())))) }
            return
        }
        do {
            let n = try await api.note(id, text: clean)
            if let me = view?.myId { view?.apply(.memberNote(userId: me, note: n)) }
        } catch let e as OutingAPIError { errorText = e.arabic } catch {}
    }

    func setStatus(_ action: String) async {
        do {
            let o = try await api.setStatus(id, action: action)
            view?.apply(.outingStatus(o.status))
            reconcileSharing()
            if o.status == .ended { closed(.outingEnded) }
        } catch let e as OutingAPIError { errorText = e.arabic } catch {}
    }

    func leave() async {
        stopSharingLocally()
        do { try await api.leave(id) } catch let e as OutingAPIError { errorText = e.arabic; return } catch {}
        closed(.left)
    }

    /// The invite link this device created, if any. The server keeps only its hash.
    func storedInviteURL() -> URL? {
        InviteTokenStore.load(id).map(InviteLink.url(for:))
    }

    /// Owner only: a new link. This revokes every earlier link, so it is never automatic.
    func newInviteURL() async -> URL? {
        do {
            let inv = try await api.rotateInvite(id)
            InviteTokenStore.save(id, inv.token)
            return InviteLink.url(for: inv.token)
        } catch let e as OutingAPIError { errorText = e.arabic } catch {}
        return nil
    }
}

/// Local notifications for notes over cars.
enum Notifier {
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func note(from name: String, text: String, outingId: String) {
        let c = UNMutableNotificationContent()
        c.title = name.isEmpty ? "ملاحظة جديدة" : name
        c.body = text
        c.sound = .default
        c.threadIdentifier = "outing-\(outingId)"
        let r = UNNotificationRequest(identifier: "note-\(outingId)-\(UUID().uuidString)", content: c, trigger: nil)
        UNUserNotificationCenter.current().add(r)
    }
}
