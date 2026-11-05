import Foundation

/// The trip's guidance on the live screen (`TripAutoNav` / `NavBroadcast` decide, this applies).
/// «أمير الرحلة»: «ابدأ التوجيه للكل» (his note tells every phone) or «لي فقط». Everyone else:
/// only for themselves. Once on, turn-by-turn to the next stop / the destination, after a
/// relaunch too; on to the next stop on arrival; «وصلتوا» at the end.
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

    /// «ابدأ التوجيه تلقائيًا مع الرحلة»: accept the leader's «للكل» without asking.
    var autoNavEnabled: Bool { TripAutoNavPrefs.enabled() }

    /// I may start guidance for everyone (the current leader; the deputy only if `NavBroadcast` allows).
    var canGuideAll: Bool {
        guard let v = session.view, v.status == .active || v.status == .created else { return false }
        return v.iOwn || (NavBroadcast.deputyMayBroadcast && v.members[v.myId]?.co_leader == true)
    }

    /// The trip's next target as this phone has reached it (for «وجّه الكل إلى …»).
    var autoNavNextTarget: NavTarget? {
        TripAutoNav.nextTarget(destination: tripDestination, stops: tripStops, reached: autoNavState.reachedStops)
    }

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

    /// Every session change: the leader's group command (a note), the network coming back
    /// (the offline fallback tries the road now), then decide.
    func autoNavSessionChanged() {
        let online = followOnline
        defer { autoNavWasOnline = online }
        if online, !autoNavWasOnline { nav.retryNow() }
        receiveBroadcasts()
        autoNavTick()
    }

    /// «أمير الرحلة بدأ التوجيه إلى …»: a group command in a member's current note. The sender's
    /// role is checked here, on receipt: anyone else's command is ignored. Also how a late joiner
    /// (or a relaunch) picks up the leader's last command: it is still his note.
    private func receiveBroadcasts() {
        guard autoNavAllowed, let v = session.displayView, v.status == .active, session.closedReason == nil else { return }
        let owner = v.snapshot.outing.owner_id
        for (uid, m) in v.members where uid != v.myId {
            guard let n = m.note, NavBroadcast.isBroadcast(n.text) else { continue }
            var s = autoNavState
            let r = NavBroadcast.receive(&s, text: n.text, at: n.at, senderId: uid, ownerId: owner, senderIsDeputy: m.co_leader == true,
                                         myId: v.myId, autoAccept: autoNavEnabled)
            if s != autoNavState { setAutoNavState(s) }
            let target = NavBroadcast.targetName(n.text) ?? tripDestination?.name ?? "الوجهة"
            switch r {
            case .start:
                toast("أمير الرحلة بدأ التوجيه إلى \(target)")
            case .offer:
                UINotificationFeedback.warning()
            case .ignored, .none:
                break
            }
        }
    }

    /// «ابدأ التوجيه» / «لي فقط» / «استأنف»: on this phone only.
    func startGuidanceForMe() {
        var s = autoNavState
        s.active = true
        s.paused = false
        s.offered = false
        setAutoNavState(s)
        if modal == .navStartChoice { modal = nil }
        autoNavTick()
    }

    /// «ابدأ التوجيه للكل» (the leader): my own guidance, and the group command in my note.
    func startGuidanceForAll() {
        guard canGuideAll else { return toast("التوجيه للكل لأمير الرحلة فقط") }
        startGuidanceForMe()
        let name = autoNavNextTarget?.name ?? tripDestination?.name ?? "الوجهة"
        Task {
            if await session.sendNote(NavBroadcast.text(targetName: name)) {
                toast("بدأ التوجيه للكل إلى \(name)")
            } else {
                toast("ما وصل الأمر للمجموعة. التوجيه شغّال على جوالك، جرّب «وجّه الكل» مرة ثانية")
            }
        }
    }

    /// After «ابدأ الطلعة»: the leader's choice («للكل» highlighted, or «لي فقط»).
    func offerGuidanceChoice() {
        guard autoNavAllowed, canGuideAll, tripDestination != nil else { return }
        modal = .navStartChoice
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
    func resumeAutoNav() { startGuidanceForMe() }

    /// «ابدأ التوجيه تلقائيًا مع الرحلة» (accept the leader's «للكل» without asking).
    func setAutoNavEnabled(_ on: Bool) {
        TripAutoNavPrefs.set(on)
        objectWillChange.send()
    }

    /// The one guidance button in the peek while the trip runs without guidance on this phone:
    /// the leader's offer, «استأنف التوجيه» after a pause, or «ابدأ التوجيه» (for me only).
    enum GuidancePrompt: Equatable {
        case leaderStarted
        case resume
        case start
    }

    var guidancePrompt: GuidancePrompt? {
        guard autoNavAllowed, !nav.isActive, nav.phase != .planning, session.view?.status == .active, session.closedReason == nil,
              tripDestination != nil, !autoNavState.arrived, !trip.record.me.arrived else { return nil }
        if autoNavState.offered && !autoNavState.active { return .leaderStarted }
        if autoNavState.paused { return .resume }
        return autoNavState.active ? nil : .start
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
        /* `-SaryAutoNavActive`: guidance already on for this phone (a relaunch mid-trip). */
        if a.contains("-SaryAutoNavActive") { var s = autoNavState; s.active = true; setAutoNavState(s) }
        /* `-SaryAutoNavAsk`: the setting off (the leader's «للكل» is offered, not started). */
        if a.contains("-SaryAutoNavAsk") { TripAutoNavPrefs.set(false) }
        /* `-SaryDemoLeaderBroadcast <s>` / `-SaryDemoFakeBroadcast <s>`: the leader's «للكل»
           (or the same text from a non-leader, which must be ignored) reaches this phone. Play a
           member with `-SaryDemoMe 00000000-0000-4000-8000-000000000002`. */
        for (flag, from) in [("-SaryDemoLeaderBroadcast", DemoData.meId), ("-SaryDemoFakeBroadcast", "00000000-0000-4000-8000-000000000003")] {
            guard let d = arg(flag) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + d) { [weak self] in
                guard let self else { return }
                let name = self.tripDestination?.name ?? "الوجهة"
                self.session.debugApply(.memberNote(userId: from, note: MemberNote(text: NavBroadcast.text(targetName: name), at: ISODate.string(Date()))))
            }
        }
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

extension LiveOutingController {
    /// «أمير الرحلة» (the title the outing uses for its leader).
    var leaderName: String { "أمير الرحلة" }
}
