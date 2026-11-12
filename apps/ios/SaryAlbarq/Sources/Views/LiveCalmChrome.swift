import SwiftUI

/// «تخفيف الزحمة» (phase A, styled after the owner's Lovable prototype): the small pieces of
/// the calm live screen. The rules live in `LiveCalmRules` (unit-tested in `LiveCalmTests`).
enum LiveCalmRules {
    /// The convoy at a glance while driving: «٤ مباشر · الأبعد ١٫٢ كم» (friends only, never me).
    static func convoyLine(_ participants: [ParticipantUI]) -> String? {
        let others = participants.filter { !$0.isMe }
        guard !others.isEmpty else { return nil }
        let live = others.filter { $0.presence.isLive }
        /* UX ٢١: «٠ مباشر» is noise — nothing to say until somebody is live. */
        guard !live.isEmpty else { return nil }
        var parts = ["\(SaryFormat.number(live.count)) مباشر"]
        if let far = live.compactMap(\.distanceMeters).max() {
            parts.append("الأبعد \(SaryFormat.distance(meters: far))")
        }
        return parts.joined(separator: " · ")
    }

    /// The layers button leads the side column in EVERY mode (stopped, driving, exploring, guiding, after the end);
    /// it never counts toward the two-button limit below. Pure: a duplicate is dropped, order of the rest kept.
    static func withLayers(_ items: [SaryMapControlItem], layers: SaryMapControlItem) -> [SaryMapControlItem] {
        [layers] + items.filter { $0.id != layers.id }
    }

    /// The side column per sheet height. Peek: everything. Half: the layers button alone (owner's Build 44 report: «خلال الطلعة لا يمكنني
    /// الضغط على الطبقات» — with the sheet raised the whole column, layers included, was gone, so there was nothing to press).
    /// Full: nothing (the sheet covers the map).
    static func sideItems(_ items: [SaryMapControlItem], detent: SheetDetentUI) -> [SaryMapControlItem] {
        switch detent {
        case .peek: return items
        case .half: return items.filter { $0.id == "layers" }
        default: return []
        }
    }

    /// The round buttons on the map's side (stopped): «تتبعني» and «أدوات» only, plus «طريق العودة»
    /// when it fits the moment; after the end, the camera alone. Driving: none.
    static func sideItems(camera: SaryMapControlItem, backTrack: SaryMapControlItem?, plusBadge: Int?,
                          driving: Bool, ended: Bool) -> [SaryMapControlItem] {
        guard !driving else { return [] }
        /* «أدوات» («+») is no longer on the map: it is «المزيد» at the end of the sheet's quick row
         * (UX simplification — one way in, not two). `plusBadge` rides on that button now. */
        var items = [camera]
        if let backTrack { items.append(backTrack) }
        return items
    }
}

/// Motion on the live screen (pure, unit-tested in `LiveDeclutterTests`): it says what changed and
/// stays almost still while driving (no stagger, no travel, quicker springs).
enum LiveMotion {
    /// The gap between items of a row appearing one after another.
    static let staggerStep: Double = 0.04
    /// Items past this one appear together (a long row never trails off).
    static let staggerMaxIndex = 4
    /// How far an item rises as it appears (pt).
    static let rise: CGFloat = 6

    /// The delay before item `index` of a row appears: none while driving or with Reduce Motion.
    static func staggerDelay(index: Int, drive: Bool, reduceMotion: Bool) -> Double {
        guard !drive, !reduceMotion, index > 0 else { return 0 }
        return Double(min(index, staggerMaxIndex)) * staggerStep
    }

    /// The rise of an appearing item: a fade only while driving or with Reduce Motion.
    static func riseOffset(drive: Bool, reduceMotion: Bool) -> CGFloat {
        drive || reduceMotion ? 0 : rise
    }

    /// The primary button's morph between states: smooth when stopped, quicker while driving.
    static func primaryMorph(drive: Bool) -> SaryMotion { drive ? .snappy : .smooth }

