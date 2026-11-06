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
    /// The wide «اضغط وتكلم» capsule of the calm live screen (the Lovable reference): the whole
    /// capsule talks; the channel is a separate label under it (never a long-press here).
    var pill = false
    /// Lovable: 200×68 while driving, 178×56 stopped.
    var big = false
    /// «تردد ١» under the title inside the capsule; tapping it opens the channels. It is its own
    /// target ABOVE the capsule (a sibling, not a child), so the talk gesture never sees that touch.
    var channelLabel: String? = nil
    var openChannels: (() -> Void)? = nil

    @Environment(\.sary) private var theme
    @State private var pressing = false
    @State private var pulse = false
    /// «طريقة اللاسلكي»: the wording follows what the button really does (tap to record vs hold).
    @AppStorage(PTTTalkMode.key) private var talkModeRaw = PTTTalkMode.default.rawValue

    private var notesMode: Bool { (PTTTalkMode(rawValue: talkModeRaw) ?? .default) == .notes }

    var body: some View {
        if pill { pillBody } else { discBody }
    }

    private var isQuiet: Bool { state == .unavailable || state == .muted }

    /// UX ٢١ (٤): «اللاسلكي واقف» stays on the button with its reason as long as it lasts
    /// (no 5-second toast that leaves a dim «اضغط وتكلم» behind).
    private var pillTitle: String { stateLabel }

    private var pillBody: some View {
        let p = theme.palette
        let h: CGFloat = big ? 68 : 56
        let d: CGFloat = big ? 26 : 20
        let fill: Color? = {
            switch state {
            case .idle, .arming: return p.accent
            case .talking: return p.accent
            case let .listening(_, color): return Color(rgb: color)
            case .muted, .unavailable: return nil
            }
        }()
        let ink: Color = {
            switch state {
            case let .listening(_, color): return SaryCarColors.ink(on: color)
            case .muted, .unavailable: return p.textSecondary
            default: return p.onAccent
            }
        }()
        let face = pillFace(h: h, d: d, fill: fill, ink: ink, placeholder: false)
        return ZStack {
        face
        .opacity(isQuiet ? 0.85 : 1)
        .scaleEffect(pressing && !theme.reduceMotion ? 1.04 : 1)
        .contentShape(Capsule())
        .gesture(pressGesture)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(a11yLabel))
        .accessibilityValue(Text(stateLabel))
        .accessibilityHint(Text(a11yHint))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("outing-ptt")
        .accessibilityAction(named: Text(notesMode ? "ابدأ التسجيل" : "ابدأ التكلم")) { actions.pressBegan() }
        .accessibilityAction(named: Text(notesMode ? "أرسل الرسالة" : "أوقف التكلم")) { notesMode ? actions.pressBegan() : actions.pressEnded() }
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .onChange(of: isOnAir) { _, on in
            guard on, !theme.reduceMotion else { pulse = false; return }
            pulse = false
            withAnimation(.easeOut(duration: 1.1).repeatForever(autoreverses: false)) { pulse = true }
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: isTalking) { _, new in new }
        .sensoryFeedback(.selection, trigger: isListening) { _, new in new }
        .animation(theme.animation(.snappy), value: state)
            if channelLabel != nil, openChannels != nil {
                pillFace(h: h, d: d, fill: nil, ink: ink, placeholder: true)
            }
        }
        .fixedSize()
    }

    /// The capsule's content. `placeholder`: the same layout, invisible, with only the channel
    /// label live (the sibling layer that takes the label's taps).
    @ViewBuilder
    private func pillFace(h: CGFloat, d: CGFloat, fill: Color?, ink: Color, placeholder: Bool) -> some View {
        let content = HStack(spacing: big ? 12 : 10) {
            pillIcon(d: d, ink: ink).opacity(placeholder ? 0 : 1).allowsHitTesting(!placeholder)
            VStack(alignment: .leading, spacing: 1) {
                pillText(ink: ink).opacity(placeholder ? 0 : 1).allowsHitTesting(!placeholder).accessibilityHidden(placeholder)
                if let c = channelLabel {
                    channelText(c, ink: ink, placeholder: placeholder)
                }
            }
        }
        .padding(.leading, big ? 26 : 20)
        .padding(.trailing, big ? 28 : 20)
        .frame(minWidth: big ? 200 : 178, minHeight: h, maxHeight: h)
        if placeholder {
            content.allowsHitTesting(true)
        } else {
            content
                .background { pillFill(fill) }
                .saryGlass(Capsule(), role: .control, interactive: fill == nil)
                .background { pillHalo(fill) }
        }
    }

    /// «تردد ١ ▾» — 13 pt bold (was 10 pt), the ▾ says it opens something (UX ٢١ ١٠).
    @ViewBuilder
    private func channelText(_ c: String, ink: Color, placeholder: Bool) -> some View {
        let t = Text(openChannels == nil ? c : "\(c) ▾")
            .font(.sary(big ? 14 : 13, .bold))
            .foregroundStyle(ink.opacity(0.9))
            .lineLimit(1)
        if placeholder {
            Button { openChannels?() } label: {
                /* Taller would reach the capsule's centre and steal the talk tap. */
                t.padding(.vertical, 6).padding(.horizontal, 10).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, -6).padding(.horizontal, -10)
            .accessibilityLabel(Text("التردد: \(c)"))
            .accessibilityHint(Text("اضغط لتغيّر التردد"))
            .accessibilityIdentifier("ptt-channel-chip")
        } else {
            t.opacity(openChannels == nil ? 1 : 0).accessibilityHidden(true)
        }
    }

    private func pillIcon(d: CGFloat, ink: Color) -> some View {
        ZStack {
            pillGlyph(ink: ink)
                .font(.system(size: d * 0.85, weight: .semibold))
                .foregroundStyle(ink)
                .environment(\.layoutDirection, .leftToRight)
            if isTalking { pillRing(ink: ink).frame(width: d + 12, height: d + 12) }
        }
        .frame(width: d + 4, height: d + 4)
    }

    private func pillText(ink: Color) -> some View {
        Text(pillTitle)
            .font(.sary(big ? 18 : 14, .bold))
            .foregroundStyle(ink)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .contentTransition(.numericText())
            .accessibilityIdentifier("outing-ptt-caption")
    }

    @ViewBuilder
    private func pillFill(_ fill: Color?) -> some View {
        if let fill {
            let glow: Double = isOnAir ? 0.55 : 0.3
            Capsule().fill(fill)
                .shadow(color: fill.opacity(glow), radius: isOnAir ? 14 : 8, y: 3)
        }
    }

    @ViewBuilder
    private func pillHalo(_ fill: Color?) -> some View {
        if isOnAir {
            let grow: CGFloat = pulse ? 1.12 + CGFloat(level) * 0.12 : 1.0
            Capsule().fill((fill ?? theme.palette.accent).opacity(0.3))
                .scaleEffect(grow)
                .opacity(pulse ? 0 : 0.9)
        }
    }

    @ViewBuilder
    private func pillGlyph(ink: Color) -> some View {
        switch state {
        case .arming: ProgressView().tint(ink)
        case .talking:
            Image(systemName: "waveform").symbolEffect(.variableColor.iterative, isActive: !theme.reduceMotion)
        case .listening:
            Image(systemName: "speaker.wave.2.fill").symbolEffect(.variableColor.iterative, isActive: !theme.reduceMotion)
        case .muted: Image(systemName: "speaker.slash.fill")
        case .unavailable: Image(systemName: "mic.slash.fill")
        case .idle: Image(systemName: SaryIcon.mic)
        }
    }

    private func pillRing(ink: Color) -> some View {
        var share: CGFloat = 0
        if case let .talking(s, remaining) = state { share = CGFloat(remaining) / CGFloat(max(1, s + remaining)) }
        return Circle()
            .trim(from: 0, to: share)
            .stroke(ink.opacity(0.9), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            .rotationEffect(.degrees(-90))
            .padding(2)
    }

    private func pillDisc(d: CGFloat, ink: Color, filled: Bool) -> some View {
        ZStack {
            Circle().fill(ink.opacity(filled ? 0.16 : 0.08))
            pillGlyph(ink: ink)
                .font(.system(size: d * 0.42, weight: .bold))
                .foregroundStyle(ink)
                .environment(\.layoutDirection, .leftToRight)
            if isTalking { pillRing(ink: ink) }
        }
        .frame(width: d, height: d)
    }

    @ViewBuilder
    private var discBody: some View {
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
            .accessibilityLabel(Text(a11yLabel))
            .accessibilityValue(Text(stateLabel))
            .accessibilityHint(Text(a11yHint))
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("outing-ptt")
            .accessibilityAction(named: Text(notesMode ? "ابدأ التسجيل" : "ابدأ التكلم")) { actions.pressBegan() }
            .accessibilityAction(named: Text(notesMode ? "أرسل الرسالة" : "أوقف التكلم")) { notesMode ? actions.pressBegan() : actions.pressEnded() }

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

    private var stateLabel: String { Self.label(for: state, notes: notesMode) }

    /// The button's words (UX ٢١: the label says what the button does). Unit-tested.
    /// · رسالة صوتية: «سجّل رسالة» → «يسجّل ٠:٠٥» → a friend's note: «رسالة من فلان».
    /// · بث مباشر: «اضغط وتكلم» → «على الهواء ٠:٠٥» → «فلان يتكلم».
    static func label(for state: PTTStateUI, notes: Bool) -> String {
        switch state {
        case .idle: return notes ? "سجّل رسالة" : "اضغط وتكلم"
        case .arming: return "نفتح التردد…"
        case let .talking(s, _): return notes ? "يسجّل \(SaryFormat.clock(seconds: s))" : "على الهواء \(SaryFormat.clock(seconds: s))"
        case let .listening(name, _): return notes ? "رسالة من \(name)" : "\(name) يتكلم"
        case .muted: return "اللاسلكي مكتوم"
        case .unavailable: return "اللاسلكي واقف · ما فيه شبكة"
        }
    }

    private var a11yLabel: String { notesMode ? "اللاسلكي، سجّل رسالة" : "اللاسلكي، اضغط وتكلم" }

    private var a11yHint: String {
        if state == .unavailable { return "اللاسلكي واقف لأن ما فيه شبكة. يرجع لحاله أول ما يرجع الاتصال" }
        if notesMode {
            if case .talking = state { return "اضغط مرة ثانية ترسل الرسالة لكل اللي على ترددك" }
            return "اضغط مرة وحدة تبدأ التسجيل، واضغط مرة ثانية أو «أرسل» ترسلها لكل اللي على ترددك"
        }
        return "امسك الزر وتكلم، يسمعك الربع مباشرة. ارفع إصبعك لتوقف"
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
