import Foundation

// Wire types for the safety pack («مؤقت الرجوع» and «غرّزت»), mirroring the
// server contract (feat/outing-features-api). Field names stay snake_case so a
// diff against the server is a straight read.

// MARK: - Return timer

enum ReturnTimerState: String, Codable, Equatable {
    case armed, overdue, arrived, cancelled
}

/// `{ id, due_at, contact_name, state }`.
struct ReturnTimerWire: Codable, Equatable {
    var id: String
    var due_at: String
    var contact_name: String
    var state: ReturnTimerState
}

/// `POST /return-timer` → `{ timer, watch_url }`; `GET /return-timer` → `{ timer: null | … }`.
/// Every field optional so `{ok:true}` (arrived / cancel) decodes too.
struct ReturnTimerBox: Decodable, Equatable {
    var timer: ReturnTimerWire?
    var watch_url: String?
}

// MARK: - Stuck

enum StuckReplyKind: String, Codable, Equatable, CaseIterable {
    case coming, have_rope, cant

    /// What the stuck person reads next to the friend's name.
    var label: String {
        switch self {
        case .coming: return "جاي"
        case .have_rope: return "معه حبل"
        case .cant: return "ما يقدر"
        }
    }

    /// The reply button («أنا»).
    var button: String {
        switch self {
        case .coming: return "جاي"
        case .have_rope: return "معي حبل"
        case .cant: return "ما أقدر"
        }
    }

    var systemImage: String {
        switch self {
        case .coming: return "car.fill"
        case .have_rope: return "link"
        case .cant: return "hand.raised.fill"
        }
    }

    /// Helpful first: who is coming, then who has a rope, then who cannot.
    var rank: Int {
        switch self {
        case .coming: return 0
        case .have_rope: return 1
        case .cant: return 2
        }
    }
}

struct StuckReplyWire: Codable, Equatable {
    var user_id: String
    var kind: StuckReplyKind
}

/// One stuck member in `GET /:id/live` → `stuck: [...]`.
struct StuckWire: Codable, Equatable {
    var user_id: String
    var at: String
    var note: String?
    var replies: [StuckReplyWire]?
}

// MARK: - Live events

/// The safety events on the outing's WebSocket (same envelope as `member_note`).
enum SafetyEvent: Equatable {
    /// `return_timer {user_id, state, due_at}`.
    case returnTimer(userId: String, state: ReturnTimerState, dueAt: String?)
    /// `member_stuck {user_id, at, note}`.
    case stuck(userId: String, at: String, note: String?)
    /// `stuck_reply {user_id, to_user_id, kind}`.
    case stuckReply(userId: String, toUserId: String, kind: StuckReplyKind)
    /// `stuck_clear {user_id}`.
    case stuckClear(userId: String)

    static let types: Set<String> = ["return_timer", "member_stuck", "stuck_reply", "stuck_clear"]

    /// nil for anything that is not a well-formed safety frame.
    static func decode(_ type: String, _ obj: [String: Any]) -> SafetyEvent? {
        guard let uid = obj["user_id"] as? String, !uid.isEmpty else { return nil }
        switch type {
        case "return_timer":
            guard let st = (obj["state"] as? String).flatMap(ReturnTimerState.init(rawValue:)) else { return nil }
            return .returnTimer(userId: uid, state: st, dueAt: obj["due_at"] as? String)
        case "member_stuck":
            let at = obj["at"] as? String ?? ISODate.string(Date())
            let note = (obj["note"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return .stuck(userId: uid, at: at, note: note)
        case "stuck_reply":
            guard let to = obj["to_user_id"] as? String,
                  let k = (obj["kind"] as? String).flatMap(StuckReplyKind.init(rawValue:)) else { return nil }
            return .stuckReply(userId: uid, toUserId: to, kind: k)
        case "stuck_clear":
            return .stuckClear(userId: uid)
        default:
            return nil
        }
    }
}

// MARK: - Availability

/// Whether the server has these endpoints yet. Never guessed as "on".
enum SafetyAvailability: Equatable {
    case unknown
    case available
    /// 404/405 with no error code: the endpoint is not deployed yet («غير متاح بعد»).
    case notDeployed
}

extension OutingAPIError {
    /// Express answers an unknown route with a bare 404 (no JSON `error`), a proxy with 405.
    /// A 404 that carries a code (`not_a_member`, …) is a real answer, not a missing route.
    var isNotDeployed: Bool {
        (status == 404 || status == 405) && (code.hasPrefix("http_") || code == "not_found")
    }
}

extension OutingAPIError {
    /// The safety routes' own codes (server branch feat/outing-features-api), then the shared table.
    var safetyArabic: String {
        switch code {
        case "invalid_due_at": return "اختر وقت رجوع بعد دقيقة على الأقل، وخلال ٧ أيام."
        case "invalid_contact_name": return "اكتب اسم اللي يتابعك (٤٠ حرفًا أو أقل)."
        case "no_timer": return "ما فيه مؤقت رجوع شغال."
        case "not_stuck": return "طلع خلاص، ما عاد غارز."
        case "cannot_reply_self": return "ما تقدر ترد على نفسك."
        case "invalid_kind": return "تعذّر إرسال الرد."
        case "too_frequent": return "انتظر ثواني ثم أعد المحاولة."
        default: return arabic
        }
    }
}
