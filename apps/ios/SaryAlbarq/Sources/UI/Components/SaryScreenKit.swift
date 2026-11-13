import SwiftUI

// Build 47 screen kit: the shared pieces every NEW-UI screen is made of
// (docs/UI-COMPONENTS.md). Header / primary / secondary buttons live in
// `Foundations/SaryFoundationComponents.swift` (`SaryWindowTitle`, `SaryPrimaryButton`,
// `SarySecondaryButton`); this file adds the scaffold, states, skeletons, list rows,
// chip, pill and avatar stack. Colours and spacing come from `@Environment(\.sary)`;
// every tappable piece is >= 44 pt, RTL-safe, Dynamic Type safe, and long names shrink
// instead of ending in «…».

// MARK: - Screen scaffold

/// One screen = header (big title right, ✕ left) + content + ONE primary button pinned below.
/// A screen passes at most one `primary`; everything else on it is secondary.
struct SaryScreenScaffold<Content: View>: View {
    var title: String
    var closeID: String = "window-close"
    var onClose: () -> Void
    var primaryTitle: String?
    var primaryImage: String?
    var primaryID: String = "primary-button"
    var onPrimary: () -> Void = {}
    @ViewBuilder var content: Content
    @Environment(\.sary) private var theme

    var body: some View {
        VStack(spacing: 0) {
            SaryWindowTitle(title, closeID: closeID, onClose: onClose)
            ScrollView {
                content
                    .padding(.horizontal, SarySpace.l.rawValue)
                    .padding(.vertical, SarySpace.s.rawValue)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let primaryTitle {
                SaryPrimaryButton(primaryTitle, systemImage: primaryImage, id: primaryID, action: onPrimary)
                    .padding(.horizontal, SarySpace.l.rawValue)
                    .padding(.vertical, SarySpace.m.rawValue)
            }
        }
        .background(theme.palette.background.ignoresSafeArea())
    }
}

// MARK: - States (empty / error)

enum SaryScreenStateKind: Equatable { case empty, error }

/// Empty and error states: an icon in a circle, ONE Najdi sentence that says what happened and
/// what to do, and one button for the next step («سوّ أول طلعة», «حاول مرة ثانية»).
/// The button is the screen's primary action. Loading uses `SarySkeletonList`, never a spinner.
struct SaryScreenState: View {
    var kind: SaryScreenStateKind
    var systemImage: String?
    /// One sentence: what happened and what to do.
    var message: String
    var actionTitle: String?
    var actionID: String = "state-action"
    /// Existing screens keep the id their tests already look for (default: the shared one).
    var messageID: String = "state-message"
    var action: () -> Void = {}
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        let symbol = systemImage ?? (kind == .error ? SaryIcon.error : SaryIcon.empty)
        VStack(spacing: SarySpace.l.rawValue) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(kind == .error ? p.emergencyText : p.textSecondary)
                .frame(width: 72, height: 72)
                .background(Circle().fill(p.surface))
                .overlay(Circle().strokeBorder(p.stroke, lineWidth: 1))
                .accessibilityHidden(true)
            Text(message)
                .saryType(.headline)
                .foregroundStyle(p.textPrimary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(messageID)
            if let actionTitle {
                SaryPrimaryButton(actionTitle, id: actionID, action: action)
                    .padding(.top, SarySpace.xs.rawValue)
            }
        }
        .padding(SarySpace.xxl.rawValue)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(kind == .error ? "state-error" : "state-empty")
    }
}

// MARK: - Loading skeleton

/// A grey placeholder shape. Pulses (opacity only) while motion is allowed; static under Reduce Motion,
/// in drive mode, off screen or in the background (the loop policy in `saryPulse`).
struct SarySkeleton: View {
    enum Shape { case capsule, circle, rounded }
    var shape: Shape = .capsule
    var width: CGFloat?
    var height: CGFloat = 12
    @Environment(\.sary) private var theme

