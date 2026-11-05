import Foundation

// Build 10 — «دقة المسار»: how a recorded track is DRAWN. Display only: nothing here
// ever changes a stored trail or its raw log; the map gets a cleaned, smoothed copy.
//
//   raw fixes ──(accuracy ≤ 25 m, no >70 m/s jumps)──▶ Kalman (`Trail.rebuild`)
//             ──▶ Douglas–Peucker 2.5 m ──▶ `TrackLine` (+ per-segment speed where known)
//
// Speeds are never invented: a segment's speed is the mean of the raw fixes' own
// CoreLocation speeds with a good speed accuracy inside it, or, without raw fixes,
// distance ÷ time between two recorded points. No time → no speed (a single colour).

/// A track ready to draw.
struct TrackLine: Equatable {
    var points: [LngLat]
    /// Per segment i (points[i] → points[i+1]): speed in m/s, nil = unknown.
    var speeds: [Double?]
    /// Per segment: an unrecorded stretch (drawn dashed and straight, never coloured by speed).
    var gaps: [Bool]

    init(points: [LngLat], speeds: [Double?]? = nil, gaps: [Bool]? = nil) {
        self.points = points
        let n = max(points.count - 1, 0)
        self.speeds = speeds ?? Array(repeating: nil, count: n)
        self.gaps = gaps ?? Array(repeating: false, count: n)
    }

    var isDrawable: Bool { points.count >= 2 }
    var start: LngLat? { points.first }
    var end: LngLat? { points.last }
    /// Some recorded segment has a speed: draw the speed gradient.
    var hasSpeeds: Bool { zip(speeds, gaps).contains { $0.0 != nil && !$0.1 } }

    /// Recorded length (gaps are not counted: we do not know that path).
    var lengthM: Double {
        var s = 0.0
        for i in 0..<max(points.count - 1, 0) where !gaps[i] { s += Vehicle.distanceMeters(points[i], points[i + 1]) }
        return s
    }

    /// Continuous recorded runs, and the unrecorded straight stretches.
    var runs: (solid: [[LngLat]], gaps: [[LngLat]]) {
        var solid: [[LngLat]] = [], gapRuns: [[LngLat]] = []
        var run: [LngLat] = [], gap: [LngLat] = []
        for i in 0..<max(points.count - 1, 0) {
            if gaps[i] {
                if run.count >= 2 { solid.append(run) }
                run = []
                if gap.isEmpty { gap = [points[i]] }
                gap.append(points[i + 1])
            } else {
                if !gap.isEmpty { gapRuns.append(gap); gap = [] }
                if run.isEmpty { run = [points[i]] }
                run.append(points[i + 1])
            }
        }
        if run.count >= 2 { solid.append(run) }
        if !gap.isEmpty { gapRuns.append(gap) }
        return (solid, gapRuns)
    }

    /// The same line the other way round («اعكس الاتجاه»).
    var reversed: TrackLine {
        TrackLine(points: points.reversed(), speeds: speeds.reversed(), gaps: gaps.reversed())
    }
}

enum TrackDisplay {
    /// A fix less sure than this does not shape the drawn line.
    static let maxAccuracyM = 25.0
    /// An implied speed above this between two fixes is a GPS jump (≈ 250 km/h).
    static let maxJumpMps = 70.0
    /// Douglas–Peucker tolerance of the drawn line.
    static let toleranceM = 2.5
    /// CoreLocation speed accuracy good enough to colour (and to count as a top speed).
    static let goodSpeedAccuracyMps = 2.0
    /// Consecutive rejected fixes that agree with each other: it was the last kept one that jumped.
    static let rejoinAfter = 4
    /// Light smoothing of the per-segment speeds (segments on each side), so the colour does not flicker.
    static let speedSmoothing = 2

    // MARK: outliers

