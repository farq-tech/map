import CryptoKit
import Foundation

/// Keys for the nearby (phone-to-phone) link of ONE outing.
///
/// Where the secret comes from:
///   * `server`: `mesh_key` in the outing payload (32 random bytes, base64url),
///     which only members receive. Preferred, and what the server should add
///     (see docs/NEARBY-MESH.md).
///   * `interim`: until the server sends one, the root is derived from the
///     outing id — a v4 UUID that only the server and the outing's members
///     (current and past) ever see; it is in no invite link or watch link.
///
/// Everything below the root is HKDF-SHA256 with domain-separated labels, so
/// the encryption key, the discovery tag and the per-member tags never reuse
/// the same key.
struct MeshKeys {
    enum Source: String, Equatable { case server, interim }

    let source: Source
    let enc: SymmetricKey
    let disc: SymmetricKey
    let memberRoot: SymmetricKey
    /// Short public tag: "same outing?" without saying which outing.
    let outingTag: String

    init(outingId: String, serverKey: String? = nil) {
        let oid = outingId.lowercased()
        let root: SymmetricKey
        if let raw = serverKey.flatMap(MeshKeys.base64url), raw.count >= 32 {
            root = SymmetricKey(data: raw)
            source = .server
        } else {
            root = SymmetricKey(data: Data("sary.mesh.interim.v1|\(oid)".utf8))
            source = .interim
        }
        let salt = Data("sary.mesh.v1|\(oid)".utf8)
        func sub(_ label: String) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: root, salt: salt, info: Data(label.utf8), outputByteCount: 32)
        }
        enc = sub("enc")
        disc = sub("disc")
        memberRoot = sub("member")
        outingTag = String(MeshKeys.hex(Data(HMAC<SHA256>.authenticationCode(for: Data("outing".utf8), using: disc))).prefix(16))
    }

    /// Per-member key: HMAC over the outing (via the root) and that member's
    /// server-issued user id. Peers recompute it for the claimed sender and
    /// accept only senders on the cached member list.
    func memberKey(_ userId: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: memberRoot, info: Data("member|\(userId.lowercased())".utf8), outputByteCount: 32)
    }

    /// The Bonjour discovery tag for a 15-minute window. It rotates so a phone
    /// cannot be followed across the day by a fixed beacon, and it reveals
    /// nothing about the outing to anyone without the key.
    static let discoveryWindowMs = 15 * 60_000.0

    func discoveryTag(nowMs: Double) -> String {
        tag(window: Int((nowMs / Self.discoveryWindowMs).rounded(.down)))
    }

    /// Current and previous window, so two phones either side of a boundary still find each other.
    func acceptedDiscoveryTags(nowMs: Double) -> Set<String> {
        let w = Int((nowMs / Self.discoveryWindowMs).rounded(.down))
        return [tag(window: w), tag(window: w - 1), tag(window: w + 1)]
    }

    private func tag(window: Int) -> String {
        String(MeshKeys.hex(Data(HMAC<SHA256>.authenticationCode(for: Data("disc|\(window)".utf8), using: disc))).prefix(16))
    }

    static func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

    static func base64url(_ s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }
}

/// Why a frame from a nearby phone was dropped. Nothing dropped is ever shown.
enum MeshReject: Error, Equatable {
    case tooLarge, malformed, wrongVersion, otherOuting, notMember, fromMe
    case replay, tooOld, inFuture, badAuth, badCipher, badPayload
}

/// One frame on the wire. Only routing fields are in clear (all inside
/// MultipeerConnectivity's own required encryption); the content is AES-GCM.
struct MeshEnvelope: Codable, Equatable {
    var v: Int
    /// `MeshKeys.outingTag`.
    var o: String
    /// Sender's user id (checked against the cached member list).
    var f: String
    /// Random message id (replay guard).
    var id: String
    /// Sender's clock at send, ms.
    var t: Double
    /// AES-GCM combined box (nonce | ciphertext | tag), base64.
    var c: String
    /// HMAC-SHA256 under the sender's member key over the header and box, base64.
    var m: String
}

/// Rejects replays and stale frames. Replays are caught by id; a captured
/// frame replayed later is also outside the time window.
struct MeshReplayGuard: Equatable {
    /// A frame older than this (or this far in the future) is refused: it also
    /// bounds how long ids must be remembered.
    static let windowMs = 10 * 60_000.0
    /// A sender's clock may step back a little, never more.
    static let backStepMs = 30_000.0
    static let maxIds = 4_096

    private(set) var seen: [String: Double] = [:]
    private(set) var newest: [String: Double] = [:]

    func check(id: String, from: String, t: Double, nowMs: Double) throws {
        if seen[id] != nil { throw MeshReject.replay }
        if t < nowMs - Self.windowMs { throw MeshReject.tooOld }
        if t > nowMs + Self.windowMs { throw MeshReject.inFuture }
        if let n = newest[from], t < n - Self.backStepMs { throw MeshReject.replay }
    }

