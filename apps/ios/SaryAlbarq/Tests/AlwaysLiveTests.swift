import XCTest
@testable import SaryAlbarq

/// «من لحظة القبول لين تخلص الطلعة يكون مباشر» — the offline queue, the presence reason and
/// the hints, on their own (the session-level tests are in BackgroundShareTests).
final class AlwaysLiveTests: XCTestCase {
    private let t0 = 1_762_423_200_000.0 // 2026-11-06 10:00 UTC

    private func fix(_ i: Int, atMs: Double, moveM: Double = 0) -> DeviceFix {
        DeviceFix(lat: 24.7113 + moveM / 111_000 * Double(i), lng: 46.6744, accuracy: 6, heading: nil, speed: 0, atMs: atMs)
    }

    // MARK: OfflineFixQueue

    func testQueueThinsAParkedCarButKeepsMovement() {
        var q = OfflineFixQueue()
        XCTAssertTrue(q.enqueue(fix(0, atMs: t0), mode: .balanced))
        XCTAssertFalse(q.enqueue(fix(0, atMs: t0 + 5_000), mode: .balanced), "parked, 5 s later: nothing new")
        XCTAssertTrue(q.enqueue(fix(1, atMs: t0 + 6_000, moveM: 100), mode: .balanced), "moved 100 m: kept")
        XCTAssertTrue(q.enqueue(fix(1, atMs: t0 + 30_000, moveM: 100), mode: .balanced), "20 s passed: kept")
        XCTAssertFalse(q.enqueue(fix(1, atMs: t0 + 10_000), mode: .balanced), "out of order: refused")
        XCTAssertEqual(q.count, 3)
    }

    func testQueueIsCappedOldestFirstOut() {
        var q = OfflineFixQueue()
        for i in 0..<(OfflineFixQueue.cap + 20) { q.enqueue(fix(i, atMs: t0 + Double(i) * 30_000), mode: .saver) }
        XCTAssertEqual(q.count, OfflineFixQueue.cap)
        XCTAssertEqual(q.items.first?.atMs, t0 + 20 * 30_000, "the 20 oldest went")
    }

    func testBatchIsOldestFirstWithTrueAgesAndAckRemovesOnlyWhatWasSent() {
        var q = OfflineFixQueue()
        for i in 0..<5 { q.enqueue(fix(i, atMs: t0 + Double(i) * 60_000), mode: .balanced) }
        let now = t0 + 10 * 60_000
        let b = try! XCTUnwrap(q.batch(nowMs: now))
        XCTAssertEqual(b.fixes.count, 5)
        XCTAssertEqual(b.fixes.first?.age_ms, 10 * 60_000)
        XCTAssertEqual(b.fixes.last?.age_ms, 6 * 60_000)
        /* A fix queued while the batch was in flight survives the ack. */
        q.enqueue(fix(9, atMs: t0 + 9 * 60_000), mode: .balanced)
        q.ack(upToMs: b.upToMs)
        XCTAssertEqual(q.count, 1)
    }

    func testQueueDropsWhatTheServerWouldRefuseAndPersists() {
        var q = OfflineFixQueue()
        q.enqueue(fix(0, atMs: t0), mode: .balanced)
        q.enqueue(fix(1, atMs: t0 + 7 * 3_600_000), mode: .balanced)
        q.prune(nowMs: t0 + 7 * 3_600_000 + 1_000)
        XCTAssertEqual(q.count, 1, "older than the 6 h backfill window: gone")
        let d = UserDefaults(suiteName: "q-\(UUID().uuidString)")!
        q.save(user: "u1", outing: "o1", defaults: d)
        XCTAssertEqual(OfflineFixQueue.load(user: "u1", outing: "o1", defaults: d), q)
        XCTAssertTrue(OfflineFixQueue.load(user: "u2", outing: "o1", defaults: d).isEmpty, "per identity: never inherited")
        q.clear()
        q.save(user: "u1", outing: "o1", defaults: d)
        XCTAssertTrue(OfflineFixQueue.load(user: "u1", outing: "o1", defaults: d).isEmpty)
    }

    // MARK: presence

    func testPresenceEventDecodesAndUpdatesTheMember() throws {
        let e = try XCTUnwrap(LiveEvent.decode(["type": "member_presence", "user_id": "u2", "state": "stale", "reason": "when_in_use", "last_fix_at": "2026-11-06T10:00:00.000Z"]))
        guard case let .memberPresence(uid, p) = e else { return XCTFail("\(e)") }
        XCTAssertEqual(uid, "u2")
        XCTAssertEqual(p.state, .stale)
        XCTAssertEqual(p.reasonKind, .whenInUse)
        XCTAssertNil(LiveEvent.decode(["type": "member_presence", "user_id": "u2", "state": "weird"]))
    }

