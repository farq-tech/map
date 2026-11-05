import CryptoKit
import XCTest
@testable import SaryAlbarq

/// The phone-to-phone link: keys, frames, replay, relay hops, dedup, and how
/// what it hears shows over the server's picture (never live when old).
final class NearbyMeshTests: XCTestCase {
    private let outing = "6f1c2a9e-3b7d-4c55-9e21-0a8b7c6d5e4f"
    private let me = "11111111-1111-4111-8111-111111111111"
    private let a = "22222222-2222-4222-8222-222222222222"
    private let b = "33333333-3333-4333-8333-333333333333"
    private let c = "44444444-4444-4444-8444-444444444444"
    private let outsider = "99999999-9999-4999-8999-999999999999"
    private let t0 = 1_793_793_600_000.0 // 2026-11-04T12:00:00Z
    private var members: Set<String> { [me, a, b, c] }

    private func codec(_ who: String, outingId: String? = nil, key: String? = nil) -> MeshCodec {
        MeshCodec(keys: MeshKeys(outingId: outingId ?? outing, serverKey: key), me: who)
    }

    private func fix(_ u: String, at: Double, age: Double = 0, hops: Int = 0, lat: Double = 24.7, speed: Double? = 0) -> MeshFix {
        MeshFix(u: u, lat: lat, lng: 46.7, acc: 8, hdg: 90, spd: speed, at: at, age: age, hops: hops)
    }

    // MARK: keys

    func testKeysAreDeterministicPerOutingAndDomainSeparated() {
        let k1 = MeshKeys(outingId: outing), k2 = MeshKeys(outingId: outing.uppercased())
        XCTAssertEqual(k1.outingTag, k2.outingTag, "both members derive the same key from the cached outing id")
        XCTAssertEqual(k1.source, .interim)
        XCTAssertNotEqual(k1.outingTag, MeshKeys(outingId: "aaaaaaaa-0000-4000-8000-000000000000").outingTag)
        XCTAssertNotEqual(k1.enc.withUnsafeBytes { Data($0) }, k1.disc.withUnsafeBytes { Data($0) })
        XCTAssertNotEqual(k1.memberKey(a).withUnsafeBytes { Data($0) }, k1.memberKey(b).withUnsafeBytes { Data($0) })
        XCTAssertFalse(k1.outingTag.contains(outing.prefix(8)), "the public tag never carries the outing id")
    }

    func testServerKeyWinsOverInterim() {
        let raw = Data((0..<32).map { UInt8($0) }).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let k = MeshKeys(outingId: outing, serverKey: raw)
        XCTAssertEqual(k.source, .server)
        XCTAssertNotEqual(k.outingTag, MeshKeys(outingId: outing).outingTag)
        XCTAssertEqual(MeshKeys(outingId: outing, serverKey: "short").source, .interim, "a malformed key never weakens to garbage")
    }

    func testDiscoveryTagRotatesAndAcceptsNeighbourWindows() {
        let k = MeshKeys(outingId: outing)
        let now = t0
        let later = now + MeshKeys.discoveryWindowMs
        XCTAssertNotEqual(k.discoveryTag(nowMs: now), k.discoveryTag(nowMs: later))
        XCTAssertTrue(k.acceptedDiscoveryTags(nowMs: later).contains(k.discoveryTag(nowMs: now)))
        XCTAssertFalse(k.acceptedDiscoveryTags(nowMs: now + 5 * MeshKeys.discoveryWindowMs).contains(k.discoveryTag(nowMs: now)))
        XCTAssertFalse(MeshKeys(outingId: "aaaaaaaa-0000-4000-8000-000000000000").acceptedDiscoveryTags(nowMs: now).contains(k.discoveryTag(nowMs: now)))
    }

    // MARK: frames

    func testSealOpenRoundTrip() throws {
        var guardA = MeshReplayGuard()
        let p = MeshPayload(pos: [fix(me, at: t0 - 2_000, age: 2_000)])
        let frame = try codec(me).seal(p, nowMs: t0)
        let (from, got) = try codec(a).open(frame, members: members, nowMs: t0 + 50, replay: &guardA)
        XCTAssertEqual(from, me)
        XCTAssertEqual(got, p)
        XCTAssertFalse(String(decoding: frame, as: UTF8.self).contains("24.7"), "coordinates never travel in clear")
    }

