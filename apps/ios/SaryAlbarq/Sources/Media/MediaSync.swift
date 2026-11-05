import Foundation

// Pure rules for «يوتيوب» — no UIKit, no network, so all of it is unit-tested.

/// «قناة الطلعة» as the server shares it (`media_state.state`, `GET /:id/media`).
/// Only what is playing and where: every phone plays its own embedded player.
struct SharedMediaState: Codable, Equatable {
    var video_id: String
    var title: String
    var controller_user_id: String
    var position_s: Double
    var playing: Bool
    var rate: Double
    var queue: [String]
    var updated_at: String?
    /// Server time at which `position_s` was true.
    var at: String

    init(video_id: String, title: String = "", controller_user_id: String, position_s: Double = 0, playing: Bool = true,
         rate: Double = 1, queue: [String] = [], updated_at: String? = nil, at: String) {
        self.video_id = video_id
        self.title = title
        self.controller_user_id = controller_user_id
        self.position_s = position_s
        self.playing = playing
        self.rate = rate
        self.queue = queue
        self.updated_at = updated_at
        self.at = at
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        video_id = try c.decode(String.self, forKey: .video_id)
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? ""
        controller_user_id = try c.decode(String.self, forKey: .controller_user_id)
        position_s = (try? c.decodeIfPresent(Double.self, forKey: .position_s)) ?? 0
        playing = (try? c.decodeIfPresent(Bool.self, forKey: .playing)) ?? false
        rate = (try? c.decodeIfPresent(Double.self, forKey: .rate)) ?? 1
        queue = (try? c.decodeIfPresent([String].self, forKey: .queue)) ?? []
        updated_at = try? c.decodeIfPresent(String.self, forKey: .updated_at)
        at = try c.decode(String.self, forKey: .at)
    }

    /// Where the video should be at `serverNow`: position_s + (now − at) × rate while playing.
    func position(atServer serverNow: Date) -> Double {
        guard playing, let atDate = ISODate.parse(at) else { return position_s }
        return position_s + max(0, serverNow.timeIntervalSince(atDate)) * rate
    }

    /// Same, from this device's clock and the measured offset (server − device, ms).
    func position(deviceNow: Date, clockOffsetMs: Double) -> Double {
        position(atServer: deviceNow.addingTimeInterval(clockOffsetMs / 1000))
    }
}

enum MediaSync {
    /// Seek only when we are further off than this (YouTube buffers; small drift is normal).
    static let driftThreshold: Double = 2
    /// How often a follower compares its player to the shared clock.
    static let checkInterval: TimeInterval = 2

    /// What the local player reports.
    struct PlayerReading: Equatable {
        var videoId: String?
        var position: Double
        var playing: Bool
        var rate: Double
    }

    enum Command: Equatable {
        case load(videoId: String, start: Double, play: Bool)
        case seek(Double)
        case play
        case pause
        case rate(Double)
    }

    /// Commands that bring `player` in line with `target` at `expected` seconds.
    /// Nothing at all when we are already close enough — no churn every tick.
    static func plan(target: SharedMediaState, expected: Double, player: PlayerReading) -> [Command] {
        guard player.videoId == target.video_id else {
            return [.load(videoId: target.video_id, start: max(0, expected), play: target.playing)] + (target.rate != 1 ? [.rate(target.rate)] : [])
        }
        var out: [Command] = []
        if abs(player.rate - target.rate) > 0.01 { out.append(.rate(target.rate)) }
        if abs(player.position - expected) > driftThreshold { out.append(.seek(max(0, expected))) }
        if target.playing != player.playing { out.append(target.playing ? .play : .pause) }
        return out
    }

    static func drift(expected: Double, actual: Double) -> Double { actual - expected }
}

/// Who may do what in «قناة الطلعة» — the same rules the server enforces.
enum MediaPermissions {
    /// Anyone may start when nothing is playing.
    static func canStart(_ s: SharedMediaState?) -> Bool { s == nil }
    /// play / pause / seek / load / next / stop: the controller, the owner or a co-leader.
    static func canControl(_ s: SharedMediaState?, me: String, iLead: Bool) -> Bool {
        guard let s else { return false }
        return s.controller_user_id == me || iLead
    }
    /// Any member may suggest the next video while something plays.
    static func canQueue(_ s: SharedMediaState?) -> Bool {
        guard let s else { return false }
        return s.queue.count < queueMax
    }
    /// Owner / co-leader take control from someone else.
    static func canTakeover(_ s: SharedMediaState?, me: String, iLead: Bool) -> Bool {
        guard let s else { return false }
        return iLead && s.controller_user_id != me
    }

