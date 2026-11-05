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

#if DEBUG
extension DemoTrail {
    /// «النفود الكبير» demo drive (screenshots / UI tests only, `-demo`): ~13 km over the dunes,
    /// 1 Hz raw fixes with their own speeds (15–60 km/h), a three-minute stop, one inaccurate
    /// fix and one GPS jump (both rejected by `TrackDisplay`). Clearly demo data; never mixed
    /// with a real outing.
    static let dunesStart = LngLat(lng: 40.9620, lat: 28.1700)

    static func dunesRaw(t0: Double = 1_799_990_000_000) -> [RawFix] {
        var out: [RawFix] = []
        var x = 0.0, y = 0.0, s = 0.0
        var t = 0.0
        var seed: UInt64 = 0x5A17
        func noise() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double((seed >> 33) % 1000) / 1000 - 0.5
        }
        while s < 13_300 {
            let stopped = t >= 600 && t < 780
            /* 15–60 km/h over the dunes: slower on the climbs, faster on the flats. */
            let v = stopped ? 0 : 4.2 + 6.2 * (1 + sin(s / 820)) * (0.75 + 0.25 * sin(s / 260))
            let heading = (48 + 38 * sin(s / 1150) + 22 * sin(s / 180)) * .pi / 180
            x += sin(heading) * v
            y += cos(heading) * v
            s += v
            t += 1
            let p = TrailGeo.lngLat(x + noise() * 2.4, y + noise() * 2.4, ref: dunesStart)
            out.append(RawFix(t: t0 + t * 1000, lat: p.lat, lng: p.lng, acc: 4 + abs(noise()) * 6,
                              spd: max(0, v + noise() * 0.4), crs: heading * 180 / .pi, spdAcc: 0.4 + abs(noise()) * 0.8))
        }
        /* What a real phone also records: a 45 m Wi-Fi fix and a 300 m jump. */
        if out.count > 400 {
            out[200].acc = 45
            let j = TrailGeo.lngLat(300, 0, ref: LngLat(lng: out[350].lng, lat: out[350].lat))
            out[350].lat = j.lat
            out[350].lng = j.lng
        }
        return out
    }

    static func dunesSubject() -> FollowSubject? {
        var trail = Trail.rebuild(dunesRaw())
        trail.compact()
        return FollowSubject.outing(id: "demo-dunes", name: "كشتة النفود الكبير", trail: trail, raw: dunesRaw())
    }
}
#endif
