import Foundation

/// The server side of the trip chat. `OutingsAPI` in the app, `DemoChatBackend` in `-demo`, fakes in tests.
protocol ChatBackend: AnyObject {
    func chatOverview(_ outingId: String) async throws -> ChatOverview
    func chatPage(_ outingId: String, with: ChatWith, before: Int?, after: Int?, limit: Int) async throws -> ChatPage
    func chatSend(_ outingId: String, draft: ChatDraft) async throws -> ChatMessage
    func chatRead(_ outingId: String, with: ChatWith, seq: Int) async throws
    func chatDelete(_ outingId: String, messageId: String) async throws -> ChatMessage
}

/// Messages I wrote that the server does not have yet, per outing, on this device
/// (survives a relaunch in a tunnel). Retried until stored or refused for good.
struct ChatOutbox {
    let defaults: UserDefaults
    let outingId: String

    static let prefix = "sary.chat.outbox.v1."
    private var key: String { Self.prefix + outingId }

    func load() -> [ChatDraft] {
        guard let d = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([ChatDraft].self, from: d)) ?? []
    }

    func save(_ drafts: [ChatDraft]) {
        if drafts.isEmpty { return defaults.removeObject(forKey: key) }
        if let d = try? JSONEncoder().encode(drafts) { defaults.set(d, forKey: key) }
    }

    /// «احذف حسابي»: nothing of the chat stays on the phone.
    static func wipeAll(_ defaults: UserDefaults = .standard) {
        for k in defaults.dictionaryRepresentation().keys where k.hasPrefix(prefix) { defaults.removeObject(forKey: k) }
    }
}

/// One conversation as this phone knows it.
struct ChatThreadState: Equatable {
    var messages: [ChatMessage] = []
    var hasMore = false
    var loaded = false
    /// Others' read markers (user id → seq), for ✓✓.
    var reads: [String: Int] = [:]
    var myReadSeq = 0
    var unread = 0
    var writable = true
    var readOnlyReason: String?
    /// From the conversation list, before the thread itself is loaded.
    var lastMessage: ChatMessage?

    var lastSeq: Int { messages.last(where: { !$0.isPending })?.seq ?? lastMessage?.seq ?? 0 }
    var latest: ChatMessage? { messages.last ?? lastMessage }
}

