import SwiftUI
import UIKit

// MARK: - Colour primitives

extension Color {
    /// `0xRRGGBB` → Color (sRGB).
    init(rgb: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255,
            opacity: opacity
        )
    }
}

/// Relative luminance / contrast helpers (WCAG 2.x), used by the car-colour
/// ink choice and by the token contrast tests.
enum SaryContrast {
    static func luminance(_ rgb: UInt32) -> Double {
        func ch(_ v: UInt32) -> Double {
            let c = Double(v) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * ch((rgb >> 16) & 0xFF) + 0.7152 * ch((rgb >> 8) & 0xFF) + 0.0722 * ch(rgb & 0xFF)
    }

    static func ratio(_ a: UInt32, _ b: UInt32) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
}

// MARK: - Participant car colours

/// Participants' car colours in join order. Same list and order as the web
/// (`apps/web/src/lib/outings/carColors.ts`) and `Core/CarColors.palette`;
/// `SaryFormatTests` keeps all three equal. The owner's spec lists the first
/// ten; the web carries two more (silver, brown) for outings with >10 cars,
/// so they are kept here too — otherwise car 11 would get a different colour
/// on iOS than on the web.
enum SaryCarColors {
    static let palette: [UInt32] = [
        0xE8EEF0, // white
        0xD6452F, // red
        0x2F6FD6, // blue
        0xF2B630, // yellow
        0x2FA56A, // green
        0x8A4FD1, // purple
        0xF07F2F, // orange
        0x1FB8C4, // teal
        0xE05A9C, // pink
        0x15191C, // black
        0x9AA5AD, // silver
        0x7A5230, // brown
    ]

    /// Arabic colour names, for VoiceOver («السيارة الحمراء»).
    static let names: [String] = [
        "أبيض", "أحمر", "أزرق", "أصفر", "أخضر", "بنفسجي", "برتقالي", "فيروزي", "وردي", "أسود", "فضي", "بني",
    ]

    /// Colour for the participant who joined at `index` (0 = first), wrapping.
    static func color(forJoinIndex index: Int) -> UInt32 {
        let n = palette.count
        return palette[((index % n) + n) % n]
    }

    static func name(for rgb: UInt32) -> String? {
        palette.firstIndex(of: rgb).map { names[$0] }
    }

    /// Light car colours get dark ink, dark ones light ink (best WCAG contrast).
    static func isLight(_ rgb: UInt32) -> Bool {
        SaryContrast.ratio(rgb, 0x15191C) >= SaryContrast.ratio(rgb, 0xFFFFFF)
    }

    static func ink(on rgb: UInt32) -> Color {
        isLight(rgb) ? Color(rgb: 0x15191C) : Color(rgb: 0xFFFFFF)
    }

    /// Very light (white) and very dark (black) cars need an outline to read
    /// on light sand / dark night maps respectively.
    static func needsOutline(_ rgb: UInt32, onDark: Bool) -> Bool {
        let l = SaryContrast.luminance(rgb)
        return onDark ? l < 0.05 : l > 0.7
    }
}

// MARK: - Accent choices (customisation)

/// The accents a person may pick in Appearance settings. Ember (#E8842C) is
/// the brand default. Each has a fill (buttons, selection) and a text tone that
/// keeps ≥ 4.5:1 on the light "day desert" background.
enum SaryAccent: String, CaseIterable, Codable, Identifiable {
    case ember, saffron, sky, rose

    var id: String { rawValue }

    var label: String {
        switch self {
        case .ember: return "جمر"
        case .saffron: return "زعفران"
        case .sky: return "سماء"
        case .rose: return "ورد طائفي"
        }
    }

    /// Fill on dark backgrounds (and on light, with dark ink).
    var fill: UInt32 {
        switch self {
        case .ember: return 0xE8842C
        case .saffron: return 0xE0A43A
        case .sky: return 0x4C8FD6
        case .rose: return 0xD0668C
        }
    }

    /// Dimmed fill for night mode (keeps dark-adapted eyes).
    var nightFill: UInt32 {
        switch self {
        case .ember: return 0xB8661F
        case .saffron: return 0xAA7C2A
        case .sky: return 0x3A6EA6
        case .rose: return 0xA0506D
        }
    }

    /// Accent used as text/icon on the light background.
    var lightText: UInt32 {
        switch self {
        case .ember: return 0x9E4C0B
        case .saffron: return 0x7E570C
        case .sky: return 0x245E9E
        case .rose: return 0x9C3A5E
        }
    }
}

// MARK: - Palette

/// Every colour a component may use, already resolved for the current
/// appearance (light / dark / night) and drive mode. Components never use raw
/// hex values; they read `@Environment(\.sary).palette`.
struct SaryPalette: Equatable {
    /// Screen background.
    var background: Color
    /// Sheets and pushed screens over the background.
    var elevated: Color
    /// Cards and rows.
    var surface: Color
    /// Text fields, wells, track of progress bars.
    var sunken: Color
    var separator: Color
    /// Hairline around floating surfaces.
    var stroke: Color

