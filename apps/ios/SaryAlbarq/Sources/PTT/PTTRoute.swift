import AVFoundation
import Foundation
import os
#if canImport(PushToTalk)
import PushToTalk
import UIKit
#endif

/// Who owns the audio session and the "on air" UI.
///
///   * `PTTSystemRoute` — Apple's PushToTalk framework (iOS 16+): the system
///     PTT UI on the Lock Screen / Dynamic Island, the talk button there, and
///     a `pushtotalk` push that wakes the app to play a friend's voice with the
///     screen locked. The system activates and deactivates the audio session.
///   * `PTTInAppRoute` — no system channel (the simulator, or the person never
///     joined one): the app activates the session itself; works in the
///     foreground only.
///
/// Both report back through the same callbacks, so `OutingWalkieTalkie` does
/// not care which one it has.
@MainActor
protocol PTTRoute: AnyObject {
    var callbacks: PTTRouteCallbacks { get set }
    /// Joined the system channel for this outing (false for the in-app route).
    var isSystemChannel: Bool { get }
    func join(outingId: String, name: String)
    func leave()
    /// The finger went down: ask for the mic. `callbacks.transmitReady` when it is live.
    func beginTransmit()
    func endTransmit()
    /// Someone else is on air (nil: nobody). `callbacks.playbackReady` when the speaker is ready.
    func setRemote(_ name: String?)
    /// «ترددات»: the channel name the system UI shows («قناة الطلعة · تردد ٣»).
    func setChannelName(_ name: String)
}

extension PTTRoute {
    func setChannelName(_ name: String) {}
}

struct PTTRouteCallbacks {
    /// The mic may record now (audio session active).
    var transmitReady: () -> Void = {}
    /// The system's own talk button (Lock Screen, headset, CarPlay) began a transmission.
    var systemBeganTransmit: () -> Void = {}
    /// The system ended our transmission (button released there, a call came in…).
    var transmitEnded: () -> Void = {}
    /// The system refused to start a transmission we asked for (failedToBeginTransmitting).
    var transmitFailed: () -> Void = {}
    /// The speaker may play now.
    var playbackReady: () -> Void = {}
    /// The ephemeral APNs token for this channel (hex), for POST /ptt/token.
    var token: (String) -> Void = { _ in }
    /// The system took the audio session back (system route only).
    var audioDeactivated: () -> Void = {}
    /// Left the channel from the system UI.
    var leftChannel: () -> Void = {}
}

// MARK: - in-app

@MainActor
final class PTTInAppRoute: PTTRoute {
    var callbacks = PTTRouteCallbacks()
    let isSystemChannel = false
    private var sessionActive = false

    func join(outingId: String, name: String) {}
    func leave() { deactivate() }

    func beginTransmit() {
        activate()
        callbacks.transmitReady()
    }

    func endTransmit() { deactivateSoon() }

    func setRemote(_ name: String?) {
        if name != nil {
            activate()
            callbacks.playbackReady()
        } else {
            deactivateSoon()
        }
    }

    private func activate() {
        guard !sessionActive else { return }
        /* «إذاعة الطلعة» pauses while the walkie-talkie has the speaker, and resumes after. */
        GroupAudioDuck.began(.ptt)
        let s = AVAudioSession.sharedInstance()
        do {
            try s.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP])
            try s.setActive(true)
            PTTDiagnosticsLog.shared.add("audio", "in-app session active")
        } catch {
            PTTDiagnosticsLog.shared.add("audio", "in-app session failed: \((error as NSError).domain)#\((error as NSError).code)")
        }
        sessionActive = true
    }

    private var pendingDeactivate: DispatchWorkItem?

    private func deactivateSoon() {
        pendingDeactivate?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.deactivate() }
        pendingDeactivate = w
        /* Back-and-forth talk should not flap the session (and other apps' audio); long enough
           for the jitter buffer's drain (≤ 2 s) and the roger + squelch tail after it. */
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.8, execute: w)
    }

    private func deactivate() {
        pendingDeactivate?.cancel()
        guard sessionActive else { return }
        sessionActive = false
        let music = GroupAudioDuck.musicOwnsSession
        if !music { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
        GroupAudioDuck.ended(.ptt)
    }
}

// MARK: - system (PushToTalk)

#if canImport(PushToTalk)
/// One per app (Apple: only one PTT channel can be active on the system, and the
/// channel manager must be created as early as possible at launch so a channel
/// can be restored and a push delivered after the app was terminated).
@MainActor
final class PTTSystemRoute: NSObject, PTTRoute {
    static let shared = PTTSystemRoute()
    static let log = Logger(subsystem: "sa.sary.albarq", category: "ptt")
    /// Every PTChannelManager callback goes to «سجل القناة» (thread-safe; no names, no ids).
    nonisolated static func diag(_ m: String) { PTTDiagnosticsLog.shared.add("sys", m) }