/// «المحادثات» for one outing: the conversations, the outbox, live frames, unread badges.
/// Socket first (`chat_message` / `chat_read` / `chat_typing`), HTTP when the socket is not
/// there or a frame goes unanswered; every send is idempotent on its client_id.
@MainActor
final class ChatStore: ObservableObject {
    struct Deps {
        /// A chat frame on the live socket; false when the socket is not live.
        var sendFrame: ([String: Any]) -> Bool = { _ in false }
        var isLive: () -> Bool = { false }
        var after: (TimeInterval, @escaping () -> Void) -> Void = { s, f in DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: f) }
        var now: () -> Date = Date.init
        var myName: () -> String? = { nil }
    }

    let outingId: String
    let me: String
    @Published private(set) var threads: [ChatWith: ChatThreadState] = [:]
    @Published private(set) var writable = true
    @Published private(set) var readOnlyReason: String?
    @Published private(set) var canModerate = false
    @Published private(set) var quickReplies = ChatRules.quickReplies
    @Published private(set) var purgeAt: String?
    @Published private(set) var retentionDays = 30
    @Published private(set) var overviewLoaded = false
    /// The server has the chat routes (unknown until the first answer). An older server
    /// (before migration 012) answers 404: the app then hides the chat with a calm note.
    enum Availability: Equatable { case unknown, available, notDeployed }
    @Published private(set) var availability: Availability = .unknown
    var isAvailable: Bool { availability == .available }
    /// «فهد يكتب…» per conversation (user id), cleared after a few seconds.
    @Published private(set) var typing: [ChatWith: String] = [:]
    @Published var lastError: String?
    /// The conversation on screen right now (its messages count as read).
    @Published private(set) var visible: ChatWith?
    /// The badge before the conversation list is loaded (from the outing snapshot).
    @Published private(set) var snapshotUnread = 0
    /// Someone else's new message while that conversation is not on screen (the live screen toasts it).
    var onIncoming: (ChatMessage) -> Void = { _ in }

    private let backend: ChatBackend
    private let outbox: ChatOutbox
    private var deps: Deps
    private var drafts: [ChatDraft]
    private var inflight: Set<String> = []
    private var frameSeq = 0
    private var retryScheduled = false
    private var readSent: [ChatWith: Int] = [:]
    private var lastTypingSent: [ChatWith: Date] = [:]

    init(outingId: String, me: String, backend: ChatBackend, defaults: UserDefaults = .standard, deps: Deps = Deps()) {
        self.outingId = outingId
        self.me = me
        self.backend = backend
        self.outbox = ChatOutbox(defaults: defaults, outingId: outingId)
        self.deps = deps
        drafts = outbox.load()
        for d in drafts { insert([d.pendingMessage(outingId: outingId, me: me, myName: nil).with(delivery: .retrying)], into: d.with) }
    }

    func configure(_ deps: Deps) { self.deps = deps }

    // MARK: - badges

    var totalUnread: Int {
        guard availability != .notDeployed else { return 0 }
        return overviewLoaded ? threads.values.reduce(0) { $0 + $1.unread } : snapshotUnread
    }

    /// 404 / 405 for a route the server does not have (not «not a member», which is a real answer).
    static func notDeployed(_ e: OutingAPIError) -> Bool {
        (e.status == 404 || e.status == 405) && e.code != "not_a_member" && e.code != "message_not_found"
    }

    func unread(_ w: ChatWith) -> Int { threads[w]?.unread ?? 0 }

    func snapshot(unread: Int?) {
        guard let unread, !overviewLoaded else { return }
        snapshotUnread = unread
    }

    /// The conversations to list: group first, then direct chats with messages (newest first).
    var directThreads: [ChatWith] {
        threads.keys.filter { !$0.isGroup && threads[$0]?.latest != nil }
            .sorted { (threads[$0]?.latest?.seq ?? 0) > (threads[$1]?.latest?.seq ?? 0) }
    }

    // MARK: - loading

    func refresh() async {
        do {
            let o = try await backend.chatOverview(outingId)
            writable = o.writable
            readOnlyReason = o.read_only_reason
            canModerate = o.can_moderate
            if let q = o.quick_replies, !q.isEmpty { quickReplies = q }
            purgeAt = o.purge_at
            retentionDays = o.retention_days ?? 30
            for c in o.conversations {
                let w = ChatWith(wire: c.with)
                var t = threads[w] ?? ChatThreadState()
                t.unread = w == visible ? 0 : c.unread
                t.myReadSeq = max(t.myReadSeq, c.my_read_seq)
                t.writable = c.writable
                if let lm = c.last_message { t.lastMessage = lm }
                if let p = c.peer_read_seq, let peer = w.peer { t.reads[peer] = max(t.reads[peer] ?? 0, p) }
                threads[w] = t
            }
            if threads[.group] == nil { threads[.group] = ChatThreadState() }
            overviewLoaded = true
            availability = .available
            lastError = nil
        } catch let e as OutingAPIError where Self.notDeployed(e) {
            /* The production server before the chat PR: no chat, no error, nothing queued. */
            availability = .notDeployed
            return
        } catch {
            /* keep what we have; the badge falls back to the snapshot */
        }
        if availability == .available { flushOutbox() }
    }

    /// The newest page (first open), or what is newer than what we have (after a gap).
    func load(_ w: ChatWith) async {
        let t = threads[w] ?? ChatThreadState()
        do {
            let after = t.loaded ? t.lastSeq : nil
            let p = try await backend.chatPage(outingId, with: w, before: nil, after: after, limit: 50)
            apply(page: p, to: w, replaceHasMore: !t.loaded)
        } catch let e as OutingAPIError {
            lastError = ChatRules.errorText(e.code)
        } catch {}
    }

    func loadOlder(_ w: ChatWith) async {
        guard let first = threads[w]?.messages.first(where: { !$0.isPending }) else { return }
        guard let p = try? await backend.chatPage(outingId, with: w, before: first.seq, after: nil, limit: 50) else { return }
        apply(page: p, to: w, replaceHasMore: true)
    }

    private func apply(page p: ChatPage, to w: ChatWith, replaceHasMore: Bool) {
        var t = threads[w] ?? ChatThreadState()
        t.messages = ChatRules.merge(t.messages, p.messages)
        if replaceHasMore { t.hasMore = p.has_more }
        t.loaded = true
        t.myReadSeq = max(t.myReadSeq, p.my_read_seq)
        for r in p.reads { t.reads[r.user_id] = max(t.reads[r.user_id] ?? 0, r.seq) }
        t.writable = p.writable
        t.readOnlyReason = p.read_only_reason
        if w == visible { t.unread = 0 }
        threads[w] = t
        if w == visible { markRead(w) }
    }

    // MARK: - on screen

    func open(_ w: ChatWith) {
        visible = w
        var t = threads[w] ?? ChatThreadState()
        t.unread = 0
        threads[w] = t
        markRead(w)
        Task { await load(w) }
    }

    func close(_ w: ChatWith) {
        if visible == w { visible = nil }
        sendTyping(w, on: false)
    }

    private func markRead(_ w: ChatWith) {
        guard let t = threads[w] else { return }
        let seq = t.lastSeq
        guard seq > 0, seq > (readSent[w] ?? 0) else { return }
        readSent[w] = seq
        threads[w]?.myReadSeq = seq
        if deps.sendFrame(["type": "chat_read", "with": w.wire, "seq": seq]) { return }
        Task { [backend, outingId] in try? await backend.chatRead(outingId, with: w, seq: seq) }
    }

    // MARK: - sending

    func sendText(_ raw: String, to w: ChatWith) -> Bool {
        switch ChatRules.check(raw) {
        case .empty: return false
        case .tooLong:
            lastError = ChatRules.errorText("text_too_long")
            return false
        case let .ok(t):
            enqueue(ChatDraft(client_id: ChatRules.newClientId(), with: w, kind: .text, text: t, point: nil, created_at: ISODate.string(deps.now())))
            return true
        }
    }

    func sendQuick(_ text: String, to w: ChatWith) {
        enqueue(ChatDraft(client_id: ChatRules.newClientId(), with: w, kind: .quick, text: text, point: nil, created_at: ISODate.string(deps.now())))
    }

    func sendPoint(_ p: ChatPoint, to w: ChatWith) {
        enqueue(ChatDraft(client_id: ChatRules.newClientId(), with: w, kind: .location, text: nil, point: p, created_at: ISODate.string(deps.now())))
    }

    private func enqueue(_ d: ChatDraft) {
        guard availability != .notDeployed else { return }
        guard writable, threads[d.with]?.writable ?? true else {
            lastError = ChatRules.errorText(threads[d.with]?.readOnlyReason ?? readOnlyReason ?? "outing_ended")
            return
        }
        drafts.append(d)
        outbox.save(drafts)
        insert([d.pendingMessage(outingId: outingId, me: me, myName: deps.myName())], into: d.with)
        deliver(d)
    }

    /// Socket when it is live and the frame is small, else HTTP. Unanswered frames fall back to HTTP.
    private func deliver(_ d: ChatDraft) {
        guard !inflight.contains(d.client_id) else { return }
        inflight.insert(d.client_id)
        var frame = d.body
        frame["type"] = "chat_message"
        frame["with"] = d.with.wire
        frameSeq += 1
        frame["id"] = frameSeq
        let small = ((try? JSONSerialization.data(withJSONObject: frame))?.count ?? .max) <= ChatRules.maxSocketBytes
        if small, deps.isLive(), deps.sendFrame(frame) {
            deps.after(8) { [weak self] in
                guard let self, self.inflight.contains(d.client_id), self.drafts.contains(where: { $0.client_id == d.client_id }) else { return }
                self.inflight.remove(d.client_id)
                self.deliverHTTP(d)
            }
            return
        }
        inflight.remove(d.client_id)
        deliverHTTP(d)
    }

    private func deliverHTTP(_ d: ChatDraft) {
        guard !inflight.contains(d.client_id) else { return }
        inflight.insert(d.client_id)
        Task { [backend, outingId] in
            do {
                let m = try await backend.chatSend(outingId, draft: d)
                self.inflight.remove(d.client_id)
                self.stored(m)
            } catch let e as OutingAPIError where Self.notDeployed(e) {
                self.inflight.remove(d.client_id)
                self.availability = .notDeployed
                self.setDelivery(d, .retrying)
            } catch let e as OutingAPIError {
                self.inflight.remove(d.client_id)
                self.failed(d, code: e.code)
            } catch {
                self.inflight.remove(d.client_id)
                self.failed(d, code: "network")
            }
        }
    }

    private func stored(_ m: ChatMessage) {
        drafts.removeAll { $0.client_id == m.client_id }
        outbox.save(drafts)
        let w = m.thread(me: me)
        insert([m], into: w)
        threads[w]?.myReadSeq = max(threads[w]?.myReadSeq ?? 0, m.seq)
        lastError = nil
    }

    private func failed(_ d: ChatDraft, code: String) {
        guard let i = drafts.firstIndex(where: { $0.client_id == d.client_id }) else { return }
        if ChatRules.terminal.contains(code) {
            drafts.remove(at: i)
            outbox.save(drafts)
            setDelivery(d, .failed(code))
            lastError = ChatRules.errorText(code)
            if code == "outing_ended" || code == "chat_read_only" { writable = false; readOnlyReason = code }
            if code == "peer_not_active" { threads[d.with]?.writable = false; threads[d.with]?.readOnlyReason = code }
            return
        }
        drafts[i].attempts += 1
        outbox.save(drafts)
        setDelivery(d, .retrying)
        scheduleRetry(attempts: drafts[i].attempts)
    }

    private func scheduleRetry(attempts: Int) {
        guard !retryScheduled else { return }
        retryScheduled = true
        let wait = min(60, pow(2, Double(min(attempts, 6))) * 1.5)
        deps.after(wait) { [weak self] in
            self?.retryScheduled = false
            self?.flushOutbox()
        }
    }

    /// Network back, socket live, foreground: try everything still waiting.
    func flushOutbox() {
        guard availability != .notDeployed else { return }
        for d in drafts { deliver(d) }
    }

    /// The person gives up on a message that cannot go out.
    func discard(_ m: ChatMessage) {
        drafts.removeAll { $0.client_id == m.client_id }
        outbox.save(drafts)
        let w = m.thread(me: me)
        threads[w]?.messages.removeAll { $0.key == m.key && $0.isPending }
    }

    func retry(_ m: ChatMessage) {
        guard let d = drafts.first(where: { $0.client_id == m.client_id }) else {
            /* Refused for good earlier: send again as a new message. */
            discard(m)
            switch m.kind {
            case .location: if let p = m.point { sendPoint(p, to: m.thread(me: me)) }
            case .quick: if let t = m.text { sendQuick(t, to: m.thread(me: me)) }
            case .text: if let t = m.text { _ = sendText(t, to: m.thread(me: me)) }
            }
            return
        }
        setDelivery(d, .sending)
        deliver(d)
    }

    func delete(_ m: ChatMessage) async {
        do {
            let r = try await backend.chatDelete(outingId, messageId: m.id)
            insert([r], into: r.thread(me: me))
        } catch let e as OutingAPIError {
            lastError = ChatRules.errorText(e.code)
        } catch {
            lastError = ChatRules.errorText("network")
        }
    }

    func canDelete(_ m: ChatMessage) -> Bool {
        guard !m.deleted, !m.isPending else { return false }
        return m.sender_id == me || (m.conv == "group" && canModerate)
    }

    /// «يكتب…»: at most every 3 s, only on the socket (a hint, never queued).
    func sendTyping(_ w: ChatWith, on: Bool = true) {
        if on, let last = lastTypingSent[w], deps.now().timeIntervalSince(last) < 3 { return }
        lastTypingSent[w] = on ? deps.now() : nil
        _ = deps.sendFrame(["type": "chat_typing", "with": w.wire, "on": on])
    }

    // MARK: - live frames

    /// A `chat_*` frame from the live socket.
    func receive(_ msg: [String: Any]) {
        guard let type = msg["type"] as? String else { return }
        switch type {
        case "chat_message", "chat_deleted":
            guard let m = decode(msg["message"]) else { return }
            let w = m.thread(me: me)
            let isNew = threads[w]?.messages.contains(where: { $0.key == m.key }) != true
            insert([m], into: w)
            if m.sender_id == me {
                drafts.removeAll { $0.client_id == m.client_id }
                outbox.save(drafts)
                inflight.remove(m.client_id)
            } else if type == "chat_message", isNew, !m.deleted {
                typing[w] = nil
                if visible == w {
                    markRead(w)
                } else {
                    threads[w, default: ChatThreadState()].unread += 1
                    onIncoming(m)
                }
            }
        case "chat_ack":
            if msg["ok"] as? Bool == true, let m = decode(msg["message"]) {
                inflight.remove(m.client_id)
                stored(m)
            } else if let cid = msg["client_id"] as? String, let d = drafts.first(where: { $0.client_id == cid }) {
                inflight.remove(cid)
                failed(d, code: msg["reason"] as? String ?? "server_error")
            }
        case "chat_read":
            guard let uid = msg["user_id"] as? String, let seq = msg["seq"] as? Int else { return }
            let w: ChatWith = (msg["conv"] as? String) == "direct" ? .direct(uid == me ? (msg["peer_id"] as? String ?? "") : uid) : .group
            if uid == me {
                threads[w]?.myReadSeq = max(threads[w]?.myReadSeq ?? 0, seq)
                threads[w]?.unread = 0
            } else {
                threads[w, default: ChatThreadState()].reads[uid] = max(threads[w]?.reads[uid] ?? 0, seq)
            }
        case "chat_typing":
            guard let uid = msg["user_id"] as? String, uid != me else { return }
            let w: ChatWith = (msg["conv"] as? String) == "direct" ? .direct(uid) : .group
            if msg["on"] as? Bool == false { typing[w] = nil; return }
            typing[w] = uid
            deps.after(5) { [weak self] in if self?.typing[w] == uid { self?.typing[w] = nil } }
        default:
            break
        }
    }

    /// The socket is live again: catch up what we missed and send what waited.
    func linkLive() {
        flushOutbox()
        Task {
            await refresh()
            for (w, t) in threads where t.loaded { await load(w) }
        }
    }

    // MARK: - internals

    private func decode(_ raw: Any?) -> ChatMessage? {
        guard let raw, let d = try? JSONSerialization.data(withJSONObject: raw) else { return nil }
        return try? JSONDecoder().decode(ChatMessage.self, from: d)
    }

    private func insert(_ ms: [ChatMessage], into w: ChatWith) {
        var t = threads[w] ?? ChatThreadState()
        t.messages = ChatRules.merge(t.messages, ms)
        if let last = t.messages.last { t.lastMessage = last }
        threads[w] = t
    }

    private func setDelivery(_ d: ChatDraft, _ s: ChatMessage.Delivery) {
        let key = "\(me):\(d.client_id)"
        guard let i = threads[d.with]?.messages.firstIndex(where: { $0.key == key && $0.isPending }) else { return }
        threads[d.with]?.messages[i].delivery = s
    }
}

