import SwiftUI

/// «اضغط وتكلم». Press and hold to record; release to send; drag far away to
/// cancel. States come from `PTTStateUI` (idle / arming / recording / sending).
struct SaryPTTButton: View {
    var state: PTTStateUI
    var actions: PTTActions = .init()
    /// Show the caption under the disc (off for tight layouts).
    var showsCaption = true

    @Environment(\.sary) private var theme
    @State private var pressing = false
    @State private var cancelled = false
    @State private var pulse = false

    var body: some View {
        let p = theme.palette
        let size = theme.bigButton
        VStack(spacing: theme.space(.xs)) {
            ZStack {
                // Recording halo
                if case .recording = state {
                    Circle().fill(p.accent.opacity(0.28))
                        .frame(width: size, height: size)
                        .scaleEffect(pulse ? 1.32 : 1.05)
                        .opacity(pulse ? 0 : 0.9)
                }
                disc(size: size)
            }
            .frame(width: size + 16, height: size + 16)
            .contentShape(Circle())
            .gesture(pressGesture(size: size))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("اضغط وتكلم"))
            .accessibilityValue(Text(stateLabel))
            .accessibilityHint(Text("اضغط مطولًا للتسجيل وارفع إصبعك للإرسال"))
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("outing-ptt")

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
            }
        }
        .onChange(of: isRecording) { _, rec in
            guard rec, !theme.reduceMotion else { pulse = false; return }
            pulse = false
            withAnimation(.easeOut(duration: 1.1).repeatForever(autoreverses: false)) { pulse = true }
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: isRecording) { _, new in new }
        .sensoryFeedback(.success, trigger: state == .sending) { _, new in new }
        .animation(theme.animation(.snappy), value: state)
    }

    private var isRecording: Bool { if case .recording = state { return true }; return false }

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
            case .recording:
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
            case .sending:
                Circle().fill(p.accent.opacity(0.85))
                    .frame(width: size, height: size)
                    .overlay {
                        Image(systemName: SaryIcon.send)
                            .font(.system(size: size * 0.34, weight: .heavy))
                            .foregroundStyle(p.onAccent)
                            .symbolEffect(.bounce, value: state == .sending)
                    }
            }
        }
        .scaleEffect(pressing && !theme.reduceMotion ? 1.06 : 1)
        .opacity(cancelled ? 0.5 : 1)
    }

    private var stateLabel: String {
        switch state {
        case .idle: return "اضغط وتكلم"
        case .arming: return "جارٍ التجهيز…"
        case .recording(let s): return cancelled ? "اترك للإلغاء" : "يسجّل \(SaryFormat.clock(seconds: s))"
        case .sending: return "جارٍ الإرسال…"
        }
    }

    private var captionColor: Color {
        switch state {
        case .recording: return cancelled ? theme.palette.emergencyText : theme.palette.accentText
        default: return theme.palette.textPrimary
        }
    }

    private func pressGesture(size: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                if !pressing {
                    pressing = true
                    cancelled = false
                    actions.pressBegan()
                }
                let far = hypot(v.translation.width, v.translation.height) > size * 1.2
                if far != cancelled { cancelled = far }
            }
            .onEnded { _ in
                pressing = false
                if cancelled { actions.cancelled() } else { actions.pressEnded() }
                cancelled = false
            }
    }
}
