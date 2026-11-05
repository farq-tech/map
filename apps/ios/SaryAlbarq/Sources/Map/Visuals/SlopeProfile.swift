import Foundation

/// «انحدار تقريبي»: where a route climbs or drops steeply, from Mapbox Terrain-DEM (the
/// ~30 m elevation model the 3D terrain already uses). Approximate by nature: a 30 m grid
/// cannot see a single dune face, so grades are measured over a 90 m baseline (three cells)
/// and only stretches that stay steep are marked — always labelled as approximate.
enum SlopeProfile {
    struct Segment: Equatable {
        var points: [LngLat]
        /// The steepest grade along it, percent (rise / run × 100, absolute).
        var maxGradePct: Double
    }

    /// Grade from which a stretch is marked (15 %: a hard climb for a loaded car on sand).
    static let steepPct = 15.0
    /// From here on it is drawn in the stronger colour.
    static let verySteepPct = 25.0
    static let spacingM = 30.0
    static let baselineM = 90.0
    /// Upper bound on DEM look-ups per refresh (≈ 45 km of route at 30 m).
    static let maxSamples = 1_500

    /// Points every `spacingM` along the line (its vertices are not kept: even spacing matters more).
    static func resample(_ line: [LngLat], spacingM: Double = spacingM, maxSamples: Int = maxSamples) -> [LngLat] {
        guard line.count >= 2 else { return line }
        var total = 0.0
        for i in 1..<line.count { total += PlanGeo.meters(line[i - 1], line[i]) }
        guard total > 0 else { return [line[0]] }
        let step = max(spacingM, total / Double(maxSamples - 1))
        var out = [line[0]]
        var carried = 0.0
        for i in 1..<line.count {
            let a = line[i - 1], b = line[i]
            let seg = PlanGeo.meters(a, b)
            guard seg > 0 else { continue }
            var at = step - carried
            while at <= seg {
                let k = at / seg
                out.append(LngLat(lng: a.lng + (b.lng - a.lng) * k, lat: a.lat + (b.lat - a.lat) * k))
                at += step
            }
            carried = seg - (at - step)
        }
        if let last = line.last, out.last != last { out.append(last) }
        return out
    }

    /// Steep stretches. `elevations[i]` is the terrain height (metres, not exaggerated) at
    /// `samples[i]`, nil where the DEM tile is not loaded — a gap, never a guess.
    static func steep(samples: [LngLat], elevations: [Double?], baselineM: Double = baselineM, thresholdPct: Double = steepPct) -> [Segment] {
        guard samples.count == elevations.count, samples.count >= 2 else { return [] }
        var flagged = Array(repeating: false, count: samples.count)
        var grade = Array(repeating: 0.0, count: samples.count)
        for i in 0..<samples.count {
            guard let e0 = elevations[i] else { continue }
            /* The first sample at least `baselineM` ahead. */
            var run = 0.0
            var k = i
            while k + 1 < samples.count, run < baselineM {
                run += PlanGeo.meters(samples[k], samples[k + 1])
                k += 1
            }
            guard run >= baselineM * 0.8, let e1 = elevations[k] else { continue }
            /* Every sample in between must be known too (no bridging a gap in the tiles). */
            if (i...k).contains(where: { elevations[$0] == nil }) { continue }
            let g = abs(e1 - e0) / run * 100
            if g >= thresholdPct {
                for m in i...k {
                    flagged[m] = true
                    grade[m] = max(grade[m], g)
                }
            }
        }
        var out: [Segment] = []
        var cur: [LngLat] = []
        var maxG = 0.0
        for i in 0..<samples.count {
            if flagged[i] {
                cur.append(samples[i])
                maxG = max(maxG, grade[i])
            } else if !cur.isEmpty {
                if cur.count >= 2 { out.append(Segment(points: cur, maxGradePct: maxG)) }
                cur = []
                maxG = 0
            }
        }
        if cur.count >= 2 { out.append(Segment(points: cur, maxGradePct: maxG)) }
        return out
    }

    /// The legend line under the map's source line.
    static let legend = "انحدار تقريبي ≥ ١٥٪ (من نموذج ارتفاع ~٣٠ م)"
}
