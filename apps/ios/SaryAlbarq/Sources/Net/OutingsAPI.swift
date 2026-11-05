import Foundation
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
            "invite_invalid": "رابط الدعوة غير صحيح.",
            "invite_expired": "انتهت صلاحية رابط الدعوة. اطلب من أمير الرحلة رابطًا جديدًا.",
            "invite_revoked": "ألغى أمير الرحلة هذا الرابط. اطلب رابطًا جديدًا.",
            "outing_ended": "انتهت هذه الطلعة.",
            "outing_full": "اكتمل عدد المشاركين في هذه الطلعة.",
            "removed_from_outing": "أزالك أمير الرحلة منها، فلا يمكنك الانضمام مرة ثانية.",
            "not_a_member": "لست عضوًا في هذه الطلعة.",
            "owner_only": "هذا الإجراء لأمير الرحلة فقط.",
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

    /// Internal (not private) so the feature clients in other files (waypoints, convoy, plan) use the same path.
    func call<T: Decodable>(_ method: String, _ path: String, body: Encodable? = nil, auth: Bool = true, timeout: TimeInterval = 12) async throws -> T {
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
        let _: OkBox = try await call("POST", "/\(outingId)/ptt/token", body: ["token": token, "environment": environment])
    }

    /// Muted the channel or left the outing: no more wake-ups for this phone (every token of mine for it).
    func unregisterPTTToken(_ outingId: String) async throws {
        let _: OkBox = try await call("DELETE", "/\(outingId)/ptt/token", body: [String: String]())
    }

    func unregisterApns(token: String) async throws {
        let _: OkBox = try await call("DELETE", "/push/apns", body: ["token": token])
    }

    func list() async throws -> ListBox { try await call("GET", "") }
    func create(name: String) async throws -> CreatedBox { try await call("POST", "", body: ["name": name]) }
    func get(_ id: String) async throws -> OutingSnapshot { try await call("GET", "/\(id)") }
    func poll(_ id: String) async throws -> OutingSnapshot { try await call("GET", "/\(id)/live") }
    func heartbeat(_ id: String, gps: GpsState, battery: BatteryInfo? = nil) async throws {
        struct Bat: Encodable { var level: Double; var charging: Bool }
        struct B: Encodable { var gps: String; var battery: Bat? }
        let _: OkBox = try await call("POST", "/\(id)/heartbeat", body: B(gps: gps.rawValue, battery: battery.map { Bat(level: $0.level, charging: $0.charging) }), timeout: 8)
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
        if let t = tokenProvider() { req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        req.httpBody = audio
        let (data, resp) = try await raw(req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(status) else {
            if status == 401 { onUnauthorized() }
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

    private func raw(_ req: URLRequest) async throws -> (Data, URLResponse) {
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
        let r: PreviewBox = try await call("POST", "/invites/preview", body: ["token": token], auth: false)
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
