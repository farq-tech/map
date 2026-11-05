import XCTest
@testable import SaryAlbarq

/// «واقعية القيادة»: smooth motion between fixes, dust, tyre tracks, body tilt, lights, OSM tracks.
final class CarMotionTests: XCTestCase {
    let origin = LngLat(lng: 40.96, lat: 28.17)
    var frame: MotionFrame { MotionFrame(origin: origin) }

    /// A fix `x`/`y` metres from the origin.
    func fix(_ x: Double, _ y: Double, atS: Double, speed: Double? = nil, course: Double? = nil, live: Bool = true, acc: Double = 5) -> MotionFix {
        MotionFix(position: frame.world(MotionVec(x: x, y: y)), atMs: atS * 1000, speedMps: speed, course: course, accuracyM: acc,
                  live: live, approximate: acc > 60)
    }

    func local(_ p: MotionPose?) -> MotionVec { frame.local(p!.position) }

    func testFirstFixIsPlacedExactly() {
        let m = CarMotion(isMe: true)
        m.ingest(fix(0, 0, atS: 100, speed: 10, course: 0), now: 0, wallMs: 100_000, reduceMotion: false)
        let p = m.pose(0)!
        XCTAssertEqual(local(p).length, 0, accuracy: 0.01)
        XCTAssertEqual(p.heading ?? -1, 0, accuracy: 0.01)
    }

    /// My car between 1 Hz fixes: it keeps moving at its speed, no stop-and-go.
    func testDeadReckoningContinuesBetweenFixes() {
        let m = CarMotion(isMe: true)
        for i in 0 ... 5 {
            m.ingest(fix(0, Double(i) * 10, atS: Double(i), speed: 10, course: 0), now: Double(i), wallMs: Double(i) * 1000, reduceMotion: false)
        }
        let a = local(m.pose(5.3)), b = local(m.pose(5.6))
        XCTAssertGreaterThan(a.y, 51.5)
        XCTAssertEqual(b.y - a.y, 3, accuracy: 0.6, "≈10 m/s between fixes")
        XCTAssertEqual(a.x, 0, accuracy: 0.3)
    }

    /// Never more than 1.5 s of estimate past the last fix, and it comes to rest smoothly.
    func testDeadReckoningStopsWithinHorizon() {
        let m = CarMotion(isMe: true)
        for i in 0 ... 4 {
            m.ingest(fix(0, Double(i) * 10, atS: Double(i), speed: 10, course: 0), now: Double(i), wallMs: Double(i) * 1000, reduceMotion: false)
        }
        let far = local(m.pose(4 + 10))
        XCTAssertLessThanOrEqual(far.y, 40 + 10 * MotionTuning.horizonS + 1.5)
        XCTAssertFalse(m.pose(4 + 10)!.animating)
        XCTAssertEqual(MotionTuning.reckonTime(100), MotionTuning.horizonS, accuracy: 0.001)
        XCTAssertEqual(MotionTuning.reckonTime(0.5), 0.5, accuracy: 1e-9)
        /* Continuous: no jump at the end of the linear part. */
        XCTAssertEqual(MotionTuning.reckonTime(1.0001), 1.0001, accuracy: 0.001)
    }

    /// GPS latency: the fix arrives 0.4 s after it was taken; the car is drawn where it is now.
    func testLatencyCompensation() {
        let m = CarMotion(isMe: true)
        for i in 0 ... 3 {
            m.ingest(fix(0, Double(i) * 10, atS: Double(i), speed: 10, course: 0), now: Double(i) + 0.4, wallMs: (Double(i) + 0.4) * 1000, reduceMotion: false)
        }
        let p = local(m.pose(3.4 + MotionTuning.blendS + 0.01))
        XCTAssertEqual(p.y, 30 + 10 * (0.4 + MotionTuning.blendS + 0.01), accuracy: 1.2)
    }

