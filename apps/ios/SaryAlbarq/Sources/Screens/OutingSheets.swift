import SwiftUI
import UIKit

// MARK: - New outing

struct CreateOutingSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.sary) private var theme
    @State private var name = ""
    @State private var busy = false
    @State private var error: String?

    private let ideas = ["كشتة الثمامة", "طلعة نفود", "مشوار العارض", "شواء الخميس"]

    var body: some View {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        SaryPage(title: "طلعة جديدة", close: { dismiss() }) {
            SaryTextField(title: "اسم الطلعة", placeholder: "مثل: كشتة الثمامة", text: $name, id: "create.name", maxLength: ServerRules.outingNameMax,
                          disabled: busy)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: theme.space(.s)) {
                    ForEach(ideas, id: \.self) { i in
                        Button(i) { name = i }
                            .buttonStyle(.sary(.secondary, width: .hug, compact: true))
                    }
                }
            }
            if let error { SaryInlineMessage(text: error, tone: .error) }
            if !model.online { SaryOfflineStrip(text: "بلا إنترنت — تقدر تنشئ الطلعة أول ما يرجع الاتصال.") }
            Button {
                busy = true
                error = nil
                Task {
                    if await model.createOuting(name: trimmed) != nil { dismiss() } else {
                        error = model.errorText ?? "تعذّر إنشاء الطلعة."
                        model.errorText = nil
                    }
                    busy = false
                }
            } label: { SaryButtonLabel(title: "أنشئ الطلعة", busy: busy, busyTitle: "ننشئها…") }
                .buttonStyle(.sary(.primary))
                .disabled(trimmed.isEmpty || busy || !model.online)
                .accessibilityIdentifier("create.submit")
            SarySection(title: "بعد الإنشاء") {
                VStack(alignment: .leading, spacing: theme.space(.s)) {
                    step("1", "تفتح الخريطة، وتشارك رابط الدعوة أو رمز QR مع أصحابك.")
                    step("2", "تبدأ الطلعة متى ما تحركتم، وتقدر توقفها مؤقتًا أو تنهيها للجميع.")
                    step("3", "كل واحد يختار بنفسه متى يشارك موقعه.")
                }
                .padding(.vertical, theme.space(.s))
            }
        }
        .presentationDetents([.large])
    }

    private func step(_ n: String, _ t: String) -> some View {
        HStack(alignment: .top, spacing: theme.space(.s)) {
            Text(SaryFormat.digits(n)).saryNumber(.subhead, weight: .bold)
                .foregroundStyle(theme.palette.onAccent)
                .frame(width: 24, height: 24)
                .background(Circle().fill(theme.palette.accent))
            Text(t).saryText(.subhead).foregroundStyle(theme.palette.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Join by link (paste / scan)

struct JoinByLinkSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.sary) private var theme
    @State private var text = ""
    @State private var invalid = false
    @State private var scanning = false

    var body: some View {
        SaryPage(title: "انضم برابط", subtitle: "الصق رابط الدعوة أو امسح رمز QR", close: { dismiss() }) {
            SaryTextField(title: "رابط الدعوة", placeholder: "https://…/outings/join#…", text: $text, id: "paste.field",
                          state: invalid ? .error("هذا ليس رابط دعوة صحيحًا.") : .normal)
                .environment(\.layoutDirection, .leftToRight)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            HStack(spacing: theme.space(.s)) {
                Button {
                    text = UIPasteboard.general.string ?? UIPasteboard.general.url?.absoluteString ?? ""
                    invalid = false
                } label: { SaryButtonLabel(title: "الصق", systemImage: "doc.on.clipboard") }
                    .buttonStyle(.sary(.secondary))
                Button { scanning = true } label: { SaryButtonLabel(title: "امسح QR", systemImage: "qrcode.viewfinder") }
                    .buttonStyle(.sary(.secondary))
                    .accessibilityIdentifier("paste.scan")
            }
            Button { go(text) } label: { SaryButtonLabel(title: "متابعة") }
                .buttonStyle(.sary(.primary))
                .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityIdentifier("paste.continue")
            Text("الانضمام لا يشارك موقعك. تختار المشاركة بنفسك داخل الطلعة.")
                .saryText(.footnote).foregroundStyle(theme.palette.textTertiary)
        }
        .sheet(isPresented: $scanning) {
            QRScanSheet(title: "امسح رمز الدعوة", hint: "وجّه الكاميرا لرمز QR في جوال صاحب الطلعة.") { s in
                scanning = false
                text = s
                go(s)
            } cancel: { scanning = false }
            .rtl()
        }
    }

    private func go(_ s: String) {
        if let t = InviteLink.token(fromPasted: s) {
            dismiss()
            model.pendingInvite = t
        } else {
            invalid = true
        }
    }
}

// MARK: - Invite preview → join

/// The invite as the server sees it: valid (name, who invited, members, state),
/// expired / revoked, invalid, or a retryable error. Joining needs a name the first time.
struct InviteJoinSheet: View {
    let token: String
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.sary) private var theme
    @State private var phase: InvitePhaseUI = .loading
    @State private var name = ""
    @State private var busy = false
    @State private var error: String?
    var preset: InvitePhaseUI?

    var body: some View {
        let p = theme.palette
        SaryPage(title: "دعوة طلعة", close: close) {
            switch phase {
            case .loading:
                SaryStateView(kind: .loading("نقرأ الدعوة…"))
            case .ready(let inv):
                VStack(alignment: .leading, spacing: theme.space(.m)) {
                    HStack {
                        SaryOutingStatusPill(status: status(inv.status))
                        Spacer()
                    }
                    Text(inv.outingName).saryText(.display, weight: .bold).foregroundStyle(p.textPrimary)
                        .accessibilityIdentifier("invite.name")
                    Label {
                        Text("دعاك \(inv.inviterName)").saryText(.callout)
                    } icon: { Image(systemName: SaryIcon.crown) }
                        .foregroundStyle(p.textSecondary)
                    Label {
                        Text("\(SaryFormat.number(inv.participantCount)) في الطلعة الآن").saryText(.callout)
                    } icon: { Image(systemName: "person.2.fill") }
                        .foregroundStyle(p.textSecondary)
                }
                .padding(theme.space(.l))
                .frame(maxWidth: .infinity, alignment: .leading)
                .sarySurface(radius: SaryRadius.l)
                if inv.status == .ended {
                    SaryBanner(text: "انتهت هذه الطلعة، فلا يمكن الانضمام لها.", tone: .warning)
                } else {
                    if model.identity == nil {
                        SaryTextField(title: "اسمك", placeholder: "كما يراه أصحابك", text: $name, id: "invite.myName", maxLength: ServerRules.nameMax)
                    }
                    if let error { SaryInlineMessage(text: error, tone: .error) }
                    Button { join() } label: {
                        SaryButtonLabel(title: model.identity.map { "انضم باسم \($0.user.display_name)" } ?? "انضم للطلعة", busy: busy, busyTitle: "ننضم…")
                    }
                    .buttonStyle(.sary(.primary))
                    .disabled(busy || (model.identity == nil && name.trimmingCharacters(in: .whitespaces).isEmpty))
                    .accessibilityIdentifier("invite.join")
                    Text("الانضمام لا يشارك موقعك. تختار المشاركة بنفسك داخل الطلعة.")
                        .saryText(.footnote).foregroundStyle(p.textTertiary)
                }
                Button("ليس الآن", action: close).buttonStyle(.sary(.plain))
            case .expired:
                SaryStateView(kind: .error(title: "انتهت صلاحية الدعوة", message: "اطلب من صاحب الطلعة رابطًا جديدًا. الروابط تنتهي أو يلغيها صاحبها."),
                              actionTitle: "حسنًا", actionID: "invite.close", actionIcon: nil, action: close)
                    .accessibilityIdentifier("invite.expired")
            case .invalid:
                SaryStateView(kind: .error(title: "رابط غير صحيح", message: "تأكد أنك نسخت الرابط كاملًا، أو امسح رمز QR من جوال صاحب الطلعة."),
                              actionTitle: "حسنًا", actionID: "invite.close", actionIcon: nil, action: close)
                    .accessibilityIdentifier("invite.invalid")
            case .error(let m):
                SaryStateView(kind: model.online ? .error(title: "تعذّر قراءة الدعوة", message: m) : .offline(message: "نقرأ الدعوة أول ما يرجع الاتصال."),
                              actionTitle: "حاول مرة ثانية", actionID: "invite.retry") { Task { await load() } }
            }
        }
        .task { if let preset { phase = preset } else { await load() } }
    }

    private func status(_ s: OutingStatusUI) -> OutingStatus {
        switch s {
        case .active: return .active
        case .paused: return .paused
        case .notStarted: return .created
        case .ended: return .ended
        }
    }

    private func close() {
        model.pendingInvite = nil
        dismiss()
    }

    private func load() async {
        phase = .loading
        do {
            let p = try await model.preview(token)
            let st: OutingStatusUI = {
                switch p.status {
                case .active: return .active
                case .paused: return .paused
                case .created: return .notStarted
                case .ended: return .ended
                }
            }()
            phase = .ready(InvitePreviewUI(outingName: p.name, inviterName: p.owner_name, participantCount: p.member_count, status: st))
        } catch let e as OutingAPIError {
            switch e.code {
            case "invite_expired", "invite_revoked": phase = .expired
            case "invite_invalid", "not_found", "http_404", "http_400": phase = .invalid
            default: phase = .error(e.arabic)
            }
        } catch {
            phase = .error("حدث خطأ. أعد المحاولة.")
        }
    }

    private func join() {
        busy = true
        error = nil
        Task {
            if model.identity == nil {
                _ = await model.createIdentity(name: name, phone: "")
                if model.identity != nil { OnboardingProgress.done = true }
            }
            if model.identity != nil, await model.join(token) {
                busy = false
                dismiss()
                return
            }
            error = model.errorText ?? "تعذّر الانضمام."
            model.errorText = nil
            busy = false
        }
    }
}

