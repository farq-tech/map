import Foundation
import UIKit
import Security

enum Endpoints {
    /// The Railway API, called directly (the Vercel `/api` rewrite proxies the
    /// same server but cannot carry a WebSocket). No key: identity is a per-device
    /// Bearer token the server issues.
    static let production = URL(string: "https://api-production-ddc84.up.railway.app")!

    static var apiBase: URL {
        #if DEBUG
        if let o = debugOverride { return o }
        #endif
        return production
    }

    static var liveSocket: URL {
        var c = URLComponents(url: apiBase, resolvingAgainstBaseURL: false)!
        c.scheme = c.scheme == "http" ? "ws" : "wss"
        c.path = "/api/outings/live"
        return c.url!
    }

    #if DEBUG
    /// DEBUG builds only: `-SaryAPIBase http://127.0.0.1:PORT` points the app at a local API
    /// (background-sharing verification on the simulator). Remembered so a background
    /// relaunch by iOS (no launch arguments then) talks to the same server; `-SaryAPIBase prod` clears it.
    static let debugKey = "sary.debug.apiBase"
    static var debugOverride: URL? {
        let d = UserDefaults.standard
        if let arg = d.volatileDomain(forName: UserDefaults.argumentDomain)["SaryAPIBase"] as? String {
            if arg == "prod" { d.removeObject(forKey: debugKey); return nil }
            d.set(arg, forKey: debugKey)
        }
        /* Local servers only (never a remote host from a launch argument). */
        guard let u = d.string(forKey: debugKey).flatMap(URL.init(string:)), let h = u.host,
              h == "127.0.0.1" || h == "localhost" else { return nil }
        return u
    }
    #endif
}

struct OutingAPIError: Error, Equatable {
    var code: String
    var status: Int

    /// A sentence a person can act on — same table as the web's `outingErrorText`.
    var arabic: String {
        let t: [String: String] = [
            "invite_invalid": "الرابط ناقص أو فيه خطأ.",
            "invite_expired": "انتهت صلاحية رابط الدعوة. اطلب من أمير الرحلة رابطًا جديدًا.",
            "invite_revoked": "ألغى أمير الرحلة هذا الرابط. اطلب رابطًا جديدًا.",
            "outing_ended": "انتهت هذه الطلعة.",
            "outing_full": "اكتمل عدد المشاركين في هذه الطلعة.",
            "removed_from_outing": "أزالك أمير الرحلة منها، فلا يمكنك الانضمام مرة ثانية.",
            "not_a_member": "لست عضوًا في هذه الطلعة.",
            "owner_only": "هذا الإجراء لأمير الرحلة فقط.",
            "invalid_name": "اكتب اسمًا يظهر للعيال.",
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
            "leader_only": "هذا الإجراء لأمير الرحلة أو نائبه فقط.",
            "cannot_remove_self": "لا يمكنك إزالة نفسك. استخدم «غادر الطلعة».",
            "invalid_rally": "تعذّر وضع نقطة التجمع هنا.",
            "sos_fix_stale": "موقعك قديم، أُرسلت الطوارئ بدون موقع.",
            "invalid_clip": "التسجيل قصير جدًا أو غير صالح.",
            "invalid_clip_duration": "التسجيل قصير جدًا.",
            "too_large": "التسجيل أطول من المسموح.",
            "clip_gone": "انتهت صلاحية هذا التسجيل.",
            "join_locked": "أمير الرحلة قفل الانضمام.",
            "recovery_invalid": "رمز الاسترجاع غير صحيح أو استُخدم من قبل. تأكد منه وحاول مرة ثانية.",
            "invalid_avatar": "الصورة كبيرة أو بصيغة غير مدعومة. جرّب صورة ثانية.",
            "outing_not_ended": "تقدر تشارك ملخصك بعد ما تنتهي الطلعة.",
            "summary_window_closed": "مضى أكثر من أسبوع على نهاية الطلعة، فما عاد ممكن مشاركة الملخص.",
            "implausible_summary": "أرقام الرحلة على هذا الجهاز غير منطقية، فلم نرسلها.",
            "invalid_summary": "تعذّر إرسال الملخص.",
            "server_busy": "الخادم مشغول. أعد المحاولة بعد قليل.",
            "invite_taken": "هذه الدعوة لشخص آخر. إذا كانت لك ودخلت بحساب جديد، أضف رقم جوالك في «حسابي» أو اطلب من أمير الرحلة دعوة جديدة باسمك.",
            "open_links_disabled": "أوقف أمير الرحلة الرابط المفتوح. اطلب منه دعوة شخصية باسمك.",
            "invite_used": "استُخدمت هذه الدعوة، وصاحبها في الطلعة.",
            "invite_replaced": "أُرسلت لهذا الشخص دعوة أحدث.",
            "invite_not_found": "لم نجد هذه الدعوة.",
            "invalid_invitee_name": "اكتب اسم الشخص كما تعرفه.",
            "too_many_invites": "وصلت الحد الأعلى للدعوات في هذه الطلعة.",
            "invalid_open_links": "تعذّر تغيير الرابط المفتوح.",
        ]
        return t[code] ?? "حدث خطأ. أعد المحاولة."
    }
}

