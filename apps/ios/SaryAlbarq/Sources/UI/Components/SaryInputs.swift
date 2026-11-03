import SwiftUI
import UIKit

// MARK: - Text field

enum SaryFieldState: Equatable {
    case normal
    case error(String)
    case success(String)
}

struct SaryTextField: View {
    var title: String
    var placeholder: String
    @Binding var text: String
    var id: String
    var keyboard: UIKeyboardType = .default
    var maxLength: Int?
    var state: SaryFieldState = .normal
    var disabled = false
    var help: String?

    @Environment(\.sary) private var theme
    @FocusState private var focused: Bool

    var body: some View {
        let p = theme.palette
        let shape = RoundedRectangle(cornerRadius: SaryRadius.s, style: .continuous)
        let border: Color = {
            if case .error = state { return p.emergency }
            return focused ? p.accent : p.stroke
        }()
        VStack(alignment: .leading, spacing: theme.space(.xs) + 2) {
            HStack {
                Text(title).saryText(.subhead).foregroundStyle(p.textSecondary)
                Spacer()
                if let maxLength {
                    Text("\(SaryFormat.number(text.count))/\(SaryFormat.number(maxLength))")
                        .saryNumber(.caption, weight: .medium)
                        .foregroundStyle(text.count >= maxLength ? p.warningText : p.textTertiary)
                        .environment(\.layoutDirection, .leftToRight)
                }
            }
            TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(p.textTertiary))
                .saryText(.body, weight: .medium)
                .foregroundStyle(p.textPrimary)
                .keyboardType(keyboard)
                .focused($focused)
                .padding(.horizontal, theme.space(.m) + 2)
                .padding(.vertical, theme.space(.s))
                .frame(minHeight: max(theme.minTarget + 6, 50))
                .background(shape.fill(p.sunken))
                .overlay(shape.strokeBorder(border, lineWidth: focused || state != .normal ? 1.5 : 1))
                .disabled(disabled)
                .opacity(disabled ? 0.5 : 1)
                .accessibilityIdentifier(id)
                .accessibilityLabel(Text(title))
                .onChange(of: text) { _, v in
                    if let maxLength, v.count > maxLength { text = String(v.prefix(maxLength)) }
                }
            switch state {
            case .normal:
                if let help { SaryInlineMessage(text: help, tone: .info) }
            case .error(let m): SaryInlineMessage(text: m, tone: .error)
            case .success(let m): SaryInlineMessage(text: m, tone: .success)
            }
        }
        .animation(theme.animation(.snappy), value: focused)
    }
}

// MARK: - Inline message

enum SaryTone { case info, success, warning, error }

struct SaryInlineMessage: View {
    var text: String
    var tone: SaryTone = .info
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        let (icon, color): (String, Color) = {
            switch tone {
            case .info: return ("info.circle.fill", p.textSecondary)
            case .success: return (SaryIcon.checkCircle, p.liveText)
            case .warning: return (SaryIcon.warning, p.warningText)
            case .error: return (SaryIcon.error, p.emergencyText)
            }
        }()
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: icon).font(.system(size: 13, weight: .semibold))
            Text(text).saryText(.subhead).multilineTextAlignment(.leading)
        }
        .foregroundStyle(color)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Toggle row

struct SaryToggleRow: View {
    var title: String
    var subtitle: String?
    var systemImage: String?
    @Binding var isOn: Bool
    var id: String?
    @Environment(\.sary) private var theme

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: theme.space(.m)) {
                if let systemImage { SaryRowIcon(systemImage: systemImage) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).saryText(.body, weight: .medium).foregroundStyle(theme.palette.textPrimary)
                    if let subtitle {
                        Text(subtitle).saryText(.footnote).foregroundStyle(theme.palette.textSecondary)
                    }
                }
            }
        }
        .tint(theme.palette.accent)
        .frame(minHeight: theme.minTarget)
        .padding(.vertical, theme.space(.xs))
        .sensoryFeedback(.selection, trigger: isOn)
        .modifier(OptionalIdentifier(id: id))
    }
}

struct SaryRowIcon: View {
    var systemImage: String
    var color: Color?
    @Environment(\.sary) private var theme
    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(theme.palette.onAccent)
            .frame(width: 30, height: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(color ?? theme.palette.accent))
            .accessibilityHidden(true)
    }
}

// MARK: - Segmented control

/// Tajawal segmented control with a sliding selection pill. Used for tabs and
/// for settings choices (tri-modes, sizes). Wraps to a vertical list at
/// accessibility text sizes so labels never truncate.
struct SarySegmented<Value: Hashable>: View {
    var options: [Value]
    @Binding var selection: Value
    var label: (Value) -> String
    var systemImage: ((Value) -> String?)? = nil
    var id: String?

    @Environment(\.sary) private var theme
    @Environment(\.dynamicTypeSize) private var typeSize
    @Namespace private var ns

    var body: some View {
        let p = theme.palette
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 2))
            : AnyLayout(HStackLayout(spacing: 2))
        layout {
            ForEach(options, id: \.self) { option in
                let selected = option == selection
                Button {
                    selection = option
                } label: {
                    HStack(spacing: 5) {
                        if let s = systemImage?(option) {
                            Image(systemName: s).font(.system(size: 13, weight: .semibold))
                        }
                        Text(label(option))
                            .saryText(.subhead, weight: selected ? .bold : .medium)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(selected ? p.textPrimary : p.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: max(theme.minTarget - 8, 36))
                    .padding(.horizontal, 6)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: SaryRadius.s - 3, style: .continuous)
                                .fill(theme.isLight ? p.surface : p.textPrimary.opacity(0.14))
                                .saryShadow(theme.isLight ? .raised : .none, theme)
                                .matchedGeometryEffect(id: "pill", in: ns)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: SaryRadius.s, style: .continuous).fill(p.sunken))
        .animation(theme.animation(.snappy), value: selection)
        .sensoryFeedback(.selection, trigger: selection)
        .modifier(OptionalIdentifier(id: id))
    }
}

// MARK: - Grouped list section (settings-style)

struct SarySection<Content: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder var content: Content
    @Environment(\.sary) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space(.s)) {
            if let title {
                Text(title)
                    .saryText(.footnote, weight: .bold)
                    .foregroundStyle(theme.palette.textSecondary)
                    .padding(.horizontal, theme.space(.xs))
                    .accessibilityAddTraits(.isHeader)
            }
            VStack(alignment: .leading, spacing: 0) { content }
                .padding(.horizontal, theme.space(.l))
                .padding(.vertical, theme.space(.xs))
                .frame(maxWidth: .infinity, alignment: .leading)
                .sarySurface(radius: SaryRadius.m)
            if let footer {
                Text(footer)
                    .saryText(.footnote)
                    .foregroundStyle(theme.palette.textTertiary)
                    .padding(.horizontal, theme.space(.xs))
            }
        }
    }
}

struct SaryDivider: View {
    @Environment(\.sary) private var theme
    var body: some View {
        Rectangle().fill(theme.palette.separator).frame(height: 0.75)
    }
}
