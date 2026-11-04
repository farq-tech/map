import SwiftUI

// Contract for the live outing screen (map + top bar + alert lane + side
// buttons + SOS/PTT + bottom sheet with three tabs). Sub-screens opened from
// here (participant card, note composer, nearest stations) are separate
// screens with their own contracts; the wiring layer presents them.

// MARK: - Sheet

enum SheetDetentUI: Equatable, CaseIterable {
    /// Only the summary line «٣ مشارك · ٢ مباشر · الأقرب ٩٠٠ م».
    case peek
    /// About 40 % of the screen.
    case half
    /// Everything up to the control row.
    case full
}

enum LiveTabUI: Equatable, CaseIterable, Hashable {
    case participants, invite, settings

    var label: String {
        switch self {
        case .participants: return "المشاركون"
        case .invite: return "الدعوة"
        case .settings: return "الإعدادات"
        }
    }
}

// MARK: - Top bar

enum LiveWarningUI: Equatable, Hashable {
    /// GPS accuracy is poor.
    case weakGPS
    /// No internet: positions are queued.
    case noInternet
    /// Advice: keep the screen on for the most accurate sharing.
    case keepScreenOn
    /// Location permission is off; sharing cannot work.
    case locationOff

    var label: String {
        switch self {
        case .weakGPS: return "إشارة الموقع ضعيفة"
        case .noInternet: return "بلا إنترنت · نرسل موقعك أول ما يرجع الاتصال"
        case .keepScreenOn: return "خلّ الشاشة شغالة لدقة أعلى"
        case .locationOff: return "إذن الموقع مقفل · افتح الإعدادات"
        }
    }
}

enum MySharingUI: Equatable {
    /// «موقعك مُشارَك الآن مع أعضاء الطلعة» with a green dot.
    case sharing
    /// I paused it: grey dot, «مشاركة موقعك متوقفة».
    case paused
    /// Waiting for the first fix / permission: amber dot, «جارٍ تحديد موقعك…».
    case starting
}

// MARK: - Alert lane

/// A playable voice clip from a friend.
struct VoiceClipUI: Equatable {
    var id: String
    var senderName: String
    var senderColor: UInt32
    var durationSeconds: Int
    var playback: VoicePlaybackUI
}

enum VoicePlaybackUI: Equatable {
    case idle
    case loading
    /// 0...1
    case playing(progress: Double)
}

enum LiveAlertKindUI: Equatable {
    /// A friend posted a note.
    case note(senderName: String, senderColor: UInt32, text: String)
    /// Someone drifted away from the group.
    case drift(name: String, color: UInt32, distanceMeters: Double)
    /// A voice clip arrived: the voice banner.
    case voice(VoiceClipUI)
    /// Short neutral toast (e.g. «تم نسخ الرابط»).
    case toast(String)
    /// Return timer, «غرّزت», sunset & way back (`Sources/Safety`).
    case safety(SafetyAlertUI)
}

struct LiveAlertUI: Equatable, Identifiable {
    var id: String
    var kind: LiveAlertKindUI
}

// MARK: - Push-to-talk

/// ONE enum for the push-to-talk button. No extra flags.
enum PTTStateUI: Equatable {
    case idle
    /// Pressed; mic is starting («جارٍ التجهيز…»).
    case arming
    /// Recording; elapsed whole seconds.
    case recording(seconds: Int)
    /// Released; uploading the clip.
    case sending
}

// MARK: - SOS

enum MySOSUI: Equatable {
    case none
    /// The hold completed and the alert is being sent.
    case sending
    /// Sent: red strip «أرسلت طوارئ» with «أنا بخير».
    case active(since: Date)
}

struct IncomingSOSUI: Equatable, Identifiable {
    /// Alert id.
    var id: String
    var participantId: String
    var name: String
    var color: UInt32
    var distanceMeters: Double?
    var bearingDegrees: Double?
    var hasPhone: Bool
    var since: Date
    /// False: full-screen alert. True (after «أظهره»): fixed red strip at the top
    /// until the sender clears it (the wiring layer removes it then).
    var acknowledged: Bool
}

struct SOSUIState: Equatable {
    var mine: MySOSUI = .none
    /// Newest first. The first unacknowledged one shows full-screen.
    var incoming: [IncomingSOSUI] = []
}

// MARK: - Participants tab

struct RallyPointUI: Equatable {
    var distanceMeters: Double?
    var bearingDegrees: Double?
    var arrivedCount: Int
    var totalCount: Int
    /// Optional label, e.g. «عند الطعس الكبير».
    var label: String?
}

