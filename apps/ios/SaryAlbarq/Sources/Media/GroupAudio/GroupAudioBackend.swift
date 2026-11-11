import Foundation

enum GroupAudioBackendError: Error, Equatable {
    /// The server does not have «إذاعة الطلعة» yet (404 that is not `not_a_member`): local-only mode.
    case notDeployed
    case server(code: String, status: Int)
    case network

    var arabic: String {
        switch self {
        case .notDeployed: return "المزامنة مع الطلعة غير متاحة بعد."
        case .network: return "لا يوجد اتصال بالإنترنت."
        case let .server(code, status):
            let t: [String: String] = [
                "not_allowed": "أمير الطلعة هو اللي يشغّل. يقدر يفتحها للكل من «الكل يقدر يشغّل».",
                "leader_only": "هذا لأمير الطلعة أو نائبه فقط.",
                "audio_idle": "ما فيه شي شغّال في إذاعة الطلعة.",
                "queue_full": "القائمة مليانة (٢٠).",
                "unknown_station": "هذي الإذاعة ما عادت متاحة.",
                "live_stream": "البث المباشر ما يتقدّم ولا يرجع.",
                "outing_ended": "انتهت هذه الطلعة.",
                "rate_limited": "على هونك… اصبر ثواني.",
                "not_a_member": "لست عضوًا في هذه الطلعة.",
            ]
            return t[code] ?? (status == 0 ? "لا يوجد اتصال بالإنترنت." : "حدث خطأ. أعد المحاولة.")
        }
    }
}

struct GroupAudioReply: Equatable {
    var state: GroupAudioState
    var canControl: Bool?
    /// Server − device (ms), measured on this round trip.
    var clockOffsetMs: Double?
}

@MainActor
protocol GroupAudioBackend: AnyObject {
    /// Shared with the trip (false: only this phone — the demo and an older server).
    var isShared: Bool { get }
    func fetch() async throws -> GroupAudioReply
    func send(_ c: GroupAudioCommand) async throws -> GroupAudioReply
}

/// `GET/POST /api/outings/:id/group-audio` with the device's Bearer token.
@MainActor
final class GroupAudioHTTPBackend: GroupAudioBackend {
    let outingId: String
    let isShared = true
    private let base: URL
    private let token: () -> String?
    private let session: URLSession

    init(outingId: String, base: URL = Endpoints.apiBase, session: URLSession = .shared, token: @escaping () -> String? = { IdentityStore.currentToken() }) {
        self.outingId = outingId
        self.base = base
        self.session = session
        self.token = token
    }

    private func request(_ method: String, body: [String: Any]? = nil) async throws -> GroupAudioReply {
        var req = URLRequest(url: base.appendingPathComponent("api/outings/\(outingId)/group-audio"), timeoutInterval: 10)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let t = token() { req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let sent = Date()
        let data: Data, resp: URLResponse
        do { (data, resp) = try await session.data(for: req) } catch { throw GroupAudioBackendError.network }
        let received = Date()
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let code = obj?["error"] as? String
        if status == 404 && code != "not_a_member" { throw GroupAudioBackendError.notDeployed }
        guard (200..<300).contains(status), obj?["ok"] as? Bool != false else {
            throw GroupAudioBackendError.server(code: code ?? "http_\(status)", status: status)
        }
        guard let state = GroupAudioEvents.decodeState(obj?["group_audio"]) else { throw GroupAudioBackendError.notDeployed }
        let offset = ISODate.parse(obj?["server_now"] as? String).map { GroupAudioSync.clockOffsetMs(serverNow: $0, sentAt: sent, receivedAt: received) }
        return GroupAudioReply(state: state, canControl: obj?["can_control"] as? Bool, clockOffsetMs: offset)
    }

    func fetch() async throws -> GroupAudioReply { try await request("GET") }
    func send(_ c: GroupAudioCommand) async throws -> GroupAudioReply { try await request("POST", body: c.body) }
}

/// No server (the demo outing, or a server without «إذاعة الطلعة» yet): the same rules
/// on the phone, for this phone only.
@MainActor
final class GroupAudioLocalBackend: GroupAudioBackend {
    private(set) var state: GroupAudioState
    let me: String
    let iLead: Bool
    let isShared: Bool
    var now: () -> Date = Date.init

    init(me: String, iLead: Bool, shared: Bool = false, seeded: GroupAudioState? = nil) {
        self.me = me
        self.iLead = iLead
        isShared = shared
        state = seeded ?? .idle()
    }

    private func rebased() -> GroupAudioState {
        var s = state
        s.position_s = s.position(atServer: now())
        s.at = ISODate.string(now())
        return s
    }

