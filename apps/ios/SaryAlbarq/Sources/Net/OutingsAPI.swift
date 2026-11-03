import Foundation
import Security

enum Endpoints {
    /// The Railway API, called directly (the Vercel `/api` rewrite proxies the
    /// same server but cannot carry a WebSocket). No key: identity is a per-device
    /// Bearer token the server issues.
    static let apiBase = URL(string: "https://api-production-ddc84.up.railway.app")!
    static let liveSocket = URL(string: "wss://api-production-ddc84.up.railway.app/api/outings/live")!
}

struct OutingAPIError: Error, Equatable {
    var code: String
    var status: Int

    /// A sentence a person can act on — same table as the web's `outingErrorText`.
    var arabic: String {
        let t: [String: String] = [
            "invite_invalid": "رابط الدعوة غير صحيح.",
            "invite_expired": "انتهت صلاحية رابط الدعوة. اطلب من صاحب الطلعة رابطًا جديدًا.",
            "invite_revoked": "ألغى صاحب الطلعة هذا الرابط. اطلب رابطًا جديدًا.",
            "outing_ended": "انتهت هذه الطلعة.",
            "outing_full": "اكتمل عدد المشاركين في هذه الطلعة.",
            "removed_from_outing": "أزالك صاحب الطلعة منها، فلا يمكنك الانضمام مرة ثانية.",
            "not_a_member": "لست عضوًا في هذه الطلعة.",
            "owner_only": "هذا الإجراء لصاحب الطلعة فقط.",
            "invalid_name": "اكتب اسمًا يظهر لأصحابك.",
            "invalid_outing_name": "اكتب اسمًا للطلعة.",
            "rate_limited": "محاولات كثيرة. انتظر قليلًا ثم أعد المحاولة.",
            "too_frequent": "انتظر ثانيتين ثم أرسل.",
            "invalid_note": "اكتب عبارة قصيرة.",
            "invalid_phone": "اكتب رقم جوال صحيح، مثل 05XXXXXXXX.",
            "invalid_transition": "لا يمكن تنفيذ هذا الآن.",
            "network": "لا يوجد اتصال بالإنترنت.",
            "timeout": "الشبكة بطيئة. أعد المحاولة.",
            "outings_unconfigured": "الطلعات المشتركة غير مفعّلة على الخادم.",
            "unauthorized": "انتهت جلستك على هذا الجهاز. ادخل باسمك مرة ثانية.",
        ]
        return t[code] ?? "حدث خطأ. أعد المحاولة."
    }
}

/// The identity token lives in this device's Keychain only, never in UserDefaults.
enum IdentityStore {
    private static let service = "sa.sary.albarq.identity"
    private static let account = "outings.v1"

    static func load() -> Identity? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return try? JSONDecoder().decode(Identity.self, from: d)
    }

    static func save(_ id: Identity?) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard let id, let d = try? JSONEncoder().encode(id) else { return }
        var add = base
        add[kSecValueData as String] = d
        /* Readable after first unlock, so a relaunch in the background (screen locked) still has it. */
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}

/// REST client for `/api/outings`. Invite tokens travel in bodies, never URLs.
final class OutingsAPI {
    var tokenProvider: () -> String?
    var onUnauthorized: () -> Void = {}
    private let session: URLSession
    private let base: URL

    init(base: URL = Endpoints.apiBase, session: URLSession = .shared, tokenProvider: @escaping () -> String?) {
        self.base = base
        self.session = session
        self.tokenProvider = tokenProvider
    }

    private struct Empty: Encodable {}

    private func call<T: Decodable>(_ method: String, _ path: String, body: Encodable? = nil, auth: Bool = true, timeout: TimeInterval = 12) async throws -> T {
        var req = URLRequest(url: base.appendingPathComponent("api/outings" + path), timeoutInterval: timeout)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(AnyEncodable(body))
        }
        if auth, let t = tokenProvider() { req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        let data: Data, resp: URLResponse
        do {
            (data, resp) = try await session.data(for: req)
        } catch let e as URLError {
            throw OutingAPIError(code: e.code == .timedOut ? "timeout" : "network", status: 0)
        }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if !(200..<300).contains(status) || obj?["ok"] as? Bool == false {
            if status == 401 { onUnauthorized() }
            throw OutingAPIError(code: obj?["error"] as? String ?? "http_\(status)", status: status)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw OutingAPIError(code: "bad_response", status: status)
        }
    }

