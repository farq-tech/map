import XCTest
@testable import SaryAlbarq

/// «ترددات»: the wire (lists, kicks, invites, the channel on ptt_* signals), the socket's
/// join / switch frames, the walkie-talkie's channel state, the Arabic labels, and the
/// playout budget (a friend's voice within ~150 ms of its first frame).
final class PTTChannelsTests: XCTestCase {
    private let priv = "9b2f0c1e-7a6d-4c3b-8e2a-5d4c3b2a1f00"

    @MainActor
    private final class JoinedSystemRoute: PTTRoute {
        var callbacks = PTTRouteCallbacks()
        let isSystemChannel = true
        private(set) var didLeave = false
        func join(outingId: String, name: String) {}
        func leave() { didLeave = true }
        func beginTransmit() {}
        func endTransmit() {}
        func setRemote(_ name: String?) {}
        func setChannelName(_ name: String) {}
    }

    // MARK: wire

    func testChannelListDecodes() throws {
        let msg: [String: Any] = [
            "type": "ptt_channels", "current": "3", "can_create": true,
            "channels": [
                ["id": "1", "kind": "public", "name": "تردد ١", "listeners": ["a"], "talker": NSNull()],
                ["id": "3", "kind": "public", "name": "تردد ٣", "listeners": ["a", "b"], "talker": ["user_id": "b", "name": "سعد"]],
                ["id": priv, "kind": "private", "name": "الأمامية", "listeners": [], "talker": NSNull(),
                 "members": ["a", "b"], "created_by": "a", "can_manage": true],
            ],
        ]
        guard case let .list(current, canCreate, list)? = PTTChannelEvent.decode(msg) else { return XCTFail("not a list") }
        XCTAssertEqual(current, "3")
        XCTAssertTrue(canCreate)
        XCTAssertEqual(list.map(\.id), ["1", "3", priv])
        XCTAssertEqual(list[1].talker, .init(userId: "b", name: "سعد"))
        XCTAssertNil(list[0].talker)
        XCTAssertTrue(list[2].isPrivate)
        XCTAssertEqual(list[2].members, ["a", "b"])
        XCTAssertTrue(list[2].canManage)
        XCTAssertFalse(list[0].canManage)
    }

    func testKickAndInviteDecode() {
        XCTAssertEqual(PTTChannelEvent.decode(["type": "ptt_channel_kicked", "channel": priv, "reason": "removed"]), .kicked(channel: priv, reason: "removed"))
        XCTAssertEqual(PTTChannelEvent.decode(["type": "ptt_channel_invite", "channel": priv, "name": "الأمامية", "by": "a"]), .invited(channel: priv, name: "الأمامية", by: "a"))
        XCTAssertNil(PTTChannelEvent.decode(["type": "ptt_channel_kicked"]))
        XCTAssertNil(PTTChannelEvent.decode(["type": "ptt_talker", "user_id": "b", "burst": 3]), "floor signals are not channel events")
    }

    func testSignalsCarryTheirChannelAndNewIdleReasons() {
        XCTAssertEqual(PTTSignal.channel(of: ["type": "ptt_talker", "channel": "3"]), "3")
        XCTAssertEqual(PTTSignal.channel(of: ["type": "ptt_talker", "channel": 4]), "4")
        XCTAssertNil(PTTSignal.channel(of: ["type": "ptt_talker"]), "a server before channels")
        XCTAssertEqual(PTTSignal.decode(["type": "ptt_idle", "user_id": "b", "burst": 2, "reason": "switched"]), .idle(userId: "b", burst: 2, reason: .switched))
        XCTAssertEqual(PTTSignal.decode(["type": "ptt_idle", "user_id": "b", "burst": 2, "reason": "closed"]), .idle(userId: "b", burst: 2, reason: .closed))
        XCTAssertEqual(PTTSignal.decode(["type": "ptt_idle", "user_id": "b", "burst": 2, "reason": "whatever"]), .idle(userId: "b", burst: 2, reason: .released))
    }

    // MARK: labels