    func testNonMembersAndOtherOutingsAreRefused() throws {
        var g = MeshReplayGuard()
        let p = MeshPayload(pos: [fix(outsider, at: t0)])
        /* An outsider who knows the outing id still is not on the member list. */
        XCTAssertThrowsError(try codec(a).open(try codec(outsider).seal(p, nowMs: t0), members: members, nowMs: t0, replay: &g)) {
            XCTAssertEqual($0 as? MeshReject, .notMember)
        }
        XCTAssertThrowsError(try codec(a).open(try codec(b, outingId: "aaaaaaaa-0000-4000-8000-000000000000").seal(p, nowMs: t0), members: members, nowMs: t0, replay: &g)) {
            XCTAssertEqual($0 as? MeshReject, .otherOuting)
        }
        /* Same tag, wrong key (e.g. the server rotated it): authentication fails. */
        let raw = Data(repeating: 7, count: 32).base64EncodedString()
        var forged = try JSONDecoder().decode(MeshEnvelope.self, from: try codec(b, key: raw).seal(p, nowMs: t0))
        forged.o = MeshKeys(outingId: outing).outingTag
        XCTAssertThrowsError(try codec(a).open(try JSONEncoder().encode(forged), members: members, nowMs: t0, replay: &g)) {
            XCTAssertEqual($0 as? MeshReject, .badAuth)
        }
    }

    func testTamperingIsDetected() throws {
        var g = MeshReplayGuard()
        let frame = try codec(b).seal(MeshPayload(pos: [fix(b, at: t0)]), nowMs: t0)
        var e = try JSONDecoder().decode(MeshEnvelope.self, from: frame)
        /* Claim to be someone else: the member tag no longer matches. */
        var spoof = e
        spoof.f = c
        XCTAssertThrowsError(try codec(a).open(try JSONEncoder().encode(spoof), members: members, nowMs: t0, replay: &g)) { XCTAssertEqual($0 as? MeshReject, .badAuth) }
        /* Flip a ciphertext byte. */
        var box = Data(base64Encoded: e.c)!
        box[box.count / 2] ^= 0x01
        e.c = box.base64EncodedString()
        XCTAssertThrowsError(try codec(a).open(try JSONEncoder().encode(e), members: members, nowMs: t0, replay: &g)) { XCTAssertEqual($0 as? MeshReject, .badAuth) }
        /* Too big is dropped before decoding. */
        XCTAssertThrowsError(try codec(a).open(Data(repeating: 0x20, count: MeshCodec.maxFrameBytes + 1), members: members, nowMs: t0, replay: &g)) { XCTAssertEqual($0 as? MeshReject, .tooLarge) }
        XCTAssertThrowsError(try codec(a).open(Data("{}".utf8), members: members, nowMs: t0, replay: &g)) { XCTAssertEqual($0 as? MeshReject, .malformed) }
    }

    func testOversizedPayloadIsRefused() throws {
        var g = MeshReplayGuard()
        let many = MeshPayload(pos: (0..<(MeshPayload.maxFixes + 1)).map { _ in fix(b, at: t0) })
        XCTAssertThrowsError(try codec(a).open(try codec(b).seal(many, nowMs: t0), members: members, nowMs: t0, replay: &g)) { XCTAssertEqual($0 as? MeshReject, .badPayload) }
        let long = MeshPayload(ev: [MeshEvent(id: "x", u: b, k: .note, text: String(repeating: "ا", count: 81), at: t0, age: 0, hops: 0)])
        XCTAssertThrowsError(try codec(a).open(try codec(b).seal(long, nowMs: t0), members: members, nowMs: t0, replay: &g)) { XCTAssertEqual($0 as? MeshReject, .badPayload) }
    }

    // MARK: replay

    func testReplayAndOldFramesAreRejected() throws {
        var g = MeshReplayGuard()
        let frame = try codec(b).seal(MeshPayload(pos: [fix(b, at: t0)]), nowMs: t0)
        _ = try codec(a).open(frame, members: members, nowMs: t0, replay: &g)
        XCTAssertThrowsError(try codec(a).open(frame, members: members, nowMs: t0 + 1_000, replay: &g)) { XCTAssertEqual($0 as? MeshReject, .replay) }
        /* A frame captured long ago and played back. */
        var g2 = MeshReplayGuard()
        XCTAssertThrowsError(try codec(a).open(frame, members: members, nowMs: t0 + MeshReplayGuard.windowMs + 1, replay: &g2)) { XCTAssertEqual($0 as? MeshReject, .tooOld) }
        XCTAssertThrowsError(try codec(a).open(try codec(b).seal(MeshPayload(), nowMs: t0 + MeshReplayGuard.windowMs + 5_000), members: members, nowMs: t0, replay: &g2)) {
            XCTAssertEqual($0 as? MeshReject, .inFuture)
        }
        /* An older frame from the same sender, after a newer one (new id, old time). */
        var g3 = MeshReplayGuard()
        _ = try codec(a).open(try codec(b).seal(MeshPayload(), nowMs: t0 + 60_000), members: members, nowMs: t0 + 60_000, replay: &g3)
        XCTAssertThrowsError(try codec(a).open(try codec(b).seal(MeshPayload(), nowMs: t0), members: members, nowMs: t0 + 60_000, replay: &g3)) { XCTAssertEqual($0 as? MeshReject, .replay) }
    }

