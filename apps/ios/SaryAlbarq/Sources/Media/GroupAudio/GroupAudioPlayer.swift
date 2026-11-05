import AVFoundation
import Foundation
import MediaPlayer
import UIKit

// MARK: - Who else wants the speaker (navigation voice, push-to-talk)

/// One line in `NavVoice` / `PTTRoute` each: «I am speaking» / «done». The music
/// ducks or pauses (GroupAudioDucking) and comes back after.
@MainActor
enum GroupAudioDuck {
    enum Kind { case nav, ptt }
    static let name = Notification.Name("sary.groupAudio.duck")

    /// «إذاعة الطلعة» is playing and owns the `.playback` session: others must not
    /// change the category to theirs nor deactivate the session (that stops the music).
    static var musicOwnsSession = false

    /// The walkie-talkie holds the `.playAndRecord` session: the nav voice must not switch it
    /// to `.playback` (that cut the mic and sent the friend's voice to a ducked/other route) nor
    /// deactivate it under the friend's voice.
    private(set) static var pttActive = false

    static func began(_ k: Kind) { if k == .ptt { pttActive = true }; post(k, true) }
    static func ended(_ k: Kind) { if k == .ptt { pttActive = false }; post(k, false) }

    private static func post(_ k: Kind, _ on: Bool) {
        NotificationCenter.default.post(name: name, object: nil, userInfo: ["kind": k == .nav ? "nav" : "ptt", "on": on])
    }
}

// MARK: - The audio session

@MainActor
enum GroupAudioSession {
    /// `.playback` without mixing: owns the lock screen / CarPlay now-playing and the
    /// steering-wheel buttons. From the background iOS may refuse a non-mixable start
    /// (`cannotStartPlaying`): then mix with others rather than stay silent.
    @discardableResult
    static func activate() -> Bool {
        let s = AVAudioSession.sharedInstance()
        do {
            try s.setCategory(.playback, mode: .default, policy: .longFormAudio, options: [])
            try s.setActive(true)
            return true
        } catch {
            try? s.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            return (try? s.setActive(true)) != nil
        }
    }

    static func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

// MARK: - The player

enum GroupAudioPlayerEvent: Equatable {
    case playing
    case paused
    case buffering
    case ended
    case failed(String)
}

/// What plays the stream. `AVGroupAudioEngine` in the app; `StubGroupAudioEngine` with
/// `-SaryStubAudio` (UI tests never touch the network).
@MainActor
protocol GroupAudioEngine: AnyObject {
    var onEvent: (GroupAudioPlayerEvent) -> Void { get set }
    var loadedURL: URL? { get }
    /// Seconds into a file (nil: nothing loaded / live).
    var position: Double? { get }
    var duration: Double? { get }
    var isPlaying: Bool { get }
    var rate: Float { get }
    func load(_ url: URL, live: Bool, start: Double, play: Bool)
    func play()
    func pause()
    func seek(to s: Double)
    func setRate(_ r: Float)
    func setVolume(_ v: Float)
    func unload()
}

@MainActor
final class AVGroupAudioEngine: NSObject, GroupAudioEngine {
    var onEvent: (GroupAudioPlayerEvent) -> Void = { _ in }
    private(set) var loadedURL: URL?
    private let player = AVPlayer()
    private var live = false
    private var controlObserver: NSKeyValueObservation?
    private var itemObserver: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var stallObserver: NSObjectProtocol?
    private var wantRate: Float = 1
    private var wantPlay = false

    override init() {
        super.init()
        player.automaticallyWaitsToMinimizeStalling = true
        controlObserver = player.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
            let st = p.timeControlStatus
            Task { @MainActor in
                guard let self else { return }
                switch st {
                case .playing: self.onEvent(.playing)
                case .paused: self.onEvent(.paused)
                case .waitingToPlayAtSpecifiedRate: self.onEvent(.buffering)
                @unknown default: break
                }
            }
        }
    }

    var position: Double? {
        guard loadedURL != nil, !live else { return nil }
        let t = player.currentTime().seconds
        return t.isFinite ? t : nil
    }

    var duration: Double? {
        guard let d = player.currentItem?.duration.seconds, d.isFinite, d > 0 else { return nil }
        return d
    }

    var isPlaying: Bool { player.timeControlStatus == .playing }
    var rate: Float { wantRate }

