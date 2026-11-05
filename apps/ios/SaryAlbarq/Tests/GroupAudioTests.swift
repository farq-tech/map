import XCTest
@testable import SaryAlbarq

/// «إذاعة الطلعة» — sync math, drift correction, ducking, permissions, wire.
@MainActor
final class GroupAudioTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private var quranItem: GroupAudioItem { QuranReciter.all[0].item(surah: 1) }

    // MARK: sync math

    func testFilePositionRunsOnTheServerClock() {
        var s = GroupAudioState(item: quranItem, playing: true, position_s: 10, at: ISODate.string(t0))
        XCTAssertEqual(s.position(atServer: t0.addingTimeInterval(5)), 15, accuracy: 0.001)
        XCTAssertEqual(s.position(atServer: t0.addingTimeInterval(-5)), 10, accuracy: 0.001, "a clock going back never rewinds")
        /* Device 2 s behind the server: offset +2000 ms. */
        XCTAssertEqual(s.position(deviceNow: t0.addingTimeInterval(3), clockOffsetMs: 2000), 15, accuracy: 0.001)
        s.playing = false
        XCTAssertEqual(s.position(atServer: t0.addingTimeInterval(60)), 10, "paused: frozen")
        s.playing = true
        s.item?.duration_s = 12
        XCTAssertEqual(s.position(atServer: t0.addingTimeInterval(60)), 12, "clamped to the end")
    }

    func testLiveRadioHasNoPosition() {
        let s = GroupAudioState(item: GroupAudioCatalog.bundled[0].item, playing: true, position_s: 99, at: ISODate.string(t0))
        XCTAssertEqual(s.position(atServer: t0.addingTimeInterval(600)), 0)
    }

    func testClockOffsetUsesTheRoundTripMidpoint() {
        /* Sent at 0, answered at 0.4 s; the server said 10.2 → its clock is 10 s ahead. */
        let off = GroupAudioSync.clockOffsetMs(serverNow: t0.addingTimeInterval(10.2), sentAt: t0, receivedAt: t0.addingTimeInterval(0.4))
        XCTAssertEqual(off, 10_000, accuracy: 0.5)
    }

    // MARK: drift correction (±300 ms)

    func testDriftInsideToleranceDoesNothing() {
        XCTAssertEqual(GroupAudioSync.plan(expected: 100, actual: 100.25, rate: 1), .none)
        XCTAssertEqual(GroupAudioSync.plan(expected: 100, actual: 99.71, rate: 1), .none)
        XCTAssertEqual(GroupAudioSync.plan(expected: 100, actual: 100.1, rate: 1.05), .rate(1), "back inside: normal speed again")
    }

    func testSmallDriftNudgesTheRate() {
        XCTAssertEqual(GroupAudioSync.plan(expected: 100, actual: 101, rate: 1), .rate(0.95), "ahead → slow down")
        XCTAssertEqual(GroupAudioSync.plan(expected: 100, actual: 98.5, rate: 1), .rate(1.05), "behind → speed up")
        XCTAssertEqual(GroupAudioSync.plan(expected: 100, actual: 98.5, rate: 1.05), .none, "already nudging")
        XCTAssertEqual(GroupAudioSync.drift(expected: 100, actual: 101), 1)
    }

    func testLargeDriftSeeks() {
        XCTAssertEqual(GroupAudioSync.plan(expected: 100, actual: 90, rate: 1), .seek(100))
        XCTAssertEqual(GroupAudioSync.plan(expected: 100, actual: 104, rate: 0.95), .seek(100))
        XCTAssertEqual(GroupAudioSync.plan(expected: -1, actual: 10, rate: 1), .seek(0))
    }

    func testNudgingConvergesInsideTolerance() {
        /* Simulate: 2 s behind, 1 s ticks, follow the plan. */
        var actual = 98.0, expected = 100.0, rate: Float = 1
        for _ in 0..<60 {
            switch GroupAudioSync.plan(expected: expected, actual: actual, rate: rate) {
            case .none: break
            case let .rate(r): rate = r
            case let .seek(p): actual = p
            }
            actual += Double(rate)
            expected += 1
        }
        XCTAssertLessThanOrEqual(abs(actual - expected), GroupAudioSync.tolerance + 0.06)
        XCTAssertEqual(rate, 1, "settles at normal speed")
    }

    // MARK: ducking state machine

    func testNavigationVoiceDucksAndRestores() {
        var d = GroupAudioDucking()
        XCTAssertEqual(d.handle(.navBegan), [.volume(0.2)])
        XCTAssertTrue(d.shouldPlay, "still playing, quieter")
        XCTAssertEqual(d.handle(.navEnded), [.volume(1)])
    }

    func testPushToTalkPausesThenResumes() {
        var d = GroupAudioDucking()
        XCTAssertEqual(d.handle(.pttBegan), [.pause])
        XCTAssertFalse(d.shouldPlay)
        XCTAssertEqual(d.handle(.navBegan), [], "already paused: nothing to duck audibly")
        XCTAssertEqual(d.handle(.navEnded), [])
        XCTAssertEqual(d.handle(.pttEnded), [.resume, .volume(1)])
    }

    func testPTTEndingDuringNavVoiceResumesDucked() {
        var d = GroupAudioDucking()
        d.handle(.pttBegan)
        d.handle(.navBegan)
        XCTAssertEqual(d.handle(.pttEnded), [.resume, .volume(0.2)])
    }

    func testInterruptionResumesOnlyWhenIOSSaysSo() {
        var d = GroupAudioDucking()
        XCTAssertEqual(d.handle(.interruptionBegan), [.pause])
        XCTAssertEqual(d.handle(.interruptionEnded(shouldResume: true)), [.resume, .volume(1)])
        d.handle(.interruptionBegan)
        XCTAssertEqual(d.handle(.interruptionEnded(shouldResume: false)), [], "stays quiet")
        XCTAssertTrue(d.muted, "until the person unmutes")
        XCTAssertEqual(d.handle(.unmute), [.resume, .volume(1)])
    }

    func testLocalMute() {
        var d = GroupAudioDucking()
        XCTAssertEqual(d.handle(.mute), [.pause])
        XCTAssertEqual(d.handle(.pttBegan), [])
        XCTAssertEqual(d.handle(.pttEnded), [], "a PTT ending never unmutes")
        XCTAssertEqual(d.handle(.unmute), [.resume, .volume(1)])
    }

    // MARK: permissions

    func testPermissions() {
        let idle = GroupAudioState.idle()
        XCTAssertTrue(GroupAudioPermissions.canControl(idle, iLead: true))
        XCTAssertFalse(GroupAudioPermissions.canControl(idle, iLead: false))
        var open = idle
        open.allow_all = true
        XCTAssertTrue(GroupAudioPermissions.canControl(open, iLead: false), "«الكل يقدر يشغّل»")
        XCTAssertFalse(GroupAudioPermissions.canSetAllowAll(iLead: false))
        XCTAssertFalse(GroupAudioPermissions.canQueue(idle), "nothing to queue after")
        open.item = quranItem
        XCTAssertTrue(GroupAudioPermissions.canQueue(open))
        open.queue = Array(repeating: quranItem, count: 20)
        XCTAssertFalse(GroupAudioPermissions.canQueue(open))
    }

    func testLocalBackendEnforcesTheServerRules() async throws {
        let member = GroupAudioLocalBackend(me: "b", iLead: false)
        do {
            _ = try await member.send(.play(GroupAudioCatalog.bundled[0].item))
            XCTFail("a member cannot start")
        } catch let e as GroupAudioBackendError {
            XCTAssertEqual(e, .server(code: "not_allowed", status: 403))
        }
        do {
            _ = try await member.send(.allowAll(true))
            XCTFail()
        } catch let e as GroupAudioBackendError { XCTAssertEqual(e, .server(code: "leader_only", status: 403)) }

        let leader = GroupAudioLocalBackend(me: "a", iLead: true)
        let r = try await leader.send(.play(GroupAudioCatalog.bundled[0].item))
        XCTAssertEqual(r.state.item?.id, "sba-quran")
        XCTAssertEqual(r.state.by, "a")
        do {
            _ = try await leader.send(.seek(10))
            XCTFail("live has no seek")
        } catch let e as GroupAudioBackendError { XCTAssertEqual(e, .server(code: "live_stream", status: 409)) }
        _ = try await leader.send(.queue(quranItem))
        let n = try await leader.send(.next)
        XCTAssertEqual(n.state.item?.source, .quran)
        let s = try await leader.send(.next)
        XCTAssertNil(s.state.item, "empty queue: stops")
    }

    // MARK: wire

    func testRadioGoesByIdOnly() {
        let w = GroupAudioCommand.play(GroupAudioCatalog.bundled[0].item).body
        XCTAssertEqual(w["action"] as? String, "play_item")
        let item = w["item"] as? [String: Any]
        XCTAssertEqual(item?["source"] as? String, "radio")
        XCTAssertEqual(item?["id"] as? String, "sba-quran")
        XCTAssertNil(item?["url"], "the server fills the URL from its catalog")
        XCTAssertEqual(GroupAudioCommand.allowAll(true).body["value"] as? Bool, true)
        XCTAssertEqual(GroupAudioCommand.seek(12.34567).body["position_s"] as? Double, 12.346)
    }

    func testStreamURLs() {
        XCTAssertEqual(GroupAudioCatalog.bundled[0].item.streamURL?.host, "live.kwikmotion.com")
        XCTAssertNil(GroupAudioItem(source: .radio, id: "x", title: "x", url: "http://insecure.example/x").streamURL, "https only")
        XCTAssertEqual(GroupAudioItem(source: .audius, id: "1AXEE", title: "t").streamURL?.absoluteString,
                       "https://api.audius.co/v1/tracks/1AXEE/stream?app_name=SaryAlbarq")
        XCTAssertNil(GroupAudioItem(source: .audius, id: "../x", title: "t").streamURL)
        XCTAssertEqual(quranItem.url, "https://cdn.mp3quran.net/audio/abdulrahman-sudais/r1/001.mp3")
        XCTAssertEqual(quranItem.title, "سورة الفاتحة")
    }

    func testDecodeServerState() throws {
        let raw: [String: Any] = [
            "allow_all": true, "playing": true, "position_s": 0, "seq": 3, "by": "u1", "at": "2026-11-05T10:00:00.000Z", "queue": [],
            "item": ["source": "radio", "id": "mbc-fm", "title": "MBC FM", "subtitle": "x", "url": "https://radio-mbcfm.mbc.net/radio-mbcfm_1.m3u8", "live": true, "duration_s": NSNull()],
        ]
        let s = try XCTUnwrap(GroupAudioEvents.decodeState(raw))
        XCTAssertEqual(s.item?.id, "mbc-fm")
        XCTAssertTrue(s.allow_all)
        XCTAssertEqual(s.seq, 3)
        XCTAssertNil(GroupAudioEvents.decodeState(NSNull()))
        XCTAssertEqual(GroupAudioEvents.decodeState(["at": "2026-11-05T10:00:00.000Z", "item": NSNull()])?.isIdle, true)
    }

    func testCatalogAndSurahs() {
        XCTAssertEqual(QuranSurahs.names.count, 114)
        XCTAssertEqual(QuranSurahs.name(114), "الناس")
        XCTAssertEqual(GroupAudioCatalog.bundled.first?.name, "إذاعة القرآن الكريم")
        XCTAssertEqual(Set(GroupAudioCatalog.bundled.map(\.id)).count, GroupAudioCatalog.bundled.count)
        XCTAssertTrue(GroupAudioCatalog.bundled.allSatisfy { $0.url.hasPrefix("https://") })
        let json = #"{"ok":true,"stations":[{"id":"a","name":"A","subtitle":"","group":"fm","url":"http://x","homepage":""},{"id":"b","name":"B","subtitle":"","group":"quran","url":"https://y","homepage":""}]}"#
        XCTAssertEqual(GroupAudioCatalog.decode(Data(json.utf8))?.map(\.id), ["b"], "http stations dropped")
        /* QA build 15: the server's catalog wins; the app's copy only when it cannot be reached. */
        let server = GroupAudioCatalog.decode(Data(json.utf8))
        XCTAssertEqual(GroupAudioCatalog.resolve(server: server, shared: true).stations.map(\.id), ["b"])
        XCTAssertFalse(GroupAudioCatalog.resolve(server: server, shared: true).offline)
        XCTAssertEqual(GroupAudioCatalog.resolve(server: nil, shared: true).stations, GroupAudioCatalog.bundled, "offline fallback")
        XCTAssertTrue(GroupAudioCatalog.resolve(server: nil, shared: true).offline)
        XCTAssertFalse(GroupAudioCatalog.resolve(server: nil, shared: false).offline, "a local-only radio uses the app's list")
    }

    func testAudiusOnlyStreamableTracks() {
        let json = #"{"data":[{"id":"1AXEE","title":"Oud","duration":337,"user":{"name":"Andros"},"is_streamable":true},{"id":"zz","title":"Locked","is_streamable":false},{"id":"a/b","title":"Bad"}]}"#
        let t = AudiusAPI.decodeSearch(Data(json.utf8))
        XCTAssertEqual(t.map(\.id), ["1AXEE"])
        XCTAssertEqual(t.first?.item.subtitle, "Andros")
        XCTAssertEqual(t.first?.item.duration_s, 337)
    }

    // MARK: the center (stub engine)

    private final class NotDeployedBackend: GroupAudioBackend {
        let isShared = true
        func fetch() async throws -> GroupAudioReply { throw GroupAudioBackendError.notDeployed }
        func send(_ c: GroupAudioCommand) async throws -> GroupAudioReply { throw GroupAudioBackendError.notDeployed }
    }

    func testOlderServerFallsBackToLocalOnlyWithoutErrors() async {
        let c = GroupAudioCenter(outingId: "o", myUserId: "b", backend: NotDeployedBackend(), iLead: { false }, names: { [:] }, clockOffset: { 0 }, engine: StubGroupAudioEngine())
        await c.refresh()
        XCTAssertEqual(c.availability, .localOnly)
        XCTAssertTrue(c.canControl, "the person can still listen on their own")
        await c.playStation(GroupAudioCatalog.bundled[0])
        XCTAssertEqual(c.nowItem?.id, "sba-quran")
        XCTAssertNil(c.errorText, "no error shown")
        c.shutDown()
    }

    func testMemberMutesLocallyAndStaleFramesAreIgnored() {
        let c = GroupAudioCenter(outingId: "o", myUserId: "b", backend: GroupAudioLocalBackend(me: "b", iLead: false, shared: true),
                                 iLead: { false }, names: { ["a": "أبو فهد"] }, clockOffset: { 0 }, engine: StubGroupAudioEngine())
        let s = GroupAudioState(item: GroupAudioCatalog.bundled[0].item, playing: true, by: "a", seq: 5, at: ISODate.string(Date()))
        c.apply(s)
        XCTAssertTrue(c.showsNowPlaying)
        XCTAssertFalse(c.canControl)
        XCTAssertEqual(c.name(of: "a"), "أبو فهد")
        c.mute()
        XCTAssertTrue(c.muted)
        XCTAssertTrue(c.showsNowPlaying, "muted still shows what plays")
        var old = s
        old.seq = 4
        old.item = nil
        c.apply(old)
        XCTAssertEqual(c.nowItem?.id, "sba-quran", "an older frame does not stop it")
        c.leave()
        XCTAssertFalse(c.showsNowPlaying)
        var newer = s
        newer.seq = 6
        newer.item = GroupAudioCatalog.bundled[8].item
        c.apply(newer)
        XCTAssertTrue(c.showsNowPlaying, "something new shows again")
        c.shutDown()
    }
}
