import AVFoundation
import Foundation

/// The microphone permission for «قناة الطلعة». (The «اضغط وتكلم» clip recorder
/// is gone: new builds talk live through `OutingWalkieTalkie`; the server still
/// takes clips from older builds, and `VoicePlayer` below still plays them.)
enum MicPermission {
    static var granted: Bool {
        AVAudioApplication.shared.recordPermission == .granted
    }

    /// Asks the first time. False when refused (or iOS never answers within 5 s).
    @MainActor
    static func request() async -> Bool {
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { finish(granted) }
        }
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
