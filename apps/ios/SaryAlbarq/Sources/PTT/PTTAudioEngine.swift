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
    private var toneTimer: DispatchSourceTimer?
    private var tonePhase = 0.0
    private var levelAt = 0.0
    private var rx = RxProbe()
    let useTestTone: Bool

    init(testTone: Bool = PTTAudioEngine.testToneRequested) {
        useTestTone = testTone
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
            attached = true
        }
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
    }

    private func stopEngineIfIdle() {
        guard !capturing, !playing else { return }
        engine.stop()
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
                input.removeTap(onBus: 0)
                input.installTap(onBus: 0, bufferSize: 1024, format: hw) { [weak self] buf, _ in
                    self?.queue.async { self?.captured(buf) }
                }
                try ensureEngine()
            } catch {
                Self.log.error("[PTT] capture failed: \(String(describing: error), privacy: .public)")
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
            decoder?.reset()
            rx = RxProbe()
        }
    }

    func startPlayback(burst b: UInt8) {
        armReceive(burst: b)
        queue.async { [self] in
            guard !playing else { return }
            do {
                try ensureEngine()
                playing = true
                player.play()
                /* Two buffers in flight keep the chain pulling at the audio clock. */
                scheduleNext()
                scheduleNext()
            } catch {
                Self.log.error("[PTT] playback failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// The talker let go: play what is still buffered (≤ 2 s), then stop.
    func stopPlayback(drain: Bool = true) {
        queue.async { [self] in
            guard playing else { return }
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
        stopEngineIfIdle()
    }

    /// An audio frame from the socket or the nearby link (any thread).
    func receive(_ f: PTTFrame) {
        queue.async { [self] in jitter.push(f) }
    }

    private func scheduleNext() {
        guard playing else { return }
        let buf: AVAudioPCMBuffer
        switch jitter.pop() {
        case .frame(let f):
            if f.codec == .aacELD16k, let pcm = decoder?.decode(f.payload) {
                rx.add(pcm)
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
