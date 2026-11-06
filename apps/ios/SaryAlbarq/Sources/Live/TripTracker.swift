import Foundation

/// Keeps one outing's `TripRecord` on this phone: the start point at my first live fix
/// after the outing started, my arrival (detected or «وصلنا»), what this phone saw of
/// the others' arrivals, and the end. Saved in UserDefaults after every change; never sent.
@MainActor
final class TripTracker {
    let outingId: String
    private let defaults: UserDefaults
    private(set) var record: TripRecord
    /// Something worth telling the person (the controller turns it into a toast / card).
    var onEvent: (TripRecord.Event) -> Void = { _ in }
    private var clock: Timer?

    init(outingId: String, defaults: UserDefaults = .standard) {
        self.outingId = outingId
        self.defaults = defaults
        record = TripStore.load(outingId, defaults: defaults) ?? TripRecord()
    }

    deinit { clock?.invalidate() }

    /// The dwell clock (a parked car sends no new fix): every few seconds.
    func startClock(every s: TimeInterval = 5, _ tick: @escaping () -> Void) {
        clock?.invalidate()
        clock = Timer.scheduledTimer(withTimeInterval: s, repeats: true) { _ in Task { @MainActor in tick() } }
    }

    func stopClock() {
        clock?.invalidate()
        clock = nil
    }

    /// Feed the latest picture: my fix, the friends' positions, the outing's state.
    func update(view v: OutingView?, myFix: DeviceFix?, destination: OutingDestination?, now: Date = Date()) {
        guard let v else { return }
        let before = record
        let nowMs = now.timeIntervalSince1970 * 1000
        let dest = destination.map { LngLat(lng: $0.lng, lat: $0.lat) }
        if v.status == .ended {
            record.ended(nowMs: nowMs)
            commit(before, events: [])
            return
        }
        var events: [TripRecord.Event] = []
        let started = LiveOutingPresenter.deviceDate(v.snapshot.outing.started_at, view: v).map { $0.timeIntervalSince1970 * 1000 }
        if let f = myFix {
            events += record.ingestMine(f, myId: v.myId, destination: dest, status: v.status, outingStartedMs: started, nowMs: nowMs)
        }
        events += record.tick(myId: v.myId, nowMs: nowMs)
        for (uid, p) in v.positions where uid != v.myId {
            guard let d = LiveOutingPresenter.deviceDate(p.recorded_at, view: v) else { continue }
            let live = v.members[uid]?.sharing == true && v.freshness(of: uid, deviceNow: now) == .live
            events += record.ingestFriend(uid, lat: p.lat, lng: p.lng, accuracy: p.accuracy, atMs: d.timeIntervalSince1970 * 1000,
                                          live: live, destination: dest, nowMs: nowMs)
        }
        updateGroupStart(v, started: started, now: now)
        commit(before, events: events)
    }

    /// «وصلنا».
    func markArrived(myId: String, now: Date = Date()) {
        let before = record
        let ev = record.markArrived(myId: myId, nowMs: now.timeIntervalSince1970 * 1000)
        commit(before, events: ev)
    }

    /// A new «مشوار» (leg): arrival starts over, the outing's start points stay.
    func beginLeg() {
        let before = record
        record.beginLeg()
        commit(before, events: [])
    }

    /// The group's start: the leader's. On the leader's phone it is my own start; elsewhere
    /// the leader's first LIVE position after the outing started, as it reached this phone.
    private func updateGroupStart(_ v: OutingView, started: Double?, now: Date) {
        guard record.groupStart == nil else { return }
        let owner = v.snapshot.outing.owner_id
        if owner == v.myId {
            record.groupStart = record.start
            return
        }
        guard let p = v.positions[owner], v.freshness(of: owner, deviceNow: now) == .live,
              let d = LiveOutingPresenter.deviceDate(p.recorded_at, view: v) else { return }
        let at = d.timeIntervalSince1970 * 1000
        guard at >= (started ?? -.infinity) - 1000 else { return }
        record.groupStart = TripStartPoint(lat: p.lat, lng: p.lng, atMs: at)
    }

    private func commit(_ before: TripRecord, events: [TripRecord.Event]) {
        if record != before { TripStore.save(outingId, record, defaults: defaults) }
        for e in events { onEvent(e) }
    }

    #if DEBUG
    /// Screenshots / UI tests only.
    func debugSet(_ r: TripRecord) {
        record = r
        TripStore.save(outingId, r, defaults: defaults)
    }
    #endif
}
