import SwiftUI

// Build 47 «شاشات الطلعة» (group A) behind `NewUI.enabled`: the page skeleton every restyled screen of the
// outing lifecycle shares, built only from the Build 46 foundations (`SaryWindowTitle`-style header, the 58 pt
// primary / 52 pt secondary buttons, glass surfaces, `SaryType` roles). When the shared components fork publishes
// `docs/UI-COMPONENTS.md`, this file shrinks to thin wrappers over those components; the screens keep calling it.
//
// Rules of the designer prompt (§٣) that this skeleton enforces for every screen:
//  - one window header: big title on the right (RTL leading), a 44 pt circular ✕ on the left (or a back chevron);
//  - ONE primary button (Ember, 58 pt, full width) pinned at the bottom, secondary buttons under it;
//  - content scrolls above the pinned actions and never sits under them.

/// The leading control of a header: nothing, a back chevron (steps of a flow) or the ✕ (windows).
enum NewUIHeaderControl {
    case none
    case back(id: String = "page-back", action: () -> Void)
    case close(id: String = "page-close", action: () -> Void)
}

/// The unified window header (title right, control left). Titles shrink instead of ending in «…».
struct NewUIHeader: View {
    var title: String
    var subtitle: String? = nil
    var back: (() -> Void)? = nil
    var backID = "page-back"
    var close: (() -> Void)? = nil
    var closeID = "page-close"
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        HStack(spacing: SarySpace.m.rawValue) {
            if let back {
                circle(SaryIcon.back, "رجوع", backID, back)
            }
            VStack(alignment: .leading, spacing: SarySpace.xs.rawValue) {
                Text(title)
                    .saryType(.title)
                    .saryLongName(lines: 2, minScale: 0.65)
                    .foregroundStyle(p.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle)
                        .saryType(.body)
                        .saryLongName(lines: 2, minScale: 0.8)
                        .foregroundStyle(p.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading) // leading = right in RTL
            if let close {
                circle(SaryIcon.close, "إغلاق", closeID, close)
            }
        }
        .padding(.horizontal, SarySpace.l.rawValue)
        .padding(.top, SarySpace.m.rawValue)
        .padding(.bottom, SarySpace.s.rawValue)
        .saryReadableWidth()
    }

    private func circle(_ symbol: String, _ label: String, _ id: String, _ action: @escaping () -> Void) -> some View {
        let p = theme.palette
        return Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(p.textPrimary)
                .frame(width: SaryMetrics.minHit, height: SaryMetrics.minHit)
                .background(Circle().fill(p.surface))
                .overlay(Circle().strokeBorder(p.stroke, lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }
}

/// A restyled page: themed background, `NewUIHeader`, scrolling content, and the pinned actions area
/// (the one primary button + secondaries). On a short screen (SE) the content scrolls; the actions never do.
struct NewUIPage<Content: View, Actions: View>: View {
    var title: String
    var subtitle: String? = nil
    var back: (() -> Void)? = nil
    var backID = "page-back"
    var close: (() -> Void)? = nil
    var closeID = "page-close"
    var scrolls = true
    /// False when a screen pins its own bottom bar (the create wizard's invite step): no empty actions strip.
    var hasActions = true
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        VStack(spacing: 0) {
            NewUIHeader(title: title, subtitle: subtitle, back: back, backID: backID, close: close, closeID: closeID)
            if scrolls {
                ScrollView {
                    VStack(alignment: .leading, spacing: SarySpace.l.rawValue) { content }
                        .padding(.horizontal, SarySpace.l.rawValue)
                        .padding(.top, SarySpace.s.rawValue)
                        .padding(.bottom, SarySpace.l.rawValue)
                        .saryReadableWidth()
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollDismissesKeyboard(.interactively)
            } else {
                content
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if hasActions { NewUIActions { actions } }
        }
        .background(p.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }
}

extension NewUIPage where Actions == EmptyView {
    init(title: String, subtitle: String? = nil, back: (() -> Void)? = nil, close: (() -> Void)? = nil, scrolls: Bool = true,
         @ViewBuilder content: () -> Content) {
        self.init(title: title, subtitle: subtitle, back: back, close: close, scrolls: scrolls, hasActions: false, content: content, actions: { EmptyView() })
    }
}

/// The pinned actions area: primary (58) first, secondaries (52) under it, 12 pt apart, 16 pt from the edges.
struct NewUIActions<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.sary) private var theme

    var body: some View {
        VStack(spacing: SarySpace.m.rawValue) { content }
            .padding(.horizontal, SarySpace.l.rawValue)
            .padding(.top, SarySpace.m.rawValue)
            .padding(.bottom, SarySpace.l.rawValue)
            .frame(maxWidth: .infinity)
            .background(theme.palette.background.ignoresSafeArea(edges: .bottom))
            .saryReadableWidth()
    }
}

/// A glass card for grouped content (the designer's floating surface at card radius).
struct NewUICard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        SaryGlassSurface(radius: SaryRadius.card, padding: SarySpace.l.rawValue) {
            VStack(alignment: .leading, spacing: SarySpace.m.rawValue) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// «أيقونة + سطر» used in explainer cards: a 40 pt icon circle and a body line.
struct NewUIPoint: View {
    var systemImage: String
    var text: String
    @Environment(\.sary) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: SarySpace.m.rawValue) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(theme.palette.accentText)
                .frame(width: SaryMetrics.iconCircle, height: SaryMetrics.iconCircle)
                .background(Circle().fill(theme.palette.sunken))
                .accessibilityHidden(true)
            Text(text)
                .saryType(.body)
                .foregroundStyle(theme.palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
