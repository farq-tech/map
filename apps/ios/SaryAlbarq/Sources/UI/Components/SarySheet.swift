import SwiftUI

// MARK: - Detents

extension SheetDetentUI {
    /// Height of the minimized sheet: handle + summary line (+ drive size).
    /// `trip`: the quick row (ملاحة، المحادثة، التجمع، أخفِ موقعي، طريق الرجعة، المزيد) sits under
    /// the summary line.
    /// `surfaces`: the guidance bar lists the route's surfaces in order under its numbers (`NavSurfaceAheadStrip`).
    /// `guide`: the v2 guidance bar (`NavDriveLayout`): numbers, surfaces or progress, and its footer row.
    static func peekHeight(drive: Bool, trip: Bool = false, surfaces: Bool = false, guide: Bool = false) -> CGFloat {
        if guide && !trip { return NavDriveLayout.peekHeight(drive: drive, surfaces: surfaces) }
        let base: CGFloat = trip ? (drive ? 172 : 140) : (drive ? 88 : 70)
        return base + (surfaces && !trip ? surfacesExtra(drive: drive) : 0)
    }

    /// The thin bar and its one line under the guidance numbers.
    static func surfacesExtra(drive: Bool) -> CGFloat { drive ? 34 : 30 }

    func presentationDetent(drive: Bool, trip: Bool = false, surfaces: Bool = false, guide: Bool = false) -> PresentationDetent {
        switch self {
        case .peek: return .height(Self.peekHeight(drive: drive, trip: trip, surfaces: surfaces, guide: guide))
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

/// What decides the peek detent's height (`SheetDetentUI.peekHeight`). Owner report (Build 36,
/// «اهتزاز النافذة السفلية»): it must not change because the sheet moved, nor while a finger is on
/// the screen — SwiftUI re-snaps the native sheet whenever its detent SET changes, so a peek height
/// that changed when the sheet was raised/lowered (or mid-drag) made the sheet jump by itself.
struct LiveSheetShape: Equatable {
    var drive: Bool
    /// The quick row sits under the summary line at peek (`LiveScreenRules.peekShowsQuickRow`).
    var trip: Bool
    /// Guiding on a route with dirt or off-road: the surfaces' line under the guidance numbers. Decided per
    /// route (not per tick), so the detent set changes at most when the route does.
    var surfaces = false
    /// Guiding with the v2 bar (`NavDriveLayout`): its footer row under the numbers.
    var guide = false

    var peekHeight: CGFloat { SheetDetentUI.peekHeight(drive: drive, trip: trip, surfaces: surfaces, guide: guide) }

    /// The shape the sheet uses now: the one frozen when a finger went down, else the live one.
    static func resolve(live: LiveSheetShape, frozen: LiveSheetShape?) -> LiveSheetShape { frozen ?? live }
}

/// Native sheet styling for the live outing sheet: three detents, the map
/// stays interactive up to «نصف», never dismissible by swipe, Liquid Glass
/// background on iOS 26 (system default at partial heights), opaque surface
/// in drive mode / solid panel look / fallback.
private struct SarySheetPresentation: ViewModifier {
    @Binding var detent: SheetDetentUI
    /// The live screen passes it (held still during a touch); nil: the theme's drive, no quick row.
    var shape: LiveSheetShape?
    @Environment(\.sary) private var theme

    func body(content: Content) -> some View {
        let drive = shape?.drive ?? theme.drive
        let trip = shape?.trip ?? false
        let surfaces = shape?.surfaces ?? false
        let guide = shape?.guide ?? false
        let binding = Binding<PresentationDetent>(
            get: { detent.presentationDetent(drive: drive, trip: trip, surfaces: surfaces, guide: guide) },
            set: { detent = SheetDetentUI($0, drive: drive) }
        )
        content
            .presentationDetents(Set(SheetDetentUI.allCases.map { $0.presentationDetent(drive: drive, trip: trip, surfaces: surfaces, guide: guide) }), selection: binding)
            .presentationBackgroundInteraction(.enabled(upThrough: .medium))
            .presentationDragIndicator(.visible)
            /* `.resizes` (was `.scrolls`): a drag on the content resizes the sheet until it reaches its
             * largest detent, and only then scrolls. With `.scrolls` the half-height ScrollView took the
             * drag, so the sheet followed the finger only on the summary / handle strip. */
            .presentationContentInteraction(.resizes)
            .interactiveDismissDisabled()
            .modifier(SheetBackground())
            .saryHaptic(.selection, trigger: detent)
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
    func sarySheetPresentation(detent: Binding<SheetDetentUI>, shape: LiveSheetShape? = nil) -> some View {
        modifier(SarySheetPresentation(detent: detent, shape: shape))
    }
}

// MARK: - Sheet header

/// THE header of every sheet that is not a `SaryPage`: one title style (`.title2`), an optional
/// subtitle, optional trailing controls and the one close control (`SaryIconButton`, ≥ 44 pt).
/// UI-AUDIT §و: there were four header styles; this is the one left.
struct SarySheetHeader<Trailing: View>: View {
    var title: String
    var subtitle: String? = nil
    var closeLabel: String = "إغلاق"
    var closeID: String? = nil
    var close: (() -> Void)? = nil
    @ViewBuilder var trailing: Trailing
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        HStack(alignment: .center, spacing: theme.space(.s)) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .saryText(.title2)
                    .foregroundStyle(p.textPrimary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle).saryText(.footnote).foregroundStyle(p.textSecondary).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            trailing
            if let close {
                SaryIconButton(systemImage: SaryIcon.close, label: closeLabel, id: closeID, action: close)
            }
        }
    }
}

extension SarySheetHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, closeLabel: String = "إغلاق", closeID: String? = nil, close: (() -> Void)? = nil) {
        self.init(title: title, subtitle: subtitle, closeLabel: closeLabel, closeID: closeID, close: close, trailing: { EmptyView() })
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
    /// A solo outing (docs/SOLO-OUTING.md): no count of people, «على جوالك فقط» instead.
    var localOnly = false
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
                Group {
                    if localOnly {
                        Label(ended ? SaryCopy.outingEnded : SoloCopy.localOnlyLong, systemImage: "lock.fill")
                            .saryText(.callout, weight: .bold)
                            .foregroundStyle(p.textSecondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    } else {
                        summaryText(count: participants.count, live: live, nearest: nearest)
                    }
                }
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
        .accessibilityLabel(Text(localOnly ? (ended ? SaryCopy.outingEnded : SoloCopy.localOnlyLong)
                                 : ended ? "\(SaryFormat.number(participants.count)) في الطلعة، انتهت الطلعة" : SaryFormat.peekSummary(participants)))
        .accessibilityHint(Text(detent == .peek && !localOnly ? "اضغط لعرض المشاركين" : ""))
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
            options: LiveTabUI.sheetTabs,
            selection: $selection,
            label: { $0.label },
            systemImage: { tab in
                switch tab {
                case .trip: return "flag.checkered"
                case .group: return "person.2.fill"
                case .more: return "gearshape"
                case .map: return "map"
                }
            },
            badge: { $0 == .group ? groupBadge : 0 },
            optionID: { tab in
                switch tab {
                case .trip: return "tab.trip"
                case .group: return "tab.group"
                case .more: return "tab.settings"
                case .map: return "tab.map"
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