    func testArabicLabels() {
        XCTAssertEqual(PTTChannels.publicName("3"), "تردد ٣")
        XCTAssertEqual(PTTChannels.publicList.map(\.name), ["تردد ١", "تردد ٢", "تردد ٣", "تردد ٤", "تردد ٥"])
        XCTAssertEqual(PTTChannels.systemLabel("تردد ٣"), "قناة الطلعة · تردد ٣", "what the Lock Screen shows")
        XCTAssertEqual(PTTChannels.chipLabel(nil), "تردد ١")
        XCTAssertEqual(PTTChannels.inviteText("الأمامية"), "أمير الرحلة دعاك إلى تردد خاص: الأمامية")
        let names = ["a": "فهد", "b": "سعد", "c": "نورة", "d": "ريم"]
        let n: (String) -> String? = { names[$0] }
        var c = PTTChannelInfo(id: "2", kind: .public, name: "تردد ٢")
        XCTAssertEqual(PTTChannels.listenersLine(c, me: "a", name: n), "لا أحد يسمع")
        c.listeners = ["a"]
        XCTAssertEqual(PTTChannels.listenersLine(c, me: "a", name: n), "لا أحد غيرك")
        c.listeners = ["a", "b"]
        XCTAssertEqual(PTTChannels.listenersLine(c, me: "a", name: n), "يسمع: سعد")
        c.listeners = ["a", "b", "c", "d"]
        XCTAssertEqual(PTTChannels.listenersLine(c, me: "a", name: n), "يسمع: سعد، نورة +١")
        XCTAssertTrue(PTTChannels.kickedText("closed", name: "الأمامية").contains("تردد ١"))
        XCTAssertEqual(PTTChannels.errorText(OutingAPIError(code: "leader_only", status: 403)), "التردد الخاص لأمير الرحلة فقط")
    }

    // MARK: the playout budget

    func testFriendsVoiceWithin150msOfItsFirstFrame() {
        let squelch = PTTRadioSynth.duration(.incomingStart)
        XCTAssertGreaterThan(squelch, PTTPlayout.maxVoiceLead, "the squelch is longer than the voice waits for it: they overlap")
        XCTAssertEqual(PTTPlayout.voiceLead(cue: squelch), PTTPlayout.maxVoiceLead)
        XCTAssertEqual(PTTPlayout.voiceLead(cue: nil), 0)
        /* Worst case: the first frame comes together with ptt_talker, then one every 30 ms. */
        for gap in [0.0, 0.01, 0.03, 0.06, 0.2] {
            let d = PTTPlayout.firstVoiceDelay(cue: squelch, talkerToFrame: gap)
            XCTAssertLessThanOrEqual(d, PTTPlayout.budget, "gap \(gap)")
            XCTAssertGreaterThanOrEqual(d, 0.06 - 1e-9, "never before 3 packets (90 ms of cushion) are queued")
        }
        /* Radio sounds off: no lead, the pull clock alone. */
        XCTAssertLessThanOrEqual(PTTPlayout.firstVoiceDelay(cue: nil, talkerToFrame: 0), PTTPlayout.budget)
        /* The talker's pre-roll burst (what they said while waiting for the floor) fills the buffer at once. */
        XCTAssertLessThan(PTTPlayout.firstVoiceDelay(cue: nil, talkerToFrame: 0.005, burstFrames: 8), PTTPlayout.firstVoiceDelay(cue: nil, talkerToFrame: 0.005))
        /* The jitter buffer the engine really uses. */
        let j = PTTJitterBuffer()
        XCTAssertLessThanOrEqual(Double(j.targetDepth) * PTTFrame.packetMs / 1000, 0.12, "≤ 120 ms of cushion")
    }

    func testIncomingSquelchStillOpensWithTheRecording() {
        let s = PTTRadioSynth.samples(.incomingStart)
        XCTAssertLessThanOrEqual(Double(s.count) / PTTRadioSynth.sampleRate, 0.25, "short: squelch + a 40 ms chirp")
        let click = PTTRadioSynth.samples(.channelClick)
        XCTAssertEqual(click.reduce(0) { max($0, abs($1)) }, PTTRadioSynth.peak, accuracy: 0.01)
        XCTAssertLessThanOrEqual(Double(click.count) / PTTRadioSynth.sampleRate, PTTRadioSynth.maxDuration)
        /* The click is up front: most of the first 10 ms is louder than the static after it. */
        let head = click.prefix(160).reduce(0) { max($0, abs($1)) }
        XCTAssertEqual(head, PTTRadioSynth.peak, accuracy: 0.02)
    }

