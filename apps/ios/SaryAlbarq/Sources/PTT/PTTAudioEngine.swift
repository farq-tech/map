import AVFoundation
import os

/// Microphone → AAC-ELD packets, and packets → speaker through the jitter
/// buffer. Everything audio runs on one serial queue; frames go out and come in
/// as `PTTFrame`s. The engine never decides who talks: `OutingWalkieTalkie` does.
///
/// Playback is pulled by the audio clock: two 30 ms buffers are always
/// scheduled, and each one that finishes playing pulls the next packet (or 30
/// ms of silence) from the jitter buffer — so the cadence never drifts.
///
/// DEBUG `-SaryPTTTone`: the "microphone" is a generated 440 Hz tone (the
/// simulator's audio input is unreliable), and every received transmission
/// logs its decoded level and pitch, so two simulators prove the whole path.
final class PTTAudioEngine {
    static let log = Logger(subsystem: "sa.sary.albarq", category: "ptt")

    /// An encoded packet ready to send (called on the audio queue).
    var onFrame: (PTTFrame) -> Void = { _ in }
    /// Input level 0…1 while talking, ~10×/s (main queue), for the button's meter.
    var onLevel: (Float) -> Void = { _ in }

    let queue = DispatchQueue(label: "sa.sary.ptt.audio", qos: .userInteractive)
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    /// «أصوات اللاسلكي»: squelch / chirp / roger, on their own node so they mix over a voice.
    private let cuePlayer = AVAudioPlayerNode()
    private var cuesInFlight = 0
    /// While a cue sounds during capture the mic sends silence (the speaker must not leak on air).
    private var micGateUntil: TimeInterval = 0
    /// Played after the current transmission has drained.
    private var endCue: PTTRadioCue?
    private var voiceFX = PTTRadioVoiceFX()
    /// Read on the audio queue for each new transmission.
    var radioVoice: () -> Bool = { PTTRadioSounds.enabled() }
    private var radioVoiceOn = false
    private var encoder = PTTEncoder()
    private var decoder = PTTDecoder()
    private var chunker = PTTChunker()
    private var inputConverter: AVAudioConverter?
    private var jitter = PTTJitterBuffer()
    private var capturing = false
    private var burst: UInt8 = 0
    private var seq: UInt16 = 0
    private var playing = false
    private var draining = false
    private var attached = false
    /// The input node has been part of the running graph since the last start.
    private var inputWired = false
    private var toneTimer: DispatchSourceTimer?
    private var tonePhase = 0.0
    private var levelAt = 0.0
    private var rx = RxProbe()
    let useTestTone: Bool

    init(testTone: Bool = PTTAudioEngine.testToneRequested) {
        useTestTone = testTone
        PTTCueWarmup.warm()
        /* The AAC-ELD codecs load on first use (≈1 s on a cold start): that second used to come
         * out of the first transmission. Load them now, before anyone presses. */
        queue.async { [self] in
            let t0 = Date()
            let pcm = Self.silence()
            if let packet = encoder?.encode(pcm) { _ = decoder?.decode(packet) }
            encoder?.reset()
            decoder?.reset()
            PTTDiagnosticsLog.shared.add("audio", "codec ready in \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
        }
    }

    static var testToneRequested: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-SaryPTTTone")
        #else
        return false
        #endif
    }

    // MARK: engine