    var textPrimary: Color
    var textSecondary: Color
    var textTertiary: Color

    /// Accent fill (primary buttons, selection).
    var accent: Color
    /// Accent as text / icon on `background`.
    var accentText: Color
    /// Ink on an accent fill.
    var onAccent: Color

    var emergency: Color
    /// Emergency as text/icon on `background`.
    var emergencyText: Color
    var onEmergency: Color
    var live: Color
    var liveText: Color
    var warning: Color
    var warningText: Color
    /// Ink on a `warning` fill (hazard badges).
    var onWarning: Color
    /// Navigation blue: the route line, maneuver arrows and nav selection.
    /// Dimmed at night like the accent.
    var navBlue: Color
    /// Ink on a `navBlue` fill.
    var onNavBlue: Color
    /// Grey for anything that is NOT live (stale, paused, unknown).
    var stale: Color

    /// Floating chrome when glass is not used (fallback / opaque / drive).
    var chromeOpaque: Color
    /// Tint laid over a material in the translucent fallback.
    var chromeTint: Color
    /// Scrim behind dialogs and full-screen alerts.
    var scrim: Color
    var shadow: Color

    /// Raw values kept for contrast tests.
    var raw: Raw

    struct Raw: Equatable {
        var background: UInt32
        var textPrimary: UInt32
        var textSecondary: UInt32
        var accentText: UInt32
        var surface: UInt32
        var chromeOpaque: UInt32
        var warningText: UInt32
        var navBlue: UInt32
        var onNavBlue: UInt32
    }

    /// Navigation blue for day / dark (also the route-line colour on the map).
    static let navBlueDay: UInt32 = 0x2B7BF0
    /// Dimmed navigation blue for desert night.
    static let navBlueNight: UInt32 = 0x2463BF

    // MARK: Dark Sand (default)

    static func dark(accent: SaryAccent = .ember) -> SaryPalette {
        SaryPalette(
            background: Color(rgb: 0x1A1612),
            elevated: Color(rgb: 0x221D18),
            surface: Color(rgb: 0x2B251F),
            sunken: Color(rgb: 0x14110E),
            separator: Color(rgb: 0xF4EFE6, opacity: 0.10),
            stroke: Color(rgb: 0xF4EFE6, opacity: 0.12),
            textPrimary: Color(rgb: 0xF4EFE6),
            textSecondary: Color(rgb: 0xB9AE9C),
            textTertiary: Color(rgb: 0x8C8478),
            accent: Color(rgb: accent.fill),
            accentText: Color(rgb: accent.fill),
            onAccent: Color(rgb: 0x1A1612),
            emergency: Color(rgb: 0xD6452F),
            emergencyText: Color(rgb: 0xF06A52),
            onEmergency: Color(rgb: 0xFFFFFF),
            live: Color(rgb: 0x2FA56A),
            liveText: Color(rgb: 0x45C083),
            warning: Color(rgb: 0xF2B630),
            warningText: Color(rgb: 0xF2B630),
            onWarning: Color(rgb: 0x1A1612),
            navBlue: Color(rgb: SaryPalette.navBlueDay),
            onNavBlue: Color(rgb: 0xFFFFFF),
            stale: Color(rgb: 0x8C8478),
            chromeOpaque: Color(rgb: 0x241F1A),
            chromeTint: Color(rgb: 0x1C1814, opacity: 0.55),
            scrim: Color.black.opacity(0.55),
            shadow: Color.black.opacity(0.35),
            raw: .init(background: 0x1A1612, textPrimary: 0xF4EFE6, textSecondary: 0xB9AE9C,
                       accentText: accent.fill, surface: 0x2B251F, chromeOpaque: 0x241F1A,
                       warningText: 0xF2B630, navBlue: SaryPalette.navBlueDay, onNavBlue: 0xFFFFFF)
        )
    }

    // MARK: Day desert (light, for direct sun)

