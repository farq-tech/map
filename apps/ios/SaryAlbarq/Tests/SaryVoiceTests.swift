import AVFoundation
import XCTest
@testable import SaryAlbarq

/// «صوت سرى»: every recorded clip decodes, and every spoken line maps to clips from
/// the maneuver itself (no names, never half clips and half device voice).
final class SaryVoiceClipsTests: XCTestCase {
    func testManifestIsInTheBundleAndEveryClipDecodes() throws {
        let entries = SaryVoiceCatalog.entries
        XCTAssertEqual(entries.count, 226, "the owner's 226 phrases")
        XCTAssertEqual(Set(entries.map(\.key)).count, entries.count, "keys are unique")
        XCTAssertEqual(Set(entries.map(\.file)).count, entries.count, "files are unique")
        var rate: Double?
        for e in entries {
            let u = try XCTUnwrap(SaryVoiceCatalog.url(e.key), e.file)
            let f = try AVAudioFile(forReading: u)
            XCTAssertGreaterThan(f.length, 2000, "\(e.file) has sound")
            XCTAssertEqual(f.fileFormat.channelCount, 1, e.file)
            if let r = rate { XCTAssertEqual(f.fileFormat.sampleRate, r, e.file) }
            rate = f.fileFormat.sampleRate
            let d = try SaryClipPlayer.decode(u)
            XCTAssertEqual(d.samples.count, Int(f.length), e.file)
            XCTAssertGreaterThan(Double(d.samples.count) / 44100, 0.1, "\(e.file) longer than 0.1 s")
            XCTAssertGreaterThan(d.samples.map(abs).max() ?? 0, 0.01, "\(e.file) is not silent")
            let clipped = d.samples.filter { abs($0) >= 0.999 }.count
            XCTAssertLessThan(Double(clipped) / Double(d.samples.count), 0.002, "\(e.file) is not clipped")
        }
        XCTAssertEqual(rate, 44100)
    }

    /// Asset linter for the ElevenLabs v4 set: every manifest key has its own file that decodes,
    /// 44.1 kHz mono, > 0.1 s, no duplicate key / file / audio, and the loudness is uniform
    /// (-16 ±0.5 LUFS integrated, ITU-R BS.1770 K-weighted and gated; sample peak ≤ -1.5 dBFS —
    /// true peak after oversampling is checked by `scripts/sary-voice-lint.py`).
    func testAssetLinterLoudnessIsUniform() throws {
        let entries = SaryVoiceCatalog.entries
        XCTAssertEqual(entries.count, 226)
        XCTAssertEqual(Set(entries.map(\.key)).count, entries.count, "duplicate key")
        XCTAssertEqual(Set(entries.map(\.file)).count, entries.count, "duplicate file")
        for e in entries { XCTAssertEqual(e.file, e.key + ".m4a", "file is named after its key") }
        var seen: [Data: String] = [:]
        var lufs: [Double] = []
        for e in entries {
            let u = try XCTUnwrap(SaryVoiceCatalog.url(e.key), "\(e.key): missing file")
            let f = try AVAudioFile(forReading: u)
            XCTAssertEqual(f.fileFormat.sampleRate, 44100, e.file)
            XCTAssertEqual(f.fileFormat.channelCount, 1, e.file)
            let x = try SaryClipPlayer.decode(u).samples
            XCTAssertGreaterThan(Double(x.count) / 44100, 0.1, e.file)
            let bytes = try Data(contentsOf: u)
            XCTAssertNil(seen[bytes], "\(e.file) is the same audio as \(seen[bytes] ?? "")")
            seen[bytes] = e.file
            let l = Loudness.integratedLUFS(x, sampleRate: 44100)
            lufs.append(l)
            XCTAssertEqual(l, -16, accuracy: 0.5, "\(e.file): \(l) LUFS")
            let peak = 20 * log10(Double(x.map(abs).max() ?? 0))
            XCTAssertLessThanOrEqual(peak, -1.5, "\(e.file): sample peak \(peak) dBFS")
        }
        XCTAssertLessThanOrEqual((lufs.max() ?? 0) - (lufs.min() ?? 0), 1.0, "spread across the set")
    }