    /// The people list re-ordering (who is nearest, who went quiet).
    static func reorder(drive: Bool) -> SaryMotion { drive ? .snappy : .smooth }
}

/// One item of a row appearing in turn (`LiveMotion.staggerDelay`) when the row is inserted:
/// a small rise and fade, once. It never re-runs on updates (only on insertion).
struct LiveStaggerIn: ViewModifier {
    var index: Int
    @Environment(\.sary) private var theme
    @State private var shown = false

    func body(content: Content) -> some View {
        let still = theme.reduceMotion
        content
            .opacity(shown || still ? 1 : 0)
            .offset(y: shown ? 0 : LiveMotion.riseOffset(drive: theme.drive, reduceMotion: theme.reduceMotion))
            .onAppear {
                guard !shown else { return }
                let delay = LiveMotion.staggerDelay(index: index, drive: theme.drive, reduceMotion: theme.reduceMotion)
                withAnimation(theme.animation(theme.drive ? .snappy : .appear).delay(delay)) { shown = true }
            }
    }
}

extension View {
    /// See `LiveStaggerIn`.
    func liveStaggerIn(_ index: Int) -> some View { modifier(LiveStaggerIn(index: index)) }
}

/// Lovable's caption under a round button: 11 pt bold on a dark pill (was 10 pt regular,
/// unreadable in sun).
struct LovableCaption: View {
    var text: String
    @Environment(\.sary) private var theme
    var body: some View {
        Text(text)
            .saryText(.micro, weight: .bold)
            .foregroundStyle(theme.palette.textSecondary)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 6)
            /* The pill keeps its 15 pt at rest (layout unchanged); drive mode's bigger text gets 18. */
            .frame(height: theme.drive ? 18 : 15)
            .background(Capsule().fill(Color.black.opacity(0.6)))
            .dynamicTypeSize(...DynamicTypeSize.xLarge)
            .accessibilityHidden(true)
    }
}

/// Separate 48 pt round buttons, each with its caption under it («تتبعني»، «أدوات»). The tools
/// button is filled orange (Lovable); the others are dark glass.
struct LiveSideButtons: View {
    var items: [SaryMapControlItem]
    var action: (String) -> Void
    /// The map's bearing: when it is turned, the camera button shows the north (it was a separate compass).
    var bearing: Double = 0
    /// Captions under the buttons (off while guiding: four bare circles, labels for VoiceOver).
    var captions = true
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        VStack(spacing: 10) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                let filled = item.id == "actions" || item.isActive
                VStack(spacing: 4) {
                    Button { action(item.id) } label: {
                        let turned = item.id == "locate" && !item.isActive && abs(Self.wrap(bearing)) > 3
                        Image(systemName: item.id == "actions" ? "plus" : (item.id == "locate" ? (turned ? "location.north.line.fill" : (captions ? "scope" : item.systemImage)) : item.systemImage))
                            .rotationEffect(.degrees(turned ? -bearing : 0))
                            .font(.system(size: item.id == "actions" ? 22 : 20, weight: .semibold))
                            .foregroundStyle(filled ? p.onAccent : p.textPrimary)
                            .contentTransition(.symbolEffect(.replace))
                            .frame(width: theme.drive ? 60 : 48, height: theme.drive ? 60 : 48)
                            .background { if filled { Circle().fill(p.accent) } }
                            .saryGlass(Circle(), role: .chrome, interactive: true)
                            .overlay(alignment: .topTrailing) {
                                if let b = item.badge, b > 0 {
                                    Text(SaryFormat.number(b)).saryNumber(.micro, weight: .heavy).foregroundStyle(p.onEmergency)
                                        .frame(minWidth: 17, minHeight: 17)
                                        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                                        .background(Circle().fill(p.emergency))
                                        .saryBadgeOutset(trailing: 3, top: 3)
                                }
                            }
                    }
                    .buttonStyle(SaryPressStyle())
                    .accessibilityLabel(Text(item.label))
                    .accessibilityHint(Text(item.hint ?? ""))
                    .accessibilityValue(Text(item.value ?? ""))
                    .accessibilityAddTraits(item.isActive ? .isSelected : [])
                    .accessibilityIdentifier(item.accessibilityID)
                    if captions { LovableCaption(text: item.label) }
                }
                /* The column comes back when the sheet settles at its peek: the buttons in turn. */
                .liveStaggerIn(index)
            }
        }
        .animation(theme.animation(.snappy), value: items)
    }

    static func wrap(_ d: Double) -> Double { var x = d.truncatingRemainder(dividingBy: 360); if x > 180 { x -= 360 }; if x < -180 { x += 360 }; return x }
}

