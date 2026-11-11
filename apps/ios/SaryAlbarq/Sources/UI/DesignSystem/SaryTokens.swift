import CoreText
import SwiftUI
import UIKit

// MARK: - Typography

/// ITF Huwiya Arabic (bundled from Farq) registered at runtime.
enum SaryFonts {
    static let files = ["itfHuwiyaArabic-Regular", "itfHuwiyaArabic-Medium", "itfHuwiyaArabic-Bold", "itfHuwiyaArabic-Black"]

    private static let registered: Bool = {
        for name in files {
            guard let url = Bundle.main.url(forResource: name, withExtension: "otf") else { continue }
            // Already registered returns an error we can ignore.
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        return true
    }()

    /// Idempotent; safe from any view body.
    @discardableResult
    static func registerIfNeeded() -> Bool { registered }
}

enum SaryWeight: CaseIterable {
    case regular, medium, bold, heavy

    var postScript: String {
        switch self {
        case .regular: return "itfHuwiyaArabic-Regular"
        case .medium: return "itfHuwiyaArabic-Medium"
        case .bold: return "itfHuwiyaArabic-Bold"
        case .heavy: return "itfHuwiyaArabic-Black"
        }
    }

    var system: Font.Weight {
        switch self {
        case .regular: return .regular
        case .medium: return .medium
        case .bold: return .semibold
        case .heavy: return .bold
        }
    }
}

/// The type ramp. Every style scales with Dynamic Type (relative to a system
/// text style) and grows 15 % in drive mode.
enum SaryTextStyle: String, CaseIterable {
    case display, title, title2, headline, body, bodyStrong, callout, subhead, footnote, caption, micro

    var size: CGFloat {
        switch self {
        case .display: return 34
        case .title: return 26
        case .title2: return 21
        case .headline: return 17
        case .body: return 16
        case .bodyStrong: return 16
        case .callout: return 15
        case .subhead: return 14
        case .footnote: return 13
        case .caption: return 12
        case .micro: return 11
        }
    }

    var weight: SaryWeight {
        switch self {
        case .display: return .heavy
        case .title, .title2, .headline, .bodyStrong: return .bold
        case .body: return .regular
        case .callout, .subhead, .footnote: return .medium
        case .caption, .micro: return .bold
        }
    }

    var relativeTo: Font.TextStyle {
        switch self {
        case .display: return .largeTitle
        case .title: return .title
        case .title2: return .title2
        case .headline: return .headline
        case .body, .bodyStrong: return .body
        case .callout: return .callout
        case .subhead: return .subheadline
        case .footnote: return .footnote
        case .caption: return .caption
        case .micro: return .caption2
        }
    }

    var label: String { rawValue }
}

extension Font {
    /// ITF Huwiya Arabic at `size`, scaling with Dynamic Type relative to `style`.
    static func sary(_ size: CGFloat, _ weight: SaryWeight = .regular, relativeTo style: Font.TextStyle = .body) -> Font {
        SaryFonts.registerIfNeeded()
        return .custom(weight.postScript, size: size, relativeTo: style)
    }

    /// Numbers that update live (distances, timers, battery): the system font
    /// (SF Arabic covers Arabic-Indic digits) with tabular figures, because
    /// Huwiya's digits are proportional and would jitter while ticking.
    /// `size` is already scaled — use `.saryNumber(_:)` in views.
    static func saryNumeric(scaled size: CGFloat, _ weight: SaryWeight = .bold) -> Font {
        .system(size: size, weight: weight.system).monospacedDigit()
    }
}

extension Font.TextStyle {
    var uiKit: UIFont.TextStyle {
        switch self {
        case .largeTitle: return .largeTitle
        case .title: return .title1
        case .title2: return .title2
        case .title3: return .title3
        case .headline: return .headline
        case .subheadline: return .subheadline
        case .callout: return .callout
        case .footnote: return .footnote
        case .caption: return .caption1
        case .caption2: return .caption2
        default: return .body
        }
    }
}

// MARK: - Spacing / radius / sizes

/// 4-pt spacing scale. `SaryTheme.space(_:)` applies the density setting.
enum SarySpace: CGFloat, CaseIterable {
    case xxs = 2, xs = 4, s = 8, m = 12, l = 16, xl = 20, xxl = 24, xxxl = 32
}

enum SaryRadius {
    static let xs: CGFloat = 8
    static let s: CGFloat = 12
    static let m: CGFloat = 16
    static let l: CGFloat = 22
    static let xl: CGFloat = 28
    /// Sheet top corners.
    static let sheet: CGFloat = 30
}

/// Elevation tokens. Glass surfaces carry their own depth on iOS 26; these
/// are used for the material fallback, opaque chrome and cards.
enum SaryShadow: CaseIterable {
    case none, raised, floating, overlay

