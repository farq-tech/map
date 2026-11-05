import AVFoundation
import XCTest
@testable import SaryAlbarq

/// «أصوات اللاسلكي»: when each cue plays, and what the synthesised sounds are.
final class RadioSoundsTests: XCTestCase {
    private let inApp = PTTRadioCueSequencer.Context(enabled: true, systemRoute: false)
    private let system = PTTRadioCueSequencer.Context(enabled: true, systemRoute: true)
    private let off = PTTRadioCueSequencer.Context(enabled: false, systemRoute: false)

    // MARK: sequencing

    func testInAppTalkPermitThenRoger() {
        var s = PTTRadioCueSequencer()
        XCTAssertEqual(s.talkGranted(audioReady: true, inApp), .talkPermit)
        XCTAssertNil(s.audioBecameReady(inApp), "one chirp per transmission")
        XCTAssertEqual(s.talkEnded(inApp), .talkEnd)
        XCTAssertNil(s.talkEnded(inApp), "one roger per transmission")
    }

    func testPermitWaitsForTheAudioSession() {
        var s = PTTRadioCueSequencer()
        XCTAssertNil(s.talkGranted(audioReady: false, inApp))
        XCTAssertEqual(s.audioBecameReady(inApp), .talkPermit)
        XCTAssertEqual(s.talkEnded(inApp), .talkEnd)
    }

    func testReleasedBeforeTheMicWasLiveIsSilent() {
        var s = PTTRadioCueSequencer()
        XCTAssertNil(s.talkGranted(audioReady: false, inApp))
        XCTAssertNil(s.talkEnded(inApp))
        XCTAssertNil(s.audioBecameReady(inApp), "a late session after release does not chirp")
    }

    func testAudioReadyWithoutAGrantIsSilent() {
        var s = PTTRadioCueSequencer()
        XCTAssertNil(s.audioBecameReady(inApp))
        XCTAssertNil(s.talkEnded(inApp))
    }

    func testSystemChannelLeavesTransmitTonesToIOS() {
        var s = PTTRadioCueSequencer()
        XCTAssertTrue(PTTRadioCueSequencer.systemPlaysTransmitTones)
        XCTAssertNil(s.talkGranted(audioReady: true, system))
        XCTAssertNil(s.talkEnded(system), "no roger after a chirp we did not play")
        /* Incoming transmissions still get ours. */
        XCTAssertEqual(s.incomingStarted(burst: 4, system), .incomingStart)
        XCTAssertEqual(s.incomingEnded(quiet: false, system), .incomingEnd)
    }

    func testIncomingOncePerBurst() {
        var s = PTTRadioCueSequencer()
        XCTAssertEqual(s.incomingStarted(burst: 7, inApp), .incomingStart)
        XCTAssertNil(s.incomingStarted(burst: 7, inApp), "pending playback resuming is the same transmission")
        XCTAssertEqual(s.incomingEnded(quiet: false, inApp), .incomingEnd)
        XCTAssertNil(s.incomingEnded(quiet: false, inApp))
        XCTAssertEqual(s.incomingStarted(burst: 7, inApp), .incomingStart, "the next press may reuse a burst id")
        XCTAssertEqual(s.incomingStarted(burst: 8, inApp), .incomingStart, "another talker took over")
    }

    func testQuietEndHasNoRoger() {
        var s = PTTRadioCueSequencer()
        _ = s.incomingStarted(burst: 1, inApp)
        XCTAssertNil(s.incomingEnded(quiet: true, inApp))
        XCTAssertEqual(s.incomingStarted(burst: 1, inApp), .incomingStart, "state was reset")
    }

    func testSwitchedOff() {
        var s = PTTRadioCueSequencer()
        XCTAssertNil(s.talkGranted(audioReady: true, off))
        XCTAssertNil(s.talkEnded(off))
        XCTAssertNil(s.incomingStarted(burst: 2, off))
        XCTAssertNil(s.incomingEnded(quiet: false, off))
        /* Turned off mid-transmission: no roger either. */
        XCTAssertEqual(s.talkGranted(audioReady: true, inApp), .talkPermit)
        XCTAssertNil(s.talkEnded(off))
    }

    func testSettingDefaultsOn() throws {
        let d = try XCTUnwrap(UserDefaults(suiteName: "radio-sounds-\(UUID().uuidString)"))
        XCTAssertTrue(PTTRadioSounds.enabled(d))
        d.set(false, forKey: PTTRadioSounds.enabledKey)
        XCTAssertFalse(PTTRadioSounds.enabled(d))
    }

    // MARK: the sounds

    func testCuesAreShortModerateAndDeterministic() {
        for cue in PTTRadioCue.allCases {
            let s = PTTRadioSynth.samples(cue)
            let seconds = Double(s.count) / PTTRadioSynth.sampleRate
            XCTAssertGreaterThan(seconds, 0.15, "\(cue)")
            XCTAssertLessThanOrEqual(seconds, PTTRadioSynth.maxDuration, "\(cue)")
            let peak = s.reduce(0) { max($0, abs($1)) }
            XCTAssertEqual(peak, PTTRadioSynth.peak, accuracy: 0.01, "\(cue)")
            let rms = (s.reduce(0) { $0 + Double($1 * $1) } / Double(s.count)).squareRoot()
            XCTAssertGreaterThan(rms, 0.03, "\(cue) is audible")
            XCTAssertEqual(abs(s.first ?? 1), 0, accuracy: 0.001, "\(cue) starts without a click")
            XCTAssertEqual(abs(s.last ?? 1), 0, accuracy: 0.001, "\(cue) ends without a click")
            XCTAssertEqual(s, PTTRadioSynth.samples(cue), "\(cue) is the same every time")
        }
        XCTAssertNotNil(PTTRadioSynth.buffer(.talkPermit))
    }

