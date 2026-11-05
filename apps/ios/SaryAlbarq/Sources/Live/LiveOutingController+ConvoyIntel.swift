import Foundation
import UIKit

/// «ذكاء القافلة» on the live screen (Core/ConvoyWatch.swift): the watch fed from the cars drawn
/// right now, its alerts in the one queue, and «ارجعوا لنقطة التجمع».
extension LiveOutingController {
    /// Distances in «المجموعة» are measured from this member.
    var convoyLeaderId: String? {
        guard let v = session.view else { return nil }
        return ConvoyLeader.id(convoy: v.convoy, ownerId: v.snapshot.outing.owner_id)
    }

    /// Feed the watch (called with the convoy check on every session / GPS change).
    func checkConvoyIntel(now: Date = Date()) {
        guard let v = session.view, v.status == .active else {
            for k in convoyWatch.lastFired.keys { dismissAlert(k) }
            convoyWatch.reset()
            return
        }
        let members = LiveOutingPresenter.mapMembers(input, hideNotes: true)
        let cars = members.map { m -> ConvoyWatch.Car in
            let live = m.presence == .live
            let speed = live ? m.speedMps.flatMap { $0.isFinite && $0 >= 0 && $0 <= Policy.maxPlausibleMps ? Speed.kmh($0) : nil } : nil
            return ConvoyWatch.Car(id: m.id, position: Geo.LatLng(lat: m.position.lat, lng: m.position.lng), speedKmh: speed, live: live, isMe: m.isMe)
        }
        var stops: [Geo.LatLng] = []
        if let d = tripDestination { stops.append(Geo.LatLng(lat: d.lat, lng: d.lng)) }
        if let r = rallyPoint { stops.append(Geo.LatLng(lat: r.position.lat, lng: r.position.lng)) }
        stops += features.waypoints.map { Geo.LatLng(lat: $0.position.lat, lng: $0.position.lng) }
        let (fire, clear) = convoyWatch.ingest(cars, context: .init(leaderId: convoyLeaderId, knownStops: stops),
                                               settings: ConvoyAlertPrefs.shared.settings, now: now)
        for k in clear { dismissAlert(k) }
        guard !fire.isEmpty else { return }
        let colors = v.colors
        func name(_ id: String) -> String { id == v.myId ? "أنت" : v.members[id]?.display_name ?? "" }
        let leaderName = convoyLeaderId.map(name)
        for a in fire {
            switch a {
            case let .separated(u, m):
                pushAlert(LiveAlertUI(id: a.key, kind: .convoy(ConvoyAlertUI(kind: .separated, userId: u, name: name(u), color: colors[u] ?? 0xFFFFFF,
                                                                            meters: m, otherName: leaderName == "أنت" ? "عنك" : leaderName,
                                                                            leaderTitle: ConvoyLeader.title(convoy: v.convoy)))), ttl: 120)
            case let .unexpectedStop(u, since):
                let mins = max(1, Int(now.timeIntervalSince(since) / 60))
                pushAlert(LiveAlertUI(id: a.key, kind: .convoy(ConvoyAlertUI(kind: .unexpectedStop, userId: u, name: name(u), color: colors[u] ?? 0xFFFFFF,
                                                                            meters: 0, minutes: mins))), ttl: 30 * 60)
            }
        }
        if now.timeIntervalSince(lastConvoyBuzz) >= 20 {
            lastConvoyBuzz = now
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        }
    }

    /// The buttons on convoy cards.
    var convoyAlertActions: ConvoyAlertActions {
        ConvoyAlertActions(recall: session.view?.iLead == true ? { [weak self] in self?.recallToRally() } : nil,
                           goToRally: { [weak self] in self?.navigate(NavTargets.rally(self?.rallyPoint)) })
    }

    /// «ارجعوا لنقطة التجمع» (leader / co-leader): sent through the note channel.
    func recallToRally() {
        guard session.view?.iLead == true else { return }
        guard rallyPoint != nil else {
            toast("حدّد نقطة التجمع أولًا، ثم أرسل الطلب")
            actions.participantsTab.rallyCreate()
            return
        }
        Task {
            if await session.sendNote(RallyRecall.noteText) { toast("وصل طلبك للمجموعة: ارجعوا لنقطة التجمع") }
        }
    }

    /// A member's note is the leader's recall: the prompt with «اتجه» instead of a plain note card.
    func recallPrompt(from uid: String, at: String, view v: OutingView) -> LiveAlertUI? {
        guard let m = v.members[uid], m.role == "owner" || m.co_leader == true, let r = rallyPoint else { return nil }
        var meters = -1.0
        if let f = location.lastFix, Date().timeIntervalSince1970 * 1000 - f.atMs <= LiveOutingPresenter.myLiveMaxAgeMs {
            meters = Geo.haversineMeters(Geo.LatLng(lat: f.lat, lng: f.lng), Geo.LatLng(lat: r.position.lat, lng: r.position.lng))
        }
        return LiveAlertUI(id: "convoy:rally:\(uid):\(at)", kind: .convoy(ConvoyAlertUI(kind: .returnToRally, userId: uid, name: m.display_name,
                                                                                        color: v.colors[uid] ?? 0xFFFFFF, meters: meters, otherName: m.display_name)))
    }
}

#if DEBUG
extension LiveOutingController {
    /// Screenshots / UI tests: `-SaryConvoyIntelDemo` — the three new convoy cards, as the watch
    /// would raise them (a far car, a sudden stop, the leader's recall).
    func seedConvoyIntelDemo() {
        guard session.isDemo, let v = session.view else { return }
        let others = v.orderedMembers.filter { $0.user_id != v.myId }
        guard let a = others.first else { return }
        let colors = v.colors
        let b = others.dropFirst().first ?? a
        pushAlert(LiveAlertUI(id: "convoy:sep:\(a.user_id)", kind: .convoy(ConvoyAlertUI(kind: .separated, userId: a.user_id, name: a.display_name,
                                                                                         color: colors[a.user_id] ?? 0xFFFFFF, meters: 2_600, otherName: "عنك"))), ttl: 600)
        pushAlert(LiveAlertUI(id: "convoy:stop:\(b.user_id)", kind: .convoy(ConvoyAlertUI(kind: .unexpectedStop, userId: b.user_id, name: b.display_name,
                                                                                          color: colors[b.user_id] ?? 0xFFFFFF, meters: 0, minutes: 4))), ttl: 600)
    }
}
#endif
