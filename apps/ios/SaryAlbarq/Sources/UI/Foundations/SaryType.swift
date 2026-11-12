import SwiftUI

/// Build 46 type roles. One enum for screens to pick from; each role maps onto
/// the existing ramp (`SaryTextStyle`, Dynamic-Type relative) and a Huwiya
/// weight. Numbers use the system font, tabular, with Arabic-Indic digits
/// (format the string with `SaryFormat.digits`: «٢٤٫٥»).
///
/// Rules:
/// - At most `sizeBudget` (3) distinct sizes on one screen: `SaryType.withinBudget`.
/// - Light is for large text only (≥ 20 pt: display); never for captions.
/// - Never `lineLimit` + «…» on names: use `.saryLongName()`.
enum SaryType: String, CaseIterable {
    case display, title, headline, body, caption, numeric

    static let sizeBudget = 3

    var style: SaryTextStyle {
        switch self {
        case .display: return .display
        case .title: return .title
        case .headline: return .headline
        case .body: return .body
        case .caption: return .footnote
        case .numeric: return .title2
        }
    }

    var weight: SaryWeight {
        switch self {
        case .display: return .heavy      // Black
        case .title: return .bold
        case .headline: return .medium
        case .body: return .regular
        case .caption: return .medium
        case .numeric: return .bold
        }
    }

    var size: CGFloat { style.size }
    var isNumeric: Bool { self == .numeric }

    /// True when `roles` use at most `sizeBudget` distinct sizes.
    static func withinBudget(_ roles: [SaryType]) -> Bool {
        Set(roles.map(\.size)).count <= sizeBudget
    }
}

extension View {
    /// Applies a type role. `weight` overrides (e.g. `.light` on a large title).
    @ViewBuilder
    func saryType(_ role: SaryType, weight: SaryWeight? = nil) -> some View {
        if role.isNumeric {
            saryNumber(role.style, weight: weight ?? role.weight)
        } else {
            saryText(role.style, weight: weight ?? role.weight)
        }
    }

    /// Long names (places, people, outings) shrink a little instead of ending in «…».
    func saryLongName(lines: Int = 1, minScale: CGFloat = 0.6) -> some View {
        self.lineLimit(lines)
            .minimumScaleFactor(minScale)
            .allowsTightening(true)
    }
}
