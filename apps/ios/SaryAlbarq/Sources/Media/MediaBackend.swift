import Foundation

/// One request to «قناة الطلعة» (`POST /api/outings/:id/media`).
struct MediaAction: Equatable {
    enum Kind: String { case play, pause, seek, load, next, queue_add, stop }
    var kind: Kind
    var videoId: String?
    var position: Double?
    var title: String?
    var rate: Double?

    static func play(at p: Double? = nil) -> MediaAction { .init(kind: .play, position: p) }
    static func pause(at p: Double? = nil) -> MediaAction { .init(kind: .pause, position: p) }
    static func seek(_ p: Double) -> MediaAction { .init(kind: .seek, position: p) }
    static func load(_ id: String, title: String, at p: Double? = nil) -> MediaAction { .init(kind: .load, videoId: id, position: p, title: title) }
    static let next = MediaAction(kind: .next)
    static let stop = MediaAction(kind: .stop)
    static func queue(_ id: String) -> MediaAction { .init(kind: .queue_add, videoId: id) }

    var body: [String: Any] {
        var b: [String: Any] = ["action": kind.rawValue]
        if let videoId { b["video_id"] = videoId }
        if let position { b["position_s"] = (max(0, position) * 1000).rounded() / 1000 }
        if let title { b["title"] = String(title.prefix(100)) }
        if let rate { b["rate"] = rate }
        return b
    }
}

enum MediaBackendError: Error, Equatable {
    /// The server does not have «قناة الطلعة» yet (route answers 404 that is not `not_a_member`).
    case notDeployed
    case server(code: String, status: Int)
    case network

    var arabic: String {
        switch self {
        case .notDeployed: return "قناة الطلعة غير متاحة بعد."
        case .network: return "لا يوجد اتصال بالإنترنت."
        case let .server(code, status):
            let t: [String: String] = [
                "not_controller": "اللي شغّل الفيديو هو اللي يتحكم فيه، أو أمير الرحلة ونائبه.",
                "leader_only": "هذا لأمير الرحلة أو نائبه فقط.",
                "media_idle": "ما فيه شي شغّال في قناة الطلعة.",
                "queue_full": "القائمة مليانة (٢٠ فيديو).",
                "invalid_video_id": "الرابط مو لفيديو يوتيوب.",
                "outing_ended": "انتهت هذه الطلعة.",
                "rate_limited": "على هونك… اصبر ثواني.",
                "not_a_member": "لست عضوًا في هذه الطلعة.",
            ]
            return t[code] ?? (status == 0 ? "لا يوجد اتصال بالإنترنت." : "حدث خطأ. أعد المحاولة.")
        }
    }
}

/// Where «قناة الطلعة» lives: the API in the app, a local stand-in for the demo outing.
@MainActor
protocol MediaBackend: AnyObject {
    func fetch() async throws -> (state: SharedMediaState?, serverNow: Date?)
    func send(_ action: MediaAction) async throws -> SharedMediaState?
    func takeover() async throws -> SharedMediaState?
}

/// `GET/POST /api/outings/:id/media` with the device's Bearer token.
@MainActor
final class MediaHTTPBackend: MediaBackend {
    let outingId: String
    private let base: URL
    private let token: () -> String?
    private let session: URLSession

    init(outingId: String, base: URL = Endpoints.apiBase, session: URLSession = .shared, token: @escaping () -> String? = { IdentityStore.load()?.token }) {
        self.outingId = outingId
        self.base = base
        self.session = session
        self.token = token
    }

    private func request(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        var req = URLRequest(url: base.appendingPathComponent("api/outings/\(outingId)\(path)"), timeoutInterval: 10)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let t = token() { req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let data: Data, resp: URLResponse
        do { (data, resp) = try await session.data(for: req) } catch { throw MediaBackendError.network }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let code = obj?["error"] as? String
        if status == 404 && code != "not_a_member" { throw MediaBackendError.notDeployed }
        guard (200..<300).contains(status), obj?["ok"] as? Bool != false else {
            throw MediaBackendError.server(code: code ?? "http_\(status)", status: status)
        }
        return obj ?? [:]
    }

    func fetch() async throws -> (state: SharedMediaState?, serverNow: Date?) {
        let o = try await request("GET", "/media")
        return (MediaEvents.decodeState(o["media"]), ISODate.parse(o["server_now"] as? String))
    }

    func send(_ action: MediaAction) async throws -> SharedMediaState? {
        MediaEvents.decodeState(try await request("POST", "/media", body: action.body)["media"])
    }

    func takeover() async throws -> SharedMediaState? {
        MediaEvents.decodeState(try await request("POST", "/media/takeover", body: [:])["media"])
    }
}

/// The demo outing (no server): the same rules, applied on the phone, so the
/// screens and UI tests behave like the real thing.
@MainActor
final class MediaDemoBackend: MediaBackend {
    private(set) var state: SharedMediaState?
    let me: String
    let iLead: Bool
    var now: () -> Date = Date.init

