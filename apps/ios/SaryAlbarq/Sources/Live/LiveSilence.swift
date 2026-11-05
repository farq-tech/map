import Foundation

// «انقطع الإرسال» on the live screen: pure mapping (presenter) + the
// controller's wiring. The server decides who is silent (10 / 30 min without a
// fix while sharing is on); this file turns that into the red-amber card,
// the «انقطع منذ ١٠ د» badge and the quiet «رجع إرسال فهد» toast.

extension LiveOutingPresenter {
    /// Device time of their last fix reaching the server, while the server says they are silent.
    static func silentSince(_ uid: String, in v: OutingView) -> Date? {
        guard uid != v.myId, let s = v.silent[uid] else { return nil }
        return deviceDate(s.since, view: v)
    }

    /// The alert-lane card for one silent friend.
    static func silentAlert(_ uid: String, in v: OutingView, now: Date = Date()) -> SilentAlertUI? {
        guard uid != v.myId, let s = v.silent[uid], let m = v.members[uid] else { return nil }
        /* «اتجه» goes to the server's last fix, else the last one we hold — never a guess. */
        let lat = s.last?.lat ?? v.positions[uid]?.lat
        let lng = s.last?.lng ?? v.positions[uid]?.lng
        let lastAt = s.last.flatMap { deviceDate($0.at, view: v) } ?? v.positions[uid].flatMap { deviceDate($0.recorded_at, view: v) }
        return SilentAlertUI(
            participantId: uid, name: m.display_name, color: v.colors[uid] ?? 0xFFFFFF,
            since: deviceDate(s.since, view: v) ?? now, level: s.level,
            lastLat: lat, lastLng: lng, lastAt: lastAt,
            hasPhone: !(m.phone ?? "").isEmpty
        )
    }

    struct SilenceChange: Equatable {
        /// New silences, or a silence that escalated (10 → 30): (re)show the card.
        var raised: [String] = []
        /// Silences that ended. `withFix` = a newer fix arrived («رجع إرسال …»); otherwise
        /// they left, paused sharing, said they were going offline, or the outing stopped.
        var cleared: [(uid: String, withFix: Bool)] = []

        static func == (a: SilenceChange, b: SilenceChange) -> Bool {
            a.raised == b.raised && a.cleared.map(\.uid) == b.cleared.map(\.uid) && a.cleared.map(\.withFix) == b.cleared.map(\.withFix)
        }
    }

    static func silenceChanges(prev: OutingView, next: OutingView) -> SilenceChange {
        var c = SilenceChange()
        for (uid, s) in next.silent.sorted(by: { $0.key < $1.key }) where uid != next.myId {
            if prev.silent[uid]?.level != s.level { c.raised.append(uid) }
        }
        for (uid, old) in prev.silent.sorted(by: { $0.key < $1.key }) where next.silent[uid] == nil {
            var withFix = false
            if next.status == .active, next.members[uid]?.sharing == true, let p = next.positions[uid] {
                let lastAt = old.last.flatMap { ISODate.parse($0.at) } ?? ISODate.parse(old.since) ?? .distantPast
                withFix = (ISODate.parse(p.recorded_at) ?? .distantPast) > lastAt
            }
            c.cleared.append((uid, withFix))
        }
        return c
    }
}

extension LiveOutingController {
    static func silentAlertId(_ uid: String) -> String { "silent:\(uid)" }

    /// Called from `sessionChanged` with the view before and after.
    func reconcileSilence(prev: OutingView, next: OutingView) {
        let change = LiveOutingPresenter.silenceChanges(prev: prev, next: next)
        let rules = ConvoyAlertPrefs.shared.settings
        for uid in change.raised {
            /* «تنبيهات القافلة»: the disconnected rule can be off, or wait for the 30-minute level. */
            guard rules.silentOn, (next.silent[uid]?.level ?? 10) >= rules.silentMinutes else { continue }
            guard let a = LiveOutingPresenter.silentAlert(uid, in: next) else { continue }
            /* Stays up while they are silent; cleared below when they come back. */
            pushAlert(LiveAlertUI(id: Self.silentAlertId(uid), kind: .silent(a)), ttl: 2 * 3600)
        }
        for (uid, withFix) in change.cleared {
            dismissAlert(Self.silentAlertId(uid))
            if withFix, let name = next.members[uid]?.display_name { toast(SilenceText.resumed(name: name)) }
        }
    }

    /// Card tapped: show where they were last seen.
    func showSilent(_ uid: String) {
        show(member: uid)
    }

    /// «اتجه»: directions to their last known position.
    func goToSilent(_ uid: String) {
        guard let v = session.view, let a = LiveOutingPresenter.silentAlert(uid, in: v), let lat = a.lastLat, let lng = a.lastLng else {
            toast("لا يوجد موقع معروف")
            return
        }
        Directions.open(lat: lat, lng: lng, name: "آخر موقع \(a.name)")
    }
}

#if DEBUG
extension OutingSession {
    /// Screenshots: `-demoSilent` — «نورة» stopped sending 11 min ago (as the server would say).
    func seedDemoSilence(now: Date = Date()) {
        guard isDemo, let v = view, let nora = v.members.values.first(where: { $0.display_name == "نورة" }) else { return }
        let since = ISODate.string(now.addingTimeInterval(-11 * 60))
        let last = v.positions[nora.user_id].map { SilentInfo.LastFix(lat: $0.lat, lng: $0.lng, at: $0.recorded_at) }
        debugApply(.memberSilent(SilentInfo(user_id: nora.user_id, since: since, level: 10, last: last)))
    }
}
#endif