    /// Raw fixes the drawn line may use: accuracy ≤ 25 m, increasing time, no impossible jump.
    static func rejectOutliers(_ raw: [RawFix]) -> [RawFix] {
        var out: [RawFix] = []
        var pending: [RawFix] = []
        for f in raw.sorted(by: { $0.t < $1.t }) {
            guard f.lat.isFinite, f.lng.isFinite, abs(f.lat) <= 90, abs(f.lng) <= 180,
                  let a = f.acc, a >= 0, a <= maxAccuracyM else { continue }
            guard let p = out.last else { out.append(f); continue }
            guard f.t > p.t else { continue }
            if plausible(p.position, p.t, f.position, f.t) {
                pending = []
                out.append(f)
                continue
            }
            /* A jump. If the next fixes agree with it and each other, the kept fix was the odd one out. */
            if let q = pending.last, !plausible(q.position, q.t, f.position, f.t) { pending = [] }
            pending.append(f)
            if pending.count >= rejoinAfter {
                out.append(contentsOf: pending)
                pending = []
            }
        }
        return out
    }

    /// The same jump rule for already-kept trail points (no accuracy there; no time → kept).
    static func rejectJumps(_ pts: [TrailPoint]) -> [TrailPoint] {
        var out: [TrailPoint] = []
        for p in pts {
            guard p.lat.isFinite, p.lng.isFinite else { continue }
            guard let q = out.last else { out.append(p); continue }
            if p.t > 0, q.t > 0 {
                guard p.t > q.t else { continue }
                if !p.gap && !plausible(q.position, q.t, p.position, p.t) { continue }
            }
            out.append(p)
        }
        return out
    }

    static func plausible(_ a: LngLat, _ ta: Double, _ b: LngLat, _ tb: Double) -> Bool {
        let dt = (tb - ta) / 1000
        return Vehicle.distanceMeters(a, b) / max(dt, 0.5) <= maxJumpMps
    }

    // MARK: lines

    /// From an outing's raw fixes (the most precise source: summary, story, «اسلك هذا المسار»).
    static func line(raw: [RawFix]) -> TrackLine {
        let clean = rejectOutliers(raw)
        return line(trail: Trail.rebuild(clean).points, raw: clean)
    }

    /// From trail points (the live trail, a trail without its raw log, a friend's trail).
    /// `raw`: the cleaned raw fixes, for the speeds; nil → distance ÷ time between points.
    static func line(trail pts: [TrailPoint], raw: [RawFix]? = nil) -> TrackLine {
        let kept = TrailSimplify.simplify(rejectJumps(pts), toleranceM: toleranceM)
        guard kept.count >= 2 else { return TrackLine(points: kept.map(\.position)) }
        var speeds: [Double?] = []
        var gaps: [Bool] = []
        let goodRaw = (raw ?? []).filter { goodSpeed($0) != nil }
        var lo = 0
        for i in 0..<(kept.count - 1) {
            let a = kept[i], b = kept[i + 1]
            gaps.append(b.gap)
            if b.gap { speeds.append(nil); continue }
            if raw != nil {
                /* The raw fixes' own speeds inside this segment's time span. */
                while lo < goodRaw.count, goodRaw[lo].t < a.t { lo += 1 }
                var j = lo, sum = 0.0, n = 0
                while j < goodRaw.count, goodRaw[j].t <= b.t {
                    sum += goodSpeed(goodRaw[j])!
                    n += 1
                    j += 1
                }
                if n > 0 { speeds.append(sum / Double(n)); continue }
            }
            speeds.append(derivedSpeed(a, b))
        }
        return TrackLine(points: kept.map(\.position), speeds: smooth(speeds, gaps: gaps), gaps: gaps)
    }

    /// A GPX / planned track: positions only, no time → one colour.
    static func line(plain pts: [LngLat]) -> TrackLine {
        let tp = pts.filter { $0.lat.isFinite && $0.lng.isFinite }.map { TrailPoint(lat: $0.lat, lng: $0.lng, t: 0) }
        return TrackLine(points: TrailSimplify.douglasPeucker(tp, toleranceM: toleranceM).map(\.position))
    }