    /// A fix that disagrees is eased in (< 300 ms), never a jump between two frames.
    func testCorrectionIsBlendedNotSnapped() {
        let m = CarMotion(isMe: true)
        for i in 0 ... 3 {
            m.ingest(fix(0, Double(i) * 10, atS: Double(i), speed: 10, course: 0), now: Double(i), wallMs: Double(i) * 1000, reduceMotion: false)
        }
        let before = local(m.pose(4))
        m.ingest(fix(6, 40, atS: 4, speed: 10, course: 0), now: 4, wallMs: 4000, reduceMotion: false)
        var prev = before
        var t = 4.0
        while t < 4.4 {
            t += 1.0 / 60
            let p = local(m.pose(t))
            XCTAssertLessThan((p - prev).length, 0.8, "no frame-to-frame jump at t=\(t)")
            prev = p
        }
        XCTAssertGreaterThan(prev.x, 1.0, "the correction did arrive (filtered, not the raw 6 m)")
        XCTAssertLessThan(MotionTuning.blendS, 0.3)
    }

    /// Parked: no estimate at all.
    func testParkedCarDoesNotMove() {
        let m = CarMotion(isMe: true)
        m.ingest(fix(0, 0, atS: 0, speed: 0), now: 0, wallMs: 0, reduceMotion: false)
        m.ingest(fix(0.5, 0, atS: 1, speed: 0.1), now: 1, wallMs: 1000, reduceMotion: false)
        let p = m.pose(3)!
        XCTAssertFalse(p.moving)
        XCTAssertEqual(p.speedMps, 0)
        XCTAssertFalse(m.pose(5)!.animating)
    }

    /// Stale (not live): never drawn as moving, rests on the last fix.
    func testStaleCarNeverShownMoving() {
        let m = CarMotion(isMe: false)
        m.ingest(fix(0, 0, atS: 0, speed: 12, course: 90), now: 0, wallMs: 0, reduceMotion: false)
        m.ingest(fix(36, 0, atS: 3, speed: 12, course: 90, live: false), now: 3, wallMs: 3000, reduceMotion: false)
        let end = m.pose(3 + MotionTuning.settleS + 0.05)!
        XCTAssertFalse(end.moving)
        XCTAssertEqual(local(end).x, 36, accuracy: 3)
        let later = m.pose(20)!
        XCTAssertEqual(local(later).x, local(end).x, accuracy: 0.01, "no estimate for a stale car")
        XCTAssertFalse(later.animating)
    }

    /// Others (fixes every ~3 s): played back smoothly along their reported path.
    func testOtherMemberGlidesAlongPath() {
        let m = CarMotion(isMe: false)
        for i in 0 ... 4 {
            m.ingest(fix(Double(i) * 36, 0, atS: Double(i) * 3, speed: 12, course: 90), now: Double(i) * 3 + 1.5, wallMs: 0, reduceMotion: false)
        }
        XCTAssertEqual(m.intervalS, 3, accuracy: 0.2)
        var prev = local(m.pose(13.5))
        var t = 13.5
        var maxStep = 0.0
        while t < 16.4 {
            t += 1.0 / 60
            let p = local(m.pose(t))
            maxStep = max(maxStep, (p - prev).length)
            XCTAssertGreaterThanOrEqual(p.x, prev.x - 0.01, "never backwards")
            prev = p
        }
        XCTAssertLessThan(maxStep, 0.5, "≈12 m/s at 60 fps is 0.2 m a frame")
        XCTAssertEqual(prev.x, 144, accuracy: 25)
    }

    /// A gap over 10 s glides in ~1.2 s instead of a teleport (or a 3 s crawl).
    func testLongGapGlidesNotTeleports() {
        let m = CarMotion(isMe: false)
        m.ingest(fix(0, 0, atS: 0, speed: 0), now: 0, wallMs: 0, reduceMotion: false)
        m.ingest(fix(300, 0, atS: 30, speed: 0), now: 30, wallMs: 0, reduceMotion: false)
        let mid = local(m.pose(30.3))
        XCTAssertGreaterThan(mid.x, 1)
        XCTAssertLessThan(mid.x, 299, "not a teleport")
        XCTAssertEqual(local(m.pose(31.3)).x, 300, accuracy: 0.5)
    }