struct ParticipantsTabUIState: Equatable {
    /// Nil: no rally point. Leaders then see «حدد نقطة تجمع».
    var rally: RallyPointUI?
    /// Everyone including me. Order is kept as given (wiring decides: me first, then by distance).
    var participants: [ParticipantUI]
    /// I have not added my number: show «لم تضف رقمك · أضف رقمك ليتصل بك أصحابك».
    var myPhoneMissing: Bool
}

// MARK: - Invite tab

struct InviteTabUIState: Equatable {
    /// Full invite URL; nil while it is being created/rotated.
    var link: String?
    /// Leader sees «إلغاء الرابط وإنشاء جديد».
    var canRevoke: Bool
    /// True while revoking/creating a new link.
    var isRevoking: Bool = false
}

// MARK: - Settings tab

struct OfflineAreaUI: Equatable, Identifiable {
    var id: String
    var name: String
    var sizeBytes: Int64
    /// Nil when ready; 0...1 while downloading.
    var downloadProgress: Double?
}

struct OfflineAreasUIState: Equatable {
    var areas: [OfflineAreaUI]
    /// True while the current map area is being saved.
    var isSavingCurrent: Bool = false
}

struct SettingsTabUIState: Equatable {
    /// My sharing switch: true = paused («أوقف مشاركة موقعي» is on).
    var isSharingPaused: Bool
    var driveMode: TriModeUI
    var nightMode: TriModeUI
    /// Normalised "05XXXXXXXX" or nil.
    var myPhone: String?
    var notificationsOn: Bool
    var batterySharingOn: Bool
    var offline: OfflineAreasUIState
    /// Leader-only actions: «أوقف مؤقتًا» / «استأنف» and «أنهِ الطلعة».
    var isLeader: Bool
    /// Needed to label pause/resume.
    var outingStatus: OutingStatusUI
}

// MARK: - Screen

struct LiveOutingUIState: Equatable {
    var outingName: String
    var status: OutingStatusUI
    var connection: ConnectionStateUI
    var sharing: MySharingUI
    /// Shown when the top bar is expanded; a warning badge appears when non-empty.
    var warnings: [LiveWarningUI]
    /// Stacked under the top bar, newest first. At most 3 are shown.
    var alerts: [LiveAlertUI]
    var ptt: PTTStateUI
    var sos: SOSUIState
    var sheetDetent: SheetDetentUI
    var selectedTab: LiveTabUI
    var participantsTab: ParticipantsTabUIState
    var inviteTab: InviteTabUIState
    var settingsTab: SettingsTabUIState
    /// Clock for "قبل ٤ د" labels. Tick it (e.g. every 15 s) from the wiring layer.
    var now: Date
}

struct LiveOutingActions {
    // Top bar
    /// Back. Expect: leave the screen (the existing app confirms before it stops sharing).
    var back: () -> Void = {}
    /// A warning row tapped (e.g. open Settings for `.locationOff`).
    var warningTapped: (_ warning: LiveWarningUI) -> Void = { _ in }

    // Alert lane
    /// An alert tapped. Expect: e.g. show that participant on the map.
    var alertTapped: (_ id: String) -> Void = { _ in }
    /// The × on an alert. Expect: remove it from `alerts`.
    var dismissAlert: (_ id: String) -> Void = { _ in }
    /// Voice banners in the lane.
    var voice: VoiceBannerActions = .init()

    // Side buttons
    /// «موقعي» (`outing-locate`). Expect: centre the map on me.
    var locateMe: () -> Void = {}
    /// «المجموعة» (`outing-fit`). Expect: fit everyone on the map.
    var fitGroup: () -> Void = {}
    /// «رسالة» (`outing-note-open`). Expect: present `NoteComposerScreen`.
    var openNoteComposer: () -> Void = {}
    /// «أقرب محطة» (`outing-nearest-open`). Expect: present `NearestStationsScreen`.
    var openNearestStations: () -> Void = {}

    /// «طوارئ» button, my red strip and incoming alerts.
    var sos: SOSActions = .init()
    /// «اضغط وتكلم».
    var ptt: PTTActions = .init()

    // Sheet
    /// Drag on the handle / tap on the summary. Expect: set `sheetDetent`.
    var setSheetDetent: (_ detent: SheetDetentUI) -> Void = { _ in }
    /// Tab tapped. Expect: set `selectedTab`.
    var selectTab: (_ tab: LiveTabUI) -> Void = { _ in }