/// Where the identity is kept. The real one is the Keychain; tests swap in memory
/// (a "relaunch" is a new read from the same backend).
protocol IdentityKeychain {
    func read() -> (status: OSStatus, data: Data?)
    /// Update in place when present, add otherwise. Never delete-then-add.
    func write(_ data: Data) -> OSStatus
    func delete() -> OSStatus
}

struct SystemIdentityKeychain: IdentityKeychain {
    let service = "sa.sary.albarq.identity"
    let account = "outings.v1"

    private var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    func read() -> (status: OSStatus, data: Data?) {
        var q = base
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        let st = SecItemCopyMatching(q as CFDictionary, &out)
        return (st, out as? Data)
    }

    func write(_ data: Data) -> OSStatus {
        /* Readable after first unlock, so a relaunch in the background (screen locked) still has it. */
        let attrs: [String: Any] = [kSecValueData as String: data,
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let st = SecItemUpdate(base as CFDictionary, attrs as CFDictionary)
        guard st == errSecItemNotFound else { return st }
        var add = base
        for (k, v) in attrs { add[k] = v }
        return SecItemAdd(add as CFDictionary, nil)
    }

    func delete() -> OSStatus { SecItemDelete(base as CFDictionary) }
}

/// The identity token lives in this device's Keychain only, never in UserDefaults.
///
/// Build 20 lost signed-in people on relaunch: `load()` turned *any* Keychain
/// failure into "no identity" (e.g. errSecInteractionNotAllowed while iOS starts
/// the app in the background before protected data is available — a location
/// relaunch, a pushtotalk wake-up, prewarming). The app then showed onboarding,
/// and `save()` (delete, then add) of the new identity destroyed the old one.
/// Now: "not found" and "cannot read right now" are different answers, the
/// write updates in place, and only an explicit sign-out / account deletion
/// deletes (`clear()`).
enum IdentityStore {
    enum Read: Equatable {
        case found(Identity)
        /// Nothing saved on this device.
        case none
        /// The Keychain did not answer (locked before first unlock, prewarm, I/O): try again later.
        case unavailable(OSStatus)
    }

    static var keychain: IdentityKeychain = SystemIdentityKeychain()
    private static let lock = NSLock()
    private static var cached: Identity?
    /// Whether iOS has protected data available (false before first unlock / during prewarm).
    /// Injectable for tests.
    static var protectedDataAvailable: () -> Bool = {
        if Thread.isMainThread { return MainActor.assumeIsolated { UIApplication.shared.isProtectedDataAvailable } }
        return true
    }
    private static var migrated = false

