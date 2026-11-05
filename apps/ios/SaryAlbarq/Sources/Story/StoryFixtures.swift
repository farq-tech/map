#if DEBUG
import Foundation

/// DEBUG-only sample outing for screenshots, previews and tests: a winter
/// «كشتة» into the red dunes of Nafud al-Thuwairat. Never compiled into Release,
/// never fed to the live map or the network — it only stands in for a trail
/// this device recorded.
enum StoryFixtures {
    /// Route corners: (lng, lat, metres per second to get here, wiggle amplitude in metres).
    private static let legs: [(Double, Double, Double, Double)] = [
        (44.8776, 26.0776, 0, 0),      // farms (start: inside the privacy zone)
        (44.8730, 26.0640, 11, 4),
        (44.8685, 26.0450, 14, 3),     // onto the highway
        (44.8470, 26.0490, 26, 2),
        (44.8255, 26.0532, 25, 2),     // leave the road at the dune edge
        (44.8140, 26.0695, 8, 38),
        (44.8006, 26.0857, 7, 46),
        (44.7870, 26.0980, 7, 40),
        (44.7800, 26.1102, 6, 30),     // camp (the long stop)
        (44.7711, 26.1305, 7, 44),
        (44.7870, 26.1448, 8, 50),
        (44.8030, 26.1570, 8, 40),
        (44.8098, 26.1387, 8, 36),
        (44.8160, 26.1200, 9, 34),
        (44.8232, 26.1000, 10, 26),
        (44.8345, 26.0857, 11, 12),    // back out at the farms
        (44.8600, 26.0920, 15, 4),
        (44.8866, 26.0959, 12, 3),     // end (inside the end privacy zone)
    ]
    static let campIndex = 8
    /// The stretch that was not recorded (app closed): from corner 12 to 13.
    static let gapLeg = 13
    static let stopS = 85.0 * 60

    /// The sample trail, starting at `start`.
    static func trail(start: Date = Date(timeIntervalSince1970: 1_793_442_600)) -> [StoryPoint] {
        var pts: [StoryPoint] = []
        var t = start.timeIntervalSince1970 * 1000
        let first = legs[0]
        pts.append(StoryPoint(lat: first.1, lng: first.0, t: t))
        var seed: UInt64 = 0x5A17_B0A1
        func rnd() -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double((seed >> 33) & 0xFFFF) / Double(0xFFFF) - 0.5
        }
        for i in 1..<legs.count {
            let (lng0, lat0, _, _) = legs[i - 1]
            let (lng1, lat1, speed, amp) = legs[i]
            let a = LngLat(lng: lng0, lat: lat0), b = LngLat(lng: lng1, lat: lat1)
            let d = Vehicle.distanceMeters(a, b)
            if i == gapLeg {
                /* App closed for this stretch: one straight unknown step. */
                t += d / speed * 1000
                pts.append(StoryPoint(lat: lat1, lng: lng1, t: t, gap: true))
                continue
            }
            let steps = max(2, Int(d / 45))
            /* Perpendicular unit (metres → degrees) for the dune wiggles. */
            let k = Double.pi / 180
            let ex = (lng1 - lng0) * cos(lat0 * k), ey = lat1 - lat0
            let el = max(1e-12, (ex * ex + ey * ey).squareRoot())
            let nx = -ey / el, ny = ex / el
            let phase = rnd() * 6
            for s in 1...steps {
                let u = Double(s) / Double(steps)
                let env = sin(u * .pi)
                let w = amp * env * (sin(u * 9.0 + phase) + 0.35 * sin(u * 23.0 + phase * 2)) + amp * 0.08 * rnd()
                let dLat = ny * w / 111_320
                let dLng = nx * w / (111_320 * cos(lat0 * k))
                t += d / Double(steps) / speed * 1000
                pts.append(StoryPoint(lat: lat0 + (lat1 - lat0) * u + dLat, lng: lng0 + (lng1 - lng0) * u + dLng, t: t))
            }
            if i == campIndex {
                /* Parked: the trail keeps no points while still; the next one comes when we drive off. */
                t += stopS * 1000
                pts.append(StoryPoint(lat: lat1 + 0.00012, lng: lng1 + 0.00009, t: t))
            }
        }
        return pts
    }

    static let companions = ["أبو فهد", "سلطان", "نورة", "سعد", "ريم"]

    static func waypoints() -> [StoryWaypoint] {
        [
            StoryWaypoint(kind: "camp", lat: legs[campIndex].1, lng: legs[campIndex].0),
            StoryWaypoint(kind: "passable", lat: 26.0612, lng: 44.8199),
            StoryWaypoint(kind: "danger", lat: 26.1497, lng: 44.7952),
            /* Inside the start zone: hidden unless «أظهر نقطة البداية» is on. */
            StoryWaypoint(kind: "water", lat: 26.0760, lng: 44.8770),
        ]
    }

    static func facts(start: Date = Date(timeIntervalSince1970: 1_793_442_600), name: String = "كشتة نفود الثويرات") -> StoryFacts {
        let pts = trail(start: start)
        let end = Date(timeIntervalSince1970: pts.last!.t / 1000)
        var len = 0.0
        for i in pts.indices.dropFirst() where !pts[i].gap { len += Vehicle.distanceMeters(pts[i - 1].position, pts[i].position) }
        return StoryFacts(outingName: name, startedAt: start.addingTimeInterval(-10 * 60), endedAt: end.addingTimeInterval(5 * 60),
                          distanceM: len, durationS: Int(end.timeIntervalSince(start)) + 15 * 60, movingS: Int(end.timeIntervalSince(start) - stopS),
                          memberCount: companions.count + 1, companionNames: companions, trail: pts, waypoints: waypoints())
    }
}
#endif