    func testFarJumpIsPlacedAtOnce() {
        let m = CarMotion(isMe: false)
        m.ingest(fix(0, 0, atS: 0), now: 0, wallMs: 0, reduceMotion: false)
        m.ingest(fix(5000, 0, atS: 3), now: 3, wallMs: 0, reduceMotion: false)
        XCTAssertEqual(local(m.pose(3)).x, 5000, accuracy: 1)
    }

    func testReduceMotionPlacesExactly() {
        let m = CarMotion(isMe: true)
        m.ingest(fix(0, 0, atS: 0, speed: 10, course: 0), now: 0, wallMs: 0, reduceMotion: true)
        m.ingest(fix(0, 10, atS: 1, speed: 10, course: 0), now: 1, wallMs: 1000, reduceMotion: true)
        XCTAssertEqual(local(m.pose(1, reduceMotion: true)).y, 10, accuracy: 0.6)
        XCTAssertEqual(local(m.pose(2, reduceMotion: true)).y, local(m.pose(1, reduceMotion: true)).y, accuracy: 0.01)
    }

    /// Approximate (> 60 m): exactly where measured, never animated.
    func testApproximateFixIsNotAnimated() {
        let m = CarMotion(isMe: false)
        m.ingest(fix(0, 0, atS: 0, speed: 10, course: 0), now: 0, wallMs: 0, reduceMotion: false)
        m.ingest(fix(0, 40, atS: 3, speed: 10, course: 0, acc: 90), now: 3, wallMs: 0, reduceMotion: false)
        let p = m.pose(3)!
        XCTAssertEqual(local(p).y, 40, accuracy: 0.01)
        XCTAssertFalse(p.moving)
    }

    /// Heading turns smoothly, never faster than the max turn rate.
    func testHeadingSlerpRespectsMaxTurnRate() {
        let m = CarMotion(isMe: true)
        m.ingest(fix(0, 0, atS: 0, speed: 10, course: 0), now: 0, wallMs: 0, reduceMotion: false)
        _ = m.pose(0)
        m.ingest(fix(10, 0, atS: 1, speed: 10, course: 90), now: 1, wallMs: 1000, reduceMotion: false)
        var last = m.pose(1)!.heading!
        var t = 1.0
        for _ in 0 ..< 30 {
            t += 1.0 / 60
            let h = m.pose(t)!.heading!
            XCTAssertLessThanOrEqual(abs(MotionTuning.signedDiff(last, h)), MotionTuning.maxTurnDegS / 60 + 0.01)
            last = h
        }
        XCTAssertGreaterThan(last, 10, "it does turn")
    }

    func testHeadingTakesTheShortWayRound() {
        XCTAssertEqual(MotionTuning.signedDiff(350, 10), 20, accuracy: 1e-9)
        XCTAssertEqual(MotionTuning.signedDiff(10, 350), -20, accuracy: 1e-9)
        XCTAssertEqual(MotionTuning.norm(-30), 330, accuracy: 1e-9)
    }

    func testConstantTurnRatePathCurves() {
        let p = MotionPath.reckon(p: .zero, t0: 0, speed: 10, heading: 0, omega: 20)
        let e = p.eval(1)
        XCTAssertGreaterThan(e.p.x, 0.5, "turning right (clockwise) bends east")
        XCTAssertEqual(e.p.length, 10, accuracy: 0.3)
        XCTAssertEqual(e.v.bearing, 20, accuracy: 0.5)
    }

