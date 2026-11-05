import AVFoundation
import Foundation

/// Spoken guidance in Arabic on the phone itself (AVSpeechSynthesizer, ar-SA):
/// no voice API request, works offline and with the screen locked (the `audio`
/// background mode). Other audio is ducked while it speaks, then restored.
@MainActor
final class NavVoice: NSObject, AVSpeechSynthesizerDelegate {
    static let muteKey = "sary.nav.muted.v1"

    private let synth = AVSpeechSynthesizer()
    private var lastText = ""
    private var lastAt = Date.distantPast
    /// Not while «اضغط وتكلم» is recording (or a clip is playing): the app decides.
    var canSpeak: () -> Bool = { true }
    /// Every line said (or that would have been said while muted), for CarPlay / tests.
    var onSpoken: (String) -> Void = { _ in }

    var muted: Bool {
        didSet {
            UserDefaults.standard.set(muted, forKey: Self.muteKey)
            if muted { synth.stopSpeaking(at: .word) }
        }
    }

    override init() {
        muted = UserDefaults.standard.bool(forKey: Self.muteKey)
        super.init()
        synth.delegate = self
    }

    static var voice: AVSpeechSynthesisVoice? {
        AVSpeechSynthesisVoice(language: "ar-SA") ?? AVSpeechSynthesisVoice(language: "ar")
    }

    func say(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        onSpoken(t)
        #if DEBUG
        NavLog.log("say%@: %@", muted ? " (muted)" : "", t)
        #endif
        /* The same line twice within a few seconds (reroute, duplicate events): once. */
        if t == lastText, Date().timeIntervalSince(lastAt) < 8 { return }
        lastText = t
        lastAt = Date()
        guard !muted, canSpeak() else { return }
        /* «إذاعة الطلعة» playing: keep its `.playback` session (changing the category or
         * deactivating it would stop the music) and let it duck itself (GroupAudioDuck). */
        GroupAudioDuck.began(.nav)
        if !GroupAudioDuck.musicOwnsSession {
            let s = AVAudioSession.sharedInstance()
            try? s.setCategory(.playback, mode: .voicePrompt, options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
            try? s.setActive(true)
        }
        let u = AVSpeechUtterance(string: t)
        u.voice = Self.voice
        u.rate = AVSpeechUtteranceDefaultSpeechRate * 1.02
        if synth.isSpeaking { synth.stopSpeaking(at: .word) }
        synth.speak(u)
    }

    func stop() {
        synth.stopSpeaking(at: .immediate)
        GroupAudioDuck.ended(.nav)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard !self.synth.isSpeaking else { return }
            GroupAudioDuck.ended(.nav)
            guard !GroupAudioDuck.musicOwnsSession else { return }
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}
