import Combine
import CoreLocation
import Foundation
import MapboxDirections
import MapboxNavigationCore

// The only file that talks to the Mapbox Navigation SDK. Everything else uses
// `NavRoutingProvider` / `NavGuidanceEngine` and the plain `Nav*` models.
//
// Billing (Navigation SDK v3, metered-trips pricing, the default):
//   * An Active Guidance trip starts at `startActiveGuidance` and ends at `setToIdle`
//     (we call it on «إنهاء», on arrival and when the outing screen closes).
//     Reroutes stay in the same trip. A NEW destination >100 m away is a new trip,
//     so «روح له» never silently re-targets a moving friend.
//   * A user counts as a monthly active user once they start one trip.
//   * We never start Free Drive (it is a separately billed trip type), and the
//     provider is created lazily on the first «ابدأ الملاحة», not at app launch.
//   * Route previews before the trip are Directions API requests, billed per
//     request (outside the trip).

/// Holds the one `MapboxNavigationProvider` the SDK allows per process.
@MainActor
enum MapboxNavCore {
    private static var provider: MapboxNavigationProvider?

    nonisolated static var token: String? {
        let t = Bundle.main.object(forInfoDictionaryKey: "MBXAccessToken") as? String ?? ""
        return t.hasPrefix("pk.") ? t : nil
    }

    static var isConfigured: Bool { token != nil }

    static var navigation: MapboxNavigation {
        if let p = provider { return p.mapboxNavigation }
        var routing = RoutingConfig(
            /* No background "faster route" / continuous-alternative requests: fewer
             * requests, and the route never changes under the driver without a reason. */
            alternativeRoutesDetectionConfig: nil,
            fasterRouteDetectionConfig: nil,
            rerouteConfig: RerouteConfig(detectsReroute: true),
            routeRefreshPeriod: 120
        )
        routing.prefersOnlineRoute = true
        let config = CoreConfig(
            routingConfig: routing,
            locationSource: .live,
            copilotEnabled: false,
            locale: Locale(identifier: "ar"),
            /* No predictive tile pre-fetching around the route: extra downloads we do not need. */
            predictiveCacheConfig: nil,
            /* Voice comes from our own `NavVoice` (on-device ar-SA), never the Mapbox voice API. */
            ttsConfig: .localOnly
        )
        let p = MapboxNavigationProvider(coreConfig: config)
        provider = p
        return p.mapboxNavigation
    }
}

/// `NavigationRoutes` is a struct; the plan carries it boxed.
final class MapboxRoutesBox {
    let routes: NavigationRoutes
    init(_ r: NavigationRoutes) { routes = r }
}

/// Mapbox Directions through the Navigation SDK's routing provider.
@MainActor
final class MapboxNavRoutingProvider: NavRoutingProvider {
    let name = "Mapbox"

    /// The request exactly as sent (tests check the mapping).
    nonisolated static func options(_ r: NavRouteRequest) -> NavigationRouteOptions {
        let spec = NavRouteSpec.from(r.options)
        var origin = MapboxDirections.Waypoint(coordinate: r.origin.coordinate)
        if let h = r.heading {
            origin.heading = h
            origin.headingAccuracy = 45
        }
        let dest = MapboxDirections.Waypoint(coordinate: r.target.position.coordinate, name: r.target.name)
        let o = NavigationRouteOptions(
            waypoints: [origin, dest],
            profileIdentifier: spec.profile == .drivingTraffic ? .automobileAvoidingTraffic : .automobile,
            queryItems: nil,
            locale: Locale(identifier: spec.language),
            distanceUnit: .kilometer
        )
        o.includesAlternativeRoutes = spec.alternatives
        o.distanceMeasurementSystem = spec.metric ? .metric : .imperial
        var avoid: RoadClasses = []
        if spec.exclude.contains("toll") { avoid.insert(.toll) }
        if spec.exclude.contains("unpaved") { avoid.insert(.unpaved) }
        o.roadClassesToAvoid = avoid
        return o
    }

    func routes(_ r: NavRouteRequest) async throws -> NavRoutePlan {
        guard MapboxNavCore.isConfigured else { throw NavRoutingError.notConfigured }
        let task = MapboxNavCore.navigation.routingProvider().calculateRoutes(options: Self.options(r))
        do {
            let nr = try await task.value
            var routes = [Self.convert(nr.mainRoute.route, id: nr.mainRoute.routeId.description)]
            routes += nr.alternativeRoutes.map { Self.convert($0.route, id: $0.routeId.description) }
            return NavRoutePlan(routes: routes, native: MapboxRoutesBox(nr))
        } catch let e as DirectionsError {
            throw Self.map(e)
        } catch let e as URLError {
            throw e.code == .notConnectedToInternet || e.code == .networkConnectionLost ? NavRoutingError.offline : .failed("")
        } catch {
            throw NavRoutingError.failed("")
        }
    }

