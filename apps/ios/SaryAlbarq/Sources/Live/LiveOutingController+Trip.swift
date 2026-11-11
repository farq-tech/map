import Foundation
import UIKit

/// «الرحلة» wiring on the live screen: what the trip is decided from (the plan's
/// destination and route, my GPS and trail, the navigation), the events it raises,
/// and its actions. The rules themselves are pure (`TripRecord`, `TripPresenter`).
extension LiveOutingController {
    /// The trip's destination: the outing's (the plan's), never a guess.
    /// The current «مشوار» first (mine, else the group's), then the plan's.
    var tripDestination: OutingDestination? { legs.current?.destination ?? planModel?.plan.destination }

    /// The outing this one is «طريق العودة» from (this phone only).
    var returnOrigin: String? { ReturnTripStore.origin(of: session.id) }

    func registerTrip() {
        /* The navigation picker must follow the active leg when it differs from the old plan. */
        navDestination = { [weak self] in self?.tripDestination }
        navPlanRoute = { [weak self] in self?.planModel?.plan.points ?? [] }
        trip.onEvent = { [weak self] e in self?.tripEvent(e) }
        session.tripSnapshot = { [weak self] in
            guard let self, self.tripDestination != nil else { return nil }
            return self.tripPanel
        }
        registerLegs()
        trip.startClock { [weak self] in
            guard let self else { return }
            self.updateTrip()
            self.autoNavTick()
            /* Ages and the elapsed time tick on screen. */
            if self.trip.record.start != nil, self.session.view?.status != .ended { self.objectWillChange.send() }
        }
        #if DEBUG
        tripDebugLaunch()
        #endif
    }

    func updateTrip() {
        trip.update(view: session.displayView, myFix: location.lastFix, destination: tripDestination)
    }

    /// `TripLogStore.load(session.id)`, decoded again only when the stored bytes changed (one more
    /// fix shared): `tripInput` is read several times per render (`input`, `tripPanel`).
    func storedTripLog() -> TripLog? {
        let id = session.id
        return tripLogMemo.value(for: UserDefaults.standard.data(forKey: TripLogStore.key)) { _ in TripLogStore.load(id) }
    }

    var tripInput: TripPresenterInput {
        var i = TripPresenterInput()
        let v = session.displayView
        i.record = trip.record
        /* A leg's numbers start with the leg (not the outing): «قطعنا» / «المدة» / ETA agree with «سجل الطلعة». */
        if let leg = legs.current ?? LegLifecycle.lastArrived(legs.legs), let ls = leg.startedDate, var st = i.record.start {
            st.atMs = max(st.atMs, ls.timeIntervalSince1970 * 1000)
            i.record.start = st
        }
        i.destination = tripDestination
        i.status = v?.status
        i.iLead = v?.iOwn == true
        i.myId = v?.myId ?? session.myUserId
        i.myFix = session.smoothedFix(location.lastFix)
        i.trail = session.displayTrail
        i.log = session.isDemo ? speed.local : storedTripLog()
        if nav.phase == .guiding || nav.phase == .offRoad {
            i.navGuiding = true
            i.navRemainingM = nav.remainingMeters
            i.navTarget = nav.target?.position
            i.navETA = nav.etaDate
        }
        i.planRoute = planModel?.plan.points ?? []
        i.members = (v?.orderedMembers ?? []).map { ($0.user_id, $0.display_name) }
        i.groupStart = trip.record.groupStart
        i.isReturnTrip = returnOrigin != nil
        i.now = Date()
        return i
    }

    var tripPanel: TripPanelUI { TripPresenter.panel(tripInput) }

    /// The trip strip in the sheet's peek row (once the outing is loaded and I am in it).
    var showsTripStrip: Bool { session.displayView?.me != nil && session.closedReason.map { $0 == .outingEnded } ?? true }

    var tripActions: TripPanelActions {
        TripPanelActions(
            setDestination: { [weak self] in self?.chooseTripDestination() },
            markArrived: { [weak self] in self?.markArrived() },
            endTrip: { [weak self] in self?.endTrip() },
            openSummary: { [weak self] in self?.openSummary() },
            returnTrip: { [weak self] in self?.startReturnTrip() },
            followOldTrail: { [weak self] in self?.followOldTrail() },
            expand: { [weak self] in
                self?.modal = .panel(.route)
            })
    }

    /// «حدّد الوجهة»: the place search (its point card has «اجعلها الوجهة»).
    func chooseTripDestination() {
        /* A direct swap (`sheet(item:)` replaces the presented sheet when the item changes): no
         * nil → 0.35 s → reopen flicker. */
        modal = .plan(.search)
    }

