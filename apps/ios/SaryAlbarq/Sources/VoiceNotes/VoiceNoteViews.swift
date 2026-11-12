import SwiftUI

/// Bars, 0…1 each, centred vertically. Left to right always (it is time, not text).
struct VoiceNoteWaveform: View {
    var levels: [Float]
    var progress: Double? = nil
    var color: Color
    var dim: Color
    var bars = 36

    var body: some View {
        GeometryReader { g in
            let n = max(1, bars)
            let w = g.size.width / CGFloat(n)
            let vals = Self.resample(levels, to: n)
            HStack(alignment: .center, spacing: 0) {
                ForEach(0..<n, id: \.self) { i in
                    let on = progress.map { Double(i) / Double(n) <= $0 } ?? true
                    Capsule()
                        .fill(on ? color : dim)
                        .frame(width: max(1.5, w * 0.55), height: max(3, g.size.height * CGFloat(0.12 + 0.88 * vals[i])))
                        .frame(width: w)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityHidden(true)
    }

    static func resample(_ l: [Float], to n: Int) -> [Float] {
        guard !l.isEmpty else { return Array(repeating: 0.05, count: n) }
        if l.count == n { return l }
        return (0..<n).map { i in
            let a = Int(Double(i) / Double(n) * Double(l.count))
            let z = max(a + 1, Int(Double(i + 1) / Double(n) * Double(l.count)))
            let s = l[min(a, l.count - 1)..<min(z, l.count)]
            return s.max() ?? 0
        }
    }
}

/// Over the talk button: the recording bar («أرسل» / «احذف», timer, waveform), the
/// «فهد يتكلم…» card while a note plays, and «الرسائل الصوتية» when some wait unheard.
struct VoiceNoteDock: View {
    @ObservedObject var center: VoiceNoteCenter
    /// «الرسائل الصوتية» (the «الترددات» sheet).
    var openList: () -> Void = {}

    var body: some View {
        VStack(spacing: 8) {
            if center.isRecording {
                VoiceNoteRecordBar(center: center, meter: center.meter)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if let p = center.playing {
                VoiceNotePlayingCard(playing: p, stop: center.stopPlaying)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if let o = center.offer {
                VoiceNoteOfferCard(offer: o, play: center.playOffer, dismiss: center.dismissOffer)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if center.unheard > 0 || center.sending > 0 {
                VoiceNoteStatusPill(unheard: center.unheard, sending: center.sending, open: openList)
                    .transition(.opacity)
            }
        }
        .animation(.snappy(duration: 0.25), value: center.isRecording)
        .animation(.snappy(duration: 0.25), value: center.playing?.id)
        .animation(.snappy(duration: 0.25), value: center.offer?.id)
    }
}

struct VoiceNoteRecordBar: View {
    @ObservedObject var center: VoiceNoteCenter
    @ObservedObject var meter: VoiceNoteMeter
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        let secs = Int(meter.elapsed)
        HStack(spacing: theme.space(.s)) {
            Button(action: center.cancel) {
                Image(systemName: "trash.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(p.emergencyText)
                    .frame(width: 52, height: 52)
                    .background(Circle().fill(p.sunken))
            }
            .buttonStyle(SaryPressStyle())
            .accessibilityLabel(Text("احذف"))
            .accessibilityHint(Text("يحذف التسجيل وما يرسله"))
            .accessibilityIdentifier("voice-note-cancel")

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Circle().fill(p.emergency).frame(width: 8, height: 8)
                    Text("يسجّل")
                        .font(.sary(13, .medium))
                        .foregroundStyle(p.textSecondary)
                    Text("\(SaryFormat.clock(seconds: secs)) / \(SaryFormat.clock(seconds: Int(VoiceNotePolicy.maxRecordMs / 1000)))")
                        .font(.sary(13, .bold)).monospacedDigit()
                        .foregroundStyle(p.textPrimary)
                        .contentTransition(.numericText())
                        .accessibilityIdentifier("voice-note-timer")
                }
                VoiceNoteWaveform(levels: meter.levels, color: p.accentText, dim: p.textTertiary.opacity(0.4))
                    .frame(height: 26)
            }
            .frame(maxWidth: .infinity)

            Button(action: center.send) {
                HStack(spacing: 6) {
                    Image(systemName: "paperplane.fill")
                    Text("أرسل").font(.sary(17, .bold))
                }
                .foregroundStyle(p.onAccent)
                .padding(.horizontal, 22)
                .frame(height: 56)
                .background(Capsule().fill(p.accent))
            }
            .buttonStyle(SaryPressStyle())
            .accessibilityIdentifier("voice-note-send")
            .accessibilityHint(Text("يرسل الرسالة لكل اللي على نفس التردد"))
        }
        .padding(.horizontal, theme.space(.s))
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(p.chromeOpaque.opacity(0.88)))
        .saryGlass(RoundedRectangle(cornerRadius: 28, style: .continuous), role: .chrome)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("voice-note-recording")
    }
}

struct VoiceNotePlayingCard: View {
    var playing: VoiceNoteCenter.Playing
    var stop: () -> Void
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        let car = Color(rgb: playing.color)
        HStack(spacing: theme.space(.s)) {
            ZStack {
                Circle().fill(car)
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(SaryCarColors.ink(on: playing.color))
                    .symbolEffect(.variableColor.iterative, isActive: !playing.loading && !theme.reduceMotion)
                    .environment(\.layoutDirection, .leftToRight)
            }
            .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text("رسالة من \(playing.name)")
                    .font(.sary(16, .bold))
                    .foregroundStyle(p.textPrimary)
                    .lineLimit(1)
                    .accessibilityIdentifier("voice-note-speaker")
                if playing.loading {
                    ProgressView().tint(p.accent).frame(height: 22)
                } else {
                    VoiceNoteWaveform(levels: playing.waveform, progress: playing.progress, color: car, dim: p.textTertiary.opacity(0.4))
                        .frame(height: 22)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(SaryFormat.clock(seconds: playing.seconds))
                .font(.sary(13, .medium)).monospacedDigit()
                .foregroundStyle(p.textSecondary)
            Button(action: stop) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(p.textPrimary)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(p.sunken))
            }
            .buttonStyle(SaryPressStyle())
            .accessibilityLabel(Text("أوقف"))
            .accessibilityIdentifier("voice-note-stop")
        }
        .padding(.horizontal, theme.space(.s))
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(p.chromeOpaque.opacity(0.88)))
        .saryGlass(RoundedRectangle(cornerRadius: 28, style: .continuous), role: .chrome)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("voice-note-playing")
    }
}

