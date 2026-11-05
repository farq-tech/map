import SwiftUI
import UIKit

// MARK: - New outing
// «طلعة جديدة» is the three-step `CreateOutingWizard` (Sources/Create).

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
            Text(ShareMemory.joinStatement)
                .saryText(.footnote).foregroundStyle(theme.palette.textSecondary)
        }
        .sheet(isPresented: $scanning) {
            QRScanSheet(title: "امسح رمز الدعوة", hint: "وجّه الكاميرا لرمز QR في جوال أمير الرحلة.") { s in
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

// MARK: - Invite preview → join (one step)

/// The invitee's whole onboarding (owner decision, build 14; `JoinMachine`): who invited you,
/// the trip, «انضم للطلعة» and one honest line. One tap makes the identity silently (the name
/// the inviter gave), asks iOS for the location, and — granted — joins and enters the live trip
/// with sharing on. Refused / imprecise: not joined; one calm «افتح الإعدادات» screen that joins
/// by itself the moment iOS says yes. Expired / taken / invalid / retryable error as before.
struct InviteJoinSheet: View {
    let token: String
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var location: LocationSharer
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.sary) private var theme
    @State private var phase: InvitePhaseUI = .loading
    @State private var name = ""
    @State private var step: JoinStep = .ready
    var preset: InvitePhaseUI?
    /// DEBUG screenshots: open on this step (e.g. the calm «افتح الإعدادات» screen).
    var presetStep: JoinStep?

    var body: some View {
        Group {
            if case let .needsLocation(p) = step {
                JoinNeedsLocationView(permission: p, openSettings: openSettings, cancel: { send(.cancel) })
                    .transition(.opacity)
            } else {
                page
            }
        }
        .animation(theme.animation(.smooth), value: step)
        .interactiveDismissDisabled(step.busy)
        .task {
            if let presetStep { step = presetStep }
            if let preset { phase = preset } else { await load() }
        }
        .onChange(of: scenePhase) { _, p in
            /* Back from Settings: iOS may say yes now → join and enter by itself. */
            guard p == .active else { return }
            location.refreshAuthorization()
            send(.sceneActive(currentPermission))
        }
        .onReceive(location.$authorization.combineLatest(location.$accuracyAuthorization).dropFirst()) { _ in
            if case .needsLocation = step { send(.permission(currentPermission)) }
        }
    }

    private var currentPermission: JoinPermission { JoinPermission.from(location.authorization, location.accuracyAuthorization) }

    private var page: some View {
        let p = theme.palette
        return SaryPage(title: "دعوة طلعة", close: { send(.cancel) }) {
            switch phase {
            case .loading:
                SaryStateView(kind: .loading("نقرأ الدعوة…"))
            case .ready(let inv):
                VStack(alignment: .leading, spacing: theme.space(.m)) {
                    HStack(spacing: theme.space(.s)) {
                        Image(systemName: SaryIcon.crown).foregroundStyle(p.accentText)
                        Text("دعاك \(inv.inviterName)").saryText(.headline, weight: .bold).foregroundStyle(p.textPrimary)
                            .accessibilityIdentifier("invite.inviter")
                        Spacer()
                        SaryOutingStatusPill(status: status(inv.status))
                    }
                    Text(inv.outingName).saryText(.display, weight: .bold).foregroundStyle(p.textPrimary)
                        .accessibilityIdentifier("invite.name")
                    Label {
                        Text("\(SaryFormat.number(inv.participantCount)) في الطلعة الآن").saryText(.callout)
                    } icon: { Image(systemName: "person.2.fill") }
                        .foregroundStyle(p.textSecondary)
                    if let invitee = inv.inviteeName {
                        Label {
                            Text("تظهر في الطلعة باسم «\(invitee)» كما حفظك \(inv.inviterName)").saryText(.callout)
                        } icon: { Image(systemName: "person.fill.checkmark") }
                            .foregroundStyle(p.textSecondary)
                            .accessibilityIdentifier("invite.personal")
                    }
                }
                .padding(theme.space(.l))
                .frame(maxWidth: .infinity, alignment: .leading)
                .sarySurface(radius: SaryRadius.l)
                if inv.status == .ended {
                    SaryBanner(text: "انتهت هذه الطلعة، فلا يمكن الانضمام لها.", tone: .warning)
                } else {
                    if needsTypedName(inv) {
                        /* An open link and no identity yet: the only thing we cannot know is your name. */
                        SaryTextField(title: "اسمك", placeholder: "كما يراه أصحابك", text: $name, id: "invite.myName", maxLength: ServerRules.nameMax)
                    }
                    if case let .failed(m) = step { SaryInlineMessage(text: m, tone: .error) }
                    Button { join(inv) } label: {
                        SaryButtonLabel(title: JoinCopy.button, systemImage: SaryIcon.locate, busy: step.busy, busyTitle: "ننضم…")
                    }
                    .buttonStyle(.sary(.primary))
                    .disabled(step.busy || (needsTypedName(inv) && name.trimmingCharacters(in: .whitespaces).isEmpty))
                    .accessibilityIdentifier("invite.join")
                    Text(JoinCopy.statement)
                        .saryText(.footnote, weight: .medium).foregroundStyle(p.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("join.shareStatement")
                }
            case .expired:
                SaryStateView(kind: .error(title: "انتهت صلاحية الدعوة", message: "اطلب من أمير الرحلة رابطًا جديدًا. الروابط تنتهي أو يلغيها أمير الرحلة."),
                              actionTitle: "حسنًا", actionID: "invite.close", actionIcon: nil, action: close)
                    .accessibilityIdentifier("invite.expired")
            case .taken:
                SaryStateView(kind: .error(title: "هذه الدعوة لشخص آخر", message: "انضم بها صاحبها. اطلب من أمير الرحلة يرسل لك دعوة باسمك."),
                              actionTitle: "حسنًا", actionID: "invite.close", actionIcon: nil, action: close)
                    .accessibilityIdentifier("invite.taken")
            case .invalid:
                SaryStateView(kind: .error(title: "رابط غير صحيح", message: "تأكد أنك نسخت الرابط كاملًا، أو امسح رمز QR من جوال أمير الرحلة."),
                              actionTitle: "حسنًا", actionID: "invite.close", actionIcon: nil, action: close)
                    .accessibilityIdentifier("invite.invalid")
            case .error(let m):
                SaryStateView(kind: model.online ? .error(title: "تعذّر قراءة الدعوة", message: m) : .offline(message: "نقرأ الدعوة أول ما يرجع الاتصال."),
                              actionTitle: "حاول مرة ثانية", actionID: "invite.retry") { Task { await load() } }
            }
        }
    }

    /// Personal invite: the inviter named you. Already on this phone: your name. Otherwise ask.
    private func needsTypedName(_ inv: InvitePreviewUI) -> Bool { model.identity == nil && inv.inviteeName == nil }

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

    private func openSettings() {
        if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
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
            if p.isPersonal, p.claim == "taken" { phase = .taken; return }
            phase = .ready(InvitePreviewUI(outingName: p.name, inviterName: p.owner_name, participantCount: p.member_count, status: st,
                                           inviteeName: p.isPersonal ? p.invitee_name : nil))
        } catch let e as OutingAPIError {
            switch e.code {
            case "invite_expired", "invite_revoked", "open_links_disabled": phase = .expired
            case "invite_taken": phase = .taken
            case "invite_invalid", "not_found", "http_404", "http_400": phase = .invalid
            default: phase = .error(e.arabic)
            }
        } catch {
            phase = .error("حدث خطأ. أعد المحاولة.")
        }
    }

    /// The one tap. Each step's work runs where the machine enters it (`run`).
    private func join(_ inv: InvitePreviewUI) {
        pendingName = model.identity == nil ? (inv.inviteeName ?? name.trimmingCharacters(in: .whitespaces)) : nil
        send(.tapJoin(hasIdentity: model.identity != nil))
    }

    @State private var pendingName: String?

    private func send(_ e: JoinEvent) {
        let before = step
        let after = JoinMachine.next(before, e)
        guard after != before else { return }
        step = after
        run(after)
    }

    private func run(_ s: JoinStep) {
        switch s {
        case .preparing:
            Task {
                /* First time on this phone: the identity is made silently with the name the inviter gave. */
                let ok = await model.createIdentity(name: pendingName ?? "", phone: "")
                if ok {
                    OnboardingProgress.done = true
                    send(.identityReady)
                } else {
                    let m = model.errorText ?? "تعذّر الحفظ. أعد المحاولة."
                    model.errorText = nil
                    send(.identityFailed(m))
                }
            }
        case .askingLocation:
            Task {
                /* The only prompt at join: When In Use (precise). Already answered → what iOS says now. */
                _ = await location.requestWhenInUse()
                send(.permission(currentPermission))
            }
        case .joining:
            Task {
                if await model.join(token) {
                    send(.joined)
                    return
                }
                if model.errorText == OutingAPIError(code: "invite_taken", status: 409).arabic {
                    model.errorText = nil
                    step = .ready
                    phase = .taken
                    return
                }
                let m = model.errorText ?? "تعذّر الانضمام."
                model.errorText = nil
                send(.joinFailed(m))
            }
        case .entered:
            dismiss()
        case .cancelled:
            close()
        case .ready, .needsLocation, .failed:
            break
        }
    }
}

/// Refused, or «الموقع الدقيق» off: not joined. One calm screen; it joins by itself once iOS says yes.
struct JoinNeedsLocationView: View {
    var permission: JoinPermission
    var openSettings: () -> Void
    var cancel: () -> Void
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        VStack(spacing: theme.space(.l)) {
            Spacer(minLength: theme.space(.xl))
            Image(systemName: permission == .reduced ? "location.circle" : "location.slash.circle.fill")
                .font(.system(size: 64, weight: .semibold))
                .foregroundStyle(p.accentText)
                .accessibilityHidden(true)
            Text(JoinCopy.needsTitle)
                .saryText(.title, weight: .bold)
                .foregroundStyle(p.textPrimary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("join.needsLocation")
            Text(JoinCopy.needsMessage(permission))
                .saryText(.callout)
                .foregroundStyle(p.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: theme.space(.xl))
            Button(action: openSettings) { SaryButtonLabel(title: JoinCopy.openSettings, systemImage: "gearshape.fill") }
                .buttonStyle(.sary(.primary))
                .accessibilityIdentifier("join.openSettings")
            Button(JoinCopy.cancel, action: cancel)
                .buttonStyle(.sary(.plain))
                .accessibilityIdentifier("join.cancel")
        }
        .padding(.horizontal, theme.space(.l))
        .padding(.bottom, theme.space(.l))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.palette.background.ignoresSafeArea())
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
