import AVFoundation

/// Plays the intro's score (`Resources/Intro/intro-score.m4a`, synthesised by
/// `scripts/make-intro-score.py`, original music).
///
/// `.ambient`: obeys the silent switch, mixes with whatever the person is listening to,
/// and never interrupts a call or «قناة الطلعة». The session is only touched when no one
/// else has configured it yet (default `.soloAmbient`) — a PushToTalk / navigation voice
/// session that is already set up is left exactly as it is, and then the intro stays quiet.
@MainActor
final class IntroAudio {
    private var player: AVAudioPlayer?
    private var touchedSession = false

    nonisolated static var url: URL? { Bundle.main.url(forResource: "intro-score", withExtension: "m4a") }

    func play() {
        let s = AVAudioSession.sharedInstance()
        /* Someone else's audio is set up (or a call is live): stay silent rather than reconfigure it. */
        guard s.category == .soloAmbient || s.category == .ambient else { return }
        guard let url = Self.url, let p = try? AVAudioPlayer(contentsOf: url) else { return }
        do {
            try s.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
            try s.setActive(true)
            touchedSession = true
        } catch { return }
        p.volume = 0.8
        p.prepareToPlay()
        p.play()
        player = p
    }

    /// Fades the music out (skip / end of the intro) and lets the session go.
    func fadeOut(_ seconds: TimeInterval = 0.6) {
        guard let p = player else { return }
        p.setVolume(0, fadeDuration: seconds)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds + 0.05) { [weak self] in self?.stop() }
    }

    func stop() {
        player?.stop()
        player = nil
        guard touchedSession else { return }
        touchedSession = false
        let s = AVAudioSession.sharedInstance()
        /* Only release our own `.ambient` activation; anything that took the session since keeps it. */
        if s.category == .ambient { try? s.setActive(false, options: .notifyOthersOnDeactivation) }
    }
}
