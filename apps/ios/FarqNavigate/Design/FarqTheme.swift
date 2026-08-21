import SwiftUI

/// Farq's design system, ported from the web rather than approximated.
///
/// Every value here is read from `apps/web/src/styles/design-tokens.css` and the
/// map stylesheet beside it. Two implementations of a brand drift, and the one
/// that drifts is always the one fewer people look at — so where a number comes
/// from the web it says so, and changing it here without changing it there is a
/// bug rather than a preference.
enum Farq {
    // MARK: Colour — design-tokens.css

    /// `--brand-900: #043434` — the header, the deep surfaces, the ink on mint.
    static let brand900 = Color(hex: 0x043434)
    /// `--brand-700: #0A4A46` — pressed states, gradient end.
    static let brand700 = Color(hex: 0x0A4A46)
    /// `--brand-500: #2A6E62` — secondary icons.
    static let brand500 = Color(hex: 0x2A6E62)
    /// `--mint-500: #83F1B1` — the accent. Buttons and indicators only, never text.
    static let mint = Color(hex: 0x83F1B1)
    /// `--mint-700: #18A66A` — the high-contrast green, for text that must pass.
    static let mintStrong = Color(hex: 0x18A66A)
    /// `--amber-500: #FFCA3A` — caution, never failure.
    static let amber = Color(hex: 0xFFCA3A)

    /// `--ink: #0E2622`
    static let ink = Color(hex: 0x0E2622)
    /// `--ink-subtle: #4A5F5A`
    static let inkSubtle = Color(hex: 0x4A5F5A)
    /// `--ink-muted: #829691`
    static let inkMuted = Color(hex: 0x829691)
    /// `--surface-3: #F3F8F5` — inset and elevated surfaces.
    static let surfaceInset = Color(hex: 0xF3F8F5)
    /// The chip rail's unselected ground, from farq-mapbox.css.
    static let chipGround = Color(hex: 0xE6EEF0)

    // MARK: Type — Tajawal, the same family the web loads from Google Fonts

    static func font(_ size: CGFloat, _ weight: Weight = .regular) -> Font {
        .custom(weight.family, size: size)
    }

    enum Weight {
        case regular, medium, bold, extraBold
        var family: String {
            switch self {
            case .regular: return "Tajawal"
            case .medium: return "Tajawal-Medium"
            case .bold: return "Tajawal-Bold"
            case .extraBold: return "TajawalExtraBold"
            }
        }
    }

    // MARK: Shape

    /// The pill radius the web uses for every chip and control: `9999px`.
    static let pill: CGFloat = 999
    /// Cards and sheets.
    static let card: CGFloat = 20
    /// The web's minimum tap target, kept because a thumb is a thumb on both.
    static let tapTarget: CGFloat = 44
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

/// Arabic-Indic digits, because the web writes numbers that way and a price in
/// one script beside a price in another reads as two different products.
enum ArabicDigits {
    private static let map: [Character: Character] = [
        "0": "٠", "1": "١", "2": "٢", "3": "٣", "4": "٤",
        "5": "٥", "6": "٦", "7": "٧", "8": "٨", "9": "٩",
    ]

    static func localize(_ value: String, isRTL: Bool = true) -> String {
        guard isRTL else { return value }
        return String(value.map { map[$0] ?? $0 })
    }

    static func localize(_ value: Int, isRTL: Bool = true) -> String {
        localize(String(value), isRTL: isRTL)
    }
}