    func testSilentFrameCarriesTheReason() throws {
        let e = try XCTUnwrap(LiveEvent.decode(["type": "member_silent", "user_id": "u2", "since": "2026-11-06T10:00:00.000Z", "level": 10, "reason": "web"]))
        guard case let .memberSilent(info) = e else { return XCTFail() }
        XCTAssertEqual(info.reasonKind, .web)
    }

    func testReasonLinesAreSpecificNeverAVagueCut() {
        let since = Date(timeIntervalSince1970: t0 / 1000)
        let now = since.addingTimeInterval(5 * 60)
        XCTAssertEqual(SilenceText.badge(since: since, now: now, reason: .locationOff), "جواله مقفل الموقع — آخر موقع قبل ٥ د")
        XCTAssertEqual(SilenceText.badge(since: since, now: now, reason: .noNetwork), "ما فيه شبكة — آخر موقع قبل ٥ د")
        XCTAssertEqual(SilenceText.badge(since: since, now: now, reason: .hidden), "مخفي موقعه")
        for r in PresenceReason.allCases {
            XCTAssertFalse(SilenceText.badge(since: since, now: now, reason: r).contains("انقطع"), "\(r)")
            XCTAssertFalse(r.text.isEmpty)
        }
        XCTAssertEqual(SilenceText.title(name: "عبيص", since: since, now: now, reason: .web), "عبيص: يتابع من المتصفح")
        /* Server and app speak the same words (apps/api/lib/outings/presence.js REASON_TEXT). */
        XCTAssertEqual(PresenceReason(rawValue: "no_gps")?.text, "ما فيه إشارة GPS")
    }

    func testHintFollowsScreenAndPermission() {
        XCTAssertEqual(PresenceHint.forState(foreground: true, canLocate: true, always: false), .foreground)
        XCTAssertEqual(PresenceHint.forState(foreground: false, canLocate: true, always: false), .backgroundWhenInUse)
        XCTAssertEqual(PresenceHint.forState(foreground: false, canLocate: true, always: true), .backgroundAlways)
        XCTAssertEqual(PresenceHint.forState(foreground: true, canLocate: false, always: true), .locationOff)
    }

    func testPresenterShowsTheReasonOnlyWhileNotLive() throws {
        let now = Date()
        var snap: [String: Any] = [
            "outing": ["id": "o1", "name": "x", "status": "active", "owner_id": "u1"],
            "me": ["user_id": "u1", "role": "owner", "sharing": true],
            "members": [
                ["user_id": "u1", "display_name": "احمد", "role": "owner", "sharing": true, "joined_at": "2026-11-06T10:00:00.000Z"],
                ["user_id": "u2", "display_name": "عبيص", "role": "member", "sharing": true, "joined_at": "2026-11-06T10:00:00.000Z",
                 "presence": ["state": "offline", "reason": "web"]],
            ],
            "positions": [], "server_now": ISODate.string(now),
        ]
        var v = OutingView(try JSONDecoder().decode(OutingSnapshot.self, from: JSONSerialization.data(withJSONObject: snap)), deviceNow: now)
        XCTAssertEqual(LiveOutingPresenter.presenceReason(v.members["u2"]!, in: v, now: now), .web)
        XCTAssertNil(LiveOutingPresenter.presenceReason(v.members["u1"]!, in: v, now: now), "never for me")
        /* A fresh fix here wins over the server's last sweep. */
        v.apply(.memberPresence(userId: "u2", presence: MemberPresence(state: .stale, reason: "no_network")))
        XCTAssertEqual(LiveOutingPresenter.presenceReason(v.members["u2"]!, in: v, now: now), .noNetwork)
        v.apply(.position(Position(user_id: "u2", lat: 24.7113, lng: 46.6744, accuracy: 5, heading: nil, speed: 0, mode: nil,
                                   recorded_at: ISODate.string(now), received_at: ISODate.string(now))))
        XCTAssertNil(LiveOutingPresenter.presenceReason(v.members["u2"]!, in: v, now: now))
        snap["outing"] = ["id": "o1", "name": "x", "status": "ended", "owner_id": "u1"]
        let ended = OutingView(try JSONDecoder().decode(OutingSnapshot.self, from: JSONSerialization.data(withJSONObject: snap)), deviceNow: now)
        XCTAssertNil(LiveOutingPresenter.presenceReason(ended.members["u2"]!, in: ended, now: now))
    }

    // MARK: cadence

    func testLowPowerNeverSendsSlowerThanTheLiveWindow() {
        for m in [BackgroundCadence.Motion.fast, .moving, .parked] {
            XCTAssertLessThanOrEqual(BackgroundCadence.intervalMs(m, lowPower: true), BackgroundCadence.intervalMs(m, lowPower: false))
        }
        XCTAssertLessThan(BackgroundCadence.intervalMs(.parked, lowPower: true), Policy.liveParkedMs, "was 80 s (field, build 21): flicker")
        XCTAssertLessThan(BackgroundCadence.intervalMs(.moving, lowPower: true), Policy.liveMovingMs)
    }
}