    var participantsTab: ParticipantsTabActions = .init()
    var inviteTab: InviteTabActions = .init()
    var settingsTab: SettingsTabActions = .init()
}

struct SOSActions {
    /// Fires ONLY after the 1 s hold on «طوارئ» completes (a shorter press does
    /// nothing). Expect: set `sos.mine = .sending`, then `.active(since:)`.
    var trigger: () -> Void = {}
    /// «أنا بخير» on my red strip. Expect: clear my SOS (`sos.mine = .none`).
    var imOK: () -> Void = {}
    /// «أظهره» on an incoming alert or strip. Expect: set `acknowledged = true`
    /// and show that participant on the map.
    var show: (_ alertId: String) -> Void = { _ in }
    /// «اتصال» on an incoming alert. Expect: dial them.
    var call: (_ alertId: String) -> Void = { _ in }
}

struct PTTActions {
    /// Finger down on «اضغط وتكلم». Expect: `ptt = .arming` → `.recording(0)`.
    var pressBegan: () -> Void = {}
    /// Finger up on the button. Expect: `ptt = .sending` → `.idle`.
    var pressEnded: () -> Void = {}
    /// Finger dragged far off the button before release. Expect: discard, `ptt = .idle`.
    var cancelled: () -> Void = {}
}

struct VoiceBannerActions {
    /// Play/stop tapped. Expect: toggle playback and update `VoiceClipUI.playback`.
    var play: (_ clipId: String) -> Void = { _ in }
    /// × tapped. Expect: remove the banner (the clip stays in history if you keep one).
    var dismiss: (_ clipId: String) -> Void = { _ in }
}

struct ParticipantsTabActions {
    /// A row tapped. Expect: present `ParticipantCardScreen` for that id.
    var openParticipant: (_ id: String) -> Void = { _ in }
    /// «أضف رقمك». Expect: switch to the settings tab or ask for the number,
    /// then call `SettingsTabActions.saveMyPhone`.
    var addMyPhone: () -> Void = {}
    /// Rally «أظهرها»: centre the map on the rally point.
    var rallyShow: () -> Void = {}
    /// Rally «اتجه»: open directions to it.
    var rallyGo: () -> Void = {}
    /// Rally «نقل» (leader/co-leader): enter "pick a new point" on the map.
    var rallyMove: () -> Void = {}
    /// Rally «إزالة» (leader/co-leader), after the UI's confirmation dialog.
    var rallyRemove: () -> Void = {}
    /// «حدد نقطة تجمع» (leader/co-leader, when there is none).
    var rallyCreate: () -> Void = {}
}

struct InviteTabActions {
    /// «نسخ». Expect: copy the link to the pasteboard (the UI flashes «تم النسخ»).
    var copyLink: () -> Void = {}
    /// «مشاركة». Expect: present the system share sheet with the link.
    var shareLink: () -> Void = {}
    /// «إلغاء الرابط وإنشاء جديد» (leader), after the UI's confirmation.
    /// Expect: `isRevoking = true`, then the new `link`.
    var revokeLink: () -> Void = {}
}

struct SettingsTabActions {
    /// My sharing switch. `paused == true` means stop sharing my location.
    var setSharingPaused: (_ paused: Bool) -> Void = { _ in }
    var setDriveMode: (_ mode: TriModeUI) -> Void = { _ in }
    var setNightMode: (_ mode: TriModeUI) -> Void = { _ in }
    /// «حفظ» my number: normalised "05XXXXXXXX", or nil to remove it.
    var saveMyPhone: (_ phone: String?) -> Void = { _ in }
    var setNotifications: (_ on: Bool) -> Void = { _ in }
    var setBatterySharing: (_ on: Bool) -> Void = { _ in }
    /// Offline maps section (same actions as `OfflineAreasScreen`).
    var offline: OfflineAreasActions = .init()
    /// Leader: «أوقف مؤقتًا» / «استأنف الطلعة», after confirmation.
    var pauseOrResumeOuting: () -> Void = {}
    /// Leader: «أنهِ الطلعة», after confirmation.
    var endOuting: () -> Void = {}
    /// «غادر الطلعة», after confirmation.
    var leaveOuting: () -> Void = {}
}

struct OfflineAreasActions {
    /// «احفظ المنطقة الظاهرة». Expect: start an offline pack for the visible area.
    var saveCurrentArea: () -> Void = {}
    /// Delete, called after the UI's confirmation.
    var deleteArea: (_ id: String) -> Void = { _ in }
    /// Standalone `OfflineAreasScreen` only: «تم».
    var close: () -> Void = {}
}