    @MainActor
    func testInAppRouteWaitsForSessionActivationAndReportsDeactivation() async {
        let route = PTTInAppRoute()
        let ready = expectation(description: "speaker is ready only after session activation")
        let stopped = expectation(description: "route reports session deactivation")
        route.callbacks.playbackReady = { ready.fulfill() }
        route.callbacks.audioUnavailable = { XCTFail("simulator audio session should activate") }
        route.callbacks.audioDeactivated = { stopped.fulfill() }

        route.setRemote("سعد")
        await fulfillment(of: [ready], timeout: 5)
        route.leave()
        await fulfillment(of: [stopped], timeout: 5)
    }

    // MARK: floor

    func testSwitchingChannelsEndsWhatWasOnAirQuietly() {
        var f = PTTFloor(me: "me")
        _ = f.receive(.talker(PTTTalker(userId: "b", name: "سعد", burst: 4)), nowMs: 0)
        XCTAssertEqual(f.channelSwitched(), [.stopPlayback])
        XCTAssertEqual(f.state, .idle)
        _ = f.pressDown(nowMs: 0, online: true)
        _ = f.receive(.grant(id: 1, burst: 9, maxMs: 60_000), nowMs: 0)
        XCTAssertEqual(f.channelSwitched(), [.stopCapture, .sendStop], "our transmission on the old channel is over")
        _ = f.pressDown(nowMs: 0, online: true)
        XCTAssertEqual(f.channelSwitched(), [.sendStop])
        XCTAssertEqual(f.channelSwitched(), [])
    }

    // MARK: the socket

    private var sockets: [FakeSocket] = []
    private let clock = FakeScheduler()

    private func channel(scoped: @escaping (PTTSignal, String?) -> Void = { _, _ in }, events: @escaping (PTTChannelEvent) -> Void = { _ in }) -> LiveChannel {
        let ch = LiveChannel(outingId: "o1", token: String(repeating: "t", count: 43), deps: .init(
            makeSocket: { [unowned self] url in let s = FakeSocket(url: url); self.sockets.append(s); return s },
            poll: { _ in throw OutingAPIError(code: "network", status: 0) },
            post: { _, _ in },
            beat: { _, _, _ in },
            scheduler: clock,
            random: { 0.5 }
        ), log: { _ in })
        ch.handlers = .init()
        ch.handlers.onPTTOnChannel = scoped
        ch.handlers.onPTTChannel = events
        return ch
    }

    private func ready(_ s: FakeSocket) {
        s.serverSays(["type": "ready", "snapshot": [
            "outing": ["id": "o1", "name": "x", "status": "active", "owner_id": "u1"],
            "me": ["user_id": "u1", "role": "owner", "sharing": true],
            "members": [], "positions": [], "invite": NSNull(), "server_now": "2026-11-03T10:00:00.000Z",
        ]])
    }

    func testJoinNamesTheChannelAndSwitchesLive() {
        let ch = channel()
        ch.setPTTChannel("3")
        ch.start()
        sockets[0].onOpen()
        ready(sockets[0])
        ch.setPTTJoined(true)
        let join = sockets[0].sent.last { $0["type"] as? String == "ptt_join" }
        XCTAssertEqual(join?["channel"] as? String, "3")
        XCTAssertEqual(join?["channels"] as? Bool, true, "tells the server this build knows «ترددات»")
        ch.setPTTChannel(priv)
        XCTAssertEqual(sockets[0].sent.last?["type"] as? String, "ptt_join_channel")
        XCTAssertEqual(sockets[0].sent.last?["channel"] as? String, priv)
        let n = sockets[0].sent.count
        ch.setPTTChannel(priv)
        XCTAssertEqual(sockets[0].sent.count, n, "same channel: nothing sent")

        /* A reconnect re-joins on the channel we were on. */
        sockets[0].onClose(1006)
        clock.advance(60_000)
        sockets.last!.onOpen()
        ready(sockets.last!)
        let rejoin = sockets.last!.sent.last { $0["type"] as? String == "ptt_join" }
        XCTAssertEqual(rejoin?["channel"] as? String, priv)
    }

    func testMutedSwitchIsRememberedNotSent() {
        let ch = channel()
        ch.start()
        sockets[0].onOpen()
        ready(sockets[0])
        ch.setPTTJoined(false)
        ch.setPTTChannel("2")
        XCTAssertFalse(sockets[0].sent.contains { $0["type"] as? String == "ptt_join_channel" })
        ch.setPTTJoined(true)
        XCTAssertEqual(sockets[0].sent.last?["channel"] as? String, "2")
    }