// MARK: - Notifications explainer (before the system prompt)

/// Shown once after joining an outing, and from notification settings. The
/// system prompt only ever comes after this.
struct NotifyExplainerSheet: View {
    var done: () -> Void
    @EnvironmentObject private var model: AppModel
    @Environment(\.sary) private var theme
    @State private var busy = false

    var body: some View {
        let p = theme.palette
        VStack(spacing: theme.space(.l)) {
            Image(systemName: "bell.badge.fill").font(.system(size: 52, weight: .semibold)).foregroundStyle(p.accentText)
                .padding(.top, theme.space(.xl))
            Text("نبّهك إذا احتاجك أحد؟").saryText(.title, weight: .bold).foregroundStyle(p.textPrimary)
            VStack(alignment: .leading, spacing: theme.space(.m)) {
                line(SaryIcon.sos, p.emergency, "طوارئ من أحد في طلعتك — تنبيه عاجل بصوت.")
                line(SaryIcon.note, nil, "رسالة قصيرة أو مقطع صوتي من المجموعة — بهدوء.")
                line("lock.fill", nil, "لا إعلانات، ولا شيء خارج طلعاتك. توقفها من الإعدادات متى شئت.")
            }
            .padding(theme.space(.l))
            .sarySurface(radius: SaryRadius.l)
            Spacer(minLength: 0)
            Button {
                busy = true
                Task {
                    await model.push.ask(signedIn: model.signedIn)
                    busy = false
                    done()
                }
            } label: { SaryButtonLabel(title: "فعّل التنبيهات", systemImage: "bell.fill", busy: busy) }
                .buttonStyle(.sary(.primary))
                .accessibilityIdentifier("notify.allow")
            Button("ليس الآن") {
                model.push.explained = true
                done()
            }
            .buttonStyle(.sary(.plain))
            .accessibilityIdentifier("notify.later")
        }
        .padding(.horizontal, theme.space(.l))
        .padding(.bottom, theme.space(.l))
        .background(p.elevated.ignoresSafeArea())
        .presentationDetents([.large])
    }

    private func line(_ icon: String, _ c: Color?, _ t: String) -> some View {
        HStack(alignment: .top, spacing: theme.space(.m)) {
            SaryRowIcon(systemImage: icon, color: c)
            Text(t).saryText(.callout).foregroundStyle(theme.palette.textPrimary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