    /// A raw fix's own speed, when CoreLocation is sure enough of it.
    static func goodSpeed(_ f: RawFix) -> Double? {
        guard let s = f.spd, s.isFinite, s >= 0, s <= maxJumpMps,
              let sa = f.spdAcc, sa >= 0, sa <= goodSpeedAccuracyMps,
              let a = f.acc, a >= 0, a <= maxAccuracyM else { return nil }
        return s
    }

    /// Distance ÷ time between two recorded points; nil without times or across a long silence.
    static func derivedSpeed(_ a: TrailPoint, _ b: TrailPoint) -> Double? {
        guard a.t > 0, b.t > a.t else { return nil }
        let dt = (b.t - a.t) / 1000
        guard dt <= 120 else { return nil }
        let v = Vehicle.distanceMeters(a.position, b.position) / dt
        return v <= maxJumpMps ? v : nil
    }

    /// Mean over ±`speedSmoothing` segments of the same run (unknown ones are skipped, never filled in).
    static func smooth(_ s: [Double?], gaps: [Bool]) -> [Double?] {
        guard speedSmoothing > 0 else { return s }
        return s.indices.map { i in
            guard s[i] != nil, !gaps[i] else { return s[i] }
            var sum = 0.0, n = 0.0
            var j = i
            while j >= 0, i - j <= speedSmoothing, !gaps[j] { if let v = s[j] { sum += v; n += 1 }; j -= 1 }
            j = i + 1
            while j < s.count, j - i <= speedSmoothing, !gaps[j] { if let v = s[j] { sum += v; n += 1 }; j += 1 }
            return n > 0 ? sum / n : nil
        }
    }
}

// MARK: - speed colours along the line (Mapbox `line-gradient`)

/// Slow = light sand, fast = deep ember: our palette, not anyone else's.
enum TrackGradient {
    static let ramp: [(kmh: Double, rgb: UInt32)] = [
        (0, 0xFFE9BF), (15, 0xFFCF7A), (35, 0xF7A53D), (60, 0xE5772A), (90, 0xC4501A), (130, 0x8E2C0C),
    ]
    /// Colours are snapped to this many km/h, so equal neighbours merge into one stop.
    static let binKmh = 5.0
    /// A gradient longer than this is thinned (Mapbox draws any count, but the style JSON stays small).
    static let maxStops = 160
    static let transparent = "rgba(0,0,0,0)"
    /// Width of the hard edge between a gap and a coloured stretch, in line progress.
    static let edge = 1e-6

    static func rgb(kmh: Double) -> UInt32 {
        let k = max(0, kmh)
        guard let hi = ramp.firstIndex(where: { $0.kmh >= k }) else { return ramp.last!.rgb }
        if hi == 0 { return ramp[0].rgb }
        let a = ramp[hi - 1], b = ramp[hi]
        let u = (k - a.kmh) / (b.kmh - a.kmh)
        func ch(_ c: UInt32, _ s: UInt32) -> Double { Double((c >> s) & 0xFF) }
        func mix(_ s: UInt32) -> UInt32 { UInt32((ch(a.rgb, s) + (ch(b.rgb, s) - ch(a.rgb, s)) * u).rounded()) }
        return (mix(16) << 16) | (mix(8) << 8) | mix(0)
    }

    static func hex(kmh: Double) -> String {
        let snapped = (kmh / binKmh).rounded() * binKmh
        return "#" + String(format: "%06x", rgb(kmh: snapped))
    }

