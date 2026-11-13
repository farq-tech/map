import Foundation

/// Everything «الرحلة» is decided from, as plain values (filled by `TripTracker`).
struct TripPresenterInput {
    var record = TripRecord()
    var destination: OutingDestination?
    var status: OutingStatus?
    var iLead = false
    var myId = ""
    var myFix: DeviceFix?
    /// What the map draws as my trail (road-matched where confident).
    var trail: [TrailPoint] = []
    /// My trip log (moving time, top speed, stops), this device only.
    var log: TripLog?
    var navGuiding = false
    var navRemainingM: Double?
    var navTarget: LngLat?
    var navETA: Date?
    var planRoute: [LngLat] = []
    var members: [(id: String, name: String)] = []
    /// The leader's start as this phone saw it.
    var groupStart: TripStartPoint?
    var isReturnTrip = false
    var now = Date()
    /// `TripMath.drivenMeters(trail:sinceMs:)` for this `trail` since `record.start`, when the caller
    /// already has it (`DrivenMetersMemo`); nil: worked out here.
    var drivenMeters: Double?
}

/// `TripMath.drivenMeters(trail:sinceMs:)` walks the whole trail; the live screen asks for the trip
/// panel several times per render with the same trail. Recomputed only when the trail or the start
/// changes (array equality: the session hands out the same memoized trail until it changes, so the
/// common case is the buffer-identity fast path).
struct DrivenMetersMemo {
    private var trail: [TrailPoint] = []
    private var sinceMs = Double.nan
    private var meters = 0.0
    /// How many times the trail was actually walked (tests).
    private(set) var computeCount = 0

    mutating func value(trail: [TrailPoint], sinceMs: Double) -> Double {
        if sinceMs == self.sinceMs, trail == self.trail { return meters }
        meters = TripMath.drivenMeters(trail: trail, sinceMs: sinceMs)
        computeCount += 1
        self.trail = trail
        self.sinceMs = sinceMs
        return meters
    }
}

/// Pure: the trip's numbers and words. Every rule is unit-tested (TripProgressTests).
enum TripPresenter {
    /// My remaining distance, or nil when my fix is missing / too old to say.
    static func myRemaining(_ i: TripPresenterInput) -> RemainingDistance? {
        guard let d = i.destination, let f = i.myFix, i.now.timeIntervalSince1970 * 1000 - f.atMs <= TripMath.myFixShowMaxAgeMs else { return nil }
        return TripMath.remaining(me: LngLat(lng: f.lng, lat: f.lat), destination: LngLat(lng: d.lng, lat: d.lat),
                                  navRemainingM: i.navRemainingM, navTarget: i.navTarget, navGuiding: i.navGuiding, navETA: i.navETA,
                                  planRoute: i.planRoute)
    }

    static func panel(_ i: TripPresenterInput) -> TripPanelUI {
        let r = i.record
        let nowMs = i.now.timeIntervalSince1970 * 1000
        let phase = r.phase(hasDestination: i.destination != nil, status: i.status)
        let endMs = r.me.arrivedAtMs ?? r.endedAtMs ?? nowMs
        var ui = TripPanelUI(phase: .notStarted, destinationName: i.destination?.name ?? "الوجهة", drivenMeters: 0, canEnd: i.iLead && i.status != .ended)
        ui.isReturnTrip = i.isReturnTrip
        ui.memberCount = i.members.count
        ui.arrivedCount = i.members.filter { r.arrivals[$0.id] != nil }.count
        ui.everyoneArrived = ArrivalOrder.everyoneArrived(arrivals: r.arrivals, memberIds: i.members.map(\.id))
        ui.arrivalLine = ArrivalOrder.line(arrivals: r.arrivals, members: i.members, myId: i.myId)
        if let g = i.groupStart, let f = i.myFix { ui.groupStartMeters = Vehicle.distanceMeters(g.position, LngLat(lng: f.lng, lat: f.lat)) }

        switch phase {
        case .needsDestination: ui.phase = .needsDestination(canSet: i.iLead)
        case .notStarted: ui.phase = .notStarted
        case .waitingFirstFix: ui.phase = .waitingFix
        case .underway: ui.phase = .underway
        case let .arrived(at): ui.phase = .arrived(at: at, manual: r.arrivedManually)
        case .ended: ui.phase = .ended
        }

        guard let start = r.start else { return ui }
        ui.drivenMeters = max(i.drivenMeters ?? TripMath.drivenMeters(trail: i.trail, sinceMs: start.atMs), 0)
        if ui.drivenMeters == 0, let l = i.log { ui.drivenMeters = l.distanceM }
        let motion = TripMotion.make(log: i.log, startMs: start.atMs, endMs: endMs)
        ui.elapsedSeconds = motion.elapsedS
        ui.movingSeconds = motion.movingS
        ui.stoppedSeconds = motion.stoppedS
        ui.avgMovingKmh = motion.avgMovingKmh
        ui.maxKmh = motion.maxKmh

        let arrived = r.me.arrived
        if arrived || phase == .ended {
            ui.percent = arrived ? 100 : nil
            ui.remainingMeters = arrived ? 0 : nil
            return ui
        }
        guard let rem = myRemaining(i) else {
            /* Never from a stale fix: say how old it is instead. */
            if let f = i.myFix { ui.myFixStaleSince = Date(timeIntervalSince1970: f.atMs / 1000) }
            return ui
        }
        ui.remainingMeters = rem.meters
        ui.remainingSource = rem.source
        let e = TripMath.eta(remaining: rem, avgMovingKmh: motion.avgMovingKmh, now: i.now)
        ui.eta = e.date
        ui.etaEstimated = e.estimated
        ui.percent = TripMath.progress(drivenM: ui.drivenMeters, remainingM: rem.meters, arrived: false).map(TripMath.percent)
        return ui
    }

    /// A friend's remaining distance (straight line, from a LIVE position only) and «وصل».
    static func member(id: String, position: Geo.LatLng?, live: Bool, destination: OutingDestination?, arrivals: [String: Double]) -> (remainingM: Double?, arrived: Bool) {
        if arrivals[id] != nil { return (nil, true) }
        guard live, let p = position, let d = destination else { return (nil, false) }
        return (Geo.haversineMeters(p, Geo.LatLng(lat: d.lat, lng: d.lng)), false)
    }

    /// For the Live Activity and CarPlay: «قطعنا ٦٢٪ • باقي ١٢ كم • نوصل ٤:٣٠ م».
    static func shortLine(_ ui: TripPanelUI) -> String? {
        switch ui.phase {
        case .arrived: return "وصلت \(ui.destinationName)"
        case .ended: return nil
        case .underway:
            let parts = [ui.progressLine, ui.remainingLine, ui.etaLine].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: " • ")
        default: return nil
        }
    }
}
