import Foundation

// Hooks for features that live on other branches (destination «الوجهة», «غرّزت», convoy,
// turn-by-turn road navigation).
// CarPlay reads them through `CarPlayFeatureSource`; every method has a default that
// means "this feature is not in this build", so the CarPlay module compiles and works
// on its own and a feature branch only has to conform and register:
//
//     extension LiveOutingController: CarPlayFeatureSource {
//         func carPlayDestination() -> CarPlayDestination? { … }
//     }
//     CarPlayFeatures.source = controller
//
// Nothing here talks to the network. CarPlay only shows what the phone already has.

/// The planned destination of the outing (plan/destination branch).
struct CarPlayDestination: Equatable {
    var position: LngLat
    /// Short label; empty means «الوجهة».
    var label: String = ""
}

/// A member who said «غرّزت» (stuck), with when they said it (safety branch).
struct CarPlayStuck: Equatable {
    var memberId: String
    var since: Date
    /// Where they are stuck, if their report carried a fix; else their last real fix is used.
    var position: LngLat?
}

/// The convoy picture (waypoints/convoy branch): who leads, who sweeps, and a gap warning.
struct CarPlayConvoy: Equatable {
    var leaderId: String?
    var sweepId: String?
    /// e.g. «سلطان بعيد عن القافلة ٢ كم»; nil when the convoy is together.
    var gapWarning: String?
}

/// What other features hand to CarPlay. All methods are optional (defaults below).
@MainActor
/// «الرحلة» as the phone decided it (`TripPresenter`): only what is true now.
struct CarPlayTripProgress: Equatable {
    /// 0...100.
    var percent: Int?
    /// Nil when my fix is too old to say.
    var remainingM: Double?
    /// The remaining distance is a straight line.
    var approximate: Bool
    var eta: Date?
    var arrived: Bool
}

protocol CarPlayFeatureSource: AnyObject {
    func carPlayDestination() -> CarPlayDestination?
    /// «قطعنا ٦٢٪ • باقي ١٢ كم • نوصل ٤:٣٠ م».
    func carPlayTripProgress() -> CarPlayTripProgress?
    func carPlayStuckMembers() -> [CarPlayStuck]
    func carPlayConvoy() -> CarPlayConvoy?
    /// «غرّزت» is offered on CarPlay only when this is true.
    var carPlayStuckReportSupported: Bool { get }
    /// «غرّزت» from the car. Return false when the feature is not available.
    func carPlayReportStuck() -> Bool
    /// Why a member's position is not live («الجوال مقفل», «بلا إنترنت», …) — presence
    /// reasons from fix/always-live (PR #114). Nil = no reason known (CarPlay shows the age only).
    func carPlayPresenceReason(_ memberId: String) -> String?
}

extension CarPlayFeatureSource {
    func carPlayDestination() -> CarPlayDestination? { nil }
    func carPlayTripProgress() -> CarPlayTripProgress? { nil }
    func carPlayStuckMembers() -> [CarPlayStuck] { [] }
    func carPlayConvoy() -> CarPlayConvoy? { nil }
    var carPlayStuckReportSupported: Bool { false }
    func carPlayReportStuck() -> Bool { false }
    func carPlayPresenceReason(_ memberId: String) -> String? { nil }
}

// MARK: - turn-by-turn road navigation (seam for feat/ios-navigation)

/// One road maneuver as CarPlay shows it (CPManeuver).
struct CarPlayRoadManeuver: Equatable {
    /// Spoken/visible instruction, already in Arabic («انعطف يمين على طريق الملك فهد»).
    var instruction: String
    /// Shorter variant for narrow CarPlay screens; nil reuses `instruction`.
    var shortInstruction: String?
    /// Metres from here to this maneuver.
    var distanceM: Double
    /// SF Symbol for the turn arrow («arrow.turn.up.right», …).
    var symbol: String
    /// The router's time for this step (traffic-aware with Mapbox), seconds; nil = unknown.
    var durationS: Double? = nil
    /// Lanes at this maneuver (empty = no lane data).
    var lanes: [NavLane] = []
    /// `CPManeuverType` name («rightTurn», «roundaboutExit2», …); nil = not known.
    var cpManeuverType: String? = nil
}

