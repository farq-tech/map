import Foundation

// «اسلك هذا المسار»: off-road guidance along any saved track — pure geometry, works
// fully offline. My position is snapped to the nearest segment of the track (never to
// a road); the remaining distance is measured ALONG the track to its end. «اعكس الاتجاه»
// follows the same track backwards (what «طريق العودة» does for my own trail).

/// What follow mode shows right now.
struct TrackFollowStatus: Equatable {
    /// Along the track from my snapped point to its end.
    var remainingM: Double
    /// Along the track from its start to my snapped point.
    var alongM: Double
    var totalM: Double
    /// 0…1 of the track behind me.
    var progress: Double
    /// My distance from the track.
    var offsetM: Double
    /// Further than `offTrackM` for longer than `offTrackHoldS` («خرجت عن المسار»).
    var offTrack: Bool
    var arrived: Bool
    /// Absolute bearing to follow (to the track when off it, along it otherwise).
    var bearing: Double
    /// My position snapped onto the track.
    var snapped: LngLat
    /// I am on a stretch that was not recorded (straight dashed line).
    var onGap: Bool
    /// The track is far from me (> `farM`): offer to navigate to its nearest point first.
    var far: Bool
}

struct TrackFollow: Equatable {
    /// The track in the direction being followed.
    let path: [LngLat]
    /// Per segment of `path`: unrecorded.
    let gaps: [Bool]
    /// Along-track distance of each point from `path[0]`.
    let cum: [Double]
    /// Followed backwards (from the track's last point to its first).
    let reversed: Bool
    private(set) var cursor = 0
    private(set) var acquired = false
    private(set) var offTrack = false
    /// Since when I have been far from the line (the warning waits `offTrackHoldS`).
    private(set) var farSinceMs: Double?

    /// «خرجت عن المسار»: further than this …
    static let offTrackM = 50.0
    /// … for this long.
    static let offTrackHoldS = 10.0
    /// Back on only once well inside it (no flicker at the edge).
    static let backOnM = 30.0
    static let arrivedM = 30.0
    /// The arrow points this far ahead along the track.
    static let lookAheadM = 40.0
    /// The search window around the last matched segment: a little back, more ahead.
    static let backSlackM = 120.0
    static let forwardSlackM = 300.0
    /// Further than this from the whole track: «المسار بعيد عنك».
    static let farM = 2_000.0

    /// - Parameters:
    ///   - points: the track as recorded (first → last).
    ///   - gaps: per segment, unrecorded (nil = none).
    ///   - reversed: follow it from its last point back to the first.
    init?(points: [LngLat], gaps: [Bool]? = nil, reversed: Bool = false) {
        guard points.count >= 2 else { return nil }
        let g = gaps ?? Array(repeating: false, count: points.count - 1)
        guard g.count == points.count - 1 else { return nil }
        path = reversed ? points.reversed() : points
        self.gaps = reversed ? g.reversed() : g
        self.reversed = reversed
        var c = [0.0]
        for i in 1..<path.count { c.append(c[i - 1] + Vehicle.distanceMeters(path[i - 1], path[i])) }
        cum = c
        guard (cum.last ?? 0) > 0 else { return nil }
    }

    init?(_ line: TrackLine, reversed: Bool = false) { self.init(points: line.points, gaps: line.gaps, reversed: reversed) }

    /// The same track the other way round (state starts afresh).
    func reversedFollow() -> TrackFollow? {
        let original = reversed ? Array(path.reversed()) : path
        let og = reversed ? Array(gaps.reversed()) : gaps
        return TrackFollow(points: original, gaps: og, reversed: !reversed)
    }

    var totalM: Double { cum.last ?? 0 }
    var startPoint: LngLat { path[0] }
    var endPoint: LngLat { path[path.count - 1] }

    /// The point `m` metres along the followed direction.
    func point(atAlong m: Double) -> LngLat {
        let m = max(0, min(totalM, m))
        var i = 1
        while i < cum.count - 1, cum[i] < m { i += 1 }
        let a = path[i - 1], b = path[i]
        let seg = cum[i] - cum[i - 1]
        let u = seg > 0 ? (m - cum[i - 1]) / seg : 0
        return LngLat(lng: a.lng + (b.lng - a.lng) * u, lat: a.lat + (b.lat - a.lat) * u)
    }

