import Foundation

/// «قناة الطلعة» on the wire: the binary audio frame and the ptt_* text
/// signals of the outing WebSocket (server: apps/api/lib/outings/ptt.js).
///
///   [0]   version 0x01
///   [1]   burst (u8, from ptt_grant; one per transmission)
///   [2-3] sequence number (u16 big-endian, wraps)
///   [4]   codec (PTTCodecID)                      ← our part of the payload
///   [5..] one encoded packet (30 ms of audio)
///
/// The server checks [0], [1] and the size, and relays the bytes untouched.
enum PTTCodecID: UInt8, Equatable {
    /// AAC-ELD, 16 kHz mono, 480 samples (30 ms) per packet. AudioToolbox, no third-party code.
    case aacELD16k = 1
    /// Raw 16-bit little-endian PCM, 16 kHz mono (tests / diagnostics only; too big for real use).
    case pcm16k = 2
}

struct PTTFrame: Equatable {
    static let version: UInt8 = 1
    static let headerBytes = 5
    /// The server refuses anything bigger (`maxFrameBytes`).
    static let maxBytes = 1_200
    /// 480 samples at 16 kHz.
    static let packetMs = 30.0

    var burst: UInt8
    var seq: UInt16
    var codec: PTTCodecID
    var payload: Data

    func encoded() -> Data {
        var d = Data(capacity: Self.headerBytes + payload.count)
        d.append(Self.version)
        d.append(burst)
        d.append(UInt8(seq >> 8))
        d.append(UInt8(seq & 0xFF))
        d.append(codec.rawValue)
        d.append(payload)
        return d
    }

    /// Nil for anything malformed: wrong version, unknown codec, no payload, too big.
    static func decode(_ d: Data) -> PTTFrame? {
        guard d.count > headerBytes, d.count <= maxBytes else { return nil }
        let b = [UInt8](d.prefix(headerBytes))
        guard b[0] == version, let codec = PTTCodecID(rawValue: b[4]) else { return nil }
        return PTTFrame(burst: b[1], seq: UInt16(b[2]) << 8 | UInt16(b[3]), codec: codec, payload: d.subdata(in: d.startIndex + headerBytes ..< d.endIndex))
    }
}

/// The person on air right now.
struct PTTTalker: Equatable {
    var userId: String
    var name: String
    var burst: UInt8
}

/// Why the floor came free (server `ptt_idle.reason`).
enum PTTIdleReason: String, Equatable {
    case released, maxDuration = "max_duration", silence, left
    /// «ترددات»: we tuned to another channel / were taken off a private one / it was closed.
    case switched, removed, closed
}

/// Server → phone ptt_* signals.
enum PTTSignal: Equatable {
    case state(talker: PTTTalker?, maxMs: Int)
    case grant(id: Int, burst: UInt8, maxMs: Int)
    case deny(id: Int?, reason: String, talkerId: String?)
    case talker(PTTTalker)
    case idle(userId: String, burst: UInt8, reason: PTTIdleReason)

    static func decode(_ m: [String: Any]) -> PTTSignal? {
        func burst(_ v: Any?) -> UInt8? { (v as? NSNumber).map(\.intValue).flatMap { (1...255).contains($0) ? UInt8($0) : nil } }
        func talker(_ v: Any?) -> PTTTalker? {
            guard let t = v as? [String: Any], let u = t["user_id"] as? String, let b = burst(t["burst"]) else { return nil }
            return PTTTalker(userId: u, name: (t["name"] as? String) ?? "", burst: b)
        }
        let max = (m["max_ms"] as? NSNumber)?.intValue ?? 60_000
        switch m["type"] as? String {
        case "ptt_state":
            return .state(talker: talker(m["talker"]), maxMs: max)
        case "ptt_grant":
            guard let id = (m["id"] as? NSNumber)?.intValue, let b = burst(m["burst"]) else { return nil }
            return .grant(id: id, burst: b, maxMs: max)
        case "ptt_deny":
            return .deny(id: (m["id"] as? NSNumber)?.intValue, reason: (m["reason"] as? String) ?? "busy", talkerId: m["talker_id"] as? String)
        case "ptt_talker":
            return talker(m).map(PTTSignal.talker)
        case "ptt_idle":
            guard let u = m["user_id"] as? String, let b = burst(m["burst"]) else { return nil }
            return .idle(userId: u, burst: b, reason: PTTIdleReason(rawValue: (m["reason"] as? String) ?? "") ?? .released)
        default:
            return nil
        }
    }
}

extension PTTSignal {
    /// «ترددات»: the channel a ptt_* message is about (servers before channels send none).
    static func channel(of m: [String: Any]) -> String? {
        if let s = m["channel"] as? String { return s }
        return (m["channel"] as? NSNumber).map { $0.stringValue }
    }
}

/// u16 sequence arithmetic: how far `a` is ahead of `b` (negative = behind), wrapping.
@inline(__always) func pttSeqDelta(_ a: UInt16, _ b: UInt16) -> Int { Int(Int16(bitPattern: a &- b)) }