    init(me: String, iLead: Bool, seeded: SharedMediaState? = nil) {
        self.me = me
        self.iLead = iLead
        state = seeded
    }

    func fetch() async throws -> (state: SharedMediaState?, serverNow: Date?) { (state.map(rebased), now()) }

    private func rebased(_ s: SharedMediaState) -> SharedMediaState {
        var c = s
        c.position_s = s.position(atServer: now())
        c.at = ISODate.string(now())
        return c
    }

    func send(_ a: MediaAction) async throws -> SharedMediaState? {
        let t = ISODate.string(now())
        guard var s = state.map(rebased) else {
            guard a.kind == .load, let id = a.videoId else {
                if a.kind == .stop { return nil }
                throw MediaBackendError.server(code: "media_idle", status: 409)
            }
            state = SharedMediaState(video_id: id, title: a.title ?? "", controller_user_id: me, position_s: a.position ?? 0, playing: true, rate: a.rate ?? 1, at: t)
            return state
        }
        if a.kind == .queue_add, let id = a.videoId {
            guard s.queue.count < MediaPermissions.queueMax else { throw MediaBackendError.server(code: "queue_full", status: 409) }
            s.queue.append(id)
            state = s
            return s
        }
        guard MediaPermissions.canControl(s, me: me, iLead: iLead) else { throw MediaBackendError.server(code: "not_controller", status: 403) }
        switch a.kind {
        case .play: s.playing = true
        case .pause: s.playing = false
        case .seek: break
        case .load:
            s.video_id = a.videoId ?? s.video_id
            s.title = a.title ?? ""
            s.position_s = 0
            s.playing = true
        case .next:
            guard !s.queue.isEmpty else { state = nil; return nil }
            s.video_id = s.queue.removeFirst()
            s.title = ""
            s.position_s = 0
            s.playing = true
        case .stop:
            state = nil
            return nil
        case .queue_add: break
        }
        if let p = a.position { s.position_s = p }
        if let r = a.rate { s.rate = r }
        s.at = t
        s.updated_at = t
        state = s
        return s
    }

    func takeover() async throws -> SharedMediaState? {
        guard var s = state.map(rebased) else { throw MediaBackendError.server(code: "media_idle", status: 409) }
        guard iLead else { throw MediaBackendError.server(code: "leader_only", status: 403) }
        s.controller_user_id = me
        state = s
        return s
    }
}

/// `media_state` frames from the live WebSocket, handed over by `LiveChannel`
/// without the live layer knowing anything about media.
enum MediaEvents {
    static let name = Notification.Name("sary.media.state")

    /// Called by LiveChannel for `media_state` and for a `ready` snapshot that carries `media`.
    static func post(outingId: String, raw: Any?) {
        NotificationCenter.default.post(name: name, object: nil, userInfo: ["outing": outingId, "state": raw ?? NSNull()])
    }

    static func decodeState(_ raw: Any?) -> SharedMediaState? {
        guard let raw, !(raw is NSNull), JSONSerialization.isValidJSONObject(raw),
              let d = try? JSONSerialization.data(withJSONObject: raw) else { return nil }
        return try? JSONDecoder().decode(SharedMediaState.self, from: d)
    }
}

/// Video titles from YouTube's public oEmbed endpoint — no API key, no stream access.
enum YouTubeOEmbed {
    private static var cache: [String: String] = [:]

    @MainActor
    static func title(for videoId: String, session: URLSession = .shared) async -> String? {
        if let t = cache[videoId] { return t }
        guard YouTubeLink.isVideoId(videoId) else { return nil }
        var c = URLComponents(string: "https://www.youtube.com/oembed")!
        c.queryItems = [URLQueryItem(name: "url", value: "https://www.youtube.com/watch?v=\(videoId)"), URLQueryItem(name: "format", value: "json")]
        guard let url = c.url else { return nil }
        guard let (data, resp) = try? await session.data(for: URLRequest(url: url, timeoutInterval: 8)),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let title = obj["title"] as? String, !title.isEmpty else { return nil }
        let clean = String(title.prefix(100))
        cache[videoId] = clean
        return clean
    }
}