    func testForgedFrameDoesNotPoisonReplayGuard() throws {
        var g = MeshReplayGuard()
        let good = try codec(b).seal(MeshPayload(pos: [fix(b, at: t0)]), nowMs: t0)
        var e = try JSONDecoder().decode(MeshEnvelope.self, from: good)
        let realMac = e.m
        e.m = Data(repeating: 0, count: 32).base64EncodedString()
        XCTAssertThrowsError(try codec(a).open(try JSONEncoder().encode(e), members: members, nowMs: t0, replay: &g))
        e.m = realMac
        XCTAssertNoThrow(try codec(a).open(try JSONEncoder().encode(e), members: members, nowMs: t0, replay: &g), "the real frame still gets through")
    }

    func testRateLimit() {
        var r = MeshRateLimiter()
        let allowed = (0..<20).filter { _ in r.allow("p", nowMs: t0) }.count
        XCTAssertEqual(allowed, Int(MeshRateLimiter.burst))
        XCTAssertTrue(r.allow("p", nowMs: t0 + 1_100), "refills at about one a second")
        XCTAssertTrue(r.allow("other", nowMs: t0), "per peer")
    }

    // MARK: relay hops

    func testHopRules() {
        XCTAssertTrue(MeshStore.hopsValid(subject: b, from: b, hops: 0))
        XCTAssertFalse(MeshStore.hopsValid(subject: c, from: b, hops: 0), "nobody can claim a direct fix for someone else")
        XCTAssertFalse(MeshStore.hopsValid(subject: b, from: b, hops: 1))
        XCTAssertTrue(MeshStore.hopsValid(subject: c, from: b, hops: 3))
        XCTAssertFalse(MeshStore.hopsValid(subject: c, from: b, hops: 4))
    }

    func testRelayAddsHopKeepsTimeAndStopsAtThree() {
        var s = MeshStore(me: me, members: members)
        s.ingest(MeshPayload(pos: [fix(b, at: t0 - 5_000, age: 5_000)]), from: b, nowMs: t0)
        s.ingest(MeshPayload(pos: [fix(c, at: t0 - 9_000, age: 9_000, hops: 3)]), from: b, nowMs: t0)
        let out = s.outgoing(myFix: DeviceFix(lat: 24.71, lng: 46.71, accuracy: 5, heading: nil, speed: 0, atMs: t0 - 1_000), nowMs: t0 + 2_000)
        XCTAssertEqual(out.pos.first?.u, me)
        XCTAssertEqual(out.pos.first?.hops, 0)
        XCTAssertEqual(out.pos.first?.age ?? 0, 3_000, accuracy: 1)
        let relayed = out.pos.first { $0.u == b }
        XCTAssertEqual(relayed?.hops, 1)
        XCTAssertEqual(relayed?.at, t0 - 5_000, "the original timestamp travels unchanged")
        XCTAssertEqual(relayed?.age ?? 0, 7_000, accuracy: 1, "age keeps growing with each hop")
        XCTAssertNil(out.pos.first { $0.u == c }, "a 3-hop fix is shown here but never passed on")
        XCTAssertNotNil(s.fixes[c])
    }

