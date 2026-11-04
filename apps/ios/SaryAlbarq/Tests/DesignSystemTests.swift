import SwiftUI
import UIKit
import XCTest
@testable import SaryAlbarq

final class SaryFormatTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_000_000)

    func testArabicIndicDigits() {
        XCTAssertEqual(SaryFormat.digits("0123456789"), "٠١٢٣٤٥٦٧٨٩")
        XCTAssertEqual(SaryFormat.digits("6.1"), "٦٫١")
        XCTAssertEqual(SaryFormat.digits("abc 12:05"), "abc ١٢:٠٥")
        XCTAssertEqual(SaryFormat.number(3), "٣")
        // No Western digit survives formatting.
        for s in [SaryFormat.distance(meters: 1234), SaryFormat.clock(seconds: 75), SaryFormat.percent(82)] {
            XCTAssertNil(s.rangeOfCharacter(from: CharacterSet(charactersIn: "0123456789")), s)
        }
    }

    func testDistance() {
        XCTAssertEqual(SaryFormat.distance(meters: 900), "٩٠٠ م")
        XCTAssertEqual(SaryFormat.distance(meters: 904), "٩٠٠ م")
        XCTAssertEqual(SaryFormat.distance(meters: 7), "٧ م")
        XCTAssertEqual(SaryFormat.distance(meters: 6_100), "٦٫١ كم")
        XCTAssertEqual(SaryFormat.distance(meters: 6_140), "٦٫١ كم")
        XCTAssertEqual(SaryFormat.distance(meters: 1_000), "١ كم")
        XCTAssertEqual(SaryFormat.distance(meters: 996), "١ كم")
        XCTAssertEqual(SaryFormat.distance(meters: 123_400), "١٢٣ كم")
        XCTAssertEqual(SaryFormat.distance(meters: -5), "٠ م")
    }

    func testElapsed() {
        XCTAssertEqual(SaryFormat.elapsed(since: now.addingTimeInterval(-30), now: now), "الآن")
        XCTAssertEqual(SaryFormat.elapsed(since: now.addingTimeInterval(-4 * 60), now: now), "قبل ٤ د")
        XCTAssertEqual(SaryFormat.elapsed(since: now.addingTimeInterval(-2 * 3600), now: now), "قبل ٢ س")
        XCTAssertEqual(SaryFormat.elapsed(since: now.addingTimeInterval(-3 * 86_400), now: now), "قبل ٣ ي")
        XCTAssertEqual(SaryFormat.lastUpdate(since: now.addingTimeInterval(-240), now: now), "آخر تحديث قبل ٤ د")
        // Future timestamps (clock skew) never show negative ages.
        XCTAssertEqual(SaryFormat.elapsed(since: now.addingTimeInterval(120), now: now), "الآن")
    }

    func testClockDurationPercent() {
        XCTAssertEqual(SaryFormat.clock(seconds: 12), "٠:١٢")
        XCTAssertEqual(SaryFormat.clock(seconds: 65), "١:٠٥")
        XCTAssertEqual(SaryFormat.duration(seconds: 8_100), "٢ س ١٥ د")
        XCTAssertEqual(SaryFormat.percent(82), "٨٢٪")
        XCTAssertEqual(SaryFormat.percent(140), "١٠٠٪")
    }

    func testPeekSummary() {
        func p(_ id: String, me: Bool = false, _ presence: ParticipantPresence, _ d: Double?) -> ParticipantUI {
            ParticipantUI(id: id, name: id, color: 0, role: .member, isMe: me, presence: presence,
                          distanceMeters: d, bearingDegrees: nil, batteryPercent: nil, note: nil, hasPhone: false)
        }
        let list = [p("me", me: true, .live, nil), p("a", .live, 900), p("b", .stale(since: now), 6_100)]
        XCTAssertEqual(SaryFormat.peekSummary(list), "٣ مشارك · ٢ مباشر · الأقرب ٩٠٠ م")
        XCTAssertEqual(SaryFormat.peekSummary([p("me", me: true, .live, nil)]), "١ مشارك · ١ مباشر")
    }

    func testRelativeDirection() {
        XCTAssertEqual(SaryFormat.relativeDirection(0), "أمامك")
        XCTAssertEqual(SaryFormat.relativeDirection(90), "على يمينك")
        XCTAssertEqual(SaryFormat.relativeDirection(-90), "على يسارك")
        XCTAssertEqual(SaryFormat.relativeDirection(180), "خلفك")
    }

    func testSaudiPhone() {
        XCTAssertEqual(SaryFormat.normalizeSaudiMobile("+966 55 123 4567"), "0551234567")
        XCTAssertEqual(SaryFormat.normalizeSaudiMobile("٠٥٥١٢٣٤٥٦٧"), "0551234567")
        XCTAssertNil(SaryFormat.normalizeSaudiMobile("0112345678"))
        XCTAssertEqual(SaryFormat.displayPhone("0551234567"), "٠٥٥ ١٢٣ ٤٥٦٧")
    }
}

