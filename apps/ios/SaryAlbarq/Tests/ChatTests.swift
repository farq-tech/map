import XCTest
@testable import SaryAlbarq

/// «المحادثات»: the rules, the store (socket + HTTP + outbox), unread badges, receipts,
/// the driving block, and the live channel routing chat frames.
@MainActor
final class ChatTests: XCTestCase {
    nonisolated static let me = "00000000-0000-4000-8000-00000000000a"
    nonisolated static let fahd = "00000000-0000-4000-8000-00000000000b"
    nonisolated static let saad = "00000000-0000-4000-8000-00000000000c"

    /// A stand-in server: records what it was asked, fails as told.
    final class FakeBackend: ChatBackend {
        var overview = ChatOverview(conversations: [], unread_total: 0, writable: true, read_only_reason: nil, can_moderate: false,
                                    quick_replies: nil, retention_days: 30, purge_at: nil)
        var page = ChatPage(with: "group", messages: [], has_more: false, my_read_seq: 0, reads: [], writable: true, read_only_reason: nil)
        var failWith: String?
        var overviewError: OutingAPIError?
        var sent: [ChatDraft] = []
        var reads: [(ChatWith, Int)] = []
        var seq = 10

        func chatOverview(_ outingId: String) async throws -> ChatOverview {
            if let e = overviewError { throw e }
            return overview
        }
        func chatPage(_ outingId: String, with: ChatWith, before: Int?, after: Int?, limit: Int) async throws -> ChatPage { page }
        func chatSend(_ outingId: String, draft: ChatDraft) async throws -> ChatMessage {
            sent.append(draft)
            if let f = failWith { throw OutingAPIError(code: f, status: f == "network" ? 0 : 409) }
            seq += 1
            return ChatTests.message(seq, from: ChatTests.me, to: draft.with.peer, clientId: draft.client_id, text: draft.text)
        }
        func chatRead(_ outingId: String, with: ChatWith, seq: Int) async throws { reads.append((with, seq)) }
        func chatDelete(_ outingId: String, messageId: String) async throws -> ChatMessage {
            var m = ChatTests.message(1, from: ChatTests.fahd)
            m.deleted = true
            m.deleted_by = "leader"
            m.text = nil
            return m
        }
    }

    nonisolated static func message(_ seq: Int, from: String, to: String? = nil, clientId: String? = nil, text: String? = "هلا", kind: ChatKind = .text) -> ChatMessage {
        ChatMessage(id: "m\(seq)", outing_id: "o1", seq: seq, conv: to == nil ? "group" : [from, to!].sorted().joined(separator: ":"),
                    sender_id: from, recipient_id: to, sender_name: nil, client_id: clientId ?? "c\(seq)", kind: kind, text: text, point: nil,
                    created_at: ISODate.string(Date(timeIntervalSince1970: 1_800_000_000 + Double(seq))), deleted: false, deleted_by: nil)
    }