    static func light(accent: SaryAccent = .ember) -> SaryPalette {
        SaryPalette(
            background: Color(rgb: 0xF5EFE4),
            elevated: Color(rgb: 0xFBF7F0),
            surface: Color(rgb: 0xFFFFFF),
            sunken: Color(rgb: 0xEDE5D7),
            separator: Color(rgb: 0x2A2218, opacity: 0.10),
            stroke: Color(rgb: 0x2A2218, opacity: 0.10),
            textPrimary: Color(rgb: 0x1F1A14),
            textSecondary: Color(rgb: 0x5C5244),
            // 0x6E6457: ≥ 4.5:1 on every light surface (0x7D7263 was 4.1:1 on `background`, 3.8:1 on `sunken`).
            textTertiary: Color(rgb: 0x6E6457),
            accent: Color(rgb: accent.fill),
            accentText: Color(rgb: accent.lightText),
            onAccent: Color(rgb: 0x1A1612),
            emergency: Color(rgb: 0xC93A24),
            emergencyText: Color(rgb: 0xB0301C),
            onEmergency: Color(rgb: 0xFFFFFF),
            live: Color(rgb: 0x23915A),
            liveText: Color(rgb: 0x1A7347),
            warning: Color(rgb: 0xE2A11C),
            warningText: Color(rgb: 0x8A5C00),
            onWarning: Color(rgb: 0x1F1A14),
            navBlue: Color(rgb: SaryPalette.navBlueDay),
            onNavBlue: Color(rgb: 0xFFFFFF),
            stale: Color(rgb: 0x8A8072),
            chromeOpaque: Color(rgb: 0xFFFCF6),
            chromeTint: Color(rgb: 0xFFFBF3, opacity: 0.55),
            scrim: Color.black.opacity(0.40),
            shadow: Color(rgb: 0x3A2A14, opacity: 0.18),
            raw: .init(background: 0xF5EFE4, textPrimary: 0x1F1A14, textSecondary: 0x5C5244,
                       accentText: accent.lightText, surface: 0xFFFFFF, chromeOpaque: 0xFFFCF6,
                       warningText: 0x8A5C00, navBlue: SaryPalette.navBlueDay, onNavBlue: 0xFFFFFF)
        )
    }

    // MARK: Desert night (dim, warm, no glare)

    static func night(accent: SaryAccent = .ember) -> SaryPalette {
        SaryPalette(
            background: Color(rgb: 0x0D0C0B),
            elevated: Color(rgb: 0x13110F),
            surface: Color(rgb: 0x1A1714),
            sunken: Color(rgb: 0x090807),
            separator: Color(rgb: 0xDCD4C6, opacity: 0.08),
            stroke: Color(rgb: 0xDCD4C6, opacity: 0.10),
            textPrimary: Color(rgb: 0xDCD4C6),
            textSecondary: Color(rgb: 0x9C9282),
            textTertiary: Color(rgb: 0x746B5F),
            accent: Color(rgb: accent.nightFill),
            accentText: Color(rgb: accent.fill),
            onAccent: Color(rgb: 0x0D0C0B),
            emergency: Color(rgb: 0xB93B28),
            emergencyText: Color(rgb: 0xE0604A),
            onEmergency: Color(rgb: 0xF4EFE6),
            live: Color(rgb: 0x268A58),
            liveText: Color(rgb: 0x3BAA74),
            warning: Color(rgb: 0xC99A2A),
            warningText: Color(rgb: 0xC99A2A),
            onWarning: Color(rgb: 0x0D0C0B),
            navBlue: Color(rgb: SaryPalette.navBlueNight),
            onNavBlue: Color(rgb: 0xF4EFE6),
            stale: Color(rgb: 0x6E675D),
            chromeOpaque: Color(rgb: 0x15130F),
            chromeTint: Color(rgb: 0x0D0C0B, opacity: 0.62),
            scrim: Color.black.opacity(0.65),
            shadow: Color.black.opacity(0.5),
            raw: .init(background: 0x0D0C0B, textPrimary: 0xDCD4C6, textSecondary: 0x9C9282,
                       accentText: accent.fill, surface: 0x1A1714, chromeOpaque: 0x15130F,
                       warningText: 0xC99A2A, navBlue: SaryPalette.navBlueNight, onNavBlue: 0xF4EFE6)
        )
    }

    /// Drive mode: secondary text closer to primary, stronger strokes. Drive
    /// surfaces are opaque (no glass) — that is decided by `SaryTheme`.
    func driveAdjusted(light: Bool) -> SaryPalette {
        var p = self
        p.textSecondary = light ? Color(rgb: 0x3D352B) : Color(rgb: 0xD9CFBF)
        p.textTertiary = light ? Color(rgb: 0x5C5244) : Color(rgb: 0xB9AE9C)
        p.stroke = light ? Color(rgb: 0x2A2218, opacity: 0.22) : Color(rgb: 0xF4EFE6, opacity: 0.22)
        p.raw.textSecondary = light ? 0x3D352B : 0xD9CFBF
        return p
    }
}
