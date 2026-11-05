import Foundation

// «إذاعة الطلعة» — pure rules (no AVFoundation, no network), all unit-tested.
// Server side: apps/api/lib/outings/group-audio.js · docs/GROUP-AUDIO.md.

enum GroupAudioSource: String, Codable, CaseIterable, Hashable {
    case radio
    case quran
    case audius

    var title: String {
        switch self {
        case .radio: return "إذاعات"
        case .quran: return "قرآن"
        case .audius: return "Audius"
        }
    }
}

/// One thing the trip can listen to.
struct GroupAudioItem: Codable, Equatable, Hashable, Identifiable {
    var source: GroupAudioSource
    /// Station id · mp3quran URL · Audius track id.
    var id: String
    var title: String
    var subtitle: String
    /// Stream URL (radio: from the server's catalog; quran: the surah file; audius: nil → resolved here).
    var url: String?
    var live: Bool
    var duration_s: Double?

    init(source: GroupAudioSource, id: String, title: String, subtitle: String = "", url: String? = nil, live: Bool = false, duration_s: Double? = nil) {
        self.source = source
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.url = url
        self.live = live
        self.duration_s = duration_s
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try c.decode(GroupAudioSource.self, forKey: .source)
        id = try c.decode(String.self, forKey: .id)
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? ""
        subtitle = (try? c.decodeIfPresent(String.self, forKey: .subtitle)) ?? ""
        url = try? c.decodeIfPresent(String.self, forKey: .url)
        live = (try? c.decodeIfPresent(Bool.self, forKey: .live)) ?? (source == .radio)
        duration_s = try? c.decodeIfPresent(Double.self, forKey: .duration_s)
    }

    static let audiusAppName = "SaryAlbarq"

    /// What this phone opens. Only https.
    var streamURL: URL? {
        switch source {
        case .radio, .quran:
            guard let u = url.flatMap(URL.init(string:)), u.scheme == "https" else { return nil }
            return u
        case .audius:
            guard id.allSatisfy({ $0.isLetter || $0.isNumber }), !id.isEmpty else { return nil }
            return URL(string: "https://api.audius.co/v1/tracks/\(id)/stream?app_name=\(Self.audiusAppName)")
        }
    }

    /// What we send: a station by id only (the server fills in the URL from its catalog).
    var wire: [String: Any] {
        switch source {
        case .radio: return ["source": "radio", "id": id]
        case .quran:
            var b: [String: Any] = ["source": "quran", "url": url ?? id, "title": String(title.prefix(100)), "subtitle": String(subtitle.prefix(100))]
            if let duration_s { b["duration_s"] = duration_s }
            return b
        case .audius:
            var b: [String: Any] = ["source": "audius", "id": id, "title": String(title.prefix(100)), "subtitle": String(subtitle.prefix(100))]
            if let duration_s { b["duration_s"] = duration_s }
            return b
        }
    }
}

/// The trip's now-playing as the server shares it (`group_audio_state.state`).
struct GroupAudioState: Codable, Equatable {
    var allow_all: Bool
    var item: GroupAudioItem?
    var playing: Bool
    var position_s: Double
    var queue: [GroupAudioItem]
    var by: String?
    var started_at: String?
    var seq: Int
    /// Server time at which `position_s` was true.
    var at: String

    init(allow_all: Bool = false, item: GroupAudioItem? = nil, playing: Bool = false, position_s: Double = 0,
         queue: [GroupAudioItem] = [], by: String? = nil, started_at: String? = nil, seq: Int = 0, at: String) {
        self.allow_all = allow_all
        self.item = item
        self.playing = playing
        self.position_s = position_s
        self.queue = queue
        self.by = by
        self.started_at = started_at
        self.seq = seq
        self.at = at
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        allow_all = (try? c.decodeIfPresent(Bool.self, forKey: .allow_all)) ?? false
        item = try? c.decodeIfPresent(GroupAudioItem.self, forKey: .item)
        playing = (try? c.decodeIfPresent(Bool.self, forKey: .playing)) ?? false
        position_s = (try? c.decodeIfPresent(Double.self, forKey: .position_s)) ?? 0
        queue = (try? c.decodeIfPresent([GroupAudioItem].self, forKey: .queue)) ?? []
        by = try? c.decodeIfPresent(String.self, forKey: .by)
        started_at = try? c.decodeIfPresent(String.self, forKey: .started_at)
        seq = (try? c.decodeIfPresent(Int.self, forKey: .seq)) ?? 0
        at = (try? c.decodeIfPresent(String.self, forKey: .at)) ?? ISODate.string(Date())
    }

    static func idle(at: Date = Date()) -> GroupAudioState { GroupAudioState(at: ISODate.string(at)) }

    var isIdle: Bool { item == nil }

    /// Where a file should be at `serverNow`: position_s + (now − at) while playing; 0 for live radio.
    func position(atServer serverNow: Date) -> Double {
        guard let item, !item.live else { return 0 }
        guard playing, let atDate = ISODate.parse(at) else { return position_s }
        var p = position_s + max(0, serverNow.timeIntervalSince(atDate))
        if let d = item.duration_s, d > 0 { p = min(p, d) }
        return p
    }

    func position(deviceNow: Date, clockOffsetMs: Double) -> Double {
        position(atServer: deviceNow.addingTimeInterval(clockOffsetMs / 1000))
    }
}

/// One command (`POST /:id/group-audio`, `group_audio_cmd`).
struct GroupAudioCommand: Equatable {
    enum Action: String { case play_item, play, pause, seek, next, stop, queue_add, allow_all }
    var action: Action
    var item: GroupAudioItem?
    var position: Double?
    var value: Bool?