/// One road route offered on the trip preview («الأسرع», «الأقصر»).
struct CarPlayRouteOption: Equatable {
    var id: String
    var distanceM: Double
    var durationS: Double
    /// «عبر طريق الملك فهد».
    var via: String?
    var hasUnpaved = false
    /// The route geometry (the preview draws the selected one).
    var line: [LngLat] = []
}

/// Progress of the active road route (CPTravelEstimates + upcoming maneuvers).
struct CarPlayRoadProgress: Equatable {
    var destinationLabel: String
    var remainingM: Double
    var remainingS: Double
    /// Next maneuver first; CarPlay shows the first one or two.
    var maneuvers: [CarPlayRoadManeuver]
    /// The route geometry, for the map line (optional).
    var routeLine: [LngLat] = []
    /// The driver left the route and the provider is rerouting.
    var rerouting = false
}

/// The turn-by-turn provider (Mapbox Navigation SDK v3, built on feat/ios-navigation).
/// That branch's `NavigationSessionProviding` adopts this with a small extension; while a
/// road route is active CarPlay drives its CPNavigationSession from it, and falls back to
/// the trail-based «طريق العودة» and the straight-line rally / destination guidance when
/// no road route exists (off-road, no network, no road near the target).
@MainActor
protocol CarPlayRoadNavigationSource: AnyObject {
    /// A road route is being followed right now.
    var carPlayRoadActive: Bool { get }
    func carPlayRoadProgress() -> CarPlayRoadProgress?
    /// Ask for a road route to a point; false when no road route can be made (CarPlay then
    /// keeps the straight-line guidance). Default: not available.
    func carPlayStartRoadRoute(to target: LngLat, label: String) -> Bool
    /// «إنهاء» on CarPlay.
    func carPlayStopRoadRoute()
    /// Plan road routes to a point WITHOUT starting guidance (the CarPlay trip preview).
    /// `memberId`: «روح لفلان». False when no road routing exists.
    func carPlayPlanRoadRoute(to target: LngLat, label: String, memberId: String?) -> Bool
    /// The planned routes, best first; empty while planning or when routing failed.
    func carPlayRouteOptions() -> [CarPlayRouteOption]
    /// Planning ended without a road route (no road near, no network): CarPlay falls back.
    var carPlayPlanFailed: Bool { get }
    /// «يلّا» on the preview: start guidance on that route.
    func carPlayStartGuidance(routeId: String)
}

extension CarPlayRoadNavigationSource {
    func carPlayStartRoadRoute(to target: LngLat, label: String) -> Bool { false }
    func carPlayPlanRoadRoute(to target: LngLat, label: String, memberId: String?) -> Bool { false }
    func carPlayRouteOptions() -> [CarPlayRouteOption] { [] }
    var carPlayPlanFailed: Bool { false }
    func carPlayStartGuidance(routeId: String) {}
}

// MARK: - walkie-talkie in the car (seam over VoiceNoteCenter)

/// «أبو فهد يتكلم» and «اضغط وسجّل» from the car. The phone's `VoiceNoteCenter` adopts it
/// (CarPlayWiring.swift); playback goes through the phone's own audio session, which iOS
/// routes to the car speakers.
@MainActor
protocol CarPlayWalkieSource: AnyObject {
    /// The note playing right now (someone else's): id + display name.
    var carPlayTalking: (id: String, userId: String, name: String)? { get }
    var carPlayRecording: Bool { get }
    /// Idle → start recording; recording → send (the phone's own talk button).
    func carPlayTalkTapped()
    func carPlayCancelRecording()
    func carPlayStopPlaying()
}

/// Where feature branches register. Weak: CarPlay never keeps a screen's controller alive.
@MainActor
enum CarPlayFeatures {
    static weak var source: CarPlayFeatureSource? {
        didSet { NotificationCenter.default.post(name: .saryCarPlayFeaturesChanged, object: nil) }
    }

    /// Turn-by-turn provider; nil = straight-line / trail guidance only.
    static weak var roadNavigation: CarPlayRoadNavigationSource? {
        didSet { NotificationCenter.default.post(name: .saryCarPlayFeaturesChanged, object: nil) }
    }

    /// A feature's data changed (call from the feature when its value moves).
    static func changed() { NotificationCenter.default.post(name: .saryCarPlayFeaturesChanged, object: nil) }
}

extension Notification.Name {
    static let saryCarPlayFeaturesChanged = Notification.Name("sary.carplay.features")
}