/// «تشغيل تلقائي» off: «فهد أرسل رسالة صوتية» with ▶︎ (and ✕).
struct VoiceNoteOfferCard: View {
    var offer: VoiceNoteCenter.Playing
    var play: () -> Void
    var dismiss: () -> Void
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        HStack(spacing: theme.space(.s)) {
            Button(action: play) {
                Image(systemName: "play.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(SaryCarColors.ink(on: offer.color))
                    .frame(width: 52, height: 52)
                    .background(Circle().fill(Color(rgb: offer.color)))
            }
            .buttonStyle(SaryPressStyle())
            .accessibilityLabel(Text("شغّل رسالة \(offer.name)"))
            .accessibilityIdentifier("voice-note-offer-play")
            VStack(alignment: .leading, spacing: 2) {
                Text("\(offer.name) أرسل رسالة صوتية").font(.sary(16, .bold)).foregroundStyle(p.textPrimary).lineLimit(1)
                Text(SaryFormat.clock(seconds: offer.seconds)).font(.sary(13, .medium)).monospacedDigit().foregroundStyle(p.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            SaryIconButton(systemImage: SaryIcon.close, label: "لاحقًا", id: "voice-note-offer-dismiss", visual: 44, action: dismiss)
        }
        .padding(.horizontal, theme.space(.s))
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(p.chromeOpaque.opacity(0.88)))
        .saryGlass(RoundedRectangle(cornerRadius: 28, style: .continuous), role: .chrome)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("voice-note-offer")
    }
}

struct VoiceNoteStatusPill: View {
    var unheard: Int
    var sending: Int
    var open: () -> Void
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        Button(action: open) {
            HStack(spacing: 6) {
                Image(systemName: sending > 0 ? "arrow.up.circle" : "waveform")
                    .environment(\.layoutDirection, .leftToRight)
                Text(label).font(.sary(13, .medium))
            }
            .foregroundStyle(p.textPrimary)
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(Capsule().fill(p.chromeOpaque.opacity(0.88)))
            .saryGlass(Capsule(), role: .chrome)
            /* The pill stays 34 tall; the touch area is 44. */
            .contentShape(Capsule().inset(by: -5))
        }
        .accessibilityIdentifier("voice-note-pill")
    }