    /// The composer relies on what some clips MEAN; the v4 wording changed, the meaning must not.
    func testKeysTheComposerReliesOnStillMeanTheSame() {
        let t = { (k: String) in SaryVoiceCatalog.byKey[k]?.text ?? "<missing \(k)>" }
        XCTAssertEqual(t("turns_14"), "وبعدها،", "the «then» connector")
        XCTAssertEqual(t("start_01"), "بسم الله نبدأ.", "auto start")
        XCTAssertEqual(t("dist_15"), "الحين،")
        XCTAssertEqual(t("start_09"), "وقفنا التوجيه.")
        XCTAssertEqual(t("turns_01"), "لف يمين.")
        XCTAssertEqual(t("turns_02"), "لف يسار.")
        XCTAssertTrue(t("turns_07").hasPrefix("ديور وارجع"), "u-turn")
        XCTAssertTrue(t("x_02").hasPrefix("ديور بالدوّار"), "all the way round")
        XCTAssertTrue(t("turns_03").contains("الخفيفة يمين") && t("turns_04").contains("الخفيفة يسار"), "slight")
        XCTAssertTrue(t("mv_03").contains("يمين بقوّة") && t("mv_04").contains("يسار بقوّة"), "sharp")
        XCTAssertEqual(t("mv_02"), "كمّل سيده.", "straight / farther than recorded")
        /* Arrival sides: the destination vs a stop on the way. */
        XCTAssertEqual(t("start_04"), "وجهتك على يمينك.")
        XCTAssertEqual(t("start_05"), "وجهتك على يسارك.")
        XCTAssertEqual(t("start_06"), "وجهتك قدّامك.")
        XCTAssertEqual(t("x_03"), "على يمينك.")
        XCTAssertEqual(t("x_04"), "على يسارك.")
        XCTAssertTrue(t("arr_01").hasPrefix("وصلتوا") && t("arr_02").hasPrefix("وصلت وجهتك"))
        XCTAssertTrue(t("start_07").contains("التجمّع"), "rally point")
        /* Off-road leads: no road at the start vs the road ended. */
        XCTAssertTrue(t("dir_06").hasPrefix("ما فيه طريق مزفلت"))
        XCTAssertTrue(t("dir_05").hasPrefix("انتهى الطريق"))
        XCTAssertTrue(t("dir_07").hasPrefix("ما فيه درب"))
        for (k, side) in [("turns_12", "اليمين"), ("turns_13", "اليسار"), ("mv_06", "اليمين"), ("mv_07", "اليسار"), ("mv_09", "اليمين"), ("mv_10", "اليسار"), ("mv_13", "اليمين"), ("mv_14", "اليسار"), ("mv_15", "يمين"), ("mv_16", "يسار"), ("mv_18", "اليمين"), ("mv_19", "اليسار")] {
            XCTAssertTrue(t(k).contains(side), "\(k) «\(t(k))» is about \(side)")
        }
        for (k, dir) in [("bar_02", "شمال"), ("bar_03", "جنوب"), ("bar_04", "شرق"), ("bar_05", "غرب"), ("dir_01", "شمال شرق"), ("dir_02", "شمال غرب"), ("dir_03", "جنوب شرق"), ("dir_04", "جنوب غرب")] {
            XCTAssertEqual(t(k), "توجّه \(dir).")
        }
        for d in SaryVoiceScript.distances + SaryVoiceScript.imperial { XCTAssertTrue(t(d.key).hasPrefix("بعد "), d.key) }
    }

    func testComposeJoinsClipsWithAShortGap() throws {
        let a = try SaryClipPlayer.decode(XCTUnwrap(SaryVoiceCatalog.url("dist_05")))
        let b = try SaryClipPlayer.decode(XCTUnwrap(SaryVoiceCatalog.url("turns_01")))
        let line = try SaryClipPlayer.compose(["dist_05", "turns_01"])
        XCTAssertEqual(line.sampleRate, 44100)
        let ta = SaryClipPlayer.joinTrimmed(a.samples, head: false, tail: true)
        let tb = SaryClipPlayer.joinTrimmed(b.samples, head: true, tail: false)
        XCTAssertLessThan(ta.count, a.samples.count, "the pad at the join is cut")
        XCTAssertGreaterThanOrEqual(ta.count, a.samples.count - Int(SaryClipPlayer.padS * 44100), "never more than the pad")
        XCTAssertEqual(Array(ta.prefix(1000)), Array(a.samples.prefix(1000)), "the outer edge of the line keeps its pad")
        let gap = line.samples.count - ta.count - tb.count
        XCTAssertEqual(Double(gap) / 44100, SaryClipPlayer.gapS, accuracy: 0.001)
        XCTAssertTrue((0.03...0.06).contains(SaryClipPlayer.gapS), "30–60 ms of silence, no crossfade")
        XCTAssertEqual(Array(line.samples[ta.count..<(ta.count + gap)]), [Float](repeating: 0, count: gap))
        XCTAssertThrowsError(try SaryClipPlayer.compose(["dist_05", "nope_99"]), "a missing clip: nothing, not half a line") { e in
            XCTAssertEqual(e as? SaryClipPlayer.ComposeError, .missing("nope_99"), "named Missing, never another clip")
        }
    }

    /// The silence heard at each join (below -50 dBFS, 2 ms windows) stays short: one flowing line.
    func testJoinsInsideALineAreShortAndSmooth() throws {
        let combos: [[String]] = [["dist_05", "turns_01"], ["dist_15", "turns_02"], ["turns_01", "turns_14", "turns_02"]]
        let thr = Float(pow(10.0, -50.0 / 20)), w = 88
        for keys in combos {
            let x = try SaryClipPlayer.compose(keys).samples
            let n = x.count / w
            let silent = (0..<n).map { i -> Bool in
                var e: Float = 0
                for j in (i * w)..<((i + 1) * w) { e += x[j] * x[j] }
                return (e / Float(w)).squareRoot() <= thr
            }
            /* Interior only: the outer pads of the line are kept on purpose. */
            guard let first = silent.firstIndex(of: false), let last = silent.lastIndex(of: false) else { return XCTFail("\(keys) silent") }
            var longest = 0, run = 0
            for s in silent[first...last] { run = s ? run + 1 : 0; longest = max(longest, run) }
            let ms = Double(longest * w) / 44.1
            XCTAssertLessThanOrEqual(ms, 120, "\(keys): \(ms) ms of silence at a join")
            XCTAssertGreaterThanOrEqual(ms, SaryClipPlayer.gapS * 1000 - 2, "\(keys): a real gap, no overlap")
            let pad = Double(silent.prefix(while: { $0 }).count * w) / 44.1
            XCTAssertGreaterThanOrEqual(pad, 70, "\(keys): the line's own leading pad stays")
        }
    }

