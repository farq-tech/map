import XCTest
@testable import SaryAlbarq

/// «تتبعني» / «باتجاهي»: the mode state machine, «رجّعني للتوجيه» and its timer, the heading
/// source (course vs compass, with hysteresis), the speed → zoom curve and the frame smoother.
final class FollowCameraTests: XCTestCase {
    private let prefs = FollowCameraPrefs.Snapshot()

    // MARK: modes

    func testButtonCyclesFreeNorthHeadingFree() {
        var s = FollowCameraState()
        XCTAssertEqual(s.mode, .free)
        s.cycle(); XCTAssertEqual(s.mode, .north)
        s.cycle(); XCTAssertEqual(s.mode, .heading)
        s.cycle(); XCTAssertEqual(s.mode, .free)
        XCTAssertFalse(s.recenterOffered)
    }

    func testLabelsAndIconsAreArabicAndStandard() {
        XCTAssertEqual(MapFollowMode.north.label, "تتبعني")
        XCTAssertEqual(MapFollowMode.heading.label, "باتجاهي")
        XCTAssertEqual(MapFollowMode.heading.systemImage, "location.north.line.fill")
        XCTAssertEqual(MapFollowMode.north.systemImage, "location.fill")
        XCTAssertEqual(MapFollowMode.free.systemImage, "location")
    }

    func testGuidanceStartEntersHeading() {
        var s = FollowCameraState()
        s.guidanceStarted()
        XCTAssertEqual(s.mode, .heading)
        XCTAssertTrue(s.auto)
        XCTAssertFalse(s.recenterOffered)
    }

    func testPanFromHeadingDropsToFreeAndOffersRecenter() {
        var s = FollowCameraState()
        s.guidanceStarted()
        s.userMovedMap(at: 100)
        XCTAssertEqual(s.mode, .free)
        XCTAssertTrue(s.recenterOffered)
        s.recenter()
        XCTAssertEqual(s.mode, .heading)
        XCTAssertFalse(s.recenterOffered)
    }

    func testPanFromNorthDropsWithoutPill() {
        var s = FollowCameraState()
        s.cycle()
        s.userMovedMap(at: 5)
        XCTAssertEqual(s.mode, .free)
        XCTAssertFalse(s.recenterOffered)
    }

    func testPanWhileFreeChangesNothing() {
        var s = FollowCameraState()
        s.userMovedMap(at: 5)
        XCTAssertEqual(s.mode, .free)
        XCTAssertFalse(s.recenterOffered)
    }

    func testOverviewKeepsThePillAndGuidanceEndClearsIt() {
        var s = FollowCameraState()
        s.guidanceStarted()
        s.release(offerBack: true, at: 1)
        XCTAssertEqual(s.mode, .free)
        XCTAssertTrue(s.recenterOffered)
        s.guidanceEnded()
        XCTAssertFalse(s.recenterOffered)
    }

    func testPlainReleaseClearsThePill() {
        var s = FollowCameraState()
        s.guidanceStarted()
        s.userMovedMap(at: 1)
        s.release()
        XCTAssertFalse(s.recenterOffered)
    }

    func testButtonAfterPanClearsThePill() {
        var s = FollowCameraState()
        s.guidanceStarted()
        s.userMovedMap(at: 1)
        s.cycle()
        XCTAssertEqual(s.mode, .north)
        XCTAssertFalse(s.recenterOffered)
    }

    // MARK: auto-recenter

    func testAutoRecenterAfterTenSecondsMoving() {
        var s = FollowCameraState()
        s.guidanceStarted()
        s.userMovedMap(at: 100)
        XCTAssertFalse(s.shouldAutoRecenter(now: 105, speedKmh: 40, prefs: prefs), "too soon")
        XCTAssertFalse(s.shouldAutoRecenter(now: 109.9, speedKmh: 40, prefs: prefs))
        XCTAssertTrue(s.shouldAutoRecenter(now: 110, speedKmh: 40, prefs: prefs))
    }

    func testNoAutoRecenterWhenSlowOrStopped() {
        var s = FollowCameraState()
        s.guidanceStarted()
        s.userMovedMap(at: 0)
        XCTAssertFalse(s.shouldAutoRecenter(now: 60, speedKmh: 10, prefs: prefs), "10 km/h is not more than 10")
        XCTAssertFalse(s.shouldAutoRecenter(now: 60, speedKmh: 0, prefs: prefs))
        XCTAssertFalse(s.shouldAutoRecenter(now: 60, speedKmh: nil, prefs: prefs))
        XCTAssertTrue(s.shouldAutoRecenter(now: 60, speedKmh: 11, prefs: prefs))
    }

