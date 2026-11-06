import SwiftUI

/// What the chat screens need from the live outing, without the controller itself.
struct ChatContext {
    var me: String
    /// Active members (the trip's name for each, their car colour).
    var members: [Member]
    var colors: [String: UInt32]
    var outingName: String
    var ended: Bool
    /// Moving > 15 km/h (the driving screen's hysteresis): no keyboard.
    var moving: Bool
    var myLocation: () -> ChatPoint?
    /// The meeting point, if one is set (shareable as a map point).
    var rally: ChatPoint?
    var showOnMap: (ChatPoint) -> Void
    /// Back to the map, where the walkie-talkie button is.
    var openPTT: () -> Void

    func name(_ uid: String, fallback: String? = nil) -> String {
        members.first { $0.user_id == uid }?.display_name ?? fallback ?? "عضو سابق"
    }

    func color(_ uid: String) -> UInt32 { colors[uid] ?? 0x9AA5AD }
}

// MARK: - Entry in the Group tab

/// «المحادثات» with the unread count — first thing in the Group tab.
struct ChatEntryRow: View {
    @ObservedObject var chat: ChatStore
    var open: () -> Void
    @Environment(\.sary) private var theme

    var body: some View {
        switch chat.availability {
        case .available: entry
        case .notDeployed: soon
        case .unknown: EmptyView()
        }
    }