    func testEachClipHasAMicroFadeNotACrossfade() throws {
        let raw = try SaryClipPlayer.decode(XCTUnwrap(SaryVoiceCatalog.url("turns_01"))).samples
        let line = try SaryClipPlayer.compose(["turns_01"]).samples
        XCTAssertEqual(line.count, raw.count, "a fade changes no length (no overlap)")
        XCTAssertTrue((0.005...0.010).contains(SaryClipPlayer.fadeS), "5–10 ms")
        XCTAssertEqual(line.first ?? 1, 0, accuracy: 1e-6)
        XCTAssertEqual(line.last ?? 1, 0, accuracy: 1e-6)
        let n = Int(SaryClipPlayer.fadeS * 44100)
        let mid = raw.count / 2
        XCTAssertEqual(line[mid], raw[mid], "the middle is untouched")
        XCTAssertEqual(line[n + 10], raw[n + 10])
    }

    /// Every clip any line can ask for is really there.
    func testEveryScriptedClipExists() {
        let kinds: [NavManeuverKind] = [.depart, .turn, .continue, .newName, .merge, .onRamp, .offRamp, .fork, .endOfRoad, .useLane, .roundabout, .exitRoundabout, .notification, .arrive]
        let dirs: [NavTurnDirection?] = [nil, .sharpRight, .right, .slightRight, .straight, .slightLeft, .left, .sharpLeft, .uTurn]
        var keys = Set<String>()
        for k in kinds { for d in dirs { for e in [nil, 1, 5, 9, 12] as [Int?] {
            for m in [0.0, 25, 80, 260, 950, 1800, 12_000, 300_000] {
                let s = NavStep(maneuver: .init(kind: k, direction: d, exit: e), roadName: "طريق الملك فهد", location: .init(lng: 0, lat: 0), distanceM: 0, durationS: 0)
                let line = SaryVoiceScript.step(s, distanceM: m)
                XCTAssertFalse(line.isEmpty, "\(k) \(String(describing: d)) exit \(String(describing: e)) at \(m) m has a line")
                keys.formUnion(line)
                keys.formUnion(SaryVoiceScript.step(s, distanceM: m, auto: true, stop: true, miles: true))
            }
        } } }
        keys.formUnion(SaryVoiceScript.distances.map(\.key))
        keys.formUnion(SaryVoiceScript.imperial.map(\.key))
        for b in stride(from: 0.0, to: 360, by: 15) { keys.insert(SaryVoiceScript.compass(b)) }
        keys.formUnion(["rr_01", "rr_05", "rr_06", "bar_01", "dir_05", "dir_06", "dir_07", "grp_14", "start_01", "start_02"])
        for t in [-600.0, 600, 1800, 3600, 7200] as [Double] { for w in [1200.0, 3600, 9000] as [Double] {
            keys.formUnion(SunsetWarning.saryClips(toSunsetS: t, wayBackS: w))
        } }
        for k in keys { XCTAssertNotNil(SaryVoiceCatalog.url(k), k) }
    }
}

final class SaryVoiceScriptTests: XCTestCase {
    private var milesBefore = false

    override func setUp() {
        milesBefore = DistanceUnits.miles
        DistanceUnits.miles = false
    }

    override func tearDown() {
        DistanceUnits.miles = milesBefore
    }

    private func step(_ k: NavManeuverKind, _ d: NavTurnDirection? = nil, exit: Int? = nil, road: String? = nil) -> NavStep {
        NavStep(maneuver: .init(kind: k, direction: d, exit: exit), roadName: road, location: .init(lng: 46.67, lat: 24.71), distanceM: 0, durationS: 0)
    }

    func testTurns() {
        XCTAssertEqual(SaryVoiceScript.step(step(.turn, .right), distanceM: 300), ["dist_05", "turns_01"], "«بعد ثلاث مية متر.» «لف يمين.»")
        XCTAssertEqual(SaryVoiceScript.step(step(.turn, .left), distanceM: 0), ["turns_02"], "right here: just the action")
        XCTAssertEqual(SaryVoiceScript.action(.init(kind: .turn, direction: .slightRight)), ["turns_03"])
        XCTAssertEqual(SaryVoiceScript.action(.init(kind: .turn, direction: .slightLeft)), ["turns_04"])
        XCTAssertEqual(SaryVoiceScript.action(.init(kind: .turn, direction: .sharpRight)), ["mv_03"])
        XCTAssertEqual(SaryVoiceScript.action(.init(kind: .turn, direction: .sharpLeft)), ["mv_04"])
        XCTAssertEqual(SaryVoiceScript.action(.init(kind: .turn, direction: .uTurn)), ["turns_07"])
        XCTAssertEqual(SaryVoiceScript.action(.init(kind: .continue, direction: .straight)), ["mv_02"])
        XCTAssertEqual(SaryVoiceScript.action(.init(kind: .depart, direction: nil)), ["mv_01"])
    }

    func testRampsForksMergesLanesEndOfRoad() {
        XCTAssertEqual(SaryVoiceScript.action(.init(kind: .onRamp, direction: .right)), ["mv_09"])
        XCTAssertEqual(SaryVoiceScript.action(.init(kind: .onRamp, direction: nil)), ["mv_08"])
        XCTAssertEqual(SaryVoiceScript.action(.init(kind: .offRamp, direction: .slightLeft)), ["turns_13"])
        XCTAssertEqual(SaryVoiceScript.action(.init(kind: .fork, direction: .left)), ["mv_07"])
        XCTAssertEqual(SaryVoiceScript.action(.init(kind: .fork, direction: .straight)), ["mv_05"])
        XCTAssertEqual(SaryVoiceScript.action(.init(kind: .merge, direction: .right)), ["mv_13"])
        XCTAssertEqual(SaryVoiceScript.action(.init(kind: .useLane, direction: .left)), ["mv_19"])
        XCTAssertEqual(SaryVoiceScript.action(.init(kind: .useLane, direction: nil)), ["mv_17"])
        XCTAssertEqual(SaryVoiceScript.action(.init(kind: .endOfRoad, direction: .right)), ["mv_15"])
        XCTAssertEqual(SaryVoiceScript.action(.init(kind: .endOfRoad, direction: .left)), ["mv_16"])
    }

