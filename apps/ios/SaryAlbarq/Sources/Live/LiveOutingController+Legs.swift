import Foundation

/// «الطلعة» و«المشوار» on the live screen (`OutingFlow` decides, this applies): the header's
/// state line, the one big button at the bottom, «وين رايحين؟», «ابدأ المشوار», «وصلنا»,
/// «أنهِ الطلعة», and «سجل الطلعة». See ux/الطلعة-والمشوار.md.
extension LiveOutingController {
    var legs: OutingLegsCenter { OutingLegsCenters.of(self) }

    /// Called from `registerTrip()`.
    func registerLegs() {
        #if DEBUG
        legsDebugLaunch()
        #endif
        let c = legs
        c.onNewLeg = { [weak self] leg in self?.legBegan(leg) }
        session.events.receive(on: DispatchQueue.main).sink { [weak self] e in
            if case .outingStatus(.ended) = e { self?.legs.outingEnded() }
        }.store(in: &bag)
        c.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        c.poll { [weak self] in self?.session.view?.status == .active && self?.session.isVisible == true }
        Task { await c.refresh() }
    }

    // MARK: state

    /// The leader's plan destination counts as «picked» while no leg goes there yet
    /// (chosen with «اجعلها الوجهة», or the outing's from «طلعة جديدة»).
    var legPicked: OutingDestination? {
        if let p = legs.picked { return p }
        guard session.view?.iLead == true, legs.current == nil, let d = planModel?.plan.destination else { return nil }
        if let last = legs.timeline.last, Vehicle.distanceMeters(LngLat(lng: last.destination.lng, lat: last.destination.lat), LngLat(lng: d.lng, lat: d.lat)) < 100 { return nil }
        return d
    }

    var flowInput: OutingFlowInput {
        let v = session.displayView
        var i = OutingFlowInput()
        i.status = v?.status
        i.iLead = v?.iLead == true
        i.iOwn = v?.iOwn == true
        i.legs = legs.legs
        i.picked = legPicked
        if legs.current != nil, let a = trip.record.me.arrivedAtMs { i.myArrivedAt = Date(timeIntervalSince1970: a / 1000) }
        i.now = Date()
        if let v {
            let others = v.positions.keys.filter { $0 != v.myId && v.members[$0]?.sharing == true && v.freshness(of: $0, deviceNow: i.now) == .live }
            i.liveCount = others.count + (session.isSharingNow ? 1 : 0)
            let livePts = v.positions.filter { others.contains($0.key) }.map { LngLat(lng: $0.value.lng, lat: $0.value.lat) }
                + (location.lastFix.map { [LngLat(lng: $0.lng, lat: $0.lat)] } ?? [])
            i.endSuggested = OutingEndSuggest.shouldSuggest(
                startedAt: LiveOutingPresenter.deviceDate(v.snapshot.outing.started_at, view: v),
                groupStart: trip.record.groupStart?.position, livePositions: livePts, hasActiveLeg: legs.current != nil, now: i.now)
        }
        if legs.current != nil {
            let p = tripPanel
            i.remainingM = p.remainingMeters
            i.eta = p.eta
        }
        return i
    }

    var flowUI: OutingFlowUI { OutingFlow.ui(flowInput) }

    // MARK: actions

    func flowTapped(_ cta: OutingCTA) {
        switch cta {
        case .startOuting: startOutingFlow()
        case .waitLeader: toast("تبدأ المشاركة أول ما يبدأ أمير الرحلة الطلعة")
        case .whereTo, .changeDestination: modal = .whereTo
        case .startLeg: startLegFlow()
        case .arrived: arrivedTapped()
        case .endOuting: legConfirmEnd = true
        case .summary: openSummary()
        }
    }

    /// «ابدأ الطلعة»: an outing needs no destination (a leg does). With one already chosen,
    /// its first leg starts with it, and the leader is offered guidance for everyone.
    func startOutingFlow() {
        Task {
            await session.setStatus("start")
            guard session.view?.status == .active else { return }
            if let d = legPicked {
                await beginLeg(to: d)
            } else {
                toast("بدأت الطلعة · وين رايحين؟")
            }
        }
    }

