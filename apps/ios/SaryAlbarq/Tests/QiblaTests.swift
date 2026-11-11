import CoreLocation
import XCTest
@testable import SaryAlbarq

final class QiblaTests: XCTestCase {
    private func c(_ lat: Double, _ lng: Double) -> CLLocationCoordinate2D { .init(latitude: lat, longitude: lng) }

    /// Reference values: the great-circle initial bearing to the Kaaba (21.4225, 39.8262).
    func testBearingFromKnownCities() {
        XCTAssertEqual(Qibla.bearing(from: c(24.7136, 46.6753)), 243.8, accuracy: 0.5)   // الرياض ≈ 244°
        XCTAssertEqual(Qibla.bearing(from: c(21.5433, 39.1728)), 101.1, accuracy: 0.5)   // جدة
        XCTAssertEqual(Qibla.bearing(from: c(26.4207, 50.0888)), 244.1, accuracy: 0.5)   // الدمام
        XCTAssertEqual(Qibla.bearing(from: c(28.3835, 36.5662)), 156.3, accuracy: 0.5)   // تبوك
        XCTAssertEqual(Qibla.bearing(from: c(24.4672, 39.6024)), 176.1, accuracy: 0.5)   // المدينة
        XCTAssertEqual(Qibla.bearing(from: c(51.5074, -0.1278)), 119.0, accuracy: 0.5)   // London
        XCTAssertEqual(Qibla.bearing(from: c(40.7128, -74.0060)), 58.5, accuracy: 0.5)   // New York (great circle, not rhumb)
        XCTAssertEqual(Qibla.bearing(from: c(-6.2088, 106.8456)), 295.2, accuracy: 0.5)  // Jakarta
    }

    func testBearingIsAlwaysInRangeAndDueNorthSouth() {
        XCTAssertEqual(Qibla.bearing(from: c(10, 39.8262)), 0, accuracy: 1e-9)
        XCTAssertEqual(Qibla.bearing(from: c(30, 39.8262)), 180, accuracy: 1e-9)
        for lat in stride(from: -60.0, through: 60, by: 15) {
            for lng in stride(from: -180.0, through: 180, by: 30) {
                let b = Qibla.bearing(from: c(lat, lng))
                XCTAssertTrue(b >= 0 && b < 360, "\(lat),\(lng) → \(b)")
            }
        }
    }

    func testDistance() {
        XCTAssertEqual(Qibla.distanceKm(from: c(24.7136, 46.6753)), 792, accuracy: 10)
        XCTAssertEqual(Qibla.distanceKm(from: Qibla.kaaba), 0, accuracy: 1e-6)
    }

    func testMapRayUsesGreatCircleAndEndsAtKaaba() {
        let origin = c(24.7136, 46.6753)
        let points = Qibla.greatCirclePoints(from: origin)
        XCTAssertEqual(points.count, 49)
        XCTAssertEqual(points.first?.latitude ?? 0, origin.latitude, accuracy: 1e-9)
        XCTAssertEqual(points.first?.longitude ?? 0, origin.longitude, accuracy: 1e-9)
        XCTAssertEqual(points.last?.latitude ?? 0, Qibla.kaaba.latitude, accuracy: 1e-9)
        XCTAssertEqual(points.last?.longitude ?? 0, Qibla.kaaba.longitude, accuracy: 1e-9)
        let firstSegmentBearing = Qibla.bearing(from: points[0], to: points[1])
        XCTAssertEqual(firstSegmentBearing, Qibla.bearing(from: origin), accuracy: 0.1)
    }

    func testTurnAndHints() {
        XCTAssertEqual(Qibla.turn(qibla: 244, heading: 240), 4, accuracy: 1e-9)
        XCTAssertEqual(Qibla.turn(qibla: 10, heading: 350), 20, accuracy: 1e-9)
        XCTAssertEqual(Qibla.turn(qibla: 350, heading: 10), -20, accuracy: 1e-9)
        XCTAssertEqual(Qibla.turnHint(3), "أنت مقابل القبلة")
        XCTAssertEqual(Qibla.turnHint(30), "لِف يمين ٣٠°")
        XCTAssertEqual(Qibla.turnHint(-90), "لِف يسار ٩٠°")
        XCTAssertEqual(Qibla.degreesLabel(243.8), "٢٤٤°")
        XCTAssertEqual(Qibla.degreesLabel(359.7), "٠°")
    }

    func testCalibration() {
        XCTAssertEqual(Qibla.calibration(accuracy: nil), .unavailable)
        XCTAssertEqual(Qibla.calibration(accuracy: -1), .unavailable)
        XCTAssertEqual(Qibla.calibration(accuracy: 8), .good)
        XCTAssertEqual(Qibla.calibration(accuracy: 35), .poor)
    }

