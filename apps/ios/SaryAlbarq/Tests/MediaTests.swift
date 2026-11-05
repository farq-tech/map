import XCTest
@testable import SaryAlbarq

/// «يوتيوب»: link parsing, sync math / drift, permissions, the one-player state
/// machine, driver safety, the demo backend's rules and the share inbox.
final class MediaTests: XCTestCase {
    private let id = "dQw4w9WgXcQ"

    // MARK: links

    func testParsesEveryYouTubeLinkShape() {
        let ok = [
            "https://youtu.be/\(id)",
            "https://youtu.be/\(id)?si=AbCdEf123",
            "youtu.be/\(id)",
            "https://www.youtube.com/watch?v=\(id)",
            "https://youtube.com/watch?v=\(id)&list=PL123&index=2",
            "http://m.youtube.com/watch?feature=share&v=\(id)",
            "https://music.youtube.com/watch?v=\(id)&feature=share",
            "https://www.youtube.com/shorts/\(id)",
            "https://youtube.com/shorts/\(id)?feature=share",
            "https://www.youtube.com/embed/\(id)",
            "https://www.youtube.com/live/\(id)?si=x",
            "https://www.youtube-nocookie.com/embed/\(id)",
            "شوفوا هذا 😂 https://youtu.be/\(id) يا شباب",
            "«https://www.youtube.com/watch?v=\(id)»",
            "Check this out\nhttps://youtube.com/shorts/\(id)\n",
        ]
        for s in ok { XCTAssertEqual(YouTubeLink.parse(s)?.videoId, id, s) }
    }

    func testStartTimes() {
        XCTAssertEqual(YouTubeLink.parse("https://youtu.be/\(id)?t=90")?.startSeconds, 90)
        XCTAssertEqual(YouTubeLink.parse("https://www.youtube.com/watch?v=\(id)&t=1m30s")?.startSeconds, 90)
        XCTAssertEqual(YouTubeLink.parse("https://www.youtube.com/watch?v=\(id)&t=1h2m3s")?.startSeconds, 3723)
        XCTAssertEqual(YouTubeLink.parse("https://www.youtube.com/embed/\(id)?start=42")?.startSeconds, 42)
        XCTAssertNil(YouTubeLink.parse("https://youtu.be/\(id)?t=abc")?.startSeconds)
        XCTAssertNil(YouTubeLink.parse("https://youtu.be/\(id)")?.startSeconds)
    }

    func testRejectsAnythingElse() {
        let bad = [
            "", "   ", "مرحبا", id, // a bare id is not a link
            "https://youtu.be/", "https://youtu.be/short",
            "https://youtu.be/\(id)x", // 12 chars
            "https://www.youtube.com/watch?v=abc",
            "https://www.youtube.com/watch", "https://www.youtube.com/channel/UC1234567890",
            "https://www.youtube.com/@someone", "https://www.youtube.com/playlist?list=PL123",
            "https://evil.com/watch?v=\(id)", "https://youtube.com.evil.com/watch?v=\(id)",
            "https://notyoutube.com/watch?v=\(id)", "ftp://youtu.be/\(id)",
            "javascript:alert(1)//youtu.be/\(id)",
            "https://vimeo.com/123456",
            "https://youtu.be/dQw4w9WgX!Q",
        ]
        for s in bad { XCTAssertNil(YouTubeLink.parse(s), s) }
    }

    func testVideoIdShape() {
        XCTAssertTrue(YouTubeLink.isVideoId("a-b_c-d_e-f"))
        XCTAssertFalse(YouTubeLink.isVideoId("a-b_c-d_e-"))
        XCTAssertFalse(YouTubeLink.isVideoId("a b_c-d_e-f"))
        XCTAssertEqual(YouTubeLink(videoId: id).watchURL.absoluteString, "https://www.youtube.com/watch?v=\(id)")
    }

    // MARK: sync math

    private func state(pos: Double = 10, playing: Bool = true, rate: Double = 1, at: Date, controller: String = "u1", queue: [String] = []) -> SharedMediaState {
        SharedMediaState(video_id: id, title: "x", controller_user_id: controller, position_s: pos, playing: playing, rate: rate, queue: queue, at: ISODate.string(at))
    }

