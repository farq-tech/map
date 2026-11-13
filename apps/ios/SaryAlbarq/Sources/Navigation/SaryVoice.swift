import AVFoundation
import Foundation

// «صوت سرى»: the owner's Najdi phrases (his own voice, ElevenLabs v4 set) speak the guidance.
// Each spoken line is a short sequence of his clips («بعد ثلاث مية متر.» • «لف يمين.»), built
// from the maneuver itself (kind, direction, exit, distance), never by parsing text.
// Street and place names are never said in his voice: they stay on the banner.
// «صوت الجهاز» (AVSpeechSynthesizer, ar-SA) stays a full option for those who want
// the names; the two are never mixed in one line.

/// Which voice says the guidance (settings → «الصوت واللاسلكي» → «صوت التوجيه»).
enum NavVoiceChoice: String, CaseIterable, Hashable {
    /// The owner's recorded clips (the default).
    case sary
    /// The phone's own Arabic voice (says street and place names too).
    case device

    static let key = "sary.nav.voiceChoice.v1"
    static let `default` = NavVoiceChoice.sary

    static func current(_ defaults: UserDefaults = .standard) -> NavVoiceChoice {
        defaults.string(forKey: key).flatMap(NavVoiceChoice.init(rawValue:)) ?? .default
    }

    var label: String {
        switch self {
        case .sary: "صوت سرى"
        case .device: "صوت الجهاز"
        }
    }
}

/// One spoken line: the full text (the device voice, CarPlay, logs, tests) and the
/// owner's clips for the same meaning (without names). Empty clips: nothing in his voice.
struct NavLine: Equatable {
    var text: String
    var clips: [String]
    /// The maneuver it is about («<step index>»), for «said once per stage» and dropping stale lines.
    var maneuverID: String? = nil
    /// The route it was built for (`NavSession.routeRevision`): a line from an older route is dropped.
    var routeRevision: Int? = nil
    /// Not said after this (guidance goes stale fast).
    var expiresAt: Date? = nil
    /// A safety line: while I am talking on the walkie-talkie it becomes a vibration and a text instead.
    var safety = false
    /// Said before the guidance part («نبدأ التوجيه» + the first instruction): kept when the
    /// guidance part is rebuilt at playback (`NavPromptTiming`).
    var leadText = ""
    var leadClips: [String] = []
    /// Held until then so it ends at a recorded distance; `heldS`: held so far (at most `NavPromptTiming.maxHoldS`).
    var notBefore: Date? = nil
    var heldS = 0.0
    /// The first line of a route (start / reroute): a soft maneuver far ahead may say «كمّل سيده».
    var opening = false
    /// Said again after a call cut it: outside the per-maneuver budget (`NavPromptBudget`).
    var restate = false
    /// Already charged against the per-maneuver budget: a held line, re-queued, is not counted twice.
    var charged = false

    func isHeld(_ now: Date = Date()) -> Bool { notBefore.map { $0 > now } ?? false }

    init(_ text: String, clips: [String], maneuverID: String? = nil, routeRevision: Int? = nil, expiresAt: Date? = nil, safety: Bool = false) {
        self.text = text
        self.clips = clips
        self.maneuverID = maneuverID
        self.routeRevision = routeRevision
        self.expiresAt = expiresAt
        self.safety = safety
    }

    /// Two lines one after the other («نبدأ التوجيه» then the first instruction): b's metadata.
    static func + (a: NavLine, b: NavLine) -> NavLine {
        let t = [a.text, b.text].filter { !$0.isEmpty }.joined(separator: ". ")
        var out = b
        out.text = t
        out.clips = a.clips + b.clips
        out.safety = a.safety || b.safety
        out.leadText = [a.leadText, a.text, b.leadText].filter { !$0.isEmpty }.joined(separator: ". ")
        out.leadClips = a.leadClips + a.clips + b.leadClips
        return out
    }
}

// MARK: - The script: maneuver → clips