    /// «وين رايحين؟» picked a place. A leader's choice is also the outing's destination
    /// (the plan), so phones on older builds see it; a member's stays on this phone until «ابدأ المشوار».
    func pickLegDestination(_ d: OutingDestination) {
        modal = nil
        RecentPlaces.add(d)
        legs.picked = d
        if session.view?.iLead == true, let plan = planModel {
            Task { _ = await plan.setDestination(d) }
        }
        objectWillChange.send()
    }

    /// «ابدأ المشوار».
    func startLegFlow() {
        guard let d = legPicked else { modal = .whereTo; return }
        Task { await beginLeg(to: d) }
    }

    private func beginLeg(to d: OutingDestination) async {
        let lead = session.view?.iLead == true
        guard let leg = await legs.start(d, scope: lead ? .group : .personal, myId: session.view?.myId) else {
            toast("ما قدرنا نبدأ المشوار، جرّب مرة ثانية")
            return
        }
        UINotificationFeedback.success()
        toast("يلا! في الطريق إلى \(leg.destination.name)")
        /* «وجّه الكل»: the leader's choice (for everyone, or only for him); a member guides only himself. */
        if lead { offerGuidanceChoice() } else if autoNavAllowed { startGuidanceForMe() }
    }

    /// A leg this phone has not begun (mine, or the leader's arriving from the server).
    func legBegan(_ leg: OutingLeg) {
        trip.beginLeg()
        var s = autoNavState
        s.arrived = false
        s.reachedStops = []
        s.paused = false
        setAutoNavState(s)
        updateTrip()
        objectWillChange.send()
    }

    /// «وصلنا»: on this phone at once; it ends the leg for all when it is the leader's group leg (or my own).
    func arrivedTapped() {
        /* The tracker's `.arrived` event closes the leg (`legArrivedHere`), detected or tapped alike. */
        if trip.record.me.arrived { legArrivedHere() } else { trip.markArrived(myId: session.displayView?.myId ?? session.myUserId) }
    }

    /// My arrival (detected or tapped): close the leg I may close.
    func legArrivedHere() {
        guard let leg = legs.current, leg.isActive else { return }
        let mayClose = leg.scope == .personal || session.view?.iLead == true
        guard mayClose else { objectWillChange.send(); return }
        let at = trip.record.me.arrivedAtMs.map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date()
        let since = leg.startedDate.map { $0.timeIntervalSince1970 * 1000 } ?? 0
        let driven = TripMath.drivenMeters(trail: session.displayTrail, sinceMs: since)
        Task { await legs.arrive(leg.id, at: at, distanceM: driven > 0 ? Int(driven) : nil) }
    }

    /// «أنهِ الطلعة» confirmed.
    func endOutingFlow() {
        legConfirmEnd = false
        legs.outingEnded()
        endTrip()
    }

    #if DEBUG
    /// UI tests / screenshots: `-SaryLegsDemo` offers two near places in «وين رايحين؟» and lets
    /// `-SaryLegArriveAfter <s>` arrive on its own.
    private func legsDebugLaunch() {
        let a = ProcessInfo.processInfo.arguments
        guard session.isDemo, a.contains("-SaryLegsDemo") else { return }
        RecentPlaces.forget()
        RecentPlaces.add(OutingDestination(name: "مخيم النفود", lat: 24.7590, lng: 46.7491))
        RecentPlaces.add(OutingDestination(name: "محطة الوقود", lat: 24.7240, lng: 46.6960))
        OutingLegStore.save(session.id, [])
    }
    #endif
}

extension LiveOutingController {
    /// «أنهِ الطلعة؟» confirmation (kept off the controller's stored state: a per-outing flag).
    var legConfirmEnd: Bool {
        get { LegConfirm.open.contains(session.id) }
        set {
            if newValue { LegConfirm.open.insert(session.id) } else { LegConfirm.open.remove(session.id) }
            objectWillChange.send()
        }
    }
}

@MainActor
private enum LegConfirm { static var open = Set<String>() }
