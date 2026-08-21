import CoreLocation
import FerrostarCore
import FerrostarCoreFFI
import Foundation

/// Turn-by-turn, from the destination the API chose.
///
/// Everything about *where* to go was settled server-side and arrives on the
/// opportunity. This type only turns that into a route and runs the guidance,
/// and it refuses to start when there is no honest destination — a confident
/// wrong answer is the only outcome worse than saying we do not know.
@MainActor
final class NavigationModel: ObservableObject {
    enum State: Equatable {
        case idle
        case routing
        case navigating
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var routes: [Route] = []
    @Published private(set) var destinationLabel: String?

    let core: FerrostarCore
    private let locationProvider: CoreLocationProvider

    init() throws {
        let locationProvider = CoreLocationProvider(
            activityType: .automotiveNavigation,
            allowBackgroundLocationUpdates: false
        )
        self.locationProvider = locationProvider

        /* Ferrostar's own step-advance and deviation defaults. They are tuned by
         * people who do this full time; overriding them before we have measured
         * anything of our own would be guessing dressed as configuration. */
        let config = SwiftNavigationControllerConfig(
            waypointAdvance: .waypointWithinRange(100),
            stepAdvanceCondition: stepAdvanceDistanceEntryAndExit(
                distanceToEndOfStep: 30,
                distanceAfterEndOfStep: 5,
                minimumHorizontalAccuracy: 32
            ),
            arrivalStepAdvanceCondition: stepAdvanceDistanceToEndOfStep(
                distance: 30,
                minimumHorizontalAccuracy: 32
            ),
            routeDeviationTracking: .staticThreshold(
                minimumHorizontalAccuracy: 25,
                maxAcceptableDeviation: 20
            ),
            snappedLocationCourseFiltering: .snapToRoute
        )

        core = try FerrostarCore(
            wellKnownRouteProvider: .valhalla(
                endpointUrl: RouteConfiguration.endpoint,
                profile: RouteConfiguration.profile,
                optionsJson: nil
            ),
            locationProvider: locationProvider,
            navigationControllerConfig: config
        )
    }

    /// Ask for routes to an opportunity's destination.
    ///
    /// Takes the whole opportunity rather than a coordinate on purpose: the
    /// refusal to navigate is part of the data, and a caller that only had a
    /// coordinate could not honour it.
    func planRoute(to opportunity: Opportunity) async {
        guard let destination = opportunity.destination else {
            state = .failed(opportunity.navigateTo?.caution
                ?? "ما عندنا وجهة مؤكدة لهذا المكان")
            return
        }
        guard let start = locationProvider.lastLocation else {
            state = .failed("نحتاج موقعك أولاً")
            return
        }

        state = .routing
        destinationLabel = opportunity.name

        let waypoint = Waypoint(
            coordinate: GeographicCoordinate(
                lat: destination.latitude,
                lng: destination.longitude
            ),
            kind: .break
        )

        do {
            let found = try await core.getRoutes(initialLocation: start, waypoints: [waypoint])
            routes = found
            guard let first = found.first else {
                state = .failed("ما فيه طريق معروف لهذا المكان")
                return
            }
            try core.startNavigation(route: first)
            state = .navigating
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func stop() {
        core.stopNavigation()
        routes = []
        destinationLabel = nil
        state = .idle
    }

    func startLocationUpdates() { locationProvider.startUpdating() }
}