    /// The server is not updated yet: a calm line, no button, no error.
    private var soon: some View {
        let p = theme.palette
        return HStack(spacing: theme.space(.m)) {
            SaryRowIcon(systemImage: "bubble.left.and.bubble.right", color: nil)
            VStack(alignment: .leading, spacing: 2) {
                Text("المحادثات").saryText(.body, weight: .bold).foregroundStyle(p.textSecondary)
                Text("قريبًا — تشتغل تلقائيًا أول ما يتحدّث الخادم.").saryText(.footnote).foregroundStyle(p.textTertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(theme.space(.m))
        .sarySurface(radius: SaryRadius.l)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("chat.soon")
    }

    private var entry: some View {
        let p = theme.palette
        let n = chat.totalUnread
        return Button(action: open) {
            HStack(spacing: theme.space(.m)) {
                SaryRowIcon(systemImage: "bubble.left.and.bubble.right.fill", color: p.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("المحادثات").saryText(.body, weight: .bold).foregroundStyle(p.textPrimary)
                    Text(preview).saryText(.footnote).foregroundStyle(p.textSecondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if n > 0 { ChatBadge(count: n) }
                Image(systemName: "chevron.backward").font(.system(size: 13, weight: .semibold)).foregroundStyle(p.textTertiary)
                    .flipsForRightToLeftLayoutDirection(true)
            }
            .padding(theme.space(.m))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sarySurface(radius: SaryRadius.l)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(n > 0 ? "المحادثات، \(SaryFormat.digits(String(n))) غير مقروءة" : "المحادثات")
        .accessibilityIdentifier("chat.entry")
    }

    private var preview: String {
        guard let m = chat.threads[.group]?.latest else { return "دردشة الطلعة والرسائل الخاصة" }
        return ChatPreview.line(m)
    }
}

struct ChatBadge: View {
    var count: Int
    @Environment(\.sary) private var theme
    var body: some View {
        Text(count > 99 ? "+٩٩" : SaryFormat.digits(String(count)))
            .saryNumber(.caption, weight: .bold)
            .foregroundStyle(theme.palette.onEmergency)
            .padding(.horizontal, 6)
            .frame(minWidth: 20, minHeight: 20)
            .background(Capsule().fill(theme.palette.emergency))
            .accessibilityIdentifier("chat.badge")
    }
}

enum ChatPreview {
    static func line(_ m: ChatMessage) -> String {
        if m.deleted { return ChatRules.deletedLabel(m) }
        switch m.kind {
        case .location: return "📍 " + (m.point?.label ?? "موقع على الخريطة")
        case .quick, .text: return m.text ?? ""
        }
    }
}

// MARK: - Conversation list

/// «المحادثات»: the group first, then every member (last message, unread).
struct ChatHomeView: View {
    @ObservedObject var chat: ChatStore
    var context: ChatContext
    var close: () -> Void
    @State var path: [ChatWith] = []
    @Environment(\.sary) private var theme

    var body: some View {
        NavigationStack(path: $path) {
            list
                .navigationDestination(for: ChatWith.self) { w in
                    ChatThreadView(chat: chat, with: w, context: context, back: { path.removeLast() }, close: close)
                }
        }
        .task { await chat.refresh() }
    }

    private var others: [Member] { context.members.filter { $0.user_id != context.me } }

    /// People I talked to who are no longer in the trip (their history stays, read-only).
    private var former: [ChatWith] {
        chat.directThreads.filter { w in !others.contains { $0.user_id == w.peer } }
    }

    private var list: some View {
        let p = theme.palette
        return SaryPage(title: "المحادثات", subtitle: context.outingName, close: close) {
            if context.ended {
                SaryInlineMessage(text: retentionText, tone: .info).accessibilityIdentifier("chat.retention")
            }
            VStack(spacing: 0) {
                row(.group, title: "دردشة الطلعة", color: nil, subtitle: chat.threads[.group]?.latest.map(ChatPreview.line) ?? "لكل أعضاء الطلعة")
            }
            .sarySurface(radius: SaryRadius.l)
            if !others.isEmpty || !former.isEmpty {
                VStack(alignment: .leading, spacing: theme.space(.s)) {
                    Text("رسائل خاصة").saryText(.footnote, weight: .bold).foregroundStyle(p.textSecondary).accessibilityAddTraits(.isHeader)
                    VStack(spacing: 0) {
                        let sorted = others.sorted { (chat.threads[.direct($0.user_id)]?.latest?.seq ?? 0) > (chat.threads[.direct($1.user_id)]?.latest?.seq ?? 0) }
                        ForEach(sorted, id: \.user_id) { m in
                            row(.direct(m.user_id), title: m.display_name, color: context.color(m.user_id),
                                subtitle: chat.threads[.direct(m.user_id)]?.latest.map(ChatPreview.line) ?? "ابدأ محادثة")
                            SaryDivider().padding(.leading, 60)
                        }
                        ForEach(former, id: \.self) { w in
                            row(w, title: context.name(w.peer ?? "", fallback: chat.threads[w]?.latest?.sender_name), color: nil,
                                subtitle: "للقراءة فقط · " + (chat.threads[w]?.latest.map(ChatPreview.line) ?? ""))
                        }
                    }
                    .sarySurface(radius: SaryRadius.l)
                }
            }
            if !context.ended {
                Text("تُحذف المحادثات تلقائيًا بعد \(SaryFormat.digits(String(chat.retentionDays))) يومًا من نهاية الطلعة.")
                    .saryText(.footnote).foregroundStyle(p.textTertiary)
            }
        }
        .accessibilityIdentifier("chat.home")
    }

    private var retentionText: String {
        if let d = ISODate.parse(chat.purgeAt) {
            let f = DateFormatter()
            f.locale = Locale(identifier: "ar")
            f.dateStyle = .medium
            return "انتهت الطلعة — المحادثات للقراءة فقط، وتُحذف تلقائيًا في \(f.string(from: d))."
        }
        return "انتهت الطلعة — المحادثات للقراءة فقط، وتُحذف تلقائيًا بعد ٣٠ يومًا من نهايتها."
    }

    private func row(_ w: ChatWith, title: String, color: UInt32?, subtitle: String) -> some View {
        let p = theme.palette
        let n = chat.unread(w)
        return Button { path.append(w) } label: {
            HStack(spacing: theme.space(.m)) {
                if let color {
                    SaryAvatar(name: title, color: color, size: 40)
                } else {
                    SaryRowIcon(systemImage: w.isGroup ? "person.3.fill" : "person.fill", color: w.isGroup ? p.accent : nil)
                        .frame(width: 40, height: 40)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).saryText(.body, weight: n > 0 ? .bold : .medium).foregroundStyle(p.textPrimary).lineLimit(1)
                    Text(subtitle).saryText(.footnote).foregroundStyle(p.textSecondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if n > 0 { ChatBadge(count: n) }
            }
            .padding(.horizontal, theme.space(.m))
            .padding(.vertical, theme.space(.s))
            .frame(minHeight: theme.minTarget + 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(w.isGroup ? "chat.row.group" : "chat.row.direct")
    }
}

// MARK: - One conversation

struct ChatThreadView: View {
    @ObservedObject var chat: ChatStore
    var with: ChatWith
    var context: ChatContext
    var back: () -> Void
    var close: () -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool
    @Environment(\.sary) private var theme
    /// «بلّغ عن الرسالة»: the message whose reason is being chosen.
    @State private var reportTarget: ChatMessage?
    /// «احظر فلان»: the message whose sender is about to be blocked.
    @State private var blockTarget: ChatMessage?

    private var thread: ChatThreadState { chat.threads[with] ?? ChatThreadState() }
    private var writable: Bool { chat.writable && thread.writable && !context.ended }
    private var others: Int {
        with.isGroup ? max(0, context.members.filter { $0.user_id != context.me }.count) : 1
    }
    private var title: String { with.isGroup ? "دردشة الطلعة" : context.name(with.peer ?? "", fallback: thread.latest?.sender_name) }

    var body: some View {
        threadBody
            .confirmationDialog("ليش تبلّغ عن الرسالة؟", isPresented: Binding(get: { reportTarget != nil }, set: { if !$0 { reportTarget = nil } }),
                                titleVisibility: .visible, presenting: reportTarget) { m in
                ForEach(ChatReportReason.allCases) { r in
                    Button(r.label) { Task { await chat.report(m, reason: r) } }
                        .accessibilityIdentifier("chat.report.\(r.rawValue)")
                }
                Button("بلّغ واحظر \(senderName(m))", role: .destructive) { Task { await chat.report(m, reason: .abuse, block: true) } }
                    .accessibilityIdentifier("chat.report.block")
                Button("إلغاء", role: .cancel) {}
            } message: { _ in
                Text("يوصل البلاغ لفريق سَرى البارق ونراجعه خلال ٢٤ ساعة. ما يدري المرسل مين بلّغ.")
            }
            .alert(blockTarget.map { "تحظر \(senderName($0))؟" } ?? "", isPresented: Binding(get: { blockTarget != nil }, set: { if !$0 { blockTarget = nil } }),
                   presenting: blockTarget) { m in
                Button("احظر", role: .destructive) { Task { await chat.block(m.sender_id, name: senderName(m)) } }
                    .accessibilityIdentifier("chat.block.confirm")
                Button("إلغاء", role: .cancel) {}
            } message: { _ in
                Text("تختفي رسائله ورسائله الصوتية عندك، وما يقدر يراسلك على الخاص. الطوارئ منه توصلك دايم. تقدر تلغي الحظر من الإعدادات ← المحظورين.")
            }
    }

    private func senderName(_ m: ChatMessage) -> String { context.name(m.sender_id, fallback: m.sender_name) }

    /// A context-menu action and a dialog cannot present in the same runloop turn (the menu is still
    /// dismissing): set the state on the next turn so «بلّغ» / «احظر» reliably open.
    private func present(_ set: @escaping () -> Void) {
        DispatchQueue.main.async(execute: set)
    }

    private var threadBody: some View {
        let p = theme.palette
        return VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: theme.space(.s)) {
                        if thread.hasMore {
                            Button("رسائل أقدم") { Task { await chat.loadOlder(with) } }
                                .buttonStyle(.sary(.secondary))
                                .accessibilityIdentifier("chat.older")
                        }
                        if thread.loaded && thread.messages.isEmpty {
                            Text(with.isGroup ? "ما فيه رسائل بعد. قل هلا 👋" : "ابدأ المحادثة مع \(title).")
                                .saryText(.subhead).foregroundStyle(p.textSecondary).padding(.top, theme.space(.xl))
                        }
                        ForEach(thread.messages, id: \.key) { m in
                            bubble(m).id(m.key)
                        }
                        if let t = chat.typing[with] {
                            Text("\(context.name(t)) يكتب…").saryText(.footnote).foregroundStyle(p.textTertiary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityIdentifier("chat.typing")
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, theme.space(.l))
                    .padding(.vertical, theme.space(.s))
                }
                .scrollDismissesKeyboard(.interactively)
                .defaultScrollAnchor(.bottom)
                .onChange(of: thread.messages.count) { _, _ in
                    withAnimation(theme.animation(.snappy)) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onChange(of: focused) { _, f in
                    if f { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { proxy.scrollTo("bottom", anchor: .bottom) } }
                }
                .accessibilityIdentifier("chat.messages")
            }
            composer
        }
        .background(p.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { chat.open(with) }
        .onDisappear { chat.close(with) }
        .onChange(of: context.moving) { _, moving in if moving { focused = false } }
        .accessibilityIdentifier("chat.thread")
    }

    private var header: some View {
        let p = theme.palette
        return HStack(spacing: theme.space(.s)) {
            SaryIconButton(systemImage: SaryIcon.back, label: "رجوع", id: "chat.back", action: back)
            if let peer = with.peer {
                SaryAvatar(name: title, color: context.color(peer), size: 32)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(title).saryText(.headline, weight: .bold).foregroundStyle(p.textPrimary).lineLimit(1)
                Text(with.isGroup ? "\(SaryFormat.digits(String(context.members.count))) أعضاء" : "رسالة خاصة")
                    .saryText(.caption).foregroundStyle(p.textSecondary)
            }
            Spacer(minLength: 0)
            SaryIconButton(systemImage: SaryIcon.close, label: "إغلاق", id: "chat.close", action: close)
        }
        .padding(.horizontal, theme.space(.l))
        .padding(.vertical, theme.space(.s))
        .saryGlass(Rectangle(), role: .chrome)
    }

    // MARK: bubbles

    @ViewBuilder
    private func bubble(_ m: ChatMessage) -> some View {
        let p = theme.palette
        let mine = m.sender_id == context.me
        let rgb = context.color(m.sender_id)
        let tint = Color(rgb: rgb)
        HStack {
            if mine { Spacer(minLength: 48) }
            VStack(alignment: .leading, spacing: 3) {
                if !mine && with.isGroup {
                    Text(context.name(m.sender_id, fallback: m.sender_name))
                        .saryText(.caption, weight: .bold)
                        .foregroundStyle(nameInk(rgb))
                }
                content(m)
                HStack(spacing: 4) {
                    Text(time(m.created_at)).saryNumber(.micro).foregroundStyle(p.textTertiary)
                    if let r = ChatRules.receipt(m, me: context.me, reads: thread.reads, others: others) { receipt(r) }
                }
            }
            .padding(.horizontal, theme.space(.m))
            .padding(.vertical, theme.space(.s))
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(mine ? tint.opacity(theme.isLight ? 0.28 : 0.34) : p.surface)
            )
            .overlay(alignment: .leading) {
                if !mine {
                    RoundedRectangle(cornerRadius: 2).fill(tint).frame(width: 4).padding(.vertical, 8)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(mine ? tint.opacity(0.7) : p.separator, lineWidth: 1))
            .contextMenu { menu(m) }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibility(m))
            .accessibilityIdentifier(mine ? "chat.bubble.mine" : "chat.bubble")
            if !mine { Spacer(minLength: 48) }
        }
    }

    /// Readable on the surface: very light car colours (white, silver) fall back to the secondary ink.
    private func nameInk(_ rgb: UInt32) -> Color {
        let p = theme.palette
        if rgb == 0xE8EEF0 || rgb == 0x9AA5AD { return p.textSecondary }
        if rgb == 0x15191C { return p.textPrimary }
        return Color(rgb: rgb)
    }

    @ViewBuilder
    private func content(_ m: ChatMessage) -> some View {
        let p = theme.palette
        if m.deleted {
            Label(ChatRules.deletedLabel(m), systemImage: "trash").saryText(.subhead).italic().foregroundStyle(p.textTertiary)
                .accessibilityIdentifier("chat.deleted")
        } else if m.kind == .location, let pt = m.point {
            Button {
                context.showOnMap(pt)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "mappin.circle.fill").font(.system(size: 22)).foregroundStyle(p.accent)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(pt.label ?? "موقع على الخريطة").saryText(.body, weight: .bold).foregroundStyle(p.textPrimary)
                        Text("اضغط لتراه على الخريطة").saryText(.caption).foregroundStyle(p.textSecondary)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("chat.point")
        } else {
            Text(m.text ?? "")
                .saryText(m.kind == .quick ? .bodyStrong : .body)
                .foregroundStyle(p.textPrimary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func receipt(_ r: ChatRules.Receipt) -> some View {
        let p = theme.palette
        switch r {
        case .sending: Image(systemName: "clock").font(.system(size: 10)).foregroundStyle(p.textTertiary).accessibilityIdentifier("chat.receipt.sending")
        case .retrying: Image(systemName: "arrow.clockwise").font(.system(size: 10)).foregroundStyle(p.warningText).accessibilityIdentifier("chat.receipt.retrying")
        case .failed: Image(systemName: "exclamationmark.circle.fill").font(.system(size: 11)).foregroundStyle(p.emergency).accessibilityIdentifier("chat.receipt.failed")
        case .sent: Text("✓").saryText(.micro, weight: .bold).foregroundStyle(p.textTertiary).accessibilityIdentifier("chat.receipt.sent")
        case .read: Text("✓✓").saryText(.micro, weight: .bold).foregroundStyle(p.accentText).accessibilityIdentifier("chat.receipt.read")
        }
    }

    @ViewBuilder
    private func menu(_ m: ChatMessage) -> some View {
        if case .failed = m.delivery {
            Button { chat.retry(m) } label: { Label("أعد الإرسال", systemImage: "arrow.clockwise") }
            Button(role: .destructive) { chat.discard(m) } label: { Label("احذفها من جهازي", systemImage: "trash") }
        }
        if m.text != nil && !m.deleted {
            Button { UIPasteboard.general.string = m.text } label: { Label("نسخ", systemImage: "doc.on.doc") }
        }
        if chat.canReport(m) {
            Button { present { reportTarget = m } } label: { Label("بلّغ عن الرسالة", systemImage: "exclamationmark.bubble") }
                .accessibilityIdentifier("chat.menu.report")
            Button(role: .destructive) { present { blockTarget = m } } label: { Label("احظر \(senderName(m))", systemImage: "hand.raised.fill") }
                .accessibilityIdentifier("chat.menu.block")
        }
        if chat.canDelete(m) {
            Button(role: .destructive) { Task { await chat.delete(m) } } label: {
                Label(m.sender_id == context.me ? "احذف رسالتي" : "احذفها (أمير الرحلة)", systemImage: "trash")
            }
        }
    }

    private func accessibility(_ m: ChatMessage) -> String {
        let who = m.sender_id == context.me ? "أنت" : context.name(m.sender_id, fallback: m.sender_name)
        return "\(who): \(ChatPreview.line(m)) · \(time(m.created_at))"
    }

    private func time(_ iso: String) -> String {
        guard let d = ISODate.parse(iso) else { return "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "ar")
        f.dateFormat = "h:mm a"
        return f.string(from: d)
    }

    // MARK: composer

    @ViewBuilder
    private var composer: some View {
        let p = theme.palette
        VStack(spacing: theme.space(.s)) {
            if let e = chat.lastError {
                SaryInlineMessage(text: e, tone: .warning).accessibilityIdentifier("chat.error")
            }
            if let n = chat.notice {
                SaryInlineMessage(text: n, tone: .info).accessibilityIdentifier("chat.notice")
            }
            if !writable {
                SaryInlineMessage(text: ChatRules.errorText(thread.readOnlyReason ?? chat.readOnlyReason ?? "outing_ended"), tone: .info)
                    .accessibilityIdentifier("chat.readonly")
            } else {
                quickRow
                if ChatRules.canType(moving: context.moving) {
                    HStack(alignment: .bottom, spacing: theme.space(.s)) {
                        TextField("اكتب رسالة…", text: $draft, axis: .vertical)
                            .lineLimit(1...5)
                            .saryText(.body)
                            .foregroundStyle(p.textPrimary)
                            .focused($focused)
                            .padding(.horizontal, theme.space(.m))
                            .padding(.vertical, 10)
                            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(p.sunken))
                            .onChange(of: draft) { _, t in if !t.isEmpty { chat.sendTyping(with) } }
                            .submitLabel(.send)
                            .accessibilityIdentifier("chat.input")
                        let over = draft.unicodeScalars.count > ChatRules.textMax
                        Button {
                            if chat.sendText(draft, to: with) { draft = "" }
                        } label: {
                            Image(systemName: "arrow.up.circle.fill").font(.system(size: 34)).foregroundStyle(over || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? p.textTertiary : p.accent)
                        }
                        .disabled(over || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityLabel("أرسل")
                        .accessibilityIdentifier("chat.send")
                    }
                    if draft.unicodeScalars.count > ChatRules.textMax - 100 {
                        Text("\(SaryFormat.digits(String(draft.unicodeScalars.count))) / ١٠٠٠")
                            .saryNumber(.caption).foregroundStyle(draft.unicodeScalars.count > ChatRules.textMax ? p.emergencyText : p.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                } else {
                    drivingBlock
                }
            }
        }
        .padding(.horizontal, theme.space(.l))
        .padding(.top, theme.space(.s))
        .padding(.bottom, theme.space(.s))
        .saryGlass(Rectangle(), role: .chrome)
    }

    /// «وقّف عشان تكتب»: no keyboard at speed — quick replies, location and the walkie-talkie stay.
    private var drivingBlock: some View {
        let p = theme.palette
        return HStack(spacing: theme.space(.m)) {
            Image(systemName: "car.fill").font(.system(size: 20, weight: .semibold)).foregroundStyle(p.warningText)
            VStack(alignment: .leading, spacing: 2) {
                Text("وقّف عشان تكتب").saryText(.body, weight: .bold).foregroundStyle(p.textPrimary)
                Text("وأنت تسوق: ردّ سريع أو موقعك، أو تكلّم بقناة الطلعة.").saryText(.footnote).foregroundStyle(p.textSecondary)
            }
            Spacer(minLength: 0)
            Button(action: context.openPTT) { SaryButtonLabel(title: "تكلّم", systemImage: "mic.fill") }
                .buttonStyle(.sary(.secondary))
                .fixedSize()
                .accessibilityIdentifier("chat.ptt")
        }
        .padding(theme.space(.m))
        .background(RoundedRectangle(cornerRadius: SaryRadius.m, style: .continuous).fill(p.sunken))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.drivingBlock")
    }

    private var quickRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: theme.space(.s)) {
                chip("📍 موقعي", id: "chat.shareLocation") {
                    if let pt = context.myLocation() { chat.sendPoint(pt, to: with) } else { chat.lastError = "ما عندنا موقعك الآن. فعّل الموقع وجرّب ثانية." }
                }
                if let r = context.rally {
                    chip("🚩 نقطة التجمع", id: "chat.shareRally") { chat.sendPoint(r, to: with) }
                }
                ForEach(chat.quickReplies, id: \.self) { q in
                    chip(q, id: "chat.quick") { chat.sendQuick(q, to: with) }
                }
            }
            .padding(.vertical, 2)
        }
        .accessibilityIdentifier("chat.quickReplies")
    }

    private func chip(_ title: String, id: String, action: @escaping () -> Void) -> some View {
        let p = theme.palette
        return Button(action: action) {
            Text(title).saryText(.subhead, weight: .medium).foregroundStyle(p.textPrimary)
                .padding(.horizontal, theme.space(.m))
                .frame(minHeight: max(theme.minTarget - 8, 36))
                .saryGlass(Capsule(), role: .control, interactive: true)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }
}
