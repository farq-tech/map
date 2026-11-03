import CoreText
import SwiftUI
import UIKit

// MARK: - Colours

/// Design tokens shared with the web ("dark sand" theme). Every view in
/// `Sources/UI` reads colours through `SaryPalette`, resolved for normal or
/// night mode from the environment (`\.saryNight`).
struct SaryPalette: Equatable {
    var background: Color
    var textPrimary: Color
    var textSecondary: Color
    /// Floating buttons and bars over the map: rgba(28,24,20,0.9) + blur.
    var floating: Color
    var accent: Color
    /// Text drawn on an accent fill (selected tab, primary button).
    var onAccent: Color
    var sheet: Color
    /// Cards and rows inside screens and the sheet.
    var card: Color
    var separator: Color
    var sos: Color
    var live: Color
    /// Grey for stale participants and anything that is "not live".
    var stale: Color
    var warning: Color

    static let normal = SaryPalette(
        background: Color(rgb: 0x1A1612),
        textPrimary: Color(rgb: 0xF4EFE6),
        textSecondary: Color(rgb: 0xB9AE9C),
        floating: Color(red: 28 / 255, green: 24 / 255, blue: 20 / 255, opacity: 0.9),
        accent: Color(rgb: 0xE8842C),
        onAccent: Color(rgb: 0x1A1612),
        sheet: Color(rgb: 0x221D18),
        card: Color(rgb: 0x2B251F),
        separator: Color(rgb: 0xF4EFE6).opacity(0.10),
        sos: Color(rgb: 0xD6452F),
        live: Color(rgb: 0x2FA56A),
        stale: Color(rgb: 0x8C8478),
        warning: Color(rgb: 0xF2B630)
    )

    /// Darker, dimmer, no glare in the desert night.
    static let night = SaryPalette(
        background: Color(rgb: 0x0D0C0B),
        textPrimary: Color(rgb: 0xDCD4C6),
        textSecondary: Color(rgb: 0x958B7C),
        floating: Color(red: 13 / 255, green: 12 / 255, blue: 11 / 255, opacity: 0.92),
        accent: Color(rgb: 0xC46F25),
        onAccent: Color(rgb: 0x0D0C0B),
        sheet: Color(rgb: 0x0D0C0B),
        card: Color(rgb: 0x181512),
        separator: Color(rgb: 0xDCD4C6).opacity(0.08),
        sos: Color(rgb: 0xB93B28),
        live: Color(rgb: 0x268A58),
        stale: Color(rgb: 0x6E675D),
        warning: Color(rgb: 0xC99A2A)
    )
}

extension Color {
    /// `0xRRGGBB` → Color.
    init(rgb: UInt32, opacity: Double = 1) {
        self.init(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255,
            opacity: opacity
        )
    }
}

/// Participants' car colours, in join order. Same list and order as the web
/// (`carColors.ts`) and `Core/CarColors.palette` (a unit test keeps them equal).
enum SaryCarColors {
    static let palette: [UInt32] = [
        0xE8EEF0, 0xD6452F, 0x2F6FD6, 0xF2B630, 0x2FA56A,
        0x8A4FD1, 0xF07F2F, 0x1FB8C4, 0xE05A9C, 0x15191C,
    ]

    /// Colour for the participant who joined at `index` (0 = first), wrapping.
    static func color(forJoinIndex index: Int) -> UInt32 {
        let n = palette.count
        return palette[((index % n) + n) % n]
    }

    /// Dark ink on light cars, light ink on dark ones.
    static func isLight(_ rgb: UInt32) -> Bool {
        let r = Double((rgb >> 16) & 0xFF), g = Double((rgb >> 8) & 0xFF), b = Double(rgb & 0xFF)
        return (0.299 * r + 0.587 * g + 0.114 * b) > 150
    }

    static func ink(on rgb: UInt32) -> Color {
        isLight(rgb) ? Color(rgb: 0x15191C) : Color(rgb: 0xF4EFE6)
    }
}

// MARK: - Environment: night / drive

private struct SaryNightKey: EnvironmentKey { static let defaultValue = false }
private struct SaryDriveKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// Night mode resolved by the wiring layer (automatic/on/off → Bool).
    var saryNight: Bool {
        get { self[SaryNightKey.self] }
        set { self[SaryNightKey.self] = newValue }
    }

    /// Drive mode resolved by the wiring layer: bigger targets and text.
    var saryDrive: Bool {
        get { self[SaryDriveKey.self] }
        set { self[SaryDriveKey.self] = newValue }
    }

    var saryPalette: SaryPalette { saryNight ? .night : .normal }
}

