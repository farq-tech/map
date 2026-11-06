import Foundation

/// Wire types for `/api/outings`, mirroring `apps/web/src/lib/outings/api.ts`.
/// Field names stay snake_case so a diff against the server is a straight read.

enum ShareMode: String, Codable, CaseIterable {
    case precise, balanced, saver
}

enum OutingStatus: String, Codable {
    case created, active, paused, ended
}

enum GpsState: String, Codable {
    case ok, weak, unavailable, denied
}

struct PublicUser: Codable, Equatable {
    var id: String
    var display_name: String
    var avatar: String?
    var phone: String?
}

struct Identity: Codable, Equatable {
    var token: String
    var user: PublicUser
}

struct MemberNote: Codable, Equatable {
    var text: String
    var at: String
}

struct Member: Codable, Equatable, Identifiable {
    var user_id: String
    var display_name: String
    var avatar: String?
    var phone: String?
    var role: String
    var sharing: Bool
    var joined_at: String
    var online: Bool?
    var away: Bool?
    var last_seen_at: String?
    var gps: GpsState?
    var note: MemberNote?
    /// «نائب الأمير»: promoted by the owner; may manage the rally point.
    var co_leader: Bool?
    /// Shared only when that member chose to (heartbeat `battery`).
    var battery: BatteryInfo?
    /// Their SOS, while it stands (memory-only on the server, 60 min TTL).
    var sos: SosInfo?
    /// «دعوة شخصية»: `display_name` is then the name the inviter gave them («فهد أخوي»);
    /// `nickname` is their own name, shown secondarily (nil when the same or not invited).
    var nickname: String? = nil
    /// Joined through a personal invite.
    var invited: Bool? = nil
    /// Last four digits of the number they were invited on (never the full number).
    var phone_last4: String? = nil
    /// «مباشر / متأخر / منقطع» + why (server-decided, active outings only). See MemberPresence.swift.
    var presence: MemberPresence? = nil

    var id: String { user_id }
}

struct BatteryInfo: Codable, Equatable {
    /// 0...1
    var level: Double
    var charging: Bool
    var at: String?
}

/// A member's SOS. `fix` is their last REAL fix with its own time (may be old), or nil.
struct SosInfo: Codable, Equatable {
    var at: String
    var fix: SosFix?
}

struct SosFix: Codable, Equatable {
    var lat: Double
    var lng: Double
    var accuracy: Double?
    var recorded_at: String
}

/// The meeting point a leader dropped.
struct RallyInfo: Codable, Equatable {
    var lat: Double
    var lng: Double
    var label: String?
    var set_at: String?
    var set_by: String?
}

/// A push-to-talk clip: memory-only on the server for 10 minutes.
struct VoiceClip: Codable, Equatable, Identifiable {
    var id: String
    var user_id: String
    var mime: String
    var duration_ms: Int
    var bytes: Int?
    var at: String
    var expires_at: String
    /// `/api/outings/:id/clips/:clipId`, needs the Bearer token.
    var url: String
}

struct Position: Codable, Equatable {
    var user_id: String
    var lat: Double
    var lng: Double
    var accuracy: Double?
    var heading: Double?
    var speed: Double?
    var mode: ShareMode?
    var recorded_at: String
    var received_at: String?
}

struct OutingInfo: Codable, Equatable {
    var id: String
    var name: String
    var status: OutingStatus
    var owner_id: String
    var created_at: String?
    var started_at: String?
    var ended_at: String?
    var rally: RallyInfo?
    var join_locked: Bool?
    /// «وضع القافلة» (contract §4); nil or both ids nil = off.
    var convoy: ConvoyInfo?
}

struct SnapshotMe: Codable, Equatable {
    var user_id: String
    var role: String
    /// The SERVER's flag. It defaults to true on join, so it is never consent:
    /// sending also needs this device's own consent and the person's share press.
    var sharing: Bool
    var co_leader: Bool?
    var can_lead: Bool?
}