    static func play(_ item: GroupAudioItem) -> GroupAudioCommand { .init(action: .play_item, item: item) }
    static func resume(at p: Double? = nil) -> GroupAudioCommand { .init(action: .play, position: p) }
    static func pause(at p: Double? = nil) -> GroupAudioCommand { .init(action: .pause, position: p) }
    static func seek(_ p: Double) -> GroupAudioCommand { .init(action: .seek, position: p) }
    static let next = GroupAudioCommand(action: .next)
    static let stop = GroupAudioCommand(action: .stop)
    static func queue(_ item: GroupAudioItem) -> GroupAudioCommand { .init(action: .queue_add, item: item) }
    static func allowAll(_ on: Bool) -> GroupAudioCommand { .init(action: .allow_all, value: on) }

    var body: [String: Any] {
        var b: [String: Any] = ["action": action.rawValue]
        if let item { b["item"] = item.wire }
        if let position { b["position_s"] = (max(0, position) * 1000).rounded() / 1000 }
        if let value { b["value"] = value }
        return b
    }
}

/// The same rules the server enforces.
enum GroupAudioPermissions {
    /// Play / pause / next / stop / pick: the leader (owner or co-leader), or anyone with «الكل يقدر يشغّل».
    static func canControl(_ s: GroupAudioState?, iLead: Bool) -> Bool { iLead || s?.allow_all == true }
    /// «الكل يقدر يشغّل» is the leader's switch.
    static func canSetAllowAll(iLead: Bool) -> Bool { iLead }
    /// Anyone may suggest the next item while something plays.
    static func canQueue(_ s: GroupAudioState?) -> Bool {
        guard let s, s.item != nil else { return false }
        return s.queue.count < queueMax
    }

    static let queueMax = 20
}

/// Keeping a file (Quran surah, Audius track) on the shared clock.
enum GroupAudioSync {
    /// Inside this, leave the player alone (s).
    static let tolerance: Double = 0.3
    /// Beyond this, seek; between tolerance and this, nudge the rate (s).
    static let seekBeyond: Double = 3
    static let slow: Float = 0.95
    static let fast: Float = 1.05
    /// How often a phone compares its player to the shared clock.
    static let checkInterval: TimeInterval = 1

    enum Action: Equatable {
        case none
        case rate(Float)
        case seek(Double)
    }

    /// `actual − expected` > 0: we are ahead.
    static func drift(expected: Double, actual: Double) -> Double { actual - expected }

    /// What to do so `actual` meets `expected`. Live radio never gets here.
    static func plan(expected: Double, actual: Double, rate: Float) -> Action {
        let d = drift(expected: expected, actual: actual)
        if abs(d) > seekBeyond { return .seek(max(0, expected)) }
        if abs(d) <= tolerance { return rate == 1 ? .none : .rate(1) }
        let want: Float = d > 0 ? slow : fast
        return rate == want ? .none : .rate(want)
    }

    /// Server − device (ms) from one round trip: the server's time is taken as the midpoint.
    static func clockOffsetMs(serverNow: Date, sentAt: Date, receivedAt: Date) -> Double {
        let mid = sentAt.addingTimeInterval(receivedAt.timeIntervalSince(sentAt) / 2)
        return serverNow.timeIntervalSince(mid) * 1000
    }
}

/// Who else wants the speaker right now, and what the music does about it.
///
///   navigation voice → music at 20 % (ducked), back to full after
///   push-to-talk     → music paused (the session becomes play-and-record), resumed after
///   interruption     → paused (a call, Siri, another app); resumed after if iOS says so,
///                      or if it was ours (PTT / nav)
///   «اسكت عندي»       → paused locally until unmuted; everyone else keeps listening
struct GroupAudioDucking: Equatable {
    private(set) var navSpeaking = false
    private(set) var ptt = false
    private(set) var interrupted = false
    private(set) var muted = false

    static let duckedVolume: Float = 0.2

    enum Event: Equatable {
        case navBegan, navEnded
        case pttBegan, pttEnded
        case interruptionBegan
        case interruptionEnded(shouldResume: Bool)
        case mute, unmute
    }

    enum Effect: Equatable {
        case volume(Float)
        case pause
        /// Re-activate `.playback` and play again (seek back to the shared position first).
        case resume
    }

    /// The local player should be running (when the trip has something playing).
    var shouldPlay: Bool { !ptt && !interrupted && !muted }
    var volume: Float { navSpeaking ? Self.duckedVolume : 1 }

    @discardableResult
    mutating func handle(_ e: Event) -> [Effect] {
        let wasPlaying = shouldPlay
        let wasVolume = volume
        switch e {
        case .navBegan: navSpeaking = true
        case .navEnded: navSpeaking = false
        case .pttBegan: ptt = true
        case .pttEnded: ptt = false
        case .interruptionBegan: interrupted = true
        case let .interruptionEnded(shouldResume):
            /* A call the person ended: iOS says whether to resume. Ours (PTT, nav): always. */
            interrupted = false
            /* iOS asked us not to resume (e.g. the person played another app): stay quiet until
             * they press play — never blast music over what they chose. Our own PTT is not an
             * interruption here: it has its own .pttBegan / .pttEnded. */
            if !shouldResume { muted = true }
        case .mute: muted = true
        case .unmute: muted = false
        }
        var out: [Effect] = []
        if wasPlaying && !shouldPlay { out.append(.pause) }
        if !wasPlaying && shouldPlay { out.append(.resume) }
        /* Volume only matters while playing (on resume it is set again). */
        if shouldPlay, volume != wasVolume || !wasPlaying { out.append(.volume(volume)) }
        return out
    }
}

/// «٣:٠٥» with Arabic-Indic digits (same as YouTube's MediaFormat).
enum GroupAudioFormat {
    static func time(_ s: Double) -> String { MediaFormat.time(s) }
}
