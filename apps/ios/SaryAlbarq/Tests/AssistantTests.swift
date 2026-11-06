import XCTest
@testable import SaryAlbarq

// «مساعد سرى»: the parser on the Najdi test sets (keyword rules alone, and with the recorded
// outputs of the real models as the mocked LLM), the templates with live vs stale data,
// «never triggers SOS», and the download's size / sha256 / install logic.

private struct UtteranceSet: Decodable {
    struct Case: Decodable { var text: String; var intent: String; var arg: String? }
    var members: [String]
    var destination: String
    var cases: [Case]

    static func load(_ name: String) throws -> UtteranceSet {
        let url = try XCTUnwrap(Bundle(for: AssistantParserTests.self).url(forResource: name, withExtension: "json"))
        return try JSONDecoder().decode(UtteranceSet.self, from: Data(contentsOf: url))
    }
}

private struct Replay: Decodable {
    struct Model: Decodable { var outputs: [String: String]; var rss_mb: Int?; var latency_ms_p50: [String: Int] }
    var models: [String: Model]

    static func load() throws -> Replay {
        let url = try XCTUnwrap(Bundle(for: AssistantParserTests.self).url(forResource: "assistant-llm-replay", withExtension: "json"))
        return try JSONDecoder().decode(Replay.self, from: Data(contentsOf: url))
    }
}

/// The mocked LLM: what the real model said for this exact prompt's question.
private final class ReplayModel: AssistantLanguageModel {
    let outputs: [String: String]
    private(set) var calls = 0
    init(_ outputs: [String: String]) { self.outputs = outputs }
    func classify(_ prompt: AssistantPrompt) async -> String? {
        calls += 1
        return outputs[prompt.question]
    }
}

private final class FixedModel: AssistantLanguageModel {
    var reply: String?
    init(_ r: String?) { reply = r }
    func classify(_ prompt: AssistantPrompt) async -> String? { reply }
}

final class AssistantParserTests: XCTestCase {
    private func score(_ set: UtteranceSet, model: AssistantLanguageModel?) async -> (ok: Int, n: Int, fails: [String]) {
        let parser = AssistantParser(resources: AssistantPrompt.Resources.load(Bundle(for: LiveOutingController.self)))
        var ok = 0
        var fails: [String] = []
        for c in set.cases {
            let r = await parser.parse(c.text, members: set.members, destination: set.destination, model: model)
            if r.intent.key == c.intent && (c.arg == nil || r.intent.arg == c.arg) { ok += 1 } else { fails.append("\(c.text) → \(r.intent.key) \(r.intent.arg ?? "")") }
        }
        return (ok, set.cases.count, fails)
    }

    func testTheTestSetsAreBigEnoughAndCoverEveryIntent() throws {
        let a = try UtteranceSet.load("assistant-utterances"), b = try UtteranceSet.load("assistant-utterances-holdout")
        XCTAssertGreaterThanOrEqual(a.cases.count, 60)
        let keys = Set((a.cases + b.cases).map(\.intent))
        XCTAssertEqual(keys, ["members_where", "trip_remaining", "nearest_fuel", "weather", "sunset", "rally_point", "navigate", "radio",
                              "set_channel", "open_chat", "sos_help", "unknown"])
    }

    /// Without the model: the keyword rules alone still place the top intents.
    func testKeywordFallbackAccuracy() async throws {
        for name in ["assistant-utterances", "assistant-utterances-holdout", "assistant-utterances-free"] {
            let s = try UtteranceSet.load(name)
            let r = await score(s, model: nil)
            print("ASSISTANT-ACC keywords \(name): \(r.ok)/\(r.n) = \(String(format: "%.1f", 100 * Double(r.ok) / Double(r.n)))%\n  " + r.fails.joined(separator: "\n  "))
            /* The free-phrasing set is where keywords alone are expected to miss (that is what the model is for). */
            XCTAssertGreaterThanOrEqual(Double(r.ok) / Double(r.n), name.hasSuffix("free") ? 0.3 : 0.9, name)
        }
    }

