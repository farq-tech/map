import Foundation

// «مساري»: the breadcrumb trail of where I came from, so the group can always
// go back the way it entered. Pure value types here (filtering, simplification,
// gaps, distance along the trail, off-track); the session records, the map draws.
//
// PRIVACY: the trail lives on this phone. Nothing in this file, nor the session
// that feeds it, ever hands a trail point to our server or the live channel; the
// server only ever sees the single latest fix that `SendGate` lets through. The
// one exception (owner decision, 2026-11) is the road matcher (`TrailMatching`),
// which sends stretches of it to Mapbox Map Matching — switchable off.

/// One kept point of a trail.
struct TrailPoint: Codable, Equatable {
    var lat: Double
    var lng: Double
    /// Device time of the fix, ms since 1970.
    var t: Double
    /// The stretch from the previous point to this one was NOT recorded (the app
    /// was closed or in the background, or the GPS was lost): drawn as a dashed
    /// straight line and labelled, never as a path we pretend to know.
    var gap: Bool = false

    var position: LngLat { LngLat(lng: lng, lat: lat) }

    private enum CodingKeys: String, CodingKey { case lat = "a", lng = "o", t, gap = "g" }

    init(lat: Double, lng: Double, t: Double, gap: Bool = false) {
        self.lat = lat
        self.lng = lng
        self.t = t
        self.gap = gap
    }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        lat = try c.decode(Double.self, forKey: .lat)
        lng = try c.decode(Double.self, forKey: .lng)
        t = try c.decode(Double.self, forKey: .t)
        gap = try c.decodeIfPresent(Bool.self, forKey: .gap) ?? false
    }

    func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode((lat * 1e6).rounded() / 1e6, forKey: .lat)
        try c.encode((lng * 1e6).rounded() / 1e6, forKey: .lng)
        try c.encode(t.rounded(), forKey: .t)
        if gap { try c.encode(true, forKey: .gap) }
    }
}

/// Flat metres around a reference latitude: plenty for the few-km spans we compare.
enum TrailGeo {
    static let r = 6_371_000.0

    static func xy(_ p: LngLat, ref: LngLat) -> (x: Double, y: Double) {
        let k = Double.pi / 180
        return ((p.lng - ref.lng) * k * cos(ref.lat * k) * r, (p.lat - ref.lat) * k * r)
    }

    static func lngLat(_ x: Double, _ y: Double, ref: LngLat) -> LngLat {
        let k = Double.pi / 180
        return LngLat(lng: ref.lng + x / (r * cos(ref.lat * k)) / k, lat: ref.lat + y / r / k)
    }

    /// Nearest point to `p` on segment a→b: the point, the fraction along (0…1), and the distance.
    static func project(_ p: LngLat, _ a: LngLat, _ b: LngLat) -> (point: LngLat, u: Double, distM: Double) {
        let pa = xy(p, ref: a), ba = xy(b, ref: a)
        let len2 = ba.x * ba.x + ba.y * ba.y
        let u = len2 > 0 ? max(0, min(1, (pa.x * ba.x + pa.y * ba.y) / len2)) : 0
        let qx = ba.x * u, qy = ba.y * u
        let dx = pa.x - qx, dy = pa.y - qy
        return (lngLat(qx, qy, ref: a), u, (dx * dx + dy * dy).squareRoot())
    }

    /// Perpendicular distance of `p` from the segment a→b, metres.
    static func segmentDistance(_ p: LngLat, _ a: LngLat, _ b: LngLat) -> Double { project(p, a, b).distM }
}