    func testNewerWinsAndOldPositionsExpire() {
        var s = MeshStore(me: me, members: members)
        s.ingest(MeshPayload(pos: [fix(c, at: t0 - 1_000, age: 1_000, hops: 2, lat: 24.8)]), from: b, nowMs: t0)
        s.ingest(MeshPayload(pos: [fix(c, at: t0 - 20_000, age: 20_000, hops: 1, lat: 24.9)]), from: a, nowMs: t0)
        XCTAssertEqual(s.fixes[c]?.fix.lat, 24.8, "an older fix of the same person never replaces a newer one")
        s.ingest(MeshPayload(pos: [fix(c, at: t0 - 1_000, age: 1_000, hops: 1, lat: 24.8)]), from: a, nowMs: t0)
        XCTAssertEqual(s.fixes[c]?.fix.hops, 1, "same fix, shorter path")
        s.ingest(MeshPayload(pos: [fix(b, at: t0 - MeshStore.maxFixAgeMs - 1, age: MeshStore.maxFixAgeMs + 1)]), from: b, nowMs: t0)
        XCTAssertNil(s.fixes[b], "older than 30 min: dropped")
        s.ingest(MeshPayload(pos: [fix(me, at: t0, hops: 1)]), from: b, nowMs: t0)
        XCTAssertNil(s.fixes[me], "my own position never comes back to me")
        s.ingest(MeshPayload(pos: [fix(outsider, at: t0, hops: 1)]), from: b, nowMs: t0)
        XCTAssertNil(s.fixes[outsider], "never a non-member's position, even relayed by a member")
        s.prune(nowMs: t0 + MeshStore.maxFixAgeMs + 2_000)
        XCTAssertTrue(s.fixes.isEmpty)
    }

    func testRemovedMemberIsForgotten() {
        var s = MeshStore(me: me, members: members)
        s.ingest(MeshPayload(pos: [fix(b, at: t0)]), from: b, nowMs: t0)
        s.members.remove(b)
        s.prune(nowMs: t0)
        XCTAssertNil(s.fixes[b])
        XCTAssertTrue(s.ingest(MeshPayload(ev: [MeshEvent(id: "e", u: b, k: .sos, at: t0, age: 0, hops: 0)]), from: b, nowMs: t0).isEmpty)
    }

    // MARK: events & dedup

    func testEventsDedupAndRelay() {
        var s = MeshStore(me: me, members: members)
        let e = MeshEvent(id: "ev-1", u: c, k: .stuck, text: "غرّزت عند الطعس", at: t0 - 3_000, age: 3_000, hops: 1)
        XCTAssertEqual(s.ingest(MeshPayload(ev: [e]), from: b, nowMs: t0).count, 1)
        XCTAssertEqual(s.ingest(MeshPayload(ev: [e]), from: a, nowMs: t0 + 500).count, 0, "the same event from another path is not new")
        let out = s.outgoing(myFix: nil, nowMs: t0 + 1_000)
        XCTAssertEqual(out.ev.first?.hops, 2)
        XCTAssertEqual(out.ev.first?.age ?? 0, 4_000, accuracy: 1)
        var mine = s
        let own = mine.addOwn(.note, text: "بوقف عند المحطة", nowMs: t0)
        XCTAssertTrue(mine.outgoing(myFix: nil, nowMs: t0).ev.contains { $0.id == own.id && $0.hops == 0 })
        XCTAssertTrue(mine.ingest(MeshPayload(ev: [MeshEvent(id: own.id, u: me, k: .note, text: "x", at: t0, age: 0, hops: 1)]), from: b, nowMs: t0).isEmpty, "my own event echoed back is not news")
    }

    func testStopRemovesTheirPositionAndRefusesOlderOnes() {
        var s = MeshStore(me: me, members: members)
        s.ingest(MeshPayload(pos: [fix(b, at: t0 - 2_000, age: 2_000)]), from: b, nowMs: t0)
        s.ingest(MeshPayload(ev: [MeshEvent(id: "stop", u: b, k: .stop, at: t0 - 1_000, age: 1_000, hops: 0)]), from: b, nowMs: t0)
        XCTAssertNil(s.fixes[b], "they stopped sharing: nobody nearby keeps showing them")
        s.ingest(MeshPayload(pos: [fix(b, at: t0 - 2_000, age: 3_000, hops: 1)]), from: a, nowMs: t0 + 1_000)
        XCTAssertNil(s.fixes[b], "a relay of a fix from before the stop is refused")
    }

    // MARK: over the server's picture (staleness)

    private func view(positions: [Position] = [], members ms: [Member]? = nil, status: OutingStatus = .active) -> OutingView {
        func m(_ id: String, _ name: String) -> Member {
            Member(user_id: id, display_name: name, avatar: nil, phone: nil, role: id == me ? "owner" : "member", sharing: true,
                   joined_at: "2026-11-04T10:00:00.000Z", online: true, away: false, last_seen_at: ISODate.string(Date(timeIntervalSince1970: (t0 - 600_000) / 1000)))
        }
        let now = Date(timeIntervalSince1970: t0 / 1000)
        return OutingView(OutingSnapshot(
            outing: OutingInfo(id: outing, name: "طلعة", status: status, owner_id: me),
            me: SnapshotMe(user_id: me, role: "owner", sharing: true),
            members: ms ?? [m(me, "أنا"), m(a, "فهد"), m(b, "سعد"), m(c, "ريم")],
            positions: positions, invite: nil, server_now: ISODate.string(now)
        ), deviceNow: now)
    }