    func testScopedSignalsAndKickResetsTheChannel() {
        var got: [(PTTSignal, String?)] = []
        var evs: [PTTChannelEvent] = []
        let ch = channel(scoped: { got.append(($0, $1)) }, events: { evs.append($0) })
        ch.setPTTChannel(priv)
        ch.start()
        sockets[0].onOpen()
        ready(sockets[0])
        ch.setPTTJoined(true)
        sockets[0].serverSays(["type": "ptt_talker", "user_id": "b", "name": "سعد", "burst": 4, "channel": priv])
        XCTAssertEqual(got.last?.1, priv)
        XCTAssertEqual(got.last?.0, .talker(PTTTalker(userId: "b", name: "سعد", burst: 4)))
        sockets[0].serverSays(["type": "ptt_channel_kicked", "channel": priv, "reason": "removed"])
        XCTAssertEqual(evs, [.kicked(channel: priv, reason: "removed")])
        XCTAssertEqual(ch.pttChannel, "1", "the server put us on ١; a reconnect must not ask for the private one again")
    }

    // MARK: the walkie-talkie

    @MainActor
    private func walkie(_ d: UserDefaults) -> OutingWalkieTalkie {
        d.set(false, forKey: PTTRadioSounds.enabledKey)
        return OutingWalkieTalkie(outingId: "o-\(UUID().uuidString)", me: "me", tokenBackend: nil, route: PTTInAppRoute(), audio: PTTAudioEngine(testTone: true), defaults: d, diag: { _, _ in })
    }

    @MainActor
    func testWalkieSwitchPersistsAndDropsOtherChannels() throws {
        let d = try XCTUnwrap(UserDefaults(suiteName: "ptt-ch-\(UUID().uuidString)"))
        let w = walkie(d)
        XCTAssertEqual(w.channelId, "1")
        w.receiveChannel(.list(current: "1", canCreate: false, channels: PTTChannels.publicList))
        XCTAssertTrue(w.showsChannels)
        w.switchChannel("3")
        XCTAssertEqual(w.channelId, "3")
        XCTAssertEqual(OutingWalkieTalkie.savedChannel(w.outingId, defaults: d), "3", "kept per outing")
        XCTAssertEqual(w.systemChannelName, "قناة الطلعة · تردد ٣")
        w.switchChannel(priv)
        XCTAssertEqual(w.channelId, "3", "not a channel we know (no invitation): ignored")

        /* A friend on another channel (in flight while we switched): not ours. */
        w.receive(.talker(PTTTalker(userId: "b", name: "سعد", burst: 4)), channel: "1")
        XCTAssertEqual(w.floor.state, .idle)
        w.receive(.talker(PTTTalker(userId: "b", name: "سعد", burst: 5)), channel: "3")
        XCTAssertEqual(w.floor.state, .listening(PTTTalker(userId: "b", name: "سعد", burst: 5)))
        w.switchChannel("4")
        XCTAssertEqual(w.floor.state, .idle, "tuning away ends it for us")

        let w2 = OutingWalkieTalkie(outingId: w.outingId, me: "me", tokenBackend: nil, route: PTTInAppRoute(), audio: PTTAudioEngine(testTone: true), defaults: d, diag: { _, _ in })
        XCTAssertEqual(w2.channelId, "4", "restored next time the outing opens")
        OutingWalkieTalkie.forgetAll(defaults: d)
        XCTAssertEqual(OutingWalkieTalkie.savedChannel(w.outingId, defaults: d), "1")
    }

    /// Today's production server (before the channels deploy): no channel on any signal, no list.
    @MainActor
    func testOldServerEveryoneOnOneChannelNoChannelUI() throws {
        let d = try XCTUnwrap(UserDefaults(suiteName: "ptt-ch-\(UUID().uuidString)"))
        d.set("3", forKey: OutingWalkieTalkie.channelKeyPrefix + "o-old")
        d.set(false, forKey: PTTRadioSounds.enabledKey)
        let w = OutingWalkieTalkie(outingId: "o-old", me: "me", tokenBackend: nil, route: PTTInAppRoute(), audio: PTTAudioEngine(testTone: true), defaults: d, diag: { _, _ in })
        XCTAssertFalse(w.showsChannels, "no chip until the server says it has channels")
        XCTAssertEqual(w.systemChannelName, "قناة الطلعة", "the Lock Screen does not claim a channel")
        w.receive(.talker(PTTTalker(userId: "b", name: "سعد", burst: 2)), channel: nil)
        XCTAssertEqual(w.floor.state, .listening(PTTTalker(userId: "b", name: "سعد", burst: 2)), "heard, whatever channel was saved")
        XCTAssertFalse(w.showsChannels)
        w.receive(.idle(userId: "b", burst: 2, reason: .released), channel: "1")
        XCTAssertTrue(w.showsChannels, "a channel-tagged signal: the server has channels")
    }