    nonisolated static func wire(_ m: ChatMessage) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(m))) as? [String: Any] ?? [:]
    }

    private var defaults: UserDefaults!
    private var frames: [[String: Any]] = []
    private var live = true
    private var later: [() -> Void] = []

    override func setUp() {
        defaults = UserDefaults(suiteName: "chat-tests-\(UUID().uuidString)")
        frames = []
        live = true
        later = []
    }

    private func store(_ backend: FakeBackend, live: Bool = true) -> ChatStore {
        self.live = live
        let s = ChatStore(outingId: "o1", me: Self.me, backend: backend, defaults: defaults)
        s.configure(.init(
            sendFrame: { [unowned self] f in guard self.live else { return false }; self.frames.append(f); return true },
            isLive: { [unowned self] in self.live },
            after: { [unowned self] _, f in self.later.append(f) }
        ))
        return s
    }

    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 30_000_000)
    }

    // MARK: rules

    func testDraftRulesAndDrivingGate() {
        XCTAssertEqual(ChatRules.check("  هلا \n"), .ok("هلا"))
        XCTAssertEqual(ChatRules.check("   "), .empty)
        XCTAssertEqual(ChatRules.check(String(repeating: "ب", count: 1000)), .ok(String(repeating: "ب", count: 1000)))
        XCTAssertEqual(ChatRules.check(String(repeating: "ب", count: 1001)), .tooLong)
        XCTAssertEqual(ChatRules.check(String(repeating: "🚙", count: 1000)).isOK, true, "code points, like the server")
        XCTAssertFalse(ChatRules.canType(moving: true), "«وقّف عشان تكتب»")
        XCTAssertTrue(ChatRules.canType(moving: false))
        XCTAssertEqual(ChatRules.quickReplies.prefix(3), ["بوقف", "محطة بنزين", "اصبروا لي"])
        XCTAssertEqual(ChatRules.deletedLabel(Self.message(1, from: Self.fahd).deletedBy("leader")), "حذفها أمير الرحلة")
        let id = ChatRules.newClientId()
        XCTAssertTrue(id.range(of: "^[A-Za-z0-9_.:-]{1,64}$", options: .regularExpression) != nil, "a client_id the server accepts")
    }

    func testDrivingBlockFollowsTheSpeedHysteresis() {
        var m = MotionHysteresis()
        m.ingest(speedMps: 14 / 3.6, at: 0)
        XCTAssertTrue(ChatRules.canType(moving: m.moving), "14 km/h: still typing")
        m.ingest(speedMps: 30 / 3.6, at: 1)
        XCTAssertFalse(ChatRules.canType(moving: m.moving), "> 15 km/h: no keyboard")
        m.ingest(speedMps: 0, at: 2)
        m.ingest(speedMps: 0, at: 25)
        XCTAssertTrue(ChatRules.canType(moving: m.moving), "stopped 20 s: type again")
    }

    func testMergeOrdersByServerSeqWithPendingLast() {
        var pending = Self.message(0, from: Self.me, clientId: "x")
        pending.delivery = .sending
        var list = ChatRules.merge([], [Self.message(3, from: Self.fahd), Self.message(1, from: Self.fahd), pending])
        XCTAssertEqual(list.map(\.seq), [1, 3, 0])
        list = ChatRules.merge(list, [Self.message(4, from: Self.me, clientId: "x")])
        XCTAssertEqual(list.map(\.seq), [1, 3, 4], "the server copy replaces the pending one")
        XCTAssertEqual(ChatRules.merge(list, [pending]).map(\.seq), [1, 3, 4], "a late pending echo never wins")
        XCTAssertEqual(ChatRules.merge(list, [Self.message(3, from: Self.fahd)]).count, 3, "socket + HTTP duplicates collapse")
    }

    func testReceipts() {
        let mine = Self.message(5, from: Self.me)
        XCTAssertEqual(ChatRules.receipt(mine, me: Self.me, reads: [:], others: 2), .sent)
        XCTAssertEqual(ChatRules.receipt(mine, me: Self.me, reads: [Self.fahd: 5], others: 2), .sent)
        XCTAssertEqual(ChatRules.receipt(mine, me: Self.me, reads: [Self.fahd: 5, Self.saad: 9], others: 2), .read, "✓✓")
        XCTAssertNil(ChatRules.receipt(Self.message(5, from: Self.fahd), me: Self.me, reads: [:], others: 2))
    }

    func testThreadKeyFromBothSides() {
        XCTAssertEqual(Self.message(1, from: Self.fahd, to: Self.me).thread(me: Self.me), .direct(Self.fahd))
        XCTAssertEqual(Self.message(1, from: Self.me, to: Self.fahd).thread(me: Self.me), .direct(Self.fahd))
        XCTAssertEqual(Self.message(1, from: Self.fahd).thread(me: Self.me), .group)
        XCTAssertEqual(ChatWith(wire: "group"), .group)
        XCTAssertEqual(ChatWith(wire: Self.fahd).wire, Self.fahd)
    }

    // MARK: store

    func testSendOverSocketThenAck() async {
        let b = FakeBackend()
        let s = store(b)
        XCTAssertTrue(s.sendText("وينكم؟", to: .group))
        XCTAssertEqual(frames.last?["type"] as? String, "chat_message")
        XCTAssertEqual(frames.last?["with"] as? String, "group")
        let cid = frames.last?["client_id"] as? String ?? ""
        XCTAssertEqual(s.threads[.group]?.messages.last?.delivery, .sending)
        XCTAssertEqual(ChatOutbox(defaults: defaults, outingId: "o1").load().count, 1, "kept until the server has it")
        s.receive(["type": "chat_ack", "id": 1, "ok": true, "message": Self.wire(Self.message(7, from: Self.me, clientId: cid, text: "وينكم؟"))])
        XCTAssertEqual(s.threads[.group]?.messages.map(\.seq), [7])
        XCTAssertEqual(s.threads[.group]?.messages.last?.delivery, .stored)
        XCTAssertTrue(ChatOutbox(defaults: defaults, outingId: "o1").load().isEmpty)
        XCTAssertTrue(b.sent.isEmpty, "no HTTP when the socket answered")
    }

    func testUnansweredFrameFallsBackToHTTPWithTheSameClientId() async {
        let b = FakeBackend()
        let s = store(b)
        _ = s.sendText("هلا", to: .group)
        let cid = frames.last?["client_id"] as? String
        later.forEach { $0() } // the 8 s ack timer fires
        await settle()
        XCTAssertEqual(b.sent.map(\.client_id), [cid].compactMap { $0 })
        XCTAssertEqual(s.threads[.group]?.messages.last?.delivery, .stored)
    }

    func testOfflineOutboxSurvivesARelaunchAndRetries() async {
        let b = FakeBackend()
        b.failWith = "network"
        let s = store(b, live: false)
        s.sendQuick("بوقف", to: .group)
        await settle()
        XCTAssertEqual(s.threads[.group]?.messages.last?.delivery, .retrying)
        XCTAssertEqual(ChatOutbox(defaults: defaults, outingId: "o1").load().map(\.text), ["بوقف"])
        /* The app is killed in the tunnel and opened again. */
        let s2 = store(b, live: false)
        XCTAssertEqual(s2.threads[.group]?.messages.count, 1, "the pending bubble is back")
        b.failWith = nil
        s2.flushOutbox()
        await settle()
        XCTAssertEqual(s2.threads[.group]?.messages.last?.delivery, .stored)
        XCTAssertEqual(Set(b.sent.map(\.client_id)).count, 1, "every retry carried the same client_id")
        XCTAssertTrue(ChatOutbox(defaults: defaults, outingId: "o1").load().isEmpty)
    }

    func testTerminalRefusalLeavesTheOutboxAndClosesTheChat() async {
        let b = FakeBackend()
        b.failWith = "outing_ended"
        let s = store(b, live: false)
        _ = s.sendText("هلا", to: .group)
        await settle()
        XCTAssertEqual(s.threads[.group]?.messages.last?.delivery, .failed("outing_ended"))
        XCTAssertTrue(ChatOutbox(defaults: defaults, outingId: "o1").load().isEmpty)
        XCTAssertFalse(s.writable)
        XCTAssertEqual(s.lastError, "انتهت الطلعة — المحادثة للقراءة فقط.")
    }

    func testUnreadBadgeAndReadOnOpen() async {
        let b = FakeBackend()
        b.overview.conversations = [
            ChatConversationWire(with: "group", conv: "group", peer_id: nil, peer_active: nil, unread: 2, last_message: Self.message(2, from: Self.fahd), my_read_seq: 0, peer_read_seq: nil, writable: true),
            ChatConversationWire(with: Self.saad, conv: "direct", peer_id: Self.saad, peer_active: true, unread: 1, last_message: Self.message(3, from: Self.saad, to: Self.me), my_read_seq: 0, peer_read_seq: 0, writable: true),
        ]
        let s = store(b)
        s.snapshot(unread: 5)
        XCTAssertEqual(s.totalUnread, 5, "the snapshot's count until the list is loaded")
        await s.refresh()
        XCTAssertEqual(s.totalUnread, 3)
        s.receive(["type": "chat_message", "message": Self.wire(Self.message(4, from: Self.fahd))])
        XCTAssertEqual(s.unread(.group), 3)
        s.receive(["type": "chat_message", "message": Self.wire(Self.message(4, from: Self.fahd))])
        XCTAssertEqual(s.unread(.group), 3, "the same message twice counts once")
        b.page = ChatPage(with: "group", messages: [Self.message(2, from: Self.fahd), Self.message(4, from: Self.fahd)], has_more: false, my_read_seq: 0, reads: [], writable: true, read_only_reason: nil)
        s.open(.group)
        await settle()
        XCTAssertEqual(s.unread(.group), 0)
        XCTAssertEqual(s.totalUnread, 1, "the direct chat is still unread")
        XCTAssertEqual(frames.last { $0["type"] as? String == "chat_read" }?["seq"] as? Int, 4, "✓✓ for the others")
        /* While it is on screen, a new one is read at once — no badge, no toast. */
        var toasts = 0
        s.onIncoming = { _ in toasts += 1 }
        s.receive(["type": "chat_message", "message": Self.wire(Self.message(5, from: Self.fahd))])
        XCTAssertEqual(s.unread(.group), 0)
        XCTAssertEqual(toasts, 0)
        s.close(.group)
        s.receive(["type": "chat_message", "message": Self.wire(Self.message(6, from: Self.saad, to: Self.me))])
        XCTAssertEqual(s.unread(.direct(Self.saad)), 2)
        XCTAssertEqual(toasts, 1)
    }

    func testReadReceiptsAndTypingFromTheSocket() {
        let s = store(FakeBackend())
        s.receive(["type": "chat_message", "message": Self.wire(Self.message(9, from: Self.me, to: Self.fahd))])
        s.receive(["type": "chat_read", "conv": "direct", "user_id": Self.fahd, "peer_id": Self.me, "seq": 9])
        XCTAssertEqual(s.threads[.direct(Self.fahd)]?.reads[Self.fahd], 9)
        let m = s.threads[.direct(Self.fahd)]!.messages.last!
        XCTAssertEqual(ChatRules.receipt(m, me: Self.me, reads: s.threads[.direct(Self.fahd)]!.reads, others: 1), .read)
        s.receive(["type": "chat_typing", "conv": "group", "user_id": Self.saad, "on": true])
        XCTAssertEqual(s.typing[.group], Self.saad)
        later.forEach { $0() }
        XCTAssertNil(s.typing[.group], "«يكتب…» fades")
    }

    func testDeletionMarkerAndWhoMayDelete() async {
        let b = FakeBackend()
        b.overview.can_moderate = true
        let s = store(b)
        await s.refresh()
        let theirs = Self.message(1, from: Self.fahd)
        XCTAssertTrue(s.canDelete(theirs), "the leader moderates the group")
        XCTAssertFalse(s.canDelete(Self.message(2, from: Self.fahd, to: Self.me)), "never someone else's DM")
        s.receive(["type": "chat_message", "message": Self.wire(theirs)])
        await s.delete(theirs)
        XCTAssertEqual(s.threads[.group]?.messages.first?.deleted, true)
        XCTAssertEqual(ChatPreview.line(s.threads[.group]!.messages.first!), "حذفها أمير الرحلة")
        let plain = store(FakeBackend())
        XCTAssertFalse(plain.canDelete(theirs))
        XCTAssertTrue(plain.canDelete(Self.message(3, from: Self.me)))
    }

    func testOlderServerHidesTheChatQuietly() async {
        let b = FakeBackend()
        b.overviewError = OutingAPIError(code: "http_404", status: 404)
        let s = store(b)
        s.snapshot(unread: nil)
        await s.refresh()
        XCTAssertEqual(s.availability, .notDeployed)
        XCTAssertEqual(s.totalUnread, 0, "no badge")
        _ = s.sendText("هلا", to: .group)
        XCTAssertTrue(frames.isEmpty && b.sent.isEmpty, "nothing is sent")
        XCTAssertNil(s.lastError, "no error shown")
        /* A removed member's 404 is a real answer, not an old server. */
        let r = FakeBackend()
        r.overviewError = OutingAPIError(code: "not_a_member", status: 404)
        let s2 = store(r)
        await s2.refresh()
        XCTAssertNotEqual(s2.availability, .notDeployed)
        /* The server gets updated: the next refresh turns it on. */
        b.overviewError = nil
        await s.refresh()
        XCTAssertTrue(s.isAvailable)
    }

    func testAccountDeletionWipesEveryOutbox() {
        ChatOutbox(defaults: defaults, outingId: "a").save([ChatDraft(client_id: "x", with: .group, kind: .text, text: "هلا", point: nil, created_at: "")])
        ChatOutbox(defaults: defaults, outingId: "b").save([ChatDraft(client_id: "y", with: .group, kind: .text, text: "هلا", point: nil, created_at: "")])
        ChatOutbox.wipeAll(defaults)
        XCTAssertTrue(ChatOutbox(defaults: defaults, outingId: "a").load().isEmpty)
        XCTAssertTrue(ChatOutbox(defaults: defaults, outingId: "b").load().isEmpty)
    }

    func testLargeMessagesGoOverHTTP() async {
        let b = FakeBackend()
        let s = store(b)
        _ = s.sendText(String(repeating: "🚙", count: 1000), to: .group) // 4 000 bytes of UTF-8: over the socket's frame cap
        await settle()
        XCTAssertFalse(frames.contains { $0["type"] as? String == "chat_message" })
        XCTAssertEqual(b.sent.count, 1)
    }

    // MARK: demo stub (what the UI tests talk to)

    func testDemoBackendAnswersAndReads() async throws {
        let demo = DemoChatBackend(outingId: "o1", me: Self.me, friends: [Self.fahd: "أبو فهد", Self.saad: "سلطان"])
        var emitted: [[String: Any]] = []
        demo.emit = { emitted.append($0) }
        let o = try await demo.chatOverview("o1")
        XCTAssertEqual(o.conversations.first?.with, "group")
        XCTAssertGreaterThan(o.unread_total, 0)
        let m = try await demo.chatSend("o1", draft: ChatDraft(client_id: "z1", with: .group, kind: .quick, text: "وصلت", point: nil, created_at: ""))
        let again = try await demo.chatSend("o1", draft: ChatDraft(client_id: "z1", with: .group, kind: .quick, text: "وصلت", point: nil, created_at: ""))
        XCTAssertEqual(m.id, again.id, "idempotent like the server")
        try await Task.sleep(nanoseconds: 2_800_000_000)
        XCTAssertTrue(emitted.contains { $0["type"] as? String == "chat_read" })
        XCTAssertTrue(emitted.contains { $0["type"] as? String == "chat_message" })
    }
}

