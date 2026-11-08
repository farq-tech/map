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

/// Lovable's caption under a round button: 10 pt on a dark pill.
struct LovableCaption: View {
    var text: String
    @Environment(\.sary) private var theme
    var body: some View {
        Text(text)
            .font(.sary(10, .regular))
            .foregroundStyle(theme.palette.textSecondary)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 6)
            .frame(height: 15)
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
            ForEach(items) { item in
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
                                    Text(SaryFormat.number(b)).font(.sary(10, .heavy)).foregroundStyle(Color.white)
                                        .frame(minWidth: 17, minHeight: 17)
                                        .background(Circle().fill(p.emergency))
                                        .offset(x: 3, y: -3)
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

    var body: some View {
        VStack(spacing: 4) {
            SarySOSButton(state: state, trigger: trigger, size: size, compactLabel: true)
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
            Text(kmh.map { SaryFormat.number($0) } ?? "—")
                .font(.sary(26, .heavy))
                .foregroundStyle(ui.overLimit ? p.emergencyText : p.textPrimary)
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text("كم/س").font(.sary(11, .regular)).foregroundStyle(p.textSecondary)
        }
        .frame(width: 76, height: 76)
        .background(Circle().fill(p.chromeOpaque.opacity(0.88)))
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
                Circle().fill(theme.palette.live).frame(width: 8, height: 8)
                Text(text)
                    .font(.sary(13, .medium))
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
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.palette.textPrimary)
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
