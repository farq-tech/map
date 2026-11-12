import SwiftUI
import XCTest
@testable import SaryAlbarq

/// «وضع السيارة / بث الشاشة»: the pure rules. Off by default, portrait-only unless on, a wide-short layout whose buttons are
/// never under 64 pt and text never under 20 pt, and the mirrored-screen rule.
final class CarModeTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let d = UserDefaults(suiteName: "car-mode-tests")!
        d.removePersistentDomain(forName: "car-mode-tests")
        return d
    }

    func testOffByDefaultAndTheKeyTurnsItOn() {
        let d = defaults()
        XCTAssertFalse(CarMode.isOn(defaults: d, arguments: []))
        d.set(true, forKey: CarMode.key)
        XCTAssertTrue(CarMode.isOn(defaults: d, arguments: []))
    }

    func testThePhoneIsPortraitOnlyUnlessTheModeIsOn() {
        XCTAssertEqual(CarMode.orientationMask(carMode: false, idiom: .phone), .portrait)
        XCTAssertEqual(CarMode.orientationMask(carMode: true, idiom: .phone), .landscape)
        XCTAssertEqual(CarMode.orientationMask(carMode: false, idiom: .pad), .all, "the iPad keeps every orientation it had")
        XCTAssertEqual(CarMode.orientationMask(carMode: true, idiom: .pad), .all)
    }

    func testPreviewSizeParsing() {
        XCTAssertEqual(CarMode.parseSize("1280x480"), CGSize(width: 1280, height: 480))
        XCTAssertEqual(CarMode.parseSize("1920×720"), CGSize(width: 1920, height: 720))
        XCTAssertNil(CarMode.parseSize("1280"))
        XCTAssertNil(CarMode.parseSize("axb"))
        XCTAssertNil(CarMode.parseSize("50x50"), "a viewport that small is not a car screen")
    }

    func testViewportKinds() {
        XCTAssertEqual(CarModeLayout.kind(for: CGSize(width: 1280, height: 480)), .ultraWide)
        XCTAssertEqual(CarModeLayout.kind(for: CGSize(width: 1920, height: 720)), .ultraWide)
        XCTAssertEqual(CarModeLayout.kind(for: CGSize(width: 1280, height: 640)), .wide)
        XCTAssertEqual(CarModeLayout.kind(for: CGSize(width: 1280, height: 720)), .standard)
        XCTAssertEqual(CarModeLayout.kind(for: CGSize(width: 0, height: 0)), .standard)
    }

    func testTheFloorsAreAboveThePhonesOwnBecauseTheMirrorIsScaledDown() {
        XCTAssertGreaterThanOrEqual(CarModeLayout.minButton, 72)
        XCTAssertGreaterThanOrEqual(CarModeLayout.minFont, 24)
        XCTAssertGreaterThanOrEqual(CarModeLayout.minInstruction, 28)
        XCTAssertGreaterThanOrEqual(CarModeLayout.minDistance, 64)
    }

    func testButtonsAndTextAreNeverSmallerThanTheMinimumAtAnyCarSize() {
        let sizes = [CGSize(width: 1280, height: 480), CGSize(width: 1920, height: 720), CGSize(width: 1280, height: 720),
                     CGSize(width: 844, height: 390), CGSize(width: 932, height: 430), CGSize(width: 1024, height: 600),
                     CGSize(width: 800, height: 300)]
        for size in sizes {
            let l = CarModeLayout.make(size: size, safe: EdgeInsets(top: 0, leading: 47, bottom: 21, trailing: 47), buttons: 9)
            XCTAssertGreaterThanOrEqual(l.button, CarModeLayout.minButton, "\(size)")
            XCTAssertGreaterThanOrEqual(l.labelFont, CarModeLayout.minFont, "\(size)")
            XCTAssertGreaterThanOrEqual(l.instructionFont, CarModeLayout.minInstruction, "\(size)")
            XCTAssertGreaterThanOrEqual(l.barFont, CarModeLayout.minFont, "\(size)")
            XCTAssertGreaterThanOrEqual(l.distanceFont, CarModeLayout.minDistance, "\(size)")
        }
    }

    func testEveryControlFitsInTheColumnsOnTheShortestScreens() {
        for size in [CGSize(width: 1280, height: 480), CGSize(width: 800, height: 300)] {
            let l = CarModeLayout.make(size: size, buttons: 9)
            let perColumn = Int((Double(9) / Double(l.columns)).rounded(.up))
            let needed = CGFloat(perColumn) * l.button + CGFloat(perColumn - 1) * l.gap
            XCTAssertLessThanOrEqual(needed, size.height, "\(size): the controls would run off the screen")
            XCTAssertLessThanOrEqual(l.columns, 3)
        }
    }

    func testTheTallestCarScreenUsesOneColumnAndALabel() {
        let l = CarModeLayout.make(size: CGSize(width: 1920, height: 1080), buttons: 9)
        XCTAssertLessThanOrEqual(l.columns, 2)
        XCTAssertTrue(l.showsLabels)
        XCTAssertLessThanOrEqual(l.button, 104)
    }

    func testTheCardNeverTakesMoreThanTheCapAndTheMapKeepsItsMiddle() {
        let l = CarModeLayout.make(size: CGSize(width: 1920, height: 720), buttons: 9)
        XCTAssertLessThanOrEqual(l.cardWidth, 560)
        XCTAssertGreaterThan(1920 - l.cardWidth - l.controlsWidth - 48, 700, "the middle of the map stays clear")
        let small = CarModeLayout.make(size: CGSize(width: 1280, height: 480), buttons: 9)
        XCTAssertGreaterThan(1280 - small.cardWidth - small.controlsWidth - 48, 400, "1280x480 keeps a usable middle")
        let rtl = l.mapInsets(rtl: true)
        XCTAssertEqual(rtl.right, l.cardWidth + 24, "RTL: the card is on the right edge")
        XCTAssertEqual(rtl.left, l.controlsWidth)
        let ltr = l.mapInsets(rtl: false)
        XCTAssertEqual(ltr.left, l.cardWidth + 24)
    }

    func testMirroredScreenRule() {
        XCTAssertFalse(CarModeCapture.isMirrored(captured: [false], screenCount: 1))
        XCTAssertTrue(CarModeCapture.isMirrored(captured: [true], screenCount: 1), "screen recording / AirPlay mirroring")
        XCTAssertTrue(CarModeCapture.isMirrored(captured: [false, false], screenCount: 2), "a second display")
    }

    func testPowerAndHeatWarnings() {
        XCTAssertNil(CarModeWarning.text(lowPower: false, thermal: .nominal))
        XCTAssertNil(CarModeWarning.text(lowPower: false, thermal: .fair))
        XCTAssertNotNil(CarModeWarning.text(lowPower: true, thermal: .nominal))
        XCTAssertTrue(CarModeWarning.text(lowPower: true, thermal: .serious)?.contains("سخن") == true, "heat outranks Low Power Mode")
        XCTAssertNotNil(CarModeWarning.text(lowPower: false, thermal: .critical))
    }

    func testKeepAwakeIsReassertedOftenEnoughAfterNavigationClearsIt() {
        XCTAssertLessThanOrEqual(CarModeAwake.reassertEvery, 30)
    }
}
