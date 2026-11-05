import Foundation

/// «طيران درون استكشافي»: an orbit around one point — a short glide in, then one full
/// circle at a low altitude and a steep pitch (~62°), easing in and out so it never jerks.
/// Pure: the camera for any time `t`; `DroneFlight` (MapVisualsDirector) plays it and stops
/// on the first touch.
struct DroneOrbit: Equatable {
    struct Frame: Equatable {
        var center: LngLat
        var zoom: Double
        var bearing: Double
        var pitch: Double
    }

    var center: LngLat
    /// The camera when the flight starts (the glide in starts from here).
    var from: Frame
    /// Seconds for the glide to the orbit's start.
    var approachS: Double = 2.0
    /// Seconds for the full circle (the brief asks for ~20–25 s).
    var orbitS: Double = 22
    var pitch: Double = DroneOrbit.defaultPitch
    /// Low: about 450–600 m of view across at this zoom and pitch.
    var zoom: Double = 15.6
    /// Degrees: one full circle.
    var sweep: Double = 360

    static let defaultOrbitS = 22.0
    /// Steep enough for the dunes to stand up, low enough that the horizon stays near.
    static let defaultPitch = 62.0

    var duration: Double { approachS + orbitS }

    /// The camera at `t` seconds; nil once the flight is over.
    func frame(at t: Double) -> Frame? {
        guard t >= 0, t <= duration else { return nil }
        if t < approachS {
            let k = Self.easeInOut(t / approachS)
            /* The circle starts at the current bearing: the glide only moves, zooms and tilts. */
            return Frame(center: LngLat(lng: from.center.lng + (center.lng - from.center.lng) * k, lat: from.center.lat + (center.lat - from.center.lat) * k),
                         zoom: from.zoom + (zoom - from.zoom) * k, bearing: Self.norm(from.bearing),
                         pitch: from.pitch + (pitch - from.pitch) * k)
        }
        let u = (t - approachS) / orbitS
        return Frame(center: center, zoom: zoom, bearing: Self.norm(from.bearing + sweep * Self.easeInOut(u)), pitch: pitch)
    }

    /// Sampled path (for tests and the signpost log): one frame every `step` seconds, end included.
    func path(step: Double = 0.5) -> [Frame] {
        var out: [Frame] = []
        var t = 0.0
        while t < duration {
            if let f = frame(at: t) { out.append(f) }
            t += step
        }
        if let f = frame(at: duration) { out.append(f) }
        return out
    }

    /// Cosine ease in / out: zero speed at both ends, the fastest turn mid-circle
    /// (π/2 × 360° / 22 s ≈ 26°/s — calm at a 65° pitch).
    static func easeInOut(_ x: Double) -> Double {
        let t = min(1, max(0, x))
        return (1 - cos(Double.pi * t)) / 2
    }

    static func norm(_ b: Double) -> Double {
        let r = b.truncatingRemainder(dividingBy: 360)
        return r < 0 ? r + 360 : r
    }

    /// Whether a flight may start now. Driving: never (a moving camera is a distraction).
    static func allowed(driving: Bool) -> Bool { !driving }
}