final class CarColorOrderTests: XCTestCase {
    /// Must equal the web's OUTING_CAR_COLORS (apps/web/src/lib/outings/carColors.ts), in order.
    private let web: [UInt32] = [
        0xE8EEF0, 0xD6452F, 0x2F6FD6, 0xF2B630, 0x2FA56A,
        0x8A4FD1, 0xF07F2F, 0x1FB8C4, 0xE05A9C, 0x15191C,
        0x9AA5AD, 0x7A5230,
    ]

    func testPaletteMatchesWebAndCore() {
        XCTAssertEqual(SaryCarColors.palette, web)
        XCTAssertEqual(CarColors.palette, web)
        XCTAssertEqual(SaryCarColors.names.count, web.count)
    }

    func testOwnerSpecFirstTen() {
        XCTAssertEqual(Array(SaryCarColors.palette.prefix(10)),
                       [0xE8EEF0, 0xD6452F, 0x2F6FD6, 0xF2B630, 0x2FA56A, 0x8A4FD1, 0xF07F2F, 0x1FB8C4, 0xE05A9C, 0x15191C])
    }

    func testJoinIndexWraps() {
        XCTAssertEqual(SaryCarColors.color(forJoinIndex: 0), 0xE8EEF0)
        XCTAssertEqual(SaryCarColors.color(forJoinIndex: 1), 0xD6452F)
        XCTAssertEqual(SaryCarColors.color(forJoinIndex: 12), 0xE8EEF0)
        XCTAssertEqual(SaryCarColors.color(forJoinIndex: -1), 0x7A5230)
    }

    func testInkContrast() {
        for c in SaryCarColors.palette {
            let ink: UInt32 = SaryCarColors.isLight(c) ? 0x15191C : 0xFFFFFF
            XCTAssertGreaterThanOrEqual(SaryContrast.ratio(c, ink), 3.0, String(format: "%06X", c))
        }
    }
}

final class AppearanceSettingsTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "sary.tests.appearance"

    override func setUp() {
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    func testDefaults() {
        let s = AppearanceSettings(defaults: defaults)
        XCTAssertEqual(s.prefs, AppearancePreferences())
        XCTAssertEqual(s.prefs.accent, .ember)
        XCTAssertEqual(s.prefs.driveMode, .auto)
    }

    func testPersistsAndRestores() {
        let a = AppearanceSettings(defaults: defaults)
        a.prefs.colorScheme = .light
        a.prefs.accent = .sky
        a.prefs.glass = .opaque
        a.prefs.driveMode = .on
        a.prefs.participantMarker = .dots
        a.prefs.textSize = .largest
        let b = AppearanceSettings(defaults: defaults)
        XCTAssertEqual(b.prefs, a.prefs)
        XCTAssertEqual(b.prefs.accent, .sky)
        XCTAssertEqual(b.prefs.participantMarker, .dots)
    }

    func testResetPersists() {
        let a = AppearanceSettings(defaults: defaults)
        a.prefs.density = .compact
        a.reset()
        XCTAssertEqual(AppearanceSettings(defaults: defaults).prefs, AppearancePreferences())
    }

    func testTolerantDecoding() throws {
        // An older/newer payload with an unknown value and a missing key keeps the rest.
        let json = #"{"accent":"rose","glass":"holographic","futureKey":1}"#
        defaults.set(Data(json.utf8), forKey: AppearanceSettings.storageKey)
        let s = AppearanceSettings(defaults: defaults)
        XCTAssertEqual(s.prefs.accent, .rose)
        XCTAssertEqual(s.prefs.glass, .regular)
        XCTAssertEqual(s.prefs.density, .regular)
    }

    func testCorruptPayloadFallsBackToDefaults() {
        defaults.set(Data("nope".utf8), forKey: AppearanceSettings.storageKey)
        XCTAssertEqual(AppearanceSettings(defaults: defaults).prefs, AppearancePreferences())
    }

    func testAutoModes() {
        let s = AppearanceSettings(defaults: defaults)
        XCTAssertFalse(s.isDriving)
        s.autoDrive = true
        XCTAssertTrue(s.isDriving)
        s.prefs.driveMode = .off
        XCTAssertFalse(s.isDriving)
        s.prefs.nightMode = .on
        XCTAssertTrue(s.isNight)
    }

    func testTextSizeSteps() {
        XCTAssertEqual(SaryTextSize.larger.apply(to: .large), .xLarge)
        XCTAssertEqual(SaryTextSize.smaller.apply(to: .xSmall), .xSmall)
        XCTAssertEqual(SaryTextSize.largest.apply(to: .accessibility5), .accessibility5)
    }
}

