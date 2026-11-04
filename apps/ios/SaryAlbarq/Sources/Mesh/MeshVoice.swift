import CryptoKit
import Foundation

/// «قناة الطلعة» without internet: walkie-talkie frames between nearby phones
/// of the same outing, over the same MultipeerConnectivity session as the rest
/// of the mesh, encrypted like every other mesh message.
///
/// Position frames are JSON (they start with `{`); a voice frame starts with
/// 0xA1, so one session carries both. A voice frame is compact binary, because
/// it goes ~33 times a second:
///
///   [0]      0xA1
///   [1]      version 1
///   [2..9]   outing tag (8 bytes; MeshKeys.outingTag in hex = 16 chars)
///   [10..17] sender clock, ms (Int64 BE)
///   [18]     sender id length n
///   [19..]   sender id (utf8, n bytes)
///   [..]     AES-GCM combined box (nonce | ciphertext | tag)
///
/// The key is derived from the SENDER's member key ("ptt-voice"), and the whole
/// header is the AES-GCM additional data, so a frame is authentic to one member
/// of this outing, exactly as the HMAC does for JSON frames. Plaintext: a kind
/// byte + the `PTTFrame` bytes (audio) or the talker's start/stop.
///
/// Direct neighbours only (no relaying: audio is too heavy and too late after
/// a hop). Frames older than `maxAgeMs` are dropped; duplicates and reordering
/// are the jitter buffer's job.
struct MeshVoiceCodec {
    static let magic: UInt8 = 0xA1
    static let version: UInt8 = 1
    static let maxAgeMs = 5_000.0
    static let maxBytes = 1_600

    enum Kind: UInt8 { case audio = 1, start = 2, stop = 3 }

    struct Message: Equatable {
        var from: String
        var kind: Kind
        /// For `.audio`: the PTTFrame bytes. For `.start`/`.stop`: [burst].
        var body: Data
    }

    let keys: MeshKeys
    let me: String

    private var tagBytes: Data { Data(hexString: keys.outingTag) ?? Data(keys.outingTag.utf8.prefix(8)) }

    private func key(_ sender: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: keys.memberKey(sender), info: Data("ptt-voice".utf8), outputByteCount: 32)
    }

    static func isVoice(_ d: Data) -> Bool { d.first == magic }

    func seal(_ kind: Kind, body: Data, nowMs: Double) throws -> Data {
        let id = Data(me.lowercased().utf8)
        guard id.count <= 64 else { throw MeshReject.malformed }
        var h = Data([Self.magic, Self.version])
        h.append(tagBytes)
        var t = Int64(nowMs.rounded()).bigEndian
        h.append(Data(bytes: &t, count: 8))
        h.append(UInt8(id.count))
        h.append(id)
        let box = try AES.GCM.seal(Data([kind.rawValue]) + body, using: key(me), authenticating: h)
        guard let c = box.combined else { throw MeshReject.badCipher }
        let out = h + c
        guard out.count <= Self.maxBytes else { throw MeshReject.tooLarge }
        return out
    }

    func open(_ d: Data, members: Set<String>, nowMs: Double) throws -> Message {
        let b = [UInt8](d)
        guard b.count <= Self.maxBytes, b.count > 19 else { throw MeshReject.malformed }
        guard b[0] == Self.magic else { throw MeshReject.malformed }
        guard b[1] == Self.version else { throw MeshReject.wrongVersion }
        guard Data(b[2..<10]) == tagBytes else { throw MeshReject.otherOuting }
        let t = Double(b[10..<18].reduce(Int64(0)) { $0 << 8 | Int64($1) })
        if t < nowMs - Self.maxAgeMs { throw MeshReject.tooOld }
        if t > nowMs + Self.maxAgeMs { throw MeshReject.inFuture }
        let n = Int(b[18])
        guard n > 0, b.count > 19 + n + 28 else { throw MeshReject.malformed }
        guard let from = String(bytes: b[19..<(19 + n)], encoding: .utf8) else { throw MeshReject.malformed }
        guard from != me.lowercased() else { throw MeshReject.fromMe }
        guard let member = members.first(where: { $0.lowercased() == from }) else { throw MeshReject.notMember }
        let header = Data(b[0..<(19 + n)])
        let plain: Data
        do {
            plain = try AES.GCM.open(AES.GCM.SealedBox(combined: Data(b[(19 + n)...])), using: key(from), authenticating: header)
        } catch { throw MeshReject.badAuth }
        guard let k = plain.first.flatMap(Kind.init(rawValue:)) else { throw MeshReject.badPayload }
        return Message(from: member, kind: k, body: plain.dropFirst())
    }
}

/// Voice is ~33 frames/s per talker; this caps what one nearby phone may push at us.
struct MeshVoiceLimiter: Equatable {
    static let burst = 80.0
    static let perSecond = 50.0
    private(set) var buckets: [String: Double] = [:]
    private(set) var at: [String: Double] = [:]

    mutating func allow(_ peer: String, nowMs: Double) -> Bool {
        let last = at[peer] ?? nowMs
        var tokens = min(Self.burst, (buckets[peer] ?? Self.burst) + (nowMs - last) / 1000 * Self.perSecond)
        at[peer] = nowMs
        guard tokens >= 1 else { buckets[peer] = tokens; return false }
        tokens -= 1
        buckets[peer] = tokens
        return true
    }

    mutating func forget(_ peer: String) {
        buckets[peer] = nil
        at[peer] = nil
    }
}

extension Data {
    init?(hexString s: String) {
        guard s.count % 2 == 0 else { return nil }
        var out = Data(capacity: s.count / 2)
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            guard let v = UInt8(s[i..<j], radix: 16) else { return nil }
            out.append(v)
            i = j
        }
        self = out
    }
}