    func testKalmanSmoothsNoise() {
        var k = Kalman1D()
        var seed: UInt64 = 7
        var worst = 0.0
        for i in 0 ..< 60 {
            seed = seed &* 6364136223846793005 &+ 1
            let noise = Double((seed >> 33) % 1000) / 1000 * 8 - 4
            if i > 0 { k.predict(1, accelSd: 1) }
            k.updatePosition(Double(i) * 10 + noise, variance: 16)
            if i > 20 { worst = max(worst, abs(k.x - Double(i) * 10)) }
        }
        XCTAssertLessThan(worst, 3.5)
        XCTAssertEqual(k.v, 10, accuracy: 1)
    }
}

final class DustTests: XCTestCase {
    func testGating() {
        func g(_ kmh: Double, paved: Bool = false, rain: Bool = false, on: Bool = true, low: Bool = false, reduce: Bool = false, moving: Bool = true) -> Bool {
            DustGate.emits(speedKmh: kmh, onPavedRoad: paved, raining: rain, enabled: on, lowPower: low, reduceMotion: reduce, moving: moving)
        }
        XCTAssertTrue(g(30))
        XCTAssertFalse(g(10), "below ~12 km/h")
        XCTAssertFalse(g(30, paved: true), "none on asphalt")
        XCTAssertFalse(g(30, rain: true), "none in rain")
        XCTAssertFalse(g(30, on: false))
        XCTAssertFalse(g(30, low: true), "Low Power Mode")
        XCTAssertFalse(g(30, reduce: true), "Reduce Motion")
        XCTAssertFalse(g(30, moving: false), "stale / parked")
        XCTAssertLessThan(DustGate.density(speedKmh: 20), DustGate.density(speedKmh: 50))
        XCTAssertEqual(DustGate.density(speedKmh: 90), 1)
        XCTAssertLessThan(DustGate.rate(speedKmh: 40, driving: true), DustGate.rate(speedKmh: 40, driving: false))
    }

    func testRainFromWeather() {
        var h = WeatherHour(time: Date())
        XCTAssertFalse(DrivingWeather.isRain(h))
        h.precipitationMm = 0.4
        XCTAssertTrue(DrivingWeather.isRain(h))
        h.precipitationMm = 0
        h.weatherCode = 63
        XCTAssertTrue(DrivingWeather.isRain(h))
        h.weatherCode = 3
        XCTAssertFalse(DrivingWeather.isRain(h))
        XCTAssertFalse(DrivingWeather.isRain(nil))
    }

    func testWindIsFromMeteorologicalDirection() {
        let w = DustWind(fromDeg: 315, kmh: 36)!
        XCTAssertEqual(w.towardDeg, 135, accuracy: 1e-9)
        XCTAssertEqual(w.speedMps, 10, accuracy: 1e-9)
        XCTAssertNil(DustWind(fromDeg: nil, kmh: 10))
    }

    /// Puffs drift downwind (a north wind pushes them south).
    func testParticlesDriftWithRealWind() {
        let d = DustSystem(seed: 1)
        d.wind = DustWind(fromDeg: 0, kmh: 36)
        d.emit(car: "a", at: .zero, heading: 90, speedMps: 0.0001 + 15, dt: 0.1, now: 0, driving: false, activeCars: 1)
        XCTAssertFalse(d.isEmpty)
        let y0 = d.particles.map(\.p.y).reduce(0, +) / Double(d.particles.count)
        for i in 1 ... 15 { d.step(dt: 0.1, now: Double(i) * 0.1) }
        let y1 = d.particles.map(\.p.y).reduce(0, +) / Double(d.particles.count)
        XCTAssertLessThan(y1, y0 - 3, "drifted south")
    }

    func testParticleLifecycleFadesIn2to4s() {
        let d = DustSystem(seed: 3)
        d.emit(car: "a", at: .zero, heading: 0, speedMps: 20, dt: 0.1, now: 0, driving: false, activeCars: 1)
        let p = d.particles[0]
        XCTAssertGreaterThanOrEqual(p.life, DustSystem.minLife)
        XCTAssertLessThanOrEqual(p.life, DustSystem.maxLife)
        XCTAssertEqual(p.opacity(0), 0, accuracy: 1e-9, "fades in")
        XCTAssertGreaterThan(p.opacity(p.life * 0.2), 0.05)
        XCTAssertLessThan(p.opacity(p.life * 0.9), p.opacity(p.life * 0.3))
        XCTAssertGreaterThan(p.radius(p.life * 0.9), p.radius(0) * 2, "expands")
        d.step(dt: 0.1, now: 4.1)
        XCTAssertTrue(d.isEmpty, "gone after its life")
    }

