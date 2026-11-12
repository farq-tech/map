import SwiftUI
import XCTest
@testable import SaryAlbarq

/// Build 47 themes: the choice → (scheme, dim) rule, and token contrast for the three themes the
/// new components draw with (dark default, daylight, dim night driving).
final class SaryThemeChoiceTests: XCTestCase {
    func testAutoIsDimOnlyAtNightWhileDriving() {
        XCTAssertEqual(SaryThemeChoice.auto.resolve(autoNight: true, driving: true).night, true)
        XCTAssertEqual(SaryThemeChoice.auto.resolve(autoNight: true, driving: false).night, false)
        XCTAssertEqual(SaryThemeChoice.auto.resolve(autoNight: false, driving: true).night, false)
        XCTAssertEqual(SaryThemeChoice.auto.resolve(autoNight: false, driving: false).scheme, .dark)
    }

    func testManualChoicesIgnoreTheContext() {
        for night in [true, false] { for drive in [true, false] {
            XCTAssertEqual(SaryThemeChoice.dark.resolve(autoNight: night, driving: drive).scheme, .dark)
            XCTAssertFalse(SaryThemeChoice.dark.resolve(autoNight: night, driving: drive).night)
            XCTAssertEqual(SaryThemeChoice.light.resolve(autoNight: night, driving: drive).scheme, .light)
            XCTAssertFalse(SaryThemeChoice.light.resolve(autoNight: night, driving: drive).night)
            XCTAssertTrue(SaryThemeChoice.dim.resolve(autoNight: night, driving: drive).night)
        } }
    }

    func testLaunchArgumentsMapToChoices() {
        XCTAssertEqual(SaryThemeChoice.fromArguments(["-SaryNewUITheme", "light"]), .light)
        XCTAssertEqual(SaryThemeChoice.fromArguments(["-SaryNewUITheme", "dim", "-SaryScheme", "light"]), .dim)
        XCTAssertEqual(SaryThemeChoice.fromArguments(["-SaryScheme", "dark", "-SaryNight", "0"]), .dark)
        XCTAssertEqual(SaryThemeChoice.fromArguments(["-SaryNight", "1"]), .dim)
        XCTAssertNil(SaryThemeChoice.fromArguments([]))
    }

    func testChoicesResolveToTheThreePalettes() {
        #if DEBUG
        XCTAssertFalse(SaryThemeChoice.previewTheme(.dark).night)
        XCTAssertTrue(SaryThemeChoice.previewTheme(.dim).night)
        XCTAssertTrue(SaryThemeChoice.previewTheme(.light).isLight)
        XCTAssertEqual(SaryThemeChoice.previewTheme(.dark).palette.raw.background, 0x1A1612)
        XCTAssertEqual(SaryThemeChoice.previewTheme(.light).palette.raw.background, 0xF5EFE4)
        XCTAssertEqual(SaryThemeChoice.previewTheme(.dim).palette.raw.background, 0x0D0C0B)
        #endif
    }

    private func mix(_ fg: UInt32, _ a: Double, over bg: UInt32) -> UInt32 {
        func ch(_ s: UInt32) -> Double { Double(s & 0xFF) }
        func c(_ shift: UInt32) -> UInt32 {
            let f = Double((fg >> shift) & 0xFF), b = Double((bg >> shift) & 0xFF)
            return UInt32((f * a + b * (1 - a)).rounded())
        }
        return (c(16) << 16) | (c(8) << 8) | c(0)
    }

    func testTokenContrastInAllThreeThemes() {
        let themes: [(String, SaryPalette)] = [("dark", .dark()), ("light", .light()), ("dim", .night())]
        for (name, p) in themes {
            let r = p.raw
            for (surfaceName, surface) in [("background", r.background), ("elevated", r.elevated), ("surface", r.surface), ("sunken", r.sunken), ("opaque chrome", r.chromeOpaque)] {
                XCTAssertGreaterThanOrEqual(SaryContrast.ratio(r.textPrimary, surface), 7, "\(name) primary on \(surfaceName)")
                XCTAssertGreaterThanOrEqual(SaryContrast.ratio(r.textSecondary, surface), 4.5, "\(name) secondary on \(surfaceName)")
                /* Tertiary is for non-essential hints only (drive/night rules); large-text threshold. */
                XCTAssertGreaterThanOrEqual(SaryContrast.ratio(r.textTertiary, surface), 3, "\(name) tertiary on \(surfaceName)")
            }
            XCTAssertGreaterThanOrEqual(SaryContrast.ratio(r.onAccent, r.accentFill), 4.5, "\(name) ink on the primary button")
            /* Big bold maneuver text on navBlue: WCAG large-text 3:1. */
            XCTAssertGreaterThanOrEqual(SaryContrast.ratio(r.onNavBlue, r.navBlue), 3, "\(name) ink on navBlue")
            /* Glass over the brightest and the darkest map pixel (blur only softens that). KNOWN FAILURE (2026-11-13): dark theme secondary on glass over white is 3.96:1; the fix is a more opaque glass fill, not a lower threshold. */
            for backdrop in [UInt32(0xFFFFFF), 0x000000] {
                let glass = mix(r.glassFill, r.glassAlpha, over: backdrop)
                XCTAssertGreaterThanOrEqual(SaryContrast.ratio(r.textPrimary, glass), 7, "\(name) primary on glass over \(String(backdrop, radix: 16))")
                XCTAssertGreaterThanOrEqual(SaryContrast.ratio(r.textSecondary, glass), 4.5, "\(name) secondary on glass over \(String(backdrop, radix: 16))")
            }
        }
    }

    func testGlassHasItsOwnTintPerTheme() {
        XCTAssertEqual(SaryPalette.dark().raw.glassFill, 0x1C1814)
        XCTAssertEqual(SaryPalette.dark().raw.glassAlpha, 0.78)
        XCTAssertNotEqual(SaryPalette.light().raw.glassFill, SaryPalette.dark().raw.glassFill)
        XCTAssertNotEqual(SaryPalette.night().raw.glassFill, SaryPalette.dark().raw.glassFill)
    }
}
