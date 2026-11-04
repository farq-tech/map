import CoreLocation
import XCTest
@testable import SaryAlbarq

/// Mirrors `apps/web/src/lib/outings/policy.test.ts` case for case, so the web
/// and the app keep describing the same person the same way.
final class PolicyTests: XCTestCase {
    private let base = DeviceFix(lat: 24.7, lng: 46.7, accuracy: 8, heading: nil, speed: nil, atMs: 0)

    /// metres north of base
    private func north(_ m: Double, _ at: Double, speed: Double? = nil, accuracy: Double? = 8) -> DeviceFix {
        DeviceFix(lat: base.lat + m / 111_195, lng: base.lng, accuracy: accuracy, heading: nil, speed: speed, atMs: at)
    }

    func testTierBySpeed() {
        XCTAssertEqual(Policy.tier(speedMps: 35), .init(intervalMs: 2_500, distanceM: 50))
        XCTAssertEqual(Policy.tier(speedMps: 15), .init(intervalMs: 4_000, distanceM: 35))
        XCTAssertEqual(Policy.tier(speedMps: 3), .init(intervalMs: 6_000, distanceM: 15))
        XCTAssertEqual(Policy.tier(speedMps: 3, mode: .saver), .init(intervalMs: 12_000, distanceM: 30))
        XCTAssertEqual(Policy.tier(speedMps: 35, mode: .precise), .init(intervalMs: 1_500, distanceM: 30))
        XCTAssertEqual(Policy.tier(speedMps: nil), Policy.tier(speedMps: 0))
    }

    func testSendsOnDistanceOrTimeWhileMoving() {
        let last = Policy.LastSent(fix: base, sentAtMs: 0)
        /* 140 km/h: 50 m crossed in under 2 s */
        XCTAssertTrue(Policy.shouldSend(north(60, 1500, speed: 39), last: last, mode: .balanced, nowMs: 1500))
        /* road speed, 20 m in 2 s: neither 35 m nor 4 s yet */
        XCTAssertFalse(Policy.shouldSend(north(20, 2000, speed: 10), last: last, mode: .balanced, nowMs: 2000))
        /* road speed, 4 s passed */
        XCTAssertTrue(Policy.shouldSend(north(20, 4000, speed: 10), last: last, mode: .balanced, nowMs: 4000))
        /* never twice inside the 1 s floor */
        XCTAssertFalse(Policy.shouldSend(north(200, 500, speed: 39), last: last, mode: .balanced, nowMs: 500))
    }

    func testParkedOnlyHeartbeat() {
        let last = Policy.LastSent(fix: base, sentAtMs: 0)
        XCTAssertFalse(Policy.shouldSend(north(3, 10_000, speed: 0), last: last, mode: .balanced, nowMs: 10_000))
        XCTAssertTrue(Policy.shouldSend(north(3, 30_000, speed: 0), last: last, mode: .balanced, nowMs: 30_000))
        /* saver: once a minute */
        XCTAssertFalse(Policy.shouldSend(north(3, 30_000, speed: 0), last: last, mode: .saver, nowMs: 30_000))
        XCTAssertTrue(Policy.shouldSend(north(3, 60_000, speed: 0), last: last, mode: .saver, nowMs: 60_000))
    }

    func testNeverSendsOlderOrUselessFix() {
        let last = Policy.LastSent(fix: north(0, 5000), sentAtMs: 5000)
        XCTAssertFalse(Policy.shouldSend(north(500, 4000), last: last, mode: .balanced, nowMs: 60_000))
        XCTAssertFalse(Policy.shouldSend(north(500, 9000, accuracy: 400), last: last, mode: .balanced, nowMs: 60_000))
        XCTAssertFalse(Policy.shouldSend(north(0, 0, accuracy: 151), last: nil, mode: .balanced, nowMs: 0))
        XCTAssertTrue(Policy.shouldSend(north(0, 0), last: nil, mode: .balanced, nowMs: 0))
    }