extension ChatMessage {
    func with(delivery: Delivery) -> ChatMessage {
        var c = self
        c.delivery = delivery
        return c
    }
}

// MARK: - the real server

extension OutingsAPI: ChatBackend {
    private struct PageBox: Decodable { var with: String; var messages: [ChatMessage]; var has_more: Bool; var my_read_seq: Int; var reads: [ChatRead]; var writable: Bool; var read_only_reason: String? }
    private struct MessageBox: Decodable { var message: ChatMessage }

    func chatOverview(_ outingId: String) async throws -> ChatOverview { try await call("GET", "/\(outingId)/chat") }

    func chatPage(_ outingId: String, with: ChatWith, before: Int?, after: Int?, limit: Int) async throws -> ChatPage {
        var q = ["limit=\(limit)"]
        if let before { q.append("before=\(before)") }
        if let after { q.append("after=\(after)") }
        let b: PageBox = try await call("GET", "/\(outingId)/chat/\(with.wire)", query: q.joined(separator: "&"))
        return ChatPage(with: b.with, messages: b.messages, has_more: b.has_more, my_read_seq: b.my_read_seq, reads: b.reads, writable: b.writable, read_only_reason: b.read_only_reason)
    }

    func chatSend(_ outingId: String, draft: ChatDraft) async throws -> ChatMessage {
        let b: MessageBox = try await call("POST", "/\(outingId)/chat/\(draft.with.wire)", body: ChatSendBody(draft))
        return b.message
    }

