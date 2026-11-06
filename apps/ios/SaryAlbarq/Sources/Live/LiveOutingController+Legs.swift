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
        /* After `registerAutoNav()` has set its own arrival handler: chain, never replace. */
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let prev = self.nav.onArrived
            self.nav.onArrived = { [weak self] t in
                prev(t)
                self?.legNavArrived(t)
            }
        }
        Task { await c.refresh() }
    }

    /// One arrival moment, 4 s (`OutingFlow.momentS`).
    func arrivalToast(_ text: String) {
        pushAlert(LiveAlertUI(id: "toast:arrived:\(UUID().uuidString)", kind: .toast(text)), ttl: OutingFlow.momentS)
    }

    /// The guidance's «وصلتوا» card is the moment: it gives the screen back after 4 s,
    /// so the header's «واقفين عند X» and the one primary button are all that stays.
    func closeArrivalCardSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + OutingFlow.momentS) { [weak self] in
            guard let self, self.nav.phase == .arrived else { return }
            self.endNav()
        }
    }

    /// The trip's guidance reached the leg's destination: that is the leg's arrival too.
    func legNavArrived(_ t: NavTarget) {
        guard t.source == .destination, legs.current != nil else { return }
        closeArrivalCardSoon()
        if !trip.record.me.arrived { trip.markArrived(myId: session.displayView?.myId ?? session.myUserId) }
    }

    // MARK: state

    /// «ابدأ المشوار» is waiting: chosen in «وين رايحين؟», or (the leader) a new plan destination
    /// after earlier legs (chosen with «اجعلها الوجهة» in the place search).
    var legPicked: OutingDestination? {
        if let p = legs.picked { return p }
        guard session.view?.iLead == true, legs.current == nil, let last = legs.timeline.last, let d = planModel?.plan.destination else { return nil }
        if Vehicle.distanceMeters(LngLat(lng: last.destination.lng, lat: last.destination.lat), LngLat(lng: d.lng, lat: d.lat)) < 100 { return nil }
        return d
    }

    /// An outing from before legs (builds ≤ 22, or a destination set straight from the place
    /// search) that is running toward its plan's destination: that IS its current leg.
    var implicitLeg: OutingLeg? {
        guard legs.legs.isEmpty, legs.picked == nil, let v = session.displayView, v.status == .active,
              let d = planModel?.plan.destination else { return nil }
        return OutingLeg(id: "plan", seq: 0, scope: .group, destination: d, started_at: v.snapshot.outing.started_at ?? ISODate.string(Date()))
    }

    var flowInput: OutingFlowInput {
        let v = session.displayView
        var i = OutingFlowInput()
        i.status = v?.status
        i.iLead = v?.iLead == true
        i.iOwn = v?.iOwn == true
        let implicit = implicitLeg
        i.legs = implicit.map { [$0] } ?? legs.legs
        i.picked = legPicked
        if legs.current != nil || implicit != nil, let a = trip.record.me.arrivedAtMs { i.myArrivedAt = Date(timeIntervalSince1970: a / 1000) }
        i.now = Date()
        if let v {
            let others = v.positions.keys.filter { $0 != v.myId && v.members[$0]?.sharing == true && v.freshness(of: $0, deviceNow: i.now) == .live }
            /* The same count as the sheet's «… مباشر». */
            i.liveCount = ui.participantsTab.participants.filter { $0.presence.isLive }.count
            let livePts = v.positions.filter { others.contains($0.key) }.map { LngLat(lng: $0.value.lng, lat: $0.value.lat) }
                + (location.lastFix.map { [LngLat(lng: $0.lng, lat: $0.lat)] } ?? [])
            i.endSuggested = OutingEndSuggest.shouldSuggest(
                startedAt: LiveOutingPresenter.deviceDate(v.snapshot.outing.started_at, view: v),
                groupStart: trip.record.groupStart?.position, livePositions: livePts, hasActiveLeg: legs.current != nil || implicitLeg != nil, now: i.now)
        }
        if legs.current != nil || implicit != nil {
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
            if let d = legs.picked ?? planModel?.plan.destination {
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
