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
            XCTAssertLessThanOrEqual(peak, PTTRadioSynth.peak + 0.001, "\(cue)")
            let rms = (s.reduce(0) { $0 + Double($1 * $1) } / Double(s.count)).squareRoot()
            XCTAssertGreaterThan(rms, 0.03, "\(cue) is audible")
            XCTAssertLessThanOrEqual(PTTLoudness.db(Float(rms)), PTTRadioSynth.cueRMSDB + 0.5, "\(cue) stays under the voice")
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
            XCTAssertLessThanOrEqual(s.reduce(0) { max($0, abs($1)) }, PTTRadioSynth.peak + 0.001)
            XCTAssertEqual(PTTLoudness.db(PTTRadioSynth.rmsOf(s)), PTTRadioSynth.cueRMSDB, accuracy: 1.5)
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

    // MARK: loudness («صوت اللاسلكي»)

    /// Speech-like test signal: a 130 Hz voice (harmonics to 3.5 kHz, two formants) in
    /// syllables at 4 Hz, a pause every second, at `db` dBFS of speech loudness.
    static func speech(seconds: Double, db: Float) -> [Float] {
        let rate = PTTAudioFormat.sampleRate
        let n = Int(seconds * rate)
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) / rate
            let f0 = 130 * (1 + 0.06 * sin(2 * .pi * 0.7 * t))
            var v = 0.0
            for h in 1...26 {
                let f = f0 * Double(h)
                guard f < 3_500 else { break }
                let formant = exp(-pow((f - 600) / 300, 2)) + 0.6 * exp(-pow((f - 1_800) / 400, 2)) + 0.15
                v += formant / Double(h).squareRoot() * sin(2 * .pi * f * t + Double(h))
            }
            let syllable = pow(max(0, sin(.pi * 4 * t)), 1.5)
            let speaking = t.truncatingRemainder(dividingBy: 1) < 0.8 ? 1.0 : 0.0
            out[i] = Float(v * syllable * speaking)
        }
        let g = PTTLoudness.linear(db - PTTLoudness.speechLoudnessDB(out))
        return out.map { $0 * g }
    }

    /// mic → [tx level] → AAC-ELD → decode → [radio voice] → [rx level], in 30 ms packets.
    private func chain(_ input: [Float], tx: Bool, rx: PTTVoiceLevel?, radio: Bool) throws -> [Float] {
        let enc = try XCTUnwrap(PTTEncoder()), dec = try XCTUnwrap(PTTDecoder())
        var txLevel = PTTTxLevel(), fx = PTTRadioVoiceFX(), rxLevel = rx.map { PTTRxLevel($0) }
        var out: [Float] = []
        let n = Int(PTTAudioFormat.samplesPerPacket)
        var i = 0
        while i + n <= input.count {
            let pcm = try XCTUnwrap(AVAudioPCMBuffer.ptt(Array(input[i..<(i + n)])))
            if tx { txLevel.process(pcm) }
            if let packet = enc.encode(pcm), let y = dec.decode(packet) {
                if radio { fx.process(y) }
                rxLevel?.process(y)
                out += Array(UnsafeBufferPointer(start: y.floatChannelData![0], count: Int(y.frameLength)))
            }
            i += n
        }
        return out
    }

    /// Settled part (the first 2 s are the gain finding its level).
    private func measure(_ y: [Float]) -> (lufs: Float, peak: Float) {
        let tail = Array(y.dropFirst(32_000))
        return (PTTLoudness.speechLoudnessDB(tail), PTTLoudness.db(PTTLoudness.peak(y)))
    }

    func testQuietMicComesOutLoudThroughTheWholeChain() throws {
        /* A phone mic at arm's length in a car: ≈ −32 dBFS of speech. */
        let mic = Self.speech(seconds: 8, db: -32)
        for radio in [true, false] {
            let before = measure(try chain(mic, tx: false, rx: nil, radio: radio))
            for level in PTTVoiceLevel.allCases {
                let after = measure(try chain(mic, tx: true, rx: level, radio: radio))
                print("[loudness] radio=\(radio) \(level): before \(before.lufs) dB (peak \(before.peak)) → after \(after.lufs) dB (peak \(after.peak))")
                XCTAssertGreaterThanOrEqual(after.lufs, level.targetDB - 2, "\(level) radio=\(radio)")
                XCTAssertLessThanOrEqual(after.peak, -1 + 0.01, "\(level) never clips")
                XCTAssertGreaterThan(after.lufs - before.lufs, 12, "much louder than build 15")
            }
        }
    }

    func testOlderSenderIsBoostedByTheReceiverAlone() throws {
        /* A build-15 sender (raw mic, no tx level): the receiver alone still lifts it. */
        let mic = Self.speech(seconds: 8, db: -30)
        let y = measure(try chain(mic, tx: false, rx: .high, radio: true))
        XCTAssertGreaterThanOrEqual(y.lufs, PTTVoiceLevel.high.targetDB - 2)
        XCTAssertLessThanOrEqual(y.peak, -0.99)
    }

    func testLoudTalkerIsNotPushedIntoClipping() throws {
        let shout = Self.speech(seconds: 6, db: -6).map { min(1, max(-1, $0)) }
        let y = measure(try chain(shout, tx: true, rx: .veryHigh, radio: false))
        XCTAssertLessThanOrEqual(y.peak, -0.99)
        XCTAssertGreaterThanOrEqual(y.lufs, PTTVoiceLevel.veryHigh.targetDB - 2)
    }

    func testPausesAreNotPumpedUp() {
        /* Hiss at −60 dBFS between transmissions stays hiss. */
        var rx = PTTRxLevel(.veryHigh)
        var rng: UInt32 = 3
        let hiss: [Float] = (0..<32_000).map { _ in
            rng = rng &* 1_664_525 &+ 1_013_904_223
            return (Float(rng >> 8) / Float(1 << 24) * 2 - 1) * 0.001
        }
        let y = hiss.map { rx.process($0) }
        XCTAssertLessThan(PTTLoudness.db(PTTRadioSynth.rmsOf(Array(y.suffix(16_000)))), -40)
    }

    func testCuesSitAboutSixDBUnderTheVoice() {
        for c in PTTRadioCue.allCases {
            let x = PTTRadioSynth.samples(c), rms = PTTRadioSynth.rmsOf(x)
            print("[loudness] cue \(c): now \(PTTLoudness.db(rms)) dB RMS, build 15 \(PTTLoudness.db(rms * 0.35 / PTTLoudness.peak(x))) dB RMS")
        }
        for level in PTTVoiceLevel.allCases {
            let cue = PTTRadioSynth.cueRMSDB + PTTLoudness.db(level.cueVolume)
            XCTAssertLessThanOrEqual(cue, level.targetDB - 5.9, "\(level)")
            XCTAssertGreaterThan(cue, level.targetDB - 13, "\(level): still audible")
        }
    }

    func testVoiceLevelSettingDefaultsHigh() throws {
        let d = try XCTUnwrap(UserDefaults(suiteName: "voice-level-\(UUID())"))
        XCTAssertEqual(PTTVoiceLevel.current(d), .high)
        d.set(PTTVoiceLevel.veryHigh.rawValue, forKey: PTTVoiceLevel.key)
        XCTAssertEqual(PTTVoiceLevel.current(d), .veryHigh)
        XCTAssertEqual(PTTVoiceLevel.veryHigh.targetDB - PTTVoiceLevel.high.targetDB, 6)
        XCTAssertEqual(PTTVoiceLevel.allCases.map(\.label), ["عادي", "عالي", "عالي جداً"])
    }

    // MARK: the loud speaker

    func testEarpieceIsOverriddenToTheSpeaker() {
        XCTAssertTrue(PTTSpeaker.needsSpeakerOverride(outputs: [.builtInReceiver]))
        XCTAssertFalse(PTTSpeaker.needsSpeakerOverride(outputs: [.builtInSpeaker]))
        XCTAssertFalse(PTTSpeaker.needsSpeakerOverride(outputs: []))
    }

    func testHeadphonesBluetoothAndCarPlayAreLeftAlone() {
        for port: AVAudioSession.Port in [.headphones, .bluetoothHFP, .bluetoothA2DP, .bluetoothLE, .carAudio, .airPlay, .usbAudio, .HDMI] {
            XCTAssertFalse(PTTSpeaker.needsSpeakerOverride(outputs: [port]), port.rawValue)
            XCTAssertFalse(PTTSpeaker.needsSpeakerOverride(outputs: [.builtInReceiver, port]), port.rawValue)
        }
    }

    func testSystemSessionIsRecategorisedForTheSpeaker() {
        XCTAssertTrue(PTTSpeaker.needsCategoryFix(category: .playAndRecord, mode: .voiceChat, options: PTTSpeaker.options))
        XCTAssertTrue(PTTSpeaker.needsCategoryFix(category: .playAndRecord, mode: .default, options: [.allowBluetoothHFP]))
        XCTAssertTrue(PTTSpeaker.needsCategoryFix(category: .soloAmbient, mode: .default, options: []))
        XCTAssertFalse(PTTSpeaker.needsCategoryFix(category: .playAndRecord, mode: .default, options: PTTSpeaker.options))
    }

    private func energy<S: Sequence>(_ s: S) -> Double where S.Element == Float { s.reduce(0) { $0 + Double($1 * $1) } }

    private func filter(_ s: [Float], _ b: Biquad) -> [Float] {
        var b = b
        return s.map { b.run($0) }
    }
}
