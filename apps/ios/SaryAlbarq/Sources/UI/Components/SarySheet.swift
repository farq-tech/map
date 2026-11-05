import SwiftUI

// MARK: - Detents

extension SheetDetentUI {
    /// Height of the minimized sheet: handle + summary line (+ drive size).
    /// `trip`: the trip strip («قطعنا ٦٢٪ · باقي …») sits under the summary line.
    static func peekHeight(drive: Bool, trip: Bool = false) -> CGFloat {
        trip ? (drive ? 140 : 104) : (drive ? 88 : 70)
    }

    func presentationDetent(drive: Bool, trip: Bool = false) -> PresentationDetent {
        switch self {
        case .peek: return .height(Self.peekHeight(drive: drive, trip: trip))
        case .half: return .medium
        case .full: return .large
        }
    }

    init(_ d: PresentationDetent, drive: Bool) {
        if d == .large { self = .full }
        else if d == .medium { self = .half }
        else { self = .peek }
    }

    var label: String {
        switch self {
        case .peek: return "مصغّرة"
        case .half: return "نصف"
        case .full: return "كاملة"
        }
    }
}

/// Native sheet styling for the live outing sheet: three detents, the map
/// stays interactive up to «نصف», never dismissible by swipe, Liquid Glass
/// background on iOS 26 (system default at partial heights), opaque surface
/// in drive mode / solid panel look / fallback.
private struct SarySheetPresentation: ViewModifier {
    @Binding var detent: SheetDetentUI
    var trip = false
    @Environment(\.sary) private var theme

    func body(content: Content) -> some View {
        let binding = Binding<PresentationDetent>(
            get: { detent.presentationDetent(drive: theme.drive, trip: trip) },
            set: { detent = SheetDetentUI($0, drive: theme.drive) }
        )
        content
            .presentationDetents(Set(SheetDetentUI.allCases.map { $0.presentationDetent(drive: theme.drive, trip: trip) }), selection: binding)
            .presentationBackgroundInteraction(.enabled(upThrough: .medium))
            .presentationDragIndicator(.visible)
            .presentationContentInteraction(.scrolls)
            .interactiveDismissDisabled()
            .modifier(SheetBackground())
            .sensoryFeedback(.selection, trigger: detent)
    }
}

private struct SheetBackground: ViewModifier {
    @Environment(\.sary) private var theme
    func body(content: Content) -> some View {
        if theme.usesLiquidGlass && theme.panelGlass != .opaque {
            // iOS 26: system glass sheet, tinted to the theme so it stays
            // legible over bright terrain.
            content.presentationBackground {
                Rectangle().fill(theme.glassTint(theme.panelGlass).opacity(0.9))
            }
        } else if theme.panelGlass == .opaque {
            content.presentationBackground(theme.palette.elevated)
                .presentationCornerRadius(SaryRadius.sheet)
        } else {
            content.presentationBackground {
                ZStack {
                    Rectangle().fill(.regularMaterial)
                    Rectangle().fill(theme.palette.chromeTint)
                }
            }
            .presentationCornerRadius(SaryRadius.sheet)
        }
    }
}

extension View {
    /// Apply to the content of the live outing `.sheet`.
    func sarySheetPresentation(detent: Binding<SheetDetentUI>, trip: Bool = false) -> some View {
        modifier(SarySheetPresentation(detent: detent, trip: trip))
    }
}

// MARK: - Summary line

/// «٣ مشارك · ٢ مباشر · الأقرب ٩٠٠ م» — the whole minimized sheet. Tapping it
/// expands to «نصف».
struct SarySheetSummary: View {
    var participants: [ParticipantUI]
    var detent: SheetDetentUI
    /// The trip ended: «انتهت الطلعة» in place of «… مباشر» (nobody is live any more,
    /// though my own car still moves with this phone's GPS).
    var ended = false
    var expand: () -> Void = {}
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        let live = participants.filter { $0.presence.isLive }.count
        let nearest = participants.filter { !$0.isMe }.compactMap(\.distanceMeters).min()
        Button(action: expand) {
            HStack(spacing: theme.space(.s)) {
                HStack(spacing: -10) {
                    ForEach(participants.prefix(4)) { m in
                        SaryAvatar(name: m.name, color: m.color, presence: m.presence, size: theme.drive ? 30 : 24)
                            .background(Circle().fill(p.elevated).padding(1))
                    }
                }
                .environment(\.layoutDirection, .rightToLeft)
                summaryText(count: participants.count, live: live, nearest: nearest)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if detent == .peek {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(p.textTertiary)
                }
            }
            .padding(.horizontal, theme.space(.l))
            .frame(minHeight: theme.minTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(ended ? "\(SaryFormat.number(participants.count)) في الطلعة، انتهت الطلعة" : SaryFormat.peekSummary(participants)))
        .accessibilityHint(Text(detent == .peek ? "اضغط لعرض المشاركين" : ""))
        .accessibilityIdentifier("outing-sheet-summary")
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }

    private func summaryText(count: Int, live: Int, nearest: Double?) -> some View {
        let p = theme.palette
        return HStack(spacing: 6) {
            Text("\(SaryFormat.number(count)) في الطلعة").foregroundStyle(p.textPrimary)
            dot
            if ended {
                Text("انتهت الطلعة").foregroundStyle(p.textSecondary)
            } else {
                HStack(spacing: 4) {
                    Circle().fill(p.live).frame(width: 7, height: 7)
                    Text("\(SaryFormat.number(live)) مباشر").foregroundStyle(p.liveText)
                }
                if let nearest {
                    dot
                    Text("الأقرب \(SaryFormat.distance(meters: nearest))").foregroundStyle(p.textSecondary)
                        .saryNumber(.callout, weight: .bold)
                }
            }
        }
        .saryText(.callout, weight: .bold)
        .lineLimit(1)
        .minimumScaleFactor(0.75)
    }

    private var dot: some View {
        Text("·").foregroundStyle(theme.palette.textTertiary)
    }
}

// MARK: - Tabs

struct SaryTabBar: View {
    @Binding var selection: LiveTabUI
    /// «المحادثات»: unread chat messages, shown on «المجموعة».
    var groupBadge: Int = 0
    var body: some View {
        SarySegmented(
            options: LiveTabUI.allCases,
            selection: $selection,
            label: { $0.label },
            systemImage: { tab in
                switch tab {
                case .trip: return "flag.checkered"
                case .group: return "person.2.fill"
                case .more: return "ellipsis.circle"
                }
            },
            badge: { $0 == .group ? groupBadge : 0 },
            optionID: { tab in
                switch tab {
                case .trip: return "tab.trip"
                case .group: return "tab.group"
                case .more: return "tab.more"
                }
            }
        )
    }
}

// MARK: - Static sheet frame (for showcase / snapshot of a detent)

/// Draws content inside the sheet's look (rounded top, handle) without
/// presenting it, so all three detents can be compared side by side.
struct SarySheetFrame<Content: View>: View {
    var height: CGFloat
    @ViewBuilder var content: Content
    @Environment(\.sary) private var theme

    var body: some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: SaryRadius.sheet, topTrailingRadius: SaryRadius.sheet, style: .continuous)
        VStack(spacing: 0) {
            Capsule().fill(theme.palette.textTertiary.opacity(0.6)).frame(width: 36, height: 5).padding(.top, 6).padding(.bottom, 4)
            content
            Spacer(minLength: 0)
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .clipShape(shape)
        .saryGlass(shape, role: .panel)
    }
}