    static let queueMax = 20
}

/// The two channels share ONE embedded player: only one plays at a time.
enum MediaChannel: String, CaseIterable, Hashable {
    case mine
    case outing

    var title: String { self == .mine ? "قناتي" : "قناة الطلعة" }
}

/// The «يوتيوب» state machine: which channel owns the player, and whether I follow the outing's.
struct MediaCoordinator: Equatable {
    /// The channel whose video is in the player (nil = no player).
    private(set) var active: MediaChannel?
    /// I joined «قناة الطلعة» (I follow its video and clock).
    private(set) var joinedShared = false
    /// Something forced a stop (app in background, CarPlay): nothing plays until the person presses play.
    private(set) var held = false

    enum Event: Equatable {
        case playPrivate
        case stopPrivate
        case joinShared
        case leaveShared
        /// The outing's channel went idle (stopped, outing ended, server forgot it).
        case sharedEnded
        case background
        case carPlay
        case resume
    }

    enum Effect: Equatable {
        case pausePlayer
        case unloadPlayer
        case startPrivate
        case followShared
    }

    @discardableResult
    mutating func handle(_ e: Event) -> [Effect] {
        switch e {
        case .playPrivate:
            held = false
            let wasShared = joinedShared
            joinedShared = false
            active = .mine
            return wasShared ? [.pausePlayer, .startPrivate] : [.startPrivate]
        case .stopPrivate:
            guard active == .mine else { return [] }
            active = nil
            return [.unloadPlayer]
        case .joinShared:
            held = false
            let effects: [Effect] = active == .mine ? [.pausePlayer, .followShared] : [.followShared]
            joinedShared = true
            active = .outing
            return effects
        case .leaveShared:
            guard joinedShared else { return [] }
            joinedShared = false
            if active == .outing { active = nil; return [.unloadPlayer] }
            return []
        case .sharedEnded:
            guard joinedShared || active == .outing else { return [] }
            joinedShared = false
            if active == .outing { active = nil; return [.unloadPlayer] }
            return []
        case .background, .carPlay:
            guard active != nil else { return [] }
            held = true
            return [.pausePlayer]
        case .resume:
            guard held else { return [] }
            held = false
            return active == .outing && joinedShared ? [.followShared] : []
        }
    }

    /// Follow the shared clock (seek / play / pause to match it)?
    var follows: Bool { joinedShared && active == .outing && !held }
}

/// Driver safety for the player's size (drive mode + moving).
enum DriveGate {
    /// Above this the phone is "moving" (km/h).
    static let movingKmh: Double = 15

    enum Presentation: Equatable {
        /// Normal size.
        case full
        /// The smallest player YouTube allows (≥ 200 × 200 pt, still visible),
        /// with «للركّاب» and «أنا راكب» to get the full size.
        case compact
    }

    static func isMoving(speedMps: Double?) -> Bool {
        guard let s = speedMps, s >= 0 else { return false }
        return s * 3.6 > movingKmh
    }

    static func presentation(driveMode: Bool, speedMps: Double?, passengerConfirmed: Bool) -> Presentation {
        guard driveMode, isMoving(speedMps: speedMps), !passengerConfirmed else { return .full }
        return .compact
    }

    /// YouTube's minimum embedded player size (points).
    static let minPlayerSide: Double = 200
}

/// "٣:٠٥" / "١:٠٢:٠٣" with Arabic-Indic digits.
enum MediaFormat {
    static func time(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        let h = s / 3600, m = (s % 3600) / 60, r = s % 60
        let two = { (n: Int) in n < 10 ? "0\(n)" : "\(n)" }
        let raw = h > 0 ? "\(h):\(two(m)):\(two(r))" : "\(m):\(two(r))"
        return SaryFormat.digits(raw)
    }

    /// Keeps "١:٠٥" in reading order inside Arabic text.
    static func ltr(_ s: String) -> String { "\u{2066}\(s)\u{2069}" }
}
