import SwiftUI

/// One control in a map cluster.
struct SaryMapControlItem: Identifiable, Equatable {
    var id: String
    var systemImage: String
    var label: String
    /// Accessibility identifier (e.g. `outing-locate`).
    var accessibilityID: String
    /// Highlighted (e.g. «موقعي» while following).
    var isActive = false
    /// Small count badge (e.g. unread notes).
    var badge: Int?

    static func == (a: Self, b: Self) -> Bool {
        a.id == b.id && a.systemImage == b.systemImage && a.isActive == b.isActive && a.badge == b.badge && a.label == b.label
    }
}

/// Single floating round map button (glass). 48 pt, 64 pt in drive mode.
struct SaryMapControlButton: View {
    var item: SaryMapControlItem
    var showsLabel = false
    var action: () -> Void
    @Environment(\.sary) private var theme

    var body: some View {
        Button(action: action) {
            SaryMapControlFace(item: item, showsLabel: showsLabel)
                .saryGlass(Circle(), role: .control, tint: item.isActive ? theme.palette.accent : nil, interactive: true)
        }
        .buttonStyle(SaryPressStyle())
        .sensoryFeedback(.selection, trigger: item.isActive)
        .accessibilityLabel(Text(item.label))
        .accessibilityAddTraits(item.isActive ? .isSelected : [])
        .accessibilityIdentifier(item.accessibilityID)
    }
}

/// The glyph (+ optional label) inside a map control, no background.
struct SaryMapControlFace: View {
    var item: SaryMapControlItem
    var showsLabel = false
    @Environment(\.sary) private var theme

    var body: some View {
        let size = theme.mapButton
        VStack(spacing: 1) {
            Image(systemName: item.systemImage)
                .font(.system(size: theme.drive ? 24 : 18, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .contentTransition(.symbolEffect(.replace))
            if showsLabel {
                Text(item.label)
                    .saryText(.micro)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .dynamicTypeSize(...DynamicTypeSize.xLarge)
            }
        }
        .foregroundStyle(item.isActive ? theme.palette.onAccent : theme.palette.textPrimary)
        .frame(width: size, height: size)
        .overlay(alignment: .topTrailing) {
            if let badge = item.badge, badge > 0 {
                Text(SaryFormat.number(badge))
                    .saryNumber(.micro)
                    .foregroundStyle(theme.palette.onAccent)
                    .padding(.horizontal, 5)
                    .frame(minWidth: 18, minHeight: 18)
                    .background(Capsule().fill(theme.palette.accent))
                    .overlay(Capsule().stroke(theme.palette.background, lineWidth: 1.5))
                    .offset(x: 4, y: -4)
                    .dynamicTypeSize(...DynamicTypeSize.xxLarge)
            }
        }
        .contentShape(Circle())
    }
}

/// A group of map controls that morphs between a vertical column (normal) and
/// a horizontal row (e.g. when the sheet is expanded or in landscape).
/// iOS 26: separate glass discs in a `GlassEffectContainer` that blend and
/// morph by `glassEffectID`. Fallback: one material capsule whose layout
/// animates between axes.
struct SaryControlCluster: View {
    var items: [SaryMapControlItem]
    var axis: Axis = .vertical
    var showsLabels = false
    var action: (_ id: String) -> Void = { _ in }

    @Environment(\.sary) private var theme
    @Namespace private var ns

    var body: some View {
        let layout: AnyLayout = axis == .vertical
            ? AnyLayout(VStackLayout(spacing: 0))
            : AnyLayout(HStackLayout(spacing: 0))

        // One control group: a single glass capsule (Apple-Maps-like) whose
        // shape morphs between column and row. On iOS 26 it lives in a
        // GlassEffectContainer with a stable glassEffectID so the capsule
        // liquid-morphs; the fallback material capsule animates with layout.
        SaryGlassGroup(spacing: 0) {
            layout {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    Button { action(item.id) } label: {
                        SaryMapControlFace(item: item, showsLabel: showsLabels)
                            .background {
                                if item.isActive {
                                    Circle().fill(theme.palette.accent).padding(4)
                                }
                            }
                    }
                    .buttonStyle(SaryPressStyle())
                    .modifier(ControlAccessibility(item: item))
                    .overlay(alignment: axis == .vertical ? .top : .leading) {
                        if index > 0 && !items[index - 1].isActive && !item.isActive { divider }
                    }
                }
            }
            .saryGlass(Capsule(), role: .control)
            .saryGlassID("cluster", in: ns, theme: theme)
        }
        .animation(theme.animation(.smooth), value: axis)
        .animation(theme.animation(.snappy), value: items)
    }

    private var divider: some View {
        let len = theme.mapButton * 0.5
        return Rectangle()
            .fill(theme.palette.separator)
            .frame(width: axis == .vertical ? len : 0.75, height: axis == .vertical ? 0.75 : len)
    }
}

private struct ControlAccessibility: ViewModifier {
    var item: SaryMapControlItem
    func body(content: Content) -> some View {
        content
            .accessibilityLabel(Text(item.label))
            .accessibilityAddTraits(item.isActive ? .isSelected : [])
            .accessibilityIdentifier(item.accessibilityID)
            .sensoryFeedback(.selection, trigger: item.isActive)
    }
}

extension SaryMapControlItem {
    /// The standard live-outing side controls, with the web's identifiers.
    static func liveDefaults(following: Bool = false, unreadNotes: Int? = nil) -> [SaryMapControlItem] {
        [
            .init(id: "locate", systemImage: following ? SaryIcon.locateFollow : SaryIcon.locate,
                  label: "موقعي", accessibilityID: "outing-locate", isActive: following),
            .init(id: "fit", systemImage: SaryIcon.fitGroup, label: "المجموعة", accessibilityID: "outing-fit"),
            .init(id: "note", systemImage: SaryIcon.note, label: "رسالة", accessibilityID: "outing-note-open", badge: unreadNotes),
            .init(id: "nearest", systemImage: SaryIcon.nearest, label: "أقرب محطة", accessibilityID: "outing-nearest-open"),
        ]
    }
}