    /// The real models' recorded outputs as the mocked LLM, behind the keyword rules (the app's path).
    func testHybridAccuracyPerModel() async throws {
        let replay = try Replay.load()
        let sets = [try UtteranceSet.load("assistant-utterances"), try UtteranceSet.load("assistant-utterances-holdout")]
        let free = try UtteranceSet.load("assistant-utterances-free")
        for (name, m) in replay.models.sorted(by: { $0.key < $1.key }) {
            let rf = await score(free, model: ReplayModel(m.outputs))
            print("ASSISTANT-ACC \(name) free phrasing, with keywords: \(rf.ok)/\(rf.n)\n  " + rf.fails.joined(separator: "\n  "))
            if name == AssistantModelSpec.current.id { XCTAssertGreaterThanOrEqual(rf.ok, 18, "the model lifts free phrasing well above the keywords alone") }
            var ok = 0, n = 0, modelOnlyOK = 0
            for s in sets {
                let r = await score(s, model: ReplayModel(m.outputs))
                ok += r.ok
                n += r.n
                /* The model alone, for the report. */
                for c in s.cases {
                    if let raw = m.outputs[c.text], let i = AssistantIntent.decode(json: raw, members: s.members),
                       i.key == c.intent, c.arg == nil || i.arg == c.arg { modelOnlyOK += 1 }
                }
            }
            print("ASSISTANT-ACC \(name): model alone \(modelOnlyOK)/\(n), with keywords \(ok)/\(n) = \(String(format: "%.1f", 100 * Double(ok) / Double(n)))%")
            if name == AssistantModelSpec.current.id {
                XCTAssertGreaterThanOrEqual(Double(modelOnlyOK) / Double(n), 0.90, "the chosen model alone is ≥ 90 %")
                XCTAssertGreaterThanOrEqual(Double(ok) / Double(n), 0.95, "the chosen model with the keyword rules")
            }
        }
    }

    /// The prompt and grammar the app builds are byte for byte the ones the models were evaluated with.
    func testPromptAndGrammarMatchTheEvaluatedOnes() throws {
        let b = Bundle(for: AssistantParserTests.self)
        let s = try UtteranceSet.load("assistant-utterances")
        let r = try XCTUnwrap(AssistantPrompt.Resources.load(Bundle(for: LiveOutingController.self)))
        let p = AssistantPrompt.make(r, question: "وين الربع", members: s.members, destination: s.destination)
        let refPrompt = try String(contentsOf: XCTUnwrap(b.url(forResource: "assistant-prompt-reference", withExtension: "txt")), encoding: .utf8)
        let refGrammar = try String(contentsOf: XCTUnwrap(b.url(forResource: "assistant-grammar-reference", withExtension: "gbnf")), encoding: .utf8)
        XCTAssertEqual(p.full, refPrompt)
        XCTAssertEqual(p.grammar, refGrammar)
    }