    var callbacks = PTTRouteCallbacks()
    private(set) var manager: PTChannelManager?
    private(set) var channelUUID: UUID?
    private var outingId: String?
    /// What the system PTT UI calls the channel: «قناة الطلعة · تردد ٣».
    private var outingName = "قناة الطلعة"
    /// Set by the delegate when a push names the speaker: who to show.
    private(set) var joinedSystem = false
    /// A push woke us for this outing (main thread hand-off from the delegate).
    var onWokenByPush: (_ outingId: String, _ talkerName: String) -> Void = { _, _ in }

    var isSystemChannel: Bool { joinedSystem }

    /// The framework is there and allowed (real device, entitlement present).
    var available: Bool { manager != nil }

    /// Call at launch. Restores a channel the system kept.
    func setUp() async {
        guard manager == nil else { return }
        do {
            manager = try await PTChannelManager.channelManager(delegate: self, restorationDelegate: self)
            if let restored = manager?.activeChannelUUID {
                channelUUID = restored
                joinedSystem = true
            }
            Self.diag("manager ready (restored channel: \(joinedSystem))")
        } catch {
            Self.log.notice("[PTT] system channel unavailable: \(String(describing: error), privacy: .public)")
            Self.diag("manager unavailable: \(Self.describe(error))")
        }
    }

    static func uuid(for outingId: String) -> UUID? { UUID(uuidString: outingId) }

    func join(outingId: String, name: String) {
        guard let m = manager, let u = Self.uuid(for: outingId) else { return }
        self.outingId = outingId
        outingName = name.isEmpty ? "قناة الطلعة" : name
        if channelUUID == u, joinedSystem { return }
        /* Another outing's channel is still up: leave it first (one channel per system). */
        if let old = channelUUID, old != u {
            Self.diag("leaving another outing's channel")
            m.leaveChannel(channelUUID: old)
        }
        channelUUID = u
        Self.diag("requestJoinChannel")
        m.requestJoinChannel(channelUUID: u, descriptor: descriptor())
    }

    func leave() {
        guard let m = manager, let u = channelUUID else { return }
        m.leaveChannel(channelUUID: u)
    }

    func beginTransmit() {
        guard let m = manager, let u = channelUUID, joinedSystem else { return Self.diag("beginTransmit skipped (not joined)") }
        Self.diag("requestBeginTransmitting")
        m.requestBeginTransmitting(channelUUID: u)
    }

    func endTransmit() {
        guard let m = manager, let u = channelUUID, joinedSystem else { return }
        m.stopTransmitting(channelUUID: u)
    }

    /// Fired when setting the remote participant fails (the system will not activate the session for it).
    var onRemoteFailed: () -> Void = {}

    func setRemote(_ name: String?) {
        guard let m = manager, let u = channelUUID, joinedSystem else { return }
        let p = name.map { PTParticipant(name: $0, image: nil) }
        Task {
            do {
                try await m.setActiveRemoteParticipant(p, channelUUID: u)
                Self.diag("setActiveRemoteParticipant(\(p == nil ? "nil" : "talker")) ok")
            } catch {
                Self.diag("setActiveRemoteParticipant failed: \(Self.describe(error))")
                if p != nil { self.onRemoteFailed() }
            }
        }
    }

    private var lastServiceStatus: Bool?

    func setServiceStatus(_ ok: Bool) {
        guard let m = manager, let u = channelUUID, joinedSystem, lastServiceStatus != ok else { return }
        lastServiceStatus = ok
        Task {
            do {
                try await m.setServiceStatus(ok ? .ready : .connecting, channelUUID: u)
                Self.diag("serviceStatus \(ok ? "ready" : "connecting")")
            } catch {
                Self.diag("setServiceStatus failed: \(Self.describe(error))")
            }
        }
    }

    /// Error domain + code only (never the user-facing text, which may hold names).
    nonisolated static func describe(_ e: Error) -> String {
        let n = e as NSError
        return "\(n.domain)#\(n.code)"
    }

    /// The radio was tuned to another channel: the Lock Screen / Dynamic Island says which.
    func setChannelName(_ name: String) {
        guard !name.isEmpty, name != outingName else { return }
        outingName = name
        guard let m = manager, let u = channelUUID, joinedSystem else { return }
        Task {
            do {
                try await m.setChannelDescriptor(descriptor(), channelUUID: u)
                Self.diag("channel descriptor updated")
            } catch {
                Self.diag("setChannelDescriptor failed: \(Self.describe(error))")
            }
        }
    }

    private func descriptor() -> PTChannelDescriptor {
        PTChannelDescriptor(name: outingName, image: UIImage(named: "LaunchMark"))
    }