    func testParticleCapAcrossConvoy() {
        let d = DustSystem(seed: 5)
        for f in 0 ..< 600 {
            for c in 0 ..< 6 {
                d.emit(car: "c\(c)", at: MotionVec(x: Double(c) * 50, y: 0), heading: 0, speedMps: 25, dt: 1.0 / 60, now: Double(f) / 60, driving: false, activeCars: 6)
            }
            d.step(dt: 1.0 / 60, now: Double(f) / 60)
            XCTAssertLessThanOrEqual(d.particles.count, DustSystem.maxParticles)
        }
        /* Fair share: every car still has a plume. */
        for c in 0 ..< 6 { XCTAssertGreaterThan(d.particles.filter { $0.car == "c\(c)" }.count, 5) }
    }

    func testDensityScalesWithSpeed() {
        let slow = DustSystem(seed: 9), fast = DustSystem(seed: 9)
        for f in 0 ..< 60 {
            slow.emit(car: "a", at: .zero, heading: 0, speedMps: 15 / 3.6, dt: 1.0 / 60, now: Double(f) / 60, driving: false, activeCars: 1)
            fast.emit(car: "a", at: .zero, heading: 0, speedMps: 60 / 3.6, dt: 1.0 / 60, now: Double(f) / 60, driving: false, activeCars: 1)
        }
        XCTAssertGreaterThan(fast.particles.count, slow.particles.count * 2)
    }
}

final class TyreTrackTests: XCTestCase {
    func testRutsOnlyOnSandAndFadeWithDistance() {
        let r = TyreTracks.Ruts()
        for i in 0 ..< 100 { r.add(MotionVec(x: 0, y: Double(i) * 3), heading: 0, at: Double(i), sand: i >= 20, moving: true) }
        let pieces = TyreTracks.pieces(r.samples, now: 100)
        XCTAssertFalse(pieces.isEmpty)
        /* Nothing from the paved stretch (y < 60 m). */
        XCTAssertTrue(pieces.allSatisfy { $0.points.allSatisfy { $0.y >= 57 } })
        XCTAssertGreaterThan(pieces.last!.opacity, pieces.first!.opacity, "fainter further back")
        XCTAssertLessThanOrEqual(pieces.last!.opacity, TyreTracks.baseOpacity)
    }

    func testRutsCappedByLengthAndAge() {
        let r = TyreTracks.Ruts()
        for i in 0 ..< 400 { r.add(MotionVec(x: 0, y: Double(i) * 3), heading: 0, at: Double(i) * 0.3, sand: true, moving: true) }
        let s = r.samples
        XCTAssertLessThanOrEqual(abs(s.last!.p.y - s.first!.p.y), TyreTracks.maxLengthM + 3)
        r.prune(400 * 0.3 + TyreTracks.maxAgeS + 1)
        XCTAssertTrue(r.isEmpty, "gone after a few minutes")
    }

    func testParkedCarAddsNothingAndJumpsBreakRuts() {
        let r = TyreTracks.Ruts()
        r.add(.zero, heading: 0, at: 0, sand: true, moving: true)
        XCTAssertFalse(r.add(MotionVec(x: 0, y: 5), heading: 0, at: 1, sand: true, moving: false))
        r.add(MotionVec(x: 0, y: 3), heading: 0, at: 1, sand: true, moving: true)
        r.add(MotionVec(x: 0, y: 500), heading: 0, at: 2, sand: true, moving: true)
        XCTAssertEqual(r.samples.count, 1, "a snap is not a track")
    }

