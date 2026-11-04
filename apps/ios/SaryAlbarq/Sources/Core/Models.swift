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
    /// «مساعد»: promoted by the owner; may manage the rally point.
    var co_leader: Bool?
    /// Shared only when that member chose to (heartbeat `battery`).
    var battery: BatteryInfo?
    /// Their SOS, while it stands (memory-only on the server, 60 min TTL).
    var sos: SosInfo?

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
