import Foundation

/// «الغبار»: soft sand-coloured puffs behind a car driving off paved roads.
///
/// Driven by real data only: the car's drawn speed and heading, whether it is on a paved
/// street (`RoadSnap`), and the wind and rain from the weather cache. Puffs expand, drift
/// with the real wind and fade in 2–4 s. The whole map holds at most `maxParticles`.
enum DustGate {
    /// No dust below this (a crawl over sand does not lift a plume).
    static let minKmh = 12.0
    /// Full density at this speed.
    static let fullKmh = 60.0

    /// Whether a car may emit dust right now.
    static func emits(speedKmh: Double, onPavedRoad: Bool, raining: Bool, enabled: Bool, lowPower: Bool, reduceMotion: Bool, moving: Bool) -> Bool {
        enabled && moving && !lowPower && !reduceMotion && !raining && !onPavedRoad && speedKmh > minKmh
    }

    /// 0…1 by speed above `minKmh` (0 at the threshold, 1 from `fullKmh`).
    static func density(speedKmh: Double) -> Double {
        max(0, min(1, (speedKmh - minKmh) / (fullKmh - minKmh)))
    }

    /// Puffs per second for one car: a few at the threshold, ~14 at full speed.
    static func rate(speedKmh: Double, driving: Bool) -> Double {
        let d = density(speedKmh: speedKmh)
        guard speedKmh > minKmh else { return 0 }
        return (2.5 + 11.5 * d) * (driving ? 0.6 : 1)
    }
}

/// The wind as the dust feels it, from the weather cache's current hour.
struct DustWind: Equatable {
    /// Where the wind blows TO, degrees from north.
    var towardDeg: Double
    var speedMps: Double

    /// From the meteorological fields (wind FROM `fromDeg`, km/h).
    init?(fromDeg: Double?, kmh: Double?) {
        guard let f = fromDeg, let k = kmh, f.isFinite, k.isFinite, k >= 0 else { return nil }
        towardDeg = (f + 180).truncatingRemainder(dividingBy: 360)
        speedMps = k / 3.6
    }

    init(towardDeg: Double, speedMps: Double) {
        self.towardDeg = towardDeg
        self.speedMps = speedMps
    }

    /// Near the ground fine dust moves at a fraction of the 10 m wind.
    static let groundFactor = 0.55

    var drift: MotionVec { MotionVec.heading(towardDeg, speedMps * Self.groundFactor) }
}

struct DustParticle: Equatable {
    var p: MotionVec
    var v: MotionVec
    var born: Double
    var life: Double
    var r0: Double
    var r1: Double
    var peak: Double
    var car: String

    func age(_ t: Double) -> Double { (t - born) / life }

    /// Opacity: a quick rise, then a long soft fade.
    func opacity(_ t: Double) -> Double {
        let a = age(t)
        guard a >= 0, a < 1 else { return 0 }
        return peak * MotionTuning.smoothstep(a / 0.12) * pow(1 - a, 1.6)
    }

    /// Radius in metres: grows fast at first, then slower.
    func radius(_ t: Double) -> Double {
        let a = max(0, min(1, age(t)))
        return r0 + (r1 - r0) * (1 - (1 - a) * (1 - a))
    }
}

final class DustSystem {
    static let maxParticles = 120
    static let minLife = 2.0, maxLife = 4.0
    /// Puff velocity relaxes to the wind's in this.
    static let dragTauS = 0.8

    private(set) var particles: [DustParticle] = []
    private var carry: [String: Double] = [:]
    private var side: [String: Double] = [:]
    private var rng: UInt64
    var wind: DustWind?

    init(seed: UInt64 = 0x9E37_79B9) { rng = seed }

    private func rand() -> Double {
        rng = rng &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double((rng >> 33) % 10_000) / 10_000
    }

    /// Emit for one car this frame. `p` is the car's centre, metres in the shared frame.
    func emit(car: String, at p: MotionVec, heading: Double, speedMps: Double, dt: Double, now: Double, driving: Bool, activeCars: Int, scale: Double = 1) {
        let kmh = speedMps * 3.6
        let rate = DustGate.rate(speedKmh: kmh, driving: driving)
        guard rate > 0, dt > 0 else { carry[car] = 0; return }
        var acc = (carry[car] ?? 0) + rate * min(dt, 0.1)
        let d = DustGate.density(speedKmh: kmh)
        let fwd = MotionVec.heading(heading)
        let right = MotionVec.heading(heading + 90)
        /* Fair share: a busy convoy never starves the newest car of its plume. */
        let share = max(8, Self.maxParticles / max(1, activeCars))
        while acc >= 1 {
            acc -= 1
            let s = (side[car] ?? 1) * -1
            side[car] = s
            /* At the rear wheels of the car as drawn (larger than life when zoomed out). */
            let origin = p + fwd * (-2.3 * scale) + right * ((s * 0.85 + (rand() - 0.5) * 0.3) * scale)
            let v = fwd * (-0.22 * speedMps) + right * ((rand() - 0.5) * 1.2) + fwd * ((rand() - 0.5) * 0.6)
            let life = Self.minLife + (Self.maxLife - Self.minLife) * (0.35 + 0.65 * d) * (0.75 + 0.25 * rand())
            let part = DustParticle(p: origin, v: v, born: now, life: min(Self.maxLife, life), r0: (0.9 + 0.4 * rand()) * scale.squareRoot(),
                                    r1: (3.2 + 4.2 * d + 1.2 * rand()) * scale.squareRoot(), peak: (0.2 + 0.26 * d) * (driving ? 0.7 : 1), car: car)
            let mine = particles.filter { $0.car == car }.count
            if mine >= share || particles.count >= Self.maxParticles {
                /* Drop this car's oldest (or the map's oldest) puff, never exceed the cap. */
                if let i = particles.firstIndex(where: { $0.car == car }) ?? particles.indices.first { particles.remove(at: i) }
            }
            particles.append(part)
        }
        carry[car] = acc
    }

    /// Advance every puff: drag towards the wind, then drop the faded ones.
    func step(dt: Double, now: Double) {
        let drift = wind?.drift ?? .zero
        let k = 1 - exp(-max(0, dt) / Self.dragTauS)
        for i in particles.indices {
            particles[i].v = particles[i].v + (drift - particles[i].v) * k
            particles[i].p = particles[i].p + particles[i].v * dt
        }
        particles.removeAll { $0.age(now) >= 1 }
    }

    func clear() {
        particles.removeAll()
        carry.removeAll()
    }

    var isEmpty: Bool { particles.isEmpty }
}
