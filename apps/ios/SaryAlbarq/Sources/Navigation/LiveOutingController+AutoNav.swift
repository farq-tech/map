import Foundation

/// The trip's automatic guidance on the live screen (`TripAutoNav` decides, this applies):
/// the outing is active with a destination ⇒ turn-by-turn to the next stop / the destination,
/// for every member, after a relaunch too; on to the next stop on arrival; «وصلتوا» at the end.
/// «أوقف التوجيه» / «استأنف» and the setting only change this phone.
extension LiveOutingController {
    /// The plan's stops, in order (none on a plan without them).
    var tripStops: [OutingDestination] { planModel?.plan.stops ?? [] }

    /// Real outings always; the `-demo` outing only with `-SaryAutoNav` (UI tests and
    /// screenshots opt in, so the other demo tests keep their own navigation).
    var autoNavAllowed: Bool {
        #if DEBUG
        if session.isDemo { return ProcessInfo.processInfo.arguments.contains("-SaryAutoNav") }
        #endif
        return !session.isDemo
    }

    var autoNavEnabled: Bool { TripAutoNavPrefs.enabled() }

    func registerAutoNav() {
        autoNavState = TripAutoNavState.load(session.id)
        autoNavWasOnline = followOnline
        nav.onArrived = { [weak self] t in self?.autoNavArrived(t) }
        session.navSnapshot = { [weak self] in self?.nav.activityLine }
        #if DEBUG
        autoNavDebugLaunch()
        #endif
        DispatchQueue.main.async { [weak self] in self?.autoNavTick() }
    }

    var autoNavInput: TripAutoNav.Input {
        var i = TripAutoNav.Input()
        i.enabled = autoNavEnabled
        i.state = autoNavState
        i.status = session.view?.status
        i.closed = session.closedReason != nil || autoNavLeft
        i.destination = tripDestination
        i.stops = tripStops
        i.tripArrived = trip.record.me.arrived
        i.hasFix = location.lastFix.map { Date().timeIntervalSince1970 * 1000 - $0.atMs < 120_000 } ?? false
        i.navPhase = nav.phase
        i.navAuto = nav.auto
        i.navTarget = nav.target
        i.arrivedAgoS = nav.arrivedAt.map { Date().timeIntervalSince($0) }
        return i
    }

    /// Every change (session, GPS, the trip clock): decide, then act.
    func autoNavTick() {
        guard autoNavAllowed else { return }
        if let f = location.lastFix, Date().timeIntervalSince1970 * 1000 - f.atMs < 30_000, !tripStops.isEmpty {
            let s = TripAutoNav.passStops(autoNavState, stops: tripStops, me: LngLat(lng: f.lng, lat: f.lat), accuracy: f.accuracy)
            if s != autoNavState { setAutoNavState(s) }
        }
        autoNavOffRoadTrack()
        switch TripAutoNav.decide(autoNavInput) {
        case .none:
            break
        case let .start(t):
            /* «طريق العودة» / «اسلك هذا المسار» chosen by the person: theirs until they stop it. */
            guard backTrack == nil, trackFollow == nil || autoNavFollowId != nil else { return }
            /* Not before the plan has loaded: its stops decide where the first leg goes. */
            guard planModel?.planPhase != .loading else { return }
            autoNavGo(t, resumed: nav.phase == .arrived)
        case let .retarget(t):
            autoNavGo(t, resumed: true)
        case .finish:
            nav.finishArrival()
        case .stop:
            nav.end()
            stopAutoFollow()
        }
    }

    private func autoNavGo(_ t: NavTarget, resumed: Bool) {
        stopAutoFollow()
        if modal == .navOptions || modal == .navSteps { modal = nil }
        following = false
        nav.autoStart(to: t, intro: TripAutoNav.intro(t, resumed: resumed))
        navCameraKey += 1
    }

    /// The network came back (the live link is up again): the offline fallback tries the road now.
    func autoNavSessionChanged() {
        let online = followOnline
        defer { autoNavWasOnline = online }
        if online, !autoNavWasOnline { nav.retryNow() }
        autoNavTick()
    }

    private func autoNavArrived(_ t: NavTarget) {
        guard nav.auto else { return }
        setAutoNavState(TripAutoNav.arrived(autoNavState, at: t, stops: tripStops))
        stopAutoFollow()
        UINotificationFeedback.success()
        if t.source == .destination {
            /* The group hears it on their own phones from my shared position (`memberArrived`). */
            selectedTab = .trip
        }
    }