    func testRoundaboutExitsOneToNine() {
        for e in 1...9 {
            XCTAssertEqual(SaryVoiceScript.action(.init(kind: .roundabout, direction: nil, exit: e)), ["rb_\(String(format: "%02d", e + 1))"])
            let text = SaryVoiceCatalog.byKey["rb_\(String(format: "%02d", e + 1))"]?.text ?? ""
            XCTAssertTrue(text.hasPrefix("في الدوّار، خذ المخرج \(NavText.ordinal(e))"), text)
        }
        XCTAssertEqual(SaryVoiceScript.action(.init(kind: .roundabout, direction: nil, exit: nil)), ["round_01"])
        XCTAssertEqual(SaryVoiceScript.action(.init(kind: .roundabout, direction: nil, exit: 11)), ["round_01"], "past nine: «ادخل الدوّار»")
        XCTAssertEqual(SaryVoiceScript.action(.init(kind: .exitRoundabout, direction: nil)), ["rb_01"])
        XCTAssertEqual(SaryVoiceScript.action(.init(kind: .roundabout, direction: .uTurn, exit: 4)), ["x_02"], "«ديور بالدوّار وارجع.»")
        XCTAssertEqual(SaryVoiceScript.step(step(.roundabout, exit: 3), distanceM: 200), ["dist_04", "rb_04"])
    }

    func testDistancesRoundDownToRecordedRoundNumbers() {
        /* Build 22: rounded DOWN — never a distance larger than the real one (75 m said «بعد مية»). */
        let cases: [(Double, String?)] = [
            (10, nil), (29, nil), (30, "m_07"), (48, "m_07"), (120, "dist_02"), (140, "dist_02"), (280, "m_02"),
            (330, "dist_05"), (380, "dist_05"), (640, "m_03"), (980, "m_05"), (1240, "dist_09"), (1300, "dist_09"),
            (2400, "dist_11"), (3600, "km_19"), (4200, "km_01"), (11_000, "dist_14"), (13_000, "x_13"), (14_000, "x_13"), (35_900, "x_14"), (45_200, "x_15"), (47_600, "x_15"),
            (87_000, "km_14"), (95_000, "km_14"), (199_000, "km_16"), (230_000, nil),
        ]
        for (m, k) in cases { XCTAssertEqual(SaryVoiceScript.distance(m), k, "\(m) m") }
        /* Every recorded value maps to itself. */
        for d in SaryVoiceScript.distances where d.m >= SaryVoiceScript.nowM { XCTAssertEqual(SaryVoiceScript.distance(d.m), d.key, "\(d.m)") }
        /* And the clip says what it means. */
        XCTAssertEqual(SaryVoiceScript.distance(25), nil, "«بعد عشرين متر» is right here: just the action")
        XCTAssertEqual(SaryVoiceCatalog.byKey["dist_05"]?.text, "بعد ثلاث مية متر.")
        XCTAssertEqual(SaryVoiceCatalog.byKey["km_06"]?.text, "بعد خمسطعش كيلو.")
    }

    func testMilesAndFeetWhenTheUnitIsMiles() {
        let cases: [(Double, String?)] = [
            (60, nil), (120, nil), (160, "x_11"), (290, "x_11"), (310, "x_12"), (420, "x_07"), (760, "x_07"), (810, "x_06"), (1500, "x_06"), (1610, "x_05"), (2900, "x_05"),
            (3300, "x_08"), (6000, "x_08"), (8100, "x_09"), (14_000, "x_09"), (16_100, "x_10"), (30_000, nil),
        ]
        for (m, k) in cases { XCTAssertEqual(SaryVoiceScript.distance(m, miles: true), k, "\(m) m in miles") }
        XCTAssertEqual(SaryVoiceScript.step(step(.turn, .left), distanceM: 1610, miles: true), ["x_05", "turns_02"], "«بعد ميل.» «لف يسار.»")
        XCTAssertEqual(SaryVoiceScript.step(step(.turn, .left), distanceM: 40_000, miles: true), ["mv_02"])
        XCTAssertEqual(SaryVoiceCatalog.byKey["x_12"]?.text, "بعد ألف قدم.")
    }

    // MARK: simulated routes

    func testRightThenLeftWithin100mSaysThenWhenThereIsTime() {
        let right = step(.turn, .right), left = step(.turn, .left)
        var r = right
        r.distanceM = 80
        let line = SaryVoiceScript.withThen(SaryVoiceScript.step(r, distanceM: 300), next: left, gapM: r.distanceM, distanceToManeuverM: 300, speedMps: 10)
        XCTAssertEqual(line, ["dist_05", "turns_01", "turns_14", "turns_02"], "«بعد ثلاث مية متر. لف يمين. وبعدها، لف يسار.»")
        let late = SaryVoiceScript.withThen(SaryVoiceScript.step(r, distanceM: 40), next: left, gapM: 80, distanceToManeuverM: 40, speedMps: 20)
        XCTAssertFalse(late.contains("turns_14"))
        let far = SaryVoiceScript.withThen(["dist_05", "turns_01"], next: left, gapM: 600, distanceToManeuverM: 300, speedMps: 10)
        XCTAssertEqual(far, ["dist_05", "turns_01"], "the next turn is not close: no «وبعدها،»")
    }