    func testStartCuesOpenWithTheRecordedSquelch() throws {
        let rec = try XCTUnwrap(PTTRadioSynth.recordedSquelch(), "radio-squelch.caf ships in the app bundle")
        XCTAssertEqual(Double(rec.count) / PTTRadioSynth.sampleRate, 0.16, accuracy: 0.02)
        XCTAssertEqual(rec.reduce(0) { max($0, abs($1)) }, 0.355, accuracy: 0.02, "levelled to about −9 dBFS")
        XCTAssertNil(Bundle.main.url(forResource: "source-walkie-talkie-83500", withExtension: "mp3"), "the source mp3 is not shipped")
        for cue in [PTTRadioCue.talkPermit, .incomingStart] {
            let withRec = PTTRadioSynth.samples(cue, squelch: rec)
            XCTAssertEqual(PTTRadioSynth.samples(cue), withRec, "\(cue) uses the recording")
            XCTAssertNotEqual(withRec, PTTRadioSynth.samples(cue, squelch: nil))
            /* The recording leads, the chirp follows: same shape as the recording (it is only rescaled). */
            let head = Array(withRec[100..<1_000]), src = Array(rec[100..<1_000])
            let dot = zip(head, src).reduce(0) { $0 + Double($1.0 * $1.1) }
            XCTAssertGreaterThan(dot / (energy(head) * energy(src)).squareRoot(), 0.99, "\(cue)")
        }
        /* End cues stay synthesised. */
        XCTAssertEqual(PTTRadioSynth.samples(.talkEnd), PTTRadioSynth.samples(.talkEnd, squelch: nil))
        XCTAssertEqual(PTTRadioSynth.samples(.incomingEnd), PTTRadioSynth.samples(.incomingEnd, squelch: nil))
    }

    func testFallsBackToTheSynthesisedSquelch() {
        XCTAssertNil(PTTRadioSynth.recordedSquelch(bundle: Bundle(for: RadioSoundsTests.self)), "not in the test bundle")
        for cue in PTTRadioCue.allCases {
            let s = PTTRadioSynth.samples(cue, squelch: nil)
            XCTAssertLessThanOrEqual(Double(s.count) / PTTRadioSynth.sampleRate, PTTRadioSynth.maxDuration)
            XCTAssertEqual(s.reduce(0) { max($0, abs($1)) }, PTTRadioSynth.peak, accuracy: 0.01)
        }
        XCTAssertEqual(PTTRadioSynth.samples(.talkPermit, squelch: []), PTTRadioSynth.samples(.talkPermit, squelch: nil))
    }

    func testSquelchIsBandLimitedNoise() {
        let s = PTTRadioSynth.squelch(ms: 200, seed: 5, decay: 0)
        let total = energy(s)
        /* Little left under the 300 Hz high-pass or over the 3 kHz low-pass. */
        XCTAssertLessThan(energy(filter(s, .lowPass(150, q: 0.7))) / total, 0.1)
        XCTAssertLessThan(energy(filter(s, .highPass(5_000, q: 0.7))) / total, 0.1)
    }

    func testRadioVoiceCutsTheBandEdgesAndKeepsTheMiddle() {
        func gain(_ hz: Double) -> Double {
            var fx = PTTRadioVoiceFX()
            let x = PTTRadioSynth.tone(hz, ms: 400).map { $0 * 0.05 } // under the compressor threshold
            let y = x.map { fx.process($0) }
            return energy(Array(y.dropFirst(1_600))) / energy(Array(x.dropFirst(1_600)))
        }
        XCTAssertGreaterThan(gain(1_000), 1.5, "mid band passes (with make-up gain)")
        XCTAssertLessThan(gain(100), 0.3, "rumble cut")
        XCTAssertLessThan(gain(6_000), 0.3, "hiss cut")
    }

    func testRadioVoiceCompressesLoudSpeech() {
        var fx = PTTRadioVoiceFX()
        let loud = PTTRadioSynth.tone(1_000, ms: 300).map { $0 / 0.6 * 0.9 }
        let y = loud.map { fx.process($0) }.dropFirst(1_600)
        let peak = y.reduce(0) { max($0, abs($1)) }
        XCTAssertLessThan(peak, 0.75, "a near-full-scale voice comes out tamer")
        XCTAssertGreaterThan(peak, 0.2)
    }

    private func energy<S: Sequence>(_ s: S) -> Double where S.Element == Float { s.reduce(0) { $0 + Double($1 * $1) } }

    private func filter(_ s: [Float], _ b: Biquad) -> [Float] {
        var b = b
        return s.map { b.run($0) }
    }
}
