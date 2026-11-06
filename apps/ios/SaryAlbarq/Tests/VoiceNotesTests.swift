import AVFoundation
import XCTest
@testable import SaryAlbarq

/// «رسالة صوتية»: the auto-play rules, the inbox, the push payload, the m4a round trip and the
/// receive chain, the outbox (retries, idempotency, final errors) and the center end to end with
/// a fake server. No network, no microphone (the recorder's test tone).
@MainActor
final class VoiceNotesTests: XCTestCase {
    private func note(_ id: String, user: String = "friend", channel: String = "1", age: Double? = 1_000, recordedAt: Date = Date()) -> VoiceNote {
        VoiceNote(id: id, channel: channel, user_id: user, mime: "audio/mp4", duration_ms: 3_000, bytes: 4_000,
                  recorded_at: ISODate.string(recordedAt), created_at: ISODate.string(recordedAt),
                  expires_at: ISODate.string(Date().addingTimeInterval(24 * 3600)), age_ms: age, url: "/api/outings/o/voice-notes/\(id)")
    }

    private func tempDefaults() -> UserDefaults {
        let name = "voice-notes-tests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    // MARK: mode

    func testVoiceNotesAreTheDefaultAndLiveIsTheOption() {
        let d = tempDefaults()
        XCTAssertEqual(PTTTalkMode.current(d), .notes)
        d.set("live", forKey: PTTTalkMode.key)
        XCTAssertEqual(PTTTalkMode.current(d), .live)
        d.set("nonsense", forKey: PTTTalkMode.key)
        XCTAssertEqual(PTTTalkMode.current(d), .notes)
        XCTAssertEqual(PTTTalkMode.live.label, "بث مباشر")
        XCTAssertEqual(PTTTalkMode.notes.label, "رسالة صوتية")
    }

    // MARK: policy

    func testAutoPlayOnlyFreshOthersOnMyChannelUnmutedUnheard() {
        let n = note("a")
        XCTAssertTrue(VoiceNotePolicy.shouldAutoPlay(note: n, ageMs: 5_000, me: "me", channel: "1", muted: false, heard: false))
        XCTAssertFalse(VoiceNotePolicy.shouldAutoPlay(note: n, ageMs: 120_001, me: "me", channel: "1", muted: false, heard: false), "stale: the list only")
        XCTAssertFalse(VoiceNotePolicy.shouldAutoPlay(note: n, ageMs: 5_000, me: "friend", channel: "1", muted: false, heard: false), "my own")
        XCTAssertFalse(VoiceNotePolicy.shouldAutoPlay(note: n, ageMs: 5_000, me: "me", channel: "2", muted: false, heard: false), "another channel")
        XCTAssertFalse(VoiceNotePolicy.shouldAutoPlay(note: n, ageMs: 5_000, me: "me", channel: "1", muted: true, heard: false), "muted")
        XCTAssertFalse(VoiceNotePolicy.shouldAutoPlay(note: n, ageMs: 5_000, me: "me", channel: "1", muted: false, heard: true), "heard already")
    }

    func testAgeUsesTheServersClockThenOurs() {
        XCTAssertEqual(VoiceNotePolicy.ageMs(serverAgeMs: 10_000, receivedAtMs: 1_000, nowMs: 31_000, recordedAt: "x"), 40_000)
        /* No server age (a push): our clock against recorded_at. */
        let iso = ISODate.string(Date().addingTimeInterval(-30))
        let a = VoiceNotePolicy.ageMs(serverAgeMs: nil, receivedAtMs: 0, nowMs: Date().timeIntervalSince1970 * 1000, recordedAt: iso)
        XCTAssertEqual(a, 30_000, accuracy: 1_500)
        XCTAssertEqual(VoiceNotePolicy.ageMs(serverAgeMs: nil, receivedAtMs: 0, nowMs: 0, recordedAt: "garbage"), .infinity)
    }

    // MARK: inbox

    func testInboxQueuesFreshNotesInOrderAndListsTheRest() {
        var box = VoiceNoteInbox()
        let t = Date()
        XCTAssertTrue(box.receive(note("b", recordedAt: t.addingTimeInterval(2)), nowMs: 0, me: "me", channel: "1", muted: false))
        XCTAssertTrue(box.receive(note("a", recordedAt: t), nowMs: 0, me: "me", channel: "1", muted: false))
        XCTAssertFalse(box.receive(note("a", recordedAt: t), nowMs: 0, me: "me", channel: "1", muted: false), "the same note twice: once")
        XCTAssertFalse(box.receive(note("old", age: 300_000), nowMs: 0, me: "me", channel: "1", muted: false), "stale: never by itself")
        XCTAssertFalse(box.receive(note("mine", user: "me"), nowMs: 0, me: "me", channel: "1", muted: false))
        XCTAssertFalse(box.receive(note("ch2", channel: "2"), nowMs: 0, me: "me", channel: "1", muted: false))
        XCTAssertEqual(box.nextToPlay(nowMs: 0)?.id, "a", "oldest first")
        box.markHeard("a")
        XCTAssertEqual(box.nextToPlay(nowMs: 0)?.id, "b")
        XCTAssertNil(box.nextToPlay(nowMs: 0))
        XCTAssertEqual(Set(box.list(channel: "1", nowMs: Date().timeIntervalSince1970 * 1000).map(\.id)), ["a", "b", "old", "mine"])
        XCTAssertEqual(box.list(channel: "2", nowMs: Date().timeIntervalSince1970 * 1000).map(\.id), ["ch2"])
        XCTAssertEqual(box.unheard(channel: "1", me: "me", nowMs: Date().timeIntervalSince1970 * 1000), 2, "b and old (not mine, not a)")
    }

    func testAQueuedNoteGoesStaleWhileWaitingForTheAir() {
        var box = VoiceNoteInbox()
        XCTAssertTrue(box.receive(note("x", age: 100_000), nowMs: 0, me: "me", channel: "1", muted: false))
        /* A live talker held the air for half a minute: now it is too old to play by itself. */
        XCTAssertNil(box.nextToPlay(nowMs: 30_000))
        XCTAssertEqual(box.list(channel: "1", nowMs: Date().timeIntervalSince1970 * 1000).map(\.id), ["x"], "still in «الرسائل الصوتية»")
    }

    func testTuningAwayDropsWhatWasQueuedForTheOldChannel() {
        var box = VoiceNoteInbox()
        box.receive(note("x"), nowMs: 0, me: "me", channel: "1", muted: false)
        box.dropQueue(except: "3")
        XCTAssertNil(box.nextToPlay(nowMs: 0))
    }

    func testHeardNotesNeverReplayAfterARelaunch() {
        let d = tempDefaults()
        VoiceNoteHeardStore.save(["a"], outingId: "o", defaults: d)
        var box = VoiceNoteInbox(heard: VoiceNoteHeardStore.load("o", defaults: d))
        XCTAssertFalse(box.receive(note("a"), nowMs: 0, me: "me", channel: "1", muted: false))
        VoiceNoteHeardStore.forgetAll(defaults: d)
        XCTAssertTrue(VoiceNoteHeardStore.load("o", defaults: d).isEmpty)
    }

    func testPruneForgetsWhatTheServerNoLongerHas() {
        var box = VoiceNoteInbox()
        box.receive(note("a"), nowMs: 0, me: "me", channel: "1", muted: false)
        box.receive(note("b", channel: "2"), nowMs: 0, me: "me", channel: "1", muted: false)
        box.prune(channel: "1", keep: [])
        let now = Date().timeIntervalSince1970 * 1000
        XCTAssertTrue(box.list(channel: "1", nowMs: now).isEmpty)
        XCTAssertEqual(box.list(channel: "2", nowMs: now).count, 1, "other channels untouched")
        XCTAssertNil(box.nextToPlay(nowMs: 0))
    }

    // MARK: push

    func testVoiceNotePushPayload() {
        let p: [String: Any] = ["aps": [:], "activeSpeaker": "فهد", "type": "voice_note", "outing_id": "o1", "channel": "3",
                                "note": ["id": "n1", "channel": "3", "user_id": "u1", "duration_ms": 4200, "recorded_at": "2026-11-06T10:00:00.000Z", "url": "/api/outings/o1/voice-notes/n1"]]
        let v = VoiceNotePush.parse(p, fallbackOuting: "x")
        XCTAssertEqual(v?.outingId, "o1")
        XCTAssertEqual(v?.speaker, "فهد")
        XCTAssertEqual(v?.note.id, "n1")
        XCTAssertEqual(v?.note.channel, "3")
        XCTAssertEqual(v?.note.duration_ms, 4200)
        XCTAssertNil(v?.note.age_ms, "age from recorded_at, our clock")
        XCTAssertNil(VoiceNotePush.parse(["type": "ptt_talker", "activeSpeaker": "فهد"], fallbackOuting: "x"), "a live wake-up is not a note")
    }

    // MARK: audio

    func testToneM4aDecodesTo16kMonoAndTheReceiveChainLevelsIt() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vn-test-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        try VoiceNoteRecorder.writeTone(to: url, seconds: 2)
        let data = try Data(contentsOf: url)
        XCTAssertGreaterThan(data.count, 256)
        XCTAssertLessThan(data.count, 40_000, "≈24 kbps + the container: a 2 s note is a few tens of KB")
        XCTAssertEqual(String(decoding: data[4..<8], as: UTF8.self), "ftyp", "an MP4 container the server accepts")
        let pcm = try XCTUnwrap(VoiceNotePlayer.decode(data))
        XCTAssertEqual(pcm.format.sampleRate, 16_000)
        XCTAssertEqual(pcm.format.channelCount, 1)
        XCTAssertEqual(Double(pcm.frameLength) / 16_000, 2, accuracy: 0.2)
        /* A quiet sender (−30 dBFS-ish) is made up towards the «صوت اللاسلكي» level, never clipped. */
        let d = pcm.floatChannelData![0]
        for i in 0..<Int(pcm.frameLength) { d[i] *= 0.1 }
        let before = pcm.pttRMS
        VoiceNotePlayer.process(pcm, radio: true, level: .high)
        var peak: Float = 0
        for i in 0..<Int(pcm.frameLength) { peak = max(peak, abs(d[i])) }
        XCTAssertLessThan(peak, 1.0, "the limiter never clips")
        XCTAssertGreaterThan(pcm.pttRMS, before * 2, "made up (≥ +6 dB) towards the «صوت اللاسلكي» level")
        let w = VoiceNotePlayer.waveform(pcm, count: 40)
        XCTAssertEqual(w.count, 40)
        XCTAssertEqual(w.max() ?? 0, 1, accuracy: 0.0001)
        XCTAssertNil(VoiceNotePlayer.decode(Data("not audio".utf8)))
    }