final class SaryThemeTests: XCTestCase {
    func testDriveIsOpaqueAndBig() {
        var prefs = AppearancePreferences()
        prefs.glass = .clear
        let t = SaryTheme.resolve(prefs: prefs, scheme: .dark, night: false, drive: true)
        XCTAssertEqual(t.effectiveGlass, .opaque)
        XCTAssertFalse(t.usesLiquidGlass)
        XCTAssertGreaterThanOrEqual(t.minTarget, 64)
        XCTAssertGreaterThanOrEqual(t.buttonHeight, 64)
        XCTAssertGreaterThanOrEqual(t.mapButton, 64)
    }

    func testForcedFallbackNeverUsesGlass() {
        let t = SaryTheme.resolve(prefs: .init(), scheme: .dark, night: false, drive: false, forceGlassFallback: true)
        XCTAssertFalse(t.usesLiquidGlass)
    }

    func testNightForcesDarkPalette() {
        let t = SaryTheme.resolve(prefs: .init(), scheme: .light, night: true, drive: false)
        XCTAssertEqual(t.scheme, .dark)
        XCTAssertEqual(t.palette.raw.background, 0x0D0C0B)
    }

    func testBrandTokens() {
        let d = SaryPalette.dark()
        XCTAssertEqual(d.raw.background, 0x1A1612)
        XCTAssertEqual(d.raw.textPrimary, 0xF4EFE6)
        XCTAssertEqual(d.raw.textSecondary, 0xB9AE9C)
        XCTAssertEqual(SaryAccent.ember.fill, 0xE8842C)
    }

    func testTextContrastAA() {
        for (name, p) in [("dark", SaryPalette.dark()), ("light", SaryPalette.light()), ("night", SaryPalette.night())] {
            XCTAssertGreaterThanOrEqual(SaryContrast.ratio(p.raw.textPrimary, p.raw.background), 7, name)
            XCTAssertGreaterThanOrEqual(SaryContrast.ratio(p.raw.textSecondary, p.raw.background), 4.5, name)
            XCTAssertGreaterThanOrEqual(SaryContrast.ratio(p.raw.textSecondary, p.raw.surface), 4.5, name)
        }
        for a in SaryAccent.allCases {
            XCTAssertGreaterThanOrEqual(SaryContrast.ratio(a.lightText, SaryPalette.light().raw.background), 4.5, a.rawValue)
            XCTAssertGreaterThanOrEqual(SaryContrast.ratio(a.fill, 0x1A1612), 4.5, a.rawValue)
        }
    }

    /// Live numbers use tabular digits: every Arabic-Indic digit has the same advance.
    func testNumericFontIsTabular() {
        let font = UIFont.monospacedDigitSystemFont(ofSize: 20, weight: .bold)
        let widths = "٠١٢٣٤٥٦٧٨٩".map { ch in
            (String(ch) as NSString).size(withAttributes: [.font: font]).width
        }
        let spread = (widths.max() ?? 0) - (widths.min() ?? 0)
        XCTAssertLessThan(spread, 0.01, "widths: \(widths)")
    }
}
