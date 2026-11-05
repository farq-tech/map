import Combine
import Foundation

/// «المحادثات» on the live screen: the entry points (Group tab, «+»), what the chat
/// screens need from the trip, and a toast for a message while the chat is closed.
extension LiveOutingController {
    var chat: ChatStore { session.chat }

    func openChat(_ w: ChatWith? = nil) {
        modal = .chat(w)
    }

    /// Moving > 15 km/h with the driving screen's hysteresis (MotionHysteresis): no keyboard.
    var chatMoving: Bool { motion.moving || debugChatMoving }

    var chatContext: ChatContext {
        let v = session.displayView
        let rally = v?.snapshot.outing.rally.map { ChatPoint(lat: $0.lat, lng: $0.lng, label: $0.label ?? "نقطة التجمع") }
        return ChatContext(
            me: session.myUserId,
            members: v.map { Array($0.members.values).sorted { $0.joined_at < $1.joined_at } } ?? [],
            colors: v?.colors ?? [:],
            outingName: v?.snapshot.outing.name ?? "",
            ended: v?.status == .ended,
            moving: chatMoving,
            myLocation: { [weak self] in
                guard let f = self?.location.lastFix else { return nil }
                return ChatPoint(lat: f.lat, lng: f.lng, label: nil)
            },
            rally: rally,
            showOnMap: { [weak self] p in
                self?.modal = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self?.lowerSheetThenAsk(.point(LngLat(lng: p.lng, lat: p.lat))) }
            },
            openPTT: { [weak self] in
                self?.modal = nil
                self?.toast("اضغط زر قناة الطلعة على الخريطة وتكلّم")
            }
        )
    }

    /// Someone wrote while the chat is closed: one short toast (never while it is open).
    /// Also: a tapped chat notification opens its conversation (now, or when this trip opens).
    func wireChatToasts() {
        let open: () -> Void = { [weak self] in
            guard let self, self.chat.availability != .notDeployed, let w = ChatDeepLink.take(outingId: self.session.id) else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.openChat(w) }
        }
        open()
        NotificationCenter.default.publisher(for: ChatDeepLink.name).receive(on: DispatchQueue.main)
            .sink { _ in open() }.store(in: &bag)
        chat.onIncoming = { [weak self] m in
            guard let self else { return }
            if case .chat = self.modal { return }
            let who = self.session.displayView?.members[m.sender_id]?.display_name ?? m.sender_name ?? "رسالة جديدة"
            let line = ChatPreview.line(m)
            self.toast(m.conv == "group" ? "💬 \(who): \(line)" : "💬 \(who) (خاص): \(line)")
        }
    }
}

/// A tapped chat notification → that conversation, once its trip is on screen.
@MainActor
enum ChatDeepLink {
    static let name = Notification.Name("sary.openChat")
    private static var pending: (outingId: String, with: ChatWith)?

    static func request(outingId: String, with: ChatWith) {
        pending = (outingId, with)
        NotificationCenter.default.post(name: name, object: nil)
    }

    static func take(outingId: String) -> ChatWith? {
        guard let p = pending, p.outingId == outingId else { return nil }
        pending = nil
        return p.with
    }
}
