import Foundation
import MultipeerConnectivity
import UIKit

/// The phone-to-phone link for one outing (MultipeerConnectivity: Bluetooth
/// and peer-to-peer Wi-Fi, no internet needed). It only runs while the owner
/// turns it on — `OutingSession` does so under the same consent as sharing —
/// and it only ever talks to phones that prove they belong to the same outing.
///
/// What leaves this phone: its own latest fix, the latest fixes it heard from
/// other members (relayed, at most 3 hops, with their real age), and members'
/// notes / SOS / «غرّزت» events. All inside AES-GCM under the outing's key.
/// Nothing received here is ever sent to the server.
@MainActor
final class NearbyMesh: NSObject, ObservableObject {
    /// Bonjour: `_sary-mesh._tcp` / `_sary-mesh._udp` (Info.plist NSBonjourServices).
    static let serviceType = "sary-mesh"
    static let sendEveryS = 4.0
    /// A nearby phone sending this many bad frames is disconnected.
    static let maxBadFrames = 5

    @Published private(set) var running = false
    @Published private(set) var nearbyCars = 0
    /// Bumped whenever what we know changed (the screen re-reads `store`).
    @Published private(set) var revision = 0

    private(set) var store: MeshStore
    private var codec: MeshCodec
    private var replay = MeshReplayGuard()
    private var limiter = MeshRateLimiter()
    private var myPeer: MCPeerID?
    private var session: MCSession?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private var advertisedTag: String?
    private var timer: Timer?
    private var badFrames: [String: Int] = [:]
    private var lastSent = 0.0

    /// This phone's own latest fix (nil when it has none it may share).
    var myFix: () -> DeviceFix? = { nil }
    /// Events from other members that are new to this phone.
    var onEvents: ([MeshEvent]) -> Void = { _ in }
    /// «قناة الطلعة» frames from a nearby member (see MeshVoice.swift).
    var onVoice: (MeshVoiceCodec.Message) -> Void = { _ in }
    private var voiceCodec: MeshVoiceCodec
    private var voiceLimiter = MeshVoiceLimiter()

    init(outingId: String, me: String, members: Set<String>, serverKey: String? = nil) {
        store = MeshStore(me: me, members: members)
        let keys = MeshKeys(outingId: outingId, serverKey: serverKey)
        codec = MeshCodec(keys: keys, me: me)
        voiceCodec = MeshVoiceCodec(keys: keys, me: me)
        super.init()
    }

    static func nowMs() -> Double { Date().timeIntervalSince1970 * 1000 }

    /// The cached member list from the latest server picture. Removed members drop out at once.
    func setMembers(_ ids: Set<String>) {
        guard ids != store.members else { return }
        store.members = ids
        store.prune(nowMs: Self.nowMs())
        revision &+= 1
    }

    func setServerKey(_ key: String?, outingId: String) {
        let k = MeshKeys(outingId: outingId, serverKey: key)
        guard k.outingTag != codec.keys.outingTag else { return }
        codec = MeshCodec(keys: k, me: store.me)
        voiceCodec = MeshVoiceCodec(keys: k, me: store.me)
        if running { stop(); start() }
    }

    func overlay(_ v: OutingView) -> (view: OutingView, viaNearby: Set<String>) {
        store.overlay(v)
    }

    // MARK: on / off

    func setRunning(_ on: Bool) {
        if on && !running { start() } else if !on && running { stop() }
    }