    func testFixFilterHoldsGlitchUntilConfirmed() {
        var f = FixFilter()
        XCTAssertNotNil(f.accept(north(0, 0)))
        XCTAssertNil(f.accept(north(2000, 2000)), "2 km in 2 s is a glitch")
        XCTAssertNotNil(f.accept(north(30, 4000)), "back on the trusted track")
        XCTAssertNil(f.accept(north(5000, 6000)))
        XCTAssertNotNil(f.accept(north(5030, 8000)), "a real relocation, confirmed by the next fix")
    }

    func testFixFilterAcceptsHighwaySpeedAndBenefitOfError() {
        var f = FixFilter()
        _ = f.accept(north(0, 0))
        XCTAssertNotNil(f.accept(north(200, 5000, speed: 40)))
        var g = FixFilter()
        _ = g.accept(north(0, 0, accuracy: 100))
        XCTAssertNotNil(g.accept(north(250, 2000, accuracy: 100)))
    }

    func testFixFilterRejectsOutOfOrder() {
        var f = FixFilter()
        _ = f.accept(north(0, 5000))
        XCTAssertNil(f.accept(north(10, 4000)))
    }

    func testFreshnessNeverCallsOldLive() {
        XCTAssertEqual(Policy.freshness(fixAgeMs: 10_000, speedMps: 20, lastSeenAgeMs: 2_000), .live)
        XCTAssertEqual(Policy.freshness(fixAgeMs: 20_000, speedMps: 20, lastSeenAgeMs: 2_000), .recent)
        XCTAssertEqual(Policy.freshness(fixAgeMs: 40_000, speedMps: 0, lastSeenAgeMs: 5_000), .live)
        XCTAssertEqual(Policy.freshness(fixAgeMs: 5 * 60_000, speedMps: 10, lastSeenAgeMs: 10_000), .recent)
        XCTAssertEqual(Policy.freshness(fixAgeMs: 90_000, speedMps: 10, lastSeenAgeMs: 90_000), .lost)
        XCTAssertEqual(Policy.freshness(fixAgeMs: 90_000, speedMps: 10, lastSeenAgeMs: nil), .lost)
    }

    func testGeometryAndArabicDirection() {
        XCTAssertEqual(Geo.bearingDeg(.init(lat: 24, lng: 46), .init(lat: 25, lng: 46)).rounded(), 0)
        XCTAssertEqual(Geo.bearingDeg(.init(lat: 24, lng: 46), .init(lat: 24, lng: 47)).rounded(), 90)
        XCTAssertEqual(Geo.directionLabel(45), "شمال شرق")
        XCTAssertEqual(Geo.directionLabel(350), "شمال")
        XCTAssertEqual(Geo.directionLabel(-90), "غرب")
        XCTAssertEqual(Geo.haversineMeters(.init(lat: 24.7, lng: 46.7), .init(lat: 24.7 + 1000 / 111_195, lng: 46.7)), 1000, accuracy: 1)
    }

    func testTrustedHeadingAndAccuracy() {
        XCTAssertNil(Policy.trustedHeading(90, speed: 0.5))
        XCTAssertNil(Policy.trustedHeading(nil, speed: 20))
        XCTAssertEqual(Policy.trustedHeading(-90, speed: 20), 270)
        XCTAssertEqual(Policy.accuracyGrade(12), .good)
        XCTAssertEqual(Policy.accuracyGrade(45), .fair)
        XCTAssertEqual(Policy.accuracyGrade(90), .poor)
        XCTAssertEqual(Policy.accuracyGrade(nil), .fair)
    }

    func testWireFixCarriesDeviceMeasuredAge() {
        let w = Policy.wireFix(north(0, 10_000, speed: 5), mode: .saver, nowMs: 12_500)
        XCTAssertEqual(w.age_ms, 2_500)
        XCTAssertEqual(w.mode, .saver)
        XCTAssertEqual(Policy.wireFix(north(0, 10_000), mode: .balanced, nowMs: 9_000).age_ms, 0, "a clock step back never makes a negative age")
    }