    func testPositionFromServerClock() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(state(at: t0).position(atServer: t0.addingTimeInterval(5)), 15, accuracy: 0.001)
        XCTAssertEqual(state(rate: 2, at: t0).position(atServer: t0.addingTimeInterval(5)), 20, accuracy: 0.001)
        XCTAssertEqual(state(rate: 0.5, at: t0).position(atServer: t0.addingTimeInterval(4)), 12, accuracy: 0.001)
        XCTAssertEqual(state(playing: false, at: t0).position(atServer: t0.addingTimeInterval(60)), 10, "paused: frozen")
        XCTAssertEqual(state(at: t0).position(atServer: t0.addingTimeInterval(-3)), 10, "never rewinds")
        /* Device clock 3 s behind the server: offset +3000 ms. */
        XCTAssertEqual(state(at: t0).position(deviceNow: t0.addingTimeInterval(2), clockOffsetMs: 3000), 15, accuracy: 0.001)
    }

    func testDecodesServerShape() throws {
        let json = #"{"video_id":"dQw4w9WgXcQ","title":"أغنية","controller_user_id":"u1","position_s":12.5,"playing":true,"rate":1.25,"queue":["aaaaaaaaaaa"],"updated_at":"2026-11-04T10:00:00.000Z","at":"2026-11-04T10:00:01.000Z"}"#
        let s = try JSONDecoder().decode(SharedMediaState.self, from: Data(json.utf8))
        XCTAssertEqual(s.rate, 1.25)
        XCTAssertEqual(s.queue, ["aaaaaaaaaaa"])
        XCTAssertNil(MediaEvents.decodeState(NSNull()), "null = idle")
        XCTAssertNil(MediaEvents.decodeState(nil))
        XCTAssertEqual(MediaEvents.decodeState(try JSONSerialization.jsonObject(with: Data(json.utf8)))?.video_id, id)
    }

    func testDriftPlan() {
        let t0 = Date()
        let s = state(pos: 100, at: t0)
        let p = { (pos: Double, playing: Bool) in MediaSync.PlayerReading(videoId: self.id, position: pos, playing: playing, rate: 1) }
        XCTAssertEqual(MediaSync.plan(target: s, expected: 100, player: p(101.9, true)), [], "within 2 s: leave it alone")
        XCTAssertEqual(MediaSync.plan(target: s, expected: 100, player: p(98.1, true)), [])
        XCTAssertEqual(MediaSync.plan(target: s, expected: 100, player: p(102.5, true)), [.seek(100)], "ahead > 2 s")
        XCTAssertEqual(MediaSync.plan(target: s, expected: 100, player: p(90, true)), [.seek(100)], "behind > 2 s")
        XCTAssertEqual(MediaSync.plan(target: s, expected: 100, player: p(100, false)), [.play])
        XCTAssertEqual(MediaSync.plan(target: state(pos: 100, playing: false, at: t0), expected: 100, player: p(100.5, true)), [.pause])
        XCTAssertEqual(MediaSync.plan(target: state(pos: 100, rate: 1.5, at: t0), expected: 100, player: p(100, true)), [.rate(1.5)])
        XCTAssertEqual(MediaSync.plan(target: s, expected: 100, player: .init(videoId: "bbbbbbbbbbb", position: 3, playing: true, rate: 1)),
                       [.load(videoId: id, start: 100, play: true)], "another video: load at the shared position")
        XCTAssertEqual(MediaSync.plan(target: s, expected: 100, player: .init(videoId: nil, position: 0, playing: false, rate: 1)),
                       [.load(videoId: id, start: 100, play: true)])
        XCTAssertEqual(MediaSync.drift(expected: 100, actual: 103), 3)
    }

    // MARK: permissions

    func testPermissions() {
        let s = state(at: Date(), controller: "saad")
        XCTAssertTrue(MediaPermissions.canStart(nil))
        XCTAssertFalse(MediaPermissions.canStart(s))
        XCTAssertTrue(MediaPermissions.canControl(s, me: "saad", iLead: false), "the controller")
        XCTAssertTrue(MediaPermissions.canControl(s, me: "owner", iLead: true), "owner / co-leader")
        XCTAssertFalse(MediaPermissions.canControl(s, me: "fahad", iLead: false), "a plain member")
        XCTAssertFalse(MediaPermissions.canControl(nil, me: "saad", iLead: true), "nothing to control")
        XCTAssertTrue(MediaPermissions.canQueue(s), "any member suggests")
        XCTAssertFalse(MediaPermissions.canQueue(state(at: Date(), queue: Array(repeating: id, count: 20))), "≤ 20")
        XCTAssertFalse(MediaPermissions.canQueue(nil))
        XCTAssertTrue(MediaPermissions.canTakeover(s, me: "owner", iLead: true))
        XCTAssertFalse(MediaPermissions.canTakeover(s, me: "saad", iLead: true), "already in control")
        XCTAssertFalse(MediaPermissions.canTakeover(s, me: "fahad", iLead: false))
    }

    // MARK: one player at a time

    func testStateMachine() {
        var c = MediaCoordinator()
        XCTAssertNil(c.active)
        XCTAssertEqual(c.handle(.playPrivate), [.startPrivate])
        XCTAssertEqual(c.active, .mine)
        /* Joining the outing's channel pauses mine. */
        XCTAssertEqual(c.handle(.joinShared), [.pausePlayer, .followShared])
        XCTAssertEqual(c.active, .outing)
        XCTAssertTrue(c.joinedShared)
        XCTAssertTrue(c.follows)
        /* Playing mine while joined takes me out of the outing's channel. */
        XCTAssertEqual(c.handle(.playPrivate), [.pausePlayer, .startPrivate])
        XCTAssertFalse(c.joinedShared)
        XCTAssertEqual(c.active, .mine)
        XCTAssertEqual(c.handle(.leaveShared), [], "not joined")
        XCTAssertEqual(c.handle(.joinShared), [.pausePlayer, .followShared])
        XCTAssertEqual(c.handle(.leaveShared), [.unloadPlayer])
        XCTAssertNil(c.active)
    }

    func testBackgroundCarPlayAndSharedEnd() {
        var c = MediaCoordinator()
        XCTAssertEqual(c.handle(.background), [], "nothing playing")
        c.handle(.joinShared)
        XCTAssertEqual(c.handle(.background), [.pausePlayer])
        XCTAssertFalse(c.follows, "held: no correcting while off screen")
        XCTAssertEqual(c.handle(.resume), [.followShared])
        XCTAssertTrue(c.follows)
        XCTAssertEqual(c.handle(.carPlay), [.pausePlayer])
        XCTAssertEqual(c.handle(.sharedEnded), [.unloadPlayer])
        XCTAssertFalse(c.joinedShared)
        XCTAssertEqual(c.handle(.resume), [], "held but nothing to follow")
        c.handle(.playPrivate)
        c.handle(.background)
        XCTAssertEqual(c.handle(.resume), [], "mine stays paused until I press play")
        XCTAssertEqual(c.handle(.sharedEnded), [], "not in the outing's channel")
        XCTAssertEqual(c.handle(.stopPrivate), [.unloadPlayer])
    }

    // MARK: driver safety

    func testDriveGate() {
        XCTAssertFalse(DriveGate.isMoving(speedMps: 4.1), "14.8 km/h")
        XCTAssertTrue(DriveGate.isMoving(speedMps: 4.2), "15.1 km/h")
        XCTAssertFalse(DriveGate.isMoving(speedMps: nil))
        XCTAssertFalse(DriveGate.isMoving(speedMps: -1), "unknown speed")
        XCTAssertEqual(DriveGate.presentation(driveMode: true, speedMps: 20, passengerConfirmed: false), .compact)
        XCTAssertEqual(DriveGate.presentation(driveMode: true, speedMps: 20, passengerConfirmed: true), .full, "«أنا راكب»")
        XCTAssertEqual(DriveGate.presentation(driveMode: true, speedMps: 2, passengerConfirmed: false), .full, "parked")
        XCTAssertEqual(DriveGate.presentation(driveMode: false, speedMps: 30, passengerConfirmed: false), .full, "not driving")
        XCTAssertGreaterThanOrEqual(DriveGate.minPlayerSide, 200, "YouTube's minimum player size")
    }

    func testTimeFormatUsesArabicDigits() {
        XCTAssertEqual(MediaFormat.time(65), "١:٠٥")
        XCTAssertEqual(MediaFormat.time(3723.9), "١:٠٢:٠٣")
        XCTAssertEqual(MediaFormat.time(-4), "٠:٠٠")
    }

    // MARK: actions on the wire

    func testActionBodies() {
        XCTAssertEqual(MediaAction.load(id, title: String(repeating: "ا", count: 150), at: 3.14159).body["title"] as? String, String(repeating: "ا", count: 100))
        XCTAssertEqual(MediaAction.load(id, title: "", at: 3.14159).body["position_s"] as? Double, 3.142)
        XCTAssertEqual(MediaAction.seek(-5).body["position_s"] as? Double, 0)
        XCTAssertEqual(MediaAction.next.body["action"] as? String, "next")
        XCTAssertEqual(MediaAction.queue(id).body["video_id"] as? String, id)
        XCTAssertNil(MediaAction.pause().body["position_s"])
    }

    func testNotDeployedErrorText() {
        XCTAssertEqual(MediaBackendError.notDeployed.arabic, "قناة الطلعة غير متاحة بعد.")
        XCTAssertTrue(MediaBackendError.server(code: "not_controller", status: 403).arabic.contains("يتحكم"))
    }

    // MARK: demo backend follows the server's rules

    @MainActor
    func testDemoBackendRules() async throws {
        let owner = MediaDemoBackend(me: "owner", iLead: true)
        do { _ = try await owner.send(.play()); XCTFail("idle") } catch let e as MediaBackendError { XCTAssertEqual(e, .server(code: "media_idle", status: 409)) }
        let s = try await owner.send(.load(id, title: "t"))
        XCTAssertEqual(s?.controller_user_id, "owner")
        let q = try await owner.send(.queue("aaaaaaaaaaa"))
        XCTAssertEqual(q?.queue, ["aaaaaaaaaaa"])
        let n = try await owner.send(.next)
        XCTAssertEqual(n?.video_id, "aaaaaaaaaaa")
        let stopped = try await owner.send(.next)
        XCTAssertNil(stopped, "empty queue: stops")

        let member = MediaDemoBackend(me: "fahad", iLead: false, seeded: SharedMediaState(video_id: id, controller_user_id: "saad", at: ISODate.string(Date())))
        do { _ = try await member.send(.pause()); XCTFail("not the controller") } catch let e as MediaBackendError { XCTAssertEqual(e, .server(code: "not_controller", status: 403)) }
        do { _ = try await member.takeover(); XCTFail("not a leader") } catch let e as MediaBackendError { XCTAssertEqual(e, .server(code: "leader_only", status: 403)) }
        let mq = try await member.send(.queue("bbbbbbbbbbb"))
        XCTAssertEqual(mq?.queue, ["bbbbbbbbbbb"], "any member may suggest")
    }

    // MARK: share extension hand-off

    func testShareInbox() {
        let d = UserDefaults(suiteName: "media-tests-\(UUID().uuidString)")!
        let t0 = Date()
        XCTAssertNil(MediaShareInbox.take(from: d))
        MediaShareInbox.put(YouTubeLink(videoId: id, startSeconds: 30), now: t0, in: d)
        XCTAssertEqual(MediaShareInbox.take(now: t0.addingTimeInterval(5), from: d), YouTubeLink(videoId: id, startSeconds: 30))
        XCTAssertNil(MediaShareInbox.take(now: t0.addingTimeInterval(6), from: d), "taken once")
        MediaShareInbox.put(YouTubeLink(videoId: id), now: t0, in: d)
        XCTAssertNil(MediaShareInbox.take(now: t0.addingTimeInterval(3601), from: d), "stale after an hour")
    }
}