    func markArrived() {
        trip.markArrived(myId: session.displayView?.myId ?? session.myUserId)
        objectWillChange.send()
    }

    /// «أنهِ الرحلة» (asked first in the view): ends the outing for everyone.
    func endTrip() {
        tripConfirmEnd = false
        if nav.isActive || nav.phase == .planning { nav.end(); modal = nil }
        if backTrack != nil { stopBackTrack() }
        /* `-demo` keeps no trip log of its own: the screen's one goes to the summary. */
        if session.isDemo { let l = speed.local; TripLogStore.update(session.id) { $0 = l } }
        /* #173: ending is for everyone, so the server decides (never faked); this line answers the tap now. */
        if !session.isLocal { toast("جاري إنهاء الطلعة…") }
        Task { await session.setStatus("end") }
    }

    /// The trip is over on this phone (ended here or by the leader's phone, or I left / was
    /// removed): every guidance of this screen stops, once. `TripAutoNav` stops only the trip's own
    /// guidance; a person's own («روح له», a map point via `NavSession.startImmediately`) used to
    /// keep its GPS (`NavLocator` / the Mapbox trip), its offline retries and the blue location
    /// arrow running after the trip ended.
    func stopGuidanceWhenTripOver() {
        guard !tripEndHandled, session.closedReason != nil || session.view?.status == .ended else { return }
        tripEndHandled = true
        if nav.isActive || nav.phase == .planning { nav.end() }
        stopAutoFollow()
        if backTrack != nil { stopBackTrack() }
        if fixWait != nil {
            fixWait = nil
            location.endFreshFixRequest()
        }
        if modal == .navOptions || modal == .navSteps { modal = nil }
    }

    /// Return trip: guide back along the trail of the outing it came back from — the WHOLE
    /// trail, city included (the person's explicit choice «على مساري»).
    func followOldTrail() {
        guard let old = returnOrigin, let t = TrailStore.load(old), t.points.count >= 2 else {
            toast("ما عندنا مسار محفوظ للطلعة السابقة على هذا الجوال.")
            return
        }
        /* Replaces the automatic desert leg: no hand-over to the road at the junction. */
        returnGuide.cancel()
        startBackTrack(along: t.points)
    }

    /// «طريق الرجعة» on this phone, with no server (UI-AUDIT 0.3): back along my trail of this
    /// outing to where I started (`BackTrack`: works with no network, the usual case in the desert).
    /// Used when the new return trip cannot be made on the server because there is no network.
    func startReturnOnPhone(offline: Bool) {
        guard backTrack == nil else { return }
        guard session.trail.points.count >= 2 else {
            toast(offline ? "ما فيه نت، وما عندنا مسار محفوظ لهذه الطلعة على جوالك"
                          : "ما عندنا مسار محفوظ لهذه الطلعة على جوالك")
            return
        }
        returnGuide.cancel()
        startBackTrack()
        if offline, backTrack != nil { toast("ما فيه نت · نرجّعك على مسارك من جوالك") }
    }

    // MARK: «طريق الرجعة»: the desert on the outbound trail, the city by the fastest road

    /// The trip's guidance is about to start to `t` (`TripAutoNav` said `.start`). On a return
    /// trip, from the desert part of the outbound trail: retrace ONLY that part back to the city
    /// ↔ desert junction (`BackTrack`; off it, «خرجت عن الطريق» leads back to the same trail —
    /// never a new desert route) and true (the road guidance waits). Decided once per screen:
    /// on the city side, without the old trail, or far from it → false (normal guidance).
    func startReturnDesertLegIfNeeded(_ t: NavTarget) -> Bool {
        guard returnGuide.phase == .undecided, t.source == .destination, let old = returnOrigin else { return false }
        guard let f = location.lastFix, let trail = TrailStore.load(old), trail.points.count >= 2 else {
            returnGuide.begin(.road)
            return false
        }
        let split = ReturnRoute.split(trail.points, saved: OutboundJunctionStore.load(old), match: TrailMatchStore.load(old))
        let start = ReturnRoute.start(trail: trail.points, split: split, me: LngLat(lng: f.lng, lat: f.lat))
        returnGuide.begin(start)
        guard case let .desertTrail(leg) = start else { return false }
        startBackTrack(along: leg)
        /* `startBackTrack` refused (or arrived and handed over at once): the road guidance now. */
        guard backTrack != nil, returnGuide.holdsRoadGuidance else {
            returnGuide.cancel()
            return false
        }
        toast("نرجع على نفس دربك في البر، وبعده أسرع طريق في المدينة")
        return true
    }

