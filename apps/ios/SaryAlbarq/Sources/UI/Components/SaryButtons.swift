import SwiftUI

// MARK: - Buttons

enum SaryButtonKind: CaseIterable {
    /// Main action: accent fill.
    case primary
    /// Alternative action: surface fill.
    case secondary
    /// Irreversible / emergency action: red fill.
    case destructive
    /// Text-only action.
    case plain
    /// Text-only, red (e.g. «غادر الطلعة» in a list).
    case plainDestructive
    /// Over the map: glass (iOS 26) / material fallback, opaque in drive mode.
    case glass

    var label: String {
        switch self {
        case .primary: return "أساسي"
        case .secondary: return "ثانوي"
        case .destructive: return "خطر"
        case .plain: return "نصي"
        case .plainDestructive: return "نصي خطر"
        case .glass: return "زجاجي"
        }
    }
}

enum SaryButtonWidth { case fill, hug }

/// Full-width (or hugging) button. Height follows the button-size setting and
/// is ≥ 64 pt in drive mode. Press = slight scale; disabled = 40 % opacity.
struct SaryButtonStyle: ButtonStyle {
    var kind: SaryButtonKind = .primary
    var width: SaryButtonWidth = .fill
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        SaryButtonBody(configuration: configuration, kind: kind, width: width, compact: compact)
    }
}

private struct SaryButtonBody: View {
    var configuration: ButtonStyleConfiguration
    var kind: SaryButtonKind
    var width: SaryButtonWidth
    var compact: Bool
    @Environment(\.sary) private var theme
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        let p = theme.palette
        let shape = RoundedRectangle(cornerRadius: compact ? SaryRadius.s : SaryRadius.m, style: .continuous)
        let height: CGFloat = compact ? max(theme.minTarget, theme.drive ? 64 : 40) : theme.buttonHeight
        let fg: Color = {
            switch kind {
            case .primary: return p.onAccent
            case .secondary, .glass: return p.textPrimary
            case .destructive: return p.onEmergency
            case .plain: return p.accentText
            case .plainDestructive: return p.emergencyText
            }
        }()
        configuration.label
            .saryText(compact ? .callout : .headline)
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .padding(.horizontal, compact ? theme.space(.m) : theme.space(.l))
            .padding(.vertical, theme.space(.s))
            .frame(maxWidth: width == .fill ? .infinity : nil, minHeight: height)
            .foregroundStyle(fg)
            .background { background(shape) }
            .modifier(GlassIfNeeded(kind: kind, shape: shape))
            .contentShape(shape)
            .scaleEffect(configuration.isPressed && !theme.reduceMotion ? 0.97 : 1)
            .brightness(configuration.isPressed ? (theme.isLight ? -0.04 : 0.06) : 0)
            .opacity(enabled ? 1 : 0.4)
            .animation(theme.animation(.snappy), value: configuration.isPressed)
    }

    @ViewBuilder
    private func background(_ shape: RoundedRectangle) -> some View {
        let p = theme.palette
        switch kind {
        case .primary: shape.fill(p.accent)
        case .secondary:
            shape.fill(theme.isLight ? p.surface : p.surface)
                .overlay(shape.stroke(p.stroke, lineWidth: 1))
        case .destructive: shape.fill(p.emergency)
        case .plain, .plainDestructive, .glass: Color.clear
        }
    }
}

private struct GlassIfNeeded: ViewModifier {
    var kind: SaryButtonKind
    var shape: RoundedRectangle
    func body(content: Content) -> some View {
        if kind == .glass {
            content.saryGlass(shape, role: .control, interactive: true)
        } else {
            content
        }
    }
}

extension ButtonStyle where Self == SaryButtonStyle {
    static var saryPrimary: SaryButtonStyle { .init(kind: .primary) }
    static var sarySecondary: SaryButtonStyle { .init(kind: .secondary) }
    static var saryDestructive: SaryButtonStyle { .init(kind: .destructive) }
    static var saryPlain: SaryButtonStyle { .init(kind: .plain) }
    static func sary(_ kind: SaryButtonKind, width: SaryButtonWidth = .fill, compact: Bool = false) -> SaryButtonStyle {
        .init(kind: kind, width: width, compact: compact)
    }
}

/// Label with an optional leading symbol and a busy spinner that keeps the
/// same width, so the button never jumps while loading.
struct SaryButtonLabel: View {
    var title: String
    var systemImage: String?
    var busy = false
    var busyTitle: String?

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                if busy {
                    ProgressView().controlSize(.small).tint(.primary)
                } else if let systemImage {
                    Image(systemName: systemImage).fontWeight(.semibold)
                }
            }
            .frame(minWidth: (busy || systemImage != nil) ? 20 : 0)
            Text(busy ? (busyTitle ?? title) : title)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Icon button (round, for sheets and cards)

struct SaryIconButton: View {
    var systemImage: String
    var label: String
    var id: String?
    var tinted = false
    var action: () -> Void
    @Environment(\.sary) private var theme

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: theme.drive ? 20 : 15, weight: .bold))
                .foregroundStyle(tinted ? theme.palette.onAccent : theme.palette.textSecondary)
                .frame(width: theme.minTarget, height: theme.minTarget)
                .background(Circle().fill(tinted ? theme.palette.accent : theme.palette.sunken))
                .contentShape(Circle())
        }
        .buttonStyle(SaryPressStyle())
        .accessibilityLabel(Text(label))
        .modifier(OptionalIdentifier(id: id))
    }
}

/// Neutral press feedback for custom-drawn buttons.
struct SaryPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PressBody(configuration: configuration)
    }

    private struct PressBody: View {
        var configuration: ButtonStyleConfiguration
        @Environment(\.sary) private var theme
        var body: some View {
            configuration.label
                .scaleEffect(configuration.isPressed && !theme.reduceMotion ? 0.94 : 1)
                .opacity(configuration.isPressed ? 0.85 : 1)
                .animation(theme.animation(.snappy), value: configuration.isPressed)
        }
    }
}

struct OptionalIdentifier: ViewModifier {
    var id: String?
    func body(content: Content) -> some View {
        if let id { content.accessibilityIdentifier(id) } else { content }
    }
}
