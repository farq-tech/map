import Combine
import CoreLocation
import Foundation
import UIKit

/// Where a navigation is.
enum NavPhase: Equatable {
    case idle
    /// The route options sheet: routes loading / shown / failed.
    case planning
    /// Turn-by-turn on the road route.
    case guiding
    /// «آخر جزء بدون طريق»: road ended (or there is none), straight line to the target.
    case offRoad
    case arrived
}

enum NavCameraMode: Equatable {
    /// Behind my car, heading-up, tilted.
    case follow
    /// The whole remaining route.
    case overview
    /// The person moved the map: leave it alone until «تابع».
    case free
}

/// One navigation at a time, from «ابدأ الملاحة» to «إنهاء». Owns the routing
/// provider, the guidance engine and the voice; the live screen observes it.
@MainActor
final class NavSession: ObservableObject {
    @Published private(set) var phase: NavPhase = .idle
    @Published private(set) var target: NavTarget?
    @Published var options: NavRouteOptions = .load() {
        didSet { options.save() }
    }
    /// Ordered best first (`NavRouteChoice`).
    @Published private(set) var routes: [NavRoute] = []
    @Published var selectedId: String?
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    /// No road route at all: only a straight line (honest «اتجاه مباشر»).
    @Published private(set) var direct = false
    /// The route being driven.
    @Published private(set) var active: NavRoute?
    @Published private(set) var progress: NavProgress?
    @Published private(set) var rerouting = false
    @Published private(set) var offRoad: NavOffRoadLeg?
    /// Live remainder in the off-road phase.
    @Published private(set) var offRoadNow: (distanceM: Double, bearing: Double)?
    @Published var camera: NavCameraMode = .follow
    @Published var muted: Bool {
        didSet { voice.muted = muted }
    }
    @Published private(set) var arrivedAt: Date?
    @Published private(set) var startedAt: Date?

    let provider: NavRoutingProvider
    let voice = NavVoice()
    private var plan = NavRoutePlan(routes: [])
    private var engine: NavGuidanceEngine?
    private let makeEngine: (NavRoutePlan) -> NavGuidanceEngine
    private let locator = NavLocator()
    private var fetchTask: Task<Void, Never>?
    private var lastOffRouteSpoken = Date.distantPast
    private let spokenSubject = PassthroughSubject<String, Never>()
    /// My latest fix (from the app's location owner).
    var myFix: () -> DeviceFix? = { nil }
    /// Say something on screen (the live screen's toast).
    var toast: (String) -> Void = { _ in }

    init(provider: NavRoutingProvider, makeEngine: ((NavRoutePlan) -> NavGuidanceEngine)? = nil) {
        self.provider = provider
        muted = UserDefaults.standard.bool(forKey: NavVoice.muteKey)
        self.makeEngine = makeEngine ?? { plan in
            plan.native is MapboxRoutesBox || plan.native is FarqRoutesBox ? MapboxGuidanceEngine() as NavGuidanceEngine : LocalGuidanceEngine()
        }
        voice.onSpoken = { [weak self] t in self?.spokenSubject.send(t) }
        locator.onFix = { [weak self] f in self?.ingest(f) }
    }

    var isActive: Bool { phase == .guiding || phase == .offRoad || phase == .arrived }
    var selected: NavRoute? { routes.first { $0.id == selectedId } ?? routes.first }

    // MARK: planning

    func plan(to t: NavTarget) {
        guard let f = myFix() else {
            toast(NavRefusal.noFix.message)
            return
        }
        if isActive { stopEngine() }
        target = t
        phase = .planning
        active = nil
        progress = nil
        arrivedAt = nil
        fetch(from: LngLat(lng: f.lng, lat: f.lat), heading: Policy.trustedHeading(f.heading, speed: f.speed))
    }

    /// The options changed in the sheet: ask again.
    func refetch() {
        guard phase == .planning, let f = myFix() else { return }
        fetch(from: LngLat(lng: f.lng, lat: f.lat), heading: Policy.trustedHeading(f.heading, speed: f.speed))
    }

    private func fetch(from origin: LngLat, heading: Double?) {
        guard let t = target else { return }
        fetchTask?.cancel()
        loading = true
        error = nil
        direct = false
        let req = NavRouteRequest(origin: origin, heading: heading, target: t, options: options)
        fetchTask = Task { [weak self] in
            guard let self else { return }
            do {
                let p = try await self.provider.routes(req)
                guard !Task.isCancelled else { return }
                self.plan = p
                self.routes = NavRouteChoice.order(p.routes, options: self.options)
                self.selectedId = self.routes.first?.id
                self.offRoad = NavOffRoad.lastLeg(routeEnd: self.selected?.end, target: t.position)
                if self.routes.isEmpty { self.goDirect(origin, t) }
                #if DEBUG
                NavLog.log("routes %d via %@ first=%.0fm/%.0fs", self.routes.count, self.provider.name, self.routes.first?.distanceM ?? 0, self.routes.first?.durationS ?? 0)
                #endif
            } catch let e as NavRoutingError {
                guard !Task.isCancelled else { return }
                #if DEBUG
                NavLog.log("routing error %@", String(describing: e))
                #endif
                if e == .noRoute { self.goDirect(origin, t) } else { self.error = e.message; self.routes = [] }
            } catch {
                guard !Task.isCancelled else { return }
                #if DEBUG
                NavLog.log("routing error %@", String(describing: error))
                #endif
                self.error = NavRoutingError.failed("").message
                self.routes = []
            }
            self.loading = false
        }
    }

