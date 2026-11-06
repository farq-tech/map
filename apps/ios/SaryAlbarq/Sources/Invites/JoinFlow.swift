import CoreLocation
import Foundation

/// The invitee's way in (build 14, tightened in build 21): from the link to «I'm live in the trip»
/// in as few taps as iOS allows. The invite screen says who invited you, the trip and where to, and
/// — when iOS has not asked yet — the Najdi pre-prompt «عشان العيال يشوفونك وتوصلك الفزعة» right
/// above «انضم للطلعة». Tapping it is the whole onboarding:
///
///   1. no identity yet → made silently with the name the inviter gave (personal invite);
///   2. iOS location (When In Use) is asked right away — the system prompt follows the pre-prompt;
///   3. «الموقع الدقيق» off → iOS's one-time «دقيق مؤقتًا» request with our purpose key (`JoinTrip`);
///   4. granted + precise → POST /invites/join → the live trip, sharing ON (no toggle, no consent sheet);
///   5. refused / still approximate → the recovery screen: «افتح الإعدادات» (joins and enters by itself
///      the moment iOS says yes) or «ادخل الطلعة بدون موقعي» — joined in view mode: the map, the convoy,
///      the walkie-talkie, with «موقعك مو ظاهر للعيال» on the map until the location is on. No dead end.
///
/// «دائمًا» is never asked here (Apple: it cannot be forced); it comes later, in the trip.
/// Notifications and the microphone are not asked at join either.
/// Owner switches for the invitee's way in.
enum JoinFlags {
    /// «ادخل الطلعة بدون موقعي» (build 21, awaiting the owner's decision): refused / approximate
    /// location can still open the trip in view mode. `false` = back to build 14 (not joined
    /// until iOS allows the location; the recovery screen offers only «افتح الإعدادات» / «إلغاء»).
    static let viewOnlyJoin = true
}

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
    /// The one screen: who invited you, the trip, «انضم للطلعة» (with the pre-prompt if iOS never asked).
    case ready
    /// Making the identity silently (first time on this phone).
    case preparing
    /// The iOS location prompt is up (or about to be answered with what iOS already knows).
    case askingLocation
    /// Allowed but «الموقع الدقيق» off: iOS's temporary full-accuracy prompt is up.
    case askingPrecise
    /// Not joined yet: the recovery screen («افتح الإعدادات» / «ادخل الطلعة بدون موقعي»).
    case needsLocation(JoinPermission)
    /// POST /invites/join. `viewOnly`: chosen from the recovery screen — in the trip, location hidden.
    case joining(viewOnly: Bool)
    /// In the live trip (sharing on, or waiting for the location in view mode).
    case entered
    /// «إلغاء» / «ليس الآن»: nothing kept.
    case cancelled
    /// Back on the one screen with this error under the button.
    case failed(String)

    /// The button spins.
    var busy: Bool {
        switch self {
        case .preparing, .askingLocation, .askingPrecise, .joining: return true
        default: return false
        }
    }
}

enum JoinEvent: Equatable {
    case tapJoin(hasIdentity: Bool)
    case identityReady
    case identityFailed(String)
    /// The answer to the prompt (or iOS's current state when it will not ask again).
    case permission(JoinPermission)
    /// The answer to the temporary «الموقع الدقيق» prompt.
    case precise(JoinPermission)
    /// The app is on screen again (e.g. back from Settings) with this permission.
    case sceneActive(JoinPermission)
    /// «ادخل الطلعة بدون موقعي» on the recovery screen.
    case enterWithoutLocation
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
            return afterPrompt(p)
        case (.askingPrecise, .precise(let p)):
            return p == .notAsked ? s : afterPrecise(p)
        case (.askingPrecise, .sceneActive(.granted)), (.askingPrecise, .permission(.granted)):
            /* The prompt closed and iOS already reports full accuracy. */
            return .joining(viewOnly: false)
        case (.needsLocation, .permission(let p)), (.needsLocation, .sceneActive(let p)):
            /* Back from Settings: granted → in, by itself. Never a prompt loop from here. */
            switch p {
            case .granted: return .joining(viewOnly: false)
            case .reduced, .denied: return .needsLocation(p)
            case .notAsked: return s
            }
        case (.needsLocation, .enterWithoutLocation):
            return JoinFlags.viewOnlyJoin ? .joining(viewOnly: true) : s
        case (.joining, .joined):
            return .entered
        case (.joining, .joinFailed(let m)):
            return .failed(m)
        case (.ready, .cancel), (.failed, .cancel), (.needsLocation, .cancel), (.askingLocation, .cancel), (.askingPrecise, .cancel):
            return .cancelled
        default:
            return s
        }
    }

    /// The When-In-Use answer: granted → join; approximate → ask for precise; refused → recovery.
    private static func afterPrompt(_ p: JoinPermission) -> JoinStep {
        switch p {
        case .granted: return .joining(viewOnly: false)
        case .reduced: return .askingPrecise
        case .denied: return .needsLocation(.denied)
        case .notAsked: return .askingLocation
        }
    }

    /// The temporary full-accuracy answer: precise → join; still approximate → recovery.
    private static func afterPrecise(_ p: JoinPermission) -> JoinStep {
        p == .granted ? .joining(viewOnly: false) : .needsLocation(p)
    }
}

/// The words of the join screen, the pre-prompt and the recovery screen (one place, tested).
enum JoinCopy {
    static let button = "انضم للطلعة"
    /// The honest line under the button (also on the creator's last step and «انضم برابط»).
    static let statement = "بانضمامك يشوف أعضاء الطلعة موقعك المباشر لين تنتهي الطلعة أو تغادرها"

    /// The Najdi pre-prompt, right above «انضم للطلعة» while iOS has not asked yet.
    static let prePromptTitle = "عشان العيال يشوفونك وتوصلك الفزعة"
    static let prePromptDetail = "بعد «انضم» يسألك الآيفون عن موقعك: اختر «السماح أثناء استخدام التطبيق» وخلّ «الموقع الدقيق» شغّال."

    static func needsTitle(_ p: JoinPermission) -> String {
        p == .reduced ? "موقعك تقريبي بالكيلومترات" : "موقعك مقفل، والعيال ما راح يشوفونك"
    }

    static func needsMessage(_ p: JoinPermission) -> String {
        switch p {
        case .reduced:
            return "«الموقع الدقيق» مقفل، فما يقدر العيال يلقونك ولا توصلك الفزعة. افتح الإعدادات ← الموقع وشغّل «الموقع الدقيق»، وترجع للطلعة على طول."
        default:
            return "افتح الإعدادات ← الموقع واختر «أثناء استخدام التطبيق» مع «الموقع الدقيق»، وترجع للطلعة على طول."
        }
    }

    static let openSettings = "افتح الإعدادات"
    /// View mode: in the trip, nothing of mine is sent until the location is on.
    static let enterWithout = "ادخل الطلعة بدون موقعي"
    static let enterWithoutNote = "تشوف العيال والوجهة واللاسلكي، بس موقعك مو ظاهر لهم لين تشغّله."
    static let cancel = "إلغاء"

    /// On the map while my position is not reaching the group (refused, or approximate only).
    static let hiddenTitle = "موقعك مو ظاهر للعيال"
    static func hiddenDetail(_ p: JoinPermission) -> String {
        p == .reduced ? "«الموقع الدقيق» مقفل" : "إذن الموقع مقفل"
    }
}