/// Douglas–Peucker on one continuous run (endpoints always kept).
enum TrailSimplify {
    static func douglasPeucker(_ pts: [TrailPoint], toleranceM: Double) -> [TrailPoint] {
        guard pts.count > 2 else { return pts }
        var keep = [Bool](repeating: false, count: pts.count)
        keep[0] = true
        keep[pts.count - 1] = true
        var stack = [(0, pts.count - 1)]
        while let (s, e) = stack.popLast() {
            guard e > s + 1 else { continue }
            var best = 0.0, idx = -1
            let a = pts[s].position, b = pts[e].position
            for i in (s + 1)..<e {
                let d = TrailGeo.segmentDistance(pts[i].position, a, b)
                if d > best { best = d; idx = i }
            }
            if idx >= 0, best > toleranceM {
                keep[idx] = true
                stack.append((s, idx))
                stack.append((idx, e))
            }
        }
        return pts.indices.filter { keep[$0] }.map { pts[$0] }
    }

    /// Simplify a whole trail, run by run: a gap is a hard boundary, both of its ends stay.
    static func simplify(_ pts: [TrailPoint], toleranceM: Double) -> [TrailPoint] {
        var out: [TrailPoint] = []
        var run: [TrailPoint] = []
        for p in pts {
            if p.gap, !run.isEmpty {
                out += douglasPeucker(run, toleranceM: toleranceM)
                run = []
            }
            run.append(p)
        }
        out += douglasPeucker(run, toleranceM: toleranceM)
        return out
    }
}

/// My recorded trail for one outing: the Kalman-smoothed path, decimated in code.
/// The raw fixes it came from are kept beside it (`TrailRawLog`), so it can always
/// be rebuilt; the map draws the road-matched version when there is one (`TrailMatchCache`).
struct Trail: Codable, Equatable {
    var points: [TrailPoint] = []
    /// We were not listening for a while (app closed / no permission): the next point
    /// only becomes a gap if the gap rule holds (see `isGap`).
    var gapNext = false
    /// Points before this index are already simplified.
    var simplifiedUpTo = 0
    /// The smoother (nil until the first usable fix; old trails load without one).
    var filter: TrailKalman?
    /// The last usable fix seen (filtered position + its time), kept or not.
    var lastUsable: TrailPoint?

    /// A kept point every few metres (decimation of the 1 Hz smoothed stream).
    static let minStepM = 8.0
    /// Ceiling used by the friends' trails and the plausibility gate.
    static let maxSpeedMps = TrailKalman.maxSpeedMps
    static let maxAccuracyM = TrailKalman.maxAccuracyM
    /// A gap ONLY when there were truly no usable fixes for this long AND this far.
    static let gapSilenceS = 60.0
    static let gapDistanceM = 500.0
    /// Simplification for storage, and how many newest points stay raw.
    static let toleranceM = 3.0
    static let rawTail = 30
    static let simplifyEvery = 120

    var isEmpty: Bool { points.isEmpty }
    var start: TrailPoint? { points.first }
    var last: TrailPoint? { points.last }

    /// The next point is after a stretch we did not see (app closed / backgrounded / restarted).
    mutating func markGap() {
        if !points.isEmpty { gapNext = true }
    }

    static func isGap(silenceS: Double, distanceM: Double) -> Bool {
        silenceS > gapSilenceS && distanceM > gapDistanceM
    }

    /// Feed one GPS fix. True when it became a trail point.
    @discardableResult
    mutating func add(_ f: DeviceFix) -> Bool { add(RawFix(f)) }

    @discardableResult
    mutating func add(_ raw: RawFix) -> Bool {
        if let last = lastUsable ?? points.last, raw.t <= last.t { return false }
        var k = filter ?? TrailKalman()
        let out = k.step(raw)
        guard case let .accepted(pos, _, _, _) = out else {
            filter = k
            return false
        }
        filter = k
        let here = TrailPoint(lat: pos.lat, lng: pos.lng, t: raw.t)
        let prevUsable = lastUsable ?? points.last
        lastUsable = here
        guard let prev = points.last else {
            points.append(here)
            gapNext = false
            return true
        }
        let silence = (raw.t - (prevUsable?.t ?? prev.t)) / 1000
        let jump = Vehicle.distanceMeters((prevUsable ?? prev).position, here.position)
        var q = here
        q.gap = Self.isGap(silenceS: silence, distanceM: jump)
        if !q.gap && Vehicle.distanceMeters(prev.position, here.position) < Self.minStepM {
            gapNext = false
            return false
        }
        gapNext = false
        append(q)
        return true
    }

