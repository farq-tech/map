import AVFoundation
import XCTest
@testable import SaryAlbarq

/// «قناة الطلعة»: framing, the jitter buffer, the floor state machine, the
/// AAC-ELD codec and the nearby (mesh) voice frames. No network, no radios.
final class WalkieTalkieTests: XCTestCase {
    // MARK: framing

    func testFrameRoundTripAndServerHeader() {
        let f = PTTFrame(burst: 7, seq: 0xBEEF, codec: .aacELD16k, payload: Data([1, 2, 3]))
        let d = f.encoded()
        XCTAssertEqual([UInt8](d.prefix(5)), [1, 7, 0xBE, 0xEF, 1], "the server reads [0] version and [1] burst")
        XCTAssertEqual(PTTFrame.decode(d), f)
        XCTAssertNil(PTTFrame.decode(Data()))
    }

    func testFrameRejectsMalformed() {
        var bad = PTTFrame(burst: 1, seq: 0, codec: .aacELD16k, payload: Data([9])).encoded()
        bad[0] = 2
        XCTAssertNil(PTTFrame.decode(bad), "unknown version")
        var codec = PTTFrame(burst: 1, seq: 0, codec: .aacELD16k, payload: Data([9])).encoded()
        codec[4] = 99
        XCTAssertNil(PTTFrame.decode(codec), "unknown codec")
        XCTAssertNil(PTTFrame.decode(Data([1, 1, 0, 0, 1])), "header only")
        XCTAssertNil(PTTFrame.decode(PTTFrame(burst: 1, seq: 0, codec: .pcm16k, payload: Data(count: 1_196)).encoded()), "over 1200 bytes")
        XCTAssertNotNil(PTTFrame.decode(PTTFrame(burst: 1, seq: 0, codec: .pcm16k, payload: Data(count: 1_195)).encoded()), "exactly 1200 bytes")
    }

    func testSignalsDecodeFromServerJSON() {
        XCTAssertEqual(PTTSignal.decode(["type": "ptt_grant", "id": 3, "burst": 9, "max_ms": 60000]), .grant(id: 3, burst: 9, maxMs: 60000))
        XCTAssertEqual(PTTSignal.decode(["type": "ptt_deny", "id": 3, "reason": "busy", "talker_id": "u1"]), .deny(id: 3, reason: "busy", talkerId: "u1"))
        XCTAssertEqual(PTTSignal.decode(["type": "ptt_talker", "user_id": "u1", "name": "فهد", "burst": 4, "since": "x"]), .talker(PTTTalker(userId: "u1", name: "فهد", burst: 4)))
        XCTAssertEqual(PTTSignal.decode(["type": "ptt_idle", "user_id": "u1", "burst": 4, "reason": "max_duration"]), .idle(userId: "u1", burst: 4, reason: .maxDuration))
        XCTAssertEqual(PTTSignal.decode(["type": "ptt_state", "talker": NSNull(), "max_ms": 60000]), .state(talker: nil, maxMs: 60000))
        XCTAssertNil(PTTSignal.decode(["type": "ptt_grant", "id": 3, "burst": 0]), "burst 0 never exists")
        XCTAssertNil(PTTSignal.decode(["type": "position"]))
    }

    func testSeqDeltaWraps() {
        XCTAssertEqual(pttSeqDelta(1, 0), 1)
        XCTAssertEqual(pttSeqDelta(0, 0xFFFF), 1)
        XCTAssertEqual(pttSeqDelta(0xFFFF, 0), -1)
    }

    // MARK: jitter buffer

    private func f(_ seq: UInt16, burst: UInt8 = 1) -> PTTFrame { PTTFrame(burst: burst, seq: seq, codec: .aacELD16k, payload: Data([UInt8(seq & 0xFF)])) }

    private func seqs(_ pops: [PTTJitterBuffer.Pop]) -> [String] {
        pops.map {
            switch $0 {
            case .wait: return "w"
            case .underrun: return "u"
            case .gap(let s): return "g\(s)"
            case .frame(let fr): return "\(fr.seq)"
            }
        }
    }

