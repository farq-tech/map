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

/// Why the guidance is a straight line instead of a road route (said on screen, honestly).
enum NavFallback: Equatable {
    /// The router knows no road to the target (a desert camp off the network).
    case noRoad
    /// Routing failed (no network, router unreachable): bearing guidance while we retry.
    /// Never a made-up route.
    case offline
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
    /// Started by the trip («ابدأ الطلعة», `TripAutoNav`), not by a tap: no options sheet,
    /// the best route at once, and a straight line (never a made-up road) when routing fails.
    @Published private(set) var auto = false
    @Published private(set) var fallback: NavFallback?
    /// Arrived at the target (the stop / destination logic lives with the trip).
    var onArrived: (NavTarget) -> Void = { _ in }
    /// Offline fallback: try a road route again this often.
    var retryInterval: TimeInterval = 20
    private var retryTask: Task<Void, Never>?
    private var retryable = false
    private var retrying = false
    /// Said before the first instruction of an automatic start («نبدأ التوجيه إلى …»).
    private var autoIntro: NavLine?

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
        voice.onReevaluate = { [weak self] in self?.restateCurrent() }
    }

    /// Bumped on every new route (start, reroute): lines built for an older one are dropped.
    private(set) var routeRevision = 0 {
        didSet { voice.routeRevision = routeRevision; saidStages = [:] }
    }
    /// Per maneuver («<revision>:<step>»), the cues already said (early / confirm / immediate).
    private var saidStages: [String: Set<Int>] = [:]

    /// The guidance line for step `index`, `d` metres ahead — nil when that cue was already said.
    /// «صوت سرى»: no name, «ثم …» when the next maneuver follows closely and there is time.
    func guidanceLine(stepIndex index: Int, distanceM d: Double, force: Bool = false) -> NavLine? {
        guard let r = active, r.steps.indices.contains(index) else { return nil }
        let step = r.steps[index]
        let speed = myFix()?.speed
        let stage = NavCueBands.stage(distanceM: d, bands: NavCueBands.distances(speedMps: speed, unpaved: r.hasUnpaved))
        let key = "\(routeRevision):\(index)"
        if !force, saidStages[key, default: []].contains(stage.rawValue) { return nil }
        saidStages[key, default: []].insert(stage.rawValue)
        var clips = SaryVoiceScript.step(step, distanceM: d, auto: auto, stop: isStopTarget)
        let next = r.steps.indices.contains(index + 1) ? r.steps[index + 1] : nil
        clips = SaryVoiceScript.withThen(clips, next: next, gapM: step.distanceM, distanceToManeuverM: d, speedMps: speed, stop: isStopTarget)
        return NavLine(NavText.spoken(step, distanceM: d, targetName: target?.name), clips: clips,
                       maneuverID: key, routeRevision: routeRevision, expiresAt: Date().addingTimeInterval(10))
    }

    /// After a call / Siri cut a line: the current maneuver, rebuilt for the distance now.
    func restateCurrent() {
        guard phase == .guiding, let p = progress,
              let line = guidanceLine(stepIndex: p.stepIndex, distanceM: p.distanceToManeuverM, force: true) else { return }
        voice.say(line)
    }

    /// A stop on the way or the rally point (said «على يمينك», not «وجهتك …»).
    var isStopTarget: Bool { target?.source == .tripStop || target?.source == .rally }

    var isActive: Bool { phase == .guiding || phase == .offRoad || phase == .arrived }
    var selected: NavRoute? { routes.first { $0.id == selectedId } ?? routes.first }

    // MARK: planning

    func plan(to t: NavTarget) {
        guard let f = myFix() else {
            toast(NavRefusal.noFix.message)
            return
        }
        if isActive { stopEngine() }
        retryTask?.cancel()
        locator.stop()
        auto = false
        fallback = nil
        retryable = false
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

    // MARK: automatic (the trip)

    /// Guide to `t` now, without the options sheet: the best road route, or — when there is
    /// no road (desert) or no network — the straight-line bearing guidance at once, retrying
    /// the road route in the background when it was the network.
    func autoStart(to t: NavTarget, intro: String? = nil, introClips: [String]? = nil) {
        guard let f = myFix() else { return }
        fetchTask?.cancel()
        retryTask?.cancel()
        if isActive { stopEngine() }
        locator.stop()
        reset()
        auto = true
        target = t
        phase = .planning
        loading = true
        arrivedAt = nil
        startedAt = nil
        autoIntro = intro.map { NavLine($0, clips: introClips ?? SaryVoiceScript.intro(resumed: false)) }
        let origin = LngLat(lng: f.lng, lat: f.lat)
        let heading = Policy.trustedHeading(f.heading, speed: f.speed)
        #if DEBUG
        NavLog.log("auto start to %@", t.name)
        #endif
        fetchTask = Task { [weak self] in
            guard let self else { return }
            let r = await self.requestRoutes(origin: origin, heading: heading, target: t)
            guard !Task.isCancelled, self.auto, self.phase == .planning, self.target == t else { return }
            self.loading = false
            self.applyAuto(r, origin: origin, target: t)
            self.start()
        }
    }

    private func requestRoutes(origin: LngLat, heading: Double?, target t: NavTarget) async -> Result<NavRoutePlan, NavRoutingError> {
        do {
            return .success(try await provider.routes(NavRouteRequest(origin: origin, heading: heading, target: t, options: options)))
        } catch let e as NavRoutingError {
            return .failure(e)
        } catch {
            return .failure(.failed(""))
        }
    }

    private func applyAuto(_ r: Result<NavRoutePlan, NavRoutingError>, origin: LngLat, target t: NavTarget) {
        switch r {
        case let .success(p) where !p.routes.isEmpty:
            plan = p
            routes = NavRouteChoice.order(p.routes, options: options)
            selectedId = routes.first?.id
            direct = false
            offRoad = NavOffRoad.lastLeg(routeEnd: selected?.end, target: t.position)
            fallback = nil
            retryable = false
        case .success, .failure(.noRoute):
            goDirect(origin, t)
            fallback = .noRoad
            retryable = false
        case .failure(.notConfigured):
            goDirect(origin, t)
            fallback = .offline
            retryable = false
        case .failure:
            goDirect(origin, t)
            fallback = .offline
            retryable = true
        }
        #if DEBUG
        NavLog.log("auto routes=%d fallback=%@", routes.count, String(describing: fallback))
        #endif
    }

    private func scheduleRetry() {
        retryTask?.cancel()
        guard retryable else { return }
        let every = max(0.01, retryInterval)
        retryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(every * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                if await self.retryRoute() { return }
            }
        }
    }

    /// One more try at a road route while the offline bearing guidance runs (on a timer, and
    /// when the network comes back). True when there is nothing left to retry.
    @discardableResult
    func retryRoute() async -> Bool {
        guard auto, phase == .offRoad, fallback == .offline, retryable else { return true }
        guard !retrying, let t = target, let f = myFix() else { return false }
        retrying = true
        defer { retrying = false }
        let origin = LngLat(lng: f.lng, lat: f.lat)
        let r = await requestRoutes(origin: origin, heading: Policy.trustedHeading(f.heading, speed: f.speed), target: t)
        guard auto, phase == .offRoad, fallback == .offline, target == t else { return true }
        switch r {
        case let .success(p) where !p.routes.isEmpty:
            #if DEBUG
            NavLog.log("retry: road route is back")
            #endif
            locator.stop()
            applyAuto(r, origin: origin, target: t)
            autoIntro = NavLine("رجع الاتصال، نوجّهك على الطريق", clips: ["rr_05"])
            start()
            return true
        case .success, .failure(.noRoute):
            fallback = .noRoad
            retryable = false
            voice.say("ما فيه طريق معبّد إلى \(t.name). كمّل مع السهم", clips: ["dir_06"])
            return true
        default:
            return false
        }
    }

    /// The network is back: try the road route now instead of waiting for the timer.
    func retryNow() {
        guard auto, phase == .offRoad, fallback == .offline, retryable else { return }
        Task { await retryRoute() }
    }

    /// The trip says I arrived (dwell at the destination): end on «وصلتوا».
    func finishArrival() {
        guard phase == .guiding || phase == .offRoad else { return }
        arrive()
    }

    // MARK: guidance

    func start() {
        guard let t = target else { return }
        #if DEBUG
        NavLog.log("start provider=%@ routes=%d direct=%d", provider.name, routes.count, direct ? 1 : 0)
        #endif
        if startedAt == nil || !auto { startedAt = Date() }
        camera = .follow
        let intro = autoIntro ?? NavLine("", clips: [])
        autoIntro = nil
        if direct || selected == nil {
            phase = .offRoad
            locator.start()
            if let f = myFix() { ingest(f) }
            if let leg = offRoad {
                let way = "\(NavText.compassDefinite(leg.bearing))، \(NavText.spokenInDistance(leg.distanceM) ?? "")"
                let arrow = { (lead: String) in SaryVoiceScript.arrow(lead: lead, bearing: leg.bearing, distanceM: leg.distanceM) }
                if auto, fallback == .offline {
                    voice.say(intro + NavLine("ما فيه إنترنت لحساب الطريق. اتجه مع السهم \(way). نعيد المحاولة لما يرجع الاتصال", clips: arrow("rr_06")))
                } else if auto {
                    voice.say(intro + NavLine("بدون طريق معبّد. اتجه مع السهم \(way)", clips: arrow("bar_01")))
                } else {
                    voice.say("لا يوجد طريق معروف. اتجه \(NavText.compassDefinite(leg.bearing)) \(NavText.spokenInDistance(leg.distanceM) ?? "")", clips: arrow("dir_07"))
                }
            }
            if auto { scheduleRetry() }
            UIApplication.shared.isIdleTimerDisabled = true
            return
        }
        guard let r = selected else { return }
        active = r
        routeRevision += 1
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
            if r.steps.count > 1, let line = self.guidanceLine(stepIndex: 1, distanceM: r.steps.first?.distanceM ?? 0) {
                self.voice.say(intro + line)
            } else if !intro.clips.isEmpty || !intro.text.isEmpty {
                self.voice.say(intro)
            }
        }
        /* The trip's guidance keeps a location stream of its own: the voice goes on with the
         * screen locked even when this phone is not sharing (the Mapbox engine ignores the fixes). */
        if auto { locator.start() }
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
                voice.say("خرجت عن الطريق، نحسب طريقًا جديدًا", clips: ["rr_01"])
            }
        case let .rerouted(r):
            guard phase == .guiding else { return }
            rerouting = false
            active = r
            routeRevision += 1
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
                voice.say(auto ? "انتهى الطريق المعبّد. اتجه مع السهم \(NavText.compassDefinite(leg.bearing))، \(NavText.spokenInDistance(leg.distanceM) ?? "")"
                               : "انتهى الطريق. \(NavOffRoad.summary(leg))",
                          clips: SaryVoiceScript.arrow(lead: "dir_05", bearing: leg.bearing, distanceM: leg.distanceM))
                if let f = myFix() { ingest(f) }
            } else {
                arrive()
            }
        case let .speak(t):
            /* Our own engine names the step: build the line here (stage, «ثم», revision). */
            if let i = t.maneuverID.flatMap(Int.init) {
                if let line = guidanceLine(stepIndex: i, distanceM: progress?.distanceToManeuverM ?? 0) { voice.say(line) }
            } else {
                voice.say(t)
            }
        case let .cue(routerText):
            if let p = progress, active?.steps.indices.contains(p.stepIndex) == true {
                if let line = guidanceLine(stepIndex: p.stepIndex, distanceM: p.distanceToManeuverM) { voice.say(line) }
            } else if NavText.isArabic(routerText) {
                /* Router narration only as a last resort, and never in another language
                 * (Valhalla narrates in English around Arabic street names). No clips: free
                 * text has no structure to map, so «صوت سرى» waits for the next cue. */
                voice.say(routerText, clips: [])
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
        retryTask?.cancel()
        voice.say(auto ? "وصلتوا \(target?.name ?? "")" : "وصلت إلى \(target?.name ?? "وجهتك")", clips: [target?.source == .rally ? "start_07" : auto ? "arr_01" : "arr_02"])
        UIApplication.shared.isIdleTimerDisabled = false
        if let t = target { onArrived(t) }
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
        retryTask?.cancel()
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
        auto = false
        fallback = nil
        retryable = false
        autoIntro = nil
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

    /// UI tests: arrive at the current target as if driven there (the real `arrive()` path).
    func debugArrive() {
        guard phase == .guiding || phase == .offRoad else { return }
        arrive()
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
    /// Stale, coarse and teleporting fixes never steer the last leg (`FixQualityGate`).
    private var gate = FixQualityGate(keepsFirstStale: false)

    override init() {
        super.init()
        manager.delegate = self
        /* Guidance: the best the chip can do (Apple: BestForNavigation while navigating), the
         * generic navigation model (no road snapping off-road), no distance filter, never paused. */
        manager.activityType = .otherNavigation
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = kCLDistanceFilterNone
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
        manager.showsBackgroundLocationIndicator = false
        gate.reset()
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let fixes = locations.compactMap(LocationTuning.deviceFix)
        Task { @MainActor in
            let now = Date().timeIntervalSince1970 * 1000
            for f in fixes { if case let .accept(ok) = self.gate.judge(f, nowMs: now) { self.onFix(ok) } }
        }
    }
}

/// «الملاحة» in one line for the Lock Screen / Dynamic Island (the widget cannot link `NavText`).
struct NavActivityLine: Equatable {
    var text: String
    var symbol: String
    var arrived = false
}

extension NavSession {
    var activityLine: NavActivityLine? {
        switch phase {
        case .guiding:
            if rerouting { return NavActivityLine(text: "نعيد حساب الطريق…", symbol: "arrow.triangle.2.circlepath") }
            guard let step = currentStep else { return nil }
            let d = progress?.distanceToManeuverM ?? step.distanceM
            let inD = NavText.inDistance(d).map { $0 + " " } ?? ""
            return NavActivityLine(text: inD + NavText.instruction(step, targetName: target?.name), symbol: NavGlyph.symbol(step.maneuver))
        case .offRoad:
            guard let leg = offRoad else { return nil }
            return NavActivityLine(text: NavOffRoad.line(leg, remainingM: offRoadNow?.distanceM, bearing: offRoadNow?.bearing, fallback: fallback),
                                   symbol: "location.north.fill")
        case .arrived:
            return NavActivityLine(text: "\(auto ? "وصلتوا" : "وصلت") \(target?.name ?? "")", symbol: "flag.checkered", arrived: true)
        case .idle, .planning:
            return nil
        }
    }
}