    /// The trail as these raw fixes make it (re-processing, GPX export, tests).
    static func rebuild(_ raw: [RawFix]) -> Trail {
        var t = Trail()
        for f in raw.sorted(by: { $0.t < $1.t }) { t.add(f) }
        return t
    }

    private mutating func append(_ p: TrailPoint) {
        points.append(p)
        if points.count - simplifiedUpTo >= Self.simplifyEvery + Self.rawTail { compact() }
    }

    /// Douglas–Peucker everything except the newest raw points.
    mutating func compact() {
        let cut = points.count - Self.rawTail
        guard cut > 2 else { return }
        let head = TrailSimplify.simplify(Array(points[0..<cut]), toleranceM: Self.toleranceM)
        points = head + points[cut...]
        simplifiedUpTo = head.count
    }

    /// Recorded length (the gaps are not counted: we do not know that path).
    var recordedLengthM: Double {
        var s = 0.0
        for i in points.indices.dropFirst() where !points[i].gap {
            s += Vehicle.distanceMeters(points[i - 1].position, points[i].position)
        }
        return s
    }

    var gapCount: Int { points.filter(\.gap).count }

    /// Continuous recorded runs, and the unrecorded straight stretches between them.
    var runs: (solid: [[LngLat]], gaps: [[LngLat]]) { Trail.runs(points) }

    static func runs(_ points: [TrailPoint]) -> (solid: [[LngLat]], gaps: [[LngLat]]) {
        var solid: [[LngLat]] = []
        var gaps: [[LngLat]] = []
        var run: [LngLat] = []
        var gap: [LngLat] = []
        for (i, p) in points.enumerated() {
            if p.gap, i > 0 {
                if run.count >= 2 { solid.append(run) }
                /* Consecutive gap points (a matched road through the unrecorded stretch) are one dashed line. */
                if gap.isEmpty { gap = [points[i - 1].position] }
                gap.append(p.position)
                run = []
            } else if !gap.isEmpty {
                gaps.append(gap)
                gap = []
            }
            run.append(p.position)
        }
        if !gap.isEmpty { gaps.append(gap) }
        if run.count >= 2 { solid.append(run) }
        return (solid, gaps)
    }
}

// MARK: - «طريق العودة»

/// What back-track mode shows right now.
struct BackTrackStatus: Equatable {
    /// To the start: my distance to the trail + the trail itself back to its first point.
    var remainingM: Double
    /// The part of `remainingM` that runs along the trail.
    var alongM: Double
    /// How far I am from the nearest point of my trail.
    var offsetM: Double
    var offTrack: Bool
    var arrived: Bool
    /// Absolute bearing (degrees from north) to follow: to the trail when off it, back along it otherwise.
    var bearing: Double
    /// The nearest trail point.
    var nearest: LngLat
    /// I am on a stretch that was not recorded (a straight dashed line, not a known path).
    var onGap: Bool
}

/// Back-tracking a frozen copy of my trail — the road-matched one when there is
/// one (`TrailDisplay`), else the smoothed one (new points recorded on the way back
/// do not change the target).
struct BackTrack: Equatable {
    let path: [TrailPoint]
    /// Distance from the start to each point, along the trail.
    let cum: [Double]
    /// Segment I was last matched to: progress moves toward the start (auto-advance),
    /// with a little forward slack, and re-acquires anywhere once I am clearly on another part.
    private(set) var cursor: Int
    private(set) var offTrack = false
    /// Since when I have been far from the trail (the warning waits `offTrackHoldS`).
    private(set) var farSinceMs: Double?

