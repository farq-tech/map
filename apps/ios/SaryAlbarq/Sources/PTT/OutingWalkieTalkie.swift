import Combine
import Foundation
import os

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

    let outingId: String
    let me: String
    private let defaults: UserDefaults
    private let audio: PTTAudioEngine
    private var route: PTTRoute
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
    /// Display names for «فلان يتكلم» (the server sends one too; this one is localised to our member list).
    var nameOf: (String) -> String? = { _ in nil }
    var outingName: () -> String = { "" }

    static let mutedKeyPrefix = "sary.ptt.muted."

    /// Account deletion / `-resetState`: every outing's «كتم» choice.
    static func forgetAll(defaults: UserDefaults = .standard) {
        for k in defaults.dictionaryRepresentation().keys where k.hasPrefix(mutedKeyPrefix) { defaults.removeObject(forKey: k) }
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

    init(outingId: String, me: String, tokenBackend: PTTTokenBackend?, route: PTTRoute? = nil, audio: PTTAudioEngine = PTTAudioEngine(), defaults: UserDefaults = .standard) {
        self.outingId = outingId
        self.me = me
        self.tokenBackend = tokenBackend
        self.audio = audio
        self.defaults = defaults
        self.route = route ?? Self.defaultRoute()
        var f = PTTFloor(me: me)
        _ = f.setMuted(defaults.bool(forKey: Self.mutedKeyPrefix + outingId))
        floor = f
        self.route.callbacks = callbacks()
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
        channel?.setPTTJoined(!muted)
        refreshMode()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    /// The outing screen closed / the outing is over: off the air, off the system channel.
    func detach(leftOuting: Bool) {
        apply(floor.linkLost())
        timer?.invalidate()
        timer = nil
        channel?.setPTTJoined(false)
        channel = nil
        mesh?.onVoice = { _ in }
        if route.isSystemChannel { route.leave() }
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
        let fx = floor.pressDown(nowMs: Self.now(), online: mode != .unavailable)
        apply(fx)
        /* The mic opens while the server decides (pre-roll), so the first word is not cut. */
        if fx.contains(where: { if case .sendStart = $0 { return true }; return false }) {
            route.beginTransmit()
        }
    }

    func pressEnded() {
        apply(floor.pressUp())
        route.endTransmit()
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

    // MARK: inbound

    func receive(_ s: PTTSignal) {
        PTTAudioEngine.log.notice("[PTT] signal \(String(describing: s), privacy: .public)")
        apply(floor.receive(s, nowMs: Self.now()))
    }

    func receiveAudio(_ d: Data) {
        guard playbackOn, let f = PTTFrame.decode(d) else { return }
        audio.receive(f)
    }

    /// iOS woke us with a pushtotalk push: make sure the socket comes back and joins.
    func wokenByPush() {
        channel?.reconnectNow()
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
                capturingBurst = burst
                micWanted = true
                if mode == .nearby { mesh?.sendVoice(.start, body: Data([burst])) }
                /* What was said while we waited for the floor goes out first, stamped with our burst. */
                let early = preRoll
                preRoll = []
                for d in early { transmit(d, burst: burst) }
                startCaptureIfReady()
            case .stopCapture:
                stopMic()
                route.endTransmit()
            case let .startPlayback(t):
                playbackOn = true
                audio.armReceive(burst: t.burst)
                route.setRemote(displayName(t))
                /* The system route activates the session asynchronously (didActivate). */
                if audioReady || !route.isSystemChannel { audio.startPlayback(burst: t.burst) } else { pendingPlayback = t.burst }
            case .stopPlayback:
                PTTAudioEngine.log.notice("[PTT] stop playback (mode=\(String(describing: self.mode), privacy: .public) live=\(self.channel?.isLive == true))")
                playbackOn = false
                pendingPlayback = nil
                audio.stopPlayback()
                route.setRemote(nil)
            case let .refused(r):
                if !isTalking { stopMic() }
                show(Self.text(for: r, name: { self.nameOf($0 ?? "") }))
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
        /* The in-app route activates the session synchronously; the system one on didActivate. */
        if audioReady || !route.isSystemChannel {
            micOn = true
            audio.startCapture(burst: capturingBurst ?? 0)
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
        }
        c.playbackReady = { [weak self] in
            guard let self else { return }
            self.audioReady = true
            if let b = self.pendingPlayback {
                self.pendingPlayback = nil
                self.audio.startPlayback(burst: b)
            }
        }
        c.audioDeactivated = { [weak self] in self?.audioReady = false }
        c.systemBeganTransmit = { [weak self] in
            /* The Lock Screen / headset button: same as ours. */
            guard let self else { return }
            self.refreshMode()
            self.apply(self.floor.pressDown(nowMs: Self.now(), online: self.mode != .unavailable))
        }
        c.transmitEnded = { [weak self] in
            guard let self else { return }
            if case .talking = self.floor.state { self.apply(self.floor.pressUp()) }
            if case .requesting = self.floor.state { self.apply(self.floor.pressUp()) }
        }
        c.token = { [weak self] hex in self?.registerToken(hex) }
        c.leftChannel = { [weak self] in self?.forgetToken() }
        return c
    }

    private func joinSystemChannelIfNeeded() {
        guard !muted, !route.isSystemChannel else { return }
        #if canImport(PushToTalk) && !targetEnvironment(simulator)
        if let sys = route as? PTTSystemRoute ?? (PTTSystemRoute.shared.available ? PTTSystemRoute.shared : nil) {
            route = sys
            sys.callbacks = callbacks()
            sys.join(outingId: outingId, name: outingName())
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
        nowMs = Self.now()
        refreshMode()
        apply(floor.tick(nowMs: nowMs))
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