    private func start() {
        let peer = MCPeerID(displayName: Self.anonymousName())
        myPeer = peer
        let s = MCSession(peer: peer, securityIdentity: nil, encryptionPreference: .required)
        s.delegate = self
        session = s
        let b = MCNearbyServiceBrowser(peer: peer, serviceType: Self.serviceType)
        b.delegate = self
        browser = b
        b.startBrowsingForPeers()
        restartAdvertiser()
        running = true
        timer = Timer.scheduledTimer(withTimeInterval: Self.sendEveryS, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    /// Stop the radios. With `farewell`, a last frame first (e.g. «أوقفت المشاركة»).
    func stop(farewell: MeshEvent.Kind? = nil) {
        if let k = farewell, running {
            _ = store.addOwn(k, nowMs: Self.nowMs())
            broadcast(force: true)
        }
        timer?.invalidate()
        timer = nil
        advertiser?.stopAdvertisingPeer()
        advertiser = nil
        advertisedTag = nil
        browser?.stopBrowsingForPeers()
        browser = nil
        let s = session
        session = nil
        /* Give a farewell frame a moment to leave before the link drops. */
        DispatchQueue.main.asyncAfter(deadline: .now() + (farewell == nil ? 0 : 0.6)) { s?.disconnect() }
        myPeer = nil
        running = false
        nearbyCars = 0
        badFrames = [:]
    }

    /// Random per start, never the person's name: nothing about who is nearby leaks over Bluetooth.
    private static func anonymousName() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)).lowercased()
    }

    private func restartAdvertiser() {
        guard let peer = myPeer else { return }
        let tag = codec.keys.discoveryTag(nowMs: Self.nowMs())
        guard tag != advertisedTag else { return }
        advertiser?.stopAdvertisingPeer()
        let a = MCNearbyServiceAdvertiser(peer: peer, discoveryInfo: ["t": tag], serviceType: Self.serviceType)
        a.delegate = self
        a.startAdvertisingPeer()
        advertiser = a
        advertisedTag = tag
    }

    // MARK: my events

    func announce(_ k: MeshEvent.Kind, text: String? = nil, sosFix: DeviceFix? = nil) {
        _ = store.addOwn(k, text: text, sosFix: sosFix, nowMs: Self.nowMs())
        revision &+= 1
        if running { broadcast(force: true) }
    }

    func serverClearedSOS(_ u: String) {
        store.serverClearedSOS(u)
        revision &+= 1
    }

    // MARK: loop

    private func tick() {
        guard running else { return }
        restartAdvertiser()
        store.prune(nowMs: Self.nowMs())
        broadcast(force: false)
        refreshCount()
    }

    private func refreshCount() {
        let n = store.directCount(nowMs: Self.nowMs())
        if n != nearbyCars { nearbyCars = n }
    }

    private func broadcast(force: Bool) {
        guard let s = session, !s.connectedPeers.isEmpty else { return }
        let now = Self.nowMs()
        if !force && now - lastSent < Self.sendEveryS * 1000 * 0.8 { return }
        let payload = store.outgoing(myFix: myFix(), nowMs: now)
        guard !payload.pos.isEmpty || !payload.ev.isEmpty, let data = try? codec.seal(payload, nowMs: now) else { return }
        try? s.send(data, toPeers: s.connectedPeers, with: .reliable)
        lastSent = now
    }

    /// Phones of this outing connected directly right now (voice goes one hop only).
    var directPeers: Int { session?.connectedPeers.count ?? 0 }

    /// A walkie-talkie frame to every directly connected member. Audio is sent
    /// unreliably (a late packet is worthless); start/stop reliably.
    @discardableResult
    func sendVoice(_ kind: MeshVoiceCodec.Kind, body: Data) -> Bool {
        guard running, let s = session, !s.connectedPeers.isEmpty,
              let d = try? voiceCodec.seal(kind, body: body, nowMs: Self.nowMs()) else { return false }
        do {
            try s.send(d, toPeers: s.connectedPeers, with: kind == .audio ? .unreliable : .reliable)
            return true
        } catch { return false }
    }

    private func receivedVoice(_ data: Data, key: String, now: Double) {
        guard voiceLimiter.allow(key, nowMs: now) else { return }
        guard let m = try? voiceCodec.open(data, members: store.members, nowMs: now) else { return }
        onVoice(m)
    }

    fileprivate func received(_ data: Data, from peer: MCPeerID) {
        let now = Self.nowMs()
        let key = peer.displayName
        if MeshVoiceCodec.isVoice(data) { return receivedVoice(data, key: key, now: now) }
        guard limiter.allow(key, nowMs: now) else { return }
        do {
            let (from, payload) = try codec.open(data, members: store.members, nowMs: now, replay: &replay)
            let fresh = store.ingest(payload, from: from, nowMs: now)
            badFrames[key] = 0
            revision &+= 1
            refreshCount()
            if !fresh.isEmpty { onEvents(fresh) }
        } catch {
            badFrames[key, default: 0] += 1
            if (badFrames[key] ?? 0) >= Self.maxBadFrames, let s = session {
                /* Not one of us (or broken): cut it off. It can't read anything anyway. */
                s.cancelConnectPeer(peer)
                badFrames[key] = nil
                limiter.forget(key)
            }
            #if DEBUG
            print("[mesh] dropped frame from \(key): \(error)")
            #endif
        }
    }

    fileprivate func found(_ peer: MCPeerID, info: [String: String]?) {
        guard let s = session, let b = browser, let mine = myPeer else { return }
        guard let t = info?["t"], codec.keys.acceptedDiscoveryTags(nowMs: Self.nowMs()).contains(t) else { return }
        guard !s.connectedPeers.contains(peer) else { return }
        /* One side invites (the lower name), so two phones never race two sessions. */
        guard mine.displayName < peer.displayName else { return }
        b.invitePeer(peer, to: s, withContext: Data(codec.keys.discoveryTag(nowMs: Self.nowMs()).utf8), timeout: 15)
    }

    fileprivate func invited(by peer: MCPeerID, context: Data?, reply: @escaping (Bool, MCSession?) -> Void) {
        guard let s = session, let c = context.flatMap({ String(data: $0, encoding: .utf8) }),
              codec.keys.acceptedDiscoveryTags(nowMs: Self.nowMs()).contains(c) else { return reply(false, nil) }
        reply(true, s)
    }

    fileprivate func peerChanged(_ peer: MCPeerID, _ state: MCSessionState) {
        if state == .connected { broadcast(force: true) }
        if state == .notConnected {
            limiter.forget(peer.displayName)
            voiceLimiter.forget(peer.displayName)
        }
        refreshCount()
    }
}

// MARK: - MultipeerConnectivity delegates (called off the main thread)

extension NearbyMesh: MCSessionDelegate, MCNearbyServiceBrowserDelegate, MCNearbyServiceAdvertiserDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor in self.peerChanged(peerID, state) }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        /* Oversized frames are dropped here, before they cross threads. */
        guard data.count <= MeshCodec.maxFrameBytes else { return }
        Task { @MainActor in self.received(data, from: peerID) }
    }

    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {
        stream.close()
    }

    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {
        progress.cancel()
    }

    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {
        if let localURL { try? FileManager.default.removeItem(at: localURL) }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        Task { @MainActor in self.found(peerID, info: info) }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        #if DEBUG
        print("[mesh] browse failed: \(error)")
        #endif
    }

    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        Task { @MainActor in self.invited(by: peerID, context: context, reply: invitationHandler) }
    }

    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        #if DEBUG
        print("[mesh] advertise failed: \(error)")
        #endif
    }
}