    func testCueBandsFollowSpeed() {
        XCTAssertEqual(NavCueBands.distances(speedMps: 12 / 3.6, unpaved: true), [175, 60, 15], "desert track")
        XCTAssertEqual(NavCueBands.distances(speedMps: 35 / 3.6, unpaved: true), [550, 200, 50], "dirt road")
        XCTAssertEqual(NavCueBands.distances(speedMps: 40 / 3.6, unpaved: false), [300, 125, 25], "city")
        XCTAssertEqual(NavCueBands.distances(speedMps: 110 / 3.6, unpaved: false), [2000, 500, 150], "highway at 110: ~110 s ahead, capped at 2 km")
        XCTAssertEqual(NavCueBands.distances(speedMps: 85 / 3.6, unpaved: false)[0], 2000)
        XCTAssertEqual(NavCueBands.distances(speedMps: 8 / 3.6, unpaved: true), [175, 60, 15], "desert at walking pace: at the point")
        let b = NavCueBands.distances(speedMps: 110 / 3.6, unpaved: false)
        XCTAssertEqual(NavCueBands.stage(distanceM: 1900, bands: b), .early)
        XCTAssertEqual(NavCueBands.stage(distanceM: 520, bands: b), .confirm)
        XCTAssertEqual(NavCueBands.stage(distanceM: 140, bands: b), .immediate)
    }

    func testSharpTurnOnADirtRoad() {
        let b = NavCueBands.distances(speedMps: 30 / 3.6, unpaved: true)
        XCTAssertEqual(b.map { SaryVoiceScript.step(step(.turn, .sharpRight), distanceM: $0) },
                       [["dist_07", "mv_03"], ["dist_04", "mv_03"], ["dist_01", "mv_03"]], "550 m reads «500 m» on the banner too")
    }

    func testForkAndRoundaboutsOnARoute() {
        XCTAssertEqual(SaryVoiceScript.step(step(.fork, .slightRight), distanceM: 500), ["dist_07", "mv_06"])
        XCTAssertEqual(SaryVoiceScript.step(step(.roundabout, exit: 3), distanceM: 150), ["dist_03", "rb_04"])
        XCTAssertEqual(SaryVoiceScript.step(step(.roundabout, exit: 9), distanceM: 0), ["rb_10"])
    }

    func testRoundaboutLastExitPastNineAndUTurn() {
        XCTAssertEqual(SaryVoiceScript.step(step(.roundabout, exit: 3), distanceM: 0), ["rb_04"], "exit 3")
        XCTAssertEqual(SaryVoiceScript.step(step(.roundabout, exit: 9), distanceM: 250), ["m_02", "rb_10"], "exit 9")
        var last = step(.roundabout, exit: 5)
        last.maneuver.lastExit = true
        XCTAssertEqual(SaryVoiceScript.step(last, distanceM: 100), ["dist_02", "x_01"], "«خذ آخر مخرج.»")
        XCTAssertEqual(SaryVoiceCatalog.byKey["x_01"]?.text, "خذ آخر مخرج.")
        XCTAssertEqual(SaryVoiceScript.step(step(.roundabout, exit: 12), distanceM: 100), ["dist_02", "round_01"], "past nine, not the last: «ادخل الدوّار.» only")
        var lastTwelve = step(.roundabout, exit: 12)
        lastTwelve.maneuver.lastExit = true
        XCTAssertEqual(SaryVoiceScript.action(lastTwelve.maneuver), ["x_01"], "the last one even past nine")
        XCTAssertEqual(SaryVoiceScript.action(.init(kind: .roundabout, direction: .uTurn, exit: 6, lastExit: true)), ["x_02"], "«ديور بالدوّار وارجع.»")
    }

    func testFartherThanRecordedSaysKeepGoingNotTheTurn() {
        XCTAssertEqual(SaryVoiceScript.step(step(.turn, .right), distanceM: 400_000), ["mv_02"])
    }

    func testArrival() {
        XCTAssertEqual(SaryVoiceScript.step(step(.arrive), distanceM: 10), ["arr_02"], "«وصلت وجهتك.»")
        XCTAssertEqual(SaryVoiceScript.step(step(.arrive), distanceM: 10, auto: true), ["arr_01"], "«وصلتوا، الله يحيّيكم.»")
        XCTAssertEqual(SaryVoiceScript.step(step(.arrive), distanceM: 500), ["dist_07", "start_06"], "«بعد خمس مية متر.» «وجهتك قدّامك.»")
        XCTAssertEqual(SaryVoiceScript.step(step(.arrive, .right), distanceM: 10), ["start_04"], "«وجهتك على يمينك.»")
        XCTAssertEqual(SaryVoiceScript.step(step(.arrive, .left), distanceM: 200), ["dist_04", "start_05"])
        XCTAssertEqual(SaryVoiceScript.step(step(.arrive, .right), distanceM: 100, stop: true), ["dist_02", "x_03"], "a stop: «على يمينك»")
        XCTAssertEqual(SaryVoiceScript.step(step(.arrive, .left), distanceM: 5, stop: true), ["x_04"])
    }