    func testJitterPrebuffersThenPlaysInOrder() {
        var j = PTTJitterBuffer(targetDepth: 3)
        j.reset(burst: 1)
        j.push(f(1))
        j.push(f(0))
        XCTAssertEqual(j.pop(), .wait, "still filling")
        j.push(f(2))
        XCTAssertEqual(seqs([j.pop(), j.pop(), j.pop(), j.pop()]), ["0", "1", "2", "u"])
        XCTAssertEqual(j.stats.underruns, 1)
    }

    func testJitterConcealsLossDropsLateAndDuplicates() {
        var j = PTTJitterBuffer(targetDepth: 2)
        j.reset(burst: 1)
        for s: UInt16 in [0, 1, 3, 4] { j.push(f(s)) }
        j.push(f(1))
        XCTAssertEqual(j.stats.duplicates, 1)
        XCTAssertEqual(seqs([j.pop(), j.pop()]), ["0", "1"])
        j.push(f(0))
        XCTAssertEqual(j.stats.late, 1, "behind the playout point")
        XCTAssertEqual(seqs([j.pop(), j.pop(), j.pop()]), ["g2", "3", "4"])
        j.push(f(2))
        XCTAssertEqual(j.stats.late, 2, "the lost one arriving after its slot is dropped")
    }

    func testJitterIgnoresOtherBurstsAndWraps() {
        var j = PTTJitterBuffer(targetDepth: 2)
        j.reset(burst: 5)
        j.push(f(0xFFFE, burst: 4))
        XCTAssertEqual(j.depth, 0, "another transmission")
        for s: UInt16 in [0xFFFE, 0xFFFF, 0, 1] { j.push(f(s, burst: 5)) }
        XCTAssertEqual(seqs([j.pop(), j.pop(), j.pop(), j.pop()]), ["65534", "65535", "0", "1"])
    }

    func testJitterBoundsLatency() {
        var j = PTTJitterBuffer(targetDepth: 2, maxDepth: 5)
        j.reset(burst: 1)
        for s: UInt16 in 0..<9 { j.push(f(s)) }
        XCTAssertEqual(j.depth, 5)
        XCTAssertEqual(j.stats.overflow, 4)
        XCTAssertEqual(seqs([j.pop()]), ["4"], "the oldest went")
    }

    // MARK: floor

    func testFloorGrantTalkRelease() {
        var fl = PTTFloor(me: "me")
        XCTAssertEqual(fl.pressDown(nowMs: 0, online: true), [.sendStart(id: 1)])
        XCTAssertEqual(fl.state, .requesting(id: 1, atMs: 0))
        XCTAssertEqual(fl.receive(.grant(id: 1, burst: 9, maxMs: 60000), nowMs: 100), [.startCapture(burst: 9)])
        XCTAssertEqual(fl.talkingSeconds(nowMs: 7_200), 7)
        XCTAssertEqual(fl.pressUp(), [.stopCapture, .sendStop])
        XCTAssertEqual(fl.state, .idle)
        XCTAssertEqual(fl.receive(.idle(userId: "me", burst: 9, reason: .released), nowMs: 0), [], "already idle")
    }

    func testFloorBusyAndDenied() {
        var fl = PTTFloor(me: "me")
        let fahad = PTTTalker(userId: "u1", name: "فهد", burst: 3)
        XCTAssertEqual(fl.receive(.talker(fahad), nowMs: 0), [.startPlayback(fahad)])
        XCTAssertEqual(fl.pressDown(nowMs: 0, online: true), [.refused(.busy(talkerId: "u1"))], "refused locally, nothing sent")
        XCTAssertEqual(fl.receive(.idle(userId: "u1", burst: 2, reason: .released), nowMs: 0), [], "an old burst does not end this one")
        XCTAssertEqual(fl.receive(.idle(userId: "u1", burst: 3, reason: .released), nowMs: 0), [.stopPlayback])
        _ = fl.pressDown(nowMs: 0, online: true)
        XCTAssertEqual(fl.receive(.deny(id: 1, reason: "busy", talkerId: "u2"), nowMs: 0), [.refused(.busy(talkerId: "u2"))])
        XCTAssertEqual(fl.state, .idle)
        _ = fl.pressDown(nowMs: 0, online: true)
        XCTAssertEqual(fl.receive(.deny(id: 2, reason: "rate_limited", talkerId: nil), nowMs: 0), [.refused(.rateLimited)])
        XCTAssertEqual(fl.pressDown(nowMs: 0, online: false), [.refused(.offline)])
    }

