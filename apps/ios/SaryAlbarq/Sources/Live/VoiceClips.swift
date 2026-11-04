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

    /// Asks for the microphone the first time. False when refused (or iOS never answers).
    func requestPermission() async -> Bool {
        await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            var done = false
            let finish: (Bool) -> Void = { ok in
                DispatchQueue.main.async {
                    guard !done else { return }
                    done = true
                    c.resume(returning: ok)
                }
            }
            AVAudioApplication.requestRecordPermission { finish($0) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { finish(self.hasPermission) }
        }
    }

    var hasPermission: Bool {
        AVAudioApplication.shared.recordPermission == .granted || AVAudioSession.sharedInstance().recordPermission == .granted
    }

    private let queue = DispatchQueue(label: "sa.sary.ptt")
    /// A previous start never came back (seen on the simulator's audio input): do not queue more.
    private var stuck = false

    /// Starts recording off the main thread. False if the microphone does not
    /// start within 2.5 s, so a wedged audio input can never freeze the map.
    func start() async -> Bool {
        guard !stuck else { return false }
        stuck = true
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("ptt-\(UUID().uuidString).m4a")
        let r: AVAudioRecorder? = await withCheckedContinuation { (c: CheckedContinuation<AVAudioRecorder?, Never>) in
            let once = Once()
            queue.async {
                let s = AVAudioSession.sharedInstance()
                var rec: AVAudioRecorder?
                if (try? s.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker])) != nil, (try? s.setActive(true)) != nil {
                    let settings: [String: Any] = [
                        AVFormatIDKey: kAudioFormatMPEG4AAC,
                        AVSampleRateKey: 22_050,
                        AVNumberOfChannelsKey: 1,
                        AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
                    ]
                    if let r = try? AVAudioRecorder(url: u, settings: settings), r.record(forDuration: Self.maxSeconds) { rec = r }
                }
                DispatchQueue.main.async {
                    if !once.fire({ c.resume(returning: rec) }) {
                        /* Too late: the press already failed. Throw this one away. */
                        rec?.stop()
                        rec?.deleteRecording()
                    }
                    self.stuck = false
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { _ = once.fire { c.resume(returning: nil) } }
        }
        guard let r else { return false }
        r.delegate = self
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

/// Runs exactly one of two racing completions (on the main thread).
private final class Once {
    private var done = false
    func fire(_ f: () -> Void) -> Bool {
        guard !done else { return false }
        done = true
        f()
        return true
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
