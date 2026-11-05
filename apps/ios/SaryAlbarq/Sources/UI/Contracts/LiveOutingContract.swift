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
    /// Lovable: «الخريطة» · «العيال» · «الرحلة» in the sheet; «المزيد» (the settings) behind the
    /// header's gear.
    case trip, group, more, map

    /// The sheet's segmented tabs, right to left.
    static let sheetTabs: [LiveTabUI] = [.map, .group, .trip]

    var label: String {
        switch self {
        case .map: return "الخريطة"
        case .trip: return "الرحلة"
        case .group: return "العيال"
        case .more: return "الإعدادات"
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
    /// iOS «الموقع الدقيق» is off: positions and «مساري» are kilometres off.
    case preciseOff

    var label: String {
        switch self {
        case .weakGPS: return "إشارة الموقع ضعيفة"
        case .noInternet: return "بلا إنترنت · نرسل موقعك أول ما يرجع الاتصال"
        case .keepScreenOn: return "تتوقف المشاركة إذا قفلت الشاشة · اختر «دائمًا»"
        case .locationOff: return "إذن الموقع مقفل · افتح الإعدادات"
        case .preciseOff: return "فعّل الموقع الدقيق · مسارك تقريبي الآن"
        }
    }
}

/// One persistent line under my sharing row: what happens off screen.
enum ShareBackgroundHint: Equatable {
    /// «أثناء الاستخدام» only: sharing stops when the screen locks. Tapping opens Settings.
    case needsAlways
    /// «دائمًا»: sharing keeps going; the one thing that stops it is swiping the app away.
    case dontForceQuit
    /// «دائمًا» + Low Power Mode: still sharing, a little less often.
    case lowPower
    /// Joined (sharing by default) but iOS location is refused: the one-line fix. Tapping opens Settings.
    case denied

    var text: String {
        switch self {
        case .denied: return "ما سمحت بالموقع، فأعضاء الطلعة ما يشوفونك. افتح الإعدادات ← الموقع ← «أثناء الاستخدام»."
        case .needsAlways: return "تتوقف المشاركة إذا قفلت الشاشة. اختر «دائمًا» من الإعدادات لتستمر."
        case .dontForceQuit: return "تستمر والشاشة مقفلة. لا تقفل التطبيق من قائمة التطبيقات أثناء الطلعة."
        case .lowPower: return "وضع توفير الطاقة: تستمر والشاشة مقفلة، لكن أقل تكرارًا (كل ٣٠ ثانية تقريبًا)."
        }
    }

    var systemImage: String {
        switch self {
        case .denied: return "location.slash.fill"
        case .needsAlways: return "gearshape.fill"
        case .dontForceQuit: return "lock.iphone"
        case .lowPower: return "battery.25percent"
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
    /// Convoy mode: someone out of the column (see `ConvoyAlertUI`).
    case convoy(ConvoyAlertUI)
    /// Wind / dust / rain / «احذر السيول في الأودية» (Sources/Weather).
    case weather(WeatherAlertUI)
    /// «انقطع إرسال فهد منذ ١٠ د» with «اتجه» / «اتصال» (SarySilentCard.swift).
    case silent(SilentAlertUI)
    /// «اسلك هذا المسار»: more than 50 m off the followed track for over 10 s.
    case offTrack(FollowDeviationAlertUI)
}

struct LiveAlertUI: Equatable, Identifiable {
    var id: String
    var kind: LiveAlertKindUI
}

// MARK: - Push-to-talk

/// ONE enum for the walkie-talkie button («قناة الطلعة»). No extra flags.
enum PTTStateUI: Equatable {
    /// Nobody on air: hold to talk.
    case idle
    /// Pressed; asking for the floor («جارٍ فتح القناة…»).
    case arming
    /// I am on air, live; elapsed and remaining whole seconds (60 s max).
    case talking(seconds: Int, remaining: Int)
    /// Someone else is on air: «فلان يتكلم» (the button is busy, not disabled).
    case listening(name: String, color: UInt32)
    /// «اكتم القناة» is on.
    case muted
    /// No server and no nearby car: nothing to talk to.
    case unavailable
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
    /// Who is there now (live fix inside the radius).
    var arrivedNames: [String] = []
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
    /// Not sharing right now (no switch since build 14: a member shares while the trip runs).
    var isSharingPaused: Bool
    var driveMode: TriModeUI
    var nightMode: TriModeUI
    /// Normalised "05XXXXXXXX" or nil.
    var myPhone: String?
    var notificationsOn: Bool
    var batterySharingOn: Bool
    /// «اكتم القناة»: no live voice in or out for this outing on this phone.
    var pttMuted: Bool = false
    /// The live link in one Arabic line («متصل منذ 3 د» / «يعيد الاتصال…» · last close code).
    var pttLink: String = ""
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
    /// Members' cars heard directly phone to phone in the last 30 s (0 = none / link off).
    var nearbyCars: Int = 0
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
    /// «انقطع الإرسال» cards: «اتجه» / «اتصال».
    var silent: SilentAlertActions = .init()

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
    /// Finger down. Expect: `ptt = .arming` → `.talking` once the floor is granted (live audio).
    var pressBegan: () -> Void = {}
    /// Finger up (or dragged away — live audio cannot be taken back). Expect: off the air, `.idle`.
    var pressEnded: () -> Void = {}
    /// Same as `pressEnded` for live talk (kept for the contract's older callers).
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
    /// «ارجعوا لنقطة التجمع» (leaders; nil hides it).
    var rallyRecall: (() -> Void)? = nil
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
    var setDriveMode: (_ mode: TriModeUI) -> Void = { _ in }
    var setNightMode: (_ mode: TriModeUI) -> Void = { _ in }
    /// «حفظ» my number: normalised "05XXXXXXXX", or nil to remove it.
    var saveMyPhone: (_ phone: String?) -> Void = { _ in }
    var setNotifications: (_ on: Bool) -> Void = { _ in }
    var setBatterySharing: (_ on: Bool) -> Void = { _ in }
    /// «اكتم القناة».
    var setPTTMuted: (_ on: Bool) -> Void = { _ in }
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

// MARK: - «مساري» and «طريق العودة»

/// The back-track panel (big arrow + distance back to «نقطة البداية» along my trail).
struct BackTrackUI: Equatable {
    enum Phase: Equatable {
        /// No recent GPS fix yet.
        case waitingFix
        case onTrail
        /// More than ~60 m from my trail: «خرجت عن الطريق».
        case offTrack
        case arrived
    }

    var phase: Phase
    /// Along the trail back to the start (plus the way back onto it).
    var remainingMeters: Double?
    /// My distance from the trail.
    var offsetMeters: Double?
    /// Arrow rotation, degrees clockwise from the top of the screen (or from my heading when `relativeToCourse`).
    var arrowDegrees: Double
    /// The compass direction to go, in words («شمال غرب»).
    var directionLabel: String
    var relativeToCourse: Bool
    /// I am on a stretch that was not recorded (straight dashed line).
    var onGap: Bool
}

/// «اسلك هذا المسار»: the follow panel (off-road, along any saved track).
struct FollowTrackUI: Equatable {
    enum Phase: Equatable {
        /// No recent GPS fix yet (an old one is never used).
        case waitingFix
        case onTrack
        /// More than 50 m from the track for over 10 s: «خرجت عن المسار».
        case offTrack
        /// More than 2 km from the whole track: offer to navigate to its nearest point (online).
        case far
        case arrived
    }

    var name: String
    var phase: Phase
    /// Along the track to its end.
    var remainingMeters: Double?
    /// 0…1 of the track behind me.
    var progress: Double?
    /// My distance from the track.
    var offsetMeters: Double?
    var arrowDegrees: Double
    var directionLabel: String
    var relativeToCourse = false
    /// On a stretch that was not recorded (straight dashed line).
    var onGap: Bool
    /// Followed backwards («اعكس الاتجاه»).
    var reversed: Bool
    /// Navigating to the track needs the internet (routing); the follow itself does not.
    var online: Bool
}

/// The one «خرجت عن المسار» card in the alert queue.
struct FollowDeviationAlertUI: Equatable {
    var trackName: String
    var meters: Double
}

/// «مساري» card in the sheet and its settings.
struct TrailCardUIState: Equatable {
    var recordedMeters: Double
    var pointCount: Int
    var gapCount: Int
    /// Straight-line distance from me to «نقطة البداية».
    var startDistanceMeters: Double?
    var isRecording: Bool
    var recordingOn: Bool
    var backgroundOn: Bool
    /// iOS allows «دائمًا» (needed for the screen-locked trail).
    var backgroundAllowed: Bool
    var recordingInBackground: Bool
    var showFriends: Bool
    var backTrackActive: Bool
    /// While recording: «الدقة ±٨ م · ١٢ نقطة/دقيقة» and what to fix.
    var health: TrailHealth? = nil
    /// «طابق مساري مع الطرق».
    var matchOn = true
}
