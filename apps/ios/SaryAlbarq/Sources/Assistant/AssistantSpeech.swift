import AVFoundation
import Foundation
import Speech

/// The mic of «مساعد سرى»: Apple's Speech framework, on-device only (`requiresOnDeviceRecognition`),
/// Arabic (Saudi when the phone has it). No audio leaves the phone; without on-device Arabic the
/// mic says so and the text field stays (no server recognition, by design).
@MainActor
final class AssistantSpeech: ObservableObject {
    enum State: Equatable {
        case idle
        case listening(String)
        case unavailable(String)
    }

    @Published private(set) var state: State = .idle
    /// The final sentence (after the person stops talking or taps again).
    var onFinal: (String) -> Void = { _ in }
    /// The walkie-talkie or a voice note owns the mic now: the assistant waits its turn.
    var micBusy: () -> Bool = { false }

    private var recognizer: SFSpeechRecognizer?
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silenceTimer: Timer?
    private var latest = ""
    /// Silence after the last word that ends the question.
    static let endSilenceS: TimeInterval = 0.7
    static let maxListenS: TimeInterval = 12

    static let localeIDs = ["ar-SA", "ar-AE", "ar-KW", "ar-QA", "ar-BH", "ar-OM", "ar"]

    static func pickRecognizer() -> SFSpeechRecognizer? {
        let supported = SFSpeechRecognizer.supportedLocales().map(\.identifier)
        for id in localeIDs {
            let ok = supported.contains(id) || supported.contains(id.replacingOccurrences(of: "-", with: "_"))
            if ok, let r = SFSpeechRecognizer(locale: Locale(identifier: id)), r.supportsOnDeviceRecognition { return r }
        }
        return nil
    }

    var isListening: Bool { if case .listening = state { return true }; return false }

    func toggle() { isListening ? finish() : start() }

    func start() {
        guard !isListening else { return }
        if micBusy() { state = .unavailable("اللاسلكي شغّال، جرّب بعد ما يخلص."); return }
        SFSpeechRecognizer.requestAuthorization { auth in
            Task { @MainActor in
                guard auth == .authorized else {
                    self.state = .unavailable("اسمح بالتعرّف على الكلام من الإعدادات، أو اكتب سؤالك.")
                    return
                }
                AVAudioApplication.requestRecordPermission { ok in
                    Task { @MainActor in ok ? self.begin() : (self.state = .unavailable("اسمح للمايك من الإعدادات، أو اكتب سؤالك.")) }
                }
            }
        }
    }

    private func begin() {
        guard let r = recognizer ?? Self.pickRecognizer() else {
            state = .unavailable("التعرّف على الكلام العربي بدون إنترنت مو متاح على جوالك. اكتب سؤالك.")
            return
        }
        recognizer = r
        let s = AVAudioSession.sharedInstance()
        do {
            try s.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker, .allowBluetoothHFP])
            try s.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            state = .unavailable("ما قدرنا نفتح المايك الحين.")
            return
        }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.requiresOnDeviceRecognition = true
        req.shouldReportPartialResults = true
        req.taskHint = .search
        request = req
        latest = ""
        let input = engine.inputNode
        let fmt = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak req] buf, _ in req?.append(buf) }
        engine.prepare()
        do { try engine.start() } catch {
            state = .unavailable("ما قدرنا نفتح المايك الحين.")
            cleanup()
            return
        }
        state = .listening("")
        task = r.recognitionTask(with: req) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    self.latest = result.bestTranscription.formattedString
                    if self.isListening { self.state = .listening(self.latest) }
                    if result.isFinal { return self.deliver() }
                    self.armSilence(Self.endSilenceS)
                }
                if error != nil, self.isListening { self.deliver() }
            }
        }
        armSilence(Self.maxListenS)
    }

    private func armSilence(_ s: TimeInterval) {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: s, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish() }
        }
    }

    /// The person tapped the mic again, or went quiet.
    func finish() {
        guard isListening else { return }
        request?.endAudio()
        deliver()
    }

    func cancel() {
        latest = ""
        cleanup()
        state = .idle
    }

    private func deliver() {
        let text = latest.trimmingCharacters(in: .whitespacesAndNewlines)
        cleanup()
        state = .idle
        if !text.isEmpty { onFinal(text) }
    }

    private func cleanup() {
        silenceTimer?.invalidate()
        silenceTimer = nil
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        task?.cancel()
        task = nil
        request = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

/// Speaks the answer: his clips when they say the whole sentence, otherwise the phone's Arabic
/// voice for the whole sentence (never a mix inside one). Respects «صوت التوجيه» = صوت الجهاز.
@MainActor
final class AssistantVoice: NSObject {
    private let synth = AVSpeechSynthesizer()
    private let clips = SaryClipPlayer()
    /// Tests: what was handed to a voice.
    private(set) var last: AssistantSpoken?
    var choice: () -> NavVoiceChoice = { NavVoiceChoice.current() }

    func speak(_ s: AssistantSpoken) {
        stop()
        var s = s
        if case let .clips(keys, text) = s, choice() == .device || !SaryVoiceCatalog.has(keys) { s = .system(text) }
        last = s
        if GroupAudioDuck.pttActive { return }
        GroupAudioDuck.began(.nav)
        if !GroupAudioDuck.musicOwnsSession {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .voicePrompt, options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
            try? AVAudioSession.sharedInstance().setActive(true)
        }
        switch s {
        case let .clips(keys, _):
            clips.onFinish = { GroupAudioDuck.ended(.nav) }
            clips.play(keys)
        case let .system(text):
            let u = AVSpeechUtterance(string: text)
            u.voice = NavVoice.voice
            u.rate = AVSpeechUtteranceDefaultSpeechRate * 1.02
            synth.speak(u)
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { GroupAudioDuck.ended(.nav) }
        }
    }

    func stop() {
        synth.stopSpeaking(at: .immediate)
        clips.stop()
    }
}