struct InviteState: Codable, Equatable {
    var active: Bool
    var expires_at: String?
    /// «الرابط المفتوح»: may the open group link admit people? nil (older server) = yes.
    var open_links: Bool? = nil
}

/// «دعوة شخصية» as the leader sees it: one line per person invited.
struct PersonalInvite: Codable, Equatable, Identifiable {
    enum Status: String, Codable { case sent, opened, joined, expired, revoked }
    var id: String
    var invitee_name: String
    var phone_last4: String?
    var status: Status
    var opened: Bool?
    var created_at: String?
    var expires_at: String
    var member_user_id: String?
    /// Only in the answer that created / re-sent it; kept on this phone after that.
    var token: String?
}

struct OutingSnapshot: Codable, Equatable {
    var outing: OutingInfo
    var me: SnapshotMe
    var members: [Member]
    var positions: [Position]
    var invite: InviteState?
    var server_now: String
    var voice_clips: [VoiceClip]?
    /// Totals members chose to share once the outing ended (never points).
    var summaries: [TripShare]?
    /// «غرّزت»: who is stuck right now, with the replies (nil while the server does not send it).
    var stuck: [StuckWire]? = nil
    /// Tolerated at the top level too, in case the server sends it there.
    var convoy: ConvoyInfo?
    /// Optional, members only: 32 random bytes (base64url) keying the
    /// phone-to-phone link (`MeshKeys`). Until the server sends it, the app
    /// derives an interim key from the outing id (see docs/NEARBY-MESH.md).
    var mesh_key: String? = nil
    /// Members whose sharing went silent ≥10 min (server-decided). Never draw them as live.
    var silent: [SilentInfo]? = nil
    /// Leaders only: the personal invites of this trip (nil from older servers / for members).
    var personal_invites: [PersonalInvite]? = nil
    /// «المحادثات»: my unread chat messages in this trip (nil from older servers).
    var chat_unread: Int? = nil
}

/// One member's shared trip totals (`PUT /:id/summary`).
struct TripShare: Codable, Equatable, Identifiable {
    var user_id: String
    var display_name: String
    var distance_m: Double
    var duration_s: Double
    var moving_s: Double
    var shared_at: String?
    var id: String { user_id }
}

struct OutingSummary: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var status: OutingStatus
    var role: String
    var my_status: String
    var member_count: Int
    var created_at: String?
    var started_at: String?
    var ended_at: String?
    var summaries: [TripShare]? = nil
}

struct InvitePreview: Codable, Equatable {
    var outing_id: String
    var name: String
    var status: OutingStatus
    var owner_name: String
    var member_count: Int
    var expires_at: String
    var join_locked: Bool? = nil
    /// "personal": one link for one person — whoever joins becomes `invitee_name` in the trip.
    var kind: String? = nil
    var invitee_name: String? = nil
    /// open · yours (used by me: rejoin) · taken (someone else used it) · claimed (used; asked anonymously).
    var claim: String? = nil
    /// The same person back with a new account (phone matches the leader's contact): joining moves the seat here.
    var reclaim: Bool? = nil
    var already_member: Bool? = nil
    /// The trip's destination («روضة الثمامة»), when the server sends it (newer servers only).
    var destination_name: String? = nil

    var isPersonal: Bool { kind == "personal" }
}

struct CreatedInvite: Codable, Equatable {
    var token: String
    var expires_at: String
}

/// The fix as the server expects it (`validate.fix`). `age_ms` is measured on
/// this device's clock at send time, so a phone whose clock is off still
/// produces an honest `recorded_at` on the server's.
struct WireFix: Codable, Equatable {
    var lat: Double
    var lng: Double
    var accuracy: Double?
    var heading: Double?
    var speed: Double?
    var mode: ShareMode
    var age_ms: Double
}

/// ISO-8601 with or without fractional seconds (Postgres gives milliseconds).
enum ISODate {
    private static let frac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parse(_ s: String?) -> Date? {
        guard let s else { return nil }
        return frac.date(from: s) ?? plain.date(from: s)
    }

    static func string(_ d: Date) -> String { frac.string(from: d) }
}