    func chatRead(_ outingId: String, with: ChatWith, seq: Int) async throws {
        let _: OkBox = try await call("POST", "/\(outingId)/chat/\(with.wire)/read", body: ["seq": seq])
    }

    func chatDelete(_ outingId: String, messageId: String) async throws -> ChatMessage {
        let b: MessageBox = try await call("DELETE", "/\(outingId)/chat/messages/\(messageId)")
        return b.message
    }

    struct ChatPrefs: Codable { var chat_push: Bool }
    func chatPrefs() async throws -> ChatPrefs { try await call("GET", "/push/chat") }
    func setChatPrefs(_ on: Bool) async throws -> ChatPrefs { try await call("PUT", "/push/chat", body: ChatPrefs(chat_push: on)) }
}

private struct ChatSendBody: Encodable {
    var client_id: String
    var kind: String
    var text: String?
    var point: ChatPoint?
    init(_ d: ChatDraft) {
        client_id = d.client_id
        kind = d.kind.rawValue
        text = d.text
        point = d.point
    }
}

// MARK: - the demo / stub

/// `-demo` (screenshots, UI tests): an in-memory chat with the demo friends. Clearly a demo:
/// never talks to the server. «أبو فهد» answers in the group, and reads what you send.
final class DemoChatBackend: ChatBackend, @unchecked Sendable {
    var emit: ([String: Any]) -> Void = { _ in }
    private let me: String
    private var seq = 0
    private var messages: [ChatMessage] = []
    private let outingId: String
    let friends: [String: String]
    /// `-SaryChatOffline`: sending fails like a dead network (the outbox keeps it).
    var offline = ProcessInfo.processInfo.arguments.contains("-SaryChatOffline")