// MARK: - the live channel hands chat frames to the chat

final class LiveChannelChatTests: XCTestCase {
    func testChatFramesAreRoutedAndSent() {
        var sockets: [FakeSocket] = []
        let clock = FakeScheduler()
        var chat: [[String: Any]] = []
        var events = 0
        let ch = LiveChannel(outingId: "o1", token: String(repeating: "t", count: 43), deps: .init(
            makeSocket: { url in let s = FakeSocket(url: url); sockets.append(s); return s },
            poll: { _ in throw OutingAPIError(code: "network", status: 0) },
            post: { _, _ in },
            beat: { _, _, _ in },
            scheduler: clock
        ))
        ch.handlers = .init(onEvent: { _ in events += 1 }, onChat: { chat.append($0) })
        XCTAssertFalse(ch.sendChat(["type": "chat_message"]), "not live yet: nothing is queued on the socket")
        ch.start()
        sockets[0].onOpen()
        sockets[0].serverSays(["type": "ready", "snapshot": LiveChannelTests.snapshotJSON])
        sockets[0].serverSays(["type": "chat_message", "message": ["id": "m1"]])
        sockets[0].serverSays(["type": "chat_read", "user_id": "u2", "seq": 3])
        XCTAssertEqual(chat.map { $0["type"] as? String }, ["chat_message", "chat_read"])
        XCTAssertEqual(events, 0, "chat frames never reach the map's reducer")
        XCTAssertTrue(ch.sendChat(["type": "chat_typing", "with": "group", "on": true]))
        XCTAssertEqual(sockets[0].sent.last?["type"] as? String, "chat_typing")
        XCTAssertFalse(ch.sendChat(["type": "position"]), "only chat frames through this door")
    }
}