    private func goDirect(_ origin: LngLat, _ t: NavTarget) {
        plan = NavRoutePlan(routes: [])
        routes = []
        selectedId = nil
        direct = true
        offRoad = NavOffRoad.direct(from: origin, to: t.position)
    }

    func select(_ id: String) {
        selectedId = id
        if let t = target { offRoad = NavOffRoad.lastLeg(routeEnd: selected?.end, target: t.position) }
    }

    func cancelPlanning() {
        fetchTask?.cancel()
        guard phase == .planning else { return }
        reset()
    }

    // MARK: guidance

    func start() {
        guard let t = target else { return }
        #if DEBUG
        NavLog.log("start provider=%@ routes=%d direct=%d", provider.name, routes.count, direct ? 1 : 0)
        #endif
        startedAt = Date()
        camera = .follow
        if direct || selected == nil {
            phase = .offRoad
            locator.start()
            if let f = myFix() { ingest(f) }
            if let leg = offRoad { voice.say("لا يوجد طريق معروف. اتجه \(NavText.compassDefinite(leg.bearing)) \(NavText.spokenInDistance(leg.distanceM) ?? "")") }
            return
        }
        guard let r = selected else { return }
        active = r
        phase = .guiding
        offRoad = NavOffRoad.lastLeg(routeEnd: r.end, target: t.position)
        let e = makeEngine(plan)
        attach(e)
        Task { [weak self] in
            guard let self else { return }
            do {
                try await e.start(route: r, plan: self.plan, target: t)
            } catch {
                #if DEBUG
                NavLog.log("engine start failed %@ → local", String(describing: error))
                #endif
                /* The SDK could not take this route (e.g. a custom route it cannot parse):
                 * follow it ourselves rather than give up. */
                e.stop()
                let local = LocalGuidanceEngine()
                self.attach(local)
                try? await local.start(route: r, plan: self.plan, target: t)
            }
            if let first = r.steps.dropFirst().first {
                self.voice.say(NavText.spoken(first, distanceM: r.steps.first?.distanceM ?? 0, targetName: t.name))
            }
        }
        UIApplication.shared.isIdleTimerDisabled = true
    }

    private func attach(_ e: NavGuidanceEngine) {
        engine = e
        e.onEvent = { [weak self] ev in self?.handle(ev) }
        if let local = e as? LocalGuidanceEngine {
            local.reroute = { [weak self] from, heading in await self?.rerouteLocally(from: from, heading: heading) }
            locator.start()
        }
    }

    private func rerouteLocally(from: LngLat, heading: Double?) async -> NavRoute? {
        guard let t = target else { return nil }
        let p = try? await provider.routes(NavRouteRequest(origin: from, heading: heading, target: t, options: options))
        guard let p, let r = NavRouteChoice.order(p.routes, options: options).first else { return nil }
        plan = p
        return r
    }

    func handle(_ ev: NavGuidanceEvent) {
        #if DEBUG
        if case let .progress(p) = ev {
            if Int(p.distanceRemainingM) / 250 != Int(progress?.distanceRemainingM ?? -1) / 250 {
                NavLog.log("progress step=%d toManeuver=%.0f remaining=%.0f eta=%.0fs limit=%@", p.stepIndex, p.distanceToManeuverM, p.distanceRemainingM, p.durationRemainingS, p.speedLimitKmh.map(String.init) ?? "-")
            }
        } else {
            NavLog.log("event %@", String(describing: ev))
        }
        #endif
        switch ev {
        case let .progress(p):
            guard phase == .guiding else { return }
            progress = p
            if rerouting { rerouting = false }
        case .offRoute:
            guard phase == .guiding else { return }
            rerouting = true
            /* Once, not on every reroute while the driver is still finding the way back. */
            if Date().timeIntervalSince(lastOffRouteSpoken) > 45 {
                lastOffRouteSpoken = Date()
                voice.say("خرجت عن الطريق، نحسب طريقًا جديدًا")
            }
        case let .rerouted(r):
            guard phase == .guiding else { return }
            rerouting = false
            active = r
            if let t = target { offRoad = NavOffRoad.lastLeg(routeEnd: r.end, target: t.position) }
            toast("مسار جديد")
        case let .rerouteFailed(m):
            rerouting = false
            toast(m)
        case .arrivedAtRouteEnd:
            guard phase == .guiding else { return }
            stopEngine()
            if let leg = offRoad {
                phase = .offRoad
                locator.start()
                voice.say("انتهى الطريق. \(NavOffRoad.summary(leg))")
                if let f = myFix() { ingest(f) }
            } else {
                arrive()
            }
        case let .speak(t):
            voice.say(t)
        case let .cue(routerText):
            if let step = currentStep, let p = progress {
                voice.say(NavText.spoken(step, distanceM: p.distanceToManeuverM, targetName: target?.name))
            } else {
                voice.say(routerText)
            }
        }
    }