    func testRutOffsetFollowsDrawnCarScale() {
        let e = TyreTracks.zoomExpression(metres: TyreTracks.halfTrackM, min: 0)
        /* ["interpolate", ["linear"], ["zoom"], 12, px, 13, px, …] */
        let px12 = e[4] as! Double, px22 = e[e.count - 1] as! Double
        XCTAssertGreaterThan(px12, 2, "beside the enlarged car when zoomed out")
        XCTAssertEqual(px22, 0.8 / (78_271.517 * cos(25 * Double.pi / 180) / pow(2, 22)), accuracy: 0.1, "true size once zoomed in")
    }
}

final class BodyDynamicsTests: XCTestCase {
    func testLevelOnFlatNoseUpClimbingNoseDownDescending() {
        let flat = BodyDynamics.tilt(front: 100, back: 100, left: 100, right: 100)
        XCTAssertEqual(flat.pitch, 0)
        XCTAssertEqual(flat.roll, 0)
        let climb = BodyDynamics.tilt(front: 101.2, back: 100, left: 100, right: 100)
        XCTAssertGreaterThan(climb.pitch, 6)
        let descend = BodyDynamics.tilt(front: 100, back: 101.2, left: 100, right: 100)
        XCTAssertLessThan(descend.pitch, -6)
        XCTAssertEqual(BodyDynamics.gradePercent(front: 101.2, back: 100), 12, accuracy: 1e-9)
    }

    func testTiltIsClamped() {
        let steep = BodyDynamics.tilt(front: 200, back: 100, left: 150, right: 100)
        XCTAssertEqual(steep.pitch, BodyDynamics.maxPitchDeg)
        XCTAssertEqual(steep.roll, BodyDynamics.maxRollDeg)
    }

    func testModelRotationKeepsHeadingAndAddsPitch() {
        let r = BodyDynamics.modelRotation(heading: 90, pitch: 5, roll: -2)
        XCTAssertEqual(r[2], Vehicle.rotation(90)[2])
        XCTAssertEqual(r[0], 5 * BodyDynamics.pitchSign)
        XCTAssertEqual(r[1], -2 * BodyDynamics.rollSign)
    }

    func testBobOnlyOffRoadAndProportionalToSpeed() {
        XCTAssertEqual(BodyDynamics.bob(t: 1.3, speedKmh: 40, offRoad: false, seed: 1).pitch, 0)
        XCTAssertEqual(BodyDynamics.bob(t: 1.3, speedKmh: 0, offRoad: true, seed: 1).pitch, 0)
        var slow = 0.0, fast = 0.0
        for i in 0 ..< 200 {
            let t = Double(i) / 60
            slow = max(slow, abs(BodyDynamics.bob(t: t, speedKmh: 10, offRoad: true, seed: 1).pitch))
            fast = max(fast, abs(BodyDynamics.bob(t: t, speedKmh: 50, offRoad: true, seed: 1).pitch))
        }
        XCTAssertGreaterThan(fast, slow * 2)
        XCTAssertLessThanOrEqual(fast, BodyDynamics.bobDeg + 1e-9, "very subtle")
    }

    func testGradeChipWithHysteresis() {
        XCTAssertEqual(BodyDynamics.gradeChip(grade: 12, shown: false, speedKmh: 20, driving: false), "▲ صعود ١٢٪")
        XCTAssertEqual(BodyDynamics.gradeChip(grade: -8.4, shown: false, speedKmh: 20, driving: false), "▼ نزول ٨٪")
        XCTAssertNil(BodyDynamics.gradeChip(grade: 7, shown: false, speedKmh: 20, driving: false))
        XCTAssertNotNil(BodyDynamics.gradeChip(grade: 7, shown: true, speedKmh: 20, driving: false), "stays until under 6 %")
        XCTAssertNil(BodyDynamics.gradeChip(grade: 15, shown: false, speedKmh: 80, driving: true), "hidden driving fast")
        XCTAssertNil(BodyDynamics.gradeChip(grade: nil, shown: true, speedKmh: 0, driving: false), "no DEM, no claim")
    }

