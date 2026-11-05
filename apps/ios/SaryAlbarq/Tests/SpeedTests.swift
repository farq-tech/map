import XCTest
@testable import SaryAlbarq

/// «سرعة المركبة»: conversion, formatting, smoothing, staleness, the alert's
/// rate limit, the trip's max / average, and friends' speed only when fresh.
final class SpeedTests: XCTestCase {
    private let t0 = 1_800_000_000_000.0

    private func fix(_ s: Double?, at sec: Double, acc: Double? = 5, speedAcc: Double? = 0.5, lat: Double = 24.7, lng: Double = 46.7) -> DeviceFix {
        DeviceFix(lat: lat, lng: lng, accuracy: acc, heading: nil, speed: s, atMs: t0 + sec * 1000, speedAccuracy: speedAcc)
    }

    private func ms(_ sec: Double) -> Double { t0 + sec * 1000 }

    // MARK: units + format

    func testUnitConversion() {
        XCTAssertEqual(Speed.kmh(10), 36, accuracy: 1e-9)
        XCTAssertEqual(Speed.kmh(33.3333333), 120, accuracy: 1e-5)
        XCTAssertEqual(Speed.mps(90), 25, accuracy: 1e-9)
        XCTAssertEqual(Speed.kmh(Speed.mps(77)), 77, accuracy: 1e-9)
    }

    func testFormatting() {
        XCTAssertEqual(SaryFormat.speedUnit, "كم/س")
        XCTAssertEqual(SaryFormat.speedValue(kmh: 87.4), "٨٧")
        XCTAssertEqual(SaryFormat.speedValue(kmh: 87.5), "٨٨")
        XCTAssertEqual(SaryFormat.speedValue(kmh: 0), "٠")
        XCTAssertEqual(SaryFormat.speedValue(kmh: 120), "١٢٠")
        XCTAssertEqual(SaryFormat.speedValue(kmh: nil), "—")
        XCTAssertEqual(SaryFormat.speedValue(kmh: -1), "—")
        XCTAssertEqual(SaryFormat.speedValue(kmh: .nan), "—")
        XCTAssertEqual(SaryFormat.speed(kmh: 64), "٦٤ كم/س")
        XCTAssertEqual(SaryFormat.speed(kmh: nil), "—")
        XCTAssertEqual(SaryFormat.friendSpeed(kmh: 1.2), "واقف")
        XCTAssertEqual(SaryFormat.friendSpeed(kmh: 45), "٤٥ كم/س")
    }

    // MARK: validity

    func testInvalidSpeedsAreRejected() {
        XCTAssertTrue(Speed.isValid(fix(10, at: 0)))
        XCTAssertFalse(Speed.isValid(fix(nil, at: 0)), "CoreLocation's -1 (mapped to nil) is unknown")
        XCTAssertFalse(Speed.isValid(fix(-1, at: 0)))
        XCTAssertFalse(Speed.isValid(fix(.infinity, at: 0)))
        XCTAssertFalse(Speed.isValid(fix(10, at: 0, acc: nil)), "no position accuracy: not trusted")
        XCTAssertFalse(Speed.isValid(fix(10, at: 0, acc: 120)), "a coarse fix")
        XCTAssertFalse(Speed.isValid(fix(10, at: 0, speedAcc: 9)), "CoreLocation's own speed error too large")
        XCTAssertTrue(Speed.isValid(fix(10, at: 0, speedAcc: nil)), "speed accuracy unknown (older devices) but position good")
        XCTAssertFalse(Speed.isValid(fix(Policy.maxPlausibleMps + 1, at: 0)), "faster than any car here: a glitch")
    }

    // MARK: smoothing + staleness