    func testFloorLateGrantIsHandedBack() {
        var fl = PTTFloor(me: "me")
        _ = fl.pressDown(nowMs: 0, online: true)
        XCTAssertEqual(fl.pressUp(), [.sendStop], "let go before the grant")
        XCTAssertEqual(fl.receive(.grant(id: 1, burst: 4, maxMs: 60000), nowMs: 0), [.sendStop], "never talk after letting go")
        XCTAssertEqual(fl.state, .idle)
    }

    func testFloorSixtySecondsAndServerCutOff() {
        var fl = PTTFloor(me: "me")
        _ = fl.pressDown(nowMs: 0, online: true)
        _ = fl.receive(.grant(id: 1, burst: 4, maxMs: 60000), nowMs: 0)
        XCTAssertEqual(fl.tick(nowMs: 59_000), [])
        XCTAssertEqual(fl.tick(nowMs: 60_000), [.stopCapture, .sendStop, .cutOff(.maxDuration)])
        _ = fl.pressDown(nowMs: 61_000, online: true)
        _ = fl.receive(.grant(id: 2, burst: 5, maxMs: 60000), nowMs: 61_000)
        XCTAssertEqual(fl.receive(.idle(userId: "me", burst: 5, reason: .silence), nowMs: 62_000), [.stopCapture, .cutOff(.silence)])
        _ = fl.pressDown(nowMs: 70_000, online: true)
        XCTAssertEqual(fl.tick(nowMs: 73_000), [.sendStop, .refused(.offline)], "no answer to a request")
    }

    func testFloorSomeoneElseWinsWhileRequesting() {
        var fl = PTTFloor(me: "me")
        _ = fl.pressDown(nowMs: 0, online: true)
        let t = PTTTalker(userId: "u1", name: "", burst: 2)
        XCTAssertEqual(fl.receive(.talker(t), nowMs: 0), [.refused(.busy(talkerId: "u1")), .startPlayback(t)])
        XCTAssertEqual(fl.receive(.talker(PTTTalker(userId: "me", name: "", burst: 9)), nowMs: 0), [], "never listen to myself")
    }

    func testFloorMuteAndLinkLoss() {
        var fl = PTTFloor(me: "me")
        _ = fl.receive(.state(talker: PTTTalker(userId: "u1", name: "", burst: 1), maxMs: 60000), nowMs: 0)
        XCTAssertEqual(fl.setMuted(true), [.stopPlayback])
        XCTAssertEqual(fl.receive(.talker(PTTTalker(userId: "u2", name: "", burst: 2)), nowMs: 0), [], "muted: nothing plays")
        XCTAssertEqual(fl.pressDown(nowMs: 0, online: true), [.refused(.muted)])
        _ = fl.setMuted(false)
        _ = fl.pressDown(nowMs: 0, online: true)
        _ = fl.receive(.grant(id: 1, burst: 3, maxMs: 60000), nowMs: 0)
        XCTAssertEqual(fl.linkLost(), [.stopCapture, .cutOff(.left)])
    }

    // MARK: codec