    /// «خرجت عن الطريق»: further than this …
    static let offTrackM = 60.0
    /// … for this long (a red light beside a parallel street is not leaving the trail).
    static let offTrackHoldS = 10.0
    /// Back on the trail only once well inside it (no flicker at the edge).
    static let backOnM = 35.0
    static let arrivedM = 30.0
    /// The arrow points this far back along the trail.
    static let lookAheadM = 40.0
    /// Forward slack along the trail (a turn-around, a U-turn at the next junction).
    static let forwardSlackM = 300.0

    init?(_ trail: Trail) { self.init(path: trail.points) }

    init?(path pts: [TrailPoint]) {
        guard pts.count >= 2 else { return nil }
        path = pts
        var c = [0.0]
        for i in 1..<pts.count { c.append(c[i - 1] + Vehicle.distanceMeters(pts[i - 1].position, pts[i].position)) }
        cum = c
        cursor = pts.count - 2
    }

    var startPoint: LngLat { path[0].position }
    var totalM: Double { cum.last ?? 0 }

    /// The point `m` metres from the start along the trail.
    func point(atAlong m: Double) -> LngLat {
        let m = max(0, min(totalM, m))
        var i = 1
        while i < cum.count - 1, cum[i] < m { i += 1 }
        let a = path[i - 1].position, b = path[i].position
        let seg = cum[i] - cum[i - 1]
        let u = seg > 0 ? (m - cum[i - 1]) / seg : 0
        return LngLat(lng: a.lng + (b.lng - a.lng) * u, lat: a.lat + (b.lat - a.lat) * u)
    }

    private func nearest(_ me: LngLat, in range: ClosedRange<Int>) -> (seg: Int, point: LngLat, u: Double, d: Double) {
        var best: (seg: Int, point: LngLat, u: Double, d: Double)?
        for i in range {
            let pr = TrailGeo.project(me, path[i].position, path[i + 1].position)
            /* Ties (a loop over itself) go to the part nearer the start. */
            if best == nil || pr.distM < best!.d - 0.5 { best = (i, pr.point, pr.u, pr.distM) }
        }
        return best!
    }

    /// - Parameters:
    ///   - accuracy: the fix's horizontal accuracy: never «خرجت» while the GPS itself is less sure than the distance.
    ///   - atMs: the fix time; nil (tests, one-off estimates) skips the hold.
    mutating func update(_ me: LngLat, accuracy: Double? = nil, atMs: Double? = nil) -> BackTrackStatus {
        let reach = cum[min(cursor + 1, cum.count - 1)] + Self.forwardSlackM
        var hi = cursor
        while hi < path.count - 2, cum[hi + 1] <= reach { hi += 1 }
        var b = nearest(me, in: 0...hi)
        if b.d > Self.offTrackM, hi < path.count - 2 {
            /* Clearly not on the part ahead of the cursor: maybe I am on a later part (the cursor was misled). */
            let g = nearest(me, in: 0...(path.count - 2))
            if g.d < Self.backOnM { b = g }
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
        let remaining = along + b.d
        let arrived = Vehicle.distanceMeters(me, startPoint) <= Self.arrivedM
        let target = offTrack ? b.point : point(atAlong: along - Self.lookAheadM)
        let bearing = Vehicle.distanceMeters(me, target) < 1 ? Vehicle.bearing(me, startPoint) : Vehicle.bearing(me, target)
        return BackTrackStatus(remainingM: arrived ? 0 : remaining, alongM: along, offsetM: b.d, offTrack: offTrack && !arrived, arrived: arrived,
                               bearing: bearing, nearest: b.point, onGap: path[b.seg + 1].gap)
    }
}

// MARK: - friends' recent trails (client-side only, this session only)

/// From the live positions this phone already receives: each friend's last ~30 minutes.
/// Never stored, never sent; forgotten when the outing screen closes.
struct FriendTrails: Equatable {
    static let windowMs = 30 * 60 * 1000.0
    /// Positions this far apart in time were not seen in between: a gap.
    static let gapS = 180.0
    static let maxAccuracyM = 60.0