    nonisolated static func map(_ e: DirectionsError) -> NavRoutingError {
        switch e {
        case .unableToRoute, .noMatches, .unableToLocate: return .noRoute
        case let .network(u): return u.code == .notConnectedToInternet || u.code == .networkConnectionLost || u.code == .timedOut ? .offline : .failed("")
        default: return .failed("")
        }
    }

    // MARK: Directions → NavRoute

    nonisolated static func convert(_ route: Route, id: String) -> NavRoute {
        let coords = (route.shape?.coordinates ?? []).map { LngLat(lng: $0.longitude, lat: $0.latitude) }
        let msteps = route.legs.flatMap(\.steps)
        var steps: [NavStep] = []
        var unpaved = false, tolls = false
        var names: [String: Double] = [:]
        for (i, s) in msteps.enumerated() {
            let lanes = s.intersections?.first?.approachLanes.map { ind -> [NavLane] in
                let usable = s.intersections?.first?.usableApproachLanes ?? IndexSet()
                let preferred = s.intersections?.first?.preferredApproachLanes ?? IndexSet()
                return ind.enumerated().map { j, l in NavLane(directions: laneDirections(l), valid: usable.contains(j), preferred: preferred.contains(j)) }
            } ?? []
            for x in s.intersections ?? [] {
                if x.outletRoadClasses?.contains(.unpaved) == true { unpaved = true }
                if x.outletRoadClasses?.contains(.toll) == true || x.tollCollection != nil { tolls = true }
            }
            if let n = s.names?.first, !n.isEmpty { names[n, default: 0] += s.distance }
            /* Directions speaks the NEXT maneuver along a step; ours hangs off the maneuver itself. */
            let spokenForThis = i > 0 ? (msteps[i - 1].instructionsSpokenAlongStep ?? []).map { NavSpoken(distanceBeforeManeuver: $0.distanceAlongStep, text: $0.text) } : []
            steps.append(NavStep(
                maneuver: maneuver(s),
                roadName: s.names?.first,
                signText: s.destinations?.first ?? s.exitNames?.first,
                routerText: s.instructions,
                location: LngLat(lng: s.maneuverLocation.longitude, lat: s.maneuverLocation.latitude),
                distanceM: s.distance,
                durationS: s.expectedTravelTime,
                lanes: lanes,
                spoken: spokenForThis.sorted { $0.distanceBeforeManeuver > $1.distanceBeforeManeuver },
                speedLimitKmh: nil
            ))
        }
        let via = names.sorted { $0.value > $1.value }.prefix(1).map(\.key).first
        return NavRoute(id: id, coordinates: coords, distanceM: route.distance, durationS: route.expectedTravelTime,
                        steps: steps, hasUnpaved: unpaved, hasTolls: tolls, via: via)
    }

    nonisolated static func maneuver(_ s: RouteStep) -> NavManeuver {
        let kind: NavManeuverKind
        switch s.maneuverType {
        case .depart: kind = .depart
        case .turn: kind = .turn
        case .continue: kind = .continue
        case .passNameChange: kind = .newName
        case .merge: kind = .merge
        case .takeOnRamp: kind = .onRamp
        case .takeOffRamp: kind = .offRamp
        case .reachFork: kind = .fork
        case .reachEnd: kind = .endOfRoad
        case .useLane: kind = .useLane
        case .takeRoundabout, .takeRotary, .turnAtRoundabout: kind = .roundabout
        case .exitRoundabout, .exitRotary: kind = .exitRoundabout
        case .heedWarning: kind = .notification
        case .arrive: kind = .arrive
        }
        return NavManeuver(kind: kind, direction: s.maneuverDirection.flatMap(direction), exit: s.exitIndex)
    }

    nonisolated static func direction(_ d: ManeuverDirection) -> NavTurnDirection? {
        switch d {
        case .sharpRight: return .sharpRight
        case .right: return .right
        case .slightRight: return .slightRight
        case .straightAhead: return .straight
        case .slightLeft: return .slightLeft
        case .left: return .left
        case .sharpLeft: return .sharpLeft
        case .uTurn: return .uTurn
        case .undefined: return nil
        }
    }

    nonisolated static func laneDirections(_ l: LaneIndication) -> [NavTurnDirection] {
        var out: [NavTurnDirection] = []
        if l.contains(.sharpLeft) { out.append(.sharpLeft) }
        if l.contains(.left) { out.append(.left) }
        if l.contains(.slightLeft) { out.append(.slightLeft) }
        if l.contains(.straightAhead) { out.append(.straight) }
        if l.contains(.slightRight) { out.append(.slightRight) }
        if l.contains(.right) { out.append(.right) }
        if l.contains(.sharpRight) { out.append(.sharpRight) }
        if l.contains(.uTurn) { out.append(.uTurn) }
        return out.isEmpty ? [.straight] : out
    }
}

