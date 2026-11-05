import CoreLocation
import Foundation

/// Owner decision (build 14): the invitee's onboarding is ONE step. The invite screen says who
/// invited you and where to, and under «انضم للطلعة» one honest line: members see your live
/// location until the trip ends or you leave. Tapping it is the whole onboarding:
///
///   1. no identity yet → made silently with the name the inviter gave (personal invite);
///   2. iOS location (When In Use, precise) is asked right away — the only prompt at join;
///   3. granted → POST /invites/join → the live trip, sharing ON (no toggle, no consent sheet);
///   4. refused, or «الموقع الدقيق» off → the server join does NOT happen; one calm screen
///      («الطلعة تحتاج موقعك عشان أصحابك يشوفونك», «افتح الإعدادات» / «إلغاء»); the moment iOS
///      says granted (back from Settings) it joins and enters by itself.
///
/// «دائمًا» is never asked here (Apple: it cannot be forced); it comes later, in context.
/// Notifications and the microphone are not asked at join either.
enum JoinPermission: Equatable {
    /// iOS has not asked yet.
    case notAsked
    /// When In Use or Always, with precise location.
    case granted
    /// Allowed, but «الموقع الدقيق» is off: kilometres off, friends cannot find you.
    case reduced
    /// Refused or restricted.
    case denied

    static func from(_ status: CLAuthorizationStatus, _ accuracy: CLAccuracyAuthorization) -> JoinPermission {
        switch status {
        case .notDetermined: return .notAsked
        case .authorizedWhenInUse, .authorizedAlways: return accuracy == .fullAccuracy ? .granted : .reduced
        default: return .denied
        }
    }
}

enum JoinStep: Equatable {
    /// The one screen: who invited you, the trip, «انضم للطلعة».
    case ready
    /// Making the identity silently (first time on this phone).
    case preparing
    /// The iOS location prompt is up (or about to be answered with what iOS already knows).
    case askingLocation
    /// Not joined: the calm «افتح الإعدادات» screen, until iOS says granted.
    case needsLocation(JoinPermission)
    /// POST /invites/join.
    case joining
    /// In the live trip, sharing on.
    case entered
    /// «إلغاء» / «ليس الآن»: nothing kept.
    case cancelled
    /// Back on the one screen with this error under the button.
    case failed(String)

    /// The button spins.
    var busy: Bool { self == .preparing || self == .askingLocation || self == .joining }
}

enum JoinEvent: Equatable {
    case tapJoin(hasIdentity: Bool)
    case identityReady
    case identityFailed(String)
    /// The answer to the prompt (or iOS's current state when it will not ask again).
    case permission(JoinPermission)
    /// The app is on screen again (e.g. back from Settings) with this permission.
    case sceneActive(JoinPermission)
    case joined
    case joinFailed(String)
    case cancel
}

/// The join state machine: pure, so every path is unit tested (JoinFlowTests).
enum JoinMachine {
    static func next(_ s: JoinStep, _ e: JoinEvent) -> JoinStep {
        switch (s, e) {
        case (.ready, .tapJoin(let has)), (.failed, .tapJoin(let has)):
            return has ? .askingLocation : .preparing
        case (.preparing, .identityReady):
            return .askingLocation
        case (.preparing, .identityFailed(let m)):
            return .failed(m)
        case (.askingLocation, .permission(let p)), (.askingLocation, .sceneActive(let p)):
            return after(p, waiting: .askingLocation)
        case (.needsLocation, .permission(let p)), (.needsLocation, .sceneActive(let p)):
            return after(p, waiting: .needsLocation(.denied))
        case (.joining, .joined):
            return .entered
        case (.joining, .joinFailed(let m)):
            return .failed(m)
        case (.ready, .cancel), (.failed, .cancel), (.needsLocation, .cancel), (.askingLocation, .cancel):
            return .cancelled
        default:
            return s
        }
    }

    /// Granted → join; refused / imprecise → the calm screen; still unanswered → keep waiting.
    private static func after(_ p: JoinPermission, waiting: JoinStep) -> JoinStep {
        switch p {
        case .granted: return .joining
        case .reduced, .denied: return .needsLocation(p)
        case .notAsked: return waiting
        }
    }
}

/// The words of the join screen and the calm «افتح الإعدادات» screen (one place, tested).
enum JoinCopy {
    static let button = "انضم للطلعة"
    /// The honest line under the button (also on the creator's last step and «انضم برابط»).
    static let statement = "بانضمامك يشوف أعضاء الطلعة موقعك المباشر لين تنتهي الطلعة أو تغادرها"
    static let needsTitle = "الطلعة تحتاج موقعك عشان أصحابك يشوفونك"

    static func needsMessage(_ p: JoinPermission) -> String {
        switch p {
        case .reduced:
            return "«الموقع الدقيق» مقفل، فيظهر مكانك تقريبيًا بالكيلومترات. افتح الإعدادات ← الموقع وفعّل «الموقع الدقيق»، وترجع للطلعة على طول."
        default:
            return "افتح الإعدادات ← الموقع واختر «أثناء استخدام التطبيق» مع «الموقع الدقيق»، وترجع للطلعة على طول."
        }
    }

    static let openSettings = "افتح الإعدادات"
    static let cancel = "إلغاء"
}
