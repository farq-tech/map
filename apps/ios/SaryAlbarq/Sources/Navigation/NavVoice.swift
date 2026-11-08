import AVFoundation
import Foundation

/// Spoken guidance on the phone itself: «صوت سرى» (the owner's recorded clips,
/// `SaryVoice.swift`, the default) or «صوت الجهاز» (AVSpeechSynthesizer, ar-SA).
/// No voice API request either way: works offline and with the screen locked (the
/// `audio` background mode). Other audio is ducked while it speaks, then restored.
///
/// One line at a time, plus at most one waiting: a waiting line from an older route
/// (`routeRevision`) or past `expiresAt` is dropped, never said late.
/// What happened to the guidance lines asked for (diagnostics: «جودة GPS / تشخيص»).
struct NavVoiceStats: Equatable {
    enum Drop: String, CaseIterable { case missing, stale, dedupe, session, interrupted }
    var requested = 0
    var spoken = 0
    var drops: [Drop: Int] = [:]
    /// Lines said with the device voice because «صوت سرى» had no clip for them (never silence).
    var deviceFallback = 0

    mutating func dropped(_ d: Drop) { drops[d, default: 0] += 1 }

    var line: String {
        "صوت: طُلب \(requested) · قيل \(spoken) · بديل \(deviceFallback) · " + Drop.allCases.map { "\($0.rawValue) \(drops[$0] ?? 0)" }.joined(separator: " · ")
    }

    /// The running navigation's counters, for the diagnostics row.
    @MainActor static var current = NavVoiceStats()
}

@MainActor
final class NavVoice: NSObject, AVSpeechSynthesizerDelegate {
    static let muteKey = "sary.nav.muted.v1"

    private let synth = AVSpeechSynthesizer()
    private let clips = SaryClipPlayer()
    private var lastText = ""
    private var lastAt = Date.distantPast
    /// The next line (only one): said when the current one ends or the speaker is free.
    private var next: (line: NavLine, at: Date)?
    private var pendingTimer: Timer?
    private var speaking = false
    var stats = NavVoiceStats() { didSet { NavVoiceStats.current = stats } }
    /// A waiting line older than this is stale guidance: dropped.
    static let pendingMaxS: TimeInterval = 12
    /// The route lines are for now (`NavSession` bumps it on every new route).
    var routeRevision = 0 {
        didSet { if let n = next, isStale(n.line) { self.next = nil } }
    }
    /// The speaker is free: no walkie-talkie voice, no voice note playing or being recorded.
    var canSpeak: () -> Bool = { true }
    /// I am the one talking (walkie-talkie or recording a voice note): guidance waits, and a
    /// safety line becomes `onSafetyWhileTalking` (vibration + text) instead of sound.
    var isSending: () -> Bool = { false }
    var onSafetyWhileTalking: (String) -> Void = { _ in }
    /// Every line said (or that would have been said while muted), for CarPlay / tests.
    var onSpoken: (String) -> Void = { _ in }
    /// Which voice; read on every line so the setting applies at once.
    var choice: () -> NavVoiceChoice = { NavVoiceChoice.current() }
    /// Replaces the synthesizer for «صوت الجهاز» (tests: the simulator's voice is slow to load).
    var speakDevice: ((String) -> Void)?
    /// What was last handed to a voice (tests): the clips, or the text for the device voice.
    private(set) var lastPlayed: (choice: NavVoiceChoice, clips: [String], text: String)?
    private var observers: [NSObjectProtocol] = []
    /// A line was cut by a call / Siri: when it ends, `onReevaluate` builds a fresh one.
    private var cutOff = false
    /// After an interruption: say the current instruction again, rebuilt for where I am now.
    var onReevaluate: () -> Void = {}

    /// What to do with a line at the moment it would start playing (build 22): the guidance
    /// rebuilds it for where I am NOW (`NavPromptTiming`), holds it a moment so it ends at a
    /// recorded distance, or drops it (the maneuver is behind me). Default: play as is.
    enum Playback: Equatable { case play(NavLine), hold(NavLine, TimeInterval), drop }
    var atPlayback: (NavLine, NavVoiceChoice) -> Playback = { l, _ in .play(l) }