    func fetch() async throws -> GroupAudioReply { .init(state: rebased(), canControl: GroupAudioPermissions.canControl(state, iLead: iLead), clockOffsetMs: 0) }

    func send(_ c: GroupAudioCommand) async throws -> GroupAudioReply {
        var s = rebased()
        switch c.action {
        case .allow_all:
            guard iLead else { throw GroupAudioBackendError.server(code: "leader_only", status: 403) }
            s.allow_all = c.value ?? false
        case .queue_add:
            guard s.item != nil else { throw GroupAudioBackendError.server(code: "audio_idle", status: 409) }
            guard s.queue.count < GroupAudioPermissions.queueMax else { throw GroupAudioBackendError.server(code: "queue_full", status: 409) }
            if let i = c.item { s.queue.append(i) }
        default:
            guard GroupAudioPermissions.canControl(s, iLead: iLead) else { throw GroupAudioBackendError.server(code: "not_allowed", status: 403) }
            guard s.item != nil || c.action == .play_item || c.action == .stop else { throw GroupAudioBackendError.server(code: "audio_idle", status: 409) }
            switch c.action {
            case .play_item:
                s.item = c.item
                s.position_s = 0
                s.playing = true
                s.started_at = ISODate.string(now())
                s.by = me
            case .play: s.playing = true; s.by = me
            case .pause: s.playing = false; s.by = me
            case .seek:
                if s.item?.live == true { throw GroupAudioBackendError.server(code: "live_stream", status: 409) }
            case .next:
                s.item = s.queue.isEmpty ? nil : s.queue.removeFirst()
                s.position_s = 0
                s.playing = s.item != nil
                s.by = me
            case .stop:
                s.item = nil
                s.playing = false
                s.position_s = 0
                s.by = me
            default: break
            }
            if let p = c.position, c.action != .play_item, s.item?.live == false { s.position_s = p }
        }
        s.seq += 1
        s.at = ISODate.string(now())
        state = s
        return .init(state: s, canControl: GroupAudioPermissions.canControl(s, iLead: iLead), clockOffsetMs: 0)
    }

    /// The demo: «أبو فهد» (the leader) starts a station for everyone.
    func simulateRemote(_ next: GroupAudioState) { state = next }
}

/// `group_audio_state` frames (and the `ready` snapshot's `group_audio`) from the live
/// WebSocket, handed over by `LiveChannel` without it knowing anything about audio.
enum GroupAudioEvents {
    static let name = Notification.Name("sary.groupAudio.state")

    static func post(outingId: String, raw: Any?, serverNow: String? = nil) {
        var info: [String: Any] = ["outing": outingId, "state": raw ?? NSNull()]
        if let serverNow { info["server_now"] = serverNow }
        NotificationCenter.default.post(name: name, object: nil, userInfo: info)
    }

    static func decodeState(_ raw: Any?) -> GroupAudioState? {
        guard let raw, !(raw is NSNull), JSONSerialization.isValidJSONObject(raw),
              let d = try? JSONSerialization.data(withJSONObject: raw) else { return nil }
        return try? JSONDecoder().decode(GroupAudioState.self, from: d)
    }
}

/// Audius public API — search tracks (no key; `app_name` on every call, per Audius' API terms).
enum AudiusAPI {
    static let base = URL(string: "https://api.audius.co/v1")!

    struct Track: Decodable, Equatable {
        struct User: Decodable, Equatable { var name: String? }
        var id: String
        var title: String
        var duration: Double?
        var user: User?
        var is_streamable: Bool?
        var permalink: String?

        var item: GroupAudioItem {
            GroupAudioItem(source: .audius, id: id, title: title, subtitle: user?.name ?? "", url: nil, live: false, duration_s: duration)
        }
    }

    static func decodeSearch(_ data: Data) -> [Track] {
        struct Wire: Decodable { var data: [Track] }
        let tracks = (try? JSONDecoder().decode(Wire.self, from: data))?.data ?? []
        /* Only what the artist lets third-party apps stream. */
        return tracks.filter { $0.is_streamable != false && !$0.id.isEmpty && $0.id.allSatisfy { $0.isLetter || $0.isNumber } }
    }

    static func search(_ q: String, session: URLSession = .shared) async -> [Track] {
        let t = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return [] }
        var c = URLComponents(url: base.appendingPathComponent("tracks/search"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "query", value: String(t.prefix(80))), URLQueryItem(name: "app_name", value: GroupAudioItem.audiusAppName)]
        guard let url = c.url, let (data, resp) = try? await session.data(for: URLRequest(url: url, timeoutInterval: 10)),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        return Array(decodeSearch(data).prefix(25))
    }
}
