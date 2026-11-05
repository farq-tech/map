import SwiftUI

// Contracts for the screens presented from the live outing, the trip summary
// and the components that sit on the map.

/// The voice banner reads a `VoiceClipUI`.
typealias VoiceBannerUIState = VoiceClipUI

// MARK: - Participant card

struct ParticipantCardUIState: Equatable {
    var participant: ParticipantUI
    /// For "قبل ٤ د".
    var now: Date
    /// I am the leader and this is someone else: shows «اجعله نائبًا للأمير» and «أزله من الطلعة».
    var canManage: Bool
    /// True while promote/remove is in flight: those buttons are disabled.
    var isBusy: Bool = false
    var errorMessage: String?
}

struct ParticipantCardActions {
    /// «اتصال» (enabled when `participant.hasPhone`). Expect: open tel:.
    var call: () -> Void = {}
    /// «واتساب» (enabled when `participant.hasPhone`). Expect: open wa.me.
    var whatsApp: () -> Void = {}
    /// «أظهره على الخريطة». Expect: dismiss the card and centre on them.
    var showOnMap: () -> Void = {}
    /// «روح له»: turn-by-turn to their last LIVE position (refused, with the reason, when it is old).
    var navigate: () -> Void = {}
    /// «اجعله نائبًا للأمير» (leader only), after the UI's confirmation.
    var promoteCoLeader: () -> Void = {}
    /// «أزله من الطلعة» (leader only), after the UI's confirmation.
    var removeMember: () -> Void = {}
    /// Close button / swipe down.
    var close: () -> Void = {}
}

// MARK: - Note composer («رسالة»)

struct NoteComposerUIState: Equatable {
    /// My current note (shown with «احذف رسالتي»), nil when none.
    var currentNote: String?
    /// Max characters.
    var maxLength: Int = 80
    /// Ready phrases, tapped to fill the field.
    var presets: [String] = ["بوقف", "محطة بنزين", "اصبروا لي", "تعبت، نوقف نرتاح", "وصلت"]
    var isSending: Bool = false
    var errorMessage: String?
}

struct NoteComposerActions {
    /// «أرسل». `text` is trimmed, 1...maxLength. Expect: post it; it shows above my car for 15 min.
    var send: (_ text: String) -> Void = { _ in }
    /// «احذف رسالتي». Expect: clear my note.
    var clearNote: () -> Void = {}
    /// «إلغاء».
    var cancel: () -> Void = {}
}

// MARK: - Nearest stations

struct StationUI: Equatable, Identifiable {
    var id: String
    var name: String
    var distanceMeters: Double
    /// Degrees clockwise from the top of the screen. Nil hides the arrow.
    var bearingDegrees: Double?
    /// e.g. «مفتوحة ٢٤ ساعة»; optional.
    var detail: String?
}

struct NearestStationsUIState: Equatable {
    /// `.empty` = nothing within range; `.error` is retryable.
    var phase: LoadPhaseUI<[StationUI]> = .loading
}

struct NearestStationsActions {
    /// «اتجه». Expect: open directions to the station.
    var go: (_ id: String) -> Void = { _ in }
    /// «أظهرها». Expect: dismiss and centre the map on it.
    var show: (_ id: String) -> Void = { _ in }
    var retry: () -> Void = {}
    var close: () -> Void = {}
}

// MARK: - Trip summary

struct TripSummaryUIState: Equatable {
    var outingName: String
    var distanceMeters: Double
    var durationSeconds: Int
    var participantCount: Int
    /// Longest stop; nil when there was none.
    var longestStopSeconds: Int?
    var endedAt: Date
    /// Route as points normalised to 0...1 (x right, y down). Used by
    /// `RouteSketch` when no real map is passed in.
    var routePoints: [CGPoint]
}

struct TripSummaryActions {
    /// «تم». Expect: back to «طلعاتي».
    var done: () -> Void = {}
    /// «شارك الملخص». Expect: share sheet with a text/image summary.
    var share: () -> Void = {}
}

// MARK: - Map overlay components (placed by the wiring layer at screen points)

struct NameChipUI: Equatable {
    var name: String
    var color: UInt32
    var isMe: Bool
    /// Stale → greyed with its age; paused → greyed «متوقف».
    var presence: ParticipantPresence
    var hasVoice: Bool = false
    var now: Date
    /// «غرّزت»: a small stuck icon on the chip until they clear it.
    var stuck: Bool = false
    /// «المقدمة» / «المؤخرة» badge in convoy mode.
    var convoy: ConvoyBadgeUI? = nil
    /// Position heard phone to phone: a small «عبر الأجهزة القريبة» marker.
    var viaNearby: Bool = false
    /// On air in «قناة الطلعة» right now: an animated speaking badge.
    var speaking: Bool = false
    /// Sharing went silent: «انقطع منذ ١٠ د» instead of the age.
    var silentSince: Date? = nil
}

struct NoteBubbleUI: Equatable {
    /// ≤ 80 characters; longer text is cut with "…".
    var text: String
    var color: UInt32
}

struct EdgeArrowChipUI: Equatable {
    var name: String
    var color: UInt32
    var distanceMeters: Double?
    /// Degrees clockwise from the top of the screen, toward the friend.
    var bearingDegrees: Double
    var isStale: Bool
}

struct RallyMarkerUI: Equatable {
    /// e.g. «نقطة التجمع».
    var label: String?
}

/// Tap targets on the overlay components.
struct MapOverlayActions {
    /// Name chip / edge arrow tapped: the participant id given by the wiring layer.
    var participantTapped: () -> Void = {}
}