    func testModelCannotInventAMemberOrAChannel() {
        let m = ["سعود", "نورة"]
        XCTAssertNil(AssistantIntent.decode(json: #"{"intent": "members_where", "who": "خالد"}"#, members: m))
        XCTAssertEqual(AssistantIntent.decode(json: #"{"intent": "members_where", "who": "everyone"}"#, members: m), .membersWhere(who: nil))
        XCTAssertNil(AssistantIntent.decode(json: #"{"intent": "set_channel", "channel": 9}"#, members: m))
        XCTAssertNil(AssistantIntent.decode(json: "garbage", members: m))
        XCTAssertEqual(AssistantIntent.decode(json: #"{"intent": "navigate", "to": "نورة"}"#, members: m), .navigate(.member("نورة")))
    }

    /// Safety words never reach the model; an unclear sentence with no model is "unknown", never a guess.
    func testKeywordsWinAndNothingIsGuessed() async {
        let parser = AssistantParser(resources: AssistantPrompt.Resources.load(Bundle(for: LiveOutingController.self)))
        let lying = FixedModel(#"{"intent": "radio", "action": "play"}"#)
        let sos = await parser.parse("تكفون فزعة غرزنا", members: [], destination: nil, model: lying)
        XCTAssertEqual(sos, .init(intent: .sosHelp, source: .keywords))
        let unclear = await parser.parse("احكي لي نكتة", members: [], destination: nil, model: nil)
        XCTAssertEqual(unclear.intent, .unknown)
        let broken = await parser.parse("احكي لي نكتة", members: [], destination: nil, model: FixedModel(nil))
        XCTAssertEqual(broken.intent, .unknown)
    }

    func testNormalisation() {
        XCTAssertEqual(AssistantText.normalize("أبو فَهد؟"), "ابو فهد")
        XCTAssertEqual(AssistantText.normalize("تردد ٣"), "تردد 3")
        XCTAssertEqual(AssistantText.member(in: "وين ابوفهد", members: ["أبو فهد", "سعود"]), "أبو فهد")
        XCTAssertEqual(AssistantText.member(in: "نوره وينها", members: ["نورة"]), "نورة")
        XCTAssertEqual(AssistantKeywords.channelNumber(["بدل", "التردد", "لاربعه"]), 4)
    }
}

final class AssistantAnswerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let me = LngLat(lng: 46.6744, lat: 24.7113)

    private func facts(_ presence: Policy.Freshness, ageMin: Double) -> AssistantFacts {
        var f = AssistantFacts(now: now)
        f.me = me
        f.others = [.init(id: "s", name: "سعود", position: LngLat(lng: 46.70, lat: 24.73), presence: presence,
                          atMs: now.timeIntervalSince1970 * 1000 - ageMin * 60_000)]
        return f
    }

    func testLiveMemberIsSaidLive() {
        let a = AssistantAnswers.answer(.membersWhere(who: "سعود"), facts(.live, ageMin: 0.2))
        XCTAssertTrue(a.text.contains("موقعه مباشر"), a.text)
        XCTAssertTrue(a.text.contains("كم"), a.text)
        XCTAssertFalse(a.stale)
        XCTAssertNil(a.detail)
    }

    func testStaleMemberIsNeverSaidLive() {
        for p in [Policy.Freshness.recent, .lost] {
            let a = AssistantAnswers.answer(.membersWhere(who: "سعود"), facts(p, ageMin: 12))
            XCTAssertTrue(a.stale)
            XCTAssertFalse(a.text.contains("مباشر"), a.text)
            XCTAssertTrue(a.text.contains("قبل ١٢ دقيقة"), a.text)
            XCTAssertTrue(a.text.contains("قديم"), a.text)
            XCTAssertEqual(a.detail, AssistantAnswers.staleNote)
        }
        /* The group answer's spoken summary picks the nearest LIVE one only. */
        var f = facts(.recent, ageMin: 30)
        f.others.append(.init(id: "n", name: "نورة", position: LngLat(lng: 46.80, lat: 24.80), presence: .live, atMs: now.timeIntervalSince1970 * 1000))
        let g = AssistantAnswers.answer(.membersWhere(who: nil), f)
        XCTAssertTrue(g.spoken.text.contains("أقربهم نورة"), g.spoken.text)
        XCTAssertTrue(g.stale)
    }

    func testNoPositionNoDistance() {
        var f = facts(.live, ageMin: 0)
        f.me = nil
        let a = AssistantAnswers.answer(.membersWhere(who: "سعود"), f)
        XCTAssertFalse(a.text.contains("كم"), a.text)
        XCTAssertTrue(a.text.contains("ما عندي موقعك"), a.text)
    }

    func testUnknownMemberAsksBack() {
        let a = AssistantAnswers.answer(.membersWhere(who: "خالد"), facts(.live, ageMin: 0))
        XCTAssertEqual(a.kind, .clarify)
        XCTAssertEqual(a.suggestions, ["وين سعود"])
    }

    func testRemainingUsesOnlyAppNumbersAndHisClipWhenItFits() {
        var f = facts(.live, ageMin: 0)
        f.destinationName = "روضة خريم"
        f.remaining = RemainingDistance(meters: 12_400, source: .navigation, navETA: nil)
        f.etaSeconds = 15 * 60
        let a = AssistantAnswers.answer(.tripRemaining, f)
        XCTAssertTrue(a.text.hasPrefix("باقي ١٢٫٤ كم على روضة خريم"), a.text)
        XCTAssertEqual(a.spoken, .clips(["eta_07"], text: "باقي ربع ساعة وتوصل."))
        f.etaSeconds = 23 * 60
        if case .system = AssistantAnswers.answer(.tripRemaining, f).spoken {} else { XCTFail("23 min has no clip: the system voice says it") }
        f.remaining = nil
        XCTAssertTrue(AssistantAnswers.answer(.tripRemaining, f).text.contains("ما عندي موقعك"))
        f.destinationName = nil
        XCTAssertTrue(AssistantAnswers.answer(.tripRemaining, f).text.contains("ما فيه وجهة"))
    }

    /// One voice per sentence: clips only from his catalogue, the rest the system voice.
    func testEveryClipAnswerUsesRecordedClipsOnly() {
        var f = facts(.live, ageMin: 0)
        f.destinationName = "روضة"
        f.remaining = RemainingDistance(meters: 5000, source: .navigation, navETA: nil)
        f.sunset = now.addingTimeInterval(3600)
        f.wayBackS = 1800
        f.rally = MapRallyPoint(position: me, label: "")
        f.chatAvailable = true
        f.hasBackTrail = true
        f.radio = .init(available: true, playing: true, muted: false, title: "إذاعة القرآن", canControl: true)
        let intents: [AssistantIntent] = [.tripRemaining, .sunset(.remaining), .sunset(.time), .sunset(.wayBack), .navigate(.back), .openChat,
                                          .radio(play: false), .rallyPoint, .sosHelp, .unknown]
        for d in [60.0, 15 * 60, 30 * 60, 3600] {
            f.etaSeconds = d
            for i in intents {
                if case let .clips(keys, _) = AssistantAnswers.answer(i, f).spoken {
                    XCTAssertFalse(keys.isEmpty)
                    for k in keys { XCTAssertNotNil(SaryVoiceCatalog.byKey[k], "\(k) is one of his clips") }
                }
            }
        }
        XCTAssertEqual(AssistantAnswers.answer(.sunset(.remaining), f).spoken, .clips(["sun_02"], text: "باقي ساعة على غروب الشمس."))
    }

    func testSunsetWayBackVerdict() {
        var f = AssistantFacts(now: now)
        f.sunset = now.addingTimeInterval(40 * 60)
        f.wayBackS = 60 * 60
        let a = AssistantAnswers.answer(.sunset(.wayBack), f)
        XCTAssertTrue(a.text.contains("ما تلحقون"), a.text)
        f.wayBackS = nil
        XCTAssertTrue(AssistantAnswers.answer(.sunset(.wayBack), f).text.contains("ما عندي مسار رجعة"))
        f.sunset = nil
        XCTAssertTrue(AssistantAnswers.answer(.sunset(.time), f).text.contains("بدون موقعك"))
    }

    func testRadioStopIsThisPhoneOnly() {
        var f = AssistantFacts(now: now)
        f.radio = .init(available: true, playing: true, muted: false, title: "x", canControl: true)
        XCTAssertEqual(AssistantAnswers.answer(.radio(play: false), f).action, .radioMute)
        f.radio.playing = false
        XCTAssertNil(AssistantAnswers.answer(.radio(play: false), f).action)
    }

    func testChannel() {
        var f = AssistantFacts(now: now)
        f.channelsAvailable = true
        f.currentChannel = "1"
        XCTAssertEqual(AssistantAnswers.answer(.setChannel(3), f).action, .setChannel("3"))
        XCTAssertNil(AssistantAnswers.answer(.setChannel(1), f).action)
        f.channelsAvailable = false
        XCTAssertNil(AssistantAnswers.answer(.setChannel(3), f).action)
    }
}

@MainActor
final class AssistantSOSTests: XCTestCase {
    /// Every utterance of both sets, and a pile of emergency phrasings: no answer has an action
    /// that could send SOS; SOS questions show the button and explain, with no action at all.
    func testNeverTriggersSOS() async throws {
        let parser = AssistantParser(resources: AssistantPrompt.Resources.load(Bundle(for: LiveOutingController.self)))
        let replay = try Replay.load()
        let m = ReplayModel(replay.models[AssistantModelSpec.current.id]?.outputs ?? [:])
        var texts = try UtteranceSet.load("assistant-utterances").cases.map(\.text) + UtteranceSet.load("assistant-utterances-holdout").cases.map(\.text)
        texts += ["ارسل SOS الحين", "اضغط زر الطوارئ عني", "فزعة فزعة", "سو استغاثة", "صار لنا حادث", "اتصل بالاسعاف", "طوارئ طوارئ", "emergency"]
        var f = AssistantFacts(now: Date())
        f.others = [.init(id: "s", name: "سعود", position: LngLat(lng: 46.7, lat: 24.7), presence: .live, atMs: Date().timeIntervalSince1970 * 1000)]
        for t in texts {
            let r = await parser.parse(t, members: ["أبو فهد", "سعود", "نورة", "محمد", "عبدالله"], destination: "روضة خريم", model: m)
            let a = AssistantAnswers.answer(r.intent, f)
            XCTAssertFalse(a.action?.triggersSOS ?? false, t)
            if r.intent == .sosHelp {
                XCTAssertNil(a.action, t)
                XCTAssertTrue(a.showsSOSButton, t)
            }
        }
        for t in ["ارسل SOS الحين", "اضغط زر الطوارئ عني", "فزعة فزعة", "صار لنا حادث"] {
            let r = await parser.parse(t, members: [], destination: nil, model: m)
            XCTAssertEqual(r.intent, .sosHelp, t)
        }
    }

    /// The controller end to end: an SOS question performs nothing.
    func testControllerPerformsNothingForSOS() async throws {
        let c = AssistantController(facts: { AssistantFacts(now: Date()) }, store: AssistantModelStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), defaults: UserDefaults(suiteName: UUID().uuidString)!),
                                    model: FixedModel(nil), resources: AssistantPrompt.Resources.load(Bundle(for: LiveOutingController.self)))
        c.speaksAnswers = false
        var performed: [AssistantAction] = []
        c.perform = { performed.append($0) }
        c.ask("ارسل استغاثة للربع")
        for _ in 0..<50 { if case .answered = c.phase { break }; try await Task.sleep(nanoseconds: 20_000_000) }
        guard case let .answered(_, a) = c.phase else { return XCTFail("no answer") }
        XCTAssertTrue(a.showsSOSButton)
        XCTAssertTrue(performed.isEmpty)
        c.speaksAnswers = true
    }
}

private final class FakeDownloader: AssistantDownloader {
    var file: URL?
    var error: Error?
    var cancelled = false
    var started: (() -> Void)?
    private var done: ((Result<URL, Error>) -> Void)?
    func start(_ url: URL, allowCellular: Bool, progress: @escaping (Double) -> Void, done: @escaping (Result<URL, Error>) -> Void) {
        self.done = done
        progress(0.5)
        started?()
    }
    func finish() {
        if let error { done?(.failure(error)) } else if let file { done?(.success(file)) }
    }
    func cancel() { cancelled = true }
}

@MainActor
final class AssistantDownloadTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("asst-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func tmpFile(_ s: String) throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("asst-dl-\(UUID().uuidString)")
        try Data(s.utf8).write(to: u)
        return u
    }

    private func spec(for s: String) -> AssistantModelSpec {
        AssistantModelSpec(id: "t", title: "t", url: URL(string: "https://huggingface.co/x")!,
                           sha256: AssistantModelStore.sha256(of: try! tmpFile(s))!, bytes: Int64(s.utf8.count), license: "Apache-2.0")
    }

    func testSHA256IsTheStandardOne() throws {
        XCTAssertEqual(AssistantModelStore.sha256(of: try tmpFile("abc")), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testChosenModelIsFromTheOfficialRepoWithAChecksum() {
        let s = AssistantModelSpec.current
        XCTAssertEqual(s.url.host, "huggingface.co")
        XCTAssertTrue(s.url.path.hasPrefix("/Qwen/"))
        XCTAssertEqual(s.sha256.count, 64)
        XCTAssertEqual(s.license, "Apache-2.0")
        XCTAssertGreaterThan(s.bytes, 100_000_000)
    }

    func testInstallVerifiesSizeAndHashAndExcludesBackup() throws {
        let sp = spec(for: "model-bytes")
        let dest = dir.appendingPathComponent(sp.fileName)
        XCTAssertNil(AssistantModelStore.install(try tmpFile("model-bytes"), spec: sp, into: dir, as: dest))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path))
        XCTAssertEqual(try dest.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        XCTAssertEqual(try dir.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        XCTAssertTrue(dir.path.contains("tmp") || dir.path.contains("Application Support"))
        XCTAssertTrue(AssistantModelStore.defaultDirectory.path.contains("Application Support"))
    }

    func testWrongHashOrSizeIsRejectedAndDeleted() throws {
        let sp = spec(for: "model-bytes")
        let dest = dir.appendingPathComponent(sp.fileName)
        let bad = try tmpFile("model-bytez")
        XCTAssertEqual(AssistantModelStore.install(bad, spec: sp, into: dir, as: dest), .checksum)
        XCTAssertFalse(FileManager.default.fileExists(atPath: bad.path), "the bad download is deleted")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))
        let short = try tmpFile("model")
        XCTAssertEqual(AssistantModelStore.install(short, spec: sp, into: dir, as: dest), .size(5))
    }

    func testStoreFlowDownloadVerifyReadyCancelDelete() async throws {
        let sp = spec(for: "weights")
        let dl = FakeDownloader()
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = AssistantModelStore(spec: sp, directory: dir, downloader: dl, defaults: defaults)
        XCTAssertEqual(store.state, .notDownloaded)
        XCTAssertNil(store.modelURL)
        dl.file = try tmpFile("weights")
        store.download(allowCellular: false)
        XCTAssertEqual(store.state, .downloading(0))
        dl.finish()
        for _ in 0..<100 where store.state != .ready { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(store.state, .ready)
        XCTAssertTrue(store.enabled)
        XCTAssertEqual(store.modelURL, store.fileURL)
        store.enabled = false
        XCTAssertNil(store.modelURL, "switched off: the model is not used")
        store.delete()
        XCTAssertEqual(store.state, .notDownloaded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))

        /* Cancel mid-way: back to not downloaded, and a late file is dropped. */
        let late = try tmpFile("weights")
        dl.file = late
        store.download(allowCellular: true)
        store.cancel()
        XCTAssertTrue(dl.cancelled)
        XCTAssertEqual(store.state, .notDownloaded)
        dl.finish()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(store.state, .notDownloaded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: late.path))

        /* A tampered file fails with the checksum message. */
        dl.file = try tmpFile("weightz")
        store.download(allowCellular: false)
        dl.finish()
        for _ in 0..<100 { if case .failed = store.state { break }; try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(store.state, .failed(AssistantModelStore.InstallError.checksum.text))
        XCTAssertNil(store.modelURL)
    }
}