    func testTouchRestartsTheClockAndBlocksWhileDown() {
        var s = FollowCameraState()
        s.guidanceStarted()
        s.userMovedMap(at: 0)
        s.touch(down: true, at: 8)
        XCTAssertFalse(s.shouldAutoRecenter(now: 30, speedKmh: 50, prefs: prefs), "finger still down")
        s.touch(down: false, at: 31)
        XCTAssertFalse(s.shouldAutoRecenter(now: 40, speedKmh: 50, prefs: prefs))
        XCTAssertTrue(s.shouldAutoRecenter(now: 41, speedKmh: 50, prefs: prefs))
    }

    func testAutoRecenterOffInSettingsAndConfigurableDelay() {
        var s = FollowCameraState()
        s.guidanceStarted()
        s.userMovedMap(at: 0)
        var p = prefs
        p.autoRecenter = false
        XCTAssertFalse(s.shouldAutoRecenter(now: 999, speedKmh: 80, prefs: p))
        p.autoRecenter = true
        p.afterS = 20
        XCTAssertFalse(s.shouldAutoRecenter(now: 15, speedKmh: 80, prefs: p))
        XCTAssertTrue(s.shouldAutoRecenter(now: 20, speedKmh: 80, prefs: p))
    }

    func testNoAutoRecenterWithoutThePill() {
        var s = FollowCameraState()
        s.cycle()
        s.userMovedMap(at: 0)
        XCTAssertFalse(s.shouldAutoRecenter(now: 100, speedKmh: 80, prefs: prefs))
    }

    @MainActor
    func testPrefsPersist() {
        let d = UserDefaults(suiteName: "follow-cam-\(UUID().uuidString)")!
        XCTAssertTrue(FollowCameraPrefs.snapshot(d).autoRecenter, "on by default")
        XCTAssertEqual(FollowCameraPrefs.snapshot(d).afterS, 10)
        FollowCameraPrefs.setAuto(false, d)
        FollowCameraPrefs.setAfter(15, d)
        XCTAssertFalse(FollowCameraPrefs.snapshot(d).autoRecenter)
        XCTAssertEqual(FollowCameraPrefs.snapshot(d).afterS, 15)
        let keys = LocalAccountData.keys
        XCTAssertTrue(keys.contains(FollowCameraPrefs.autoKey))
    }

    // MARK: heading source

    func testCourseWhenMovingCompassWhenStopped() {
        var h = FollowHeadingSource()
        XCTAssertEqual(h.update(speedKmh: 30, course: 90, compass: 200, compassError: 5), 90)
        XCTAssertEqual(h.source, .course)
        /* Stopped: the compass (the course of a parked car means nothing). */
        XCTAssertEqual(h.update(speedKmh: 0, course: 90, compass: 200, compassError: 5), 200)
        XCTAssertEqual(h.source, .compass)
    }

    func testSpeedHysteresisAroundTheThreshold() {
        var h = FollowHeadingSource()
        h.update(speedKmh: 5, course: 10, compass: 100, compassError: 5)
        XCTAssertFalse(h.usingCourse, "5 km/h: not yet")
        h.update(speedKmh: 6.5, course: 10, compass: 100, compassError: 5)
        XCTAssertTrue(h.usingCourse)
        /* Wobbling between 4 and 6 km/h keeps the course: no flip-flop. */
        for v in [4.2, 5.8, 4.0, 5.0] {
            h.update(speedKmh: v, course: 10, compass: 100, compassError: 5)
            XCTAssertTrue(h.usingCourse, "\(v)")
        }
        h.update(speedKmh: 3, course: 10, compass: 100, compassError: 5)
        XCTAssertFalse(h.usingCourse)
    }

    func testCompassDeadbandStopsSpinning() {
        var h = FollowHeadingSource()
        XCTAssertEqual(h.update(speedKmh: 0, course: nil, compass: 40, compassError: 10), 40)
        XCTAssertEqual(h.update(speedKmh: 0, course: nil, compass: 47, compassError: 10), 40, "7° jitter ignored")
        XCTAssertEqual(h.update(speedKmh: 0, course: nil, compass: 33, compassError: 10), 40)
        XCTAssertEqual(h.update(speedKmh: 0, course: nil, compass: 60, compassError: 10), 60, "a real turn")
        /* Across north too. */
        var n = FollowHeadingSource()
        n.update(speedKmh: 0, course: nil, compass: 355, compassError: 10)
        XCTAssertEqual(n.update(speedKmh: 0, course: nil, compass: 4, compassError: 10), 355)
    }