    func setAutoNavState(_ s: TripAutoNavState) {
        autoNavState = s
        s.save(session.id)
    }

    /// «أوقف التوجيه» (this phone only).
    func pauseAutoNav() {
        var s = autoNavState
        s.paused = true
        setAutoNavState(s)
        toast("أوقفنا التوجيه على جوالك فقط")
    }

    /// «استأنف».
    func resumeAutoNav() {
        var s = autoNavState
        s.paused = false
        setAutoNavState(s)
        if !autoNavEnabled { TripAutoNavPrefs.set(true) }
        autoNavTick()
    }

    /// «ابدأ التوجيه تلقائيًا مع الرحلة».
    func setAutoNavEnabled(_ on: Bool) {
        TripAutoNavPrefs.set(on)
        if !on, nav.auto { nav.end(); stopAutoFollow() }
        objectWillChange.send()
        if on { autoNavTick() }
    }

    /// The trip is on, its guidance is paused (or off) here: «استأنف التوجيه» in the peek.
    var showsAutoNavResume: Bool {
        guard autoNavAllowed, !nav.isActive, nav.phase != .planning, session.view?.status == .active, session.closedReason == nil,
              tripDestination != nil, !autoNavState.arrived, !trip.record.me.arrived else { return false }
        return autoNavState.paused || !autoNavEnabled
    }

    // MARK: off-road along the plan's track

    /// In the straight-line leg after the road (not the no-road / offline fallback, which says
    /// why it is a straight line), when the plan's drawn route ends at
    /// the target: «اسلك هذا المسار» along it (it says how far off the track I am) instead of
    /// only the bearing. The navigation's own arrival still ends the leg.
    private func autoNavOffRoadTrack() {
        guard nav.auto, nav.phase == .offRoad, !nav.direct, trackFollow == nil, let t = nav.target, autoNavFollowId == nil else { return }
        let pts = planModel?.plan.points ?? []
        guard pts.count >= 2, let end = pts.last, Vehicle.distanceMeters(end, t.position) <= Self.planTrackEndM,
              let s = FollowSubject.plan(points: pts, name: "مسار الخطة") else { return }
        autoNavFollowId = s.id
        startFollow(s)
    }

    /// The plan's route counts as leading to the target when it ends this close to it.
    static let planTrackEndM = 300.0

    func stopAutoFollow() {
        guard let id = autoNavFollowId else { return }
        autoNavFollowId = nil
        if trackFollow?.id == id { stopFollow() }
    }

    #if DEBUG
    /// UI tests: `-SaryAutoNavArrive <s>` arrives at the current target after s seconds, and
    /// again at each next target until the destination (the real arrival path, no driving).
    private func autoNavDebugLaunch() {
        let a = ProcessInfo.processInfo.arguments
        func arg(_ k: String) -> Double? { a.firstIndex(of: k).flatMap { $0 + 1 < a.count ? Double(a[$0 + 1]) : nil } }
        /* `-SaryNavRetry <s>`: the offline fallback retries the road this often (default 20 s). */
        if let r = arg("-SaryNavRetry") { nav.retryInterval = r }
        /* `-SaryAutoNavRouteEnd <s>`: the road part ends after s seconds (the off-road leg follows). */
        if let e = arg("-SaryAutoNavRouteEnd") {
            func routeEndLater() {
                DispatchQueue.main.asyncAfter(deadline: .now() + e) { [weak self] in
                    guard let self else { return }
                    if self.nav.phase == .guiding { self.nav.handle(.arrivedAtRouteEnd) } else if self.nav.phase != .offRoad { routeEndLater() }
                }
            }
            routeEndLater()
        }
        guard let i = a.firstIndex(of: "-SaryAutoNavArrive"), i + 1 < a.count, let s = Double(a[i + 1]) else { return }
        func arriveLater() {
            DispatchQueue.main.asyncAfter(deadline: .now() + s) { [weak self] in
                guard let self else { return }
                if self.nav.phase == .guiding || self.nav.phase == .offRoad {
                    let wasStop = self.nav.target?.source == .tripStop
                    self.nav.debugArrive()
                    if wasStop { arriveLater() }
                } else if !self.autoNavState.arrived {
                    arriveLater()
                }
            }
        }
        arriveLater()
    }
    #endif
}
