import SwiftUI

/// Alerts stacked UNDER the status capsule (never over it), newest first,
/// at most `limit` visible; older ones collapse into «+٢ تنبيه».
struct SaryAlertLane: View {
    var alerts: [LiveAlertUI]
    var limit = 3
    var tapped: (String) -> Void = { _ in }
    var dismiss: (String) -> Void = { _ in }
    var voice: VoiceBannerActions = .init()
    @Environment(\.sary) private var theme

    var body: some View {
        VStack(spacing: theme.space(.s)) {
            ForEach(alerts.prefix(limit)) { alert in
                SaryAlertCard(alert: alert, tapped: { tapped(alert.id) }, dismiss: { dismiss(alert.id) }, voice: voice)
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .opacity.combined(with: .scale(scale: 0.96))
                    ))
            }
            if alerts.count > limit {
                Text("+\(SaryFormat.number(alerts.count - limit)) تنبيه")
                    .saryText(.caption)
                    .foregroundStyle(theme.palette.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .saryGlass(Capsule(), role: .control)
            }
        }
        .animation(theme.animation(.enter), value: alerts.map(\.id))
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }
}

struct SaryAlertCard: View {
    var alert: LiveAlertUI
    var tapped: () -> Void = {}
    var dismiss: () -> Void = {}
    var voice: VoiceBannerActions = .init()
    @Environment(\.sary) private var theme

    var body: some View {
        switch alert.kind {
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
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(theme.palette.warningText)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(theme.palette.warning.opacity(0.18)))
                    Circle().fill(Color(rgb: color)).frame(width: 12, height: 12)
                        .overlay(Circle().stroke(theme.palette.background, lineWidth: 2))
                }
            } content: {
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(name) ابتعد عن المجموعة").saryText(.callout, weight: .bold)
                        .foregroundStyle(theme.palette.textPrimary).lineLimit(2)
                    Text("على بعد \(SaryFormat.distance(meters: meters))").saryNumber(.footnote, weight: .medium)
                        .foregroundStyle(theme.palette.textSecondary)
                }
            }
            .accessibilityLabel(Text("\(name) ابتعد عن المجموعة، على بعد \(SaryFormat.distance(meters: meters))"))
        case .weather(let w):
            card {
                WeatherAlertLeading(alert: w)
            } content: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(w.title).saryText(.callout, weight: .bold).foregroundStyle(theme.palette.textPrimary).lineLimit(2)
                    Text(w.detail).saryNumber(.footnote, weight: .medium).foregroundStyle(theme.palette.textSecondary).lineLimit(theme.drive ? 2 : 3)
                }
            }
            .accessibilityLabel(Text("\(w.title). \(w.detail)"))
            .accessibilityIdentifier("alert.weather.\(w.kind.rawValue)")
        case .voice(let clip):
            SaryVoiceBanner(clip: clip, play: { voice.play(clip.id) }, dismiss: { voice.dismiss(clip.id) })
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
            }
            .buttonStyle(SaryPressStyle())
            .accessibilityLabel(Text(playing ? "إيقاف الرسالة الصوتية" : "تشغيل رسالة \(clip.senderName) الصوتية"))
            .sensoryFeedback(.impact(weight: .light), trigger: playing)

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(clip.senderName).saryText(.callout, weight: .bold).foregroundStyle(p.textPrimary).lineLimit(1)
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
