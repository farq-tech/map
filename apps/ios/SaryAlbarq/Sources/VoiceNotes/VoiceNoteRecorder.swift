import AudioToolbox
import AVFoundation
import Foundation

/// The microphone for «رسالة صوتية»: AAC in an m4a, mono, 16 kHz, ≈24 kbps (≈180 KB a minute),
/// at most 60 s. Publishes the elapsed time and a live level for the waveform.
///
/// DEBUG `-SaryPTTTone` (the simulator's microphone is unreliable): no microphone at all — the
/// "recording" is a generated 440 Hz tone of the same length, written as a real m4a.
@MainActor
final class VoiceNoteRecorder: NSObject, AVAudioRecorderDelegate {
    struct Take: Equatable {
        var file: URL
        var durationMs: Int
        var stoppedAt: Date
        /// 0…1, ≈ 20 a second over the take (the sender's own waveform).
        var levels: [Float]
    }

    enum Failure: Error, Equatable { case noPermission, cannotStart }

    nonisolated static let sampleRate = 16_000.0
    nonisolated static let bitRate = 24_000

    private var recorder: AVAudioRecorder?
    private var meter: Timer?
    private var startedAt: Date?
    private(set) var levels: [Float] = []
    private(set) var isRecording = false
    private var toneFile: URL?
    let useTestTone: Bool
    /// ~20×/s while recording: elapsed seconds and the newest level 0…1.
    var onTick: (TimeInterval, Float) -> Void = { _, _ in }
    /// The 60 s limit stopped it by itself.
    var onLimit: () -> Void = {}

    init(testTone: Bool = PTTAudioEngine.testToneRequested) {
        useTestTone = testTone
    }

