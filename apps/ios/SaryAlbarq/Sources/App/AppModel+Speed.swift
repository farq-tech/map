import Foundation

extension AppModel {
    /// My top and average moving speed for this outing, from this device only.
    /// Never part of «شارك ملخصي» (that sends distance and times only).
    func mySpeed(_ id: String) -> TripSpeedSummary? {
        if isDemo { return TripSpeedSummary(maxKmh: 118, avgMovingKmh: 64) }
        guard let s = TripLogStore.load(id)?.speedSummary, !s.isEmpty else { return nil }
        return s
    }
}

// MARK: - «الرحلة» after the end (this device only)

/// What the trip summary shows about my trip: start → end, moving / stopped, the
/// longest stop and who arrived when. All of it from this phone; none of it is sent.
struct TripSummaryFacts: Equatable {
    var start: TripStartPoint?
    var arrivedAt: Date?
    var endedAt: Date?
    var motion: TripMotion
    var arrivals: [String: Double]
}

extension AppModel {
    /// The trip record kept on this phone (demo: a fixed, plausible one).
    func tripRecord(_ id: String) -> TripRecord? {
        if isDemo {
            #if DEBUG
            if let r = TripStore.load(id), r.start != nil { return r }
            return DemoData.tripRecord(id)
            #else
            return nil
            #endif
        }
        if let s = session, s.id == id, let r = TripStore.load(id) { return r }
        return TripStore.load(id)
    }

    func tripFacts(_ id: String) -> TripSummaryFacts? {
        guard let r = tripRecord(id), r.start != nil else { return nil }
        let log: TripLog? = isDemo ? (TripStore.load(id)?.start != nil ? TripLogStore.load(id) : DemoData.tripLog()) : TripLogStore.load(id)
        let end = r.me.arrivedAtMs ?? r.endedAtMs ?? log?.lastAtMs ?? Date().timeIntervalSince1970 * 1000
        return TripSummaryFacts(start: r.start, arrivedAt: r.me.arrivedAtMs.map { Date(timeIntervalSince1970: $0 / 1000) },
                                endedAt: r.endedAtMs.map { Date(timeIntervalSince1970: $0 / 1000) },
                                motion: TripMotion.make(log: log, startMs: r.start?.atMs, endMs: end), arrivals: r.arrivals)
    }
}

extension DemoData {
    /// Demo summary: arrived after 3 h 12 m; «أبو فهد» first, then me, then «سلطان».
    static func tripRecord(_ id: String, now: Date = Date()) -> TripRecord? {
        guard id == "demo-old" || id == outingId else { return nil }
        let end = now.addingTimeInterval(-86400 * 3).timeIntervalSince1970 * 1000
        var r = TripRecord()
        r.start = TripStartPoint(lat: 24.7062, lng: 46.6611, atMs: end - (3 * 3600 + 12 * 60) * 1000)
        r.groupStart = r.start
        r.me.markArrived(atMs: end - 20 * 60_000)
        r.arrivals = [meId: end - 20 * 60_000, "00000000-0000-4000-8000-00000000021": end - 31 * 60_000, "00000000-0000-4000-8000-00000000022": end - 9 * 60_000]
        r.ended(nowMs: end)
        return r
    }

    static func tripLog() -> TripLog {
        var l = TripLog()
        l.distanceM = 48_300
        l.movingS = 2 * 3600 + 5 * 60
        l.longestStopS = 41 * 60
        l.peak = SpeedPeak(maxMps: 118 / 3.6)
        return l
    }
}
