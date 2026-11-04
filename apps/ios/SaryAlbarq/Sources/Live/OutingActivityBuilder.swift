import Foundation

/// A member who reported «غرّزت» (feature 2). Fed by the session once the
/// stuck state reaches the client; the activity already ranks it.
struct StuckMark: Equatable {
    var userId: String
    var at: Date
}

/// Turns the live screen's real data into the Live Activity's picture.
/// Pure: the same presenter rules as the map (an old fix is never live).
enum OutingActivityBuilder {
    /// My own fix still places me for distances up to this age. Looser than the map's 30 s
    /// «live» because with the screen locked the trail GPS only reports every 15 m: a parked
    /// car gets no new fix, and that is not a lost GPS.
    static let myFixMaxAgeS: TimeInterval = 120

    /// - Parameters:
    ///   - backMeters: along my trail to its start (back-track), when it exists.
    ///   - stuck: members who reported «غرّزت», newest first or in any order.
    static func state(_ i: LivePresenterInput, backMeters: Double?, stuck: [StuckMark] = []) -> OutingActivityState? {
        guard let v = i.view else { return nil }
        let parts = LiveOutingPresenter.participants(i)
        let live = parts.filter { $0.presence == .live }

        /* My own fix decides every distance: without a fresh one, none is shown. */
        var gpsOK = false
        if let f = i.myFix, i.gpsState != .denied, i.gpsState != .unavailable {
            gpsOK = i.now.timeIntervalSince1970 - f.atMs / 1000 <= myFixMaxAgeS
        }
        var farthest: ParticipantUI?
        if gpsOK {
            farthest = live.filter { !$0.isMe && $0.distanceMeters != nil }.max { ($0.distanceMeters ?? 0) < ($1.distanceMeters ?? 0) }
        }

        let online = i.closed == nil && (i.link == .live || i.link == .polling)
        return OutingActivityState(
            liveCount: live.count,
            memberCount: v.members.count,
            farthestName: farthest?.name,
            farthestMeters: farthest?.distanceMeters,
            backMeters: gpsOK ? backMeters.map { max(0, $0) } : nil,
            alert: alert(i, view: v, stuck: stuck),
            gpsOK: gpsOK,
            online: online,
            updatedAt: i.now
        )
    }

    /// SOS before «غرّزت»; a friend's before my own; newest first within each.
    static func alert(_ i: LivePresenterInput, view v: OutingView, stuck: [StuckMark]) -> OutingActivityState.Alert? {
        var all: [OutingActivityState.Alert] = []
        let sos = LiveOutingPresenter.sos(i)
        for s in sos.incoming.sorted(by: { $0.since > $1.since }) {
            all.append(.init(kind: .sos, name: s.name, isMe: false, since: s.since))
        }
        if case let .active(since) = sos.mine { all.append(.init(kind: .sos, name: "", isMe: true, since: since)) }
        let theirs = stuck.filter { $0.userId != v.myId && v.members[$0.userId] != nil }.sorted { $0.at > $1.at }
        for s in theirs { all.append(.init(kind: .stuck, name: v.members[s.userId]?.display_name ?? "", isMe: false, since: s.at)) }
        if let mine = stuck.first(where: { $0.userId == v.myId }) { all.append(.init(kind: .stuck, name: "", isMe: true, since: mine.at)) }
        guard var top = all.first else { return nil }
        top.more = all.count - 1
        return top
    }
}

/// When a new picture is worth sending to the activity: at once for anything
/// that changes what a person should do (an alert, GPS, the link, who is live),
/// otherwise at most every 15 s and only for a meaningful distance change, plus
/// a refresh every minute so a still-true picture is not shown as old.
enum OutingActivityThrottle {
    static let minInterval: TimeInterval = 15
    static let refreshInterval: TimeInterval = 60
    /// Distances move the picture only by this much (or 5 %).
    static let minDistanceChangeM = 50.0

    static func shouldPush(_ new: OutingActivityState, last: OutingActivityState?, lastAt: Date?, now: Date) -> Bool {
        guard let last, let lastAt else { return true }
        if isUrgent(new, last) { return true }
        let since = now.timeIntervalSince(lastAt)
        guard since >= minInterval else { return false }
        if new.farthestName != last.farthestName { return true }
        if moved(new.farthestMeters, last.farthestMeters) || moved(new.backMeters, last.backMeters) { return true }
        return since >= refreshInterval
    }

    static func isUrgent(_ a: OutingActivityState, _ b: OutingActivityState) -> Bool {
        a.alert != b.alert || a.gpsOK != b.gpsOK || a.online != b.online || a.liveCount != b.liveCount || a.memberCount != b.memberCount
    }

    static func moved(_ a: Double?, _ b: Double?) -> Bool {
        switch (a, b) {
        case (nil, nil): return false
        case let (x?, y?): return abs(x - y) >= max(minDistanceChangeM, 0.05 * max(x, y))
        default: return true
        }
    }
}