/// SOS (Lovable): a red disc with «SOS · طوارئ» under the header on the left, «اضغط مطوّل» under it.
/// A 1 s hold, then a 3 s «تراجع» countdown (`SOSCountdown`). Never hidden while the trip runs.
struct LovableSOS: View {
    var state: MySOSUI
    var size: CGFloat
    var trigger: () -> Void
    /// False in a solo outing: no «نرسل طوارئ…» countdown (`SarySOSButton.countdown`).
    var countdown = true

    var body: some View {
        VStack(spacing: 4) {
            SarySOSButton(state: state, trigger: trigger, size: size, compactLabel: true, countdown: countdown)
                .padding(4)
                .chromeFrame("sos")
            LovableCaption(text: "اضغط مطوّل")
        }
    }
}

/// The speed (Lovable): a 76 pt dark disc, the number big, «كم/س» under it.
struct LovableSpeedBubble: View {
    var ui: SpeedometerUI
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        let kmh = ui.current.kmh.map { Int($0.rounded()) }
        VStack(spacing: 0) {
            /* Tabular digits (no jitter while it ticks) that grow with the drive scale like
             * every other number: 26 pt at rest, 30 pt in drive mode. */
            Text(kmh.map { SaryFormat.number($0) } ?? "—")
                .saryNumber(.title, weight: .heavy)
                .foregroundStyle(ui.overLimit ? p.emergencyText : p.textPrimary)
                .contentTransition(SaryTransition.number(Double(kmh ?? 0), theme))
                /* Rolls on the speed readings that already arrive (no extra updates). */
                .animation(theme.animation(.snappy), value: kmh)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text("كم/س").saryText(.caption, weight: .bold).foregroundStyle(p.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 8)
        /* A fixed 76 pt disc: its text follows Dynamic Type only as far as `SarySpeedometer` does. */
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
        .frame(width: 76, height: 76)
        .background(Circle().fill(p.chromeOpaque.opacity(theme.drive ? 1 : 0.88)))
        .saryGlass(Circle(), role: .chrome)
        .overlay { if ui.overLimit { Circle().stroke(p.emergency, lineWidth: 3) } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(kmh.map { "السرعة \(SaryFormat.number($0)) كم/س" } ?? "السرعة غير معروفة"))
        .accessibilityIdentifier("speedometer")
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
                Circle().fill(theme.palette.live).frame(width: theme.drive ? 10 : 8, height: theme.drive ? 10 : 8)
                /* Primary while driving: the ramp's footnote (15 pt in drive mode), bold. */
                Text(text)
                    .saryText(.footnote, weight: .bold)
                    .foregroundStyle(theme.palette.textPrimary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .saryGlass(Capsule(), role: .chrome, interactive: true)
        }
        .buttonStyle(SaryPressStyle())
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .accessibilityLabel(Text("القافلة: \(text)"))
        .accessibilityHint(Text("يفتح الأصدقاء"))
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
            /* Secondary chrome: it steps back in drive mode so the alert beside it leads. */
            Image(systemName: open ? "xmark" : "clock.arrow.circlepath")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.drive && !open ? theme.palette.textSecondary : theme.palette.textPrimary)
                .frame(width: 44, height: 44)
                .saryGlass(Circle(), role: .chrome, interactive: true)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(SaryPressStyle())
        .accessibilityLabel(Text(open ? "أخفِ التنبيهات" : "سجل التنبيهات"))
        .accessibilityIdentifier("alerts.history")
    }
}
