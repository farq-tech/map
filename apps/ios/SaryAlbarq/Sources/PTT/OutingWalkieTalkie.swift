import Combine
import Foundation
import os
import UIKit

/// «قناة الطلعة» for one outing: hold to talk, everyone in the outing hears you
/// live, one person at a time — like a radio.
///
///   button / system PTT UI ─▶ PTTFloor ─effects─▶ LiveChannel (ptt_*, binary audio)
///                                         │      PTTAudioEngine (mic / speaker)
///                                         │      PTTRoute (system PushToTalk or in-app)
///                                         └────▶ NearbyMesh voice, when the server is unreachable
///
/// Lives with the `OutingSession` (not the screen), so a friend's voice plays
/// with the screen locked once iOS wakes the app through the system channel.
/// Nothing is recorded or kept: frames go out as they are made and are played
/// as they come.
@MainActor
final class OutingWalkieTalkie: ObservableObject {
    enum Mode: Equatable {
        /// Through the server (the normal case).
        case server
        /// Phone to phone, no internet (direct neighbours only).
        case nearby
        /// Neither: the button explains.
        case unavailable
    }

    @Published private(set) var floor: PTTFloor
    @Published private(set) var level: Float = 0
    @Published private(set) var mode: Mode = .unavailable
    /// A short sentence after a refusal («فهد يتكلم الآن»), cleared after a moment.
    @Published private(set) var notice: String?
    /// Ticks once a second while talking (the button's clock).
    @Published private(set) var nowMs = Date().timeIntervalSince1970 * 1000

    // «ترددات»: which channel we are on, and what the server says about all of them.
    /// "1"…"5" or a private channel's id. Saved per outing.
    @Published private(set) var channelId: String
    @Published private(set) var channels: [PTTChannelInfo]
    /// «+ تردد خاص»: the server says I may (the trip's leader).
    @Published private(set) var canCreatePrivate: Bool
    /// The server knows «ترددات» (it sent a channel list or a channel-tagged signal). Until then —
    /// a production server before the channels deploy — everyone is on one channel, the chip is
    /// hidden and nothing about channels is sent that could change what we hear.
    @Published private(set) var channelsSupported = false
    /// An invitation not looked at yet (a dot on the chip until the sheet opens).
    @Published private(set) var pendingInvite: PTTChannelInfo?
    /// REST for private channels (nil: the demo — everything stays on this phone).
    var channelBackend: PTTChannelBackend?
    /// The demo: may I play the leader (no server to say so).
    var demoLeader: () -> Bool = { false }

    let outingId: String
    let me: String
    private let defaults: UserDefaults
    private let audio: PTTAudioEngine
    private var route: PTTRoute
    /// Audio session owner when the system channel is not (yet) joined, or refused us: a
    /// `PTTSystemRoute` that is not joined does nothing, and the mic then recorded silence
    /// (no session category) and a friend's voice followed the silent switch.
    private let inApp = PTTInAppRoute()
    private var forceInAppAudio = false
    private var audioRoute: PTTRoute { route.isSystemChannel && !forceInAppAudio ? route : inApp }
    /// The system's talk button started this transmission (Lock Screen, Dynamic Island, headset).
    private var systemTransmit = false
    private let diag: (String, String) -> Void
    private var channel: LiveChannel?
    private weak var mesh: NearbyMesh?
    private let tokenBackend: PTTTokenBackend?
    private var audioReady = false
    private var capturingBurst: UInt8?
    private var playbackOn = false
    private var timer: Timer?
    private var noticeTimer: Timer?
    private var meshSilence: Timer?
    private var registeredToken: String?
    private var pendingPlayback: UInt8?
    /// «أصوات اللاسلكي»: which squelch / chirp / roger to play, and when.
    private var cues = PTTRadioCueSequencer()
    private var leaving = false
    /// Display names for «فلان يتكلم» (the server sends one too; this one is localised to our member list).
    var nameOf: (String) -> String? = { _ in nil }
    var outingName: () -> String = { "" }

    static let mutedKeyPrefix = "sary.ptt.muted."
    static let channelKeyPrefix = "sary.ptt.channel."

    /// Account deletion / `-resetState`: every outing's «كتم» choice and channel.
    static func forgetAll(defaults: UserDefaults = .standard) {
        for k in defaults.dictionaryRepresentation().keys where k.hasPrefix(mutedKeyPrefix) || k.hasPrefix(channelKeyPrefix) { defaults.removeObject(forKey: k) }
    }