    static func read() -> Read {
        let (st, data) = keychain.read()
        switch st {
        case errSecSuccess:
            guard let data, let id = try? JSONDecoder().decode(Identity.self, from: data) else { return .unavailable(errSecDecode) }
            lock.withLock { cached = id }
            /* Items saved by builds before 21 may still be «when unlocked only»: such an item is
             * invisible (errSecItemNotFound) when iOS relaunches the app with the phone locked.
             * Re-write it once per process so it moves to «after first unlock» (update in place). */
            let first = lock.withLock { () -> Bool in defer { migrated = true }; return !migrated }
            if first { _ = keychain.write(data) }
            return .found(id)
        case errSecItemNotFound:
            /* Not found while protected data is unavailable is not an answer: a «when unlocked»
             * item hides then. Only an unlocked phone can say "nothing saved". */
            return protectedDataAvailable() ? .none : .unavailable(st)
        default:
            return .unavailable(st)
        }
    }

    /// The identity, or nil when none is saved *or* it cannot be read right now.
    static func load() -> Identity? {
        if case let .found(id) = read() { return id }
        return nil
    }

    /// The token for a request: the last identity read or saved in this process,
    /// so a transient Keychain miss never sends a request without one.
    static func currentToken() -> String? {
        if let t = lock.withLock({ cached?.token }) { return t }
        return load()?.token
    }

    @discardableResult
    static func save(_ id: Identity?) -> Bool {
        guard let id else { clear(); return true }
        guard let d = try? JSONEncoder().encode(id) else { return false }
        lock.withLock { cached = id }
        return keychain.write(d) == errSecSuccess
    }

    /// Explicit sign-out / account deletion / test reset only.
    static func clear() {
        lock.withLock { cached = nil }
        _ = keychain.delete()
    }

    /// Tests: forget the in-process copy, as a new launch would.
    static func forgetCache() { lock.withLock { cached = nil; migrated = false } }
}

/// REST client for `/api/outings`. Invite tokens travel in bodies, never URLs.
final class OutingsAPI {
    var tokenProvider: () -> String?
    /// A 401 for a request that carried this token. Requests without a token never sign anyone out.
    var onUnauthorized: (_ sentToken: String) -> Void = { _ in }
    private let session: URLSession
    /// Internal so the voice-note client (Sources/VoiceNotes) builds its raw-audio requests the same way.
    let base: URL

    init(base: URL = Endpoints.apiBase, session: URLSession = .shared, tokenProvider: @escaping () -> String?) {
        self.base = base
        self.session = session
        self.tokenProvider = tokenProvider
    }

    private struct Empty: Encodable {}

