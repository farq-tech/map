import SwiftUI

/// «قناة الطلعة» — the walkie-talkie button. Hold to talk live to everyone in
/// the outing, let go to stop; one person at a time. While someone else talks
/// it shows who («فهد يتكلم») in their car colour. States: `PTTStateUI`.
struct SaryPTTButton: View {
    var state: PTTStateUI
    var actions: PTTActions = .init()
    /// Show the caption under the disc (off for tight layouts).
    var showsCaption = true
    /// Microphone level 0…1 while talking (drives the halo).
    var level: Float = 0

    @Environment(\.sary) private var theme
    @State private var pressing = false
    @State private var pulse = false

    var body: some View {
        let size = theme.bigButton
        VStack(spacing: theme.space(.xs)) {
            ZStack {
                halo(size: size)
                disc(size: size)
                if case let .talking(s, remaining) = state {
                    /* What is left of the minute, as a ring. */
                    Circle()
                        .trim(from: 0, to: CGFloat(remaining) / CGFloat(max(1, s + remaining)))
                        .stroke(theme.palette.onAccent.opacity(0.9), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: size - 6, height: size - 6)
                        .animation(theme.animation(.snappy), value: remaining)
                }
            }
            .frame(width: size + 16, height: size + 16)
            .contentShape(Circle())
            .gesture(pressGesture)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("قناة الطلعة، اضغط وتكلم"))
            .accessibilityValue(Text(stateLabel))
            .accessibilityHint(Text("اضغط مطولًا وتكلم، يسمعك أعضاء الطلعة مباشرة. ارفع إصبعك لتتوقف"))
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("outing-ptt")
            .accessibilityAction(named: Text("ابدأ التكلم")) { actions.pressBegan() }
            .accessibilityAction(named: Text("أوقف التكلم")) { actions.pressEnded() }

            if showsCaption {
                Text(stateLabel)
                    .saryNumber(.caption)
                    .foregroundStyle(captionColor)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .saryGlass(Capsule(), role: .control)
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .contentTransition(.numericText())
                    .accessibilityIdentifier("outing-ptt-caption")
            }
        }
        .onChange(of: isOnAir) { _, on in
            guard on, !theme.reduceMotion else { pulse = false; return }
            pulse = false
            withAnimation(.easeOut(duration: 1.1).repeatForever(autoreverses: false)) { pulse = true }
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: isTalking) { _, new in new }
        .sensoryFeedback(.selection, trigger: isListening) { _, new in new }
        .animation(theme.animation(.snappy), value: state)
    }

    private var isTalking: Bool { if case .talking = state { return true }; return false }
    private var isListening: Bool { if case .listening = state { return true }; return false }
    private var isOnAir: Bool { isTalking || isListening }

    @ViewBuilder
    private func halo(size: CGFloat) -> some View {
        let p = theme.palette
        switch state {
        case .talking:
            Circle().fill(p.accent.opacity(0.28))
                .frame(width: size, height: size)
                .scaleEffect(pulse ? 1.25 + CGFloat(level) * 0.25 : 1.05)
                .opacity(pulse ? 0 : 0.9)
        case let .listening(_, color):
            Circle().fill(Color(rgb: color).opacity(0.32))
                .frame(width: size, height: size)
                .scaleEffect(pulse ? 1.3 : 1.05)
                .opacity(pulse ? 0 : 0.9)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func disc(size: CGFloat) -> some View {
        let p = theme.palette
        ZStack {
            switch state {
            case .idle:
                Image(systemName: SaryIcon.mic)
                    .font(.system(size: size * 0.36, weight: .semibold))
                    .foregroundStyle(p.textPrimary)
                    .frame(width: size, height: size)
                    .saryGlass(Circle(), role: .control, interactive: true)
            case .arming:
                ProgressView().tint(p.accent)
                    .frame(width: size, height: size)
                    .saryGlass(Circle(), role: .control, tint: p.accent.opacity(0.25))
            case .talking:
                Circle().fill(p.accent)
                    .frame(width: size, height: size)
                    .overlay {
                        Image(systemName: "waveform")
                            .font(.system(size: size * 0.38, weight: .bold))
                            .foregroundStyle(p.onAccent)
                            .symbolEffect(.variableColor.iterative, isActive: !theme.reduceMotion)
                            .environment(\.layoutDirection, .leftToRight)
                    }
                    .shadow(color: p.accent.opacity(0.5), radius: 10, y: 2)
            case let .listening(_, color):
                Circle().fill(Color(rgb: color))
                    .frame(width: size, height: size)
                    .overlay {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.system(size: size * 0.34, weight: .bold))
                            .foregroundStyle(SaryCarColors.ink(on: color))
                            .symbolEffect(.variableColor.iterative, isActive: !theme.reduceMotion)
                            .environment(\.layoutDirection, .leftToRight)
                    }
                    .overlay(Circle().stroke(p.textPrimary.opacity(0.35), lineWidth: SaryCarColors.needsOutline(color, onDark: !theme.isLight) ? 1 : 0))
            case .muted, .unavailable:
                Image(systemName: state == .muted ? "speaker.slash.fill" : "mic.slash.fill")
                    .font(.system(size: size * 0.32, weight: .semibold))
                    .foregroundStyle(p.textSecondary)
                    .frame(width: size, height: size)
                    .saryGlass(Circle(), role: .control)
            }
        }
        .scaleEffect(pressing && !theme.reduceMotion ? 1.06 : 1)
    }

    private var stateLabel: String {
        switch state {
        case .idle: return "اضغط وتكلم"
        case .arming: return "جارٍ فتح القناة…"
        case let .talking(s, _): return "على الهواء \(SaryFormat.clock(seconds: s))"
        case let .listening(name, _): return "\(name) يتكلم"
        case .muted: return "القناة مكتومة"
        case .unavailable: return "القناة غير متاحة"
        }
    }

    private var captionColor: Color {
        switch state {
        case .talking: return theme.palette.accentText
        case .muted, .unavailable: return theme.palette.textSecondary
        default: return theme.palette.textPrimary
        }
    }

    /* Live audio: dragging away cannot "un-say" anything, so any release ends the transmission. */
    private var pressGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard !pressing else { return }
                pressing = true
                actions.pressBegan()
            }
            .onEnded { _ in
                pressing = false
                actions.pressEnded()
            }
    }
}
