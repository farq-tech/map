import Foundation

/// Fixed, plausible trails for the demo outing (screenshots and UI tests only;
/// launched with `-demo -demoTrail`). Never mixed with a real outing.
enum DemoTrail {
    /// Where «أنا» stands in the demo shots (simctl location is set here too).
    static let me = LngLat(lng: 46.6753, lat: 24.7122)
    static let start = LngLat(lng: 46.6930, lat: 24.7268)

    /// From «نقطة البداية» to me: ~2.6 km of wandering track with one unrecorded stretch.
    static func mine(now: Date) -> Trail {
        let n = 46
        var pts: [TrailPoint] = []
        let t0 = now.timeIntervalSince1970 * 1000 - 50 * 60_000
        for i in 0...n {
            let u = Double(i) / Double(n)
            /* A gentle S-curve between the dunes. */
            let wob = sin(u * .pi * 3) * 0.0018 * (1 - u * 0.4)
            let lat = start.lat + (me.lat - start.lat) * u + wob * 0.6
            let lng = start.lng + (me.lng - start.lng) * u - wob
            pts.append(TrailPoint(lat: lat, lng: lng, t: t0 + u * 48 * 60_000))
        }
        /* The app was in the background between 45 % and 62 %: only the two ends are known. */
        let a = Int(Double(n) * 0.45), b = Int(Double(n) * 0.62)
        var kept = Array(pts[0...a])
        var resume = pts[b]
        resume.gap = true
        kept.append(resume)
        kept += pts[(b + 1)...]
        var t = Trail()
        t.points = kept
        t.gapNext = true
        return t
    }

    /// A friend's last ~25 minutes, ending (just before) their current position.
    static func friend(to p: LngLat, seed: String, endMs: Double) -> [TrailPoint] {
        let h = seed.unicodeScalars.reduce(7) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        let dir = Double(h % 360) * .pi / 180
        let k = 18
        var out: [TrailPoint] = []
        for i in 0...k {
            let back = Double(k - i) * 70.0
            let wob = sin(Double(i) * 0.7 + Double(h % 7)) * 35
            let x = sin(dir) * back + cos(dir) * wob
            let y = cos(dir) * back - sin(dir) * wob
            let q = TrailGeo.lngLat(x, y, ref: p)
            out.append(TrailPoint(lat: q.lat, lng: q.lng, t: endMs - Double(k - i) * 80_000))
        }
        return out
    }
}
