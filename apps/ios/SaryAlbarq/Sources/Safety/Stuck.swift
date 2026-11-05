import Foundation

// «غرّزت»: one tap (after a confirm) tells the group your car is stuck. Friends
// get a card with how far and which way, and answer «جاي» / «معي حبل» / «ما أقدر»;
// you see who is coming. «طلعت» clears it. The server keeps it in memory (like SOS)
// and drops it after 3 h. Pure state here, unit-tested.

/// One stuck member as this phone knows it.
struct StuckReport: Equatable {
    var userId: String
    var at: Date
    var note: String?
    /// The latest answer from each friend (a friend can change their mind).
    var replies: [String: StuckReplyKind] = [:]
}

enum StuckLogic {
    /// Same as the server: a report older than this is gone.
    static let ttl: TimeInterval = 3 * 3600
    static let noteMax = 80

    static func expired(_ r: StuckReport, now: Date) -> Bool { now.timeIntervalSince(r.at) > ttl }

    /// The whole picture from `GET /:id/live` (`stuck` is nil when the server does not send it yet).
    static func fromSnapshot(_ wire: [StuckWire], clockOffsetMs: Double, now: Date) -> [String: StuckReport] {
        var out: [String: StuckReport] = [:]
        for w in wire {
            let at = (ISODate.parse(w.at) ?? now).addingTimeInterval(-clockOffsetMs / 1000)
            var r = StuckReport(userId: w.user_id, at: at, note: w.note.flatMap { $0.isEmpty ? nil : $0 })
            for rep in w.replies ?? [] where rep.user_id != w.user_id { r.replies[rep.user_id] = rep.kind }
            if !expired(r, now: now) { out[w.user_id] = r }
        }
        return out
    }

    /// Apply one live event. `stuck` again from the same person is a fresh report: old replies go.
    static func apply(_ e: SafetyEvent, to reports: inout [String: StuckReport], clockOffsetMs: Double, now: Date) {
        switch e {
        case let .stuck(uid, at, note):
            let d = (ISODate.parse(at) ?? now).addingTimeInterval(-clockOffsetMs / 1000)
            reports[uid] = StuckReport(userId: uid, at: d, note: note)
        case let .stuckReply(from, to, kind):
            guard from != to, reports[to] != nil else { return }
            reports[to]?.replies[from] = kind
        case let .stuckClear(uid):
            reports[uid] = nil
        case .returnTimer:
            break
        }
    }

    /// A member who left can no longer be stuck nor answer.
    static func prune(_ reports: inout [String: StuckReport], members: Set<String>, now: Date) {
        for (uid, r) in reports {
            if !members.contains(uid) || expired(r, now: now) { reports[uid] = nil; continue }
            reports[uid]?.replies = r.replies.filter { members.contains($0.key) }
        }
    }

    // MARK: what the stuck person sees

    struct ReplyLine: Equatable, Identifiable {
        var userId: String
        var name: String
        var color: UInt32
        var kind: StuckReplyKind
        var id: String { userId }
    }

    /// Replies, helpful first («جاي» → «معه حبل» → «ما يقدر»), then by name.
    static func replyLines(_ r: StuckReport, name: (String) -> String?, color: (String) -> UInt32) -> [ReplyLine] {
        r.replies.compactMap { uid, k in name(uid).map { ReplyLine(userId: uid, name: $0, color: color(uid), kind: k) } }
            .sorted { a, b in a.kind.rank != b.kind.rank ? a.kind.rank < b.kind.rank : a.name < b.name }
    }

    /// «٢ جايين · ١ معه حبل · ١ ما يقدر», or «ما رد أحد بعد».
    static func summary(_ r: StuckReport) -> String {
        var c: [StuckReplyKind: Int] = [:]
        for k in r.replies.values { c[k, default: 0] += 1 }
        var parts: [String] = []
        if let n = c[.coming] { parts.append(n == 1 ? "١ جاي" : "\(SaryFormat.number(n)) جايين") }
        if let n = c[.have_rope] { parts.append(n == 1 ? "١ معه حبل" : "\(SaryFormat.number(n)) معهم حبل") }
        if let n = c[.cant] { parts.append(n == 1 ? "١ ما يقدر" : "\(SaryFormat.number(n)) ما يقدرون") }
        return parts.isEmpty ? "ما رد أحد بعد" : parts.joined(separator: " · ")
    }

    /// Someone is on their way (or has a rope): the stuck person can relax a little.
    static func helpComing(_ r: StuckReport) -> Bool { r.replies.values.contains { $0 != .cant } }

    static func cleanNote(_ s: String) -> String? { ServerRules.cleanText(s, max: noteMax) }
}

/// A friend's «غرّز» card in the alert lane.
struct StuckAlertUI: Equatable {
    var userId: String
    var name: String
    var color: UInt32
    var note: String?
    /// From my live fix to their last real fix — nil when either is unknown (never a guess).
    var distanceMeters: Double?
    /// Degrees clockwise from the top of the screen.
    var bearingDegrees: Double?
    /// Their position on my map is old (not live): the card says so.
    var positionStale: Bool
    var since: Date
    /// My own answer, highlighted.
    var myReply: StuckReplyKind?
    /// The others' answers, short («١ جاي»).
    var others: String?
}

/// The safety cards in the alert lane.
enum SafetyAlertUI: Equatable {
    case friendStuck(StuckAlertUI)
    /// «باقي ساعة على المغرب وطريق العودة ٤٥ دقيقة».
    case sunset(title: String, detail: String)
    /// My return timer is overdue: «مدّد / وصلت».
    case myTimerOverdue(contact: String, due: Date)
    /// A friend's return timer went overdue (they get the «وصلت / مدّد» prompt, not me).
    case friendTimerOverdue(name: String, color: UInt32)
}
