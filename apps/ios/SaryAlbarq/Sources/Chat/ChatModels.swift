import Foundation

/// «المحادثات» — the trip chat (server: apps/api/lib/outings/chat.js).
///
///   · one group conversation per trip («دردشة الطلعة»), for every member;
///   · 1:1 direct conversations between two members of the same trip.
///
/// The server decides who may read and write (membership on every request
/// and socket frame), orders everything by its own `seq`, and deletes the
/// whole chat 30 days after the trip ended.

/// Which conversation: the group, or a direct chat with one other member.
enum ChatWith: Hashable, Codable, Identifiable {
    case group
    case direct(String)

    /// The `:with` path segment / socket `with` field.
    var wire: String {
        switch self {
        case .group: return "group"
        case let .direct(id): return id
        }
    }

    init(wire: String) { self = wire == "group" ? .group : .direct(wire) }

    var id: String { wire }
    var isGroup: Bool { self == .group }
    var peer: String? { if case let .direct(p) = self { return p } else { return nil } }

    init(from decoder: Decoder) throws { self.init(wire: try decoder.singleValueContainer().decode(String.self)) }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(wire)
    }
}

struct ChatPoint: Codable, Equatable, Hashable {
    var lat: Double
    var lng: Double
    var label: String?
}

enum ChatKind: String, Codable { case text, quick, location }

/// One message as the server sends it, plus the local delivery state of my own.
struct ChatMessage: Codable, Equatable, Identifiable {
    var id: String
    var outing_id: String
    var seq: Int
    var conv: String
    var sender_id: String
    var recipient_id: String?
    var sender_name: String?
    var client_id: String
    var kind: ChatKind
    var text: String?
    var point: ChatPoint?
    var created_at: String
    var deleted: Bool
    var deleted_by: String?

    /// Local only: my message is still in the outbox (no server seq yet), or the server refused it.
    var delivery: Delivery = .stored

    enum Delivery: Equatable { case stored, sending, retrying, failed(String) }

    enum CodingKeys: String, CodingKey {
        case id, outing_id, seq, conv, sender_id, recipient_id, sender_name, client_id, kind, text, point, created_at, deleted, deleted_by
    }

    var isPending: Bool { delivery != .stored }

    /// The conversation this message belongs to, from `me`'s side.
    func thread(me: String) -> ChatWith {
        guard conv != "group" else { return .group }
        return .direct(sender_id == me ? (recipient_id ?? "") : sender_id)
    }

    /// Stable across the pending → stored transition (the server keeps my client_id).
    var key: String { "\(sender_id):\(client_id)" }
}

struct ChatRead: Codable, Equatable {
    var user_id: String
    var seq: Int
}

/// `GET /:id/chat/:with` — one page, oldest first.
struct ChatPage: Decodable {
    var with: String
    var messages: [ChatMessage]
    var has_more: Bool
    var my_read_seq: Int
    var reads: [ChatRead]
    var writable: Bool
    var read_only_reason: String?
}

/// One line of the conversation list (`GET /:id/chat`).
struct ChatConversationWire: Decodable, Equatable {
    var with: String
    var conv: String
    var peer_id: String?
    var peer_active: Bool?
    var unread: Int
    var last_message: ChatMessage?
    var my_read_seq: Int
    var peer_read_seq: Int?
    var writable: Bool
}

struct ChatOverview: Decodable, Equatable {
    var conversations: [ChatConversationWire]
    var unread_total: Int
    var writable: Bool
    var read_only_reason: String?
    var can_moderate: Bool
    var quick_replies: [String]?
    var retention_days: Int?
    var purge_at: String?
}

/// What I asked to send — kept in the outbox until the server has it.
struct ChatDraft: Codable, Equatable, Identifiable {
    var client_id: String
    var with: ChatWith
    var kind: ChatKind
    var text: String?
    var point: ChatPoint?
    var created_at: String
    var attempts: Int = 0

    var id: String { client_id }

    /// The HTTP / socket body.
    var body: [String: Any] {
        var b: [String: Any] = ["client_id": client_id, "kind": kind.rawValue]
        if let text { b["text"] = text }
        if let point {
            var p: [String: Any] = ["lat": point.lat, "lng": point.lng]
            if let l = point.label { p["label"] = l }
            b["point"] = p
        }
        return b
    }