    /// The desert leg reached the junction: stop retracing, the trip's normal road guidance
    /// (fastest, reroutes) takes the city part to the start point.
    func handOverReturnToRoad() {
        stopBackTrack()
        toast("وصلت طرف البر · نكمل بأسرع طريق")
        DispatchQueue.main.async { [weak self] in self?.autoNavTick() }
    }

    /// While this outing's guidance to its destination drives a route: keep where that route
    /// leaves the paved road (`OutboundJunctionStore`), for a later «طريق الرجعة». Only while I
    /// am still on the city side of it (a reroute from the desert says nothing about the city).
    func recordOutboundJunction() {
        guard nav.phase == .guiding, let target = nav.target, target.source == .destination, returnOrigin == nil,
              let r = nav.active, let j = ReturnRoute.roadEnd(of: r), let f = location.lastFix else { return }
        if let s = savedRoadJunction, Vehicle.distanceMeters(s, j) < 1 { return }
        let me = LngLat(lng: f.lng, lat: f.lat)
        guard Vehicle.distanceMeters(me, target.position) > Vehicle.distanceMeters(j, target.position) else { return }
        savedRoadJunction = j
        OutboundJunctionStore.save(session.id, j)
    }

    private func tripEvent(_ e: TripRecord.Event) {
        let v = session.displayView
        switch e {
        case .started:
            break
        case .arrived:
            legArrivedHere()
            UINotificationFeedback.success()
            /* The arrival is said ONCE (the owner's «زحمة» review): the header already reads
             * «واقفين عند X»; the moment is either the guidance's «وصلتوا» card or one toast, for
             * 4 s; the leg's numbers are in the «الرحلة» sheet only (not opened by itself). */
            if nav.auto, nav.phase == .guiding || nav.phase == .offRoad {
                nav.finishArrival()
                closeArrivalCardSoon()
            } else {
                if nav.phase == .guiding || nav.phase == .offRoad { endNav() }
                /* The guidance's own «وصلتوا» card is already the moment. */
                if nav.phase != .arrived { arrivalToast("وصلنا \(tripDestination?.name ?? "الوجهة") 🎉") }
            }
        case let .memberArrived(id, _):
            guard let name = v?.members[id]?.display_name else { break }
            toast("وصل \(name) \(tripDestination?.name ?? "الوجهة")")
            /* Driving with guidance: the screen is not for reading, so it is said too. */
            if nav.isActive, nav.phase != .arrived { nav.voice.say("وصل \(name)", clips: ["grp_14"]) }
        }
        if let v, v.iOwn, ArrivalOrder.everyoneArrived(arrivals: trip.record.arrivals, memberIds: v.orderedMembers.map(\.user_id)) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.toast("وصل الربع كلهم · تقدر تنهي الطلعة") }
        }
        objectWillChange.send()
    }

    #if DEBUG
    /// Screenshots: `-SaryTrip arrived|underway` seeds a plausible trip in the demo outing.
    private func tripDebugLaunch() {
        let a = ProcessInfo.processInfo.arguments
        guard session.isDemo, let i = a.firstIndex(of: "-SaryTrip"), i + 1 < a.count else { return }
        let kind = a[i + 1]
        let now = Date().timeIntervalSince1970 * 1000
        var r = TripRecord()
        r.start = TripStartPoint(lat: 24.7062, lng: 46.6611, atMs: now - 47 * 60_000)
        r.groupStart = r.start
        if kind == "arrived" {
            r.me.markArrived(atMs: now - 3 * 60_000)
            r.arrivals[session.myUserId] = now - 3 * 60_000
            r.arrivals["00000000-0000-4000-8000-000000000002"] = now - 6 * 60_000
        }
        trip.debugSet(r)
    }
    #endif
}

enum UINotificationFeedback {
    @MainActor static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    @MainActor static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
}

/// Keeps a value decoded from stored bytes until those bytes change. Comparing the bytes is a
/// memcmp; decoding them (every outing's trip log, as JSON) is far dearer.
struct StoredBytesMemo<Value> {
    private var bytes: Data?
    private var cached: Value?
    private var filled = false
    /// How many times `decode` actually ran (tests).
    private(set) var decodeCount = 0

    mutating func value(for bytes: Data?, decode: (Data?) -> Value) -> Value {
        if filled, self.bytes == bytes, let cached { return cached }
        let v = decode(bytes)
        decodeCount += 1
        self.bytes = bytes
        cached = v
        filled = true
        return v
    }
}