    func testSmoothingAveragesTheLastFewSeconds() {
        var s = SpeedSmoother()
        s.add(fix(20, at: 0))
        s.add(fix(22, at: 1))
        s.add(fix(24, at: 2))
        XCTAssertEqual(s.reading(nowMs: ms(2)).kmh!, Speed.kmh(22), accuracy: 1e-9)
        /* A one-off spike is damped, not shown raw. */
        s.add(fix(40, at: 3))
        let v = s.reading(nowMs: ms(3)).kmh!
        XCTAssertLessThan(v, Speed.kmh(40) - 15)
        /* Old samples leave the 4 s window. */
        s.add(fix(30, at: 8))
        XCTAssertEqual(s.reading(nowMs: ms(8)).kmh!, Speed.kmh(30), accuracy: 1e-9)
    }

    func testStaleFixReadsDashNeverTheOldSpeed() {
        var s = SpeedSmoother()
        s.add(fix(25, at: 0))
        XCTAssertNotNil(s.reading(nowMs: ms(4.9)).kmh)
        XCTAssertEqual(s.reading(nowMs: ms(5.1)), .unknown, "older than ~5 s is not a current speed")
        XCTAssertEqual(s.reading(nowMs: ms(-10)), .unknown, "a fix from the future (clock change) is not trusted")
        XCTAssertEqual(SpeedSmoother().reading(nowMs: ms(0)), .unknown, "no fix yet")
    }

    func testInvalidLatestFixReadsDashAndRestartsTheWindow() {
        var s = SpeedSmoother()
        s.add(fix(30, at: 0))
        s.add(fix(30, at: 1))
        s.add(fix(nil, at: 2))
        XCTAssertEqual(s.reading(nowMs: ms(2)), .unknown)
        s.add(fix(10, at: 3, acc: 200))
        XCTAssertEqual(s.reading(nowMs: ms(3)), .unknown, "coarse fix")
        s.add(fix(5, at: 4))
        XCTAssertEqual(s.reading(nowMs: ms(4)).kmh!, Speed.kmh(5), accuracy: 1e-9, "the old 30 m/s is not averaged in after a bad fix")
    }

    func testOutOfOrderFixesAreIgnoredAndParkedReadsZero() {
        var s = SpeedSmoother()
        s.add(fix(0.4, at: 5))
        s.add(fix(30, at: 4))
        XCTAssertEqual(s.reading(nowMs: ms(5)), .kmh(0), "jitter while parked reads 0")
    }

    @MainActor
    func testModelGoesDashByItselfWhenFixesStop() {
        let m = SpeedModel()
        let start = Date(timeIntervalSince1970: t0 / 1000)
        m.ingest(fix(20, at: 0), now: start)
        XCTAssertEqual(m.snapshot.kmh, 72)
        m.refresh(now: start.addingTimeInterval(6))
        XCTAssertEqual(m.current, .unknown)
        XCTAssertNil(m.snapshot.kmh)
    }

    // MARK: alert

    func testAlertNeedsAFewSecondsOverTheLimit() {
        var g = SpeedAlertGate(thresholdKmh: 120)
        XCTAssertFalse(g.update(.kmh(125), nowMs: ms(0)))
        XCTAssertFalse(g.update(.kmh(126), nowMs: ms(2)))
        XCTAssertTrue(g.update(.kmh(127), nowMs: ms(3)))
        /* One brief spike over the limit never nudges. */
        var h = SpeedAlertGate(thresholdKmh: 120)
        XCTAssertFalse(h.update(.kmh(130), nowMs: ms(0)))
        XCTAssertFalse(h.update(.kmh(110), nowMs: ms(1)))
        XCTAssertFalse(h.update(.kmh(130), nowMs: ms(2)))
        XCTAssertFalse(h.update(.kmh(130), nowMs: ms(4)))
        XCTAssertFalse(h.update(.unknown, nowMs: ms(4.5)), "«—» resets the run")
        XCTAssertFalse(h.update(.kmh(130), nowMs: ms(5)))
    }

