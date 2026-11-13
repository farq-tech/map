import SwiftUI

/// Alerts stacked UNDER the status capsule (never over it), newest first,
/// at most `limit` visible (2 by default: a burst of stuck + convoy + silence +
/// weather must not bury the map); the rest collapse into «+٢ تنبيهات», which
/// expands the lane on tap and folds it back with «إخفاء».
struct SaryAlertLane: View {
    var alerts: [LiveAlertUI]
    var limit = SaryAlertLane.defaultLimit
    var tapped: (String) -> Void = { _ in }
    var dismiss: (String) -> Void = { _ in }
    var voice: VoiceBannerActions = .init()
    var silent: SilentAlertActions = .init()
    /// The screen's own state when it must react (the plan pills step aside while expanded).
    var expandedState: Binding<Bool>? = nil
    /// An expanded burst scrolls inside this height instead of pushing into the map controls.
    var maxExpandedHeight: CGFloat = 420
    @Environment(\.sary) private var theme
    @State private var localExpanded = false
    @State private var expandedContentHeight: CGFloat = 0

    static let defaultLimit = 2

    private var expanded: Bool {
        get { expandedState?.wrappedValue ?? localExpanded }
        nonmutating set { if let b = expandedState { b.wrappedValue = newValue } else { localExpanded = newValue } }
    }

    /// «+١ تنبيه» / «+٢ تنبيهات».
    static func overflowLabel(_ hidden: Int) -> String {
        "+\(SaryFormat.number(hidden)) \(hidden == 1 ? "تنبيه" : "تنبيهات")"
    }

    static func isToast(_ alert: LiveAlertUI) -> Bool {
        if case .toast = alert.kind { return true }
        return false
    }

    /// What the lane shows: the first `limit`, or all of them once expanded.
    static func visible(_ alerts: [LiveAlertUI], limit: Int, expanded: Bool) -> (shown: [LiveAlertUI], hidden: Int) {
        let l = max(1, limit)
        if expanded || alerts.count <= l { return (alerts, 0) }
        return (Array(alerts.prefix(l)), alerts.count - l)
    }

