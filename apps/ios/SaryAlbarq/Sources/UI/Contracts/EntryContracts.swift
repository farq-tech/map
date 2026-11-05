import SwiftUI
import UIKit

// Contracts for the screens before the live map: first launch, my outings,
// new outing, invite/join and account recovery.

// MARK: - Onboarding (first launch)

enum OnboardingStepUI: Equatable {
    /// One-line idea + «ابدأ».
    case intro
    /// Name (≤ 40), optional photo and Saudi mobile.
    case profile
    /// Explains location before the system prompt: «نستخدم موقعك أثناء الطلعة فقط».
    case locationExplainer
}

struct OnboardingUIState: Equatable {
    /// Which step is on screen. The wiring layer advances it.
    var step: OnboardingStepUI = .intro
    /// Pre-fill for the name field (e.g. from a previous attempt).
    var initialName: String = ""
    /// Pre-fill for the phone field.
    var initialPhone: String = ""
    /// Photo chosen through `pickPhoto` (nil = initials).
    var photo: UIImage?
    /// True while the profile is being saved: the button shows a spinner.
    var isSubmitting: Bool = false
    /// Arabic error from saving the profile, shown under the form.
    var errorMessage: String?
}

struct OnboardingActions {
    /// «ابدأ» on the intro step. Expect: set `step = .profile`.
    var start: () -> Void = {}
    /// Avatar tapped. Expect: present a photo picker, then set `state.photo`.
    var pickPhoto: () -> Void = {}
    /// «إزالة الصورة». Expect: set `state.photo = nil`.
    var removePhoto: () -> Void = {}
    /// «متابعة» on the profile step. `name` is trimmed, 1...40 chars; `phone` is
    /// nil or already normalised to "05XXXXXXXX" (`SaryFormat.normalizeSaudiMobile`).
    /// Expect: save the identity, then set `step = .locationExplainer`.
    var submitProfile: (_ name: String, _ phone: String?) -> Void = { _, _ in }
    /// «اسمح بالموقع». Expect: ask the system for location permission, then leave onboarding.
    var allowLocation: () -> Void = {}
    /// «ليس الآن» on the location step. Expect: leave onboarding without asking.
    var skipLocation: () -> Void = {}
    /// «عندي حساب سابق» on intro. Expect: show the Recovery screen.
    var openRecovery: () -> Void = {}
}

// MARK: - My outings («طلعاتي»)

struct OutingRowUI: Equatable, Identifiable {
    var id: String
    var name: String
    var status: OutingStatusUI
    var participantCount: Int
    /// I own the outing («أمير الرحلة»).
    var isLeader: Bool
}

struct OutingsListUIState: Equatable {
    /// `.empty` shows the "create your first outing" invitation.
    var phase: LoadPhaseUI<[OutingRowUI]> = .loading
    /// Device has no internet: a grey banner, the cached list stays visible.
    var isOffline: Bool = false
    /// My display name, shown in the header.
    var myName: String = ""
}

struct OutingsListActions {
    /// Row tapped. Expect: open the live outing with this id.
    var openOuting: (_ id: String) -> Void = { _ in }
    /// «طلعة جديدة». Expect: present `NewOutingScreen`.
    var newOuting: () -> Void = {}
    /// «انضم برابط». Expect: read the pasteboard / ask for a link, then show `InviteJoinScreen`.
    var joinByLink: () -> Void = {}
    /// «حاول مرة ثانية» in the error state, and pull-to-refresh.
    var retry: () -> Void = {}
    /// Profile button in the header. Expect: show the profile / my number.
    var openProfile: () -> Void = {}
}

// MARK: - New outing (sheet)

struct NewOutingUIState: Equatable {
    /// Pre-fill for the name field.
    var initialName: String = ""
    /// True while creating: the button spins and the field is disabled.
    var isCreating: Bool = false
    var errorMessage: String?
    /// Max name length.
    var maxLength: Int = 60
}

struct NewOutingActions {
    /// «أنشئ الطلعة». `name` is trimmed and non-empty. Expect: create, then open it.
    var create: (_ name: String) -> Void = { _ in }
    /// «إلغاء». Expect: dismiss the sheet.
    var cancel: () -> Void = {}
}

// MARK: - Invite / join

struct InvitePreviewUI: Equatable {
    var outingName: String
    /// Who invited me: «دعاك أبو فهد».
    var inviterName: String
    var participantCount: Int
    var status: OutingStatusUI
    /// «دعوة شخصية»: the name the leader gave me — I join as this person.
    var inviteeName: String? = nil
}

enum InvitePhaseUI: Equatable {
    case loading
    case ready(InvitePreviewUI)
    /// The link was revoked or timed out.
    case expired
    /// The link is malformed or unknown.
    case invalid
    /// A personal invite someone else already used: «هذه الدعوة لشخص آخر».
    case taken
    /// Network or server error, retryable.
    case error(String)
}

struct InviteJoinUIState: Equatable {
    var phase: InvitePhaseUI = .loading
    /// My saved name. Nil = no identity yet: a name field is shown and the
    /// button reads «انضم للطلعة»; otherwise «انضم باسم …».
    var myName: String?
    /// True while joining: the button spins.
    var isJoining: Bool = false
    var errorMessage: String?
}

struct InviteJoinActions {
    /// «انضم». `name` is nil when `state.myName` exists, otherwise the typed
    /// name (trimmed, 1...40). Expect: create identity if needed, join, open the outing.
    var join: (_ name: String?) -> Void = { _ in }
    /// «ليس الآن». Expect: dismiss, keep nothing.
    var notNow: () -> Void = {}
    /// «حاول مرة ثانية» for `.error`.
    var retry: () -> Void = {}
}

// MARK: - Recovery

enum RecoveryPhaseUI: Equatable {
    /// Enter the recovery code or scan the QR from the old device.
    case enterCode
    /// Restoring: spinner, inputs disabled.
    case restoring
    /// Arabic error, the form stays editable.
    case error(String)
    /// Restored as this name.
    case restored(name: String)
}

struct RecoveryUIState: Equatable {
    var phase: RecoveryPhaseUI = .enterCode
    /// Expected code length (characters, ignoring dashes/spaces).
    var codeLength: Int = 12
}

struct RecoveryActions {
    /// «استرجع». `code` is uppercased with spaces/dashes removed.
    var submitCode: (_ code: String) -> Void = { _ in }
    /// «امسح رمز QR من جهازك القديم». Expect: present a camera scanner, then call
    /// `submitCode` yourself with the scanned code.
    var scanQR: () -> Void = {}
    /// «متابعة» after `.restored`. Expect: go to «طلعاتي».
    var finish: () -> Void = {}
    /// «إلغاء». Expect: go back to onboarding.
    var cancel: () -> Void = {}
}