    func testOffRoadArrow() {
        XCTAssertEqual(SaryVoiceScript.compass(0), "bar_02")
        XCTAssertEqual(SaryVoiceScript.compass(44), "dir_01")
        XCTAssertEqual(SaryVoiceScript.compass(90), "bar_04")
        XCTAssertEqual(SaryVoiceScript.compass(180), "bar_03")
        XCTAssertEqual(SaryVoiceScript.compass(225), "dir_04")
        XCTAssertEqual(SaryVoiceScript.compass(-45), "dir_02")
        XCTAssertEqual(SaryVoiceScript.arrow(lead: "dir_06", bearing: 90, distanceM: 3000), ["dir_06", "bar_04", "dist_12", "start_06"])
        XCTAssertEqual(SaryVoiceScript.arrow(lead: "dir_05", bearing: 180, distanceM: 10), ["dir_05", "bar_03"])
    }

    /// A street name is on the banner and in the device voice, never in the owner's voice.
    func testStreetNameIsNotSaidInSaryVoice() {
        let s = step(.turn, .right, road: "طريق الملك فهد")
        XCTAssertTrue(NavText.spoken(s, distanceM: 300).contains("طريق الملك فهد"), "the device voice says it")
        XCTAssertEqual(SaryVoiceScript.step(s, distanceM: 300), ["dist_05", "turns_01"], "«صوت سرى» says the turn without it")
        let a = step(.arrive)
        XCTAssertTrue(NavText.spoken(a, distanceM: 5, targetName: "مخيم النفود").contains("مخيم النفود"))
        XCTAssertEqual(SaryVoiceScript.step(a, distanceM: 5), ["arr_02"])
    }

    func testMilesModeRoundsLikeTheBanner() {
        XCTAssertEqual(SaryVoiceScript.step(step(.roundabout, exit: 2), distanceM: 800, miles: true), ["x_06", "rb_03"], "«بعد نص ميل» exit 2")
        XCTAssertEqual(SaryVoiceScript.step(step(.arrive, .right), distanceM: 300, miles: true), ["x_12", "start_04"], "«بعد ألف قدم.» «وجهتك على يمينك.»")
        XCTAssertEqual(SaryVoiceScript.step(step(.turn, .right), distanceM: 50, miles: true), ["turns_01"], "too close for feet: just the turn")
    }

    func testSunsetLines() {
        XCTAssertEqual(SunsetWarning.saryClips(toSunsetS: 61 * 60, wayBackS: 47 * 60), ["sun_02", "sun_08", "sun_01"])
        XCTAssertEqual(SunsetWarning.saryClips(toSunsetS: 30 * 60, wayBackS: 25 * 60), ["sun_03", "sun_07", "sun_01"])
        XCTAssertEqual(SunsetWarning.saryClips(toSunsetS: 15 * 60, wayBackS: 130 * 60), ["sun_04", "sun_09", "sun_01"])
        XCTAssertEqual(SunsetWarning.saryClips(toSunsetS: 120 * 60, wayBackS: 110 * 60), ["sun_09", "sun_01"])
        XCTAssertEqual(SunsetWarning.saryClips(toSunsetS: -5 * 60, wayBackS: 40 * 60), ["sun_05", "sun_07", "sun_06"])
    }
}

@MainActor
final class SaryVoicePlaybackTests: XCTestCase {
    private var mutedBefore: Any?

    override func setUp() async throws {
        mutedBefore = UserDefaults.standard.object(forKey: NavVoice.muteKey)
    }

    override func tearDown() async throws {
        if let m = mutedBefore { UserDefaults.standard.set(m, forKey: NavVoice.muteKey) } else { UserDefaults.standard.removeObject(forKey: NavVoice.muteKey) }
    }

    func testDefaultIsSaryVoice() {
        XCTAssertEqual(NavVoiceChoice.current(UserDefaults(suiteName: "sary.voice.test.\(UUID())")!), .sary)
        XCTAssertEqual(NavVoiceChoice.allCases.map(\.label), ["صوت سرى", "صوت الجهاز"])
    }

    func testSaryVoicePlaysClipsAndDeviceVoiceTheText() {
        let v = NavVoice()
        v.muted = false
        v.choice = { .sary }
        v.say("بعد ٣٠٠ متر، انعطف يمينًا إلى طريق الملك فهد", clips: ["dist_05", "turns_01"])
        XCTAssertEqual(v.lastPlayed?.choice, .sary)
        XCTAssertEqual(v.lastPlayed?.clips, ["dist_05", "turns_01"])
        v.stop()
        let dv = NavVoice()
        dv.muted = false
        dv.choice = { .device }
        var device: [String] = []
        dv.speakDevice = { device.append($0) }
        dv.say("بعد ٥٠٠ متر، انعطف يسارًا إلى طريق العروبة", clips: ["dist_07", "turns_02"])
        XCTAssertEqual(dv.lastPlayed?.choice, .device)
        XCTAssertTrue(dv.lastPlayed?.text.contains("طريق العروبة") == true)
        XCTAssertEqual(device, ["بعد ٥٠٠ متر، انعطف يسارًا إلى طريق العروبة"], "the device voice says the whole line, names too")
        dv.stop()
    }

    func testSaryVoiceNeverFallsBackToTheDeviceVoice() {
        let v = NavVoice()
        v.muted = false
        v.choice = { .sary }
        var said: [String] = []
        v.onSpoken = { said.append($0) }
        v.say("Turn right onto King Fahd Road", clips: [])
        XCTAssertEqual(said.count, 1, "still reported (CarPlay, logs)")
        XCTAssertNil(v.lastPlayed, "router text in another language is never read out")
    }