    func radius() -> CGFloat {
        switch self {
        case .none: return 0
        case .raised: return 4
        case .floating: return 12
        case .overlay: return 24
        }
    }

    func y() -> CGFloat {
        switch self {
        case .none: return 0
        case .raised: return 1
        case .floating: return 4
        case .overlay: return 10
        }
    }

    func opacity() -> Double {
        switch self {
        case .none: return 0
        case .raised: return 0.5
        case .floating: return 0.8
        case .overlay: return 1
        }
    }
}

extension View {
    func saryShadow(_ s: SaryShadow, _ theme: SaryTheme) -> some View {
        shadow(color: theme.palette.shadow.opacity(s.opacity()), radius: s.radius(), x: 0, y: s.y())
    }
}

// MARK: - Motion

/// Motion tokens. Always go through `SaryTheme.animation(_:)` so the Reduce
/// Motion setting (system or the app's own motion preference) is respected:
/// under reduced motion, movement becomes a short cross-fade.
enum SaryMotion {
    /// Taps, toggles, small state changes.
    case snappy
    /// Layout changes: cluster morph, sheet content, expanding capsule.
    case smooth
    /// Things entering from off-screen (alert cards, strips).
    case enter
    /// Emergency: quick and decisive.
    case urgent

    var animation: Animation {
        switch self {
        case .snappy: return .spring(response: 0.28, dampingFraction: 0.86)
        case .smooth: return .spring(response: 0.42, dampingFraction: 0.88)
        case .enter: return .spring(response: 0.5, dampingFraction: 0.82)
        case .urgent: return .spring(response: 0.22, dampingFraction: 0.92)
        }
    }

    static let reduced: Animation = .easeInOut(duration: 0.18)
}

// MARK: - Icons (SF Symbols)

/// One place for every symbol, so the same idea always uses the same glyph.
enum SaryIcon {
    static let back = "chevron.backward" // auto-mirrors in RTL
    static let close = "xmark"
    static let locate = "location.fill"
    static let locateFollow = "location.north.line.fill"
    static let fitGroup = "person.3.fill"
    static let note = "text.bubble.fill"
    static let nearest = "fuelpump.fill"
    static let layers = "square.3.layers.3d"
    static let compass = "safari"
    static let sos = "sos"
    static let mic = "mic.fill"
    static let send = "arrow.up"
    static let play = "play.fill"
    static let stop = "stop.fill"
    static let rally = "flag.fill"
    /// «طريق العودة» (back along my trail).
    static let backTrack = "arrow.uturn.backward"
    static let rallyArrived = "flag.checkered"
    static let drift = "arrow.up.right.and.arrow.down.left"
    static let warning = "exclamationmark.triangle.fill"
    static let connection = "antenna.radiowaves.left.and.right"
    static let gps = "location.fill"
    static let gpsOff = "location.slash.fill"
    static let internet = "network"
    static let offline = "wifi.slash"
    static let pause = "pause.fill"
    static let phone = "phone.fill"
    static let message = "message.fill"
    static let showOnMap = "scope"
    static let directions = "arrow.triangle.turn.up.right.diamond.fill"
    static let share = "square.and.arrow.up"
    static let copy = "doc.on.doc"
    static let settings = "gearshape.fill"
    static let car = "car.fill"
    static let drive = "steeringwheel"
    static let night = "moon.stars.fill"
    static let check = "checkmark"
    static let checkCircle = "checkmark.circle.fill"
    static let retry = "arrow.clockwise"
    static let empty = "tray"
    static let error = "exclamationmark.circle.fill"
    static let crown = "crown.fill"
    static let shield = "shield.lefthalf.filled"

    static func battery(_ percent: Int) -> String {
        switch percent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}
