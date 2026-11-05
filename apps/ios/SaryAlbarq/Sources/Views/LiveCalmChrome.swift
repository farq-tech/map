import SwiftUI

/// «تخفيف الزحمة» (phase A, styled after the owner's Lovable prototype): the small pieces of
/// the calm live screen. The rules live in `LiveCalmRules` (unit-tested in `LiveCalmTests`).
enum LiveCalmRules {
    /// The convoy at a glance while driving: «٤ مباشر · الأبعد ١٫٢ كم» (friends only, never me).
    static func convoyLine(_ participants: [ParticipantUI]) -> String? {
        let others = participants.filter { !$0.isMe }
        guard !others.isEmpty else { return nil }
        let live = others.filter { $0.presence.isLive }
        var parts = ["\(SaryFormat.number(live.count)) مباشر"]
        if let far = live.compactMap(\.distanceMeters).max() {
            parts.append("الأبعد \(SaryFormat.distance(meters: far))")
        }
        return parts.joined(separator: " · ")
    }

    /// The round buttons on the map's side (stopped): «تتبعني» and «أدوات» only, plus «طريق العودة»
    /// when it fits the moment; after the end, the camera alone. Driving: none.
    static func sideItems(camera: SaryMapControlItem, backTrack: SaryMapControlItem?, plusBadge: Int?,
                          driving: Bool, ended: Bool) -> [SaryMapControlItem] {
        guard !driving else { return [] }
        var items = [camera]
        if let backTrack { items.append(backTrack) }
        if !ended {
            var plus = SaryMapControlItem.actions
            plus.label = "أدوات"
            plus.badge = plusBadge
            items.append(plus)
        }
        return items
    }
}

/// Separate round glass buttons, each with its caption under it («تتبعني»، «أدوات»).
struct LiveSideButtons: View {
    var items: [SaryMapControlItem]
    var action: (String) -> Void
    @Environment(\.sary) private var theme

    var body: some View {
        VStack(spacing: theme.space(.s)) {
            ForEach(items) { item in
                VStack(spacing: 3) {
                    SaryMapControlButton(item: item) { action(item.id) }
                    Text(item.label)
                        .saryText(.micro, weight: .bold)
                        .foregroundStyle(theme.palette.textPrimary)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .saryGlass(Capsule(), role: .chrome)
                        .dynamicTypeSize(...DynamicTypeSize.xLarge)
                        .accessibilityHidden(true)
                }
            }
        }
        .animation(theme.animation(.snappy), value: items)
    }
}

/// «٤ مباشر · الأبعد ١٫٢ كم» over the dock while the guidance bar holds the sheet's peek.
struct ConvoyLinePill: View {
    var text: String
    var open: () -> Void
    @Environment(\.sary) private var theme

    var body: some View {
        Button(action: open) {
            HStack(spacing: 6) {
                Circle().fill(theme.palette.live).frame(width: 8, height: 8)
                Text(text)
                    .saryNumber(theme.drive ? .callout : .footnote, weight: .bold)
                    .foregroundStyle(theme.palette.textPrimary)
                    .lineLimit(1)
            }
            .padding(.horizontal, theme.space(.m))
            .frame(minHeight: 34)
            .saryGlass(Capsule(), role: .chrome, interactive: true)
        }
        .buttonStyle(SaryPressStyle())
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .accessibilityLabel(Text("القافلة: \(text)"))
        .accessibilityHint(Text("يفتح الجماعة"))
        .accessibilityIdentifier("convoy.line")
    }
}

/// The alert banner's ♲ history: every alert of this trip (the bell's list), one tap from the banner.
struct AlertHistoryButton: View {
    var open: Bool
    var action: () -> Void
    @Environment(\.sary) private var theme

    var body: some View {
        Button(action: action) {
            Image(systemName: open ? "xmark" : "clock.arrow.circlepath")
                .font(.system(size: theme.drive ? 20 : 17, weight: .semibold))
                .foregroundStyle(theme.palette.textPrimary)
                .frame(width: theme.drive ? 56 : 46, height: theme.drive ? 56 : 46)
                .saryGlass(Circle(), role: .chrome, interactive: true)
        }
        .buttonStyle(SaryPressStyle())
        .accessibilityLabel(Text(open ? "أخفِ التنبيهات" : "سجل التنبيهات"))
        .accessibilityIdentifier("alerts.history")
    }
}