    var body: some View {
        let v = Self.visible(alerts, limit: limit, expanded: expanded)
        VStack(spacing: theme.space(.s)) {
            if expanded {
                /* As tall as its cards, up to `maxExpandedHeight`; beyond that it scrolls. */
                ScrollView(showsIndicators: false) {
                    cards(v.shown)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { expandedContentHeight = $0 }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: min(max(expandedContentHeight, 1), maxExpandedHeight))
            } else {
                cards(v.shown)
            }
            if v.hidden > 0 || (expanded && alerts.count > max(1, limit)) {
                Button { expanded.toggle() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .saryGlyph(11, weight: .bold)
                        Text(expanded ? "إخفاء" : Self.overflowLabel(v.hidden))
                            .saryText(.caption, weight: .bold)
                    }
                    .foregroundStyle(theme.palette.textSecondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .saryGlass(Capsule(), role: .control)
                    .frame(minHeight: theme.minTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(SaryPressStyle())
                .transition(SaryTransition.chipPop(theme))
                .accessibilityIdentifier("alerts.more")
                .accessibilityLabel(Text(expanded ? "إخفاء التنبيهات" : "\(Self.overflowLabel(v.hidden))، اعرضها"))
            }
        }
        .animation(theme.animation(.enter), value: v.shown.map(\.id))
        .animation(theme.animation(.snappy), value: expanded)
        .onChange(of: alerts.count) { _, n in if n <= max(1, limit) { expanded = false } }
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }

    private func cards(_ list: [LiveAlertUI]) -> some View {
        VStack(spacing: theme.space(.s)) {
            ForEach(list) { alert in
                SaryAlertCard(alert: alert, tapped: { tapped(alert.id) }, dismiss: { dismiss(alert.id) }, voice: voice, silent: silent)
                    /* Spatial continuity: cards come down out of the status capsule they sit
                     * under, and leave in place (fade + settle) rather than flying off. A toast
                     * only rises a little. Both cross-fade under Reduce Motion. */
                    .transition(Self.isToast(alert) ? SaryTransition.toast(theme) : SaryTransition.banner(theme))
            }
        }
    }
}

struct SaryAlertCard: View {
    var alert: LiveAlertUI
    var tapped: () -> Void = {}
    var dismiss: () -> Void = {}
    var voice: VoiceBannerActions = .init()
    var silent: SilentAlertActions = .init()
    @Environment(\.sary) private var theme
    @Environment(\.convoyAlertActions) private var convoyActions

    var body: some View {
        switch alert.kind {
        case .silent(let s):
            SarySilentCard(alert: s, tapped: tapped, dismiss: dismiss, actions: silent)
        case .offTrack(let o):
            card {
                Image(systemName: FollowIcon.offTrack)
                    .font(.system(size: theme.drive ? 20 : 15, weight: .bold))
                    .foregroundStyle(theme.palette.emergencyText)
                    .frame(width: theme.drive ? 48 : 36, height: theme.drive ? 48 : 36)
                    .background(Circle().fill(theme.palette.emergency.opacity(0.18)))
            } content: {
                VStack(alignment: .leading, spacing: 1) {
                    Text("خرجت عن المسار").saryText(theme.drive ? .headline : .callout, weight: .bold)
                        .foregroundStyle(theme.palette.textPrimary).lineLimit(1)
                    Text("على بعد \(SaryFormat.distance(meters: o.meters)) من «\(o.trackName)» · ارجع باتجاه السهم")
                        .saryNumber(.footnote, weight: detailWeight).foregroundStyle(theme.palette.textSecondary).lineLimit(2)
                }
            }
            .accessibilityLabel(Text("خرجت عن المسار، على بعد \(SaryFormat.distance(meters: o.meters)) من \(o.trackName)"))
            .accessibilityIdentifier("alert.offTrack")
        case .toast(let text):
            Text(text)
                .saryText(.subhead, weight: .bold)
                .foregroundStyle(theme.palette.textPrimary)
                .padding(.horizontal, theme.space(.l))
                .padding(.vertical, theme.space(.s) + 2)
                .saryGlass(Capsule(), role: .panel)
                .accessibilityAddTraits(.isStaticText)
        case .note(let name, let color, let text):
            card {
                SaryAvatar(name: name, color: color, size: 32)
            } content: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).saryText(.footnote, weight: .bold).foregroundStyle(theme.palette.textSecondary)
                    Text(text).saryText(.callout).foregroundStyle(theme.palette.textPrimary).lineLimit(2)
                }
            }
            .accessibilityLabel(Text("رسالة من \(name): \(text)"))
        case .drift(let name, let color, let meters):
            card {
                ZStack(alignment: .bottomTrailing) {
                    Image(systemName: SaryIcon.warning)
                        .font(.system(size: theme.drive ? 20 : 15, weight: .bold))
                        .foregroundStyle(theme.palette.warningText)
                        .frame(width: theme.drive ? 48 : 36, height: theme.drive ? 48 : 36)
                        .background(Circle().fill(theme.palette.warning.opacity(0.18)))
                    Circle().fill(Color(rgb: color)).frame(width: 12, height: 12)
                        .overlay(Circle().stroke(theme.palette.background, lineWidth: 2))
                }
            } content: {
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(name) ابتعد عن الأصدقاء").saryText(theme.drive ? .headline : .callout, weight: .bold)
                        .foregroundStyle(theme.palette.textPrimary).lineLimit(2)
                    Text("على بعد \(SaryFormat.distance(meters: meters))").saryNumber(.footnote, weight: detailWeight)
                        .foregroundStyle(theme.palette.textSecondary)
                }
            }
            .accessibilityLabel(Text("\(name) ابتعد عن الأصدقاء، على بعد \(SaryFormat.distance(meters: meters))"))
        case .weather(let w):
            card {
                WeatherAlertLeading(alert: w)
            } content: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(w.title).saryText(theme.drive ? .headline : .callout, weight: .bold).foregroundStyle(theme.palette.textPrimary).lineLimit(2)
                    Text(w.detail).saryNumber(.footnote, weight: detailWeight).foregroundStyle(theme.palette.textSecondary).lineLimit(w.kind == .flood ? 4 : (theme.drive ? 2 : 3))
                }
            }
            .accessibilityLabel(Text("\(w.title). \(w.detail)"))
            .accessibilityIdentifier("alert.weather.\(w.kind.rawValue)")
        case .voice(let clip):
            SaryVoiceBanner(clip: clip, play: { voice.play(clip.id) }, dismiss: { voice.dismiss(clip.id) })
        case .safety(let s):
            SafetyAlertCard(alert: s, tapped: tapped, dismiss: dismiss)
        case .convoy(let c):
            VStack(spacing: theme.space(.xs)) {
                card {
                    ZStack(alignment: .bottomTrailing) {
                        Image(systemName: c.symbol)
                            .font(.system(size: theme.drive ? 20 : 15, weight: .bold))
                            .foregroundStyle(theme.palette.warningText)
                            .frame(width: theme.drive ? 48 : 36, height: theme.drive ? 48 : 36)
                            .background(Circle().fill(theme.palette.warning.opacity(0.18)))
                        Circle().fill(Color(rgb: c.color)).frame(width: 12, height: 12)
                            .overlay(Circle().stroke(theme.palette.background, lineWidth: 2))
                    }
                } content: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(c.title).saryText(theme.drive ? .headline : .callout, weight: .bold)
                            .foregroundStyle(theme.palette.textPrimary).lineLimit(2)
                        Text(c.detail).saryNumber(.footnote, weight: detailWeight)
                            .foregroundStyle(theme.palette.textSecondary)
                    }
                }
                .accessibilityLabel(Text("القافلة: \(c.title)، \(c.detail)"))
                .accessibilityIdentifier("convoy-alert")
                convoyButtons(c)
            }
        }
    }

    /// A card's second line: medium at rest, bold in drive mode so it still reads in sun glare.
    private var detailWeight: SaryWeight { theme.drive ? .bold : .medium }

    /// «اتجه» on the return-to-rally prompt; «ارجعوا لنقطة التجمع» on separation / stop for leaders.
    @ViewBuilder
    private func convoyButtons(_ c: ConvoyAlertUI) -> some View {
        if c.kind == .returnToRally {
            Button(action: convoyActions.goToRally) { SaryButtonLabel(title: "اتجه", systemImage: SaryIcon.directions) }
                .buttonStyle(.sary(.primary, compact: true))
                .accessibilityIdentifier("convoy.goRally")
        } else if c.kind == .separated || c.kind == .unexpectedStop, let recall = convoyActions.recall {
            Button(action: recall) { SaryButtonLabel(title: "ارجعوا لنقطة التجمع", systemImage: SaryIcon.rally) }
                .buttonStyle(.sary(.secondary, compact: true))
                .accessibilityIdentifier("convoy.recall")
        }
    }

    private func card<L: View, C: View>(@ViewBuilder leading: () -> L, @ViewBuilder content: () -> C) -> some View {
        HStack(spacing: theme.space(.m)) {
            Button(action: tapped) {
                HStack(spacing: theme.space(.m)) {
                    leading()
                    content().frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            SaryDismissButton(action: dismiss)
        }
        .padding(.leading, theme.space(.m))
        .padding(.trailing, theme.space(.xs))
        .padding(.vertical, theme.space(.s))
        .frame(minHeight: theme.minTarget + 12)
        .saryGlass(RoundedRectangle(cornerRadius: SaryRadius.l, style: .continuous), role: .panel)
        .accessibilityElement(children: .combine)
    }
}

struct SaryDismissButton: View {
    var action: () -> Void
    @Environment(\.sary) private var theme
    var body: some View {
        Button(action: action) {
            Image(systemName: SaryIcon.close)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(theme.palette.textSecondary)
                .frame(width: 26, height: 26)
                .background(Circle().fill(theme.palette.textPrimary.opacity(0.08)))
                .frame(width: theme.minTarget, height: theme.minTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(SaryPressStyle())
        .accessibilityLabel(Text("إغلاق"))
    }
}

/// Voice clip from a friend: play/stop, progress, fixed-width duration.
struct SaryVoiceBanner: View {
    var clip: VoiceClipUI
    var play: () -> Void = {}
    var dismiss: () -> Void = {}
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        let progress: Double = { if case .playing(let x) = clip.playback { return x }; return 0 }()
        let playing: Bool = { if case .playing = clip.playback { return true }; return false }()
        HStack(spacing: theme.space(.m)) {
            Button(action: play) {
                ZStack {
                    Circle().fill(Color(rgb: clip.senderColor))
                    if clip.playback == .loading {
                        ProgressView().tint(SaryCarColors.ink(on: clip.senderColor))
                    } else {
                        Image(systemName: playing ? SaryIcon.stop : SaryIcon.play)
                            .font(.system(size: 15, weight: .heavy))
                            .foregroundStyle(SaryCarColors.ink(on: clip.senderColor))
                            .contentTransition(.symbolEffect(.replace))
                            .environment(\.layoutDirection, .leftToRight)
                    }
                }
                .frame(width: theme.drive ? 52 : 40, height: theme.drive ? 52 : 40)
                .overlay {
                    if SaryCarColors.needsOutline(clip.senderColor, onDark: !theme.isLight) {
                        Circle().stroke(p.textTertiary, lineWidth: 1)
                    }
                }
                /* Small circle, full touch target (like `SaryDismissButton`). */
                .frame(width: theme.minTarget, height: theme.minTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(SaryPressStyle())
            .accessibilityLabel(Text(playing ? "إيقاف الرسالة الصوتية" : "تشغيل رسالة \(clip.senderName) الصوتية"))
            .saryHaptic(.selection, trigger: playing)

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(clip.senderName).saryText(.callout, weight: .bold).foregroundStyle(p.textPrimary).lineLimit(1).minimumScaleFactor(0.85)
                    Spacer(minLength: 4)
                    Text(SaryFormat.clock(seconds: playing ? Int(Double(clip.durationSeconds) * progress) : clip.durationSeconds))
                        .saryNumber(.footnote, weight: .medium)
                        .foregroundStyle(p.textSecondary)
                }
                SaryWaveform(progress: progress, color: Color(rgb: clip.senderColor == 0x15191C ? 0x9AA5AD : clip.senderColor))
                    .frame(height: 16)
                    .environment(\.layoutDirection, .leftToRight)
            }
            SaryDismissButton(action: dismiss)
        }
        .padding(.leading, theme.space(.m))
        .padding(.trailing, theme.space(.xs))
        .padding(.vertical, theme.space(.s))
        .saryGlass(RoundedRectangle(cornerRadius: SaryRadius.l, style: .continuous), role: .panel)
        .accessibilityElement(children: .contain)
    }
}

/// Deterministic bar waveform with played portion highlighted. Plays left→right
/// like the media it represents (not mirrored).
struct SaryWaveform: View {
    var progress: Double
    var color: Color
    var bars = 28
    @Environment(\.sary) private var theme

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width / CGFloat(bars)
            HStack(alignment: .center, spacing: 0) {
                ForEach(0..<bars, id: \.self) { i in
                    let h = 0.3 + 0.7 * abs(sin(Double(i) * 1.7) * cos(Double(i) * 0.45))
                    Capsule()
                        .fill(Double(i) / Double(bars) < progress ? color : theme.palette.textTertiary.opacity(0.45))
                        .frame(width: max(2, w * 0.55), height: geo.size.height * h)
                        .frame(width: w)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .accessibilityHidden(true)
    }
}
