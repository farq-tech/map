import Foundation

/// The car sits on the ground it drives over: level on the flat, nose up on a climb, nose
/// down (tail up) on a descent, rolled on a side slope — from the terrain (Mapbox Terrain
/// DEM, ~30 m, so the grade is approximate) along the car's heading, smoothed and clamped,
/// plus a very gentle suspension bob off-road. Pure; the renderer feeds it elevations.
enum BodyDynamics {
    /// Sample the terrain this far ahead / behind along the heading, and to each side.
    static let alongM = 5.0
    static let acrossM = 1.6
    /// Visual clamp (the DEM is coarse: never a cartoon tilt).
    static let maxPitchDeg = 20.0
    static let maxRollDeg = 12.0
    /// Smoothing time constant.
    static let tauS = 0.45
    /// Bob amplitude (degrees) at full off-road speed.
    static let bobDeg = 0.7
    static let bobFullKmh = 50.0
    /// The grade chip by my car shows from this |grade| and hides below `chipHideGrade`.
    static let chipShowGrade = 8.0
    static let chipHideGrade = 6.0

    /// Pitch (nose up positive) and roll (right side down positive), degrees, from four elevations.
    static func tilt(front: Double, back: Double, left: Double, right: Double) -> (pitch: Double, roll: Double) {
        let pitch = atan((front - back) / (2 * alongM)) * 180 / .pi
        let roll = atan((left - right) / (2 * acrossM)) * 180 / .pi
        return (max(-maxPitchDeg, min(maxPitchDeg, pitch)), max(-maxRollDeg, min(maxRollDeg, roll)))
    }

    /// Grade in percent from two elevations `2 * alongM` apart (positive uphill).
    static func gradePercent(front: Double, back: Double) -> Double {
        (front - back) / (2 * alongM) * 100
    }

    /// Exponential smoothing towards a target.
    static func smooth(_ current: Double, _ target: Double, dt: Double, tau: Double = tauS) -> Double {
        current + (target - current) * (1 - exp(-max(0, dt) / tau))
    }

    /// Suspension bob (pitch, roll) at time t: two incommensurate sines, proportional to speed off-road.
    static func bob(t: Double, speedKmh: Double, offRoad: Bool, seed: Double) -> (pitch: Double, roll: Double) {
        guard offRoad, speedKmh > 3 else { return (0, 0) }
        let a = bobDeg * min(1, speedKmh / bobFullKmh)
        let p = a * (0.65 * sin(2 * .pi * 1.7 * t + seed) + 0.35 * sin(2 * .pi * 2.9 * t + seed * 1.7))
        let r = a * 0.6 * (0.6 * sin(2 * .pi * 1.3 * t + seed * 2.3) + 0.4 * sin(2 * .pi * 3.4 * t + seed))
        return (p, r)
    }

    /// `model-rotation` for a car with heading and a body tilt. Mapbox applies X, then Y, then Z
    /// (yaw) to the model in its own frame, so pitch is about the car's lateral axis
    /// and roll about its length. `signs` maps nose-up / right-down onto the model's axes.
    static func modelRotation(heading: Double?, pitch: Double, roll: Double) -> [Double] {
        var r = Vehicle.rotation(heading)
        r[0] = pitchSign * pitch
        r[1] = rollSign * roll
        return r
    }

    /// Axis signs for the generated SUV (nose +Z, turned by `Vehicle.modelHeadingOffset`);
    /// checked on the simulator with an exaggerated tilt.
    static var pitchSign = 1.0
    static var rollSign = 1.0

    /// The 2D icon: a small shift of the car and its shadow (nose up: shadow falls behind).
    static func iconShift(pitch: Double, bob: Double) -> (car: Double, shadowBackM: Double) {
        (-(bob * 0.6), max(-1.2, min(1.2, pitch / maxPitchDeg * 1.2)))
    }

    /// «صعود ١٢٪» / «نزول ٨٪» for my car, with hysteresis; nil hides it.
    static func gradeChip(grade: Double?, shown: Bool, speedKmh: Double, driving: Bool) -> String? {
        guard let g = grade, g.isFinite else { return nil }
        if driving && speedKmh > 60 { return nil }
        let threshold = shown ? chipHideGrade : chipShowGrade
        guard abs(g) >= threshold else { return nil }
        let n = SaryFormat.number(Int(min(99, abs(g)).rounded()))
        return g > 0 ? "▲ صعود \(n)٪" : "▼ نزول \(n)٪"
    }
}

/// Day contact shadow and night lights, from the real sun.
enum CarLights {
    /// Sun azimuth, degrees from north (clockwise), same low-precision formula as `SunLight`.
    static func sunAzimuthDeg(_ date: Date, lat: Double, lng: Double) -> Double {
        let rad = Double.pi / 180
        let d = date.timeIntervalSince1970 / 86_400 + 2_440_587.5 - 2_451_545.0
        let g = (357.529 + 0.98560028 * d) * rad
        let q = 280.459 + 0.98564736 * d
        let L = (q + 1.915 * sin(g) + 0.02 * sin(2 * g)) * rad
        let e = (23.439 - 0.00000036 * d) * rad
        let ra = atan2(cos(e) * sin(L), cos(L))
        let dec = asin(sin(e) * sin(L))
        let gmst = (18.697374558 + 24.06570982441908 * d).truncatingRemainder(dividingBy: 24)
        let ha = (gmst * 15 + lng) * rad - ra
        let phi = lat * rad
        let az = atan2(-sin(ha), tan(dec) * cos(phi) - sin(phi) * cos(ha)) / rad
        return MotionTuning.norm(az)
    }

    /// Where the contact shadow sits (metres, away from the sun) and how dark it is; nil at night.
    static func shadow(elevationDeg el: Double, azimuthDeg az: Double) -> (offset: MotionVec, opacity: Double)? {
        guard el > 2 else { return nil }
        let len = min(2.2, 1.1 / tan(el * .pi / 180))
        let o = 0.26 * min(1, (el - 2) / 12)
        return (MotionVec.heading(az + 180, len), o)
    }

    /// Lights are on at night (and in the dark half of twilight).
    static func lightsOn(elevationDeg el: Double, forcedNight: Bool) -> Bool { forcedNight || el < -3 }
}