    /// The bubble shown while it travels.
    func pendingMessage(outingId: String, me: String, myName: String?) -> ChatMessage {
        ChatMessage(id: "local-\(client_id)", outing_id: outingId, seq: 0, conv: with.isGroup ? "group" : "direct",
                    sender_id: me, recipient_id: with.peer, sender_name: myName, client_id: client_id, kind: kind,
                    text: text, point: point, created_at: created_at, deleted: false, deleted_by: nil, delivery: .sending)
    }
}

enum ChatRules {
    static let textMax = 1000
    /// The note presets, offered as quick replies (the server sends its own list too).
    static let quickReplies = ["بوقف", "محطة بنزين", "اصبروا لي", "تعبت، نوقف نرتاح", "وصلت"]
    /// Socket frames are capped at 4 KB on the server; bigger messages go over HTTP.
    static let maxSocketBytes = 3_500
    /// Server answers that will never succeed on retry: drop from the outbox, show why.
    static let terminal: Set<String> = ["outing_ended", "chat_read_only", "peer_not_active", "not_a_member", "text_too_long",
                                        "invalid_message", "invalid_point", "invalid_kind", "invalid_conversation", "invalid_client_id", "unauthorized"]

    enum DraftCheck: Equatable { case ok(String), empty, tooLong }

    /// Trimmed; at most 1000 characters (code points, like the server).
    static func check(_ raw: String) -> DraftCheck {
        let t = raw.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return .empty }
        if t.unicodeScalars.count > textMax { return .tooLong }
        return .ok(t)
    }

    /// «وقّف عشان تكتب»: no keyboard while the car moves (> 15 km/h, same hysteresis as the driving screen).
    static func canType(moving: Bool) -> Bool { !moving }

    static func newClientId() -> String { "i" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(20).lowercased() }

    static func deletedLabel(_ m: ChatMessage) -> String { m.deleted_by == "leader" ? "حذفها أمير الرحلة" : "حُذفت الرسالة" }

    static func errorText(_ code: String) -> String {
        switch code {
        case "outing_ended": return "انتهت الطلعة — المحادثة للقراءة فقط."
        case "chat_read_only": return "غادرت الطلعة — المحادثة للقراءة فقط."
        case "peer_not_active": return "خرج من الطلعة — ما تقدر تراسله."
        case "text_too_long": return "الرسالة أطول من ١٠٠٠ حرف."
        case "too_frequent", "rate_limited": return "مهلًا، رسائل كثيرة بسرعة."
        case "not_allowed": return "ما تقدر تحذف هذه الرسالة."
        case "not_a_member": return "لست عضوًا في هذه الطلعة."
        default: return "ما وصلت — نعيد المحاولة تلقائيًا."
        }
    }

    /// Order: server seq; my pending ones last, in the order I wrote them.
    static func merge(_ list: [ChatMessage], _ incoming: [ChatMessage]) -> [ChatMessage] {
        var byKey: [String: ChatMessage] = [:]
        var order: [String] = []
        for m in list + incoming {
            if let prev = byKey[m.key] {
                /* The server's copy wins over a pending one; a deletion over the original. */
                if !prev.isPending && m.isPending { continue }
                if !prev.isPending && prev.deleted && !m.deleted { continue }
            } else {
                order.append(m.key)
            }
            byKey[m.key] = m
        }
        return order.compactMap { byKey[$0] }.sorted { a, b in
            switch (a.isPending, b.isPending) {
            case (true, true): return a.created_at < b.created_at
            case (true, false): return false
            case (false, true): return true
            default: return a.seq < b.seq
            }
        }
    }

    /// ✓ stored · ✓✓ everyone else in the conversation has read it.
    enum Receipt: Equatable { case sending, retrying, failed, sent, read }

    static func receipt(_ m: ChatMessage, me: String, reads: [String: Int], others: Int) -> Receipt? {
        guard m.sender_id == me else { return nil }
        switch m.delivery {
        case .sending: return .sending
        case .retrying: return .retrying
        case .failed: return .failed
        case .stored: break
        }
        let readers = reads.filter { $0.key != me && $0.value >= m.seq }.count
        return others > 0 && readers >= others ? .read : .sent
    }
}
