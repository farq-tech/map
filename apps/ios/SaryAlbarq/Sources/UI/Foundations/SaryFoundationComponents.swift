import SwiftUI

// Build 46 foundation components. Colours/metrics come from `@Environment(\.sary)`
// and the tokens in `SaryTokens`; nothing here uses raw hex except the glass recipe
// above. Every interactive piece is >= 44 pt and RTL-safe.

enum SaryMetrics {
    /// Designer prompt: the one primary button per screen is 58 pt tall.
    static let primaryHeight: CGFloat = 58
    static let secondaryHeight: CGFloat = 52
    static let minHit: CGFloat = 44
    static let rowHeight: CGFloat = 56
    static let iconCircle: CGFloat = 40
}

// MARK: - Glass surface

/// Floating dark glass: translucent fill + blur + hairline + soft shadow.
/// Opaque in drive mode / increased contrast (via the theme).
struct SaryGlassSurface<Content: View>: View {
    var radius: CGFloat = SaryRadius.bar
    var padding: CGFloat = SarySpace.l.rawValue
    @ViewBuilder var content: Content
    @Environment(\.sary) private var theme

    /// Designer glass recipe, dark first: rgba(28,24,20,.78) + blur + hairline rgba(244,239,230,.10).
    /// Light / dim variants arrive with the themes PR; until then they follow the palette's own tints.
    static var darkFill: Color { Color(rgb: 0x1C1814, opacity: 0.78) }
    static var darkHairline: Color { Color(rgb: 0xF4EFE6, opacity: 0.10) }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let dark = !theme.isLight && !theme.night
        content
            .padding(padding)
            .background {
                ZStack {
                    if theme.effectiveGlass == .opaque {
                        shape.fill(theme.palette.chromeOpaque)
                    } else {
                        shape.fill(.ultraThinMaterial)
                        shape.fill(dark ? Self.darkFill : theme.palette.chromeTint)
                    }
                    shape.strokeBorder(dark ? Self.darkHairline : theme.palette.stroke, lineWidth: 1)
                }
                .compositingGroup()
                .saryShadow(.floating, theme)
            }
            .clipShape(shape)
    }
}

// MARK: - Buttons

/// THE primary action of a screen: Ember, 58 pt, full width. One per screen.
struct SaryPrimaryButton: View {
    var title: String
    var systemImage: String?
    var id: String
    var action: () -> Void

    init(_ title: String, systemImage: String? = nil, id: String = "primary-button", action: @escaping () -> Void) {
        self.title = title; self.systemImage = systemImage; self.id = id; self.action = action
    }

    var body: some View {
        Button(action: action) {
            SaryButtonLabel(title: title, systemImage: systemImage)
        }
        .buttonStyle(SaryFoundationButtonStyle(kind: .primary))
        .accessibilityIdentifier(id)
    }
}

/// Everything else: dark surface, light text, hairline.
struct SarySecondaryButton: View {
    var title: String
    var systemImage: String?
    var id: String
    var action: () -> Void

    init(_ title: String, systemImage: String? = nil, id: String = "secondary-button", action: @escaping () -> Void) {
        self.title = title; self.systemImage = systemImage; self.id = id; self.action = action
    }

    var body: some View {
        Button(action: action) {
            SaryButtonLabel(title: title, systemImage: systemImage)
        }
        .buttonStyle(SaryFoundationButtonStyle(kind: .secondary))
        .accessibilityIdentifier(id)
    }
}

struct SaryFoundationButtonStyle: ButtonStyle {
    var kind: SaryButtonKind
    @Environment(\.sary) private var theme
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        let p = theme.palette
        let primary = kind == .primary
        let shape = RoundedRectangle(cornerRadius: SaryRadius.control, style: .continuous)
        configuration.label
            .saryType(.headline)
            .saryLongName(lines: 2, minScale: 0.8)
            .multilineTextAlignment(.center)
            .padding(.horizontal, SarySpace.l.rawValue)
            .frame(maxWidth: .infinity,
                   minHeight: max(primary ? SaryMetrics.primaryHeight : SaryMetrics.secondaryHeight,
                                  theme.minTarget))
            .foregroundStyle(primary ? p.onAccent : p.textPrimary)
            .background {
                if primary { shape.fill(p.accent) }
                else { shape.fill(p.surface).overlay(shape.strokeBorder(p.stroke, lineWidth: 1)) }
            }
            .contentShape(shape)
            .scaleEffect(configuration.isPressed && !theme.reduceMotion ? 0.97 : 1)
            .opacity(enabled ? (configuration.isPressed ? 0.92 : 1) : 0.4)
            .animation(theme.animation(.snappy), value: configuration.isPressed)
    }
}

// MARK: - Window title

/// Unified window header: large title on the right (RTL leading), 44 pt circular ✕ on the left.
struct SaryWindowTitle: View {
    var title: String
    var closeID: String
    var onClose: () -> Void
    @Environment(\.sary) private var theme

    init(_ title: String, closeID: String = "window-close", onClose: @escaping () -> Void) {
        self.title = title; self.closeID = closeID; self.onClose = onClose
    }

    var body: some View {
        HStack(spacing: SarySpace.m.rawValue) {
            Text(title)
                .saryType(.title)
                .saryLongName(lines: 1, minScale: 0.65)
                .foregroundStyle(theme.palette.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading) // leading = right in RTL
                .accessibilityAddTraits(.isHeader)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(theme.palette.textPrimary)
                    .frame(width: SaryMetrics.minHit, height: SaryMetrics.minHit)
                    .background(Circle().fill(theme.palette.surface))
                    .overlay(Circle().strokeBorder(theme.palette.stroke, lineWidth: 1))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("إغلاق")
            .accessibilityIdentifier(closeID)
        }
        .padding(.horizontal, SarySpace.l.rawValue)
        .padding(.vertical, SarySpace.s.rawValue)
    }
}
