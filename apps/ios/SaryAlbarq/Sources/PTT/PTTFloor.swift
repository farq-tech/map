import Foundation

/// Half-duplex floor control on the phone — the twin of the server's rules in
/// apps/api/lib/outings/ptt.js. Pure: events in, effects out; the walkie-talkie
/// performs the effects (socket, microphone, speaker, system PTT UI).
///
///   idle ──press──▶ requesting ──grant──▶ talking ──release / 60 s / server──▶ idle
///     ▲                │ deny / release                                         │
///     └────────────────┘                                                        │
///   idle ──someone else's ptt_talker──▶ listening ──ptt_idle──▶ idle ◀──────────┘
///
/// The server is the authority: a press while someone else talks is refused
/// here without asking, and a grant that arrives after the finger is up is
/// handed straight back.
struct PTTFloor: Equatable {
    enum State: Equatable {
        case idle
        case requesting(id: Int, atMs: Double)
        case talking(burst: UInt8, sinceMs: Double)
        case listening(PTTTalker)
    }

    enum Effect: Equatable {
        case sendStart(id: Int)
        case sendStop
        /// Microphone on; frames carry this burst.
        case startCapture(burst: UInt8)
        case stopCapture
        /// Prepare the speaker for this talker («فلان يتكلم»).
        case startPlayback(PTTTalker)
        case stopPlayback
        /// Tell the person why nothing happened.
        case refused(Refusal)
        /// We were cut off (60 s, silence, the server).
        case cutOff(PTTIdleReason)
    }

    enum Refusal: Equatable {
        case busy(talkerId: String?)
        case muted
        case offline
        case rateLimited
        case notAllowed
    }

    static let maxTalkMs = 60_000.0
    /// No answer to a floor request within this → give up.
    static let requestTimeoutMs = 3_000.0

    let me: String
    private(set) var state: State = .idle
    private(set) var muted = false
    private(set) var maxTalkMs = PTTFloor.maxTalkMs
    private var nextId = 0

    init(me: String) { self.me = me }

    // MARK: my button

    mutating func pressDown(nowMs: Double, online: Bool) -> [Effect] {
        switch state {
        case .listening(let t): return [.refused(.busy(talkerId: t.userId))]
        case .requesting, .talking: return []
        case .idle: break
        }
        if muted { return [.refused(.muted)] }
        if !online { return [.refused(.offline)] }
        nextId += 1
        state = .requesting(id: nextId, atMs: nowMs)
        return [.sendStart(id: nextId)]
    }

    mutating func pressUp() -> [Effect] {
        switch state {
        case .requesting:
            /* Let go before the grant: cancel; a late grant is handed back below. */
            state = .idle
            return [.sendStop]
        case .talking:
            state = .idle
            return [.stopCapture, .sendStop]
        default:
            return []
        }
    }

    // MARK: server

    mutating func receive(_ s: PTTSignal, nowMs: Double) -> [Effect] {
        switch s {
        case let .grant(id, burst, maxMs):
            maxTalkMs = min(Self.maxTalkMs, Double(maxMs))
            guard case .requesting(let want, _) = state, want == id else {
                /* A grant nobody is waiting for any more (finger already up). */
                if case .talking = state { return [] }
                return [.sendStop]
            }
            state = .talking(burst: burst, sinceMs: nowMs)
            return [.startCapture(burst: burst)]
        case let .deny(id, reason, talkerId):
            guard case .requesting(let want, _) = state, id == nil || id == want else { return [] }
            state = .idle
            switch reason {
            case "busy": return [.refused(.busy(talkerId: talkerId))]
            case "rate_limited": return [.refused(.rateLimited)]
            case "not_joined": return [.refused(.muted)]
            default: return [.refused(.notAllowed)]
            }
        case let .state(talker, maxMs):
            maxTalkMs = min(Self.maxTalkMs, Double(maxMs))
            guard let t = talker, t.userId != me else { return endListening() }
            return listen(t)
        case let .talker(t):
            guard t.userId != me else { return [] }
            return listen(t)
        case let .idle(userId, burst, reason):
            if case let .talking(b, _) = state, userId == me, b == burst {
                state = .idle
                return reason == .released ? [.stopCapture] : [.stopCapture, .cutOff(reason)]
            }
            if case let .listening(t) = state, t.userId == userId, t.burst == burst { return endListening() }
            return []
        }
    }

    private mutating func listen(_ t: PTTTalker) -> [Effect] {
        if muted { return [] }
        switch state {
        case .talking:
            /* The server gave someone else the floor: we lost ours (e.g. a reconnect). */
            state = .listening(t)
            return [.stopCapture, .startPlayback(t)]
        case .requesting:
            state = .listening(t)
            return [.refused(.busy(talkerId: t.userId)), .startPlayback(t)]
        case .listening(let cur) where cur == t:
            return []
        default:
            state = .listening(t)
            return [.startPlayback(t)]
        }
    }

    private mutating func endListening() -> [Effect] {
        guard case .listening = state else { return [] }
        state = .idle
        return [.stopPlayback]
    }

    // MARK: clock, mute, link

    /// Once a second or so: the local 60 s cap and the request timeout.
    mutating func tick(nowMs: Double) -> [Effect] {
        switch state {
        case let .talking(_, since) where nowMs - since >= maxTalkMs:
            state = .idle
            return [.stopCapture, .sendStop, .cutOff(.maxDuration)]
        case let .requesting(_, at) where nowMs - at >= Self.requestTimeoutMs:
            state = .idle
            return [.sendStop, .refused(.offline)]
        default:
            return []
        }
    }

    /// «اكتم القناة»: no audio in, and no talking out (the server takes us off the channel).
    mutating func setMuted(_ on: Bool) -> [Effect] {
        guard on != muted else { return [] }
        muted = on
        guard on else { return [] }
        switch state {
        case .listening:
            state = .idle
            return [.stopPlayback]
        case .talking:
            state = .idle
            return [.stopCapture, .sendStop]
        case .requesting:
            state = .idle
            return [.sendStop]
        case .idle:
            return []
        }
    }

    /// The socket dropped: whatever was on air is over for us.
    mutating func linkLost() -> [Effect] {
        switch state {
        case .talking:
            state = .idle
            return [.stopCapture, .cutOff(.left)]
        case .listening:
            state = .idle
            return [.stopPlayback]
        case .requesting:
            state = .idle
            return [.refused(.offline)]
        case .idle:
            return []
        }
    }

    func talkingSeconds(nowMs: Double) -> Int {
        if case let .talking(_, since) = state { return max(0, Int((nowMs - since) / 1000)) }
        return 0
    }
}
