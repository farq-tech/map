import SwiftUI

// Build 47 · screens group B (information screens). The unified window header of the new interface:
// a big title on the right (RTL leading), an optional subtitle under it, the page's own trailing buttons,
// and ONE round ✕ (44 pt) on the left. Back pages keep the back chevron on the right and no ✕.
// Same accessibility ids as the legacy header (`page-close`, `page-back`) so every existing test keeps working.
// Used by `SaryPage` only when `NewUI.enabled`.

struct NewPageHeader<Trailing: View>: View {
    var title: String
    var subtitle: String?
    var back: (() -> Void)?
    var close: (() -> Void)?
    var closeID = "page-close"
    @ViewBuilder var trailing: Trailing
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        HStack(alignment: .center, spacing: theme.space(.s)) {
            if let back {
                SaryIconButton(systemImage: SaryIcon.back, label: "رجوع", id: "page-back", action: back)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .saryType(.title)
                    .saryLongName(lines: 1, minScale: 0.65)
                    .foregroundStyle(p.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle)
                        .saryType(.caption)
                        .saryLongName(lines: 2, minScale: 0.85)
                        .foregroundStyle(p.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            trailing
            if let close {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(p.textPrimary)
                        .frame(width: SaryMetrics.minHit, height: SaryMetrics.minHit)
                        .background(Circle().fill(p.surface))
                        .overlay(Circle().strokeBorder(p.stroke, lineWidth: 1))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("إغلاق")
                .accessibilityIdentifier(closeID)
            }
        }
        .padding(.horizontal, theme.space(.l))
        .padding(.top, theme.space(.m))
        .padding(.bottom, theme.space(.s))
    }
}

/// Row height of the new interface (designer prompt: rows share one height). The legacy value stays when the flag is off.
enum NewScreens {
    static func rowMinHeight(legacy: CGFloat) -> CGFloat { NewUI.enabled ? SaryMetrics.rowHeight : legacy }

    /// «اتجه» on a camp suggestion: the primary button only on the first one (one primary per screen) when the new UI is on.
    static func campGoIsPrimary(rank: Int, newUI: Bool = NewUI.enabled) -> Bool { !newUI || rank == 1 }
}
