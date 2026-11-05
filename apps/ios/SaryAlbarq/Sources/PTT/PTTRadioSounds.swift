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
    /// «ترددات»: the channel knob turned — a detent click and a breath of static between channels.
    case channelClick
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
    /// Loudest sample any cue may have (≈ −6 dBFS).
    static let peak: Float = 0.5
    /// Each cue's loudness (dBFS RMS): ≈ 6 dB under a voice at «عالي» (`PTTVoiceLevel`). They
    /// used to be built to a 0.35 peak (≈ −13 dBFS RMS) — louder than the voice that followed.
    static let cueRMSDB: Float = -20
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
            /* Short chirp: the voice starts ≤ 120 ms into this cue (PTTPlayout), the chirp sits under its first syllable. */
            out = (opening ?? squelch(ms: 165, seed: 37, decay: 0.45)) + silence(ms: 12) + tone(1_650, ms: 40)
        case .incomingEnd:
            out = tone(1_300, ms: 85) + silence(ms: 15) + squelch(ms: 150, seed: 51, decay: 1)
        case .channelClick:
            out = silence(ms: 3) + click(ms: 9) + silence(ms: 14) + squelch(ms: 140, seed: 61, decay: 1).map { $0 * 0.55 }
        }
        normalise(&out, rmsDB: cueRMSDB, peakCap: peak)
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

    /// A knob detent: a few ms of a damped 2.2 kHz ring over a falling noise burst.
    static func click(ms: Double) -> [Float] {
        let n = count(ms)
        var rng: UInt32 = 71
        return (0..<n).map { i in
            rng = rng &* 1_664_525 &+ 1_013_904_223
            let noise = Float(rng >> 8) / Float(1 << 24) * 2 - 1
            let t = Double(i) / sampleRate
            let env = Float(exp(-t * 900)) * Float(min(1, Double(i) / 8))
            return (Float(sin(2 * .pi * 2_200 * t)) * 0.8 + noise * 0.4) * env
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

    private static func normalise(_ s: inout [Float], rmsDB: Float, peakCap: Float) {
        let m = s.reduce(0) { max($0, abs($1)) }
        let rms = rmsOf(s)
        guard m > 0, rms > 0 else { return }
        let g = min(PTTLoudness.linear(rmsDB) / rms, peakCap / m)
        for i in s.indices { s[i] *= g }
    }

    static func rmsOf(_ s: [Float]) -> Float {
        guard !s.isEmpty else { return 0 }
        return Float((s.reduce(0) { $0 + Double($1 * $1) } / Double(s.count)).squareRoot())
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

/// The cues are built once (the recorded squelch is read from the bundle). Built on the audio
/// queue at the first press, that took seconds on a cold start: the mic tap, the 440 Hz test
/// tone and every received frame waited behind it, and a short press went out as a few frames
/// («ما يوصل، وأحيانًا يوصل»). Now they are built in the background at launch, and a cue that is
/// not ready yet is skipped rather than waited for.
enum PTTCueWarmup {
    private static let lock = NSLock()
    private static var started = false
    private static var ready = false

    static func warm() {
        lock.lock()
        let go = !started
        started = true
        lock.unlock()
        guard go else { return }
        DispatchQueue.global(qos: .utility).async {
            let t0 = Date()
            _ = PTTRadioSynth.samples(.talkPermit)
            lock.lock()
            ready = true
            lock.unlock()
            PTTDiagnosticsLog.shared.add("audio", "radio cues ready in \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
        }
    }

    static var isReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return ready
    }
}

// MARK: - loudness («صوت اللاسلكي»)

/// «صوت اللاسلكي» in «الإعدادات»: how loud a friend's voice comes out of the speaker.
/// The level is the speech loudness the receiver normalises to (RMS of the voiced
/// parts, ≈ LUFS for band-limited speech); a limiter keeps every peak under −1 dBFS.
enum PTTVoiceLevel: String, CaseIterable, Hashable {
    case normal, high, veryHigh

    static let key = "sary.ptt.voiceLevel"
    /// «عالي» by default: the walkie-talkie is used in a car, with wind and engine.
    static let `default` = PTTVoiceLevel.high

    static func current(_ defaults: UserDefaults = .standard) -> PTTVoiceLevel {
        defaults.string(forKey: key).flatMap(PTTVoiceLevel.init(rawValue:)) ?? .default
    }

    var label: String {
        switch self {
        case .normal: "عادي"
        case .high: "عالي"
        case .veryHigh: "عالي جداً"
        }
    }

    /// Speech loudness at the speaker, dBFS RMS.
    var targetDB: Float {
        switch self {
        case .normal: -17
        case .high: -14
        case .veryHigh: -8   // +6 dB over «عالي»; the limiter takes the peaks
        }
    }

    /// The most the receiver boosts a quiet sender (an older build that sends the raw mic).
    var maxGainDB: Float {
        switch self {
        case .normal: 15
        case .high: 20
        case .veryHigh: 26
        }
    }

    /// The radio cues sit ≈ 6 dB under the voice (they are built at `PTTRadioSynth.cueRMSDB`).
    var cueVolume: Float {
        min(1, PTTLoudness.linear(targetDB - 6 - PTTRadioSynth.cueRMSDB))
    }
}

enum PTTLoudness {
    /// −1 dBFS: nothing leaves the chain above this.
    static let ceiling: Float = 0.891
    /// What the sender normalises the mic to before encoding (dBFS RMS of speech).
    static let txTargetDB: Float = -16

    static func linear(_ db: Float) -> Float { pow(10, db / 20) }
    static func db(_ x: Float) -> Float { 20 * log10(max(x, 1e-9)) }

    /// Speech loudness of `s` (dBFS): RMS over 100 ms blocks louder than −50 dBFS (pauses
    /// do not count, like the LUFS gate). −120 for silence.
    static func speechLoudnessDB(_ s: [Float], rate: Double = PTTAudioFormat.sampleRate) -> Float {
        let block = Int(rate / 10)
        var sum = 0.0, n = 0
        var i = 0
        while i + block <= s.count {
            var e = 0.0
            for j in i..<(i + block) { e += Double(s[j] * s[j]) }
            if (e / Double(block)).squareRoot() > 0.00316 { sum += e; n += block }
            i += block
        }
        return n > 0 ? db(Float((sum / Double(n)).squareRoot())) : -120
    }

    static func peak(_ s: [Float]) -> Float { s.reduce(0) { max($0, abs($1)) } }
}

/// Brings speech to `targetDB`: a slow RMS follower (≈ 200 ms), gain that falls fast and
/// rises slowly, held through pauses (the hiss between words is never pumped up).
struct PTTAutoGain {
    let target: Float
    let maxGain: Float
    private let minGain: Float = 0.25
    private let gate: Float = 0.003       // ≈ −50 dBFS: below it is a pause
    private var power: Float
    private(set) var gain: Float

    private static let rate = Float(PTTAudioFormat.sampleRate)
    private static let follow = exp(-1 / (0.2 * rate))
    private static let down = 1 - exp(-1 / (0.04 * rate))
    private static let up = 1 - exp(-1 / (0.5 * rate))

    init(targetDB: Float, maxGainDB: Float, startGainDB: Float) {
        target = PTTLoudness.linear(targetDB)
        maxGain = PTTLoudness.linear(maxGainDB)
        gain = min(PTTLoudness.linear(startGainDB), maxGain)
        /* As if the speech so far were exactly at the start gain's level. */
        power = pow(target / gain, 2)
    }

    mutating func process(_ x: Float) -> Float {
        power = Self.follow * power + (1 - Self.follow) * x * x
        let rms = power.squareRoot()
        if rms > gate {
            let want = min(maxGain, max(minGain, target / rms))
            gain += (want - gain) * (want < gain ? Self.down : Self.up)
        }
        return x * gain
    }
}

/// Peak limiter at `PTTLoudness.ceiling`: instant attack (never over), 80 ms release.
struct PTTLimiter {
    private var gain: Float = 1
    private static let release = 1 - exp(-1 / (0.08 * Float(PTTAudioFormat.sampleRate)))

    mutating func process(_ x: Float) -> Float {
        let c = PTTLoudness.ceiling
        let a = abs(x)
        if a * gain > c { gain = c / a }
        let y = x * gain
        gain += (1 - gain) * Self.release
        return min(c, max(-c, y))
    }
}

/// The sender: mic → `txTargetDB` → limiter → encoder. A quiet phone mic (≈ −30 dBFS of
/// speech at arm's length) used to go on air as it was.
struct PTTTxLevel {
    private var agc = PTTAutoGain(targetDB: PTTLoudness.txTargetDB, maxGainDB: 24, startGainDB: 12)
    private var limiter = PTTLimiter()

    mutating func process(_ x: Float) -> Float { limiter.process(agc.process(x)) }

    mutating func process(_ b: AVAudioPCMBuffer) {
        guard let d = b.floatChannelData?[0] else { return }
        for i in 0..<Int(b.frameLength) { d[i] = process(d[i]) }
    }
}

/// The receiver, after the decoder and the radio voice: make-up to the «صوت اللاسلكي»
/// level (+3…+26 dB for a quiet sender) and a limiter so it never clips.
struct PTTRxLevel {
    private var agc: PTTAutoGain
    private var limiter = PTTLimiter()

    init(_ level: PTTVoiceLevel = .default) {
        /* A sender on this build arrives at ≈ −16 dBFS: start at the gain that needs. */
        agc = PTTAutoGain(targetDB: level.targetDB, maxGainDB: level.maxGainDB,
                          startGainDB: max(0, level.targetDB - PTTLoudness.txTargetDB))
    }

    mutating func process(_ x: Float) -> Float { limiter.process(agc.process(x)) }

    mutating func process(_ b: AVAudioPCMBuffer) {
        guard let d = b.floatChannelData?[0] else { return }
        for i in 0..<Int(b.frameLength) { d[i] = process(d[i]) }
    }
}