    /// Where Mapbox measures `line-progress`: along the projected (Web Mercator) line.
    static func progress(_ pts: [LngLat]) -> [Double] {
        guard pts.count >= 2 else { return pts.map { _ in 0 } }
        func merc(_ p: LngLat) -> (Double, Double) {
            let k = Double.pi / 180
            let lat = max(-85.05, min(85.05, p.lat))
            return (p.lng * k, log(tan(.pi / 4 + lat * k / 2)))
        }
        var c = [0.0]
        var prev = merc(pts[0])
        for p in pts.dropFirst() {
            let q = merc(p)
            c.append(c.last! + ((q.0 - prev.0) * (q.0 - prev.0) + (q.1 - prev.1) * (q.1 - prev.1)).squareRoot())
            prev = q
        }
        let total = c.last!
        return total > 0 ? c.map { $0 / total } : c
    }

    struct Stop: Equatable {
        var at: Double
        var color: String
    }

    /// Progress → colour stops for the whole line (gaps transparent: the dashed layer shows there).
    /// nil when there is nothing to colour by (no speed anywhere): draw one colour instead.
    /// `uniform`: colour every recorded stretch with this one colour instead (a GPX track, a
    /// friend's trail), still with the gaps cut out.
    static func stops(_ line: TrackLine, uniform: String? = nil) -> [Stop]? {
        guard line.isDrawable, line.hasSpeeds || uniform != nil else { return nil }
        let p = progress(line.points)
        /* Unknown speeds inside a run take the nearest known one before them (or after, at the start). */
        var known = line.speeds
        var last: Double?
        for i in known.indices { if line.gaps[i] { last = nil; continue }; if let v = known[i] { last = v } else { known[i] = last } }
        last = nil
        for i in known.indices.reversed() { if line.gaps[i] { last = nil; continue }; if let v = known[i] { last = v } else { known[i] = last } }

        var out: [Stop] = []
        func add(_ at: Double, _ c: String) {
            if let l = out.last, at <= l.at {
                /* Same position: the later one wins only at a hard edge. */
                if at == l.at { out[out.count - 1].color = c }
                return
            }
            out.append(Stop(at: at, color: c))
        }
        for i in line.speeds.indices {
            let a = p[i], b = p[i + 1]
            if line.gaps[i] {
                add(a + edge, transparent)
                add(b - edge, transparent)
                continue
            }
            let c = uniform ?? known[i].map { hex(kmh: Speed.kmh($0)) } ?? hex(kmh: 0)
            let prevGap = i > 0 && line.gaps[i - 1]
            let nextGap = i + 1 < line.gaps.count && line.gaps[i + 1]
            if i == 0 || prevGap { add(a, c) }
            add((a + b) / 2, c)
            if i == line.speeds.count - 1 || nextGap { add(b, c) }
        }
        out = merged(out)
        if out.count > maxStops { out = thinned(out, to: maxStops) }
        return out.count >= 2 ? out : nil
    }

    /// Drop stops inside a run of the same colour (keep its two ends).
    static func merged(_ s: [Stop]) -> [Stop] {
        guard s.count > 2 else { return s }
        var out = [s[0]]
        for i in 1..<(s.count - 1) where !(s[i].color == s[i - 1].color && s[i].color == s[i + 1].color) { out.append(s[i]) }
        out.append(s[s.count - 1])
        return out
    }

    /// Keep every k-th coloured stop; gap edges and the ends always stay.
    static func thinned(_ s: [Stop], to n: Int) -> [Stop] {
        let edges = s.indices.filter { $0 == 0 || $0 == s.count - 1 || s[$0].color == transparent
            || (s[$0 - 1].color == transparent) || (s[$0 + 1].color == transparent) }
        let room = max(n - edges.count, 2)
        let others = s.indices.filter { !edges.contains($0) }
        let step = max(1, Int((Double(others.count) / Double(room)).rounded(.up)))
        let keep = Set(edges).union(others.enumerated().filter { $0.offset % step == 0 }.map(\.element))
        return s.indices.filter { keep.contains($0) }.map { s[$0] }
    }