    struct UserBox: Decodable { var user: PublicUser }
    struct IdentityBox: Decodable { var user: PublicUser; var token: String }
    struct ListBox: Decodable { var current: [OutingSummary]; var history: [OutingSummary] }
    struct CreatedBox: Decodable { var outing_id: String; var invite: CreatedInvite }
    struct InviteBox: Decodable { var invite: CreatedInvite }
    struct PreviewBox: Decodable { var invite: InvitePreview }
    struct JoinBox: Decodable { var outing_id: String; var already: Bool? }
    struct OutingBox: Decodable { var outing: OutingInfo }
    struct NoteBox: Decodable { var note: MemberNote? }
    struct SharingBox: Decodable { var sharing: Bool }
    struct OkBox: Decodable { var ok: Bool? }

    func createIdentity(name: String) async throws -> Identity {
        let r: IdentityBox = try await call("POST", "/me", body: ["display_name": name], auth: false)
        return Identity(token: r.token, user: r.user)
    }

    /// `phone: ""` clears it; nil leaves it unchanged.
    func updateProfile(name: String? = nil, phone: String? = nil) async throws -> PublicUser {
        var b: [String: String] = [:]
        if let name { b["display_name"] = name }
        if let phone { b["phone"] = phone }
        let r: UserBox = try await call("PATCH", "/me", body: b)
        return r.user
    }

    func list() async throws -> ListBox { try await call("GET", "") }
    func create(name: String) async throws -> CreatedBox { try await call("POST", "", body: ["name": name]) }
    func get(_ id: String) async throws -> OutingSnapshot { try await call("GET", "/\(id)") }
    func poll(_ id: String) async throws -> OutingSnapshot { try await call("GET", "/\(id)/live") }
    func heartbeat(_ id: String, gps: GpsState) async throws {
        let _: OkBox = try await call("POST", "/\(id)/heartbeat", body: ["gps": gps.rawValue], timeout: 8)
    }
    func sendPosition(_ id: String, fix: WireFix) async throws {
        struct B: Encodable { var fix: WireFix }
        let _: OkBox = try await call("POST", "/\(id)/positions", body: B(fix: fix), timeout: 8)
    }
    func setStatus(_ id: String, action: String) async throws -> OutingInfo {
        let r: OutingBox = try await call("POST", "/\(id)/status", body: ["action": action])
        return r.outing
    }
    func rotateInvite(_ id: String) async throws -> CreatedInvite {
        let r: InviteBox = try await call("POST", "/\(id)/invites", body: [String: String]())
        return r.invite
    }
    func note(_ id: String, text: String) async throws -> MemberNote? {
        let r: NoteBox = try await call("POST", "/\(id)/note", body: ["text": text])
        return r.note
    }
    func setSharing(_ id: String, sharing: Bool) async throws -> Bool {
        let r: SharingBox = try await call("PATCH", "/\(id)/me", body: ["sharing": sharing])
        return r.sharing
    }
    func leave(_ id: String) async throws {
        let _: OkBox = try await call("POST", "/\(id)/leave")
    }
    func preview(token: String) async throws -> InvitePreview {
        let r: PreviewBox = try await call("POST", "/invites/preview", body: ["token": token], auth: false)
        return r.invite
    }
    func join(token: String) async throws -> JoinBox { try await call("POST", "/invites/join", body: ["token": token]) }
}

private struct AnyEncodable: Encodable {
    let value: Encodable
    init(_ v: Encodable) { value = v }
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}

/// The owner keeps invite links on this device; the server only stores their hash.
enum InviteTokenStore {
    private static let key = "sary.outings.invites.v1"
    static func load(_ outingId: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: String])?[outingId]
    }
    static func save(_ outingId: String, _ token: String?) {
        var all = (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:]
        all[outingId] = token
        UserDefaults.standard.set(all, forKey: key)
    }
}