    func testBadCompassHoldsTheLastDirection() {
        var h = FollowHeadingSource()
        h.update(speedKmh: 40, course: 120, compass: nil, compassError: nil)
        XCTAssertEqual(h.update(speedKmh: 0, course: nil, compass: 300, compassError: 90), 120, "inaccurate compass ignored")
        XCTAssertEqual(h.update(speedKmh: 0, course: nil, compass: 300, compassError: -1), 120, "invalid compass ignored")
        XCTAssertEqual(h.source, .held)
        XCTAssertNil(FollowHeadingSource().bearing)
    }

    // MARK: zoom, placement

    func testSpeedZoomCurve() {
        XCTAssertEqual(FollowZoom.zoom(kmh: 0), 17.4, accuracy: 0.001)
        XCTAssertEqual(FollowZoom.zoom(kmh: nil), 17.4, accuracy: 0.001)
        XCTAssertEqual(FollowZoom.zoom(kmh: 130), 14.8, accuracy: 0.001)
        XCTAssertEqual(FollowZoom.zoom(kmh: 200), 14.8, accuracy: 0.001)
        XCTAssertEqual(FollowZoom.zoom(kmh: 55), 16.2, accuracy: 0.001)
        /* Monotonic: faster never zooms in. */
        var last = Double.infinity
        for v in stride(from: 0.0, through: 160, by: 2.5) {
            let z = FollowZoom.zoom(kmh: v)
            XCTAssertLessThanOrEqual(z, last + 1e-9, "\(v)")
            last = z
        }
    }

    func testCarSitsInTheLowerPartOfTheClearArea() {
        let h = 874.0, top = 150.0, bottom = 250.0
        let p = FollowZoom.padding(clearTop: top, clearBottom: bottom, height: h, share: FollowZoom.carScreenShare)
        let centerY = (p.top + h - p.bottom) / 2
        let share = (centerY - top) / (h - top - bottom)
        XCTAssertEqual(share, FollowZoom.carScreenShare, accuracy: 0.001)
        XCTAssertGreaterThan(share, 0.66, "lower third: the road ahead shows")
        let mid = FollowZoom.padding(clearTop: top, clearBottom: bottom, height: h, share: 0.5)
        XCTAssertEqual((mid.top + h - mid.bottom) / 2, top + (h - top - bottom) / 2, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(mid.top, 0)
        XCTAssertGreaterThanOrEqual(mid.bottom, 0)
    }

    // MARK: smoothing

    func testBearingTakesTheShortWayAndIsRateLimited() {
        XCTAssertEqual(FollowMath.delta(350, 10), 20, accuracy: 1e-9)
        XCTAssertEqual(FollowMath.delta(10, 350), -20, accuracy: 1e-9)
        let b = FollowMath.approachBearing(0, 180, dt: 1.0 / 60, tau: 0.45, maxRate: 75)
        XCTAssertLessThanOrEqual(abs(FollowMath.delta(0, b)), 75.0 / 60 + 1e-9)
    }

    func testSmootherEntersEasedThenTracksTheCarWithoutLag() {
        var s = FollowCameraSmoother()
        let from = FollowCameraPose(center: LngLat(lng: 46.60, lat: 24.70), zoom: 12, bearing: 0, pitch: 0, topPadding: 0, bottomPadding: 0)
        s.enter(.heading, from: from, at: 0)
        let car = LngLat(lng: 46.67, lat: 24.71)
        let target = FollowCameraPose(center: car, zoom: 16.5, bearing: 30, pitch: 58, topPadding: 300, bottomPadding: 0)
        let first = s.step(target: target, at: 1.0 / 60)
        XCTAssertTrue(first.settling)
        XCTAssertLessThan(abs(first.pose.center.lng - from.center.lng), 0.01, "no jump on entry")
        var t = 1.0 / 60
        var out = first
        while t < 12 { t += 1.0 / 60; out = s.step(target: target, at: t) }
        XCTAssertFalse(s.entering)
        XCTAssertEqual(out.pose.center, car, "after entry the camera sits on the car itself")
        XCTAssertEqual(out.pose.zoom, 16.5, accuracy: 0.02)
        XCTAssertEqual(out.pose.pitch, 58, accuracy: 0.1)
        XCTAssertEqual(out.pose.bearing, 30, accuracy: 0.3)
        /* The car moves on: the centre follows exactly the same frame. */
        let car2 = LngLat(lng: 46.6705, lat: 24.7104)
        var t2 = target; t2.center = car2
        XCTAssertEqual(s.step(target: t2, at: t + 1.0 / 60).pose.center, car2)
    }

    func testSmootherNeverJitters() {
        /* A noisy course (±4°) around 90° moves the shown bearing much less than the noise. */
        var s = FollowCameraSmoother()
        let p = FollowCameraPose(center: LngLat(lng: 46.6, lat: 24.7), zoom: 16, bearing: 90, pitch: 58, topPadding: 300, bottomPadding: 0)
        s.enter(.heading, from: p, at: 0)
        var t = 0.0
        var shown: [Double] = []
        for i in 0..<600 {
            t += 1.0 / 60
            var q = p
            q.bearing = 90 + (i % 2 == 0 ? 4 : -4)
            shown.append(s.step(target: q, at: t).pose.bearing)
        }
        let tail = shown.suffix(300)
        XCTAssertLessThan((tail.max() ?? 0) - (tail.min() ?? 0), 6)
        for (a, b) in zip(tail, tail.dropFirst()) { XCTAssertLessThan(abs(FollowMath.delta(a, b)), 75.0 / 60 + 1e-6) }
    }

    func testReduceMotionJumpsStraightThere() {
        var s = FollowCameraSmoother()
        let from = FollowCameraPose(center: LngLat(lng: 46, lat: 24), zoom: 10, bearing: 0, pitch: 0, topPadding: 0, bottomPadding: 0)
        s.enter(.north, from: from, at: 0)
        let target = FollowCameraPose(center: LngLat(lng: 46.5, lat: 24.5), zoom: 16, bearing: 0, pitch: 0, topPadding: 10, bottomPadding: 0)
        XCTAssertEqual(s.step(target: target, at: 0.016, reduceMotion: true).pose, target)
    }
}

/// Build 36 (owner's report item 6): «رجّعني للتوجيه» came up again and again during guidance.
/// A touch that left the camera where it was gives following straight back, without the pill.
final class FollowCameraGestureTests: XCTestCase {
    func testATouchThatMovedNothingKeepsFollowingWithoutThePill() {
        var s = FollowCameraState()
        s.guidanceStarted()
        s.userMovedMap(at: 10)
        XCTAssertEqual(s.mode, .free, "the camera stops fighting the finger at once")
        XCTAssertTrue(s.recenterOffered)
        s.gestureEnded(negligible: true)
        XCTAssertEqual(s.mode, .heading, "a drifting tap is not a decision to look elsewhere")
        XCTAssertFalse(s.recenterOffered, "no «رجّعني للتوجيه»")
    }