    func testAMinuteIsAboutTwoHundredKilobytes() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vn-60-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        try VoiceNoteRecorder.writeTone(to: url, seconds: 60)
        let size = try Data(contentsOf: url).count
        XCTAssertLessThan(size, 640 * 1024, "under the server's cap")
        XCTAssertLessThan(size, 260_000, "≈24–32 kbps")
        /* A recorder's high-rate file comes out at the same rate after transcode. */
        let raw = FileManager.default.temporaryDirectory.appendingPathComponent("vn-raw-\(UUID().uuidString).m4a")
        try FileManager.default.copyItem(at: url, to: raw)
        let out = VoiceNoteRecorder.transcode(raw)
        defer { try? FileManager.default.removeItem(at: out) }
        XCTAssertNotEqual(out, raw)
        XCTAssertLessThan(try Data(contentsOf: out).count, 260_000)
    }

    func testWaveformResampleKeepsPeaks() {
        XCTAssertEqual(VoiceNoteWaveform.resample([], to: 4), [0.05, 0.05, 0.05, 0.05])
        XCTAssertEqual(VoiceNoteWaveform.resample([0, 1, 0, 0, 0.5, 0], to: 3), [1, 0, 0.5])
    }

    // MARK: outbox

    final class FakeBackend: VoiceNoteBackend {
        var failures: [Error] = []
        var uploads: [(clientId: String, channel: String, ms: Int, age: Int)] = []
        var notes: [VoiceNote] = []
        var audio: [String: Data] = [:]

        func uploadVoiceNote(_ outingId: String, audio: Data, durationMs: Int, channel: String, clientId: String, ageMs: Int) async throws -> VoiceNote {
            uploads.append((clientId, channel, durationMs, ageMs))
            if !failures.isEmpty { throw failures.removeFirst() }
            return VoiceNote(id: "srv-\(uploads.count)", channel: channel, user_id: "me", mime: "audio/mp4", duration_ms: durationMs, bytes: audio.count,
                             recorded_at: ISODate.string(Date()), created_at: nil, expires_at: ISODate.string(Date().addingTimeInterval(86_400)), age_ms: 0, url: "/x")
        }

        func listVoiceNotes(_ outingId: String, channel: String) async throws -> [VoiceNote] { notes.filter { $0.channel == channel } }

        func fetchVoiceNote(_ note: VoiceNote) async throws -> Data {
            guard let d = audio[note.id] else { throw OutingAPIError(code: "clip_gone", status: 404) }
            return d
        }
    }

    private func toneFile(_ s: Double = 1) throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("vn-\(UUID().uuidString).m4a")
        try VoiceNoteRecorder.writeTone(to: u, seconds: s)
        return u
    }

    private func waitFor(_ what: String, timeout: TimeInterval = 8, _ cond: () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !cond(), Date() < end { try? await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertTrue(cond(), what)
    }

    func testOutboxRetriesWithTheSameIdempotencyKeyUntilStored() async throws {
        let b = FakeBackend()
        b.failures = [OutingAPIError(code: "network", status: 0)]
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vn-outbox-\(UUID().uuidString)")
        let up = VoiceNoteUploader(outingId: "o", backend: b, defaults: tempDefaults(), dir: dir)
        var outcomes: [VoiceNoteUploader.Outcome] = []
        up.onOutcome = { _, o in outcomes.append(o) }
        XCTAssertNotNil(up.enqueue(file: try toneFile(), channel: "4", durationMs: 1_000, recordedAt: Date()))
        await waitFor("sent after one retry") { outcomes.contains { if case .sent = $0 { return true }; return false } }
        XCTAssertEqual(b.uploads.count, 2)
        XCTAssertEqual(b.uploads[0].clientId, b.uploads[1].clientId, "the retry is the same note")
        XCTAssertEqual(b.uploads[1].channel, "4")
        XCTAssertEqual(up.pending, 0)
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.count ?? 0, 0, "nothing left on the phone")
    }

    func testOutboxDropsWhatNoRetryWillFix() async throws {
        let b = FakeBackend()
        b.failures = [OutingAPIError(code: "not_invited", status: 403)]
        let up = VoiceNoteUploader(outingId: "o", backend: b, defaults: tempDefaults(), dir: FileManager.default.temporaryDirectory.appendingPathComponent("vn-\(UUID().uuidString)"))
        var dropped: String?
        up.onOutcome = { _, o in if case let .dropped(w) = o { dropped = w } }
        _ = up.enqueue(file: try toneFile(), channel: "1", durationMs: 1_000, recordedAt: Date())
        await waitFor("dropped") { dropped != nil }
        XCTAssertEqual(dropped, "not_invited")
        XCTAssertTrue(VoiceNoteUploader.isFinal(OutingAPIError(code: "outing_ended", status: 409)))
        XCTAssertFalse(VoiceNoteUploader.isFinal(OutingAPIError(code: "rate_limited", status: 429)))
        XCTAssertFalse(VoiceNoteUploader.isFinal(OutingAPIError(code: "http_502", status: 502)))
    }

    func testOutboxSurvivesARelaunchAndSendsTheAge() async throws {
        let d = tempDefaults()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vn-\(UUID().uuidString)")
        let offline = VoiceNoteUploader(outingId: "o", backend: nil, defaults: d, dir: dir)
        _ = offline.enqueue(file: try toneFile(), channel: "1", durationMs: 1_000, recordedAt: Date().addingTimeInterval(-90))
        XCTAssertEqual(offline.pending, 1)
        let b = FakeBackend()
        let again = VoiceNoteUploader(outingId: "o", backend: b, defaults: d, dir: dir)
        XCTAssertEqual(again.pending, 1, "still waiting after the app was killed")
        again.kick()
        await waitFor("sent") { again.pending == 0 }
        XCTAssertEqual(Double(b.uploads.first?.age ?? 0), 90_000, accuracy: 3_000, "the server learns it is 90 s old")
    }

    // MARK: center

    func testRecordSendAndAFriendsFreshNotePlaysByItself() async throws {
        let b = FakeBackend()
        let walkie = OutingWalkieTalkie(outingId: "o-vn", me: "me", tokenBackend: nil, route: PTTInAppRoute(), defaults: tempDefaults())
        let c = VoiceNoteCenter(outingId: "o-vn", me: "me", backend: b, walkie: walkie, defaults: tempDefaults(),
                                recorder: VoiceNoteRecorder(testTone: true),
                                outboxDir: FileManager.default.temporaryDirectory.appendingPathComponent("vn-\(UUID().uuidString)"))
        c.nameOf = { $0 == "friend" ? "فهد" : nil }
        c.isForeground = { true }
        c.attach()
        defer { c.close(leftOuting: true) }

        c.talkTapped()
        XCTAssertTrue(c.isRecording)
        XCTAssertEqual(c.buttonState(), .talking(seconds: 0, remaining: 60))
        try await Task.sleep(nanoseconds: 1_200_000_000)
        c.talkTapped() // the second tap sends
        XCTAssertFalse(c.isRecording)
        await waitFor("uploaded on «تردد ١»") { b.uploads.count == 1 }
        XCTAssertEqual(b.uploads.first?.channel, "1")
        XCTAssertGreaterThanOrEqual(b.uploads.first?.ms ?? 0, 1_000)

        /* A friend's note arrives on the socket, fresh: it plays by itself, «فهد يتكلم…». */
        let url = try toneFile(1.5)
        b.audio["n1"] = try Data(contentsOf: url)
        c.receive(note("n1"))
        await waitFor("playing") { c.playing?.id == "n1" && c.playing?.loading == false }
        XCTAssertEqual(c.playing?.name, "فهد")
        XCTAssertEqual(c.buttonState(), .listening(name: "فهد", color: 0xFFFFFF))
        await waitFor("finished and heard", timeout: 10) { c.playing == nil }
        XCTAssertTrue(c.isHeard("n1"))

        /* An old one: listed, never played by itself. */
        c.receive(note("n2", age: 600_000))
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertNil(c.playing)
        XCTAssertEqual(c.unheard, 1)
        XCTAssertTrue(c.list.contains { $0.id == "n2" })
    }

    func testAutoplayOffShowsACardWithPlayInstead() async throws {
        let d = tempDefaults()
        XCTAssertTrue(VoiceAutoplay.isOn(d), "on by default")
        d.set(false, forKey: VoiceAutoplay.key)
        let b = FakeBackend()
        b.audio["n1"] = try Data(contentsOf: try toneFile(1))
        let c = VoiceNoteCenter(outingId: "o-off", me: "me", backend: b, walkie: nil, defaults: d,
                                recorder: VoiceNoteRecorder(testTone: true),
                                outboxDir: FileManager.default.temporaryDirectory.appendingPathComponent("vn-\(UUID().uuidString)"))
        c.nameOf = { _ in "فهد" }
        c.isForeground = { true }
        c.attach()
        defer { c.close(leftOuting: true) }
        c.receive(note("n1"))
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertNil(c.playing, "does not play by itself")
        XCTAssertEqual(c.offer?.id, "n1", "waits on a card with ▶︎")
        XCTAssertEqual(c.offer?.name, "فهد")
        /* A stale one never makes a card. */
        c.dismissOffer()
        c.receive(note("old", age: 600_000))
        XCTAssertNil(c.offer)
        /* ▶︎ plays it. */
        c.receive(note("n2"))
        b.audio["n2"] = b.audio["n1"]
        c.playOffer()
        XCTAssertNil(c.offer)
        await waitFor("playing after ▶︎") { c.playing?.id == "n2" }
    }

    func testDeleteSendsNothing() async throws {
        let b = FakeBackend()
        let c = VoiceNoteCenter(outingId: "o-del", me: "me", backend: b, walkie: nil, defaults: tempDefaults(),
                                recorder: VoiceNoteRecorder(testTone: true),
                                outboxDir: FileManager.default.temporaryDirectory.appendingPathComponent("vn-\(UUID().uuidString)"))
        c.talkTapped()
        try await Task.sleep(nanoseconds: 900_000_000)
        c.cancel()
        XCTAssertFalse(c.isRecording)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(b.uploads.isEmpty)
        c.close(leftOuting: true)
    }
}