    typealias Match = (seg: Int, point: LngLat, u: Double, d: Double)

    func nearest(_ me: LngLat, in range: ClosedRange<Int>) -> Match {
        var best: Match?
        for i in range {
            let pr = TrailGeo.project(me, path[i], path[i + 1])
            /* Ties (a track crossing itself): the part nearer where I already am. */
            if best == nil || pr.distM < best!.d - 0.5 { best = (i, pr.point, pr.u, pr.distM) }
        }
        return best!
    }

    /// Nearest point of the whole track (the approach target when it is far).
    func nearestPoint(to me: LngLat) -> (point: LngLat, alongM: Double, distM: Double) {
        let b = nearest(me, in: 0...(path.count - 2))
        return (b.point, cum[b.seg] + (cum[b.seg + 1] - cum[b.seg]) * b.u, b.d)
    }

    /// - Parameters:
    ///   - accuracy: the fix's horizontal accuracy: never «خرجت» while the GPS is less sure than the distance.
    ///   - atMs: the fix time; nil (tests, one-off estimates) skips the hold.
    mutating func update(_ me: LngLat, accuracy: Double? = nil, atMs: Double? = nil) -> TrackFollowStatus {
        let last = path.count - 2
        var b: Match
        if !acquired {
            b = nearest(me, in: 0...last)
            acquired = true
        } else {
            let lo = cum[cursor] - Self.backSlackM, hi = cum[cursor + 1] + Self.forwardSlackM
            var a = cursor, z = cursor
            while a > 0, cum[a] > lo { a -= 1 }
            while z < last, cum[z + 1] < hi { z += 1 }
            b = nearest(me, in: a...z)
            if b.d > Self.offTrackM {
                /* Not near the part around the cursor: maybe on another part (a shortcut, a loop). */
                let g = nearest(me, in: 0...last)
                if g.d < Self.backOnM || g.d < b.d - Self.offTrackM { b = g }
            }
        }
        cursor = b.seg
        let along = cum[b.seg] + (cum[b.seg + 1] - cum[b.seg]) * b.u
        let unsure = (accuracy ?? 0) >= b.d
        if offTrack {
            if b.d < Self.backOnM || unsure { offTrack = false; farSinceMs = nil }
        } else if b.d > Self.offTrackM && !unsure {
            if let t = atMs {
                if farSinceMs == nil { farSinceMs = t }
                if t - farSinceMs! >= Self.offTrackHoldS * 1000 { offTrack = true }
            } else {
                offTrack = true
            }
        } else {
            farSinceMs = nil
        }
        let remaining = max(0, totalM - along)
        let arrived = Vehicle.distanceMeters(me, endPoint) <= Self.arrivedM || (remaining <= Self.arrivedM && b.d < Self.backOnM)
        let target = offTrack ? b.point : point(atAlong: along + Self.lookAheadM)
        let bearing = Vehicle.distanceMeters(me, target) < 1 ? Vehicle.bearing(me, endPoint) : Vehicle.bearing(me, target)
        return TrackFollowStatus(remainingM: arrived ? 0 : remaining, alongM: along, totalM: totalM,
                                 progress: arrived ? 1 : (totalM > 0 ? min(1, along / totalM) : 0),
                                 offsetM: b.d, offTrack: offTrack && !arrived, arrived: arrived, bearing: bearing,
                                 snapped: b.point, onGap: gaps[b.seg], far: b.d > Self.farM)
    }
}

/// One deviation alert at a time: raised when «خرجت عن المسار» starts, cleared when back on.
struct FollowDeviation: Equatable {
    private(set) var raised = false

    enum Event: Equatable { case raise(offsetM: Double), clear, none }

    mutating func ingest(_ s: TrackFollowStatus?) -> Event {
        let off = s?.offTrack == true
        if off && !raised { raised = true; return .raise(offsetM: s!.offsetM) }
        if !off && raised { raised = false; return .clear }
        return .none
    }
}
