import SwiftUI
import UIKit

// Shared value types used by more than one screen. All are plain `Equatable`
// values: the wiring layer builds them from Core/Net models, the screens only
// read them. Nothing in here talks to the network, location or the map.

/// Where a participant's position stands. ONE field — never separate flags.
/// A stale position is always drawn greyed with its age; it never looks live.
enum ParticipantPresence: Equatable {
    /// A fresh fix (the wiring layer decides "fresh", e.g. Core `Freshness.live`).
    case live
    /// The last fix is old. `since` = time of that last fix (shown as "قبل ٤ د").
    case stale(since: Date)
    /// The participant paused sharing their location on purpose.
    case paused

    var isLive: Bool { self == .live }
}

/// Role inside one outing.
enum ParticipantRole: Equatable {
    /// Created the outing: «صاحب الطلعة».
    case leader
    /// Promoted by the leader: «مساعد». Can manage the rally point.
    case coLeader
    case member

    /// Leader or co-leader: may move/remove the rally point.
    var canManageRally: Bool { self != .member }
}

/// Outing lifecycle as shown to people.
enum OutingStatusUI: Equatable {
    case active, paused, notStarted, ended

    var label: String {
        switch self {
        case .active: return "جارية"
        case .paused: return "متوقفة مؤقتًا"
        case .notStarted: return "لم تبدأ"
        case .ended: return "انتهت"
        }
    }
}

/// Connection of the live channel.
enum ConnectionStateUI: Equatable {
    case connected, connecting, limited, offline

    var label: String {
        switch self {
        case .connected: return "متصل"
        case .connecting: return "جارٍ الاتصال…"
        case .limited: return "اتصال محدود"
        case .offline: return "بلا إنترنت"
        }
    }
}

/// Automatic / on / off, used by drive mode and night mode settings.
enum TriModeUI: Equatable, CaseIterable, Hashable {
    case automatic, on, off

    var label: String {
        switch self {
        case .automatic: return "تلقائي"
        case .on: return "تشغيل"
        case .off: return "إيقاف"
        }
    }
}

/// One participant as every screen sees them.
struct ParticipantUI: Equatable, Identifiable {
    /// Stable id (the server's user_id).
    var id: String
    /// Display name, up to 40 characters. Long names are truncated by the views.
    var name: String
    /// Car colour as 0xRRGGBB, from join order (Core `CarColors.assign`).
    var color: UInt32
    var role: ParticipantRole
    /// True for the current user: shown as «أنت».
    var isMe: Bool
    var presence: ParticipantPresence
    /// Metres from me. Nil when either position is unknown (hides distance).
    var distanceMeters: Double?
    /// Direction to them in degrees clockwise from the top of the screen
    /// (i.e. bearing minus map/device heading). Nil hides the arrow.
    var bearingDegrees: Double?
    /// Battery 0...100 when they share it, nil when they don't.
    var batteryPercent: Int?
    /// Their current note above the car (≤ 80 chars), nil when none.
    var note: String?
    /// True while they have an unplayed voice clip (small icon above the car).
    var hasVoice: Bool = false
    /// True when they added a phone number (enables «اتصال» / «واتساب»).
    var hasPhone: Bool
    /// Optional photo. Initials on their colour are drawn when nil.
    var photo: UIImage?
    /// Their speed in km/h, only from a fresh (live) position; nil hides it
    /// (stale: just «آخر موقع قبل …», never an old speed).
    var speedKmh: Double? = nil

    /// «صاحب الطلعة» / «مساعد» / «أنت», joined with "·" when several apply.
    var roleLabel: String? {
        var parts: [String] = []
        switch role {
        case .leader: parts.append("صاحب الطلعة")
        case .coLeader: parts.append("مساعد")
        case .member: break
        }
        if isMe { parts.append("أنت") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Generic load state for lists fetched by the wiring layer.
enum LoadPhaseUI<Value: Equatable>: Equatable {
    case loading
    case loaded(Value)
    /// Loaded, nothing to show.
    case empty
    /// Arabic, human message (e.g. «تعذّر التحميل، حاول مرة ثانية»).
    case error(String)
}