enum SaryVoiceScript {
    /// Distances he recorded, metres → clip («بعد …»). Spoken like Google Maps: round numbers.
    static let distances: [(m: Double, key: String)] = [
        (20, "m_06"), (30, "m_07"), (50, "dist_01"), (100, "dist_02"), (150, "dist_03"), (200, "dist_04"),
        (250, "m_02"), (300, "dist_05"), (400, "dist_06"), (500, "dist_07"), (600, "m_03"), (700, "dist_08"),
        (800, "m_04"), (900, "m_05"),
        (1000, "dist_09"), (1500, "dist_10"), (2000, "dist_11"), (2500, "km_18"), (3000, "dist_12"), (3500, "km_19"),
        (4000, "km_01"), (5000, "dist_13"), (6000, "km_02"), (7000, "km_03"), (8000, "km_04"), (9000, "km_05"),
        (10000, "dist_14"), (12000, "x_13"), (15000, "km_06"), (20000, "km_07"), (25000, "km_08"), (30000, "km_09"),
        (35000, "x_14"), (40000, "km_10"), (45000, "x_15"), (50000, "km_11"), (60000, "km_12"), (70000, "km_13"), (80000, "km_14"), (100_000, "km_15"),
        (150_000, "km_16"), (200_000, "km_17"),
    ]
    /// With «ميل» in «وحدات المسافة»: feet and miles he recorded (metres → clip).
    static let imperial: [(m: Double, key: String)] = [
        (152.4, "x_11"), (304.8, "x_12"), (402.336, "x_07"), (804.672, "x_06"), (1609.344, "x_05"),
        (3218.688, "x_08"), (8046.72, "x_09"), (16093.44, "x_10"),
    ]
    /// Miles: under ~300 ft no «بعد …» (500 ft would overstate it), past 15 mi nothing recorded.
    static let imperialNowM = 90.0
    static let imperialFarM = 24_140.0
    /// Under this the maneuver is right here: just the action (as `NavText.spokenInDistance`).
    static let nowM = 30.0
    /// Past the last recorded distance (200 km) by more than half a step: no «بعد …» we could say honestly.
    static let farM = 225_000.0

    /// The «بعد …» clip for `m` metres: the largest recorded distance NOT above `m` (rounded
    /// down, never up: build 21 said «بعد مية متر» at 75 m because 75 rounded to the nearer 100).
    /// nil when it is right here, or farther than we recorded.
    static func distance(_ m: Double, miles: Bool = DistanceUnits.miles) -> String? {
        floorBand(m, miles: miles)?.key
    }

    /// The recorded distance (metres, clip) said for `m`: the largest one ≤ `m`.
    static func floorBand(_ m: Double, miles: Bool = DistanceUnits.miles) -> (m: Double, key: String)? {
        guard m.isFinite else { return nil }
        if miles {
            guard m >= imperialNowM, m <= imperialFarM else { return nil }
            return imperial.last { $0.m <= m + 0.5 }
        }
        guard m >= nowM, m <= farM else { return nil }
        return distances.last { $0.m <= m + 0.5 }
    }

    static func isFar(_ m: Double, miles: Bool = DistanceUnits.miles) -> Bool { m > (miles ? imperialFarM : farM) }

    private enum Side { case right, left }

    private static func side(_ d: NavTurnDirection?) -> Side? {
        switch d {
        case .right, .slightRight, .sharpRight: return .right
        case .left, .slightLeft, .sharpLeft: return .left
        default: return nil
        }
    }

    static func turn(_ d: NavTurnDirection?) -> String {
        switch d {
        case .right: return "turns_01"
        case .left: return "turns_02"
        case .slightRight: return "turns_03"
        case .slightLeft: return "turns_04"
        case .sharpRight: return "mv_03"
        case .sharpLeft: return "mv_04"
        case .uTurn: return "turns_07"
        case .straight, .none: return "mv_02"
        }
    }

    /// Roundabout exits 1–9 («في الدوّار، خذ المخرج …»); the last exit: «خذ آخر مخرج»;
    /// all the way round: «ديور بالدوّار وارجع»; past nine (not the last): «ادخل الدوّار» (the number is on the banner).
    static func roundabout(exit: Int?, direction: NavTurnDirection? = nil, last: Bool = false) -> String {
        if direction == .uTurn { return "x_02" }
        if last { return "x_01" }
        guard let e = exit, (1...9).contains(e) else { return "round_01" }
        return "rb_\(String(format: "%02d", e + 1))"
    }

