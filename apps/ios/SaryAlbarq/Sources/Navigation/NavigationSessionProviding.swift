import Combine
import Foundation

/// What the CarPlay layer (feat/ios-carplay, custom templates) consumes. There is
/// no second CarPlay UI here: CarPlay renders the SAME navigation the phone runs.
///
/// Wiring it to CarPlay's own navigation types (in the CarPlay branch, which imports CarPlay):
///
/// ```swift
/// // When `snapshot.phase` becomes .guiding:
/// let trip = CPTrip(origin: MKMapItem.forCurrentLocation(),
///                   destination: MKMapItem(placemark: MKPlacemark(coordinate: s.target!.position.coordinate)),
///                   routeChoices: s.routes.map { r in
///                       CPRouteChoice(summaryVariants: [r.via ?? s.target!.name],
///                                     additionalInformationVariants: [NavText.remaining(seconds: r.durationS)],
///                                     selectionSummaryVariants: [])
///                   })
/// let session = mapTemplate.startNavigationSession(for: trip)
/// session.maneuverType = .arriveAtDestination ... // see `NavCarPlayManeuver.cpManeuverType`
///
/// // On every snapshot:
/// func maneuver(_ m: NavCarPlayManeuver) -> CPManeuver {
///     let c = CPManeuver()
///     c.instructionVariants = m.instructionVariants
///     c.symbolImage = UIImage(systemName: m.symbolName)       // never mirrored for RTL
///     c.initialTravelEstimates = CPTravelEstimates(
///         distanceRemaining: Measurement(value: m.distanceM, unit: UnitLength.meters),
///         timeRemaining: m.durationS)
///     return c
/// }
/// session.upcomingManeuvers = s.carPlayManeuvers.map(maneuver)
/// session.updateEstimates(CPTravelEstimates(distanceRemaining: .init(value: s.distanceRemainingM, unit: .meters),
///                                           timeRemaining: s.durationRemainingS),
///                         for: session.upcomingManeuvers[0])
/// // The current maneuver's distance ticks with `snapshot.distanceToManeuverM`.
///
/// // Reroute: `snapshot.rerouting` true → session.pauseTrip(for: .rerouting, description: "نحسب طريقًا جديدًا")
/// //          then a new route id → set upcomingManeuvers again.
/// // Arrival: `.arrived` → session.finishTrip(). «إنهاء» on CarPlay → `provider.endNavigation()`.
/// // Off-road last leg: one CPManeuver with `offRoadInstruction` and the bearing arrow
/// //          (`symbolName` "location.north.fill" rotated by `offRoadArrowDegrees`).
/// // Voice: the phone already speaks (one AVSpeechSynthesizer, routed to the car's
/// //        speakers by iOS); CarPlay must NOT speak `spokenInstructions` a second time —
/// //        use it only for captions / logging.
/// ```
///
/// Mapbox's `CarPlayManager` (MapboxNavigationUIKit) would bring its own CarPlay UI
/// and map, replacing the custom templates the CarPlay branch builds, and it starts
/// a billed Free Drive trip on connect by default (`startFreeDriveAutomatically`).
/// So: keep the custom templates and consume this protocol.
@MainActor
protocol NavigationSessionProviding: AnyObject {
    /// Everything about the current navigation, as plain data.
    var snapshot: NavSnapshot { get }
    /// Emits on every change (progress ticks about once a second while driving).
    var snapshots: AnyPublisher<NavSnapshot, Never> { get }
    /// Each line the voice says (or would say while muted).
    var spokenInstructions: AnyPublisher<String, Never> { get }
    /// «ابدأ الملاحة» from CarPlay (e.g. a destination list): opens planning on the phone.
    func startNavigation(to target: NavTarget)
    /// Start on the chosen route (CarPlay's "Go").
    func startGuidance(routeId: String?)
    func endNavigation()
    func setMuted(_ muted: Bool)
}

/// The navigation for CarPlay (and anything else) to render.
struct NavSnapshot: Equatable {
    var phase: NavPhase
    var target: NavTarget?
    /// Planning: every route, best first. Guiding: the one being driven first.
    var routes: [NavRoute]
    var activeRouteId: String?
    var distanceToManeuverM: Double?
    var distanceRemainingM: Double?
    var durationRemainingS: Double?
    var eta: Date?
    var speedLimitKmh: Int?
    var rerouting: Bool
    var muted: Bool
    /// The current maneuver first, then the next ones.
    var carPlayManeuvers: [NavCarPlayManeuver]
    var offRoad: NavOffRoadLeg?
    var offRoadInstruction: String?
    /// The bearing to the target, relative to north (CarPlay rotates its own arrow).
    var offRoadBearing: Double?

    static let idle = NavSnapshot(phase: .idle, target: nil, routes: [], activeRouteId: nil, rerouting: false, muted: false, carPlayManeuvers: [])
}

/// One maneuver, shaped like `CPManeuver` without importing CarPlay.
struct NavCarPlayManeuver: Equatable {
    /// Longest first: CarPlay picks the one that fits.
    var instructionVariants: [String]
    var symbolName: String
    var distanceM: Double
    var durationS: Double
    var lanes: [NavLane]
    var maneuver: NavManeuver
    /// `CPManeuverType` name (iOS 17.4+), e.g. "rightTurn", "roundaboutExit2".
    var cpManeuverType: String
}

extension NavSession: NavigationSessionProviding {
    var snapshot: NavSnapshot {
        var s = NavSnapshot.idle
        s.phase = phase
        s.target = target
        s.routes = active.map { [$0] } ?? routes
        s.activeRouteId = active?.id
        s.distanceToManeuverM = progress?.distanceToManeuverM
        s.distanceRemainingM = remainingMeters
        s.durationRemainingS = remainingSeconds
        s.eta = etaDate
        s.speedLimitKmh = progress?.speedLimitKmh
        s.rerouting = rerouting
        s.muted = muted
        if let r = active {
            let from = progress?.stepIndex ?? 1
            s.carPlayManeuvers = r.steps.indices.filter { $0 >= from }.prefix(3).map { i in
                let st = r.steps[i]
                let d = i == from ? (progress?.distanceToManeuverM ?? st.distanceM) : r.steps[i - 1].distanceM
                return NavCarPlayManeuver(instructionVariants: [NavText.instruction(st, targetName: target?.name), NavText.action(st.maneuver)],
                                          symbolName: NavGlyph.symbol(st.maneuver), distanceM: d, durationS: st.durationS,
                                          lanes: st.lanes, maneuver: st.maneuver, cpManeuverType: NavGlyph.carPlayType(st.maneuver))
            }
        }
        s.offRoad = offRoad
        if let leg = offRoad {
            /* The trip's guidance says why it is a straight line («مافي طريق مزفلت» / «بلا إنترنت»). */
            s.offRoadInstruction = auto ? NavOffRoad.line(leg, remainingM: offRoadNow?.distanceM, bearing: offRoadNow?.bearing, fallback: fallback)
                                        : NavOffRoad.summary(leg)
            s.offRoadBearing = offRoadNow?.bearing ?? leg.bearing
        }
        return s
    }

    var snapshots: AnyPublisher<NavSnapshot, Never> {
        objectWillChange
            .receive(on: DispatchQueue.main)
            .map { [weak self] _ in self?.snapshot ?? .idle }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    var spokenInstructions: AnyPublisher<String, Never> { spoken }

    func startNavigation(to target: NavTarget) { plan(to: target) }

    func startGuidance(routeId: String?) {
        if let routeId { select(routeId) }
        start()
    }

    func endNavigation() { end() }

    func setMuted(_ muted: Bool) { self.muted = muted }
}
