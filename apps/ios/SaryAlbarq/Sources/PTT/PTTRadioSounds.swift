import AVFoundation
import Foundation

/// «أصوات اللاسلكي»: the field-radio feel of «قناة الطلعة».
///
///   * a short squelch burst («كشش») and a tiny chirp when the floor is ours
///     (speak now), a roger beep and a squelch tail when we let go;
///   * the same burst + chirp when a friend comes on air, roger + tail when
///     they stop;
///   * their voice band-limited (≈300–3400 Hz) and lightly compressed.
///
/// The opening «كشش» is a recorded squelch the owner chose
/// (`Resources/Sounds/radio-squelch.caf`, Pixabay Content License — see
/// docs/SOUNDS-LICENSE.md), trimmed and levelled; if it cannot be loaded a
/// synthesised one stands in. Everything else (chirps, roger, squelch tails)
/// is synthesised here at run time (seeded noise, sine tones and biquad
/// filters): nothing is copied from any radio maker or app. One switch
/// in «الإعدادات» turns all of it off (`enabledKey`, on by default).
enum PTTRadioSounds {
    static let enabledKey = "sary.ptt.radioSounds"

    static func enabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? true
    }
}

/// The four moments a radio makes a sound.
enum PTTRadioCue: CaseIterable, Equatable {
    /// The floor is ours and the mic is live: squelch + "speak now" chirp.
    case talkPermit
    /// We let go: roger beep + squelch tail.
    case talkEnd
    /// A friend came on air: squelch + chirp.
    case incomingStart
    /// They let go: roger beep + squelch tail.
    case incomingEnd
}

// MARK: - when

/// Decides which cue (if any) each walkie-talkie event plays. Pure: tested
/// without audio.
///
/// Apple's PushToTalk plays its own tones when *our* transmission begins and
/// ends on a system channel (the Lock Screen talk button included), so the
/// transmit cues stay quiet there and only the in-app route plays them — no
/// double chirp. Incoming transmissions get ours on both routes (the
/// framework is not documented to tone those). Both are flags so a device
/// test can flip them.
struct PTTRadioCueSequencer: Equatable {
    static let systemPlaysTransmitTones = true
    static let systemPlaysReceiveTones = false

    struct Context: Equatable {
        /// «أصوات اللاسلكي».
        var enabled: Bool
        /// The PushToTalk system channel owns the session (and its tones).
        var systemRoute: Bool
    }

    private enum Tx: Equatable {
        case idle
        /// Granted; the audio session is not active yet (system route).
        case waitingForAudio
        /// Live; `cued`: our permit chirp played, so a roger follows.
        case live(cued: Bool)
    }

    private var tx = Tx.idle
    private var rxBurst: UInt8?
    private var rxCued = false

    /// The server (or the nearby link) gave us the floor.
    mutating func talkGranted(audioReady: Bool, _ c: Context) -> PTTRadioCue? {
        tx = .waitingForAudio
        return audioReady ? permit(c) : nil
    }

    /// The audio session became active (system route: `didActivate`).
    mutating func audioBecameReady(_ c: Context) -> PTTRadioCue? {
        guard tx == .waitingForAudio else { return nil }
        return permit(c)
    }

    /// Our transmission is over (released, cut off, lost the floor, muted…).
    mutating func talkEnded(_ c: Context) -> PTTRadioCue? {
        defer { tx = .idle }
        guard tx == .live(cued: true), c.enabled else { return nil }
        return .talkEnd
    }

    /// A friend's transmission starts playing (`burst` tells one press from the next).
    mutating func incomingStarted(burst: UInt8, _ c: Context) -> PTTRadioCue? {
        guard rxBurst != burst else { return nil }
        rxBurst = burst
        rxCued = c.enabled && !(c.systemRoute && Self.systemPlaysReceiveTones)
        return rxCued ? .incomingStart : nil
    }

    /// Their transmission is over. `quiet`: we muted the channel or lost the link — no roger.
    mutating func incomingEnded(quiet: Bool, _ c: Context) -> PTTRadioCue? {
        defer { rxBurst = nil; rxCued = false }
        guard rxBurst != nil, rxCued, c.enabled, !quiet else { return nil }
        return .incomingEnd
    }

    private mutating func permit(_ c: Context) -> PTTRadioCue? {
        let cued = c.enabled && !(c.systemRoute && Self.systemPlaysTransmitTones)
        tx = .live(cued: cued)
        return cued ? .talkPermit : nil
    }
}

// MARK: - what