    func testAlertIsRateLimited() {
        var g = SpeedAlertGate(thresholdKmh: 120)
        var fired = 0
        /* Five minutes over the limit: one nudge, not a stream. */
        for sec in stride(from: 0.0, through: 300, by: 1) where g.update(.kmh(130), nowMs: ms(sec)) { fired += 1 }
        XCTAssertEqual(fired, 1)
        /* Slightly under the limit does not re-arm (hysteresis)… */
        XCTAssertFalse(g.update(.kmh(115), nowMs: ms(301)))
        for sec in stride(from: 302.0, through: 310, by: 1) { XCTAssertFalse(g.update(.kmh(130), nowMs: ms(sec))) }
        /* …clearly under it does, and after the cooldown it may nudge again. */
        XCTAssertFalse(g.update(.kmh(100), nowMs: ms(311)))
        XCTAssertFalse(g.update(.kmh(130), nowMs: ms(312)))
        XCTAssertTrue(g.update(.kmh(130), nowMs: ms(315)))
        /* Re-armed inside the cooldown: still quiet. */
        XCTAssertFalse(g.update(.kmh(90), nowMs: ms(316)))
        for sec in stride(from: 317.0, through: 330, by: 1) { XCTAssertFalse(g.update(.kmh(130), nowMs: ms(sec))) }
    }

    func testPrefsDefaultOffAt120() {
        let d = UserDefaults(suiteName: "speed-tests")!
        d.removePersistentDomain(forName: "speed-tests")
        XCTAssertFalse(SpeedPrefs.alertOn(d), "off by default")
        XCTAssertEqual(SpeedPrefs.limitKmh(d), 120)
        d.set(77, forKey: SpeedPrefs.limitKey)
        XCTAssertEqual(SpeedPrefs.limitKmh(d), 120, "not one of the offered limits")
        d.set(140, forKey: SpeedPrefs.limitKey)
        XCTAssertEqual(SpeedPrefs.limitKmh(d), 140)
    }

    // MARK: trip max / average

    func testPeakIgnoresASingleSpike() {
        var p = SpeedPeak()
        for (i, s) in [20.0, 21, 50, 22, 23].enumerated() { p.add(fix(s, at: Double(i))) }
        XCTAssertEqual(p.maxMps, 22, accuracy: 1e-9, "the 50 m/s spike is not the trip's top speed")
        /* Sustained higher speed counts. */
        for (i, s) in [30.0, 31, 32].enumerated() { p.add(fix(s, at: 10 + Double(i))) }
        XCTAssertEqual(p.maxMps, 30, accuracy: 1e-9)
    }

    func testPeakNeedsContiguousValidFixes() {
        var p = SpeedPeak()
        p.add(fix(40, at: 0))
        p.add(fix(40, at: 1))
        p.add(fix(nil, at: 2))
        p.add(fix(40, at: 3))
        XCTAssertEqual(p.maxMps, 0, "an invalid fix breaks the run")
        p.add(fix(40, at: 4))
        p.add(fix(40, at: 30))
        XCTAssertEqual(p.maxMps, 0, "a long gap breaks it too")
        p.add(fix(40, at: 31))
        p.add(fix(40, at: 32))
        XCTAssertEqual(p.maxMps, 40, accuracy: 1e-9)
    }

    func testTripSummaryAverageIsDistanceOverMovingTime() {
        let s = TripSpeedSummary.make(distanceM: 30_000, movingS: 1_800, peakMps: 30)
        XCTAssertEqual(s.avgMovingKmh!, 60, accuracy: 1e-9)
        XCTAssertEqual(s.maxKmh!, 108, accuracy: 1e-9)
        XCTAssertNil(TripSpeedSummary.make(distanceM: 100, movingS: 30, peakMps: nil).avgMovingKmh, "too little driving for an honest average")
        XCTAssertTrue(TripSpeedSummary.make(distanceM: 0, movingS: 0, peakMps: 0).isEmpty)
        XCTAssertEqual(TripSpeedSummary.make(distanceM: 30_000, movingS: 600, peakMps: 10).avgMovingKmh!, 36, accuracy: 1e-9, "never above the peak")
    }

