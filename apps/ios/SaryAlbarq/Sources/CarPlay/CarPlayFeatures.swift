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
protocol CarPlayFeatureSource: AnyObject {
    func carPlayDestination() -> CarPlayDestination?
    func carPlayStuckMembers() -> [CarPlayStuck]
    func carPlayConvoy() -> CarPlayConvoy?
    /// «غرّزت» is offered on CarPlay only when this is true.
    var carPlayStuckReportSupported: Bool { get }
    /// «غرّزت» from the car. Return false when the feature is not available.
    func carPlayReportStuck() -> Bool
}

extension CarPlayFeatureSource {
    func carPlayDestination() -> CarPlayDestination? { nil }
    func carPlayStuckMembers() -> [CarPlayStuck] { [] }
    func carPlayConvoy() -> CarPlayConvoy? { nil }
    var carPlayStuckReportSupported: Bool { false }
    func carPlayReportStuck() -> Bool { false }
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
}

extension CarPlayRoadNavigationSource {
    func carPlayStartRoadRoute(to target: LngLat, label: String) -> Bool { false }
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