    func testSunShadowFallsAwayFromSun() {
        /* Sun in the south (180°): the shadow falls north. */
        let s = CarLights.shadow(elevationDeg: 40, azimuthDeg: 180)!
        XCTAssertGreaterThan(s.offset.y, 0.3)
        XCTAssertNil(CarLights.shadow(elevationDeg: -5, azimuthDeg: 180), "no sun shadow at night")
        XCTAssertTrue(CarLights.lightsOn(elevationDeg: -10, forcedNight: false))
        XCTAssertFalse(CarLights.lightsOn(elevationDeg: 20, forcedNight: false))
        XCTAssertTrue(CarLights.lightsOn(elevationDeg: 20, forcedNight: true))
    }

    func testSunAzimuthIsPlausible() {
        /* Riyadh, 09:00 local (06:00 UTC) on the March equinox. */
        var c = DateComponents()
        c.year = 2026; c.month = 3; c.day = 20; c.hour = 6; c.minute = 0
        c.timeZone = TimeZone(identifier: "UTC")
        let morning = Calendar(identifier: .gregorian).date(from: c)!
        XCTAssertEqual(CarLights.sunAzimuthDeg(morning, lat: 24.7, lng: 46.7), 110, accuracy: 10, "east-south-east at 09:00 local on the equinox")
    }
}

final class OffroadTrackStyleTests: XCTestCase {
    func testStreetsV8Groups() {
        XCTAssertEqual(OffroadTracks.group(class: "track", type: "track:grade1", surface: "unpaved"), "grade1")
        XCTAssertEqual(OffroadTracks.group(class: "track", type: "track:grade5", surface: nil), "grade5")
        XCTAssertEqual(OffroadTracks.group(class: "track", type: "track", surface: nil), "track")
        XCTAssertEqual(OffroadTracks.group(class: "path", type: "path", surface: nil), "path")
        XCTAssertNil(OffroadTracks.group(class: "path", type: "footway", surface: nil))
        XCTAssertEqual(OffroadTracks.group(class: "street", type: "unclassified", surface: "unpaved"), "unpaved")
        XCTAssertNil(OffroadTracks.group(class: "street", type: "residential", surface: "paved"))
        XCTAssertNil(OffroadTracks.group(class: "primary", type: "primary", surface: "paved"))
    }

    func testFinerDashesForSofterGrades() {
        let g = Dictionary(uniqueKeysWithValues: OffroadTracks.grades.map { ($0.id, $0.dash) })
        XCTAssertNil(g["grade1"]!, "grade1 solid")
        XCTAssertGreaterThan(g["grade2"]!!.first!, g["grade4"]!!.first!)
        XCTAssertGreaterThan(g["grade4"]!!.first!, g["grade5"]!!.first!)
    }

    func testVisibility() {
        XCTAssertTrue(OffroadTracks.visible(pref: true, exploring: true, offRoad: false))
        XCTAssertTrue(OffroadTracks.visible(pref: true, exploring: false, offRoad: true))
        XCTAssertFalse(OffroadTracks.visible(pref: true, exploring: false, offRoad: false))
        XCTAssertFalse(OffroadTracks.visible(pref: false, exploring: true, offRoad: true))
        XCTAssertEqual(OffroadTracks.attribution, "© OpenStreetMap contributors")
    }

    func testPrefsDefaultOnAndMasterSwitch() {
        let d = UserDefaults(suiteName: "realism-test-\(UUID().uuidString)")!
        XCTAssertEqual(DrivingRealismPrefs.snapshot(d), DrivingRealismPrefs.Snapshot())
        d.set(false, forKey: DrivingRealismPrefs.onKey)
        let s = DrivingRealismPrefs.snapshot(d)
        XCTAssertFalse(s.dust || s.tracks || s.lights || s.tilt)
        XCTAssertTrue(s.osmTracks, "the OSM layer is its own toggle")
    }
}
