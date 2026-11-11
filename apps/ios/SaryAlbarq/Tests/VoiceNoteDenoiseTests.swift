import Accelerate
import AVFoundation
import XCTest
@testable import SaryAlbarq

/// «تنقية الصوت» (DeepFilterNet3 on the sender's phone). Fixtures: one of the app's own TTS lines
/// (`dir_06`) mixed at 0 dB SNR with generated wind (gusty low-passed noise), engine (38 Hz firing
/// + harmonics + rumble) and tyre noise (band noise 300–2500 Hz), 16 kHz mono, 4.4 s.
final class VoiceNoteDenoiseTests: XCTestCase {
    private func fixture(_ name: String) throws -> [Float] {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "wav"))
        let f = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        XCTAssertEqual(f.processingFormat.sampleRate, 16_000)
        let b = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)))
        try f.read(into: b)
        return Array(UnsafeBufferPointer(start: b.floatChannelData![0], count: Int(b.frameLength)))
    }

    /// 10·log10(‖s‖² / ‖s − y‖²): how close `y` is to the clean speech `s`.
    private func snr(clean s: [Float], _ y: [Float]) -> Double {
        let n = min(s.count, y.count)
        var sig = 0.0, err = 0.0
        for i in 0..<n {
            sig += Double(s[i] * s[i])
            err += Double((s[i] - y[i]) * (s[i] - y[i]))
        }
        return 10 * log10(sig / max(err, 1e-12))
    }

    func testTheModelShipsInTheApp() {
        XCTAssertTrue(VoiceNoteDenoise.Model.isAvailable, "DeepFilterNet3Stream.mlmodelc is bundled")
        XCTAssertNotNil(Bundle.main.url(forResource: "DeepFilterNet-LICENSE", withExtension: "txt"), "the MIT notice ships with it")
        XCTAssertTrue(VoiceDenoiseLicenseNotice.text.contains("Hendrik Schröter"))
    }

    func testERBBandsMatchLibDF() {
        /* libDF erb_fb(48000, 960, 32, 2), as the Python reference prints it. */
        XCTAssertEqual(VoiceNoteDenoise.ERB.widths, [2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 5, 5, 7, 7, 8, 10, 12, 13, 15, 18, 20, 24, 28, 31, 37, 42, 50, 56, 67])
        XCTAssertEqual(VoiceNoteDenoise.ERB.widths.reduce(0, +), 481)
    }

    func testSTFTAnalysisThenSynthesisIsTheIdentity() {
        /* libDF's Vorbis window + wnorm reconstruct perfectly after the n_fft − hop delay. */
        var x: [Float] = []
        x.reserveCapacity(48_000)
        for index in 0..<48_000 {
            let phase = Double(index)
            let lowTone = 0.3 * sin(phase * 0.013)
            let highTone = 0.1 * sin(phase * 0.41)
            x.append(Float(lowTone + highTone))
        }
        let padded = x + [Float](repeating: 0, count: 960)
        let frames = padded.count / 480
        var re = [Float](repeating: 0, count: frames * 481), im = re
        VoiceNoteDenoise.STFT.shared.analysis(padded, frames: frames, re: &re, im: &im)
        let y = VoiceNoteDenoise.STFT.shared.synthesis(re: re, im: im, frames: frames)
        var maxErr: Float = 0
        for i in 0..<x.count { maxErr = max(maxErr, abs(y[i + 480] - x[i])) }
        XCTAssertLessThan(maxErr, 1e-4)
    }

    func testResampleByThreeKeepsLengthAndTheVoiceBand() {
        var x: [Float] = []
        x.reserveCapacity(16_000)
        for index in 0..<16_000 {
            let phase = 2 * Double.pi * 1_000 * Double(index) / 16_000
            x.append(Float(0.5 * sin(phase)))
        }
        let up = Resample3.up(x)
        XCTAssertEqual(up.count, 48_000)
        let back = Resample3.down(up, count: x.count)
        XCTAssertEqual(back.count, x.count)
        var maxErr: Float = 0
        for i in 200..<(x.count - 200) { maxErr = max(maxErr, abs(back[i] - x[i])) }
        XCTAssertLessThan(maxErr, 0.01, "1 kHz passes unchanged and in time")
    }

    func testDenoiseKeepsTheLengthNeverClipsAndRaisesTheSNR() throws {
        let clean = try fixture("denoise-clean"), noisy = try fixture("denoise-noisy")
        XCTAssertEqual(clean.count, noisy.count)
        let t0 = Date()
        let out = try VoiceNoteDenoise.denoise16k(noisy)
        let took = Date().timeIntervalSince(t0)
        XCTAssertEqual(out.count, noisy.count, "the same length out as in")
        XCTAssertTrue(out.allSatisfy(\.isFinite))
        XCTAssertLessThan(VoiceNoteDenoise.peak(out), 1.0, "no clipping")
        let before = snr(clean: clean, noisy), after = snr(clean: clean, out)
        print("DENOISE-SNR before \(String(format: "%.2f", before)) dB after \(String(format: "%.2f", after)) dB, \(Int(took * 1000)) ms for \(noisy.count / 16) ms")
        XCTAssertGreaterThan(after, before + 5, "wind, engine and tyres mostly gone")
        /* The voice stays: most of the clean speech energy is still there. */
        var eC: Float = 0, eO: Float = 0
        vDSP_svesq(clean, 1, &eC, vDSP_Length(clean.count))
        vDSP_svesq(out, 1, &eO, vDSP_Length(out.count))
        XCTAssertGreaterThan(eO / eC, 0.4)
        XCTAssertLessThan(eO / eC, 1.6)
        /* For the Python parity check (scripts/deepfilternet). */
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("denoise-swift-out.f32")
        try out.withUnsafeBufferPointer { try Data(buffer: $0).write(to: url) }
        print("DENOISE-OUT \(url.path)")
    }

    func testAMinuteDenoisesQuickly() throws {
        let noisy = try fixture("denoise-noisy")
        var minute: [Float] = []
        while minute.count < 60 * 16_000 { minute += noisy }
        minute = Array(minute.prefix(60 * 16_000))
        _ = try VoiceNoteDenoise.denoise16k(Array(noisy.prefix(16_000)))  // model load + first compile
        let t0 = Date()
        let out = try VoiceNoteDenoise.denoise16k(minute)
        let took = Date().timeIntervalSince(t0)
        print("DENOISE-BENCH 60 s in \(Int(took * 1000)) ms")
        XCTAssertEqual(out.count, minute.count)
        XCTAssertLessThan(took, 6, "simulator bound (the phone's Neural Engine is faster)")
    }

    func testBadInputFailsSoTheOriginalIsSent() throws {
        XCTAssertThrowsError(try VoiceNoteDenoise.denoise16k([]))
        XCTAssertThrowsError(try VoiceNoteDenoise.denoise16k([0.1, .nan, 0.2]))
        /* A 48 kHz buffer is not a voice note: nil, the caller keeps it. */
        let f48 = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
        let b = AVAudioPCMBuffer(pcmFormat: f48, frameCapacity: 480)!
        b.frameLength = 480
        XCTAssertNil(VoiceNoteDenoise.process(b))
        XCTAssertTrue(VoiceNoteRecorder.denoised(b) === b)
    }

    func testTranscodeDenoisesAndKeepsTheDuration() throws {
        let noisy = try fixture("denoise-noisy")
        let fmt = VoiceNotePlayer.format
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(noisy.count)))
        pcm.frameLength = AVAudioFrameCount(noisy.count)
        noisy.withUnsafeBufferPointer { pcm.floatChannelData![0].update(from: $0.baseAddress!, count: noisy.count) }
        let raw = FileManager.default.temporaryDirectory.appendingPathComponent("vn-dn-\(UUID().uuidString).m4a")
        try VoiceNoteRecorder.encodeAAC(pcm, to: raw, bitRate: 32_000)
        let out = VoiceNoteRecorder.transcode(raw)
        defer { try? FileManager.default.removeItem(at: out) }
        XCTAssertNotEqual(out, raw)
        let back = try XCTUnwrap(VoiceNotePlayer.decode(try Data(contentsOf: out)))
        XCTAssertEqual(Double(back.frameLength) / 16_000, Double(noisy.count) / 16_000, accuracy: 0.1)
        XCTAssertLessThan(back.pttRMS, pcm.pttRMS, "the noise is gone from what is sent")
    }
}