    init(outingId: String, me: String, friends: [String: String], now: Date = Date()) {
        self.outingId = outingId
        self.me = me
        self.friends = friends
        let ids = friends.keys.sorted()
        if let a = ids.first {
            add(sender: a, to: nil, kind: .text, text: "هلا بالشباب، وصلنا أول النفود 👋", at: now.addingTimeInterval(-900))
            add(sender: a, to: nil, kind: .location, point: ChatPoint(lat: 24.7141, lng: 46.6727, label: "مخيم الشباب"), at: now.addingTimeInterval(-840))
        }
        if ids.count > 1 {
            add(sender: ids[1], to: nil, kind: .quick, text: "انتظروني", at: now.addingTimeInterval(-600))
            add(sender: ids[1], to: me, kind: .text, text: "عندك حبل سحب زيادة؟", at: now.addingTimeInterval(-300))
        }
    }

    @discardableResult
    private func add(sender: String, to: String?, kind: ChatKind, text: String? = nil, point: ChatPoint? = nil, at: Date = Date(), clientId: String? = nil) -> ChatMessage {
        seq += 1
        let m = ChatMessage(id: "demo-chat-\(seq)", outing_id: outingId, seq: seq, conv: to == nil ? "group" : [sender, to!].sorted().joined(separator: ":"),
                            sender_id: sender, recipient_id: to, sender_name: friends[sender], client_id: clientId ?? "demo-\(seq)", kind: kind,
                            text: text, point: point, created_at: ISODate.string(at), deleted: false, deleted_by: nil)
        messages.append(m)
        return m
    }