    var body: some View {
        let fill = theme.palette.textPrimary.opacity(theme.isLight ? 0.08 : 0.10)
        Group {
            switch shape {
            case .capsule: Capsule().fill(fill)
            case .circle: Circle().fill(fill)
            case .rounded: RoundedRectangle(cornerRadius: SaryRadius.s, style: .continuous).fill(fill)
            }
        }
        .frame(width: width, height: height)
        .accessibilityHidden(true)
    }
}

/// N placeholder list rows at the real row height, so the list does not jump when data arrives.
struct SarySkeletonList: View {
    var rows: Int = 5
    @Environment(\.sary) private var theme

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<rows, id: \.self) { i in
                HStack(spacing: SarySpace.m.rawValue) {
                    SarySkeleton(shape: .rounded, width: SaryMetrics.iconCircle, height: SaryMetrics.iconCircle)
                    VStack(alignment: .leading, spacing: 6) {
                        SarySkeleton(width: i % 2 == 0 ? 150 : 110, height: 12)
                        SarySkeleton(width: i % 2 == 0 ? 90 : 130, height: 10)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, SarySpace.l.rawValue)
                .frame(height: SaryMetrics.rowHeight)
                if i < rows - 1 { SaryListSeparator() }
            }
        }
        .saryPulse(.skeleton, style: .dim)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("جاري التحميل")
        .accessibilityIdentifier("skeleton-list")
    }
}

// MARK: - List rows

/// Thin separator, inset to start after the icon column (right in RTL).
struct SaryListSeparator: View {
    var inset: CGFloat = SarySpace.l.rawValue + SaryMetrics.iconCircle + SarySpace.m.rawValue
    @Environment(\.sary) private var theme
    var body: some View {
        Rectangle()
            .fill(theme.palette.separator)
            .frame(height: 1 / UIScreen.main.scale)
            .padding(.leading, inset)
            .accessibilityHidden(true)
    }
}

/// A list row: icon on the right (leading in RTL), title + optional subtitle, optional trailing value,
/// and a disclosure chevron that points the right way for Arabic. All rows are the same height
/// (`SaryMetrics.rowHeight`, growing only for Dynamic Type). Long names shrink, never «…».
struct SaryListRow: View {
    var title: String
    var subtitle: String?
    var systemImage: String?
    var iconColor: Color?
    var trailing: String?
    var disclosure: Bool = true
    var id: String?
    var action: (() -> Void)?
    @Environment(\.sary) private var theme

    var body: some View {
        if let action {
            Button(action: action) { rowBody }
                .buttonStyle(SaryRowPressStyle())
                .modifier(OptionalIdentifier(id: id))
        } else {
            rowBody.modifier(OptionalIdentifier(id: id))
        }
    }

