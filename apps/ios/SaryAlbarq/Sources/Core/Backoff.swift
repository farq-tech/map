import Foundation

/// Reconnect timing for the live socket — same constants as `live.ts`.
enum Backoff {
    static let baseMs = 1_000.0
    static let maxMs = 30_000.0
    /// Socket attempts that never reached `ready` before we start polling.
    static let failsBeforePolling = 3
    static let pollMs = 4_000.0
    /// No frame at all for this long means a half-open socket.
    static let silenceMs = 45_000.0
    static let pingMs = 20_000.0

    /// "Equal jitter": never zero, never the whole cap for everyone at once.
    static func delayMs(attempt: Int, rand: Double) -> Double {
        let cap = min(maxMs, baseMs * pow(2, Double(max(0, attempt))))
        return (cap / 2 + (cap / 2) * min(1, max(0, rand))).rounded()
    }
}

/// While the link is down only the newest fix is kept: an old position sent late
/// is not news, and the server refuses fixes older than 60 s anyway.
struct LatestFixSlot {
    private(set) var pending: (fix: DeviceFix, mode: ShareMode)?

    mutating func put(_ fix: DeviceFix, mode: ShareMode) {
        if let p = pending, p.fix.atMs > fix.atMs { return }
        pending = (fix, mode)
    }

    /// The fix ready to go out now, or nil. A fix past `Policy.maxSendAgeMs` is dropped.
    mutating func take(nowMs: Double) -> WireFix? {
        guard let p = pending else { return nil }
        pending = nil
        let wire = Policy.wireFix(p.fix, mode: p.mode, nowMs: nowMs)
        return wire.age_ms > Policy.maxSendAgeMs ? nil : wire
    }

    /// Put back a fix whose send failed — unless a newer one arrived meanwhile.
    mutating func restore(_ fix: DeviceFix, mode: ShareMode) { put(fix, mode: mode) }

    mutating func clear() { pending = nil }
}

/// WebSocket close codes the server uses to say "do not reconnect".
enum LiveCloseReason: String, Equatable {
    case unauthorized, removed, notAMember = "not_a_member", replaced, outingEnded = "outing_ended", left

    init?(code: Int) {
        switch code {
        case 4401: self = .unauthorized
        case 4403: self = .removed
        case 4404: self = .notAMember
        case 4409: self = .replaced
        case 4410: self = .outingEnded
        default: return nil
        }
    }
}