/// The cues, 16 kHz mono float (the walkie-talkie's own format).
enum PTTRadioSynth {
    static let sampleRate = PTTAudioFormat.sampleRate
    /// Loudest sample of any cue (≈ −9 dBFS): audible next to a voice, never harsh.
    static let peak: Float = 0.35
    static let maxDuration = 0.4
    static let squelchResource = "radio-squelch"

    /// Each cue, built once (the recorded squelch when the bundle has it).
    private static let cache: [PTTRadioCue: [Float]] = {
        let rec = recordedSquelch()
        return Dictionary(uniqueKeysWithValues: PTTRadioCue.allCases.map { ($0, samples($0, squelch: rec)) })
    }()

    static func samples(_ cue: PTTRadioCue) -> [Float] { cache[cue] ?? [] }

    /// `squelch`: the recorded opening burst (nil: synthesise one).
    static func samples(_ cue: PTTRadioCue, squelch rec: [Float]?) -> [Float] {
        /* The recording at the tones' level, so the mix normalises the same. */
        let opening = rec.flatMap { $0.isEmpty ? nil : scaled($0, to: 0.6) }
        var out: [Float]
        switch cue {
        case .talkPermit:
            out = (opening ?? squelch(ms: 140, seed: 11, decay: 0.5)) + silence(ms: 12) + tone(1_450, ms: 34) + silence(ms: 8) + tone(1_950, ms: 46)
        case .talkEnd:
            out = tone(1_850, ms: 55) + silence(ms: 10) + tone(1_250, ms: 70) + silence(ms: 15) + squelch(ms: 110, seed: 23, decay: 1)
        case .incomingStart:
            out = (opening ?? squelch(ms: 165, seed: 37, decay: 0.45)) + silence(ms: 12) + tone(1_650, ms: 55)
        case .incomingEnd:
            out = tone(1_300, ms: 85) + silence(ms: 15) + squelch(ms: 150, seed: 51, decay: 1)
        }
        normalise(&out, to: peak)
        fade(&out, ms: 2)
        return out
    }

    static func duration(_ cue: PTTRadioCue) -> TimeInterval { Double(samples(cue).count) / sampleRate }

    /// `radio-squelch.caf` (16 kHz mono) as floats; nil when missing or unreadable.
    static func recordedSquelch(bundle: Bundle = .main) -> [Float]? {
        guard let url = bundle.url(forResource: squelchResource, withExtension: "caf"),
              let f = try? AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false),
              f.processingFormat.sampleRate == sampleRate, f.processingFormat.channelCount == 1, f.length > 0,
              let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)),
              (try? f.read(into: b)) != nil, let d = b.floatChannelData?[0] else { return nil }
        let s = Array(UnsafeBufferPointer(start: d, count: Int(b.frameLength)))
        /* Leave room for the chirp after it. */
        return Double(s.count) / sampleRate <= 0.25 ? s : nil
    }

    private static func scaled(_ s: [Float], to target: Float) -> [Float] {
        let m = s.reduce(0) { max($0, abs($1)) }
        return m > 0 ? s.map { $0 * target / m } : s
    }

    static func buffer(_ cue: PTTRadioCue) -> AVAudioPCMBuffer? {
        let s = samples(cue)
        guard let b = AVAudioPCMBuffer(pcmFormat: PTTAudioFormat.pcm, frameCapacity: AVAudioFrameCount(s.count)),
              let d = b.floatChannelData?[0] else { return nil }
        b.frameLength = AVAudioFrameCount(s.count)
        s.withUnsafeBufferPointer { d.update(from: $0.baseAddress!, count: s.count) }
        return b
    }

    /// Band-passed white noise (≈300–3000 Hz) with a 3 ms attack: the «كشش».
    /// `decay` 0…1: how much of the burst is fading out (1 = a tail that dies away).
    static func squelch(ms: Double, seed: UInt32, decay: Double) -> [Float] {
        let n = count(ms)
        var rng = seed
        var hp = Biquad.highPass(300, q: 0.7)
        var lp1 = Biquad.lowPass(3_000, q: 0.7)
        var lp2 = Biquad.lowPass(3_000, q: 0.7)
        let attack = count(3)
        let decayFrom = Int(Double(n) * (1 - decay))
        return (0..<n).map { i in
            rng = rng &* 1_664_525 &+ 1_013_904_223
            let white = Float(rng >> 8) / Float(1 << 24) * 2 - 1
            var x = lp2.run(lp1.run(hp.run(white)))
            /* A slight crackle: the real thing is never smooth. */
            if rng % 97 == 0 { x *= 2.2 }
            let env: Float
            if i < attack { env = Float(i) / Float(attack) }
            else if i >= decayFrom { env = Float(exp(-4 * Double(i - decayFrom) / Double(max(1, n - decayFrom)))) }
            else { env = 1 }
            return x * env
        }
    }

    /// A sine with a 4 ms rise and fall (no clicks), slightly lower than the noise.
    static func tone(_ hz: Double, ms: Double) -> [Float] {
        let n = count(ms)
        let ramp = count(4)
        return (0..<n).map { i in
            let env = Float(min(1, Double(min(i, n - 1 - i)) / Double(ramp)))
            return Float(sin(2 * .pi * hz * Double(i) / sampleRate)) * 0.6 * env
        }
    }

    static func silence(ms: Double) -> [Float] { [Float](repeating: 0, count: count(ms)) }

    private static func count(_ ms: Double) -> Int { Int(sampleRate * ms / 1000) }

    private static func normalise(_ s: inout [Float], to target: Float) {
        let m = s.reduce(0) { max($0, abs($1)) }
        guard m > 0 else { return }
        let g = target / m
        for i in s.indices { s[i] *= g }
    }

    private static func fade(_ s: inout [Float], ms: Double) {
        let n = min(count(ms), s.count / 2)
        guard n > 0 else { return }
        for i in 0..<n {
            let g = Float(i) / Float(n)
            s[i] *= g
            s[s.count - 1 - i] *= g
        }
    }
}