    func testArabicFormatting() {
        XCTAssertEqual(ArabicFormat.distance(4), "١٠ م")
        XCTAssertEqual(ArabicFormat.distance(2340), "٢٫٣ كم")
        XCTAssertEqual(ArabicFormat.distance(23_400), "٢٣ كم")
        XCTAssertEqual(ArabicFormat.ago(3_000), "الآن")
        XCTAssertEqual(ArabicFormat.ago(180_000), "قبل ٣ د")
        XCTAssertEqual(ArabicFormat.freshnessLabel(.live), "مباشر")
        XCTAssertEqual(ArabicFormat.freshnessLabel(.recent), "آخر موقع")
        XCTAssertEqual(ArabicFormat.freshnessLabel(.lost), "انقطع")
    }
}

final class LocationTuningTests: XCTestCase {
    func testBatteryProtectionDropsToSaver() {
        XCTAssertEqual(LocationTuning.effectiveMode(chosen: .precise, lowPowerMode: true, batteryLevel: 0.9, charging: false), .saver)
        XCTAssertEqual(LocationTuning.effectiveMode(chosen: .balanced, lowPowerMode: false, batteryLevel: 0.15, charging: false), .saver)
        XCTAssertEqual(LocationTuning.effectiveMode(chosen: .balanced, lowPowerMode: false, batteryLevel: 0.15, charging: true), .balanced)
        /* -1 = unknown (simulator): never treated as low */
        XCTAssertEqual(LocationTuning.effectiveMode(chosen: .precise, lowPowerMode: false, batteryLevel: -1, charging: false), .precise)
    }

    func testNoDistanceFilterWhileSharingSoParkedHeartbeatsStillGetFixes() {
        for mode in ShareMode.allCases {
            for speed in [0.0, 10, 30] {
                XCTAssertEqual(LocationTuning.settings(mode: mode, speedMps: speed).distanceFilter, kCLDistanceFilterNone)
            }
        }
    }

    func testAccuracyFollowsModeAndMotion() {
        XCTAssertEqual(LocationTuning.settings(mode: .precise, speedMps: 30).desiredAccuracy, kCLLocationAccuracyBestForNavigation)
        XCTAssertEqual(LocationTuning.settings(mode: .balanced, speedMps: 10).desiredAccuracy, kCLLocationAccuracyBest)
        XCTAssertEqual(LocationTuning.settings(mode: .balanced, speedMps: 0).desiredAccuracy, kCLLocationAccuracyNearestTenMeters)
        XCTAssertEqual(LocationTuning.settings(mode: .saver, speedMps: 0).desiredAccuracy, kCLLocationAccuracyHundredMeters)
    }

    func testDeviceFixMapsInvalidValues() {
        let l = CLLocation(coordinate: .init(latitude: 24.7, longitude: 46.7), altitude: 0, horizontalAccuracy: 12, verticalAccuracy: -1, course: -1, speed: -1, timestamp: Date(timeIntervalSince1970: 100))
        let f = LocationTuning.deviceFix(l)
        XCTAssertNil(f?.heading)
        XCTAssertNil(f?.speed)
        XCTAssertEqual(f?.atMs, 100_000)
        let bad = CLLocation(coordinate: .init(latitude: 24.7, longitude: 46.7), altitude: 0, horizontalAccuracy: -1, verticalAccuracy: -1, timestamp: Date())
        XCTAssertNil(LocationTuning.deviceFix(bad))
    }

    func testGpsState() {
        XCTAssertEqual(LocationTuning.gpsState(auth: .denied, lastAccuracy: 5, lastFixAgeMs: 1), .denied)
        XCTAssertEqual(LocationTuning.gpsState(auth: .authorizedWhenInUse, lastAccuracy: 5, lastFixAgeMs: 1_000), .ok)
        XCTAssertEqual(LocationTuning.gpsState(auth: .authorizedWhenInUse, lastAccuracy: 90, lastFixAgeMs: 1_000), .weak)
        XCTAssertEqual(LocationTuning.gpsState(auth: .authorizedAlways, lastAccuracy: 5, lastFixAgeMs: 45_000), .unavailable)
    }
}