    /// The verb part, same meaning as `NavText.action` (nearest recorded wording).
    static func action(_ m: NavManeuver) -> [String] {
        let s = side(m.direction)
        switch m.kind {
        case .turn: return [turn(m.direction)]
        case .continue, .newName, .notification:
            if let d = m.direction, d != .straight { return [turn(d)] }
            return ["mv_02"]
        case .merge: return [s == .right ? "mv_13" : s == .left ? "mv_14" : "mv_12"]
        case .onRamp: return [s == .right ? "mv_09" : s == .left ? "mv_10" : "mv_08"]
        case .offRamp: return [s == .right ? "turns_12" : s == .left ? "turns_13" : "mv_11"]
        case .fork: return [s == .right ? "mv_06" : s == .left ? "mv_07" : "mv_05"]
        case .endOfRoad:
            if m.direction == .uTurn { return ["turns_07"] }
            return [s == .right ? "mv_15" : s == .left ? "mv_16" : "mv_02"]
        case .useLane: return [s == .right ? "mv_18" : s == .left ? "mv_19" : "mv_17"]
        case .roundabout:
            /* The exit number is the router's own (Mapbox `maneuver.exit`, Valhalla's
             * roundabout_exit_count through OSRM JSON), never counted by us. Without one:
             * «ادخل الدوّار.» + the direction — never a guessed number. */
            if m.exit == nil, !m.lastExit, let d = m.direction, d != .uTurn { return ["round_01", turn(d)] }
            return [roundabout(exit: m.exit, direction: m.direction, last: m.lastExit)]
        case .exitRoundabout: return ["rb_01"]
        case .depart: return ["mv_01"]
        case .arrive: return ["arr_02"]
        }
    }

    /// One guidance line: [«بعد …»] [the action]. No road name, ever (it is on the banner).
    /// Farther than we recorded: «كمّل سيده» (never an action that sounds like «now»).
    /// `stop`: a stop / rally point on the way (not the destination): «على يمينك» rather than «وجهتك على يمينك».
    static func step(_ step: NavStep, distanceM: Double, auto: Bool = false, stop: Bool = false, miles: Bool = DistanceUnits.miles) -> [String] {
        let far = isFar(distanceM, miles: miles)
        let d = distance(distanceM, miles: miles).map { [$0] } ?? []
        if step.maneuver.kind == .arrive {
            /* The router says which side it is on (Directions' arrive modifier). */
            let side: String?
            switch step.maneuver.direction {
            case .right, .slightRight, .sharpRight: side = stop ? "x_03" : "start_04"
            case .left, .slightLeft, .sharpLeft: side = stop ? "x_04" : "start_05"
            default: side = nil
            }
            if distanceM < nowM { return [side ?? (auto ? "arr_01" : "arr_02")] }
            if far { return ["mv_02"] }
            /* «بعد ثلاث مية متر • وجهتك قدامك». */
            return d + [side ?? "start_06"]
        }
        if far { return ["mv_02"] }
        return d + action(step.maneuver)
    }

    /// The next maneuver comes right after this one: «… وبعدها، لف يسار» (`turns_14` is the connector).
    static let thenWithinM = 150.0

    /// [this line] «وبعدها،» [next action] — only when the next maneuver is close after this one AND
    /// the longer line still ends before I reach this maneuver (time = distance ÷ speed).
    static func withThen(_ line: [String], next: NavStep?, gapM: Double, distanceToManeuverM: Double, speedMps: Double?, stop: Bool = false) -> [String] {
        guard let next, gapM > 0, gapM <= thenWithinM, line.last != "mv_02" else { return line }
        let tail = next.maneuver.kind == .arrive ? [step(next, distanceM: 0, stop: stop).first ?? "start_06"].map { $0 == "arr_02" || $0 == "arr_01" ? "start_06" : $0 } : action(next.maneuver)
        let full = line + ["turns_14"] + tail
        let v = max(3, speedMps ?? 10)
        guard SaryVoiceCatalog.duration(full) < distanceToManeuverM / v else { return line }
        return full
    }

