import Foundation

/// «آثار الكفرات»: two thin ruts behind a car on sand, ≈0.8 m each side of its centre line,
/// fading out with distance (~250 m) and age (~3 min). Only where the car really drove off
/// paved roads; laid under the recorded trail, which stays the one line of the route.
enum TyreTracks {
    static let halfTrackM = 0.8
    static let rutWidthM = 0.35

    /// Pixels for `metres` at the car's drawn scale (`Vehicle.scaleAt`), one stop per zoom 12…22,
    /// for 512-px tiles around Saudi latitudes; never thinner than `min` px.
    static func zoomExpression(metres: Double, min floor: Double) -> [Any] {
        var e: [Any] = ["interpolate", ["linear"], ["zoom"]]
        for z in 12 ... 22 {
            let px = metres * Vehicle.scaleAt(zoom: Double(z)) / (78_271.517 * cos(25 * Double.pi / 180) / pow(2, Double(z)))
            let v = abs(px) < floor ? (px < 0 ? -floor : floor) : px
            e += [Double(z), (v * 100).rounded() / 100]
        }
        return e
    }
    static let maxLengthM = 250.0
    static let maxAgeS = 180.0
    /// A new sample every this many metres of drawn travel.
    static let stepM = 2.0
    /// Samples per drawn chunk (each chunk has one opacity).
    static let chunk = 5
    static let baseOpacity = 0.42

    struct Sample: Equatable {
        var p: MotionVec
        var heading: Double
        var t: Double
        var sand: Bool
    }

    /// One drawn piece of a rut: its points and opacity.
    struct Piece: Equatable {
        var points: [MotionVec]
        var opacity: Double
    }

    final class Ruts {
        private(set) var samples: [Sample] = []

        /// Record where the car is drawn. Returns true when the ruts changed.
        @discardableResult
        func add(_ p: MotionVec, heading: Double, at t: Double, sand: Bool, moving: Bool) -> Bool {
            guard moving else { return prune(t) }
            if let last = samples.last, (p - last.p).length < TyreTracks.stepM { return prune(t) }
            /* A jump (a snap, a reconnect) is not a track. */
            if let last = samples.last, (p - last.p).length > 60 { samples.removeAll() }
            samples.append(Sample(p: p, heading: heading, t: t, sand: sand))
            prune(t)
            return true
        }

        /// Drop what is older than `maxAgeS` or beyond `maxLengthM` from the car.
        @discardableResult
        func prune(_ t: Double) -> Bool {
            let n = samples.count
            samples.removeAll { t - $0.t > TyreTracks.maxAgeS }
            var len = 0.0
            var cut = 0
            if samples.count >= 2 {
                for i in stride(from: samples.count - 1, to: 0, by: -1) {
                    len += (samples[i].p - samples[i - 1].p).length
                    if len > TyreTracks.maxLengthM { cut = i - 1; break }
                }
            }
            if cut > 0 { samples.removeFirst(cut) }
            return samples.count != n
        }

        var isEmpty: Bool { samples.isEmpty }
    }

    /// The ruts' centre line as fading pieces (sand stretches only), oldest first; the map draws
    /// it twice, offset `halfTrackM` (at the car's drawn scale) each side.
    static func pieces(_ samples: [Sample], now: Double) -> [Piece] {
        guard samples.count >= 2 else { return [] }
        /* Distance from the car (the newest sample) back along the ruts. */
        var dist = [Double](repeating: 0, count: samples.count)
        for i in stride(from: samples.count - 2, through: 0, by: -1) {
            dist[i] = dist[i + 1] + (samples[i + 1].p - samples[i].p).length
        }
        var out: [Piece] = []
        var i = 0
        while i < samples.count - 1 {
            guard samples[i].sand, samples[i + 1].sand else { i += 1; continue }
            var j = i
            while j < samples.count - 1, j - i < chunk, samples[j + 1].sand { j += 1 }
            let mid = (i + j) / 2
            let fadeD = 1 - dist[mid] / maxLengthM
            let fadeT = 1 - (now - samples[mid].t) / maxAgeS
            let o = baseOpacity * max(0, min(1, fadeD)) * max(0, min(1, fadeT))
            if o > 0.01 { out.append(Piece(points: (i ... j).map { samples[$0].p }, opacity: o)) }
            i = j
        }
        return out
    }
}
