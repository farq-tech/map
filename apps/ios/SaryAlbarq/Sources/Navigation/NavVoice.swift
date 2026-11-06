import AVFoundation
import Foundation

/// Spoken guidance on the phone itself: «صوت سرى» (the owner's recorded clips,
/// `SaryVoice.swift`, the default) or «صوت الجهاز» (AVSpeechSynthesizer, ar-SA).
/// No voice API request either way: works offline and with the screen locked (the
/// `audio` background mode). Other audio is ducked while it speaks, then restored.
///
/// One line at a time, plus at most one waiting: a waiting line from an older route
/// (`routeRevision`) or past `expiresAt` is dropped, never said late.
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
        #if DEBUG
        NavLog.log("say%@: %@ [%@]", muted ? " (muted)" : "", t, line.clips.joined(separator: " "))
        #endif
        /* The same line twice within a few seconds (reroute, duplicate events): once. */
        let id = t + "|" + line.clips.joined(separator: "+")
        if id == lastText, Date().timeIntervalSince(lastAt) < 8 { return }
        lastText = id
        lastAt = Date()
        guard !muted, !isStale(line) else { return }
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
        next = (line, Date())
        guard pendingTimer == nil else { return }
        pendingTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pump() }
        }
    }

    private func pump() {
        guard let n = next else { return dropPending() }
        guard !muted, !isStale(n.line), Date().timeIntervalSince(n.at) < Self.pendingMaxS else { return dropPending() }
        guard !isSpeaking, canSpeak() else { return }
        dropPending()
        speak(n.line)
    }

    private func dropPending() {
        next = nil
        pendingTimer?.invalidate()
        pendingTimer = nil
    }

    private func speak(_ line: NavLine) {
        let c = choice()
        /* «صوت سرى» and nothing in his voice for this line: never the device voice in the middle. */
        if c == .sary, line.clips.isEmpty { return }
        /* Only while a line plays. «إذاعة الطلعة» playing: keep its `.playback` session and let it
         * duck itself; the walkie-talkie / a voice note owns `.playAndRecord`: play on it as is. */
        GroupAudioDuck.began(.nav)
        if !GroupAudioDuck.musicOwnsSession, !GroupAudioDuck.pttActive {
            let s = AVAudioSession.sharedInstance()
            try? s.setCategory(.playback, mode: .voicePrompt, options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
            try? s.setActive(true)
        }
        speaking = true
        lastPlayed = (c, line.clips, line.text)
        switch c {
        case .sary:
            clips.play(line.clips) { ok in
                #if DEBUG
                if !ok { NavLog.log("sary voice: could not play [%@]", line.clips.joined(separator: " ")) }
                #endif
            }
        case .device:
            if let f = speakDevice {
                f(line.text)
                DispatchQueue.main.async { [weak self] in self?.finished() }
            } else {
                let u = AVSpeechUtterance(string: line.text)
                u.voice = Self.voice
                u.rate = AVSpeechUtteranceDefaultSpeechRate * 1.02
                synth.speak(u)
            }
        }
    }

    private func interrupt() {
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
        if let n = next, !muted, !isStale(n.line), canSpeak() {
            dropPending()
            return speak(n.line)
        }
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