    func testLocationAuthorizationAndFailuresLeaveTheWaitingState() {
        XCTAssertEqual(QiblaLocationState.authorization(.notDetermined), .locating)
        XCTAssertEqual(QiblaLocationState.authorization(.authorizedWhenInUse), .locating)
        XCTAssertEqual(QiblaLocationState.authorization(.authorizedAlways), .locating)
        XCTAssertEqual(QiblaLocationState.authorization(.denied), .denied)
        XCTAssertEqual(QiblaLocationState.authorization(.restricted), .denied)
        XCTAssertEqual(QiblaLocationState.failure(CLError(.denied)), .denied)
        XCTAssertEqual(QiblaLocationState.failure(CLError(.locationUnknown)), .failed)
    }

    func testQiblaIsOneEntryInTheToolsGrid() {
        let groups = LiveActionCatalog.groups(.init())
        let children = groups.flatMap(\.items).flatMap(\.children).map(\.id)
        XCTAssertEqual(children.filter { $0 == "qibla" }.count, 1, "under «طقس واتجاه», not as a duplicate tile")
        XCTAssertEqual(LiveModal.qibla.id, "qibla")
        /* It still makes sense after the trip ends. */
        let endedChildren = LiveActionCatalog.groups(.init(ended: true)).flatMap(\.items).flatMap(\.children)
        XCTAssertTrue(endedChildren.contains { $0.id == "qibla" })
    }

    // MARK: screen fit

    func testCompassKeepsItsSizeOnStandardAndLargePhones() {
        // Sheet content areas (pt) of a 393×852 phone and a 440×956 Pro Max.
        XCTAssertEqual(Qibla.compassScale(page: CGSize(width: 393, height: 780)), 1)
        XCTAssertEqual(Qibla.compassScale(page: CGSize(width: 440, height: 890)), 1)
        XCTAssertEqual(Qibla.compassScale(page: CGSize(width: 375, height: 745)), 1, "mini keeps the full compass")
    }

    func testCompassShrinksOnAnSE() {
        let s = Qibla.compassScale(page: CGSize(width: 375, height: 620))
        XCTAssertLessThan(s, 1)
        XCTAssertEqual(s, (620 - 340) / 320, accuracy: 0.0001)
        // Compass + header/degrees/hint fit the page.
        XCTAssertLessThanOrEqual(Qibla.compassDesign.height * s + 340, 620.5)
    }

    func testCompassScaleIsBounded() {
        XCTAssertEqual(Qibla.compassScale(page: CGSize(width: 200, height: 300)), 0.72)
        XCTAssertEqual(Qibla.compassScale(page: .zero), 1)
        XCTAssertEqual(Qibla.compassScale(page: CGSize(width: 320, height: 900)), (320 - 40) / 300, accuracy: 0.0001)
    }

    func testDialTurnsTheShortWayAcrossNorth() {
        XCTAssertEqual(Qibla.unwrap(previous: nil, next: 370), 10, accuracy: 1e-9)
        XCTAssertEqual(Qibla.unwrap(previous: 359, next: 1), 361, accuracy: 1e-9, "+2°, not −358°")
        XCTAssertEqual(Qibla.unwrap(previous: 361, next: 355), 355, accuracy: 1e-9)
        XCTAssertEqual(Qibla.unwrap(previous: 2, next: 358), -2, accuracy: 1e-9)
        var d: Double? = nil
        for h in [350.0, 355, 0, 5, 10, 5, 0, 355] { d = Qibla.unwrap(previous: d, next: h) }
        XCTAssertEqual(d ?? 0, 355, accuracy: 1e-9, "a sweep back and forth over north stays continuous")
    }

    func testAlignedHasHysteresisSoTheHapticPlaysOnce() {
        XCTAssertTrue(Qibla.aligned(turn: 4, was: false))
        XCTAssertFalse(Qibla.aligned(turn: 6, was: false), "not in yet")
        XCTAssertTrue(Qibla.aligned(turn: 6, was: true), "a tremble at the edge keeps it")
        XCTAssertTrue(Qibla.aligned(turn: -7.9, was: true))
        XCTAssertFalse(Qibla.aligned(turn: 9, was: true), "really turned away")
    }

    /// Issue #163: a late authorization answer after the screen closed must not restart the GPS.
    @MainActor
    func testStoppedCompassDoesNotStartLocationAgain() {
        let c = QiblaCompass()
        c.start()
        XCTAssertTrue(c.isRunning)
        c.stop()
        XCTAssertFalse(c.isRunning)
        c.start()
        XCTAssertTrue(c.isRunning, "a new start runs again")
        c.stop()
        XCTAssertFalse(c.isRunning, "begin-location is guarded by this flag")
    }
}
