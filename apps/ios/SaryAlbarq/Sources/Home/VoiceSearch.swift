import AVFoundation
import Foundation
import Speech

/// The mic in «وين رايحين؟»: say the place, it is typed into the search. Arabic (Saudi),
/// on-device when the phone can; stops on its own after a short silence or 8 s.
@MainActor
final class VoiceSearch: ObservableObject {
    enum State: Equatable { case idle, listening, denied, unavailable }

    @Published private(set) var state: State = .idle
    @Published private(set) var text = ""

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ar-SA"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var stopper: Task<Void, Never>?

    var isListening: Bool { state == .listening }

    func toggle() { isListening ? stop() : start() }

    func start() {
        guard state != .listening else { return }
        guard let recognizer, recognizer.isAvailable else { state = .unavailable; return }
        SFSpeechRecognizer.requestAuthorization { [weak self] auth in
            Task { @MainActor in
                guard let self else { return }
                guard auth == .authorized else { self.state = .denied; return }
                AVAudioApplication.requestRecordPermission { ok in
                    Task { @MainActor in ok ? self.begin(recognizer) : (self.state = .denied) }
                }
            }
        }
    }

    private func begin(_ recognizer: SFSpeechRecognizer) {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            state = .unavailable
            return
        }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        request = req
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { state = .unavailable; return }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak req] buf, _ in req?.append(buf) }
        engine.prepare()
        do { try engine.start() } catch { state = .unavailable; cleanUp(); return }
        text = ""
        state = .listening
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let r = result {
                    self.text = r.bestTranscription.formattedString
                    self.armSilence()
                    if r.isFinal { self.stop() }
                }
                if error != nil { self.stop() }
            }
        }
        stopper = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            self?.stop()
        }
    }

    /// 1.4 s without a new word ends the listening.
    private func armSilence() {
        stopper?.cancel()
        stopper = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }

    func stop() {
        guard state == .listening else { return }
        state = .idle
        cleanUp()
    }

    private func cleanUp() {
        stopper?.cancel()
        stopper = nil
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