    var muted: Bool {
        didSet {
            UserDefaults.standard.set(muted, forKey: Self.muteKey)
            if muted { stop() }
        }
    }

    override init() {
        muted = UserDefaults.standard.bool(forKey: Self.muteKey)
        super.init()
        synth.delegate = self
        clips.onFinish = { [weak self] in self?.finished() }
        let nc = NotificationCenter.default
        /* A call or Siri: the line stops and is not resumed (the next cue says what is current). */
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
            let type = (n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            MainActor.assumeIsolated {
                guard let self else { return }
                if type == .began {
                    self.cutOff = self.isSpeaking || self.next != nil
                    self.interrupt()
                } else if type == .ended, self.cutOff {
                    /* Never the old clip again: the session says what is true now. */
                    self.cutOff = false
                    self.onReevaluate()
                }
            }
        })
        /* Headphones out / CarPlay gone: what was playing is cut, not continued on the speaker. */
        observers.append(nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] n in
            let why = (n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init)
            MainActor.assumeIsolated { if why == .oldDeviceUnavailable { self?.interrupt() } }
        })
    }

    static var voice: AVSpeechSynthesisVoice? {
        AVSpeechSynthesisVoice(language: "ar-SA") ?? AVSpeechSynthesisVoice(language: "ar")
    }

    var isSpeaking: Bool { speaking || synth.isSpeaking || clips.isPlaying }

    func say(_ text: String, clips keys: [String], safety: Bool = false) { say(NavLine(text, clips: keys, safety: safety)) }

    func say(_ line: NavLine) {
        let t = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty || !line.clips.isEmpty else { return }
        onSpoken(t)
        if !muted { stats.requested += 1 }
        #if DEBUG
        NavLog.log("say%@: %@ [%@]", muted ? " (muted)" : "", t, line.clips.joined(separator: " "))
        #endif
        /* The same line twice within a few seconds (reroute, duplicate events): once. */
        let id = t + "|" + line.clips.joined(separator: "+")
        if id == lastText, Date().timeIntervalSince(lastAt) < 8 {
            if !muted { stats.dropped(.dedupe) }
            return
        }
        lastText = id
        lastAt = Date()
        guard !muted else { return }
        guard !isStale(line) else { return stats.dropped(.stale) }
        if !canSpeak(), isSending(), line.safety {
            /* I am talking: never over my own voice, but safety is never skipped. */
            return onSafetyWhileTalking(t)
        }
        if isSpeaking || !canSpeak() { return enqueue(line) }
        speak(line)
    }

    private func isStale(_ l: NavLine) -> Bool {
        if let r = l.routeRevision, r < routeRevision { return true }
        if let e = l.expiresAt, e < Date() { return true }
        return false
    }

    /// The one waiting line (a newer one replaces it).
    private func enqueue(_ line: NavLine) {
        if next != nil { stats.dropped(.stale) }
        next = (line, Date())
        guard pendingTimer == nil else { return }
        pendingTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pump() }
        }
    }

    private func pump() {
        guard let n = next else { return dropPending() }
        guard !muted, !isStale(n.line), Date().timeIntervalSince(n.at) < Self.pendingMaxS else {
            if !muted { stats.dropped(.stale) }
            return dropPending()
        }
        guard !isSpeaking, canSpeak(), !n.line.isHeld() else { return }
        dropPending()
        speak(n.line)
    }

    private func dropPending() {
        next = nil
        pendingTimer?.invalidate()
        pendingTimer = nil
    }

    private func speak(_ queued: NavLine) {
        var c = choice()
        /* The distance is the one when the line ENDS, from where I am now — not when it was asked for. */
        let line: NavLine
        switch atPlayback(queued, c) {
        case let .play(l): line = l
        case let .hold(l, s):
            var h = l
            h.notBefore = Date().addingTimeInterval(s)
            h.heldS += s
            enqueue(h)
            /* On time, not at the next 0.4 s tick (0.4 s is 6 m at 50 km/h). */
            DispatchQueue.main.asyncAfter(deadline: .now() + s + 0.01) { [weak self] in self?.pump() }
            return
        case .drop:
            stats.dropped(.stale)
            if next == nil, !isSpeaking { releaseAudio() }
            return
        }
        /* A held line for the same maneuver is superseded by this one. */
        if let n = next, let id = line.maneuverID, n.line.maneuverID == id { dropPending() }
        /* «صوت سرى» with no clip for this line: the device voice says it — a guidance line is never silent. */
        if c == .sary, line.clips.isEmpty {
            /* Arabic only: router narration in another language is never read out. */
            guard NavText.isArabic(line.text) else { return stats.dropped(.missing) }
            c = .device
            stats.deviceFallback += 1
        }
        /* Only while a line plays. «إذاعة الطلعة» playing: keep its `.playback` session and let it
         * duck itself; the walkie-talkie / a voice note owns `.playAndRecord`: play on it as is. */
        GroupAudioDuck.began(.nav)
        if !GroupAudioDuck.musicOwnsSession, !GroupAudioDuck.pttActive {
            activateSession()
        }
        speaking = true
        lastPlayed = (c, line.clips, line.text)
        switch c {
        case .sary:
            clips.play(line.clips) { [weak self] ok in
                guard let self else { return }
                if ok { self.stats.spoken += 1; return }
                NSLog("[NAV] sary voice: could not play [%@] → device voice", line.clips.joined(separator: " "))
                /* A clip missing or broken: the device voice says the line rather than nothing. */
                self.stats.dropped(.missing)
                guard NavText.isArabic(line.text) else { return }
                self.stats.deviceFallback += 1
                self.speaking = true
                self.speakWithDevice(line.text)
            }
        case .device:
            speakWithDevice(line.text)
        }
    }

    private func speakWithDevice(_ text: String) {
        stats.spoken += 1
        if let f = speakDevice {
            f(text)
            DispatchQueue.main.async { [weak self] in self?.finished() }
        } else {
            let u = AVSpeechUtterance(string: text)
            u.voice = Self.voice
            u.rate = AVSpeechUtteranceDefaultSpeechRate * 1.02
            synth.speak(u)
        }
    }

    /// The playback session for a line. Another app or a call may still hold it: logged, tried
    /// once more 300 ms later; the line is played either way (ducking may just not apply).
    private func activateSession() {
        let s = AVAudioSession.sharedInstance()
        do {
            try s.setCategory(.playback, mode: .voicePrompt, options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
            try s.setActive(true)
        } catch {
            NSLog("[NAV] audio session: %@ — retrying in 300 ms", String(describing: error))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                do { try s.setActive(true) } catch {
                    NSLog("[NAV] audio session failed again: %@", String(describing: error))
                    self?.stats.dropped(.session)
                }
            }
        }
    }

    private func interrupt() {
        if speaking || next != nil { stats.dropped(.interrupted) }
        dropPending()
        synth.stopSpeaking(at: .immediate)
        clips.interrupted()
        if speaking { finished() }
    }

    func stop() {
        dropPending()
        synth.stopSpeaking(at: .immediate)
        clips.stop()
        speaking = false
        GroupAudioDuck.ended(.nav)
    }

    private func finished() {
        speaking = false
        guard !synth.isSpeaking, !clips.isPlaying else { return }
        if let n = next, !muted, !isStale(n.line), canSpeak(), !n.line.isHeld() {
            dropPending()
            return speak(n.line)
        }
        releaseAudio()
    }

    private func releaseAudio() {
        GroupAudioDuck.ended(.nav)
        guard !GroupAudioDuck.musicOwnsSession, !GroupAudioDuck.pttActive else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finished() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in if !self.synth.isSpeaking, !self.clips.isPlaying { self.speaking = false } }
    }
}
