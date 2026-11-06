import Foundation

/// «انقطع الإرسال» — a friend with sharing on whose fixes stopped reaching the
/// server for 10 minutes (and again at 30). The server decides; the app shows
/// it and never draws that friend as live (`apps/api/lib/outings/silence.js`).
///
///   ← { type: 'member_silent', user_id, since, last: { lat, lng, at } | null, level: 10 | 30 }
///   ← { type: 'member_resumed', user_id, reason? }   (no reason = a fresh fix arrived)
///   snapshot: silent: [{ user_id, since, level, last }]
struct SilentInfo: Codable, Equatable {
    struct LastFix: Codable, Equatable {
        var lat: Double
        var lng: Double
        /// When that fix was taken (server clock).
        var at: String
    }

    var user_id: String
    /// When the last fix reached the server (server clock).
    var since: String
    /// 10 or 30 (minutes).
    var level: Int
    var last: LastFix?
}

extension LiveEvent {
    /// The two silence frames; nil for anything else.
    static func decodeSilence(_ type: String, _ obj: [String: Any]) -> LiveEvent? {
        guard let uid = obj["user_id"] as? String, !uid.isEmpty else { return nil }
        switch type {
        case "member_silent":
            guard let since = obj["since"] as? String else { return nil }
            let level = (obj["level"] as? NSNumber)?.intValue ?? 10
            var last: SilentInfo.LastFix?
            if let l = obj["last"] as? [String: Any], let lat = (l["lat"] as? NSNumber)?.doubleValue,
               let lng = (l["lng"] as? NSNumber)?.doubleValue, let at = l["at"] as? String {
                last = SilentInfo.LastFix(lat: lat, lng: lng, at: at)
            }
            return .memberSilent(SilentInfo(user_id: uid, since: since, level: level >= 30 ? 30 : 10, last: last))
        case "member_resumed":
            return .memberResumed(userId: uid, reason: obj["reason"] as? String)
        default:
            return nil
        }
    }
}

extension OutingView {
    /// Keeps `silent` honest for every event: set by `member_silent`, cleared by
    /// `member_resumed`, a fix newer than the silent one, leaving, sharing off,
    /// or the outing no longer active.
    mutating func applySilence(_ e: LiveEvent) {
        switch e {
        case let .memberSilent(info):
            let uid = info.user_id
            guard uid != myId, status == .active, members[uid]?.sharing == true else { return }
            /* A fix newer than the one the server called "last" already arrived here: not silent. */
            if let p = positions[uid], let last = info.last,
               (ISODate.parse(p.recorded_at) ?? .distantPast) > (ISODate.parse(last.at) ?? .distantPast) { return }
            silent[uid] = info
        case let .memberResumed(uid, _):
            silent[uid] = nil
        case let .position(p):
            guard let s = silent[p.user_id] else { return }
            let lastAt = s.last.flatMap { ISODate.parse($0.at) } ?? ISODate.parse(s.since) ?? .distantPast
            if (ISODate.parse(p.recorded_at) ?? .distantPast) > lastAt { silent[p.user_id] = nil }
        case let .memberLeft(uid):
            silent[uid] = nil
        case let .memberSharing(uid, sharing):
            if !sharing { silent[uid] = nil }
        case let .outingStatus(st):
            if st != .active { silent = [:] }
        default:
            break
        }
    }

    func isSilent(_ uid: String) -> Bool { silent[uid] != nil }
}

/// The Arabic lines, in one place (Arabic-Indic digits).
enum SilenceText {
    /// Whole minutes, rounded: the map chip ticks on a 30 s clock, the card on the live one — both read the same.
    static func minutes(since: Date, now: Date) -> Int { max(1, Int((now.timeIntervalSince(since) / 60).rounded())) }

    /// «انقطع منذ ١٠ د» — the badge on the chip / row.
    static func badge(since: Date, now: Date) -> String {
        let m = minutes(since: since, now: now)
        if m >= 60 { return "انقطع منذ \(ArabicFormat.number(Double(m / 60))) س" }
        return "انقطع منذ \(ArabicFormat.number(Double(m))) د"
    }

    /// «انقطع إرسال فهد منذ ١٠ د»
    static func title(name: String, since: Date, now: Date) -> String {
        let m = minutes(since: since, now: now)
        let span = m >= 60 ? "\(ArabicFormat.number(Double(m / 60))) س" : "\(ArabicFormat.number(Double(m))) د"
        return "انقطع إرسال \(name) منذ \(span)"
    }

    /// «آخر موقع قبل ١٠ د» / «لا يوجد موقع معروف»
    static func lastFix(_ at: Date?, now: Date) -> String {
        guard let at else { return "لا يوجد موقع معروف" }
        let m = minutes(since: at, now: now)
        if m >= 60 { return "آخر موقع قبل \(ArabicFormat.number(Double(m / 60))) س" }
        return "آخر موقع قبل \(ArabicFormat.number(Double(m))) د"
    }

    /// «قبل ١٤ د» / «قبل ٢ س» (same rounding as the card).
    static func ago(_ at: Date, now: Date) -> String {
        let m = minutes(since: at, now: now)
        if m >= 60 { return "قبل \(ArabicFormat.number(Double(m / 60))) س" }
        return "قبل \(ArabicFormat.number(Double(m))) د"
    }

    /// «رجع إرسال فهد»
    static func resumed(name: String) -> String { "رجع إرسال \(name)" }
}