extension View {
    /// Apply once at the root (and on any sheet/fullScreenCover you present):
    /// RTL, Arabic locale, dark scheme, Tajawal registered, night/drive flags.
    func saryTheme(night: Bool = false, drive: Bool = false) -> some View {
        SaryFonts.registerIfNeeded()
        return self
            .environment(\.saryNight, night)
            .environment(\.saryDrive, drive)
            .modifier(SaryChrome())
    }

    /// Used by every screen's body so a screen is RTL/Arabic even when presented
    /// in a sheet that does not inherit the environment.
    func saryScreenChrome() -> some View { modifier(SaryChrome()) }
}

private struct SaryChrome: ViewModifier {
    @Environment(\.saryPalette) private var palette
    func body(content: Content) -> some View {
        SaryFonts.registerIfNeeded()
        return content
            .environment(\.layoutDirection, .rightToLeft)
            .environment(\.locale, Locale(identifier: "ar"))
            .preferredColorScheme(.dark)
            .tint(palette.accent)
    }
}

// MARK: - Metrics

/// Sizes that change with drive mode.
struct SaryMetrics {
    var drive: Bool
    /// Minimum touch target: 44 pt, 54 pt while driving.
    var target: CGFloat { drive ? 54 : 44 }
    /// Floating round map buttons.
    var mapButton: CGFloat { drive ? 60 : 48 }
    /// SOS / push-to-talk.
    var bigButton: CGFloat { drive ? 76 : 64 }
    var cornerSmall: CGFloat { 14 }
    var corner: CGFloat { 18 }
    var cornerLarge: CGFloat { 22 }
    var fontScale: CGFloat { drive ? 1.2 : 1 }
}

extension EnvironmentValues {
    var saryMetrics: SaryMetrics { SaryMetrics(drive: saryDrive) }
}

// MARK: - Motion

enum SaryMotion {
    /// Gentle spring, 0.26 s. Nil (no animation) under Reduce Motion.
    static func spring(_ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .spring(response: 0.26, dampingFraction: 0.86)
    }
}

// MARK: - Typography (Tajawal, Dynamic Type)

enum SaryFonts {
    static let files = ["Tajawal-Regular", "Tajawal-Medium", "Tajawal-Bold", "Tajawal-ExtraBold"]

    private static let registered: Bool = {
        for name in files {
            guard let url = Bundle.main.url(forResource: name, withExtension: "ttf") else { continue }
            // Already-registered (e.g. via UIAppFonts) returns an error we can ignore.
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        return true
    }()

    /// Idempotent; safe to call from any view body.
    @discardableResult
    static func registerIfNeeded() -> Bool { registered }
}

enum SaryWeight {
    case regular, medium, bold, heavy
    var postScript: String {
        switch self {
        case .regular: return "Tajawal-Regular"
        case .medium: return "Tajawal-Medium"
        case .bold: return "Tajawal-Bold"
        case .heavy: return "Tajawal-ExtraBold"
        }
    }
}

extension Font {
    /// Tajawal at `size`, scaling with Dynamic Type relative to `style`.
    static func sary(_ size: CGFloat, _ weight: SaryWeight = .regular, relativeTo style: Font.TextStyle = .body) -> Font {
        SaryFonts.registerIfNeeded()
        return .custom(weight.postScript, size: size, relativeTo: style)
    }

    static var saryLargeTitle: Font { .sary(30, .heavy, relativeTo: .largeTitle) }
    static var saryTitle: Font { .sary(22, .bold, relativeTo: .title2) }
    static var saryHeadline: Font { .sary(17, .bold, relativeTo: .headline) }
    static var saryBody: Font { .sary(16, .regular, relativeTo: .body) }
    static var saryBodyBold: Font { .sary(16, .bold, relativeTo: .body) }
    static var sarySubhead: Font { .sary(14, .medium, relativeTo: .subheadline) }
    static var saryCaption: Font { .sary(12.5, .medium, relativeTo: .caption) }
}

/// Font that grows in drive mode.
struct SaryText: ViewModifier {
    @Environment(\.saryDrive) private var drive
    var size: CGFloat
    var weight: SaryWeight
    var style: Font.TextStyle
    func body(content: Content) -> some View {
        content.font(.sary(size * (drive ? 1.2 : 1), weight, relativeTo: style))
    }
}

extension View {
    func saryFont(_ size: CGFloat, _ weight: SaryWeight = .regular, relativeTo style: Font.TextStyle = .body) -> some View {
        modifier(SaryText(size: size, weight: weight, style: style))
    }
}