    func testOverlayShowsRealAgeAndOldRelayIsNeverLive() {
        var s = MeshStore(me: me, members: members)
        s.ingest(MeshPayload(pos: [fix(b, at: 1, age: 3_000, speed: 12)]), from: b, nowMs: t0)
        s.ingest(MeshPayload(pos: [fix(c, at: 1, age: 4 * 60_000, hops: 2, speed: 12)]), from: b, nowMs: t0)
        let now = Date(timeIntervalSince1970: t0 / 1000)
        let (v, via) = s.overlay(view(), deviceNow: now)
        XCTAssertEqual(via, [b, c])
        XCTAssertEqual(v.freshness(of: b, deviceNow: now), .live, "a 3 s old fix straight from their phone is live")
        XCTAssertNotEqual(v.freshness(of: c, deviceNow: now), .live, "a 4 min old relayed fix is never live")
        XCTAssertEqual(v.positionAgeMs(v.positions[c]!, deviceNow: now), 4 * 60_000, accuracy: 5)
        var i = LivePresenterInput()
        i.view = v
        i.nearbyVia = via
        i.now = now
        let parts = LiveOutingPresenter.participants(i)
        XCTAssertEqual(parts.first { $0.id == b }?.presence, .live)
        XCTAssertEqual(parts.first { $0.id == b }?.viaNearby, true)
        guard case .stale? = parts.first(where: { $0.id == c })?.presence else { return XCTFail("relayed old fix must be stale") }
        XCTAssertEqual(LiveOutingPresenter.mapMembers(i, hideNotes: false).first { $0.id == c }?.viaNearby, true)
        /* A minute later with nothing new, the direct one ages too. */
        let later = now.addingTimeInterval(60)
        XCTAssertNotEqual(v.freshness(of: b, deviceNow: later), .live)
    }

    func testOverlayAgeDoesNotDependOnTheSendersClock() {
        var s = MeshStore(me: me, members: members)
        /* Their clock is an hour ahead: `at` is meaningless here, `age` is what counts. */
        s.ingest(MeshPayload(pos: [fix(b, at: t0 + 3_600_000, age: 120_000)]), from: b, nowMs: t0)
        let now = Date(timeIntervalSince1970: t0 / 1000)
        let v = s.overlay(view(), deviceNow: now).view
        XCTAssertEqual(v.positionAgeMs(v.positions[b]!, deviceNow: now), 120_000, accuracy: 5)
        XCTAssertNotEqual(v.freshness(of: b, deviceNow: now), .live)
    }

    func testServerNewerWinsWhenDataReturns() {
        var s = MeshStore(me: me, members: members)
        s.ingest(MeshPayload(pos: [fix(b, at: 1, age: 30_000, lat: 24.5)]), from: b, nowMs: t0)
        let serverFix = Position(user_id: b, lat: 24.6, lng: 46.7, accuracy: 5, heading: nil, speed: 0, mode: .balanced,
                                 recorded_at: ISODate.string(Date(timeIntervalSince1970: (t0 - 2_000) / 1000)))
        let (v, via) = s.overlay(view(positions: [serverFix]))
        XCTAssertEqual(v.positions[b]?.lat, 24.6, "the server's newer fix is shown, not the nearby one")
        XCTAssertFalse(via.contains(b), "and it is not marked «عبر الأجهزة القريبة»")
        let older = Position(user_id: b, lat: 24.6, lng: 46.7, accuracy: 5, heading: nil, speed: 0, mode: .balanced,
                             recorded_at: ISODate.string(Date(timeIntervalSince1970: (t0 - 300_000) / 1000)))
        XCTAssertEqual(s.overlay(view(positions: [older])).view.positions[b]?.lat, 24.5)
        XCTAssertTrue(s.overlay(view(status: .paused)).view.positions.isEmpty, "paused outing: no positions from anywhere")
    }