    /// The saved channel for this outing, if it still looks like one ("1"…"5" or a uuid).
    static func savedChannel(_ outingId: String, defaults: UserDefaults) -> String {
        guard let s = defaults.string(forKey: channelKeyPrefix + outingId) else {
            /* A new outing starts on «التردد الافتراضي». */
            return defaults.string(forKey: PTTChannels.preferredKey).flatMap { PTTChannels.isPublic($0) ? $0 : nil } ?? PTTChannels.defaultId
        }
        return PTTChannels.isPublic(s) || UUID(uuidString: s) != nil ? s : PTTChannels.defaultId
    }

    #if DEBUG
    /// Screenshots only (`-SaryPTTDemo talking|listening`, DEBUG builds): the button and the
    /// speaking badge in a floor state, without a server or a microphone.
    func debugForce(_ s: PTTFloor.State) {
        floor.debugForce(s)
        mode = .server
        if case .talking = s { level = 0.55 }
    }
    #endif

    init(outingId: String, me: String, tokenBackend: PTTTokenBackend?, demo: Bool = false, demoCanCreatePrivate: Bool = false, route: PTTRoute? = nil, audio: PTTAudioEngine = PTTAudioEngine(), defaults: UserDefaults = .standard,
         diag: @escaping (String, String) -> Void = { PTTDiagnosticsLog.shared.add($0, $1) }) {
        self.diag = diag
        self.outingId = outingId
        self.me = me
        self.tokenBackend = tokenBackend
        self.audio = audio
        self.defaults = defaults
        self.route = route ?? Self.defaultRoute()
        var f = PTTFloor(me: me)
        _ = f.setMuted(defaults.bool(forKey: Self.mutedKeyPrefix + outingId))
        floor = f
        let savedChannel = Self.savedChannel(outingId, defaults: defaults)
        channelId = savedChannel
        self.demo = demo
        _channels = Published(initialValue: PTTChannels.publicList.map { channel in
            var channel = channel
            if demo, channel.id == savedChannel, !f.muted { channel.listeners = [me] }
            return channel
        })
        _canCreatePrivate = Published(initialValue: demo && demoCanCreatePrivate)
        self.route.callbacks = callbacks()
        inApp.callbacks = callbacks()
        audio.onFrame = { [weak self] frame in
            let bytes = frame.encoded()
            DispatchQueue.main.async { self?.sendFrame(bytes) }
        }
        audio.onLevel = { [weak self] l in self?.level = l }
    }

    static func defaultRoute() -> PTTRoute {
        #if canImport(PushToTalk) && !targetEnvironment(simulator)
        if PTTSystemRoute.shared.available { return PTTSystemRoute.shared }
        #endif
        return PTTInAppRoute()
    }

    var muted: Bool { floor.muted }

    // MARK: lifecycle

