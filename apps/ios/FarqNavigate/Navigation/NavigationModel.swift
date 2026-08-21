import Combine
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

    /// Where the map should draw you — snapped to the road while you are on it.
    /// Everything that draws a position reads this and only this.
    @Published private(set) var mapLocation: CLLocation?

    /// The same position, as the stream Mapbox's puck consumes.
    let locationStream = FarqLocationStream()

    /// Says the turn out loud, in Arabic we build rather than Arabic we are given.
    let voice = ArabicVoiceGuide()

    /// Whether the trip is being narrated. Off is a real choice, so it is one.
    @Published var isVoiceOn = true {
        didSet { voice.isEnabled = isVoiceOn; if !isVoiceOn { voice.reset() } }
    }

    private var cancellables = Set<AnyCancellable>()

    /// Nil only when the configured routing endpoint could not be used at all.
    /// The app then says so instead of offering a navigate button that cannot
    /// work.
    private(set) var core: FerrostarCore?
    private let locationProvider: CoreLocationProvider

    /// Non-throwing on purpose: this object is owned by a `@StateObject`, and a
    /// throwing initialiser forces the view to build it in `onAppear` and hold
    /// it in plain `@State` — where SwiftUI does not observe it, and guidance
    /// runs with the map still showing the browsing screen. That was the bug.
    init() {
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

        do {
            core = try FerrostarCore(
                wellKnownRouteProvider: .valhalla(
                    endpointUrl: RouteConfiguration.endpoint,
                    profile: RouteConfiguration.profile,
                    optionsJson: nil
                ),
                locationProvider: locationProvider,
                navigationControllerConfig: config
            )
        } catch {
            core = nil
            state = .failed("تعذّر إعداد المسارات: \(error.localizedDescription)")
        }

        /* Both inputs feed one decision. The raw fix arrives from CoreLocation
         * whether or not a route exists; the navigation state arrives once one
         * does and carries the snapped position with it. */
        locationProvider.$lastLocation
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.republishLocation() }
            .store(in: &cancellables)

        core?.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.republishLocation()
                self?.voice.consider(state: state)
            }
            .store(in: &cancellables)
    }

    private func republishLocation() {
        guard let chosen = FarqLocationSource.preferred(
            navigation: core?.state,
            raw: locationProvider.lastLocation
        ) else { return }
        locationStream.send(chosen)
        mapLocation = CLLocation(
            latitude: chosen.coordinates.lat,
            longitude: chosen.coordinates.lng
        )
        #if DEBUG
        /* The claim this fix makes, stated as a number rather than a look: how
         * far the drawn position is from the raw fix, and how far it is from
         * the route it is supposed to be on. On route, the second should be
         * within a metre; before the fix it was whatever the GPS error was. */
        if let raw = locationProvider.lastLocation, case .navigating = state {
            let drawn = CLLocation(latitude: chosen.coordinates.lat, longitude: chosen.coordinates.lng)
            let unsnapped = CLLocation(latitude: raw.coordinates.lat, longitude: raw.coordinates.lng)
            NSLog(
                "[farq-loc] drawn %.6f,%.6f · moved %.1fm from raw · %.2fm from route",
                chosen.coordinates.lat, chosen.coordinates.lng,
                drawn.distance(from: unsnapped),
                metresFromRoute(drawn)
            )
        }
        #endif
    }

    /// Ask for routes to an opportunity's destination.
    ///
    /// Takes the whole opportunity rather than a coordinate on purpose: the
    /// refusal to navigate is part of the data, and a caller that only had a
    /// coordinate could not honour it.
    func planRoute(to opportunity: Opportunity) async {
        guard let core else {
            state = .failed("خدمة المسارات غير مهيأة")
            return
        }
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
            voice.reset()
            try core.startNavigation(route: first)
            state = .navigating
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    #if DEBUG
    /// Shortest distance from a point to the planned route's own geometry.
    private func metresFromRoute(_ point: CLLocation) -> Double {
        guard let geometry = routes.first?.geometry, !geometry.isEmpty else { return -1 }
        return geometry.reduce(Double.greatestFiniteMagnitude) { best, vertex in
            let node = CLLocation(latitude: vertex.lat, longitude: vertex.lng)
            return min(best, point.distance(from: node))
        }
    }
    #endif

    func stop() {
        voice.reset()
        core?.stopNavigation()
        routes = []
        destinationLabel = nil
        state = .idle
    }

    func startLocationUpdates() { locationProvider.startUpdating() }
}