    func load(_ url: URL, live: Bool, start: Double, play: Bool) {
        self.live = live
        loadedURL = url
        let item = AVPlayerItem(asset: AVURLAsset(url: url))
        /* Live radio: stay near the live edge; files: buffer a little for smooth seeks. */
        item.preferredForwardBufferDuration = live ? 0 : 20
        item.audioTimePitchAlgorithm = .timeDomain
        itemObserver = item.observe(\.status, options: [.new]) { [weak self] it, _ in
            let failed = it.status == .failed
            Task { @MainActor in if failed { self?.onEvent(.failed("تعذّر تشغيل المصدر. جرّب إذاعة ثانية أو تأكد من الإنترنت.")) } }
        }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.onEvent(.ended) }
        }
        if let stallObserver { NotificationCenter.default.removeObserver(stallObserver) }
        /* A tunnel / weak coverage: AVPlayer waits; for live radio, reload at the live edge once back. */
        stallObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemPlaybackStalled, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.onEvent(.buffering) }
        }
        player.replaceCurrentItem(with: item)
        if !live, start > 0.5 { player.seek(to: CMTime(seconds: start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) }
        wantRate = 1
        wantPlay = play
        if play { self.play() }
    }

    func play() {
        wantPlay = true
        player.playImmediately(atRate: live ? 1 : wantRate)
    }

    func pause() {
        wantPlay = false
        player.pause()
    }

    func seek(to s: Double) {
        guard !live else { return }
        player.seek(to: CMTime(seconds: max(0, s), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func setRate(_ r: Float) {
        guard !live else { return }
        wantRate = r
        if wantPlay { player.rate = r }
    }

    func setVolume(_ v: Float) { player.volume = v }

    func unload() {
        wantPlay = false
        player.pause()
        player.replaceCurrentItem(with: nil)
        loadedURL = nil
    }
}

/// UI tests: plays nothing, remembers what it was told.
@MainActor
final class StubGroupAudioEngine: GroupAudioEngine {
    var onEvent: (GroupAudioPlayerEvent) -> Void = { _ in }
    private(set) var loadedURL: URL?
    private var startedAt: Date?
    private var base: Double = 0
    private(set) var volume: Float = 1
    private(set) var isPlaying = false
    private(set) var rate: Float = 1
    private var live = false
    let duration: Double? = nil

    var position: Double? {
        guard loadedURL != nil, !live else { return nil }
        guard isPlaying, let s = startedAt else { return base }
        return base + Date().timeIntervalSince(s) * Double(rate)
    }

    func load(_ url: URL, live: Bool, start: Double, play: Bool) {
        loadedURL = url
        self.live = live
        base = start
        isPlaying = false
        if play { self.play() }
    }

    func play() {
        base = position ?? 0
        startedAt = Date()
        isPlaying = true
        onEvent(.playing)
    }

    func pause() {
        base = position ?? 0
        isPlaying = false
        onEvent(.paused)
    }

    func seek(to s: Double) {
        base = s
        startedAt = Date()
    }

    func setRate(_ r: Float) {
        base = position ?? 0
        startedAt = Date()
        rate = r
    }

    func setVolume(_ v: Float) { volume = v }

    func unload() {
        loadedURL = nil
        isPlaying = false
    }
}

// MARK: - Lock screen / CarPlay now-playing and remote commands

@MainActor
final class GroupAudioNowPlaying {
    struct Handlers {
        var toggle: () -> Void = {}
        var play: () -> Void = {}
        var pause: () -> Void = {}
        var next: (() -> Void)?
    }

    private var targets: [(MPRemoteCommand, Any)] = []

    func attach(_ h: Handlers) {
        detachCommands()
        let c = MPRemoteCommandCenter.shared()
        func add(_ cmd: MPRemoteCommand, _ f: @escaping () -> Void) {
            cmd.isEnabled = true
            let t = cmd.addTarget { _ in
                Task { @MainActor in f() }
                return .success
            }
            targets.append((cmd, t))
        }
        add(c.togglePlayPauseCommand, h.toggle)
        add(c.playCommand, h.play)
        add(c.pauseCommand, h.pause)
        if let next = h.next { add(c.nextTrackCommand, next) } else { c.nextTrackCommand.isEnabled = false }
        c.previousTrackCommand.isEnabled = false
        c.changePlaybackPositionCommand.isEnabled = false
        c.skipForwardCommand.isEnabled = false
        c.skipBackwardCommand.isEnabled = false
    }

    func update(title: String, artist: String, live: Bool, position: Double?, duration: Double?, playing: Bool) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: artist,
            MPMediaItemPropertyAlbumTitle: "إذاعة الطلعة",
            MPNowPlayingInfoPropertyIsLiveStream: live,
            MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if !live, let position { info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position }
        if !live, let duration { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if let img = UIImage(named: "AppIcon") ?? UIImage(systemName: "dot.radiowaves.left.and.right") {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = playing ? .playing : .paused
    }

    func clear() {
        detachCommands()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    private func detachCommands() {
        for (cmd, t) in targets { cmd.removeTarget(t) }
        targets.removeAll()
    }
}