    private func arrive() {
        phase = .arrived
        #if DEBUG
        NavLog.log("arrived at %@", target?.name ?? "-")
        #endif
        arrivedAt = Date()
        locator.stop()
        stopEngine()
        voice.say("وصلت إلى \(target?.name ?? "وجهتك")")
        UIApplication.shared.isIdleTimerDisabled = false
    }

    /// Every GPS fix (the app's own, and our locator's in the off-road phase / local engine).
    func ingest(_ f: DeviceFix) {
        switch phase {
        case .guiding:
            engine?.ingest(f)
        case .offRoad:
            guard let leg = offRoad else { return }
            let r = NavOffRoad.remaining(leg, me: LngLat(lng: f.lng, lat: f.lat))
            offRoadNow = (r.distanceM, r.bearing)
            if r.arrived { arrive() }
        default:
            break
        }
    }

    func end() {
        fetchTask?.cancel()
        stopEngine()
        locator.stop()
        voice.stop()
        reset()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func stopEngine() {
        engine?.stop()
        engine = nil
    }

    private func reset() {
        phase = .idle
        target = nil
        routes = []
        selectedId = nil
        active = nil
        progress = nil
        offRoad = nil
        offRoadNow = nil
        rerouting = false
        loading = false
        error = nil
        direct = false
        plan = NavRoutePlan(routes: [])
    }

    // MARK: what the UI shows

    var currentStep: NavStep? {
        guard let r = active, let p = progress, r.steps.indices.contains(p.stepIndex) else { return active?.steps.dropFirst().first }
        return r.steps[p.stepIndex]
    }

    var nextStep: NavStep? {
        guard let r = active else { return nil }
        let i = (progress?.stepIndex ?? 1) + 1
        return r.steps.indices.contains(i) ? r.steps[i] : nil
    }

    var etaDate: Date? {
        guard let s = remainingSeconds else { return nil }
        return Date().addingTimeInterval(s)
    }

    var remainingSeconds: Double? {
        if let p = progress { return p.durationRemainingS }
        return active?.durationS
    }

    var remainingMeters: Double? {
        if phase == .offRoad { return offRoadNow?.distanceM ?? offRoad?.distanceM }
        let road = progress?.distanceRemainingM ?? active?.distanceM
        return road.map { $0 + (offRoad?.distanceM ?? 0) }
    }

    var spoken: AnyPublisher<String, Never> { spokenSubject.eraseToAnyPublisher() }

    #if DEBUG
    /// Screenshots: put the session in a state without driving.
    func debugSet(phase: NavPhase, target: NavTarget, routes: [NavRoute], progress: NavProgress?, offRoad: NavOffRoadLeg?, rerouting: Bool = false, direct: Bool = false) {
        self.target = target
        self.routes = routes
        selectedId = routes.first?.id
        active = phase == .planning ? nil : routes.first
        self.progress = progress
        self.offRoad = offRoad
        offRoadNow = offRoad.map { ($0.distanceM, $0.bearing) }
        self.rerouting = rerouting
        self.direct = direct
        self.phase = phase
        if phase == .arrived { arrivedAt = Date() }
    }
    #endif
}

/// Our own location stream for the off-road last leg (and the local engine):
/// the Mapbox engine is idle by then, and the leg must keep working locked.
/// Runs only between «ابدأ الملاحة» and arrival / «إنهاء»; never sent anywhere.
@MainActor
final class NavLocator: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    var onFix: (DeviceFix) -> Void = { _ in }
    private(set) var running = false

    override init() {
        super.init()
        manager.delegate = self
        manager.activityType = .otherNavigation
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.pausesLocationUpdatesAutomatically = false
    }

    func start() {
        guard !running else { return }
        running = true
        if Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes").flatMap({ $0 as? [String] })?.contains("location") == true {
            manager.allowsBackgroundLocationUpdates = true
            manager.showsBackgroundLocationIndicator = true
        }
        manager.startUpdatingLocation()
    }

    func stop() {
        guard running else { return }
        running = false
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let l = locations.last, l.horizontalAccuracy >= 0 else { return }
        let f = DeviceFix(lat: l.coordinate.latitude, lng: l.coordinate.longitude, accuracy: l.horizontalAccuracy,
                          heading: l.course >= 0 ? l.course : nil, speed: l.speed >= 0 ? l.speed : nil,
                          atMs: l.timestamp.timeIntervalSince1970 * 1000)
        Task { @MainActor in self.onFix(f) }
    }
}