    private func ensureEngine() throws {
        if !attached {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: PTTAudioFormat.pcm)
            engine.attach(cuePlayer)
            engine.connect(cuePlayer, to: engine.mainMixerNode, format: PTTAudioFormat.pcm)
            attached = true
        }
        if !engine.isRunning {
            let t0 = Date()
            engine.prepare()
            try engine.start()
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            /* Field logs: a slow start here holds every frame and cue queued behind it. */
            if ms > 150 { PTTDiagnosticsLog.shared.add("audio", "engine start took \(ms) ms") }
        }
    }

    private func stopEngineIfIdle() {
        guard !capturing, !playing, cuesInFlight == 0 else { return }
        engine.stop()
        inputWired = false
    }

    // MARK: talking

    /// Microphone on for this burst. The audio session must already be active
    /// (the system activates it in PTT mode; `PTTInAppRoute` does otherwise).
    func startCapture(burst b: UInt8) {
        queue.async { [self] in
            guard !capturing else { return }
            burst = b
            seq = 0
            chunker.reset()
            encoder?.reset()
            capturing = true
            if useTestTone { return startTone() }
            do {
                let input = engine.inputNode
                let hw = input.outputFormat(forBus: 0)
                guard hw.sampleRate > 0, hw.channelCount > 0 else { throw PTTError.noMicrophone }
                inputConverter = AVAudioConverter(from: hw, to: PTTAudioFormat.pcm)
                /* An engine already running for a cue or a friend's voice was started without the
                 * input in its graph: a tap added now may never be called. Restart it with the mic. */
                if engine.isRunning, !inputWired, !playing {
                    cuePlayer.stop()
                    cuesInFlight = 0
                    engine.stop()
                }
                inputWired = true
                input.removeTap(onBus: 0)
                input.installTap(onBus: 0, bufferSize: 1024, format: hw) { [weak self] buf, _ in
                    self?.queue.async { self?.captured(buf) }
                }
                try ensureEngine()
            } catch {
                Self.log.error("[PTT] capture failed: \(String(describing: error), privacy: .public)")
                PTTDiagnosticsLog.shared.add("audio", "mic failed: \((error as NSError).domain)#\((error as NSError).code)")
                capturing = false
            }
        }
    }

    func stopCapture() {
        queue.async { [self] in
            guard capturing else { return }
            capturing = false
            toneTimer?.cancel()
            toneTimer = nil
            if !useTestTone { engine.inputNode.removeTap(onBus: 0) }
            inputConverter = nil
            stopEngineIfIdle()
        }
    }

    private func captured(_ buf: AVAudioPCMBuffer) {
        guard capturing, let conv = inputConverter else { return }
        let ratio = PTTAudioFormat.sampleRate / buf.format.sampleRate
        let cap = AVAudioFrameCount(Double(buf.frameLength) * ratio + 32)
        guard let out = AVAudioPCMBuffer(pcmFormat: PTTAudioFormat.pcm, frameCapacity: cap) else { return }
        var fed = false
        var err: NSError?
        _ = conv.convert(to: out, error: &err) { _, s in
            if fed { s.pointee = .noDataNow; return nil }
            fed = true
            s.pointee = .haveData
            return buf
        }
        guard out.frameLength > 0, let d = out.floatChannelData?[0] else { return }
        feed(UnsafeBufferPointer(start: d, count: Int(out.frameLength)))
    }

    private func feed(_ samples: UnsafeBufferPointer<Float>) {
        if Date().timeIntervalSince1970 < micGateUntil {
            /* A cue is sounding: what the mic hears now is our own speaker. Send silence instead. */
            let zeros = [Float](repeating: 0, count: samples.count)
            return zeros.withUnsafeBufferPointer { feedChunks($0) }
        }
        feedChunks(samples)
    }

    private func feedChunks(_ samples: UnsafeBufferPointer<Float>) {
        for chunk in chunker.push(samples) {
            guard let pcm = AVAudioPCMBuffer.ptt(chunk), let packet = encoder?.encode(pcm) else { continue }
            let f = PTTFrame(burst: burst, seq: seq, codec: .aacELD16k, payload: packet)
            seq &+= 1
            onFrame(f)
            let now = Date().timeIntervalSince1970
            if now - levelAt > 0.1 {
                levelAt = now
                let level = min(1, pcm.pttRMS * 3)
                DispatchQueue.main.async { self.onLevel(level) }
            }
        }
    }

    /// DEBUG test source: 440 Hz at half scale, generated in real time.
    private func startTone() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(Int(PTTFrame.packetMs)))
        t.setEventHandler { [weak self] in
            guard let self, self.capturing else { return }
            var s = [Float](repeating: 0, count: Int(PTTAudioFormat.samplesPerPacket))
            for i in s.indices {
                s[i] = Float(0.5 * sin(self.tonePhase))
                self.tonePhase += 2 * .pi * 440 / PTTAudioFormat.sampleRate
            }
            self.tonePhase = self.tonePhase.truncatingRemainder(dividingBy: 2 * .pi)
            s.withUnsafeBufferPointer { self.feed($0) }
        }
        toneTimer = t
        t.resume()
    }

    // MARK: listening

    /// A new talker: reset the jitter buffer for their burst and start the speaker.
    /// Start buffering this talker's frames now (the speaker may come a moment later).
    func armReceive(burst b: UInt8) {
        queue.async { [self] in
            guard jitter.burst != b else { return }
            draining = false
            jitter.reset(burst: b)
            firstFrameAt = nil
            decoder?.reset()
            voiceFX.reset()
            radioVoiceOn = radioVoice()
            endCue = nil
            rx = RxProbe()
        }
    }

    /// `cue`: played first; the voice waits for it (`leadIn`), the jitter buffer fills meanwhile.
    func startPlayback(burst b: UInt8, cue: PTTRadioCue? = nil) {
        armReceive(burst: b)
        if let cue { playCue(cue) }
        queue.async { [self] in
            guard !playing else { return }
            do {
                try ensureEngine()
                playing = true
                player.play()
                /* The squelch opens now; the voice waits for at most `PTTPlayout.maxVoiceLead` of it
                   (the rest of the cue sounds under the first syllable) while the jitter buffer fills
                   in parallel. The pull chain starts when the lead is consumed — not behind two more
                   silent buffers — so the first packet plays right after it (≤ 150 ms budget). */
                let leadSeconds = cue != nil && PTTCueWarmup.isReady ? PTTPlayout.voiceLead(cue: PTTRadioSynth.duration(cue!)) : 0
                if leadSeconds > 0, let lead = Self.silence(seconds: leadSeconds) {
                    firstVoiceAt = nil
                    leadStartedAt = Date().timeIntervalSince1970
                    player.scheduleBuffer(lead, completionCallbackType: .dataConsumed) { [weak self] _ in
                        self?.queue.async {
                            guard let self, self.playing else { return }
                            self.scheduleNext()
                            self.scheduleNext()
                        }
                    }
                } else {
                    firstVoiceAt = nil
                    leadStartedAt = Date().timeIntervalSince1970
                    /* Two buffers in flight keep the chain pulling at the audio clock. */
                    scheduleNext()
                    scheduleNext()
                }
            } catch {
                Self.log.error("[PTT] playback failed: \(String(describing: error), privacy: .public)")
                PTTDiagnosticsLog.shared.add("audio", "speaker failed: \((error as NSError).domain)#\((error as NSError).code)")
            }
        }
    }

    /// The talker let go: play what is still buffered (≤ 2 s), then `cue` (roger + squelch), then stop.
    func stopPlayback(drain: Bool = true, cue: PTTRadioCue? = nil) {
        queue.async { [self] in
            guard playing else { return }
            endCue = cue
            if drain, jitter.depth > 0 {
                draining = true
                let b = jitter.burst
                queue.asyncAfter(deadline: .now() + 2) { [weak self] in
                    guard let self, self.draining, self.jitter.burst == b else { return }
                    self.finishPlayback()
                }
                return
            }
            finishPlayback()
        }
    }

    private func finishPlayback() {
        draining = false
        guard playing else { return }
        playing = false
        if useTestTone || rx.frames > 0 { rx.report(final: true, stats: jitter.stats) }
        jitter.reset(burst: nil)
        player.stop()
        if let c = endCue {
            endCue = nil
            startCue(c)
        }
        stopEngineIfIdle()
    }

    // MARK: radio cues

    /// Plays one cue through the session the route activated. Cues queue one after another.
    func playCue(_ cue: PTTRadioCue) {
        queue.async { [self] in startCue(cue) }
    }

    private func startCue(_ cue: PTTRadioCue) {
        /* Never build the cues here: this queue carries the mic and the friend's voice. */
        guard PTTCueWarmup.isReady else {
            PTTCueWarmup.warm()
            return PTTDiagnosticsLog.shared.add("audio", "cue skipped (still warming)")
        }
        guard let buf = PTTRadioSynth.buffer(cue) else { return }
        do { try ensureEngine() } catch {
            Self.log.error("[PTT] cue failed: \(String(describing: error), privacy: .public)")
            return
        }
        let seconds = Double(buf.frameLength) / PTTAudioFormat.sampleRate
        if capturing {
            /* Room for the cues already queued, plus the speaker's latency. */
            micGateUntil = max(micGateUntil, Date().timeIntervalSince1970) + seconds + 0.08
        }
        cuesInFlight += 1
        cuePlayer.scheduleBuffer(buf, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            self?.queue.async {
                guard let self else { return }
                self.cuesInFlight = max(0, self.cuesInFlight - 1)
                if self.cuesInFlight == 0 { self.cuePlayer.stop() }
                self.stopEngineIfIdle()
            }
        }
        cuePlayer.play()
    }

    /// An audio frame from the socket or the nearby link (any thread).
    func receive(_ f: PTTFrame) {
        queue.async { [self] in
            if jitter.burst == f.burst, jitter.stats.received == 0 { firstFrameAt = Date().timeIntervalSince1970 }
            jitter.push(f)
        }
    }

    /// Latency probes for «سجل القناة» (audio queue only).
    private var leadStartedAt: TimeInterval?
    private var firstFrameAt: TimeInterval?
    private var firstVoiceAt: TimeInterval?

    private func scheduleNext() {
        guard playing else { return }
        let buf: AVAudioPCMBuffer
        switch jitter.pop() {
        case .frame(let f):
            if firstVoiceAt == nil, let t0 = leadStartedAt, let first = firstFrameAt {
                /* Diagnostics: squelch start → first voice packet scheduled, and first frame → it. */
                let now = Date().timeIntervalSince1970
                firstVoiceAt = now
                PTTDiagnosticsLog.shared.add("audio", "first voice: \(Int((now - t0) * 1000)) ms after the squelch, \(Int((now - first) * 1000)) ms after its first frame")
            }
            if f.codec == .aacELD16k, let pcm = decoder?.decode(f.payload) {
                rx.add(pcm)
                if radioVoiceOn { voiceFX.process(pcm) }
                if rx.frames % 33 == 0 { rx.report(final: false, stats: jitter.stats) }
                buf = pcm
            } else {
                buf = Self.silence()
            }
        case .underrun where draining, .wait where draining:
            return finishPlayback()
        case .gap, .wait, .underrun:
            buf = Self.silence()
        }
        player.scheduleBuffer(buf, completionCallbackType: .dataConsumed) { [weak self] _ in
            self?.queue.async { self?.scheduleNext() }
        }
    }

    private static func silence(seconds: TimeInterval) -> AVAudioPCMBuffer? {
        let n = AVAudioFrameCount(seconds * PTTAudioFormat.sampleRate)
        guard n > 0, let b = AVAudioPCMBuffer(pcmFormat: PTTAudioFormat.pcm, frameCapacity: n) else { return nil }
        b.frameLength = n
        return b
    }

    private static func silence() -> AVAudioPCMBuffer {
        let b = AVAudioPCMBuffer(pcmFormat: PTTAudioFormat.pcm, frameCapacity: PTTAudioFormat.samplesPerPacket)!
        b.frameLength = PTTAudioFormat.samplesPerPacket
        return b
    }

    /// Debug numbers about what was actually decoded: level and pitch (zero crossings).
    private struct RxProbe {
        var frames = 0
        var energy: Double = 0
        var samples = 0
        var crossings = 0
        var last: Float = 0

        mutating func add(_ b: AVAudioPCMBuffer) {
            guard let d = b.floatChannelData?[0] else { return }
            frames += 1
            for i in 0..<Int(b.frameLength) {
                let x = d[i]
                energy += Double(x * x)
                if (x >= 0) != (last >= 0) { crossings += 1 }
                last = x
            }
            samples += Int(b.frameLength)
        }

        func report(final: Bool, stats: PTTJitterBuffer.Stats) {
            guard samples > 0 else { return }
            let rms = (energy / Double(samples)).squareRoot()
            let hz = Double(crossings) / 2 / (Double(samples) / PTTAudioFormat.sampleRate)
            PTTAudioEngine.log.notice("[PTT] rx\(final ? " end" : "", privacy: .public) frames=\(frames) rms=\(String(format: "%.3f", rms), privacy: .public) hz=\(Int(hz)) gaps=\(stats.gaps) late=\(stats.late) underruns=\(stats.underruns)")
        }
    }
}

enum PTTError: Error { case noMicrophone }