    private func inThread(_ m: ChatMessage, _ w: ChatWith) -> Bool { m.thread(me: me) == w }

    func chatOverview(_ outingId: String) async throws -> ChatOverview {
        var convs: [ChatConversationWire] = []
        var keys: [ChatWith] = [.group]
        for m in messages where !keys.contains(m.thread(me: me)) { keys.append(m.thread(me: me)) }
        for w in keys {
            let list = messages.filter { inThread($0, w) }
            convs.append(ChatConversationWire(with: w.wire, conv: w.isGroup ? "group" : "direct", peer_id: w.peer, peer_active: true,
                                              unread: list.filter { $0.sender_id != me && $0.seq > (readMarks[w] ?? 0) }.count,
                                              last_message: list.last, my_read_seq: readMarks[w] ?? 0, peer_read_seq: nil, writable: true))
        }
        return ChatOverview(conversations: convs, unread_total: convs.reduce(0) { $0 + $1.unread }, writable: true, read_only_reason: nil,
                            can_moderate: true, quick_replies: ChatRules.quickReplies, retention_days: 30, purge_at: nil)
    }

    private var readMarks: [ChatWith: Int] = [:]

    func chatPage(_ outingId: String, with: ChatWith, before: Int?, after: Int?, limit: Int) async throws -> ChatPage {
        var list = messages.filter { inThread($0, with) }
        if let before { list = list.filter { $0.seq < before } }
        if let after { list = list.filter { $0.seq > after } }
        let more = list.count > limit
        list = Array(list.suffix(limit))
        return ChatPage(with: with.wire, messages: list, has_more: more, my_read_seq: readMarks[with] ?? 0, reads: [], writable: true, read_only_reason: nil)
    }