    func testMutedSaysNothing() {
        let v = NavVoice()
        v.muted = true
        v.choice = { .sary }
        v.say("خرجت عن الطريق، نحسب طريقًا جديدًا", clips: ["rr_01"])
        XCTAssertNil(v.lastPlayed)
    }

    func testHeldWhileAVoiceNotePlaysThenSaid() async {
        let v = NavVoice()
        v.muted = false
        v.choice = { .sary }
        var busy = true
        v.canSpeak = { !busy }
        v.say("انتبه", clips: ["arr_02"])
        XCTAssertNil(v.lastPlayed, "not over the voice note")
        busy = false
        let end = Date().addingTimeInterval(3)
        while v.lastPlayed == nil, Date() < end { try? await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertEqual(v.lastPlayed?.clips, ["arr_02"], "said once the speaker is free")
        v.stop()
    }

    func testAMissingClipIsAnErrorNeverAnotherClip() async {
        let p = SaryClipPlayer()
        var started: Bool?
        p.play(["dist_05", "nope_99"]) { started = $0 }
        let end = Date().addingTimeInterval(3)
        while started == nil, Date() < end { try? await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(started, false, "nothing is played, not half the line")
        XCTAssertEqual(p.lastError, .missing("nope_99"), "the missing key is named")
        XCTAssertFalse(p.isPlaying)
    }

    func testStaleAndExpiredLinesAreDropped() {
        let v = NavVoice()
        v.muted = false
        v.choice = { .sary }
        v.routeRevision = 3
        v.say(NavLine("old route", clips: ["turns_01"], routeRevision: 2))
        XCTAssertNil(v.lastPlayed, "a line from the route before the reroute")
        v.say(NavLine("expired", clips: ["turns_02"], expiresAt: Date().addingTimeInterval(-1)))
        XCTAssertNil(v.lastPlayed)
        v.say(NavLine("now", clips: ["turns_03"], routeRevision: 3))
        XCTAssertEqual(v.lastPlayed?.clips, ["turns_03"])
        v.stop()
    }

    func testRepeatedReroutesDropTheWaitingLineOfTheOldRoute() {
        let v = NavVoice()
        v.muted = false
        v.choice = { .sary }
        var busy = true
        v.canSpeak = { !busy }
        for rev in 1...4 {
            v.routeRevision = rev
            v.say(NavLine("route \(rev)", clips: ["dist_0\(rev + 1)", "turns_01"], maneuverID: "\(rev):1", routeRevision: rev))
        }
        v.routeRevision = 5
        busy = false
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        XCTAssertNil(v.lastPlayed, "every waiting line was for a route that no longer exists")
        v.say(NavLine("route 5", clips: ["turns_02"], routeRevision: 5))
        XCTAssertEqual(v.lastPlayed?.clips, ["turns_02"])
        v.stop()
    }

    func testAGPSGapNeverSaysAnExpiredLine() {
        let v = NavVoice()
        v.muted = false
        v.choice = { .sary }
        var busy = true
        v.canSpeak = { !busy }
        v.say(NavLine("بعد خمس مية متر انعطف يمين", clips: ["dist_07", "turns_01"], expiresAt: Date().addingTimeInterval(0.2)))
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        busy = false
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        XCTAssertNil(v.lastPlayed, "the fix came back too late: «بعد خمس مية» is no longer true")
        v.say(NavLine("انعطف يمين", clips: ["turns_01"], expiresAt: Date().addingTimeInterval(10)))
        XCTAssertEqual(v.lastPlayed?.clips, ["turns_01"], "the fresh line for where I am now")
        v.stop()
    }

    func testOnlyOneLineWaits() {
        let v = NavVoice()
        v.muted = false
        v.choice = { .sary }
        var busy = true
        v.canSpeak = { !busy }
        v.say("a", clips: ["dist_05", "turns_01"])
        v.say("b", clips: ["dist_04", "turns_01"])
        v.say("c", clips: ["dist_02", "turns_01"])
        busy = false
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        XCTAssertEqual(v.lastPlayed?.clips, ["dist_02", "turns_01"], "the newest replaced the older waiting ones")
        v.stop()
    }

    func testSafetyWhileITalkIsAVibrationAndText() {
        let v = NavVoice()
        v.muted = false
        v.choice = { .sary }
        v.canSpeak = { false }
        v.isSending = { true }
        var shown: [String] = []
        v.onSafetyWhileTalking = { shown.append($0) }
        v.say("باقي ساعة على المغرب", clips: ["sun_02"], safety: true)
        XCTAssertEqual(shown, ["باقي ساعة على المغرب"])
        XCTAssertNil(v.lastPlayed, "never over my own voice")
        v.say("بعد مية متر، انعطف يمينًا", clips: ["dist_02", "turns_01"])
        XCTAssertEqual(shown.count, 1, "guidance waits instead")
        v.stop()
    }

    func testRerouteAndArrivalLinesThroughTheSession() async {
        let start = LngLat(lng: 46.6744, lat: 24.7113), end = LngLat(lng: 46.7000, lat: 24.7300)
        let c = (0...10).map { i in LngLat(lng: start.lng + (end.lng - start.lng) * Double(i) / 10, lat: start.lat + (end.lat - start.lat) * Double(i) / 10) }
        let d = Vehicle.distanceMeters(start, end)
        let route = NavRoute(id: "r", coordinates: c, distanceM: d, durationS: d / 15, steps: [
            NavStep(maneuver: .init(kind: .depart, direction: nil), roadName: "طريق الملك فهد", location: start, distanceM: d, durationS: d / 15),
            NavStep(maneuver: .init(kind: .arrive, direction: nil), roadName: nil, location: end, distanceM: 0, durationS: 0),
        ])
        let n = NavSession(provider: ScriptedRouter([.success(NavRoutePlan(routes: [route]))]), makeEngine: { _ in LocalGuidanceEngine() })
        n.muted = false
        n.voice.choice = { .sary }
        n.voice.canSpeak = { true }
        n.myFix = { DeviceFix(lat: start.lat, lng: start.lng, accuracy: 5, heading: nil, speed: 12, atMs: Date().timeIntervalSince1970 * 1000) }
        n.autoStart(to: NavTarget(source: .destination, name: "مخيم النفود", position: end), intro: "نبدأ التوجيه إلى مخيم النفود", introClips: ["start_01"])
        let until = Date().addingTimeInterval(3)
        while n.voice.lastPlayed == nil, Date() < until { try? await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(n.voice.lastPlayed?.clips.first, "start_01")
        XCTAssertEqual(n.voice.lastPlayed?.clips.last, "start_06", "«بسم الله نبدأ.» … «وجهتك قدّامك.», no name")
        /* The same cue again (a repeated reroute event, a duplicate router cue): said once per stage. */
        XCTAssertNil(n.guidanceLine(stepIndex: 1, distanceM: route.steps[0].distanceM))
        let rev = n.routeRevision
        n.handle(.offRoute)
        n.handle(.rerouted(route))
        XCTAssertEqual(n.routeRevision, rev + 1)
        /* The new route's first maneuver is said at once on «rerouted» (Mapbox's own first cue for it
         * came before the event and was lost): it replaces the waiting «خرجت عن الطريق». */
        XCTAssertNil(n.guidanceLine(stepIndex: 1, distanceM: route.steps[0].distanceM), "already said for the new route")
        await wait { n.voice.lastPlayed?.clips.last == "start_06" && n.routeRevision == rev + 1 && n.voice.lastPlayed?.clips.first != "start_01" }
        XCTAssertEqual(n.voice.lastPlayed?.clips.last, "start_06", "the new route's line, after the current one ends")
        await wait { !n.voice.isSpeaking }
        n.finishArrival()
        await wait { n.voice.lastPlayed?.clips == ["arr_01"] }
        XCTAssertEqual(n.voice.lastPlayed?.clips, ["arr_01"], "«وصلتوا، الله يحيّيكم.»")
        n.end()
    }

    private func wait(_ ok: @escaping () -> Bool) async {
        let end = Date().addingTimeInterval(10)
        while !ok(), Date() < end { try? await Task.sleep(nanoseconds: 50_000_000) }
    }
}

/// ITU-R BS.1770-4 integrated loudness (mono): K-weighting, 400 ms blocks, 75 % overlap,
/// absolute gate -70 LUFS, relative gate -10 LU. Same algorithm as ffmpeg `ebur128`.
enum Loudness {
    private static func biquad(_ x: [Double], _ b: [Double], _ a: [Double]) -> [Double] {
        var y = [Double](repeating: 0, count: x.count)
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        for i in x.indices {
            let v = (b[0] * x[i] + b[1] * x1 + b[2] * x2 - a[1] * y1 - a[2] * y2) / a[0]
            x2 = x1; x1 = x[i]; y2 = y1; y1 = v
            y[i] = v
        }
        return y
    }

    static func integratedLUFS(_ s: [Float], sampleRate fs: Double) -> Double {
        /* Stage 1: high shelf (+4 dB @ 1682 Hz). Stage 2: high pass (38 Hz). */
        let g = 3.99984385397, q1 = 0.7071752369554193, f1 = 1681.9744509555319
        let A = pow(10, g / 40), w1 = 2 * Double.pi * f1 / fs, al1 = sin(w1) / (2 * q1), c1 = cos(w1)
        let b1 = [A * ((A + 1) + (A - 1) * c1 + 2 * sqrt(A) * al1), -2 * A * ((A - 1) + (A + 1) * c1), A * ((A + 1) + (A - 1) * c1 - 2 * sqrt(A) * al1)]
        let a1 = [(A + 1) - (A - 1) * c1 + 2 * sqrt(A) * al1, 2 * ((A - 1) - (A + 1) * c1), (A + 1) - (A - 1) * c1 - 2 * sqrt(A) * al1]
        let q2 = 0.5003270373253953, f2 = 38.13547087613982
        let w2 = 2 * Double.pi * f2 / fs, al2 = sin(w2) / (2 * q2), c2 = cos(w2)
        let b2 = [(1 + c2) / 2, -(1 + c2), (1 + c2) / 2], a2 = [1 + al2, -2 * c2, 1 - al2]
        let y = biquad(biquad(s.map(Double.init), b1, a1), b2, a2)
        let block = Int(0.4 * fs), hop = Int(0.1 * fs)
        guard y.count >= block else { return -.infinity }
        var z: [Double] = []
        var i = 0
        while i + block <= y.count {
            var sum = 0.0
            for k in i..<(i + block) { sum += y[k] * y[k] }
            z.append(sum / Double(block))
            i += hop
        }
        let lk = { (m: Double) in -0.691 + 10 * log10(m) }
        let abs = z.filter { lk($0) > -70 }
        guard !abs.isEmpty else { return -.infinity }
        let rel = lk(abs.reduce(0, +) / Double(abs.count)) - 10
        let gated = abs.filter { lk($0) > rel }
        return lk(gated.reduce(0, +) / Double(gated.count))
    }
}