    func testARealPanKeepsTheMapAndThePill() {
        var s = FollowCameraState()
        s.guidanceStarted()
        s.userMovedMap(at: 10)
        s.gestureEnded(negligible: false)
        XCTAssertEqual(s.mode, .free)
        XCTAssertTrue(s.recenterOffered)
        /* A later negligible touch on the free map brings nothing back by itself. */
        s.userMovedMap(at: 20)
        s.gestureEnded(negligible: true)
        XCTAssertEqual(s.mode, .free)
        XCTAssertTrue(s.recenterOffered)
    }

    func testNorthUpComesBackTooAndOverviewIsNotUndone() {
        var s = FollowCameraState()
        s.cycle()
        s.userMovedMap(at: 1)
        s.gestureEnded(negligible: true)
        XCTAssertEqual(s.mode, .north)
        var o = FollowCameraState()
        o.guidanceStarted()
        o.release(offerBack: true, at: 1)
        o.userMovedMap(at: 2)
        o.gestureEnded(negligible: true)
        XCTAssertEqual(o.mode, .free, "«نظرة عامة» chosen on purpose stays")
        XCTAssertTrue(o.recenterOffered)
    }

    func testAButtonDuringTheGestureWins() {
        var s = FollowCameraState()
        s.guidanceStarted()
        s.userMovedMap(at: 1)
        s.recenter()
        s.release()
        s.gestureEnded(negligible: true)
        XCTAssertEqual(s.mode, .free, "the camera taken for a member after the touch: not undone")
    }

    func testNegligibleThresholds() {
        XCTAssertTrue(FollowCameraState.negligibleGesture(shiftPt: 8, zoomDelta: 0.02, bearingDelta: 1, pitchDelta: 0))
        XCTAssertFalse(FollowCameraState.negligibleGesture(shiftPt: 60, zoomDelta: 0, bearingDelta: 0, pitchDelta: 0), "a pan")
        XCTAssertFalse(FollowCameraState.negligibleGesture(shiftPt: 2, zoomDelta: 0.5, bearingDelta: 0, pitchDelta: 0), "a pinch")
        XCTAssertFalse(FollowCameraState.negligibleGesture(shiftPt: 2, zoomDelta: 0, bearingDelta: -20, pitchDelta: 0), "a rotation")
        XCTAssertFalse(FollowCameraState.negligibleGesture(shiftPt: 2, zoomDelta: 0, bearingDelta: 0, pitchDelta: 12), "a tilt")
    }
}