private extension ChatRules.DraftCheck {
    var isOK: Bool { if case .ok = self { return true } else { return false } }
}

private extension ChatMessage {
    func deletedBy(_ r: String) -> ChatMessage {
        var c = self
        c.deleted = true
        c.deleted_by = r
        return c
    }

    // MARK: «بلّغ» و«احظر» (App Store 1.2)

    final class ModBackend: ChatBackend, ChatModerationBackend {
        let inner = FakeBackend()
        var reports: [(String, ChatReportReason, Bool)] = []
        var blocked: [String] = []
        func chatOverview(_ o: String) async throws -> ChatOverview { try await inner.chatOverview(o) }
        func chatPage(_ o: String, with: ChatWith, before: Int?, after: Int?, limit: Int) async throws -> ChatPage { try await inner.chatPage(o, with: with, before: before, after: after, limit: limit) }
        func chatSend(_ o: String, draft: ChatDraft) async throws -> ChatMessage { try await inner.chatSend(o, draft: draft) }
        func chatRead(_ o: String, with: ChatWith, seq: Int) async throws {}
        func chatDelete(_ o: String, messageId: String) async throws -> ChatMessage { try await inner.chatDelete(o, messageId: messageId) }
        func chatReport(_ o: String, messageId: String, reason: ChatReportReason, block: Bool) async throws { reports.append((messageId, reason, block)) }
        func blockUser(_ userId: String) async throws { blocked.append(userId) }
        func unblockUser(_ userId: String) async throws { blocked.removeAll { $0 == userId } }
        func listBlocks() async throws -> [BlockedUser] { blocked.map { BlockedUser(user_id: $0) } }
    }