    nonisolated static func settings(bitRate: Int?) -> [String: Any] {
        var s: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]
        if let bitRate { s[AVEncoderBitRateKey] = bitRate }
        return s
    }

    private static func tempFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("sary-voice-\(UUID().uuidString).m4a")
    }

    /// The audio session must already be active (`VoiceNoteAudio.acquire`).
    func start() throws {
        guard !isRecording else { return }
        levels = []
        let url = Self.tempFile()
        if useTestTone {
            toneFile = url
        } else {
            guard AVAudioApplication.shared.recordPermission == .granted else { throw Failure.noPermission }
            /* Whatever bit rate the recorder picks: `transcode` makes it ≈24 kbps before it is sent. */
            let r = try? AVAudioRecorder(url: url, settings: Self.settings(bitRate: nil))
            guard let r else { throw Failure.cannotStart }
            r.delegate = self
            r.isMeteringEnabled = true
            guard r.prepareToRecord(), r.record(forDuration: VoiceNotePolicy.maxRecordMs / 1000) else { throw Failure.cannotStart }
            recorder = r
        }
        startedAt = Date()
        isRecording = true
        meter = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        guard isRecording, let t0 = startedAt else { return }
        let elapsed = Date().timeIntervalSince(t0)
        let level: Float
        if let r = recorder {
            r.updateMeters()
            /* −50…0 dBFS → 0…1, a little curved so speech fills the bars. */
            let db = r.averagePower(forChannel: 0)
            level = max(0, min(1, pow((db + 50) / 50, 1.6)))
        } else {
            /* The test tone: a gentle syllable-like envelope. */
            level = Float(0.35 + 0.3 * abs(sin(elapsed * 5.3)))
        }
        levels.append(level)
        onTick(elapsed, level)
        if useTestTone, elapsed * 1000 >= VoiceNotePolicy.maxRecordMs { onLimit() }
    }

    /// Stop and keep the take (nil if it was too short to be meant, or nothing was written).
    func stop() -> Take? {
        guard isRecording, let t0 = startedAt else { return nil }
        let ms = min(VoiceNotePolicy.maxRecordMs, Date().timeIntervalSince(t0) * 1000)
        finishTimers()
        let url: URL?
        if let r = recorder {
            r.stop()
            url = r.url
            recorder = nil
        } else if let f = toneFile {
            url = (try? Self.writeTone(to: f, seconds: ms / 1000)) == nil ? nil : f
            toneFile = nil
        } else {
            url = nil
        }
        guard let url, ms >= VoiceNotePolicy.minRecordMs,
              let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue, size > 256 else {
            if let url { try? FileManager.default.removeItem(at: url) }
            return nil
        }
        return Take(file: url, durationMs: Int(ms.rounded()), stoppedAt: Date(), levels: levels)
    }

    /// «احذف»: nothing is kept.
    func cancel() {
        guard isRecording else { return }
        finishTimers()
        if let r = recorder {
            r.stop()
            r.deleteRecording()
            recorder = nil
        }
        toneFile = nil
    }

    private func finishTimers() {
        isRecording = false
        startedAt = nil
        meter?.invalidate()
        meter = nil
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        /* `record(forDuration:)` reached the minute by itself. */
        Task { @MainActor in
            if self.isRecording, self.recorder === recorder { self.onLimit() }
        }
    }

    /// A real AAC m4a of a 440 Hz tone (DEBUG test path; also used by unit tests).
    nonisolated static func writeTone(to url: URL, seconds: Double, hz: Double = 440) throws {
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        let total = AVAudioFrameCount(max(1, seconds * sampleRate))
        guard let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: total), let d = b.floatChannelData?[0] else { throw Failure.cannotStart }
        b.frameLength = total
        var phase = 0.0
        for i in 0..<Int(total) {
            let t = Double(i) / sampleRate
            /* Syllables: 0.2…0.5 amplitude at ~5 Hz, so the receiver's level chain has speech-like dynamics. */
            let env = 0.2 + 0.3 * abs(sin(t * 5.3))
            d[i] = Float(env * sin(phase))
            phase += 2 * .pi * hz / sampleRate
        }
        try encodeAAC(b, to: url)
    }

    /// The recording as it goes out: decoded, «تنقية الصوت» (`VoiceNoteDenoise`, DeepFilterNet3 on
    /// the device: wind, engine and tyre noise out) and re-encoded as AAC-LC 16 kHz mono at a constant
    /// `bitRate` (AVAudioRecorder / AVAudioFile ignore the bit rate asked for: ≈70–100 kbps).
    /// If the denoise fails the original voice is sent; if anything else fails, the original file.
    /// Off the main thread.
    nonisolated static func transcode(_ raw: URL, denoise: Bool = true) -> URL {
        guard let data = try? Data(contentsOf: raw), var pcm = VoiceNotePlayer.decode(data) else { return raw }
        if denoise { pcm = denoised(pcm) }
        let out = raw.deletingLastPathComponent().appendingPathComponent("sary-voice-\(UUID().uuidString).m4a")
        do {
            try encodeAAC(pcm, to: out)
            try? FileManager.default.removeItem(at: raw)
            return out
        } catch {
            try? FileManager.default.removeItem(at: out)
            return raw
        }
    }

    /// The denoised take, or the same buffer when the model is missing, the phone is too hot, or it fails.
    nonisolated static func denoised(_ pcm: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        guard ProcessInfo.processInfo.thermalState != .critical else {
            PTTDiagnosticsLog.shared.add("voice", "denoise skipped (thermal critical)")
            return pcm
        }
        guard let (clean, r) = VoiceNoteDenoise.process(pcm) else {
            PTTDiagnosticsLog.shared.add("voice", "denoise unavailable → original")
            return pcm
        }
        PTTDiagnosticsLog.shared.add("voice", "denoised \(Int(r.audioMs)) ms in \(Int(r.tookMs)) ms")
        return clean
    }

    /// 16 kHz mono float → AAC-LC m4a at a constant bit rate (ExtAudioFile + its converter).
    nonisolated static func encodeAAC(_ pcm: AVAudioPCMBuffer, to url: URL, bitRate: Int = bitRate) throws {
        var out = AudioStreamBasicDescription(mSampleRate: pcm.format.sampleRate, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0, mBytesPerPacket: 0,
                                              mFramesPerPacket: 1024, mBytesPerFrame: 0, mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)
        var file: ExtAudioFileRef?
        var st = ExtAudioFileCreateWithURL(url as CFURL, kAudioFileM4AType, &out, nil, AudioFileFlags.eraseFile.rawValue, &file)
        guard st == noErr, let file else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(st)) }
        defer { ExtAudioFileDispose(file) }
        var client = pcm.format.streamDescription.pointee
        st = ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat, UInt32(MemoryLayout.size(ofValue: client)), &client)
        guard st == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(st)) }
        var conv: AudioConverterRef?
        var size = UInt32(MemoryLayout<AudioConverterRef?>.size)
        if ExtAudioFileGetProperty(file, kExtAudioFileProperty_AudioConverter, &size, &conv) == noErr, let conv {
            var mode = UInt32(kAudioCodecBitRateControlMode_Constant)
            _ = AudioConverterSetProperty(conv, kAudioCodecPropertyBitRateControlMode, UInt32(MemoryLayout<UInt32>.size), &mode)
            var br = UInt32(bitRate)
            _ = AudioConverterSetProperty(conv, kAudioConverterEncodeBitRate, UInt32(MemoryLayout<UInt32>.size), &br)
            var none: CFPropertyList?
            _ = ExtAudioFileSetProperty(file, kExtAudioFileProperty_ConverterConfig, UInt32(MemoryLayout<CFPropertyList?>.size), &none)
        }
        st = ExtAudioFileWrite(file, pcm.frameLength, pcm.audioBufferList)
        guard st == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(st)) }
    }
}

/// The audio session for recording and playing voice notes on screen (the PushToTalk system
/// session is borrowed through `OutingWalkieTalkie` when the phone is locked). Speaker, not the
/// earpiece; «إذاعة الطلعة» pauses meanwhile.
@MainActor
enum VoiceNoteAudio {
    private static var users = 0
    private static var pendingOff: DispatchWorkItem?

    @discardableResult
    static func acquire(why: String) -> Bool {
        pendingOff?.cancel()
        pendingOff = nil
        users += 1
        guard users == 1 else { return true }
        GroupAudioDuck.began(.ptt)
        let s = AVAudioSession.sharedInstance()
        do {
            try s.setCategory(.playAndRecord, mode: .default, options: PTTSpeaker.options)
            try s.setActive(true)
            PTTSpeaker.engage(s, why: "voice note \(why)")
            return true
        } catch {
            PTTDiagnosticsLog.shared.add("voice", "session failed (\(why)): \((error as NSError).domain)#\((error as NSError).code)")
            return false
        }
    }

    static func release() {
        users = max(0, users - 1)
        guard users == 0 else { return }
        let w = DispatchWorkItem {
            MainActor.assumeIsolated {
                guard users == 0 else { return }
                PTTSpeaker.disengage()
                if !GroupAudioDuck.musicOwnsSession { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
                GroupAudioDuck.ended(.ptt)
            }
        }
        pendingOff = w
        /* Back-and-forth messages should not flap the session (and other apps' audio). */
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: w)
    }
}