    private var rowBody: some View {
        let p = theme.palette
        return HStack(spacing: SarySpace.m.rawValue) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(iconColor ?? p.accent)
                    .frame(width: SaryMetrics.iconCircle, height: SaryMetrics.iconCircle)
                    .background(RoundedRectangle(cornerRadius: SaryRadius.control * 0.55, style: .continuous).fill(p.surface))
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .saryType(.headline)
                    .saryLongName(lines: 2, minScale: 0.7)
                    .foregroundStyle(p.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .saryType(.caption)
                        .saryLongName(lines: 2, minScale: 0.8)
                        .foregroundStyle(p.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let trailing {
                Text(SaryFormat.digits(trailing))
                    .saryType(.caption)
                    .foregroundStyle(p.textSecondary)
            }
            if disclosure && action != nil {
                Image(systemName: SaryIcon.disclosure)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(p.textTertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, SarySpace.l.rawValue)
        .frame(minHeight: max(SaryMetrics.rowHeight, theme.minTarget))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// Rows with hairlines between them (none after the last one).
struct SaryListGroup<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.sary) private var theme
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: SaryRadius.card, style: .continuous)
        VStack(spacing: 0) {
            _VariadicView.Tree(SaryListGroupLayout()) { content }
        }
        .background(shape.fill(theme.palette.surface))
        .overlay(shape.strokeBorder(theme.palette.stroke, lineWidth: 1))
        .clipShape(shape)
    }
}

private struct SaryListGroupLayout: _VariadicView_UnaryViewRoot {
    func body(children: _VariadicView.Children) -> some View {
        let last = children.last?.id
        VStack(spacing: 0) {
            ForEach(children) { child in
                child
                if child.id != last { SaryListSeparator() }
            }
        }
    }
}

// MARK: - Chip and pill

/// A selectable filter chip («الكل», «الأسفلت»): 44 pt hit area, Ember fill when selected.
struct SaryChip: View {
    var title: String
    var systemImage: String?
    var selected: Bool
    var id: String?
    var action: () -> Void
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage { Image(systemName: systemImage).font(.system(size: 13, weight: .semibold)) }
                Text(title).saryType(.caption).saryLongName(lines: 1, minScale: 0.8)
            }
            .foregroundStyle(selected ? p.onAccent : p.textPrimary)
            .padding(.horizontal, SarySpace.m.rawValue)
            .frame(minHeight: 36)
            .background(Capsule().fill(selected ? p.accent : p.surface))
            .overlay(Capsule().strokeBorder(selected ? Color.clear : p.stroke, lineWidth: 1))
            /* 44 pt touch area around the 36 pt capsule. */
            .frame(minHeight: theme.minTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .modifier(OptionalIdentifier(id: id))
    }
}

enum SaryPillTone { case neutral, accent, live, warning, emergency }

/// A small non-interactive status pill: «مباشر», «تحذير», «٤ أصدقاء».
struct SaryPill: View {
    var text: String
    var tone: SaryPillTone = .neutral
    var systemImage: String?
    @Environment(\.sary) private var theme

    var body: some View {
        let (bg, fg) = colors
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage).font(.system(size: 11, weight: .bold)) }
            Text(SaryFormat.digits(text)).saryType(.caption).saryLongName(lines: 1, minScale: 0.75)
        }
        .foregroundStyle(fg)
        .padding(.horizontal, SarySpace.s.rawValue + 2)
        .padding(.vertical, 4)
        .background(Capsule().fill(bg))
    }

    private var colors: (Color, Color) {
        let p = theme.palette
        switch tone {
        case .neutral: return (p.surface, p.textSecondary)
        case .accent: return (p.accent, p.onAccent)
        case .live: return (p.live, Color.white)
        case .warning: return (p.warning, p.onWarning)
        case .emergency: return (p.emergency, p.onEmergency)
        }
    }
}

// MARK: - Avatar stack

struct SaryAvatarStackPerson: Identifiable, Equatable {
    var id: String
    var name: String
    var color: UInt32
}

/// Overlapping friend avatars with a «+N» overflow circle; the caption («٣ معك») is the caller's.
struct SaryAvatarStack: View {
    var people: [SaryAvatarStackPerson]
    var size: CGFloat = 32
    var maxShown: Int = 3
    @Environment(\.sary) private var theme

    /// How many people the «+N» circle stands for.
    static func overflow(count: Int, maxShown: Int) -> Int { max(0, count - max(0, maxShown)) }

    var body: some View {
        let shown = Array(people.prefix(maxShown))
        let extra = Self.overflow(count: people.count, maxShown: maxShown)
        HStack(spacing: -size * 0.28) {
            ForEach(shown) { p in
                SaryAvatar(name: p.name, color: p.color, size: size - 7)
                    .background(Circle().fill(theme.palette.background).padding(-1))
            }
            if extra > 0 {
                Text("+" + SaryFormat.digits(String(extra)))
                    .saryType(.caption)
                    .foregroundStyle(theme.palette.textPrimary)
                    .frame(width: size, height: size)
                    .background(Circle().fill(theme.palette.surface))
                    .overlay(Circle().strokeBorder(theme.palette.stroke, lineWidth: 1))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(SaryFormat.digits(String(people.count))) أصدقاء")
        .accessibilityIdentifier("avatar-stack")
    }
}