    /// Only after the frame authenticated, so forged junk cannot poison the guard.
    mutating func remember(id: String, from: String, t: Double, nowMs: Double) {
        seen[id] = nowMs
        newest[from] = max(newest[from] ?? t, t)
        if seen.count > Self.maxIds {
            let cutoff = nowMs - Self.windowMs
            seen = seen.filter { $0.value >= cutoff }
            if seen.count > Self.maxIds {
                for k in seen.sorted(by: { $0.value < $1.value }).prefix(seen.count - Self.maxIds).map(\.key) { seen[k] = nil }
            }
        }
    }
}

/// Seal / open frames for one outing and one identity.
struct MeshCodec {
    static let version = 1
    /// No frame bigger than this is parsed at all.
    static let maxFrameBytes = 16 * 1024

    let keys: MeshKeys
    let me: String

    private static func aad(_ e: MeshEnvelope) -> Data {
        Data("v\(e.v)|\(e.o)|\(e.f.lowercased())|\(e.id)|\(Int64(e.t))".utf8)
    }

    func seal(_ p: MeshPayload, nowMs: Double, id: String = UUID().uuidString) throws -> Data {
        var e = MeshEnvelope(v: Self.version, o: keys.outingTag, f: me, id: id, t: nowMs.rounded(), c: "", m: "")
        let plain = try JSONEncoder().encode(p)
        let box = try AES.GCM.seal(plain, using: keys.enc, authenticating: Self.aad(e))
        guard let combined = box.combined else { throw MeshReject.badCipher }
        e.c = combined.base64EncodedString()
        let mac = HMAC<SHA256>.authenticationCode(for: Self.aad(e) + combined, using: keys.memberKey(me))
        e.m = Data(mac).base64EncodedString()
        let out = try JSONEncoder().encode(e)
        guard out.count <= Self.maxFrameBytes else { throw MeshReject.tooLarge }
        return out
    }

    /// Every check that can fail cheaply runs before any crypto.
    func open(_ data: Data, members: Set<String>, nowMs: Double, replay: inout MeshReplayGuard) throws -> (from: String, payload: MeshPayload) {
        guard data.count <= Self.maxFrameBytes else { throw MeshReject.tooLarge }
        guard let e = try? JSONDecoder().decode(MeshEnvelope.self, from: data) else { throw MeshReject.malformed }
        guard e.v == Self.version else { throw MeshReject.wrongVersion }
        guard e.o == keys.outingTag else { throw MeshReject.otherOuting }
        let from = e.f.lowercased()
        guard from != me.lowercased() else { throw MeshReject.fromMe }
        guard members.contains(where: { $0.lowercased() == from }) else { throw MeshReject.notMember }
        guard e.id.count <= 64, e.t.isFinite else { throw MeshReject.malformed }
        try replay.check(id: e.id, from: from, t: e.t, nowMs: nowMs)
        guard let combined = Data(base64Encoded: e.c), let mac = Data(base64Encoded: e.m) else { throw MeshReject.malformed }
        guard HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: Self.aad(e) + combined, using: keys.memberKey(from)) else { throw MeshReject.badAuth }
        let plain: Data
        do {
            plain = try AES.GCM.open(AES.GCM.SealedBox(combined: combined), using: keys.enc, authenticating: Self.aad(e))
        } catch { throw MeshReject.badCipher }
        guard let p = try? JSONDecoder().decode(MeshPayload.self, from: plain), p.isWithinLimits else { throw MeshReject.badPayload }
        replay.remember(id: e.id, from: from, t: e.t, nowMs: nowMs)
        return (members.first { $0.lowercased() == from } ?? from, p)
    }
}

/// Per nearby phone: a small burst, then about one frame a second. Frames
/// over the budget are dropped before they are even decoded.
struct MeshRateLimiter: Equatable {
    static let burst = 6.0
    static let perSecond = 1.0

    private(set) var buckets: [String: (tokens: Double, atMs: Double)] = [:]

    static func == (a: MeshRateLimiter, b: MeshRateLimiter) -> Bool { a.buckets.keys == b.buckets.keys }

    mutating func allow(_ peer: String, nowMs: Double) -> Bool {
        var b = buckets[peer] ?? (Self.burst, nowMs)
        b.tokens = min(Self.burst, b.tokens + max(0, nowMs - b.atMs) / 1000 * Self.perSecond)
        b.atMs = nowMs
        guard b.tokens >= 1 else { buckets[peer] = b; return false }
        b.tokens -= 1
        buckets[peer] = b
        return true
    }

    mutating func forget(_ peer: String) { buckets[peer] = nil }
}