    func attach(channel: LiveChannel?, mesh: NearbyMesh?) {
        self.channel = channel
        self.mesh = mesh
        mesh?.onVoice = { [weak self] m in self?.nearbyVoice(m) }
        demo = channel == nil && channelBackend == nil
        /* `channelsSupported` already starts false. Avoid a redundant @Published write while
         * the demo session is synchronously attached during SwiftUI StateObject creation. */
        if demo, channelsSupported { channelsSupported = false }
        channel?.setPTTChannel(channelId)
        channel?.setPTTJoined(!muted)
        if demo { refreshDemoChannels() }
        refreshMode()
        #if canImport(PushToTalk) && !targetEnvironment(simulator)
        PTTSystemRoute.shared.onRemoteFailed = { [weak self] in
            guard let self, let b = self.pendingPlayback, case let .listening(t) = self.floor.state, t.burst == b,
                  UIApplication.shared.applicationState == .active else { return }
            self.diag("audio", "system refused the speaker: in-app speaker")
            self.forceInAppAudio = true
            self.pendingPlayback = nil
            self.inApp.setRemote(self.displayName(t))
            self.startPlayback(burst: b)
        }
        #endif
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    /// The outing screen closed: stop its socket/audio, but keep the system PTT channel while
    /// the member is still in an active outing. PushToTalk needs that joined channel to wake
    /// the app and play a stored voice note while its UI is closed or the screen is locked.
    /// Leaving the outing or ending it revokes the channel and its ephemeral push token.
    func detach(leftOuting: Bool) {
        leaving = true
        apply(floor.linkLost())
        leaving = false
        timer?.invalidate()
        timer = nil
        channel?.setPTTJoined(false)
        channel = nil
        mesh?.onVoice = { _ in }
        if leftOuting, route.isSystemChannel { route.leave() }
        if leftOuting { forgetToken() }
    }

    /// The socket's state changed (`OutingSession.linkChanged`).
    func linkChanged() {
        PTTAudioEngine.log.notice("[PTT] link live=\(self.channel?.isLive == true)")
        if channel?.isLive != true, mode == .server { apply(floor.linkLost()) }
        refreshMode()
        #if canImport(PushToTalk) && !targetEnvironment(simulator)
        (route as? PTTSystemRoute)?.setServiceStatus(channel?.isLive == true)
        #endif
    }

    func refreshMode() {
        let m: Mode
        if channel?.isLive == true { m = .server }
        else if let mesh, mesh.running, mesh.directPeers > 0 { m = .nearby }
        else { m = .unavailable }
        if m != mode { mode = m }
    }

    // MARK: my button

    func pressBegan() {
        refreshMode()
        joinSystemChannelIfNeeded()
        systemTransmit = false
        let fx = request(source: "button")
        /* The mic opens while the server decides (pre-roll), so the first word is not cut. */
        if fx.contains(where: { if case .sendStart = $0 { return true }; return false }) {
            audioRoute.beginTransmit()
        }
    }

    func pressEnded() {
        diag("floor", "release (button)")
        apply(floor.pressUp())
        audioRoute.endTransmit()
    }

    /// A press, from our button or the system's. With the socket down it still asks: the request
    /// waits for the reconnect (LiveChannel queues it) instead of an instant «لا اتصال».
    @discardableResult
    private func request(source: String) -> [PTTFloor.Effect] {
        let live = channel?.isLive == true
        let canReconnect = !live && channel.map { !$0.isStopped } == true && mode != .nearby
        if canReconnect { channel?.ensureLive(reason: "press") }
        let fx = floor.pressDown(nowMs: Self.now(), online: mode != .unavailable || canReconnect,
                                 waitMs: canReconnect ? PTTFloor.reconnectRequestTimeoutMs : PTTFloor.requestTimeoutMs)
        diag("floor", "press (\(source)) link=\(live ? "live" : canReconnect ? "reconnecting" : String(describing: mode)) → \(fx.map(Self.short).joined(separator: ","))")
        apply(fx)
        return fx
    }

    /// «اكتم القناة»: nothing in, nothing out, no Lock Screen wake-ups.
    func setMuted(_ on: Bool) {
        defaults.set(on, forKey: Self.mutedKeyPrefix + outingId)
        apply(floor.setMuted(on))
        channel?.setPTTJoined(!on)
        if on {
            if route.isSystemChannel { route.leave() }
            forgetToken()
        } else {
            /* A tap is the user interaction the system channel needs to join. */
            joinSystemChannelIfNeeded()
        }
        objectWillChange.send()
    }

    /// The user explicitly started a voice message. Join Apple's system PTT channel now so
    /// incoming messages can wake this device and play through the system audio session later.
    func prepareForBackgroundMessages() {
        joinSystemChannelIfNeeded()
    }

    // MARK: inbound

    /// A ptt_* signal tagged with its channel («ترددات»). One for another channel (in flight
    /// while we switched) is dropped: it is not what this radio is tuned to.
    func receive(_ s: PTTSignal, channel ch: String?) {
        if ch != nil, !channelsSupported { channelsSupported = true }
        if let ch, ch != channelId {
            diag("ptt", "\(Self.short(s)) for another channel: dropped")
            return
        }
        if case let .idle(_, _, reason) = s, [.switched, .removed, .closed].contains(reason) { quietEnd = true }
        receive(s)
        quietEnd = false
    }

    func receive(_ s: PTTSignal) {
        let fx = floor.receive(s, nowMs: Self.now())
        diag("ptt", "\(Self.short(s)) → \(fx.map(Self.short).joined(separator: ","))")
        apply(fx)
    }

    private var rxFrames = 0

    /// Signal / effect in a few words for «سجل القناة» (no names, no ids).
    static func short(_ s: PTTSignal) -> String {
        switch s {
        case let .grant(_, burst, _): return "grant b\(burst)"
        case let .deny(_, reason, _): return "deny \(reason)"
        case let .state(t, _): return t == nil ? "state idle" : "state talker b\(t!.burst)"
        case let .talker(t): return "talker b\(t.burst)"
        case let .idle(_, burst, reason): return "idle b\(burst) \(reason)"
        }
    }

    static func short(_ e: PTTFloor.Effect) -> String {
        switch e {
        case .sendStart: return "sendStart"
        case .sendStop: return "sendStop"
        case let .startCapture(b): return "mic b\(b)"
        case .stopCapture: return "micOff"
        case let .startPlayback(t): return "play b\(t.burst)"
        case .stopPlayback: return "playOff"
        case let .refused(r): return "refused \(r)"
        case let .cutOff(r): return "cutOff \(r)"
        }
    }

    func receiveAudio(_ d: Data) {
        guard let f = PTTFrame.decode(d) else { return diag("audio", "undecodable frame (\(d.count) bytes)") }
        rxFrames += 1
        if rxFrames == 1 || rxFrames % 100 == 0 { diag("audio", "rx frames=\(rxFrames) playback=\(playbackOn) ready=\(audioReady)") }
        guard playbackOn else { return }
        audio.receive(f)
    }

    /// iOS woke us with a pushtotalk push: make sure the socket comes back (now, not after a backoff) and joins.
    func wokenByPush() {
        diag("push", "pushtotalk wake (link=\(channel?.isLive == true ? "live" : "down"))")
        channel?.ensureLive(reason: "push")
        channel?.setPTTJoined(!muted)
    }

    // MARK: effects

    private func apply(_ fx: [PTTFloor.Effect]) {
        for e in fx {
            switch e {
            case let .sendStart(id):
                micWanted = true
                preRoll = []
                if mode == .nearby { nearbyStart(id: id) } else { channel?.pttStart(id: id) }
            case .sendStop:
                if mode == .nearby, let b = capturingBurst ?? lastNearbyBurst { mesh?.sendVoice(.stop, body: Data([b])) }
                else { channel?.pttStop() }
                if !isTalking { stopMic() }
            case let .startCapture(burst):
                nowMs = Self.now()
                capturingBurst = burst
                micWanted = true
                if mode == .nearby { mesh?.sendVoice(.start, body: Data([burst])) }
                /* What was said while we waited for the floor goes out first, stamped with our burst. */
                let early = preRoll
                preRoll = []
                for d in early { transmit(d, burst: burst) }
                startCaptureIfReady()
                /* "Speak now": once the floor is ours *and* the session is live. The engine sends
                   silence while it sounds, so the chirp never goes on air. */
                if let c = cues.talkGranted(audioReady: audioReady, cueContext) { audio.playCue(c) }
            case .stopCapture:
                /* Roger first (the mic is gated while it sounds), then the mic closes. */
                if let c = cues.talkEnded(cueContext) { audio.playCue(c) }
                stopMic()
                audioRoute.endTransmit()
                systemTransmit = false
                if forceInAppAudio, !playbackOn { forceInAppAudio = false }
            case let .startPlayback(t):
                playbackOn = true
                audio.armReceive(burst: t.burst)
                pendingPlayback = t.burst
                audioRoute.setRemote(displayName(t))
                /* If activation completed synchronously because the session was already active,
                 * playbackReady may have drained this pending burst inside setRemote. */
                if audioReady, pendingPlayback == t.burst {
                    pendingPlayback = nil
                    startPlayback(burst: t.burst)
                } else if !audioReady {
                    /* The system route normally activates via PushToTalk. If it doesn't, the
                     * foreground fallback borrows the app route; that route also confirms ready. */
                    if audioRoute.isSystemChannel { armPlaybackFallback(t) }
                }
            case .stopPlayback:
                PTTAudioEngine.log.notice("[PTT] stop playback (mode=\(String(describing: self.mode), privacy: .public) live=\(self.channel?.isLive == true))")
                playbackOn = false
                pendingPlayback = nil
                /* Muted, the link dropped, or we tuned away: no roger for a transmission we did not hear end. */
                let quiet = leaving || muted || quietEnd || (channel?.isLive != true && mode != .nearby)
                audio.stopPlayback(cue: cues.incomingEnded(quiet: quiet, cueContext))
                audioRoute.setRemote(nil)
                if forceInAppAudio, !micWanted { forceInAppAudio = false }
            case let .refused(r):
                if !isTalking { stopMic() }
                let text = Self.text(for: r, name: { self.nameOf($0 ?? "") })
                show(text)
                /* Hand the system's talk UI back at once, and say why where the person is looking. */
                audioRoute.endTransmit()
                if systemTransmit, audioRoute !== route { route.endTransmit() }
                if systemTransmit, UIApplication.shared.applicationState != .active {
                    Notifier.post(title: "قناة الطلعة", body: "ما انرسل صوتك: \(text)", outingId: outingId, kind: "ptt")
                }
                systemTransmit = false
            case let .cutOff(reason):
                show(reason == .maxDuration ? "انتهت الدقيقة — اضغط مرة ثانية لتكمل" : "انقطع الإرسال")
            }
        }
        objectWillChange.send()
    }

    /// The mic should be on: asking for the floor (pre-roll) or talking.
    private var micWanted = false
    private var micOn = false
    /// Frames made before the grant (≤ 20 ≈ 600 ms; the server's per-second cap leaves room for them).
    private var preRoll: [Data] = []
    static let preRollMax = 20

    private var isTalking: Bool { if case .talking = floor.state { return true }; return false }

    private func startCaptureIfReady() {
        guard micWanted, !micOn else { return }
        guard audioReady else { return }
        micOn = true
        audio.startCapture(burst: capturingBurst ?? 0)
    }

    private var cueContext: PTTRadioCueSequencer.Context {
        .init(enabled: PTTRadioSounds.enabled(defaults), systemRoute: audioRoute.isSystemChannel)
    }

    private func startPlayback(burst: UInt8) {
        diag("audio", "speaker on b\(burst) via \(audioRoute.isSystemChannel ? "system" : "app")")
        audio.startPlayback(burst: burst, cue: cues.incomingStarted(burst: burst, cueContext))
    }

    /// The system should activate the session for a friend's voice (didActivate). If it has not
    /// within a moment and we are on screen, open the speaker ourselves rather than stay silent.
    private func armPlaybackFallback(_ t: PTTTalker) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, self.pendingPlayback == t.burst, UIApplication.shared.applicationState == .active else { return }
            self.diag("audio", "no didActivate after 1.2 s: in-app speaker")
            self.forceInAppAudio = true
            self.pendingPlayback = nil
            self.inApp.setRemote(self.displayName(t))
            self.startPlayback(burst: t.burst)
        }
    }

    private func stopMic() {
        micWanted = false
        preRoll = []
        capturingBurst = nil
        level = 0
        guard micOn else { return }
        micOn = false
        audio.stopCapture()
    }

    private var txFrames = 0

    private func sendFrame(_ bytes: Data) {
        switch floor.state {
        case .requesting:
            preRoll.append(bytes)
            if preRoll.count > Self.preRollMax { preRoll.removeFirst(preRoll.count - Self.preRollMax) }
        case let .talking(burst, _):
            transmit(bytes, burst: burst)
        default:
            break
        }
    }

    private func transmit(_ frame: Data, burst: UInt8) {
        var bytes = frame
        if bytes.count > 1 { bytes[bytes.startIndex + 1] = burst }
        txFrames += 1
        if txFrames % 33 == 1 { PTTAudioEngine.log.notice("[PTT] tx frames=\(self.txFrames) bytes=\(bytes.count) mode=\(String(describing: self.mode), privacy: .public)") }
        switch mode {
        case .server: channel?.sendAudio(bytes)
        case .nearby: mesh?.sendVoice(.audio, body: bytes)
        case .unavailable: break
        }
    }

    private func callbacks() -> PTTRouteCallbacks {
        var c = PTTRouteCallbacks()
        c.transmitReady = { [weak self] in
            guard let self else { return }
            self.audioReady = true
            self.startCaptureIfReady()
            if let cue = self.cues.audioBecameReady(self.cueContext) { self.audio.playCue(cue) }
        }
        c.playbackReady = { [weak self] in
            guard let self else { return }
            self.audioReady = true
            if let r = self.noteSpeakerReady {
                self.noteSpeakerReady = nil
                r()
            }
            if let b = self.pendingPlayback {
                self.pendingPlayback = nil
                self.startPlayback(burst: b)
            }
        }
        c.audioUnavailable = { [weak self] in
            guard let self else { return }
            self.audioReady = false
            self.pendingPlayback = nil
            self.playbackOn = false
            self.audio.stopPlayback(cue: nil)
            self.diag("audio", "in-app speaker unavailable")
            self.show("تعذر تشغيل صوت اللاسلكي")
        }
        c.audioDeactivated = { [weak self] in self?.audioReady = false }
        c.systemBeganTransmit = { [weak self] in
            /* The Lock Screen / headset button: same as ours — and the socket may need to come back first
             * (the system keeps the transmission open meanwhile; we end it if the floor is refused). */
            guard let self else { return }
            self.refreshMode()
            self.systemTransmit = true
            self.request(source: "system")
        }
        c.transmitEnded = { [weak self] in
            guard let self else { return }
            self.diag("floor", "release (system)")
            self.systemTransmit = false
            if case .talking = self.floor.state { self.apply(self.floor.pressUp()) }
            if case .requesting = self.floor.state { self.apply(self.floor.pressUp()) }
        }
        c.transmitFailed = { [weak self] in
            guard let self else { return }
            /* The system would not start (another call, a restriction): on screen, our own button still works in-app. */
            if !self.systemTransmit, UIApplication.shared.applicationState == .active, self.micWanted {
                self.diag("audio", "system transmit refused: in-app mic")
                self.forceInAppAudio = true
                self.inApp.beginTransmit()
                return
            }
            self.systemTransmit = false
            if case .talking = self.floor.state { self.apply(self.floor.pressUp()) }
            if case .requesting = self.floor.state { self.apply(self.floor.pressUp()) }
        }
        c.token = { [weak self] hex in self?.registerToken(hex) }
        c.leftChannel = { [weak self] in self?.forgetToken() }
        return c
    }

    // MARK: «رسالة صوتية» — the system speaker for a voice note (phone locked)

    private var noteSpeakerReady: (() -> Void)?

    /// The PushToTalk system channel is joined (a voice note can play with the screen locked).
    var hasSystemChannel: Bool { route.isSystemChannel }

    /// Ask the system to activate its walkie-talkie session for a voice note from `name` (the Lock
    /// Screen shows them speaking). `ready` runs once it is active — at once if it already is.
    /// False when there is no system channel to borrow.
    @discardableResult
    func borrowSystemSpeaker(name: String, ready: @escaping () -> Void) -> Bool {
        guard route.isSystemChannel, !muted else { return false }
        route.setRemote(name)
        if audioReady {
            ready()
        } else {
            noteSpeakerReady = ready
        }
        return true
    }

    /// The voice note is over: the system may close its session (unless a live talker took it meanwhile).
    func returnSystemSpeaker() {
        noteSpeakerReady = nil
        guard route.isSystemChannel else { return }
        if case .idle = floor.state { route.setRemote(nil) }
    }

    /// A voice note may play now: nobody is on air live and we are not talking.
    var isQuiet: Bool { floor.state == .idle }

    private func joinSystemChannelIfNeeded() {
        guard !muted else { return }
        #if canImport(PushToTalk) && !targetEnvironment(simulator)
        if let sys = route as? PTTSystemRoute ?? (PTTSystemRoute.shared.available ? PTTSystemRoute.shared : nil) {
            route = sys
            sys.callbacks = callbacks()
            /* Another outing may have left this singleton's channel joined. `join` is
               idempotent for this outing and switches cleanly when its UUID is different. */
            sys.join(outingId: outingId, name: systemChannelName)
        }
        #endif
    }

    private func registerToken(_ hex: String) {
        guard !muted, let b = tokenBackend else { return }
        registeredToken = hex
        let id = outingId
        Task { try? await b.registerPTTToken(id, token: hex, environment: PushRegistrar.buildEnvironment) }
    }

    private func forgetToken() {
        guard let b = tokenBackend else { return }
        registeredToken = nil
        let id = outingId
        Task { try? await b.unregisterPTTToken(id) }
    }

    private func tick() {
        let now = Self.now()
        /* The clock is only UI state while we hold the floor. Publishing it twice a second
         * while idle needlessly invalidated the map and could race SwiftUI's first render. */
        if case .talking = floor.state, Int(now / 1000) != Int(nowMs / 1000) { nowMs = now }
        refreshMode()
        if floor.needsTick(nowMs: now) {
            let effects = floor.tick(nowMs: now)
            if !effects.isEmpty { apply(effects) }
        }
    }

    private func show(_ text: String) {
        notice = text
        noticeTimer?.invalidate()
        noticeTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.notice = nil }
        }
    }

    private func displayName(_ t: PTTTalker) -> String {
        nameOf(t.userId) ?? (t.name.isEmpty ? "عضو" : t.name)
    }

    static func now() -> Double { Date().timeIntervalSince1970 * 1000 }

    static func text(for r: PTTFloor.Refusal, name: (String?) -> String?) -> String {
        switch r {
        case .busy(let id): return "\(name(id) ?? "أحد") يتكلم الآن — انتظر دورك"
        case .muted: return "القناة مكتومة — شغّلها من الإعدادات"
        case .offline: return "لا اتصال الآن — جرّب بعد قليل"
        case .rateLimited: return "محاولات كثيرة — انتظر قليلًا"
        case .notAllowed: return "لا يمكنك التكلم في هذه الطلعة"
        }
    }

    // MARK: nearby (no internet)

    // MARK: «ترددات» — channels

    /// Set while a transmission ends because we changed channel (no roger beep for it).
    private var quietEnd = false

    var currentChannel: PTTChannelInfo? { channels.first { $0.id == channelId } }

    /// «غيّر التردد»: the knob clicks at once; whatever we heard or said on the old channel ends
    /// for us; the server tunes us in and sends the new channel's current sentence from its start.
    func switchChannel(_ id: String) {
        guard id != channelId else { return }
        guard PTTChannels.isPublic(id) || channels.contains(where: { $0.id == id && $0.isPrivate }) else { return }
        diag("channel", "switch → \(PTTChannels.isPublic(id) ? id : "private")")
        quietEnd = true
        apply(floor.channelSwitched())
        quietEnd = false
        channelId = id
        defaults.set(id, forKey: Self.channelKeyPrefix + outingId)
        channel?.setPTTChannel(id)
        if PTTRadioSounds.enabled(defaults) { audio.playCue(.channelClick) }
        updateSystemChannelName()
        if demo { refreshDemoChannels() }
        if pendingInvite?.id == id { pendingInvite = nil }
        objectWillChange.send()
    }

    /// The sheet was opened: the invitation was seen.
    func invitationSeen() { pendingInvite = nil }

    /// ptt_channels / ptt_channel_kicked / ptt_channel_invite.
    func receiveChannel(_ ev: PTTChannelEvent) {
        switch ev {
        case let .list(_, canCreate, list):
            channelsSupported = true
            channels = list.isEmpty ? PTTChannels.publicList : list
            canCreatePrivate = canCreate
            /* Our private channel is gone from the list (closed while we were away): back to ١. */
            if !PTTChannels.isPublic(channelId), !channels.contains(where: { $0.id == channelId }) { fallBack() }
        case let .kicked(ch, reason):
            let name = channels.first { $0.id == ch }?.name
            if ch == channelId { fallBack() }
            if reason != "not_invited" || ch == channelId { show(PTTChannels.kickedText(reason, name: name)) }
        case let .invited(ch, name, _):
            pendingInvite = PTTChannelInfo(id: ch, kind: .private, name: name)
            show(PTTChannels.inviteText(name))
        }
        objectWillChange.send()
    }

    /// Off a private channel (removed, closed, not invited): the server already put us on ١.
    private func fallBack() {
        quietEnd = true
        apply(floor.channelSwitched())
        quietEnd = false
        channelId = PTTChannels.defaultId
        defaults.set(channelId, forKey: Self.channelKeyPrefix + outingId)
        channel?.pttChannelReset()
        updateSystemChannelName()
    }

    /// «قناة الطلعة · تردد ٣» on the Lock Screen / Dynamic Island.
    private func updateSystemChannelName() {
        route.setChannelName(systemChannelName)
    }

    var systemChannelName: String {
        channelsSupported || demo ? PTTChannels.systemLabel(PTTChannels.chipLabel(currentChannel)) : "قناة الطلعة"
    }

    /// Show the channel chip: the server has channels (or the demo, which keeps them on the phone).
    var showsChannels: Bool { channelsSupported || demo }

    /// «+ تردد خاص» (the leader): name + the members he picks. The server checks everything again.
    func createPrivate(name: String, members: [String]) async throws -> PTTChannelInfo {
        if let b = channelBackend {
            let c = try await b.createPTTChannel(outingId, name: name, members: members)
            if !channels.contains(where: { $0.id == c.id }) { channels.append(c) }
            return c
        }
        /* The demo: a channel on this phone only. */
        let c = PTTChannelInfo(id: UUID().uuidString.lowercased(), kind: .private, name: name, members: [me] + members.filter { $0 != me }, createdBy: me, canManage: true)
        demoPrivate.append(c)
        refreshDemoChannels()
        return c
    }

    func updatePrivate(_ id: String, name: String?, add: [String], remove: [String]) async throws {
        if let b = channelBackend {
            let c = try await b.updatePTTChannel(outingId, channel: id, name: name, add: add, remove: remove)
            if let i = channels.firstIndex(where: { $0.id == id }) { channels[i] = c }
            return
        }
        guard let i = demoPrivate.firstIndex(where: { $0.id == id }) else { return }
        if let name { demoPrivate[i].name = name }
        demoPrivate[i].members = demoPrivate[i].members.filter { !remove.contains($0) } + add.filter { !demoPrivate[i].members.contains($0) }
        refreshDemoChannels()
    }

    func closePrivate(_ id: String) async throws {
        if let b = channelBackend {
            try await b.closePTTChannel(outingId, channel: id)
            channels.removeAll { $0.id == id }
        } else {
            demoPrivate.removeAll { $0.id == id }
            refreshDemoChannels()
        }
        if channelId == id { fallBack() }
        objectWillChange.send()
    }

    private var demoPrivate: [PTTChannelInfo] = []
    /// Attached without a server (the demo outing): channels live on this phone.
    private var demo = false

    /// No server (the demo): the five public channels and ours, with only me listening where I am.
    private func refreshDemoChannels() {
        guard demo else { return }
        let updatedChannels = (PTTChannels.publicList + demoPrivate).map { c in
            var c = c
            c.listeners = c.id == channelId && !muted ? [me] : []
            return c
        }
        if channels != updatedChannels { channels = updatedChannels }
        let canCreate = demoLeader()
        if canCreatePrivate != canCreate { canCreatePrivate = canCreate }
    }

    private var lastNearbyBurst: UInt8?
    private var nearbyTalker: (id: String, burst: UInt8, atMs: Double)?

    /// No server to grant the floor: take it if nobody nearby is talking.
    private func nearbyStart(id: Int) {
        if let t = nearbyTalker, Self.now() - t.atMs < 1_500 {
            return apply(floor.receive(.deny(id: id, reason: "busy", talkerId: t.id), nowMs: Self.now()))
        }
        let b = UInt8.random(in: 1...255)
        lastNearbyBurst = b
        apply(floor.receive(.grant(id: id, burst: b, maxMs: Int(PTTFloor.maxTalkMs)), nowMs: Self.now()))
    }

    private func nearbyVoice(_ m: MeshVoiceCodec.Message) {
        guard !muted, mode != .server else { return }
        let now = Self.now()
        switch m.kind {
        case .start, .audio:
            let frame = m.kind == .audio ? PTTFrame.decode(m.body) : nil
            guard let burst = frame?.burst ?? m.body.first else { return }
            if nearbyTalker?.id != m.from || nearbyTalker?.burst != burst {
                /* Two pressed at once: the lower id keeps the floor (both phones agree). */
                if case .talking = floor.state, me.lowercased() < m.from.lowercased() { return }
                nearbyTalker = (m.from, burst, now)
                apply(floor.receive(.talker(PTTTalker(userId: m.from, name: nameOf(m.from) ?? "", burst: burst)), nowMs: now))
            }
            nearbyTalker?.atMs = now
            if let frame, playbackOn { audio.receive(frame) }
            armNearbySilence()
        case .stop:
            guard let t = nearbyTalker, t.id == m.from else { return }
            endNearby(t)
        }
    }

    private func armNearbySilence() {
        meshSilence?.invalidate()
        meshSilence = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, let t = self.nearbyTalker else { return }
                self.endNearby(t)
            }
        }
    }

    private func endNearby(_ t: (id: String, burst: UInt8, atMs: Double)) {
        nearbyTalker = nil
        meshSilence?.invalidate()
        apply(floor.receive(.idle(userId: t.id, burst: t.burst, reason: .released), nowMs: Self.now()))
    }
}

/// POST / DELETE /api/outings/:id/ptt/token.
protocol PTTTokenBackend: AnyObject {
    func registerPTTToken(_ outingId: String, token: String, environment: String) async throws
    func unregisterPTTToken(_ outingId: String) async throws
}

extension OutingsAPI: PTTTokenBackend {}