    func testReportAndBlockHideTheSendersMessagesAndLaterOnes() async {
        let b = ModBackend()
        let s = ChatStore(outingId: "o1", me: Self.me, backend: b, defaults: defaults)
        s.receive(["type": "chat_message", "message": Self.wire(Self.message(4, from: Self.fahd))])
        s.receive(["type": "chat_message", "message": Self.wire(Self.message(5, from: Self.saad))])
        let m = s.threads[.group]!.messages.first { $0.sender_id == Self.fahd }!
        XCTAssertTrue(s.canReport(m))
        XCTAssertFalse(s.canReport(Self.message(9, from: Self.me)), "not my own")
        let ok = await s.report(m, reason: .harassment)
        XCTAssertTrue(ok)
        XCTAssertEqual(b.reports.first?.1, .harassment)
        XCTAssertNotNil(s.notice)

        let blocked = await s.block(Self.fahd, name: "فهد")
        XCTAssertTrue(blocked)
        XCTAssertEqual(b.blocked, [Self.fahd])
        XCTAssertFalse(s.threads[.group]!.messages.contains { $0.sender_id == Self.fahd }, "gone at once")
        XCTAssertTrue(s.threads[.group]!.messages.contains { $0.sender_id == Self.saad }, "the others stay")
        XCTAssertTrue(BlockedUsers.storedIds(defaults).contains(Self.fahd))
        /* a late frame from him (old server) is still hidden */
        s.receive(["type": "chat_message", "message": Self.wire(Self.message(6, from: Self.fahd))])
        XCTAssertFalse(s.threads[.group]!.messages.contains { $0.sender_id == Self.fahd })
        BlockedUsers.remove(Self.fahd, defaults: defaults)
        XCTAssertTrue(BlockedUsers.load(defaults).isEmpty)
    }

    func testABackendWithoutModerationOffersNoReport() {
        let s = store(FakeBackend())
        XCTAssertFalse(s.canReport(Self.message(4, from: Self.fahd)))
    }

    func testReportReasonsMatchTheServer() {
        XCTAssertEqual(ChatReportReason.allCases.map(\.rawValue), ["abuse", "harassment", "spam", "sexual", "violence", "other"])
    }
}