    /// `["interpolate", ["linear"], ["line-progress"], at, colour, …]`.
    static func expression(_ stops: [Stop]) -> [Any] {
        var e: [Any] = ["interpolate", ["linear"], ["line-progress"]]
        for s in stops { e.append(s.at); e.append(s.color) }
        return e
    }
}

// MARK: - the three big numbers

/// «المسافة · أعلى سرعة · مدة القيادة» for a track. Never invented: a number we cannot
/// stand behind is nil and shows «—».
struct TrackStats: Equatable {
    /// Recorded length of the drawn line (gaps not counted), m.
    var distanceM: Double
    /// Top speed from fixes with a good speed accuracy only (3-fix median, so one spike does not count).
    var maxKmh: Double?
    /// Moving time, s (nil: no times recorded, e.g. a GPX file).
    var movingS: Int?

    static let movingMps = 1.5
    /// A silence longer than this is not counted as driving.
    static let maxStepS = 60.0

    /// From the outing's raw fixes and the line drawn from them.
    static func make(raw: [RawFix], line: TrackLine) -> TrackStats {
        let clean = TrackDisplay.rejectOutliers(raw)
        return TrackStats(distanceM: line.lengthM, maxKmh: maxKmh(clean), movingS: clean.count >= 2 ? movingSeconds(clean) : nil)
    }

    /// From trail points only (no raw log): no trusted speed, moving time from the points' times.
    static func make(points: [TrailPoint], line: TrackLine) -> TrackStats {
        let timed = points.filter { $0.t > 0 }
        var moving = 0.0
        for i in timed.indices.dropFirst() where !timed[i].gap {
            let dt = (timed[i].t - timed[i - 1].t) / 1000
            guard dt > 0, dt <= maxStepS else { continue }
            if Vehicle.distanceMeters(timed[i - 1].position, timed[i].position) / dt >= movingMps { moving += dt }
        }
        return TrackStats(distanceM: line.lengthM, maxKmh: nil, movingS: timed.count >= 2 ? Int(moving.rounded()) : nil)
    }

    /// Positions only (GPX): the distance, nothing else.
    static func make(plain line: TrackLine) -> TrackStats { TrackStats(distanceM: line.lengthM, maxKmh: nil, movingS: nil) }

    static func maxKmh(_ clean: [RawFix]) -> Double? {
        var best: Double?
        var window: [(t: Double, v: Double)] = []
        for f in clean {
            guard let v = TrackDisplay.goodSpeed(f) else { window = []; continue }
            if let l = window.last, f.t - l.t > 3_000 { window = [] }
            window.append((f.t, v))
            if window.count > 3 { window.removeFirst() }
            guard window.count == 3 else { continue }
            let med = window.map(\.v).sorted()[1]
            best = max(best ?? 0, med)
        }
        return best.map(Speed.kmh)
    }

    static func movingSeconds(_ clean: [RawFix]) -> Int {
        var s = 0.0
        for i in clean.indices.dropFirst() {
            let a = clean[i - 1], b = clean[i]
            let dt = (b.t - a.t) / 1000
            guard dt > 0, dt <= maxStepS else { continue }
            let v = TrackDisplay.goodSpeed(b) ?? Vehicle.distanceMeters(a.position, b.position) / dt
            if v >= movingMps { s += dt }
        }
        return Int(s.rounded())
    }

    // MARK: words

    /// «١٣٫٣» (always one decimal, km).
    var distanceText: String { SaryFormat.digits(String(format: "%.1f", distanceM / 1000)) }
    /// «٦٠» or «—».
    var maxSpeedText: String { maxKmh.map { SaryFormat.number(Int($0.rounded())) } ?? "—" }
    /// «٠٢:٤٤» (hours:minutes) or «—».
    var movingText: String { movingS.map(Self.hhmm) ?? "—" }

    static func hhmm(_ seconds: Int) -> String {
        let m = max(0, seconds) / 60
        return SaryFormat.digits(String(format: "%02d:%02d", m / 60, m % 60))
    }
}