    /// Internal (not private) so the feature clients in other files (waypoints, convoy, plan) use the same path.
    func call<T: Decodable>(_ method: String, _ path: String, body: Encodable? = nil, auth: Bool = true, timeout: TimeInterval = 12, query: String? = nil) async throws -> T {
        var url = base.appendingPathComponent("api/outings" + path)
        /* «المحادثات»: cursor pagination (?before=/?after=). Never anything personal in a query. */
        if let query, var c = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            c.percentEncodedQuery = query
            url = c.url ?? url
        }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(AnyEncodable(body))
        }
        let sent = auth ? tokenProvider() : nil
        if let t = sent { req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        let data: Data, resp: URLResponse
        do {
            (data, resp) = try await session.data(for: req)
        } catch let e as URLError {
            throw OutingAPIError(code: e.code == .timedOut ? "timeout" : "network", status: 0)
        }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if !(200..<300).contains(status) || obj?["ok"] as? Bool == false {
            if status == 401, let sent { onUnauthorized(sent) }
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
    /// `invite` is nil for a personal-only trip (`invites: "personal"`): people are invited one by one.
    struct CreatedBox: Decodable { var outing_id: String; var invite: CreatedInvite?; var open_links: Bool? }
    struct InviteBox: Decodable { var invite: CreatedInvite }
    struct PreviewBox: Decodable { var invite: InvitePreview }
    struct JoinBox: Decodable { var outing_id: String; var already: Bool? }
    /// `POST /:id/status` returns only id, name, status, started_at, ended_at.
    struct StatusOuting: Decodable { var id: String; var status: OutingStatus }
    struct OutingBox: Decodable { var outing: StatusOuting }
    struct NoteBox: Decodable { var note: MemberNote? }
    struct SharingBox: Decodable { var sharing: Bool }
    struct OkBox: Decodable { var ok: Bool? }

    func createIdentity(name: String, avatar: String? = nil) async throws -> Identity {
        var b = ["display_name": name]
        if let avatar { b["avatar"] = avatar }
        let r: IdentityBox = try await call("POST", "/me", body: b, auth: false)
        return Identity(token: r.token, user: r.user)
    }

    /// `phone: ""` / `avatar: ""` clear them; nil leaves them unchanged.
    func updateProfile(name: String? = nil, phone: String? = nil, avatar: String? = nil) async throws -> PublicUser {
        var b: [String: String] = [:]
        if let name { b["display_name"] = name }
        if let phone { b["phone"] = phone }
        if let avatar { b["avatar"] = avatar }
        let r: UserBox = try await call("PATCH", "/me", body: b)
        return r.user
    }

    // MARK: recovery (no passwords: a code made on the old device, redeemed on the new one)

    struct RecoveryStatus: Codable, Equatable { var active: Bool; var created_at: String? }
    struct MeBox: Decodable { var user: PublicUser; var recovery: RecoveryStatus? }
    struct RecoveryCode: Codable, Equatable { var code: String; var created_at: String? }
    struct RecoveryBox: Decodable { var recovery: RecoveryCode }

    /// `GET /me`: who this device is, and whether a recovery code is saved.
    func me() async throws -> MeBox { try await call("GET", "/me") }

    /// `POST /me/recovery`: a new code, shown once; replaces any earlier one.
    func createRecoveryCode() async throws -> RecoveryCode {
        let r: RecoveryBox = try await call("POST", "/me/recovery", body: [String: String]())
        return r.recovery
    }

    /// `POST /me/recover`: the code (in the body) → a new device token. The old device is signed out.
    func recover(code: String) async throws -> Identity {
        let r: IdentityBox = try await call("POST", "/me/recover", body: ["code": code], auth: false)
        return Identity(token: r.token, user: r.user)
    }

    // MARK: trip summary (opt-in totals, never points)

    struct SummaryBox: Decodable { var summary: TripShare? }
    func shareSummary(_ id: String, _ t: TripTotals) async throws -> TripShare? {
        struct S: Encodable { var distance_m: Int; var duration_s: Int; var moving_s: Int }
        struct B: Encodable { var summary: S }
        let r: SummaryBox = try await call("PUT", "/\(id)/summary", body: B(summary: S(distance_m: t.distanceM, duration_s: t.durationS, moving_s: t.movingS)))
        return r.summary
    }
    func withdrawSummary(_ id: String) async throws {
        let _: OkBox = try await call("DELETE", "/\(id)/summary")
    }

    // MARK: iOS push (APNs device token; server side may still be off: 503 apns_disabled)

    struct ApnsConfig: Decodable, Equatable { var enabled: Bool; var bundle_id: String? }
    func apnsConfig() async throws -> ApnsConfig { try await call("GET", "/push/apns", auth: false) }
    func registerApns(token: String, environment: String, bundleId: String) async throws {
        let _: OkBox = try await call("POST", "/push/apns", body: ["token": token, "environment": environment, "bundle_id": bundleId])
    }
    // MARK: «قناة الطلعة» — this device's PushToTalk channel token for one outing

    func registerPTTToken(_ outingId: String, token: String, environment: String) async throws {
        /* voice_notes: this build plays the «رسالة صوتية» it is woken for (server: ptt_tokens.voice_notes). */
        struct B: Encodable { var token: String; var environment: String; var voice_notes = true }
        let _: OkBox = try await call("POST", "/\(outingId)/ptt/token", body: B(token: token, environment: environment))
    }

    /// Muted the channel or left the outing: no more wake-ups for this phone (every token of mine for it).
    func unregisterPTTToken(_ outingId: String) async throws {
        let _: OkBox = try await call("DELETE", "/\(outingId)/ptt/token", body: [String: String]())
    }

    func unregisterApns(token: String) async throws {
        let _: OkBox = try await call("DELETE", "/push/apns", body: ["token": token])
    }

    func list() async throws -> ListBox { try await call("GET", "") }
    /// `personal: true` (build 12+): no open link — the leader invites people one by one.
    /// An older server ignores the field and still returns an open link.
    func create(name: String, personal: Bool = true) async throws -> CreatedBox {
        var b = ["name": name]
        if personal { b["invites"] = "personal" }
        return try await call("POST", "", body: b)
    }

    // MARK: «دعوة شخصية» — one single-use link per person

    struct PersonalBox: Decodable { var invite: PersonalInvite; var replaced: String? }
    struct PersonalListBox: Decodable { var invites: [PersonalInvite] }
    struct OpenLinksBox: Decodable { var open_links: Bool }

    func personalInvites(_ id: String) async throws -> [PersonalInvite] {
        let r: PersonalListBox = try await call("GET", "/\(id)/invites/personal")
        return r.invites
    }
    /// `phone`: E.164 or nil. The server keeps only its last 4 digits and a salted digest.
    func createPersonalInvite(_ id: String, name: String, phone: String?) async throws -> PersonalInvite {
        var b = ["name": name]
        if let phone { b["phone"] = phone }
        let r: PersonalBox = try await call("POST", "/\(id)/invites/personal", body: b)
        return r.invite
    }
    func resendPersonalInvite(_ id: String, invite: String) async throws -> PersonalInvite {
        let r: PersonalBox = try await call("POST", "/\(id)/invites/personal/\(invite)/resend", body: [String: String]())
        return r.invite
    }
    func revokePersonalInvite(_ id: String, invite: String) async throws -> PersonalInvite {
        let r: PersonalBox = try await call("DELETE", "/\(id)/invites/personal/\(invite)")
        return r.invite
    }
    func setOpenLinks(_ id: String, on: Bool) async throws -> Bool {
        let r: OpenLinksBox = try await call("PATCH", "/\(id)/invites/settings", body: ["open_links": on])
        return r.open_links
    }
    func get(_ id: String) async throws -> OutingSnapshot { try await call("GET", "/\(id)") }
    func poll(_ id: String) async throws -> OutingSnapshot { try await call("GET", "/\(id)/live") }
    /// `hint` / `lowPower`: why this phone may go quiet («أثناء الاستخدام» in the background, Low
    /// Power Mode…), so the others see the reason (server presence.js), never a vague «انقطع».
    func heartbeat(_ id: String, gps: GpsState, battery: BatteryInfo? = nil, hint: PresenceHint? = nil, lowPower: Bool? = nil) async throws {
        struct Bat: Encodable { var level: Double; var charging: Bool }
        struct B: Encodable { var gps: String; var battery: Bat?; var hint: String?; var low_power: Bool? }
        let _: OkBox = try await call("POST", "/\(id)/heartbeat", body: B(gps: gps.rawValue, battery: battery.map { Bat(level: $0.level, charging: $0.charging) },
                                                                          hint: hint?.rawValue, low_power: lowPower), timeout: 8)
    }

    /// The app is being closed (`applicationWillTerminate`): tell the server in the ~2 s left, so
    /// the others read «سرى مسكّر عنده» instead of guessing. Blocking on purpose; best effort.
    func heartbeatTerminatingNow(_ id: String, gps: GpsState, wait: TimeInterval = 2) {
        guard let t = tokenProvider() else { return }
        var req = URLRequest(url: base.appendingPathComponent("api/outings/\(id)/heartbeat"), timeoutInterval: wait)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["gps": gps.rawValue, "hint": PresenceHint.terminated.rawValue])
        let done = DispatchSemaphore(value: 0)
        session.dataTask(with: req) { _, _, _ in done.signal() }.resume()
        _ = done.wait(timeout: .now() + wait)
    }
    func sendPosition(_ id: String, fix: WireFix) async throws {
        struct B: Encodable { var fix: WireFix }
        let _: OkBox = try await call("POST", "/\(id)/positions", body: B(fix: fix), timeout: 8)
    }
    func setStatus(_ id: String, action: String) async throws -> StatusOuting {
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
    struct SosBox: Decodable { var sos: SosInfo? }
    struct RallyBox: Decodable { var rally: RallyInfo? }
    struct ClipBox: Decodable { var clip: VoiceClip }

    /// Raise (or refresh) my SOS. `fix` only when the send gate is open (see `SendGate.allowsSosFix`).
    func raiseSos(_ id: String, fix: WireFix?) async throws -> SosInfo? {
        struct B: Encodable { var fix: WireFix? }
        let r: SosBox = try await call("POST", "/\(id)/sos", body: B(fix: fix))
        return r.sos
    }
    func cancelSos(_ id: String) async throws {
        let _: SosBox = try await call("DELETE", "/\(id)/sos")
    }
    /// Drop or move the meeting point (owner or «نائب الأمير»).
    func setRally(_ id: String, lat: Double, lng: Double, label: String?) async throws -> RallyInfo? {
        struct B: Encodable { var lat: Double; var lng: Double; var label: String? }
        let r: RallyBox = try await call("PUT", "/\(id)/rally", body: B(lat: lat, lng: lng, label: label))
        return r.rally
    }
    func clearRally(_ id: String) async throws {
        let _: RallyBox = try await call("DELETE", "/\(id)/rally")
    }
    func setCoLeader(_ id: String, member: String, on: Bool) async throws {
        let _: OkBox = try await call("POST", "/\(id)/members/\(member)/co-leader", body: ["co_leader": on])
    }
    func removeMember(_ id: String, member: String) async throws {
        let _: OkBox = try await call("DELETE", "/\(id)/members/\(member)")
    }
    /// Revoke every invite link (a new one is made with `rotateInvite`).
    func revokeInvites(_ id: String) async throws {
        let _: OkBox = try await call("DELETE", "/\(id)/invites")
    }

    /// Push-to-talk upload: the m4a bytes as the body, the length in a header.
    func uploadClip(_ id: String, audio: Data, durationMs: Int) async throws -> VoiceClip {
        var req = URLRequest(url: base.appendingPathComponent("api/outings/\(id)/clips"), timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("audio/mp4", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(String(durationMs), forHTTPHeaderField: "X-Clip-Duration-Ms")
        let sent = tokenProvider()
        if let t = sent { req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        req.httpBody = audio
        let (data, resp) = try await raw(req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(status) else {
            if status == 401, let sent { onUnauthorized(sent) }
            throw OutingAPIError(code: obj?["error"] as? String ?? "http_\(status)", status: status)
        }
        if let c = try? JSONDecoder().decode(ClipBox.self, from: data) { return c.clip }
        if let c = try? JSONDecoder().decode(VoiceClip.self, from: data) { return c }
        throw OutingAPIError(code: "bad_response", status: status)
    }

    /// The clip's audio bytes (memory-only on the server; gone after 10 min).
    func fetchClip(_ clip: VoiceClip) async throws -> Data {
        let path = clip.url.hasPrefix("/") ? String(clip.url.dropFirst()) : clip.url
        var req = URLRequest(url: base.appendingPathComponent(path), timeoutInterval: 15)
        if let t = tokenProvider() { req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        let (data, resp) = try await raw(req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw OutingAPIError(code: status == 404 ? "clip_gone" : "http_\(status)", status: status) }
        return data
    }

    func raw(_ req: URLRequest) async throws -> (Data, URLResponse) {
        do { return try await session.data(for: req) } catch let e as URLError {
            throw OutingAPIError(code: e.code == .timedOut ? "timeout" : "network", status: 0)
        }
    }

    func leave(_ id: String) async throws {
        let _: OkBox = try await call("POST", "/\(id)/leave")
    }
    /// «احذف حسابي»: the server leaves every outing for me and deletes this identity. 404/405 = not deployed yet.
    func deleteAccount() async throws {
        let _: OkBox = try await call("DELETE", "/me")
    }
    func preview(token: String) async throws -> InvitePreview {
        /* With this phone's identity when there is one: a used personal invite then says «yours» or «taken». */
        let r: PreviewBox = try await call("POST", "/invites/preview", body: ["token": token])
        return r.invite
    }
    func join(token: String) async throws -> JoinBox { try await call("POST", "/invites/join", body: ["token": token]) }
}

/// «أقرب محطة»: public OSM fuel points (ODbL) around a COARSE box — the
/// request carries no identity and no exact position (same as the web).
enum OutdoorAPI {
    struct Station: Equatable, Identifiable {
        var id: String
        var name: String?
        var brand: String?
        var lat: Double
        var lng: Double
    }

    /// ~14 km grid, ±0.125° (the web's NEAR_BOX); the wide look is 0.25° / ±0.5°.
    static func coarseBbox(lat: Double, lng: Double, grid: Double = 0.125, half: Double = 0.125) -> [Double] {
        let snap = { (v: Double) in (v / grid).rounded() * grid }
        let r = { (v: Double) in (v * 1000).rounded() / 1000 }
        let la = snap(lat), lo = snap(lng)
        return [r(lo - half), r(la - half), r(lo + half), r(la + half)]
    }

    static func fuel(bbox: [Double], base: URL = Endpoints.apiBase, session: URLSession = .shared) async throws -> [Station] {
        var c = URLComponents(url: base.appendingPathComponent("api/outdoor/features"), resolvingAgainstBaseURL: false)!
        c.queryItems = [
            .init(name: "bbox", value: bbox.map { String($0) }.joined(separator: ",")),
            .init(name: "types", value: "fuel"),
            .init(name: "limit", value: "400"),
        ]
        var req = URLRequest(url: c.url!, timeoutInterval: 12)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data, resp: URLResponse
        do { (data, resp) = try await session.data(for: req) } catch { throw OutingAPIError(code: "network", status: 0) }
        guard ((resp as? HTTPURLResponse)?.statusCode ?? 0) == 200 else { throw OutingAPIError(code: "http", status: 0) }
        struct P: Decodable { var id: String; var kind: String; var name: String?; var brand: String?; var lat: Double; var lng: Double }
        struct F: Decodable { var properties: P }
        struct FC: Decodable { var features: [F]? }
        let fc = try JSONDecoder().decode(FC.self, from: data)
        return (fc.features ?? []).map(\.properties).filter { $0.kind == "fuel" }.map { Station(id: $0.id, name: $0.name, brand: $0.brand, lat: $0.lat, lng: $0.lng) }
    }
}

private struct AnyEncodable: Encodable {
    let value: Encodable
    init(_ v: Encodable) { value = v }
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}

/// The owner keeps invite links on this device; the server only stores their hash.
enum InviteTokenStore {
    static let key = "sary.outings.invites.v1"
    static func load(_ outingId: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: String])?[outingId]
    }
    static func save(_ outingId: String, _ token: String?) {
        var all = (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:]
        all[outingId] = token
        UserDefaults.standard.set(all, forKey: key)
    }
}