    func testOverlayEventsNotesAndSOS() {
        var s = MeshStore(me: me, members: members)
        s.ingest(MeshPayload(ev: [
            MeshEvent(id: "n", u: b, k: .note, text: "بنوقف هنا", at: 1, age: 10_000, hops: 0),
            MeshEvent(id: "s", u: b, k: .sos, lat: 24.71, lng: 46.72, acc: 9, fixAt: 1 - 5_000, at: 1, age: 10_000, hops: 0),
        ]), from: b, nowMs: t0)
        var v = s.overlay(view()).view
        XCTAssertEqual(v.members[b]?.note?.text, "بنوقف هنا")
        XCTAssertEqual(v.members[b]?.sos?.fix?.lat, 24.71)
        let sosAt = ISODate.parse(v.members[b]?.sos?.at)!.timeIntervalSince1970 * 1000
        let fixAt = ISODate.parse(v.members[b]?.sos?.fix?.recorded_at)!.timeIntervalSince1970 * 1000
        XCTAssertEqual(sosAt - fixAt, 5_000, accuracy: 2, "the SOS fix keeps its own (older) time")
        s.ingest(MeshPayload(ev: [MeshEvent(id: "ok", u: b, k: .sosClear, at: 2, age: 1_000, hops: 0)]), from: b, nowMs: t0)
        v = s.overlay(view()).view
        XCTAssertNil(v.members[b]?.sos, "«أنا بخير» heard nearby clears it")
        s.ingest(MeshPayload(ev: [MeshEvent(id: "s2", u: c, k: .sos, at: 1, age: 0, hops: 1)]), from: b, nowMs: t0)
        s.serverClearedSOS(c)
        XCTAssertNil(s.overlay(view()).view.members[c]?.sos, "the server's clear wins over an old copy")
    }

    func testDirectCountIsOnlyRecentlyHeardMembers() {
        var s = MeshStore(me: me, members: members)
        s.ingest(MeshPayload(), from: a, nowMs: t0)
        s.ingest(MeshPayload(), from: b, nowMs: t0 - 40_000)
        s.ingest(MeshPayload(pos: [fix(c, at: t0, hops: 1)]), from: a, nowMs: t0)
        XCTAssertEqual(s.directCount(nowMs: t0), 1, "only phones heard directly in the last 30 s; relayed cars don't count")
        XCTAssertEqual(LiveOutingPresenter.nearbyLabel(2), "متصل مباشرة بـ ٢ سيارات")
        XCTAssertEqual(LiveOutingPresenter.nearbyLabel(1), "متصل مباشرة بسيارة واحدة")
        XCTAssertNil(LiveOutingPresenter.nearbyLabel(0))
    }

    // MARK: consent / activation

    func testActivationNeedsTheSharingGate() {
        var m = MeshActivation()
        XCTAssertFalse(m.update(gateOpen: false, linkHealthy: false, friendLost: true, forced: true, nowMs: t0), "never without sharing consent, even forced")
        XCTAssertFalse(m.update(gateOpen: true, linkHealthy: false, friendLost: false, nowMs: t0))
        XCTAssertTrue(m.update(gateOpen: true, linkHealthy: false, friendLost: false, nowMs: t0 + MeshActivation.startAfterMs))
        XCTAssertTrue(m.update(gateOpen: true, linkHealthy: true, friendLost: false, nowMs: t0 + 20_000), "keeps running a while after the data returns")
        XCTAssertFalse(m.update(gateOpen: true, linkHealthy: true, friendLost: false, nowMs: t0 + 20_000 + MeshActivation.stopAfterMs))
        XCTAssertFalse(m.update(gateOpen: true, linkHealthy: true, friendLost: false, nowMs: t0 + 400_000))
        _ = m.update(gateOpen: true, linkHealthy: true, friendLost: true, nowMs: t0 + 500_000)
        XCTAssertTrue(m.update(gateOpen: true, linkHealthy: true, friendLost: true, nowMs: t0 + 510_000), "a friend dropped off the server: help them see us")
        XCTAssertFalse(m.update(gateOpen: false, linkHealthy: false, friendLost: true, nowMs: t0 + 511_000), "stop sharing → off at once")
    }

    @MainActor
    func testSessionMeshOffWithoutConsent() {
        let s = OutingSession(id: outing, myUserId: me, api: OutingsAPI(tokenProvider: { nil }), token: "", location: LocationSharer(), demo: view(),
                              env: SessionEnv(defaults: UserDefaults(suiteName: "mesh-test-\(UUID())")!, timers: true, authorizationOverride: true))
        s.updateMesh()
        XCTAssertFalse(s.gate.allowsPosition)
        XCTAssertFalse(s.mesh.running, "no consent, no share: the radios stay off")
    }
}
