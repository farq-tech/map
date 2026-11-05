import AVFoundation
import Foundation

/// Plays one voice note the way a live transmission sounds: the incoming squelch + chirp, the
/// voice through the radio filter (when «أصوات اللاسلكي» is on) and the receiver's level chain
/// (`PTTRxLevel`: make-up gain → compressor → limiter, at the «صوت اللاسلكي» level), then the
/// roger + squelch tail. 16 kHz mono, its own small engine (the live one is left alone).
///
/// The audio session must be active first: `VoiceNoteAudio` on screen, or the PushToTalk
/// system session (borrowed through `OutingWalkieTalkie`) with the phone locked.
@MainActor
final class VoiceNotePlayer {
    private let engine = AVAudioEngine()
    private let voice = AVAudioPlayerNode()
    private let cues = AVAudioPlayerNode()
    private var attached = false
    private var progressTimer: Timer?
    private var startedVoiceAt: AVAudioFramePosition?
    private var totalFrames: AVAudioFramePosition = 0
    private var token = 0
    private(set) var playingId: String?

    /// 0…1 while the voice plays.
    var onProgress: (String, Double) -> Void = { _, _ in }
    /// Finished (`completed`: the whole note was heard).
    var onFinish: (String, Bool) -> Void = { _, _ in }
    var radioSounds: () -> Bool = { PTTRadioSounds.enabled() }
    var voiceLevel: () -> PTTVoiceLevel = { PTTVoiceLevel.current() }

    nonisolated static var format: AVAudioFormat { PTTAudioFormat.pcm }

    /// m4a (or any file AVAudioFile reads) → 16 kHz mono float. Nil if it cannot be decoded.
    nonisolated static func decode(_ data: Data) -> AVAudioPCMBuffer? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sary-play-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        guard (try? data.write(to: url)) != nil, let file = try? AVAudioFile(forReading: url) else { return nil }
        let inFmt = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0, let src = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: frames), (try? file.read(into: src)) != nil else { return nil }
        let out = format
        if inFmt.sampleRate == out.sampleRate, inFmt.channelCount == 1, inFmt.commonFormat == .pcmFormatFloat32, !inFmt.isInterleaved { return src }
        guard let conv = AVAudioConverter(from: inFmt, to: out) else { return nil }
        let cap = AVAudioFrameCount(Double(src.frameLength) * out.sampleRate / inFmt.sampleRate + 1024)
        guard let dst = AVAudioPCMBuffer(pcmFormat: out, frameCapacity: cap) else { return nil }
        var fed = false
        var err: NSError?
        let st = conv.convert(to: dst, error: &err) { _, s in
            if fed { s.pointee = .endOfStream; return nil }
            fed = true
            s.pointee = .haveData
            return src
        }
        guard st != .error, dst.frameLength > 0 else { return nil }
        return dst
    }

    /// The receive chain on a whole note, in place (pure DSP; unit-tested).
    nonisolated static func process(_ b: AVAudioPCMBuffer, radio: Bool, level: PTTVoiceLevel) {
        if radio {
            var fx = PTTRadioVoiceFX()
            fx.process(b)
        }
        var rx = PTTRxLevel(level)
        rx.process(b)
    }

    /// 0…1 bars for the waveform (`count` of them) from decoded audio.
    nonisolated static func waveform(_ b: AVAudioPCMBuffer, count: Int = 40) -> [Float] {
        guard let d = b.floatChannelData?[0], b.frameLength > 0, count > 0 else { return [] }
        let n = Int(b.frameLength)
        let step = max(1, n / count)
        var out: [Float] = []
        var peak: Float = 0.0001
        for i in 0..<count {
            let a = i * step
            guard a < n else { break }
            let z = min(n, a + step)
            var s: Float = 0
            for j in a..<z { s += d[j] * d[j] }
            let rms = (s / Float(max(1, z - a))).squareRoot()
            out.append(rms)
            peak = max(peak, rms)
        }
        return out.map { min(1, $0 / peak) }
    }

    private func ensureEngine() throws {
        if !attached {
            engine.attach(voice)
            engine.attach(cues)
            engine.connect(voice, to: engine.mainMixerNode, format: Self.format)
            engine.connect(cues, to: engine.mainMixerNode, format: Self.format)
            attached = true
        }
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
    }

    /// Plays `pcm` (already decoded) now. False if the engine would not start.
    @discardableResult
    func play(_ pcm: AVAudioPCMBuffer, id: String) -> Bool {
        stop(completed: false)
        Self.process(pcm, radio: radioSounds(), level: voiceLevel())
        do { try ensureEngine() } catch {
            PTTDiagnosticsLog.shared.add("voice", "player failed: \((error as NSError).domain)#\((error as NSError).code)")
            return false
        }
        token += 1
        let my = token
        playingId = id
        totalFrames = AVAudioFramePosition(pcm.frameLength)
        let cuesOn = radioSounds() && PTTCueWarmup.isReady
        cues.volume = voiceLevel().cueVolume
        voice.volume = 1
        /* The squelch opens; the voice starts a little into it (like a live transmission). */
        var lead: TimeInterval = 0
        if cuesOn, let c = PTTRadioSynth.buffer(.incomingStart) {
            cues.scheduleBuffer(c, completionHandler: nil)
            lead = PTTPlayout.voiceLead(cue: PTTRadioSynth.duration(.incomingStart))
        }
        let leadFrames = AVAudioFrameCount(lead * Self.format.sampleRate)
        if leadFrames > 0, let silence = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: leadFrames) {
            silence.frameLength = leadFrames
            voice.scheduleBuffer(silence, completionHandler: nil)
        }
        startedVoiceAt = AVAudioFramePosition(leadFrames)
        voice.scheduleBuffer(pcm, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.token == my else { return }
                self.voiceEnded(my, cuesOn: cuesOn)
            }
        }
        cues.play()
        voice.play()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickProgress() }
        }
        return true
    }

    private func tickProgress() {
        guard let id = playingId, totalFrames > 0, let rt = voice.lastRenderTime, let pt = voice.playerTime(forNodeTime: rt) else { return }
        let done = Double(pt.sampleTime - (startedVoiceAt ?? 0)) / Double(totalFrames)
        onProgress(id, max(0, min(1, done)))
    }

    private func voiceEnded(_ my: Int, cuesOn: Bool) {
        guard let id = playingId else { return }
        onProgress(id, 1)
        progressTimer?.invalidate()
        progressTimer = nil
        if cuesOn, let c = PTTRadioSynth.buffer(.incomingEnd) {
            cues.scheduleBuffer(c, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.token == my else { return }
                    self.finish(completed: true)
                }
            }
            cues.play()
        } else {
            finish(completed: true)
        }
    }

    private func finish(completed: Bool) {
        guard let id = playingId else { return }
        playingId = nil
        progressTimer?.invalidate()
        progressTimer = nil
        voice.stop()
        cues.stop()
        engine.stop()
        onFinish(id, completed)
    }

    /// Stop now (another note, «إيقاف», the trip closed). No roger: it was cut off.
    func stop(completed: Bool = false) {
        token += 1
        finish(completed: completed)
    }
}