    @MainActor
    func testWalkieInviteKickAndClosedList() throws {
        let d = try XCTUnwrap(UserDefaults(suiteName: "ptt-ch-\(UUID().uuidString)"))
        let w = walkie(d)
        let list: [PTTChannelInfo] = PTTChannels.publicList + [PTTChannelInfo(id: priv, kind: .private, name: "الأمامية", members: ["a", "me"])]
        w.receiveChannel(.invited(channel: priv, name: "الأمامية", by: "a"))
        XCTAssertEqual(w.pendingInvite?.id, priv)
        XCTAssertEqual(w.notice, "أمير الرحلة دعاك إلى تردد خاص: الأمامية")
        w.receiveChannel(.list(current: "1", canCreate: false, channels: list))
        XCTAssertFalse(w.canCreatePrivate)
        w.switchChannel(priv)
        XCTAssertEqual(w.channelId, priv)
        XCTAssertNil(w.pendingInvite, "switching to it is seeing it")
        XCTAssertEqual(w.systemChannelName, "قناة الطلعة · الأمامية")

        w.receiveChannel(.kicked(channel: priv, reason: "removed"))
        XCTAssertEqual(w.channelId, "1")
        XCTAssertTrue(w.notice?.contains("أُخرجت من «الأمامية»") == true)

        /* Back on it, then it disappears from the list (closed while the socket was down). */
        w.switchChannel(priv)
        w.receiveChannel(.list(current: nil, canCreate: false, channels: PTTChannels.publicList))
        XCTAssertEqual(w.channelId, "1")
    }

    @MainActor
    func testDemoLeaderCreatesManagesAndClosesAPrivateChannel() async throws {
        let d = try XCTUnwrap(UserDefaults(suiteName: "ptt-ch-\(UUID().uuidString)"))
        let w = walkie(d)
        w.demoLeader = { true }
        w.attach(channel: nil, mesh: nil)
        XCTAssertTrue(w.canCreatePrivate)
        XCTAssertEqual(w.channels.first { $0.id == "1" }?.listeners, ["me"])
        let c = try await w.createPrivate(name: "الأمامية", members: ["a", "b"])
        XCTAssertEqual(c.members, ["me", "a", "b"], "the leader is always in it")
        w.switchChannel(c.id)
        XCTAssertEqual(w.currentChannel?.name, "الأمامية")
        try await w.updatePrivate(c.id, name: "الأمامية ٢", add: ["c"], remove: ["a"])
        XCTAssertEqual(w.currentChannel?.members.sorted(), ["b", "c", "me"])
        XCTAssertEqual(w.currentChannel?.name, "الأمامية ٢")
        try await w.closePrivate(c.id)
        XCTAssertEqual(w.channelId, "1")
        XCTAssertFalse(w.channels.contains { $0.isPrivate })
        w.detach(leftOuting: false)
    }

    @MainActor
    func testClosingOutingScreenKeepsSystemPushToTalkChannelUntilLeavingOuting() {
        let d = UserDefaults(suiteName: "ptt-detach-\(UUID().uuidString)")!
        let stillMemberRoute = JoinedSystemRoute()
        let stillMember = OutingWalkieTalkie(outingId: "o-\(UUID().uuidString)", me: "me", tokenBackend: nil,
                                             route: stillMemberRoute, audio: PTTAudioEngine(testTone: true), defaults: d)
        stillMember.detach(leftOuting: false)
        XCTAssertFalse(stillMemberRoute.didLeave, "closing the map/session must keep background voice-note wake-ups")

        let leavingRoute = JoinedSystemRoute()
        let leaving = OutingWalkieTalkie(outingId: "o-\(UUID().uuidString)", me: "me", tokenBackend: nil,
                                         route: leavingRoute, audio: PTTAudioEngine(testTone: true), defaults: d)
        leaving.detach(leftOuting: true)
        XCTAssertTrue(leavingRoute.didLeave, "a departed or ended outing must release its PTT channel")
    }
}