    func testTripLogTracksPeakAndStillDecodesOldLogs() throws {
        var log = TripLog()
        /* ~20 m/s east for 2 minutes, one fix a second. */
        for i in 0...120 {
            log.add(lat: 24.7, lng: 46.7 + Double(i) * 0.000198, accuracy: 5, speed: 20, atMs: ms(Double(i)), speedAccuracy: 0.5)
        }
        let s = log.speedSummary
        XCTAssertEqual(s.maxKmh!, 72, accuracy: 0.01)
        XCTAssertEqual(s.avgMovingKmh!, 72, accuracy: 3)
        /* A log saved before this feature (no `peak`) still loads. */
        let old = #"{"distanceM":1000,"movingS":100,"firstAtMs":1,"lastAtMs":200000}"#
        let decoded = try JSONDecoder().decode(TripLog.self, from: Data(old.utf8))
        XCTAssertNil(decoded.peak)
        XCTAssertNil(decoded.speedSummary.maxKmh)
        /* The shared totals carry no speed at all. */
        let shared = try JSONEncoder().encode(log.totals!)
        XCTAssertFalse(String(decoding: shared, as: UTF8.self).lowercased().contains("speed"))
    }

    // MARK: friends

    private let now = ISODate.parse("2026-11-04T12:00:00.000Z")!
    private func iso(_ agoS: Double) -> String { ISODate.string(now.addingTimeInterval(-agoS)) }

    private func member(_ id: String, sharing: Bool = true, joined: Int) -> Member {
        Member(user_id: id, display_name: id, avatar: nil, phone: nil, role: id == "me" ? "owner" : "member", sharing: sharing,
               joined_at: "2026-11-04T10:0\(joined):00.000Z", online: true, away: false, last_seen_at: iso(2), gps: .ok,
               note: nil, co_leader: nil, battery: nil, sos: nil)
    }

    func testFriendSpeedOnlyFromFreshPositions() {
        let v = OutingView(OutingSnapshot(
            outing: OutingInfo(id: "o", name: "طلعة", status: .active, owner_id: "me", rally: nil),
            me: SnapshotMe(user_id: "me", role: "owner", sharing: true),
            members: [member("me", joined: 0), member("a", joined: 1), member("b", joined: 2), member("c", joined: 3), member("d", sharing: false, joined: 4)],
            positions: [
                Position(user_id: "a", lat: 24.701, lng: 46.70, accuracy: 5, heading: 0, speed: 25, mode: .balanced, recorded_at: iso(3)),
                Position(user_id: "b", lat: 24.71, lng: 46.70, accuracy: 5, heading: nil, speed: 25, mode: .balanced, recorded_at: iso(240)),
                Position(user_id: "c", lat: 24.72, lng: 46.70, accuracy: 5, heading: nil, speed: nil, mode: .balanced, recorded_at: iso(2)),
                Position(user_id: "d", lat: 24.73, lng: 46.70, accuracy: 5, heading: nil, speed: 20, mode: .balanced, recorded_at: iso(2)),
            ],
            invite: nil, server_now: ISODate.string(now)
        ), deviceNow: now)
        var i = LivePresenterInput()
        i.view = v
        i.myFix = DeviceFix(lat: 24.7, lng: 46.7, accuracy: 5, heading: nil, speed: 30, atMs: now.timeIntervalSince1970 * 1000 - 500)
        i.isSharingNow = true
        i.now = now
        let parts = Dictionary(uniqueKeysWithValues: LiveOutingPresenter.participants(i).map { ($0.id, $0) })
        XCTAssertEqual(parts["a"]?.speedKmh ?? -1, 90, accuracy: 1e-9, "fresh position: its speed")
        XCTAssertNil(parts["b"]?.speedKmh, "a 4-minute-old position shows «آخر موقع», never its old speed")
        XCTAssertNil(parts["c"]?.speedKmh, "no speed reported")
        XCTAssertNil(parts["d"]?.speedKmh, "not sharing")
        XCTAssertNil(parts["me"]?.speedKmh, "mine is the speedometer's job")
    }
}