    private var label: String {
        if sending > 0 { return sending == 1 ? "رسالة تنتظر الإرسال" : "\(SaryFormat.number(sending)) رسائل تنتظر الإرسال" }
        return unheard == 1 ? "رسالة صوتية ما سمعتها" : "\(SaryFormat.number(unheard)) رسائل صوتية ما سمعتها"
    }
}

/// «الرسائل الصوتية» of the current channel (24 h), with a play button each — a section of
/// the «الترددات» sheet (`PTTChannelSheet`), so it opens from the channel chip or the dock's pill.
struct VoiceNoteSection: View {
    @ObservedObject var center: VoiceNoteCenter
    @Environment(\.sary) private var theme

    var body: some View {
        Section {
            if center.list.isEmpty {
                SaryInlineState(systemImage: "waveform", text: "ما فيه رسائل صوتية على هالتردد للحين. اضغط «اضغط وتكلم» وسجّل أول رسالة.")
                    .accessibilityIdentifier("voice-notes-empty")
            } else {
                ForEach(center.list.prefix(20)) { n in row(n) }
            }
        } header: {
            Text("الرسائل الصوتية")
        } footer: {
            Text("آخر ٢٤ ساعة على هذا التردد. الرسالة تشتغل لحالها إذا وصلت خلال دقيقتين، والأقدم تلقاها هنا.")
        }
        .task { await center.sync() }
    }

    private func row(_ n: VoiceNote) -> some View {
        let p = theme.palette
        let mine = n.user_id == center.me
        let name = mine ? "أنت" : (center.nameOf(n.user_id) ?? "عضو")
        let isPlaying = center.playing?.id == n.id
        return HStack(spacing: theme.space(.s)) {
            Button { center.play(n.id) } label: {
                Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(SaryCarColors.ink(on: center.colorOf(n.user_id)))
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Color(rgb: center.colorOf(n.user_id))))
                    .frame(width: theme.minTarget, height: theme.minTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(isPlaying ? "أوقف رسالة \(name)" : "شغّل رسالة \(name)"))
            .accessibilityIdentifier("voice-note-play")
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.sary(15, .bold)).foregroundStyle(p.textPrimary).lineLimit(1).minimumScaleFactor(0.85)
                Text("\(SaryFormat.clock(seconds: n.seconds)) · \(Self.when(n.recorded_at))")
                    .font(.sary(12, .regular)).monospacedDigit().foregroundStyle(p.textSecondary)
            }
            Spacer()
            if !mine, !center.isHeard(n.id) {
                Circle().fill(p.accent).frame(width: 8, height: 8).accessibilityLabel(Text("ما سمعتها"))
            }
        }
        .accessibilityIdentifier("voice-note-row")
    }

    static func when(_ iso: String) -> String {
        guard let d = ISODate.parse(iso) else { return "" }
        /* The app's one «قبل ٤ د» (was a local copy that said «الحين» where everything else says «الآن»). */
        return SaryFormat.elapsed(since: d, now: Date())
    }
}