    /// «توجّه شمال» … «توجّه جنوب غرب» (eight directions, like `NavText.compassDefinite`).
    static func compass(_ deg: Double) -> String {
        let keys = ["bar_02", "dir_01", "bar_04", "dir_03", "bar_03", "dir_04", "bar_05", "dir_02"]
        let d = (deg.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        return keys[Int((d + 22.5) / 45) % 8]
    }

    /// The arrow: [lead] [«توجّه …»] [«بعد …» «وجهتك قدّامك»].
    static func arrow(lead: String, bearing: Double, distanceM: Double, miles: Bool = DistanceUnits.miles) -> [String] {
        var out = [lead, compass(bearing)]
        if let d = distance(distanceM, miles: miles) { out += [d, "start_06"] }
        return out
    }

    /// Automatic guidance starts: «بسم الله نبدأ.» / resumed «بدأ التوجيه.» — no name.
    static func intro(resumed: Bool) -> [String] { [resumed ? "start_02" : "start_01"] }
}

// MARK: - The clips in the bundle

/// `SaryVoice/manifest.json` and its m4a files (a folder resource in the app).
enum SaryVoiceCatalog {
    struct Entry: Decodable, Equatable {
        var key: String
        var section: String
        var text: String
        var file: String
    }

    static let folder = "SaryVoice"

    static func manifestURL(_ bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: "manifest", withExtension: "json", subdirectory: folder)
    }

    static func load(_ bundle: Bundle = .main) -> [Entry] {
        guard let u = manifestURL(bundle), let d = try? Data(contentsOf: u) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: d)) ?? []
    }

    static let entries: [Entry] = load()
    static let byKey: [String: Entry] = Dictionary(entries.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })

    static func url(_ key: String, bundle: Bundle = .main) -> URL? {
        guard let e = (bundle == .main ? byKey[key] : load(bundle).first { $0.key == key }) else { return nil }
        let name = (e.file as NSString).deletingPathExtension, ext = (e.file as NSString).pathExtension
        return bundle.url(forResource: name, withExtension: ext, subdirectory: folder)
    }

    /// Every clip of the line is in the bundle.
    static func has(_ keys: [String]) -> Bool {
        !keys.isEmpty && keys.allSatisfy { url($0) != nil }
    }

    private static var durations: [String: Double] = [:]

    /// Seconds of one clip (file header only), for «is there time for «وبعدها،» …».
    static func duration(_ key: String) -> Double {
        if let d = durations[key] { return d }
        guard let u = url(key), let f = try? AVAudioFile(forReading: u) else { return 0 }
        let d = Double(f.length) / f.fileFormat.sampleRate
        durations[key] = d
        return d
    }

    /// The whole line said: clips plus the gaps between them, minus the pads cut at the joins (at most).
    static func duration(_ keys: [String]) -> Double {
        keys.map(duration).reduce(0, +) + Double(max(0, keys.count - 1)) * (SaryClipPlayer.gapS - 2 * SaryClipPlayer.padS)
    }
}

// MARK: - When to speak (time, not only distance)

/// The three cues before a maneuver (early, confirm, immediate), metres, from my speed: off-road
/// in the sand nothing is said 2 km ahead, on the highway 40 m is too late.
enum NavCueBands {
    enum Stage: Int { case early, confirm, immediate }

    static func distances(speedMps: Double?, unpaved: Bool) -> [Double] {
        let kmh = max(0, (speedMps ?? 0) * 3.6)
        switch kmh {
        case ..<20: return [175, 60, 15]                                         // desert track 5–20
        case ..<50 where unpaved: return [550, 200, 50]                          // dirt road 20–50
        case ..<60: return [300, 125, 25]                                        // city 30–50
        case ..<80: return [900, 300, 80]
        default: return [min(2000, max(1000, kmh / 3.6 * 110)).rounded(), 500, 150] // highway: ~110 s ahead (1–2 km)
        }
    }

    /// Which cue a line said at `d` metres before the maneuver is.
    static func stage(distanceM d: Double, bands b: [Double]) -> Stage {
        if d <= b[2] * 1.6 { return .immediate }
        if d <= b[1] * 1.6 { return .confirm }
        return .early
    }
}

// MARK: - Playing a line

