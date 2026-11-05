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
}

struct PTTRouteCallbacks {
    /// The mic may record now (audio session active).
    var transmitReady: () -> Void = {}
    /// The system's own talk button (Lock Screen, headset, CarPlay) began a transmission.
    var systemBeganTransmit: () -> Void = {}
    /// The system ended our transmission (button released there, a call came in…).
    var transmitEnded: () -> Void = {}
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
        try? s.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP])
        try? s.setActive(true)
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

    var callbacks = PTTRouteCallbacks()
    private(set) var manager: PTChannelManager?
    private(set) var channelUUID: UUID?
    private var outingId: String?
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
        } catch {
            Self.log.notice("[PTT] system channel unavailable: \(String(describing: error), privacy: .public)")
        }
    }

    static func uuid(for outingId: String) -> UUID? { UUID(uuidString: outingId) }

    func join(outingId: String, name: String) {
        guard let m = manager, let u = Self.uuid(for: outingId) else { return }
        self.outingId = outingId
        outingName = name.isEmpty ? "قناة الطلعة" : "قناة الطلعة · \(name)"
        if channelUUID == u, joinedSystem { return }
        /* Another outing's channel is still up: leave it first (one channel per system). */
        if let old = channelUUID, old != u { m.leaveChannel(channelUUID: old) }
        channelUUID = u
        m.requestJoinChannel(channelUUID: u, descriptor: descriptor())
    }

    func leave() {
        guard let m = manager, let u = channelUUID else { return }
        m.leaveChannel(channelUUID: u)
    }

    func beginTransmit() {
        guard let m = manager, let u = channelUUID, joinedSystem else { return }
        m.requestBeginTransmitting(channelUUID: u)
    }

    func endTransmit() {
        guard let m = manager, let u = channelUUID, joinedSystem else { return }
        m.stopTransmitting(channelUUID: u)
    }

    func setRemote(_ name: String?) {
        guard let m = manager, let u = channelUUID, joinedSystem else { return }
        let p = name.map { PTParticipant(name: $0, image: nil) }
        Task { try? await m.setActiveRemoteParticipant(p, channelUUID: u) }
    }

    func setServiceStatus(_ ok: Bool) {
        guard let m = manager, let u = channelUUID, joinedSystem else { return }
        Task { try? await m.setServiceStatus(ok ? .ready : .connecting, channelUUID: u) }
    }

    private func descriptor() -> PTChannelDescriptor {
        PTChannelDescriptor(name: outingName, image: UIImage(named: "LaunchMark"))
    }

    nonisolated static func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
}

extension PTTSystemRoute: PTChannelManagerDelegate, PTChannelRestorationDelegate {
    nonisolated func channelManager(_ channelManager: PTChannelManager, didJoinChannel channelUUID: UUID, reason: PTChannelJoinReason) {
        Task { @MainActor in
            self.channelUUID = channelUUID
            self.joinedSystem = true
            Self.log.notice("[PTT] system channel joined")
        }
    }

    nonisolated func channelManager(_ channelManager: PTChannelManager, didLeaveChannel channelUUID: UUID, reason: PTChannelLeaveReason) {
        Task { @MainActor in
            self.joinedSystem = false
            if self.channelUUID == channelUUID { self.channelUUID = nil }
            self.callbacks.leftChannel()
        }
    }

    nonisolated func channelManager(_ channelManager: PTChannelManager, channelUUID: UUID, didBeginTransmittingFrom source: PTChannelTransmitRequestSource) {
        Task { @MainActor in
            /* From our own button we already asked the server; from the Lock Screen / a headset we must. */
            if source != .developerRequest { self.callbacks.systemBeganTransmit() }
        }
    }

    nonisolated func channelManager(_ channelManager: PTChannelManager, channelUUID: UUID, didEndTransmittingFrom source: PTChannelTransmitRequestSource) {
        Task { @MainActor in self.callbacks.transmitEnded() }
    }

    nonisolated func channelManager(_ channelManager: PTChannelManager, receivedEphemeralPushToken pushToken: Data) {
        let hex = Self.hex(pushToken)
        Task { @MainActor in self.callbacks.token(hex) }
    }

    /// Must return at once (Apple): parse, hand the rest to the main thread.
    nonisolated func incomingPushResult(channelManager: PTChannelManager, channelUUID: UUID, pushPayload: [String: Any]) -> PTPushResult {
        guard let name = pushPayload["activeSpeaker"] as? String, !name.isEmpty else { return .leaveChannel }
        let outing = (pushPayload["outing_id"] as? String) ?? channelUUID.uuidString.lowercased()
        Task { @MainActor in self.onWokenByPush(outing, name) }
        return .activeRemoteParticipant(PTParticipant(name: name, image: nil))
    }

    nonisolated func channelManager(_ channelManager: PTChannelManager, didActivate audioSession: AVAudioSession) {
        Task { @MainActor in
            /* The system decides whether this is for talking or listening; both callbacks are idempotent. */
            GroupAudioDuck.began(.ptt)
            self.callbacks.transmitReady()
            self.callbacks.playbackReady()
        }
    }

    nonisolated func channelManager(_ channelManager: PTChannelManager, didDeactivate audioSession: AVAudioSession) {
        Task { @MainActor in
            self.callbacks.audioDeactivated()
            GroupAudioDuck.ended(.ptt)
        }
    }

    nonisolated func channelManager(_ channelManager: PTChannelManager, failedToJoinChannel channelUUID: UUID, error: Error) {
        Task { @MainActor in
            Self.log.notice("[PTT] join failed: \(String(describing: error), privacy: .public)")
            self.joinedSystem = false
        }
    }

    nonisolated func channelManager(_ channelManager: PTChannelManager, failedToBeginTransmittingInChannel channelUUID: UUID, error: Error) {
        Task { @MainActor in self.callbacks.transmitEnded() }
    }

    nonisolated func channelDescriptor(restoredChannelUUID channelUUID: UUID) -> PTChannelDescriptor {
        PTChannelDescriptor(name: "قناة الطلعة", image: nil)
    }
}
#endif