// MARK: - the received voice

/// «صوت لاسلكي» on a friend's voice: 300–3400 Hz band, a gentle compressor
/// (3:1 over −20 dBFS, quick attack, slow release) and a soft limiter. Keeps
/// state between 30 ms packets; `reset()` at each new transmission.
struct PTTRadioVoiceFX {
    private var hp1 = Biquad.highPass(300, q: 0.7)
    private var hp2 = Biquad.highPass(300, q: 0.7)
    private var lp1 = Biquad.lowPass(3_400, q: 0.7)
    private var lp2 = Biquad.lowPass(3_400, q: 0.7)
    private var envelope: Float = 0

    static let threshold: Float = 0.1   // −20 dBFS
    static let ratio: Float = 3
    static let makeUp: Float = 1.6
    private static let attack = Float(exp(-1 / (0.003 * PTTRadioSynth.sampleRate)))
    private static let release = Float(exp(-1 / (0.12 * PTTRadioSynth.sampleRate)))

    mutating func reset() { self = PTTRadioVoiceFX() }

    mutating func process(_ x: Float) -> Float {
        var y = lp2.run(lp1.run(hp2.run(hp1.run(x))))
        let a = abs(y)
        let k = a > envelope ? Self.attack : Self.release
        envelope = k * envelope + (1 - k) * a
        if envelope > Self.threshold {
            /* Gain that maps the envelope to threshold + (env − threshold) / ratio, in dB. */
            let over = 20 * log10(envelope / Self.threshold)
            y *= pow(10, -(over - over / Self.ratio) / 20)
        }
        return tanh(y * Self.makeUp)
    }

    mutating func process(_ b: AVAudioPCMBuffer) {
        guard let d = b.floatChannelData?[0] else { return }
        for i in 0..<Int(b.frameLength) { d[i] = process(d[i]) }
    }
}

/// RBJ cookbook biquad (direct form I), at the walkie-talkie's 16 kHz.
struct Biquad: Equatable {
    var b0: Float, b1: Float, b2: Float, a1: Float, a2: Float
    var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0

    static func lowPass(_ f: Double, q: Double, rate: Double = PTTAudioFormat.sampleRate) -> Biquad {
        let w = 2 * Double.pi * f / rate, c = cos(w), al = sin(w) / (2 * q), a0 = 1 + al
        return Biquad(b0: Float((1 - c) / 2 / a0), b1: Float((1 - c) / a0), b2: Float((1 - c) / 2 / a0),
                      a1: Float(-2 * c / a0), a2: Float((1 - al) / a0))
    }

    static func highPass(_ f: Double, q: Double, rate: Double = PTTAudioFormat.sampleRate) -> Biquad {
        let w = 2 * Double.pi * f / rate, c = cos(w), al = sin(w) / (2 * q), a0 = 1 + al
        return Biquad(b0: Float((1 + c) / 2 / a0), b1: Float(-(1 + c) / a0), b2: Float((1 + c) / 2 / a0),
                      a1: Float(-2 * c / a0), a2: Float((1 - al) / a0))
    }

    mutating func run(_ x: Float) -> Float {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1; x1 = x
        y2 = y1; y1 = y
        return y
    }
}