/// Joins the clips of one line into ONE PCM buffer (pads cut at the joins, a short silence between them, no crossfade)
/// and plays it on one AVAudioPlayerNode. Decoding happens off the main thread.
@MainActor
final class SaryClipPlayer: NSObject {
    /// Between two clips of one line (added after the silent pads at the join are cut).
    nonisolated static let gapS = 0.035
    /// Every clip has an 80 ms digital-silence pad at both ends. Inside a line the pads at the
    /// joins are cut (never more than the pad, never past the first sample above
    /// `edgeThresholdDB`), so «بعد ثلاث مية متر» + «لف يمين» flow: ~70–100 ms audible gap.
    /// The outer edges of the line keep their pads.
    nonisolated static let padS = 0.080
    nonisolated static let edgeThresholdDB: Float = -50
    nonisolated static let edgeWindowS = 0.002
    /// A micro fade at both edges of every clip (no click at the joins; not a crossfade).
    nonisolated static let fadeS = 0.008
    nonisolated static let sampleRate = 44_100.0

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: SaryClipPlayer.sampleRate, channels: 1)!
    /// Bumped on every play/stop: callbacks of an older line are ignored (stopping the node fires them).
    private var token = 0
    private(set) var isPlaying = false
    /// The last line that could not be composed (`.missing(key)` names the key).
    private(set) var lastError: ComposeError?
    var onFinish: () -> Void = {}
    private var configObserver: NSObjectProtocol?

    override init() {
        super.init()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        /* The output changed (headphones, CarPlay, Bluetooth): the engine stopped; drop the line. */
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.interrupted() }
        }
    }

    enum ComposeError: Error, Equatable { case missing(String), decode(String), format(String) }

    nonisolated(unsafe) private static var cache: [String: [Float]] = [:]
    nonisolated private static let cacheLock = NSLock()

    /// One clip → mono Float samples at 44.1 kHz (converted if a file ever differs).
    nonisolated static func decode(_ url: URL) throws -> (samples: [Float], sampleRate: Double) {
        let f: AVAudioFile
        do { f = try AVAudioFile(forReading: url) } catch { throw ComposeError.decode(url.lastPathComponent) }
        let src = f.processingFormat
        guard f.length > 0, let buf = AVAudioPCMBuffer(pcmFormat: src, frameCapacity: AVAudioFrameCount(f.length)) else {
            throw ComposeError.decode(url.lastPathComponent)
        }
        do { try f.read(into: buf) } catch { throw ComposeError.decode(url.lastPathComponent) }
        var pcm = buf
        if src.sampleRate != sampleRate || src.channelCount != 1 {
            let dst = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
            guard let conv = AVAudioConverter(from: src, to: dst),
                  let out = AVAudioPCMBuffer(pcmFormat: dst, frameCapacity: AVAudioFrameCount(Double(buf.frameLength) * sampleRate / src.sampleRate) + 1024)
            else { throw ComposeError.format(url.lastPathComponent) }
            var fed = false
            var err: NSError?
            conv.convert(to: out, error: &err) { _, status in
                if fed { status.pointee = .endOfStream; return nil }
                fed = true
                status.pointee = .haveData
                return buf
            }
            if err != nil { throw ComposeError.format(url.lastPathComponent) }
            pcm = out
        }
        guard let ch = pcm.floatChannelData, pcm.frameLength > 0 else { throw ComposeError.decode(url.lastPathComponent) }
        return (Array(UnsafeBufferPointer(start: ch[0], count: Int(pcm.frameLength))), sampleRate)
    }

    /// The clips by manifest key, laid end to end with `gap` seconds of silence. A missing key
    /// throws `.missing(key)`: never silently another clip.
    nonisolated static func compose(_ keys: [String], gap: Double = gapS, bundle: Bundle = .main) throws -> (samples: [Float], sampleRate: Double) {
        guard !keys.isEmpty else { throw ComposeError.missing("") }
        var out: [Float] = []
        for (i, k) in keys.enumerated() {
            cacheLock.lock()
            var s = bundle == .main ? cache[k] : nil
            cacheLock.unlock()
            if s == nil {
                guard let u = SaryVoiceCatalog.url(k, bundle: bundle) else { throw ComposeError.missing(k) }
                s = try decode(u).samples
                cacheLock.lock()
                if cache.count > 120 { cache.removeAll() }
                if bundle == .main { cache[k] = s }
                cacheLock.unlock()
            }
            if i > 0 { out += [Float](repeating: 0, count: Int(gap * sampleRate)) }
            out += faded(joinTrimmed(s ?? [], head: i > 0, tail: i < keys.count - 1))
        }
        return (out, sampleRate)
    }

    /// Silent samples (below `edgeThresholdDB`, `edgeWindowS` windows) at the start (`fromEnd` false)
    /// or the end of a clip, capped at the pad: speech is never cut.
    nonisolated static func silentEdge(_ s: [Float], fromEnd: Bool) -> Int {
        let w = max(1, Int(edgeWindowS * sampleRate)), cap = min(Int(padS * sampleRate), s.count / 2)
        let thr = pow(10, edgeThresholdDB / 20)
        var n = 0
        while n + w <= cap {
            var e: Float = 0
            for j in n..<(n + w) { let v = s[fromEnd ? s.count - 1 - j : j]; e += v * v }
            if (e / Float(w)).squareRoot() > thr { break }
            n += w
        }
        return n
    }

    /// The clip with the silent pad cut at the edges that are joins inside the line.
    nonisolated static func joinTrimmed(_ s: [Float], head: Bool, tail: Bool) -> [Float] {
        let a = head ? silentEdge(s, fromEnd: false) : 0
        let b = tail ? silentEdge(s, fromEnd: true) : 0
        guard a + b < s.count else { return s }
        return Array(s[a..<(s.count - b)])
    }

    /// `fadeS` linear ramp in and out at the clip's edges (the middle is untouched).
    nonisolated static func faded(_ s: [Float], fade: Double = fadeS) -> [Float] {
        var s = s
        let n = min(Int(fade * sampleRate), s.count / 2)
        guard n > 0 else { return s }
        for i in 0..<n {
            let g = Float(i) / Float(n)
            s[i] *= g
            s[s.count - 1 - i] *= g
        }
        return s
    }

    /// Decodes off the main thread, then plays the whole line as one buffer. `done(false)`: a clip
    /// is missing (nothing is said in his voice, never half of it).
    func play(_ keys: [String], started: @escaping (Bool) -> Void = { _ in }) {
        stop()
        token += 1
        let t = token
        isPlaying = true
        Task.detached(priority: .userInitiated) {
            let result = Result { try Self.compose(keys) }
            await MainActor.run {
                guard t == self.token else { return }
                if case let .failure(e) = result {
                    /* A missing or broken clip is an error, never a silent substitute. */
                    self.lastError = e as? ComposeError
                    NSLog("[SaryVoice] line not played: %@ [%@]", String(describing: e), keys.joined(separator: " "))
                }
                guard let line = try? result.get(), let buf = self.buffer(line.samples) else {
                    self.isPlaying = false
                    started(false)
                    return self.onFinish()
                }
                do {
                    if !self.engine.isRunning { try self.engine.start() }
                } catch {
                    self.isPlaying = false
                    started(false)
                    return self.onFinish()
                }
                self.node.scheduleBuffer(buf, at: nil, options: [], completionCallbackType: .dataPlayedBack) { [weak self] _ in
                    /* Never stop the player from inside its own callback: hop to main first. */
                    DispatchQueue.main.async { self?.done(t) }
                }
                self.node.play()
                started(true)
            }
        }
    }

    private func buffer(_ s: [Float]) -> AVAudioPCMBuffer? {
        guard !s.isEmpty, let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(s.count)), let ch = b.floatChannelData else { return nil }
        b.frameLength = AVAudioFrameCount(s.count)
        s.withUnsafeBufferPointer { ch[0].update(from: $0.baseAddress!, count: s.count) }
        return b
    }

    private func done(_ t: Int) {
        guard t == token, isPlaying else { return }
        isPlaying = false
        node.stop()
        engine.stop()
        onFinish()
    }

    func stop() {
        token += 1
        guard isPlaying || engine.isRunning else { return }
        isPlaying = false
        node.stop()
        engine.stop()
    }

    /// A call, Siri or a route change: the line is gone (not resumed later).
    func interrupted() {
        let was = isPlaying
        stop()
        if was { onFinish() }
    }
}
