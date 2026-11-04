import Foundation

// «مساري»: the breadcrumb trail of where I came from, so the group can always
// go back the way it entered. Pure value types here (filtering, simplification,
// gaps, distance along the trail, off-track); the session records, the map draws.
//
// PRIVACY: the trail lives ONLY on this phone. Nothing in this file, nor the
// session that feeds it, ever hands a trail point to the network layer; the
// server only ever sees the single latest fix that `SendGate` lets through.

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

/// My recorded trail for one outing.
struct Trail: Codable, Equatable {
    var points: [TrailPoint] = []
    /// The next accepted point starts after an unrecorded stretch.
    var gapNext = false
    /// Fixes that looked like a jump from the last point; three consistent ones
    /// in a row mean the jump was real (the last point was the bad one).
    var pending: [TrailPoint] = []
    /// Points before this index are already simplified.
    var simplifiedUpTo = 0

    // Noise filter (owner: accuracy gate, ~10 m steps, reject jumps by speed).
    static let maxAccuracyM = 30.0
    static let minStepM = 10.0
    static let maxSpeedMps = 70.0
    /// In the foreground, a silence this long AND a move this far is a GPS gap too.
    static let silentGapS = 120.0
    static let silentGapM = 300.0
    static let jumpConfirmations = 3
    /// Simplification for storage, and how many newest points stay raw.
    static let toleranceM = 4.0
    static let rawTail = 30
    static let simplifyEvery = 120

    var isEmpty: Bool { points.isEmpty }
    var start: TrailPoint? { points.first }
    var last: TrailPoint? { points.last }

    /// The next point is after a stretch we did not see (app closed / backgrounded / restarted).
    mutating func markGap() {
        if !points.isEmpty { gapNext = true }
        pending = []
    }

    /// Feed one GPS fix. True when it became a trail point.
    @discardableResult
    mutating func add(_ f: DeviceFix) -> Bool {
        if let a = f.accuracy, a > Self.maxAccuracyM { return false }
        guard f.lat.isFinite, f.lng.isFinite, abs(f.lat) <= 90, abs(f.lng) <= 180 else { return false }
        let p = TrailPoint(lat: f.lat, lng: f.lng, t: f.atMs)
        guard let prev = points.last else {
            points.append(p)
            return true
        }
        guard p.t > prev.t else { return false }
        let d = Vehicle.distanceMeters(prev.position, p.position)
        let dt = (p.t - prev.t) / 1000
        if gapNext {
            /* After an unrecorded stretch any distance is possible: start the new run here. */
            var q = p
            q.gap = d >= Self.minStepM
            if !q.gap, d < Self.minStepM { gapNext = false; return false }
            append(q)
            gapNext = false
            return true
        }
        if d < Self.minStepM { pending = []; return false }
        if d / max(dt, 0.5) > Self.maxSpeedMps {
            /* A jump. Believe it only when the next fixes agree with each other. */
            if let lastPending = pending.last {
                let pd = Vehicle.distanceMeters(lastPending.position, p.position)
                let pdt = (p.t - lastPending.t) / 1000
                if pdt > 0, pd / max(pdt, 0.5) <= Self.maxSpeedMps { pending.append(p) } else { pending = [p] }
            } else {
                pending = [p]
            }
            if pending.count >= Self.jumpConfirmations {
                var first = pending[0]
                first.gap = true
                append(first)
                for q in pending.dropFirst() where Vehicle.distanceMeters(points.last!.position, q.position) >= Self.minStepM { append(q) }
                pending = []
                return true
            }
            return false
        }
        pending = []
        var q = p
        /* Foreground but no fixes for minutes while we moved far: we did not see that stretch. */
        q.gap = dt > Self.silentGapS && d > Self.silentGapM
        append(q)
        return true
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
        for (i, p) in points.enumerated() {
            if p.gap, i > 0 {
                if run.count >= 2 { solid.append(run) }
                gaps.append([points[i - 1].position, p.position])
                run = []
            }
            run.append(p.position)
        }
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

/// Back-tracking a frozen copy of my trail (new points recorded on the way back do not change the target).
struct BackTrack: Equatable {
    let path: [TrailPoint]
    /// Distance from the start to each point, along the trail.
    let cum: [Double]
    /// Highest segment still ahead of me: progress only moves toward the start (auto-advance).
    private(set) var cursor: Int
    private(set) var offTrack = false

    static let offTrackM = 60.0
    /// Back on the trail only once well inside it (no flicker at the edge).
    static let backOnM = 45.0
    static let arrivedM = 30.0
    /// The arrow points this far back along the trail.
    static let lookAheadM = 40.0
    /// Forward slack: a few segments the person may still be on after a turn-around.
    static let forwardSlack = 2

    init?(_ trail: Trail) {
        let pts = trail.points
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

    mutating func update(_ me: LngLat) -> BackTrackStatus {
        let hi = min(path.count - 2, cursor + Self.forwardSlack)
        var best: (seg: Int, point: LngLat, u: Double, d: Double)?
        for i in 0...hi {
            let pr = TrailGeo.project(me, path[i].position, path[i + 1].position)
            /* Ties (a loop over itself) go to the part nearer the start. */
            if best == nil || pr.distM < best!.d - 0.5 { best = (i, pr.point, pr.u, pr.distM) }
        }
        let b = best!
        cursor = b.seg
        let along = cum[b.seg] + (cum[b.seg + 1] - cum[b.seg]) * b.u
        if offTrack { offTrack = b.d > Self.backOnM } else { offTrack = b.d > Self.offTrackM }
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

    static func delete(_ outingId: String, in dir: URL? = directory) {
        guard let u = url(outingId, in: dir) else { return }
        try? FileManager.default.removeItem(at: u)
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