    func testAACELDRoundTripKeepsTheTone() throws {
        let enc = try XCTUnwrap(PTTEncoder())
        let dec = try XCTUnwrap(PTTDecoder())
        var chunker = PTTChunker()
        var phase = 0.0
        var packets: [Data] = []
        /* Odd-sized input blocks, as a microphone tap delivers them. */
        for _ in 0..<40 {
            var block = [Float](repeating: 0, count: 700)
            for i in block.indices { block[i] = Float(0.5 * sin(phase)); phase += 2 * .pi * 440 / 16_000 }
            for chunk in block.withUnsafeBufferPointer({ chunker.push($0) }) {
                XCTAssertEqual(chunk.count, 480)
                packets.append(try XCTUnwrap(enc.encode(try XCTUnwrap(AVAudioPCMBuffer.ptt(chunk)))))
            }
        }
        XCTAssertEqual(packets.count, 40 * 700 / 480)
        XCTAssertTrue(packets.allSatisfy { $0.count + PTTFrame.headerBytes <= PTTFrame.maxBytes })
        let avg = packets.dropFirst().map(\.count).reduce(0, +) / (packets.count - 1)
        XCTAssertLessThan(avg, 160, "≈ 24 kbit/s at 30 ms")
        var rms: [Float] = []
        for p in packets { rms.append(try XCTUnwrap(dec.decode(p)).pttRMS) }
        XCTAssertEqual(Double(rms.suffix(20).reduce(0, +) / 20), 0.354, accuracy: 0.06, "a 0.5 sine comes back at ~0.35 RMS")
        XCTAssertNil(dec.decode(Data()))
    }

    // MARK: nearby voice

    func testMeshVoiceSealOpenAndRejects() throws {
        let members: Set<String> = ["a1", "b2"]
        let keys = MeshKeys(outingId: "11111111-1111-4111-8111-111111111111", serverKey: nil)
        let a = MeshVoiceCodec(keys: keys, me: "a1")
        let b = MeshVoiceCodec(keys: keys, me: "b2")
        let frame = PTTFrame(burst: 3, seq: 7, codec: .aacELD16k, payload: Data(repeating: 5, count: 80)).encoded()
        let sealed = try a.seal(.audio, body: frame, nowMs: 1_000_000)
        XCTAssertTrue(MeshVoiceCodec.isVoice(sealed))
        XCTAssertFalse(MeshVoiceCodec.isVoice(Data("{\"v\":1}".utf8)), "JSON mesh frames are not voice")
        let m = try b.open(sealed, members: members, nowMs: 1_000_500)
        XCTAssertEqual(m.from, "a1")
        XCTAssertEqual(m.kind, .audio)
        XCTAssertEqual(PTTFrame.decode(m.body)?.seq, 7)
        XCTAssertFalse(sealed.range(of: Data(repeating: 5, count: 16)) != nil, "audio is not in clear")

        XCTAssertThrowsError(try a.open(sealed, members: members, nowMs: 1_000_500)) { XCTAssertEqual($0 as? MeshReject, .fromMe) }
        XCTAssertThrowsError(try b.open(sealed, members: ["b2"], nowMs: 1_000_500)) { XCTAssertEqual($0 as? MeshReject, .notMember) }
        XCTAssertThrowsError(try b.open(sealed, members: members, nowMs: 1_010_000)) { XCTAssertEqual($0 as? MeshReject, .tooOld) }
        let other = MeshVoiceCodec(keys: MeshKeys(outingId: "22222222-2222-4222-8222-222222222222", serverKey: nil), me: "b2")
        XCTAssertThrowsError(try other.open(sealed, members: members, nowMs: 1_000_500)) { XCTAssertEqual($0 as? MeshReject, .otherOuting) }
        var tampered = sealed
        tampered[tampered.count - 1] ^= 1
        XCTAssertThrowsError(try b.open(tampered, members: members, nowMs: 1_000_500)) { XCTAssertEqual($0 as? MeshReject, .badAuth) }
        /* Claiming to be b2 with a1's box: the key is per sender, so it does not open. */
        var spoof = sealed
        let idAt = 19
        spoof.replaceSubrange(idAt..<(idAt + 2), with: Data("b2".utf8))
        let c = MeshVoiceCodec(keys: keys, me: "c3")
        XCTAssertThrowsError(try c.open(spoof, members: ["a1", "b2", "c3"], nowMs: 1_000_500))
    }

    func testMeshVoiceLimiter() {
        var l = MeshVoiceLimiter()
        var ok = 0
        for _ in 0..<200 where l.allow("p", nowMs: 0) { ok += 1 }
        XCTAssertEqual(ok, 80, "burst")
        XCTAssertTrue(l.allow("p", nowMs: 1_000), "refills at 50/s")
    }
}