    private(set) var byId: [String: [TrailPoint]] = [:]

    mutating func ingest(_ id: String, lat: Double, lng: Double, atMs: Double, accuracy: Double?) {
        if let a = accuracy, a > Self.maxAccuracyM { return }
        var pts = byId[id] ?? []
        let p = TrailPoint(lat: lat, lng: lng, t: atMs)
        if let prev = pts.last {
            guard atMs > prev.t else { return }
            let d = Vehicle.distanceMeters(prev.position, p.position)
            let dt = (atMs - prev.t) / 1000
            guard d >= Trail.minStepM else { return }
            if d / max(dt, 0.5) > Trail.maxSpeedMps { return }
            var q = p
            q.gap = dt > Self.gapS
            pts.append(q)
        } else {
            pts.append(p)
        }
        byId[id] = pts
    }

    /// Drop what is older than the window (and friends no longer on the map).
    mutating func prune(nowMs: Double, keep ids: Set<String>) {
        for (id, pts) in byId {
            guard ids.contains(id) else { byId[id] = nil; continue }
            var kept = pts.filter { nowMs - $0.t <= Self.windowMs }
            if var first = kept.first, first.gap { first.gap = false; kept[0] = first }
            byId[id] = kept.isEmpty ? nil : kept
        }
    }

    mutating func removeAll() { byId = [:] }
}

// MARK: - storage (this device only)

/// One small JSON file per outing in Application Support (not backed up to iCloud).
/// Works offline, survives restarts; wiped on sign-out / account deletion.
enum TrailStore {
    static var directory: URL? = {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return base.appendingPathComponent("trails-v1", isDirectory: true)
    }()

    static func fileName(_ outingId: String) -> String {
        outingId.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") } + ".json"
    }

    static func url(_ outingId: String, in dir: URL? = directory) -> URL? {
        dir?.appendingPathComponent(fileName(outingId))
    }

    static func load(_ outingId: String, in dir: URL? = directory) -> Trail? {
        guard let u = url(outingId, in: dir), let d = try? Data(contentsOf: u) else { return nil }
        return try? JSONDecoder().decode(Trail.self, from: d)
    }

    static func save(_ trail: Trail, outingId: String, in dir: URL? = directory) {
        guard let dir, let u = url(outingId, in: dir) else { return }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var d = dir
            try? d.setResourceValues(values)
            let data = try JSONEncoder().encode(trail)
            try data.write(to: u, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {}
    }

    /// The trail, its raw fixes and its road-matched geometry.
    static func delete(_ outingId: String, in dir: URL? = directory) {
        guard let u = url(outingId, in: dir) else { return }
        try? FileManager.default.removeItem(at: u)
        TrailRawLog.delete(outingId, in: dir)
        TrailMatchStore.delete(outingId, in: dir)
    }

    static func forgetAll(in dir: URL? = directory) {
        guard let dir else { return }
        try? FileManager.default.removeItem(at: dir)
    }
}

/// The person's trail switches (this device).
enum TrailPrefs {
    static let recordKey = "sary.trail.record.v1"
    static let backgroundKey = "sary.trail.background.v1"
    static let friendsKey = "sary.trail.friends.v1"
    /// The «دائمًا» explainer was shown (once; the switch can bring it back).
    static let explainedKey = "sary.trail.alwaysExplained.v1"
    static var keys: [String] { [recordKey, backgroundKey, friendsKey, explainedKey] }

    static func record(_ d: UserDefaults = .standard) -> Bool { d.object(forKey: recordKey) as? Bool ?? true }
    /// On by default (owner): record with the screen locked once iOS allows «دائمًا».
    static func background(_ d: UserDefaults = .standard) -> Bool { d.object(forKey: backgroundKey) as? Bool ?? true }
    static func friends(_ d: UserDefaults = .standard) -> Bool { d.object(forKey: friendsKey) as? Bool ?? true }
}
