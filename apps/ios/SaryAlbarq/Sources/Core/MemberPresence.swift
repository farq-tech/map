import Foundation

/// «مباشر / متأخر / منقطع» + why, decided by the server from the last fix's time
/// (`apps/api/lib/outings/presence.js`). The app shows the reason, never a vague «انقطع».
///
///   snapshot: members[].presence = { state, reason, last_fix_at, since }
///   ← { type: 'member_presence', user_id, state, reason, last_fix_at, since }
struct MemberPresence: Codable, Equatable {
    enum State: String, Codable { case live, stale, offline, hidden }

    var state: State
    var reason: String?
    var last_fix_at: String?
    var since: String?

    var reasonKind: PresenceReason? { reason.flatMap(PresenceReason.init(rawValue:)) }
}

/// Why a member is not live. Same table as the server's `REASON_TEXT`.
enum PresenceReason: String, Equatable, CaseIterable {
    case hidden
    case locationOff = "location_off"
    case appClosed = "app_closed"
    case whenInUse = "when_in_use"
    case web
    case noGps = "no_gps"
    case lowPower = "low_power"
    case noNetwork = "no_network"

    /// The short Najdi line on the chip / row.
    var text: String {
        switch self {
        case .hidden: return "مخفي موقعه"
        case .locationOff: return "جواله مقفل الموقع"
        case .appClosed: return "سرى مسكّر عنده"
        case .whenInUse: return "الموقع «أثناء الاستخدام» بس"
        case .web: return "يتابع من المتصفح"
        case .noGps: return "ما فيه إشارة GPS"
        case .lowPower: return "وضع توفير الطاقة"
        case .noNetwork: return "ما فيه شبكة"
        }
    }

    /// What the leader can tell them (the participant card).
    var fix: String? {
        switch self {
        case .hidden: return nil
        case .locationOff: return "يفتح الإعدادات ← سرى ← الموقع ← «دائمًا»"
        case .appClosed: return "يفتح سرى مرة وحدة ويرجع موقعه"
        case .whenInUse: return "يغيّر إذن الموقع إلى «دائمًا»"
        case .web: return "ينزّل تطبيق سرى عشان يوصل موقعه والجوال مقفل"
        case .noGps: return "يطلع لمكان مكشوف"
        case .lowPower: return "يطفي وضع توفير الطاقة"
        case .noNetwork: return "بيوصل موقعه أول ما ترجع الشبكة"
        }
    }
}

extension SilenceText {
    /// «جواله مقفل الموقع — آخر موقع قبل ٥ د» (or the old line when the reason is unknown).
    static func badge(since: Date, now: Date, reason: PresenceReason?) -> String {
        guard let reason else { return badge(since: since, now: now) }
        if reason == .hidden { return reason.text }
        return "\(reason.text) — \(lastFix(since, now: now))"
    }

    /// The card title: «فهد: ما فيه شبكة».
    static func title(name: String, since: Date, now: Date, reason: PresenceReason?) -> String {
        guard let reason else { return title(name: name, since: since, now: now) }
        return "\(name): \(reason.text)"
    }
}

/// What this phone tells the server about itself in the heartbeat (`hint`), so the others see
/// why it may go quiet before it does. Pure.
enum PresenceHint: String, Equatable {
    case foreground = "fg"
    case backgroundAlways = "bg_always"
    case backgroundWhenInUse = "bg_when_in_use"
    case lowPower = "low_power"
    case terminated
    case locationOff = "location_off"

    /// The hint for leaving / returning to the screen.
    static func forState(foreground: Bool, canLocate: Bool, always: Bool) -> PresenceHint {
        if !canLocate { return .locationOff }
        if foreground { return .foreground }
        return always ? .backgroundAlways : .backgroundWhenInUse
    }
}

extension ParticipantPresence {
    /// When the last fix was taken, if not live.
    var staleSince: Date? {
        if case let .stale(since) = self { return since }
        return nil
    }
}
