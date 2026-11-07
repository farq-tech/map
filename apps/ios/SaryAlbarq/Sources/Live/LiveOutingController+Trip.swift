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
        /* The navigation picker's «الوجهة» and «نهاية المسار» read the plan too. */
        navDestination = { [weak self] in self?.planModel?.plan.destination }
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
        i.log = session.isDemo ? speed.local : TripLogStore.load(session.id)
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
        modal = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.modal = .plan(.search) }
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
        Task { await session.setStatus("end") }
    }

    /// Return trip: guide back along the trail of the outing it came back from.
    func followOldTrail() {
        guard let old = returnOrigin, let t = TrailStore.load(old), t.points.count >= 2 else {
            toast("ما عندنا مسار محفوظ للطلعة السابقة على هذا الجوال.")
            return
        }
        startBackTrack(along: t.points)
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.toast("وصل الجميع · تقدر تنهي الرحلة") }
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