/// Active guidance on the Mapbox Navigation SDK: its own location, map matching,
/// off-route detection and reroute, voice timing from the Directions response.
@MainActor
final class MapboxGuidanceEngine: NavGuidanceEngine {
    var onEvent: (NavGuidanceEvent) -> Void = { _ in }
    private var bag = Set<AnyCancellable>()
    private var currentRouteId: String?
    private var speedLimit: Int?
    nonisolated(unsafe) private var running = false

    deinit {
        /* Never leave a billed trip (and the SDK's GPS) running behind a closed screen. */
        if running { Task { @MainActor in MapboxNavCore.navigation.tripSession().setToIdle() } }
    }

    func start(route: NavRoute, plan: NavRoutePlan, target: NavTarget) async throws {
        var routes: NavigationRoutes
        if let farq = plan.native as? FarqRoutesBox {
            /* The company's Valhalla route, navigated as a custom (external) route. */
            routes = try await farq.navigationRoutes(routeId: route.id)
        } else if let box = plan.native as? MapboxRoutesBox {
            routes = box.routes
            if box.routes.mainRoute.routeId.description != route.id,
               let alt = box.routes.alternativeRoutes.first(where: { $0.routeId.description == route.id }),
               let chosen = await box.routes.selecting(alternativeRoute: alt) {
                routes = chosen
            }
        } else {
            throw NavRoutingError.failed("")
        }
        let nav = MapboxNavCore.navigation
        stopObserving()
        currentRouteId = routes.mainRoute.routeId.description
        running = true
        observe(nav)
        nav.tripSession().startActiveGuidance(with: routes, startLegIndex: 0)
    }

    func stop() {
        stopObserving()
        guard running else { return }
        running = false
        /* Ends the Active Guidance trip (billing) and stops the SDK's location updates. */
        MapboxNavCore.navigation.tripSession().setToIdle()
    }

    func ingest(_ fix: DeviceFix) {}

    private func stopObserving() {
        bag.removeAll()
    }

    private func observe(_ nav: MapboxNavigation) {
        let n = nav.navigation()
        n.routeProgress.compactMap { $0?.routeProgress }.receive(on: DispatchQueue.main).sink { [weak self] p in
            guard let self else { return }
            let leg = p.currentLegProgress
            let next = min(leg.stepIndex + 1, max(0, leg.leg.steps.count - 1))
            /* Steps are flattened over legs; we route one leg, so the index is the leg's. */
            self.onEvent(.progress(NavProgress(stepIndex: next, distanceToManeuverM: leg.currentStepProgress.distanceRemaining,
                                               distanceRemainingM: p.distanceRemaining, durationRemainingS: p.durationRemaining,
                                               speedLimitKmh: self.speedLimit)))
        }.store(in: &bag)
        n.locationMatching.receive(on: DispatchQueue.main).sink { [weak self] m in
            guard let v = m.speedLimit.value else { self?.speedLimit = nil; return }
            self?.speedLimit = Int(v.converted(to: .kilometersPerHour).value.rounded())
        }.store(in: &bag)
        n.voiceInstructions.receive(on: DispatchQueue.main).sink { [weak self] v in
            self?.onEvent(.cue(v.spokenInstruction.text))
        }.store(in: &bag)
        n.rerouting.receive(on: DispatchQueue.main).sink { [weak self] s in
            switch s.event {
            case is ReroutingStatus.Events.FetchingRoute: self?.onEvent(.offRoute)
            case is ReroutingStatus.Events.Failed: self?.onEvent(.rerouteFailed("تعذّر حساب طريق جديد"))
            default: break
            }
        }.store(in: &bag)
        nav.tripSession().navigationRoutes.compactMap { $0 }.receive(on: DispatchQueue.main).sink { [weak self] r in
            guard let self, r.mainRoute.routeId.description != self.currentRouteId else { return }
            self.currentRouteId = r.mainRoute.routeId.description
            self.onEvent(.rerouted(MapboxNavRoutingProvider.convert(r.mainRoute.route, id: r.mainRoute.routeId.description)))
        }.store(in: &bag)
        n.waypointsArrival.receive(on: DispatchQueue.main).sink { [weak self] a in
            if a.event is WaypointArrivalStatus.Events.ToFinalDestination { self?.onEvent(.arrivedAtRouteEnd) }
        }.store(in: &bag)
    }
}
