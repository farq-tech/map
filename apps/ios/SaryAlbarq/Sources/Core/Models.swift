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

    var id: String { user_id }
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
}

struct SnapshotMe: Codable, Equatable {
    var user_id: String
    var role: String
    var sharing: Bool
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