    func chatSend(_ outingId: String, draft: ChatDraft) async throws -> ChatMessage {
        if offline { throw OutingAPIError(code: "network", status: 0) }
        if let prior = messages.first(where: { $0.client_id == draft.client_id && $0.sender_id == me }) { return prior }
        let m = add(sender: me, to: draft.with.peer, kind: draft.kind, text: draft.text, point: draft.point, clientId: draft.client_id)
        readMarks[draft.with] = m.seq
        /* The friends read it, and «أبو فهد» answers in the group. */
        let w = draft.with
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            for f in self.friends.keys {
                if w.isGroup || w.peer == f {
                    self.emit(["type": "chat_read", "conv": w.isGroup ? "group" : "direct", "user_id": f, "peer_id": self.me, "seq": m.seq])
                }
            }
        }
        if w.isGroup, let a = friends.keys.sorted().first {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
                guard let self else { return }
                self.emit(["type": "chat_typing", "conv": "group", "user_id": a, "on": true])
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { [weak self] in
                guard let self else { return }
                let r = self.add(sender: a, to: nil, kind: .text, text: "تمام، وصلت 👍")
                if let d = try? JSONEncoder().encode(r), let o = try? JSONSerialization.jsonObject(with: d) {
                    self.emit(["type": "chat_message", "message": o])
                }
            }
        }
        return m
    }

    func chatRead(_ outingId: String, with: ChatWith, seq: Int) async throws { readMarks[with] = max(readMarks[with] ?? 0, seq) }

    func chatDelete(_ outingId: String, messageId: String) async throws -> ChatMessage {
        guard let i = messages.firstIndex(where: { $0.id == messageId }) else { throw OutingAPIError(code: "message_not_found", status: 404) }
        messages[i].deleted = true
        messages[i].deleted_by = messages[i].sender_id == me ? "self" : "leader"
        messages[i].text = nil
        messages[i].point = nil
        return messages[i]
    }
}
