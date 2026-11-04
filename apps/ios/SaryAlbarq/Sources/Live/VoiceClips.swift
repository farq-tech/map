import AVFoundation
import Foundation

/// «اضغط وتكلم»: records AAC in an .m4a (what the server sniffs as audio/mp4),
/// at most 15 s, only while the finger is down. Nothing is kept on the phone
/// after the upload.
@MainActor
final class VoiceRecorder: NSObject, AVAudioRecorderDelegate {
    static let maxSeconds: TimeInterval = 15
    static let minMs = 400

    private var recorder: AVAudioRecorder?
    private var startedAt: Date?
    private var url: URL?

    /// Asks for the microphone the first time. False when refused.
    func requestPermission() async -> Bool {
        await withCheckedContinuation { c in
            AVAudioApplication.requestRecordPermission { ok in c.resume(returning: ok) }
        }
    }

    var hasPermission: Bool { AVAudioApplication.shared.recordPermission == .granted }

    func start() -> Bool {
        let s = AVAudioSession.sharedInstance()
        do {
            try s.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker])
            try s.setActive(true)
        } catch { return false }
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("ptt-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 22_050,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]
        guard let r = try? AVAudioRecorder(url: u, settings: settings) else { return false }
        r.delegate = self
        guard r.record(forDuration: Self.maxSeconds) else { return false }
        recorder = r
        url = u
        startedAt = Date()
        return true
    }

    var elapsed: Int { startedAt.map { Int(Date().timeIntervalSince($0)) } ?? 0 }
    var isRecording: Bool { recorder?.isRecording == true }

    /// Stops and returns the clip (nil when too short or nothing recorded).
    func stop() -> (data: Data, durationMs: Int)? {
        guard let r = recorder, let u = url, let t0 = startedAt else { return nil }
        let ms = Int(min(Date().timeIntervalSince(t0), Self.maxSeconds) * 1000)
        r.stop()
        recorder = nil
        startedAt = nil
        defer { try? FileManager.default.removeItem(at: u) }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        guard ms >= Self.minMs, let d = try? Data(contentsOf: u), d.count >= 256 else { return nil }
        return (d, ms)
    }

    func cancel() {
        recorder?.stop()
        recorder?.deleteRecording()
        recorder = nil
        startedAt = nil
        if let u = url { try? FileManager.default.removeItem(at: u) }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

/// Plays one clip at a time and reports progress 0...1.
@MainActor
final class VoicePlayer: NSObject, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    private var timer: Timer?
    private(set) var playingId: String?
    var onProgress: (String, Double) -> Void = { _, _ in }
    var onFinish: (String) -> Void = { _ in }

    func play(_ data: Data, id: String) -> Bool {
        stop()
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        guard let p = try? AVAudioPlayer(data: data) else { return false }
        p.delegate = self
        guard p.play() else { return false }
        player = p
        playingId = id
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let p = self.player, let id = self.playingId, p.duration > 0 else { return }
                self.onProgress(id, min(1, p.currentTime / p.duration))
            }
        }
        return true
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        player?.stop()
        player = nil
        if let id = playingId {
            playingId = nil
            onFinish(id)
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.stop() }
    }
}