    nonisolated static func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
}

extension PTTSystemRoute: PTChannelManagerDelegate, PTChannelRestorationDelegate {
    nonisolated func channelManager(_ channelManager: PTChannelManager, didJoinChannel channelUUID: UUID, reason: PTChannelJoinReason) {
        Self.diag("didJoinChannel reason=\(reason.rawValue)")
        Task { @MainActor in
            self.channelUUID = channelUUID
            self.joinedSystem = true
            self.lastServiceStatus = nil
            Self.log.notice("[PTT] system channel joined")
        }
    }

    nonisolated func channelManager(_ channelManager: PTChannelManager, didLeaveChannel channelUUID: UUID, reason: PTChannelLeaveReason) {
        Self.diag("didLeaveChannel reason=\(reason.rawValue)")
        Task { @MainActor in
            self.joinedSystem = false
            if self.channelUUID == channelUUID { self.channelUUID = nil }
            self.callbacks.leftChannel()
        }
    }

    nonisolated func channelManager(_ channelManager: PTChannelManager, channelUUID: UUID, didBeginTransmittingFrom source: PTChannelTransmitRequestSource) {
        Self.diag("didBeginTransmitting source=\(source.rawValue)")
        Task { @MainActor in
            /* From our own button we already asked the server; from the Lock Screen / a headset we must. */
            if source != .developerRequest { self.callbacks.systemBeganTransmit() }
        }
    }

    nonisolated func channelManager(_ channelManager: PTChannelManager, channelUUID: UUID, didEndTransmittingFrom source: PTChannelTransmitRequestSource) {
        Self.diag("didEndTransmitting source=\(source.rawValue)")
        Task { @MainActor in self.callbacks.transmitEnded() }
    }

    nonisolated func channelManager(_ channelManager: PTChannelManager, receivedEphemeralPushToken pushToken: Data) {
        let hex = Self.hex(pushToken)
        Self.diag("ephemeral push token (\(pushToken.count) bytes)")
        Task { @MainActor in self.callbacks.token(hex) }
    }

    /// Must return at once (Apple): parse, hand the rest to the main thread.
    nonisolated func incomingPushResult(channelManager: PTChannelManager, channelUUID: UUID, pushPayload: [String: Any]) -> PTPushResult {
        guard let name = pushPayload["activeSpeaker"] as? String, !name.isEmpty else {
            Self.diag("incoming push without activeSpeaker → leaveChannel")
            return .leaveChannel
        }
        Self.diag("incoming push (app \(Thread.isMainThread ? "main" : "bg") thread)")
        let outing = (pushPayload["outing_id"] as? String) ?? channelUUID.uuidString.lowercased()
        Task { @MainActor in self.onWokenByPush(outing, name) }
        return .activeRemoteParticipant(PTParticipant(name: name, image: nil))
    }

    nonisolated func channelManager(_ channelManager: PTChannelManager, didActivate audioSession: AVAudioSession) {
        Self.diag("didActivate audio session (category=\(audioSession.category.rawValue.replacingOccurrences(of: "AVAudioSessionCategory", with: "")))")
        Task { @MainActor in
            /* The system decides whether this is for talking or listening; both callbacks are idempotent. */
            GroupAudioDuck.began(.ptt)
            self.callbacks.transmitReady()
            self.callbacks.playbackReady()
        }
    }

    nonisolated func channelManager(_ channelManager: PTChannelManager, didDeactivate audioSession: AVAudioSession) {
        Self.diag("didDeactivate audio session")
        Task { @MainActor in
            self.callbacks.audioDeactivated()
            GroupAudioDuck.ended(.ptt)
        }
    }

    nonisolated func channelManager(_ channelManager: PTChannelManager, failedToJoinChannel channelUUID: UUID, error: Error) {
        Self.diag("failedToJoinChannel \(Self.describe(error))")
        Task { @MainActor in
            Self.log.notice("[PTT] join failed: \(String(describing: error), privacy: .public)")
            self.joinedSystem = false
        }
    }

    nonisolated func channelManager(_ channelManager: PTChannelManager, failedToBeginTransmittingInChannel channelUUID: UUID, error: Error) {
        Self.diag("failedToBeginTransmitting \(Self.describe(error))")
        Task { @MainActor in self.callbacks.transmitFailed() }
    }

    nonisolated func channelManager(_ channelManager: PTChannelManager, failedToStopTransmittingInChannel channelUUID: UUID, error: Error) {
        Self.diag("failedToStopTransmitting \(Self.describe(error))")
    }

    nonisolated func channelDescriptor(restoredChannelUUID channelUUID: UUID) -> PTChannelDescriptor {
        PTChannelDescriptor(name: "قناة الطلعة", image: nil)
    }
}
#endif
