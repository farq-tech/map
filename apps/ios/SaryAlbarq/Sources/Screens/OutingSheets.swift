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
                          state: invalid ? .error("الرابط ناقص أو فيه خطأ.") : .normal)
                .environment(\.layoutDirection, .leftToRight)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            HStack(spacing: theme.space(.s)) {
                /* The system «لصق»: the pasteboard is read only on this tap (no iOS paste banner). */
                PasteButton(payloadType: String.self) { strings in
                    Task { @MainActor in pasted(strings) }
                }
                .buttonBorderShape(.capsule)
                .tint(theme.palette.accent)
                .accessibilityIdentifier("paste.paste")
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
            QRScanSheet(title: "امسح رمز الدعوة", hint: "وجّه الكاميرا لرمز QR في جوال أمير الطلعة.") { s in
                scanning = false
                text = s
                go(s)
            } cancel: { scanning = false }
            .rtl()
        }
    }

    /// «لصق»: the link goes in the field; a valid one opens the invite at once.
    private func pasted(_ strings: [String]) {
        guard let s = strings.first(where: { InviteLink.token(fromPasted: $0) != nil }) ?? strings.first else { return }
        text = s
        invalid = false
        if InviteLink.token(fromPasted: s) != nil { go(s) } else { invalid = true }
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

/// The invitee's whole onboarding (build 14, tightened in build 21; `JoinMachine`): who invited
/// you, the trip, the destination, the Najdi pre-prompt (iOS has not asked yet) and «انضم للطلعة».
/// One tap makes the identity silently (the name the inviter gave), asks iOS for the location
/// (then for «الموقع الدقيق» if it is off) and — granted — joins and enters the live trip with
/// sharing on. Refused / still approximate: not joined — the recovery screen «افتح الإعدادات» /
/// «إلغاء», which joins by itself the moment iOS says yes. Expired / taken / invalid as before.
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
            restorePendingJoinAttempt()
        }
        .onChange(of: scenePhase) { _, p in
            /* Back from Settings: iOS may say yes now → join and enter by itself. */
            guard p == .active else { return }
            location.refreshAuthorization()
            /* iOS may rebuild the sheet while its permission alert is in front. The persisted
             * attempt survives that rebuild; if the view state restarted at `.ready`, restore
             * it from Core Location's resolved answer before showing another active Join button. */
            if step == .ready, model.hasPendingInviteJoinAttempt(token), currentPermission != .notAsked {
                restorePendingJoinAttempt()
                return
            }
            switch step {
            case .askingLocation, .needsLocation:
                /* The system prompt can reactivate the app before Core Location finishes its
                 * async request. Resolve the join state from the manager's current answer. */
                send(.sceneActive(currentPermission))
            default:
                break
            }
        }
        .onReceive(location.$authorization.combineLatest(location.$accuracyAuthorization).dropFirst()) { _ in
            switch step {
            case .askingLocation, .needsLocation:
                /* Do not leave the join button spinning if the authorization publisher wins
                 * the race with the request continuation after the system alert. */
                send(.permission(currentPermission))
            case .ready where model.hasPendingInviteJoinAttempt(token) && currentPermission != .notAsked:
                /* Authorization can publish before the scene-active event. Recover even if the
                 * permission sheet caused SwiftUI to recreate this view's local state. */
                restorePendingJoinAttempt()
            default:
                break
            }
        }
    }

    private var currentPermission: JoinPermission {
        let p = JoinPermission.from(location.authorization, location.accuracyAuthorization)
        #if DEBUG
        /* UI tests: `-SaryJoinReduced allow|deny` plays «الموقع الدقيق» off (the simulator cannot set it). */
        if JoinDebug.reduced != nil, p == .granted, !debugPreciseGranted { return .reduced }
        #endif
        return p
    }

    private var joinButtonAccessibilityValue: String {
        let stepValue = step.accessibilityValue
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-SaryJoinDiagnostics") {
            return "\(stepValue) · auth=\(location.authorization.rawValue) · pending=\(model.hasPendingInviteJoinAttempt(token))"
        }
        #endif
        return stepValue
    }

    #if DEBUG
    @State private var debugPreciseGranted = false
    #endif

    /// iOS has not asked for the location yet: the pre-prompt says why before the system alert.
    private var showsPrePrompt: Bool { location.authorization == .notDetermined }

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
                    if let dest = inv.destinationName {
                        Label {
                            Text("الوجهة: \(dest)").saryText(.callout, weight: .bold)
                                .accessibilityIdentifier("invite.destination")
                        } icon: { Image(systemName: "mappin.and.ellipse").accessibilityHidden(true) }
                            .foregroundStyle(p.textPrimary)
                    }
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
                        SaryTextField(title: "اسمك", placeholder: "كما يشوفه الربع", text: $name, id: "invite.myName", maxLength: ServerRules.nameMax)
                    }
                    if case let .failed(m) = step { SaryInlineMessage(text: m, tone: .error) }
                    if showsPrePrompt { JoinPrePrompt() }
                    Button { join(inv) } label: {
                        SaryButtonLabel(title: JoinCopy.button, systemImage: SaryIcon.locate, busy: step.busy, busyTitle: step == .askingPrecise ? "نطلب الموقع الدقيق…" : "ننضم…")
                    }
                    .buttonStyle(.sary(.primary))
                    .disabled(step.busy || (needsTypedName(inv) && name.trimmingCharacters(in: .whitespaces).isEmpty))
                    .accessibilityIdentifier("invite.join")
                    .accessibilityValue(joinButtonAccessibilityValue)
                    Text(JoinCopy.statement)
                        .saryText(.footnote, weight: .medium).foregroundStyle(p.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("join.shareStatement")
                }
            case .expired:
                SaryStateView(kind: .error(title: "انتهت صلاحية الدعوة", message: "اطلب من أمير الطلعة رابطًا جديدًا. الروابط تنتهي أو يلغيها أمير الطلعة."),
                              actionTitle: "حسنًا", actionID: "invite.close", actionIcon: nil, action: close)
                    .accessibilityIdentifier("invite.expired")
            case .taken:
                SaryStateView(kind: .error(title: "هذه الدعوة لشخص آخر", message: "انضم بها صاحبها. إذا كانت لك ودخلت بحساب جديد، أضف رقم جوالك في «ملفي» وافتح الرابط مرة ثانية، أو اطلب من أمير الطلعة دعوة جديدة باسمك."),
                              actionTitle: "حسنًا", actionID: "invite.close", actionIcon: nil, action: close)
                    .accessibilityIdentifier("invite.taken")
            case .invalid:
                SaryStateView(kind: .error(title: "الرابط ناقص أو فيه خطأ", message: "تأكد أنك نسخت الرابط كاملًا، أو امسح رمز QR من جوال أمير الطلعة."),
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
        model.clearPendingInviteJoinAttempt(token)
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
            if InviteClaim.outcome(p) == .taken { phase = .taken; return }
            phase = .ready(InvitePreviewUI(outingName: p.name, inviterName: p.owner_name, participantCount: p.member_count, status: st,
                                           inviteeName: p.isPersonal ? p.invitee_name : nil,
                                           destinationName: InvitePreviewUI.destination(p.destination_name)))
        } catch let e as OutingAPIError {
            switch InviteClaim.outcome(errorCode: e.code) {
            case .expired: phase = .expired
            case .taken: phase = .taken
            case .invalid: phase = .invalid
            case .join, .other: phase = .error(e.arabic)
            }
        } catch {
            phase = .error("ما قدرنا نقرأ الدعوة الحين. تأكد إن النت شغّال وجرّب مرة ثانية.")
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
        #if DEBUG
        NSLog("[JOIN_DIAG] event=%@ before=%@ after=%@ auth=%d", String(describing: e), String(describing: before), String(describing: after), location.authorization.rawValue)
        #endif
        guard after != before else { return }
        step = after
        if case .askingLocation = after { model.markPendingInviteJoinAttempt(token) }
        if case .needsLocation = after { model.markPendingInviteJoinAttempt(token) }
        if after == .cancelled { model.clearPendingInviteJoinAttempt(token) }
        run(after)
    }

    /// The iOS permission alert can take this sheet out of the view tree. If SwiftUI builds it
    /// again, recover the join from the model and the authoritative Core Location state.
    private func restorePendingJoinAttempt() {
        let pending = model.hasPendingInviteJoinAttempt(token)
        location.refreshAuthorization()
        #if DEBUG
        NSLog("[JOIN_DIAG] restore pending=%d step=%@ auth=%d", pending, String(describing: step), location.authorization.rawValue)
        #endif
        guard pending else { return }
        switch currentPermission {
        case .denied, .reduced:
            step = .needsLocation(currentPermission)
        case .granted:
            step = .joining(viewOnly: false)
            run(step)
        case .notAsked:
            step = .askingLocation
            run(step)
        }
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
                /* Right after the pre-prompt: When In Use. Already answered → what iOS says now. */
                let status = await location.requestWhenInUse()
                /* Use Core Location's completed answer, then refresh the manager snapshot. This
                 * avoids leaving the join spinner up if the published authorization update races
                 * the async permission continuation. */
                location.refreshAuthorization()
                var permission = JoinPermission.from(status, location.accuracyAuthorization)
                #if DEBUG
                /* iOS Simulator cannot switch full/reduced accuracy on demand; only the
                 * precise-location follow-up is substituted by this focused UI-test hook. */
                if JoinDebug.reduced != nil, permission == .granted, !debugPreciseGranted {
                    permission = .reduced
                }
                #endif
                send(.permission(permission))
            }
        case .askingPrecise:
            Task {
                /* «الموقع الدقيق» off: iOS's temporary full accuracy (GPS's `requestPreciseForTrip`, purpose key ConvoyTrip). */
                #if DEBUG
                if let allow = JoinDebug.reduced {
                    /* Keep the simulated request visible long enough for UI automation to observe it. */
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    debugPreciseGranted = allow
                    send(.precise(currentPermission))
                    return
                }
                #endif
                _ = await location.requestPreciseForTrip()
                send(.precise(currentPermission))
            }
        case .joining:
            /* The GPS starts now, while the server join is in flight: the first fix is on its way
             * before the live map opens (no-op without permission; the session keeps it running). */
            location.watchForeground()
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
            model.clearPendingInviteJoinAttempt(token)
            dismiss()
        case .cancelled:
            close()
        case .ready, .needsLocation, .failed:
            break
        }
    }
}

/// Refused, or «الموقع الدقيق» still off: not joined (owner decision: never in a trip without the
/// location). «افتح الإعدادات» / «إلغاء»; it joins by itself once iOS says yes.
struct JoinNeedsLocationView: View {
    var permission: JoinPermission
    var openSettings: () -> Void
    var cancel: () -> Void
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        /* Scrolls on an SE / large text instead of pushing the buttons off; the buttons stay pinned. */
        SaryFitColumn {
            VStack(spacing: theme.space(.l)) {
                Spacer(minLength: theme.space(.xl))
                Image(systemName: permission == .reduced ? "location.circle" : "location.slash.circle.fill")
                    .font(.system(size: 64, weight: .semibold))
                    .foregroundStyle(p.accentText)
                    .accessibilityHidden(true)
                Text(JoinCopy.needsTitle(permission))
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
                Spacer(minLength: theme.space(.l))
            }
            .padding(.horizontal, theme.space(.l))
        } bottom: {
            VStack(spacing: theme.space(.l)) {
                Button(action: openSettings) { SaryButtonLabel(title: JoinCopy.openSettings, systemImage: "gearshape.fill") }
                    .buttonStyle(.sary(.primary))
                    .accessibilityIdentifier("join.openSettings")
                Button(JoinCopy.cancel, action: cancel)
                    .buttonStyle(.sary(.plain))
                    .accessibilityIdentifier("join.cancel")
            }
            .padding(.top, theme.space(.s))
            .padding(.horizontal, theme.space(.l))
            .padding(.bottom, theme.space(.l))
            .background(p.background)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.palette.background.ignoresSafeArea())
    }
}

/// The Najdi pre-prompt above «انضم للطلعة» while iOS has not asked for the location yet:
/// why, then the system alert comes from the same tap (no extra screen).
struct JoinPrePrompt: View {
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        HStack(alignment: .top, spacing: theme.space(.m)) {
            Image(systemName: "location.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(p.accentText)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: theme.space(.xs)) {
                Text(JoinCopy.prePromptTitle)
                    .saryText(.headline, weight: .bold)
                    .foregroundStyle(p.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("join.prePrompt")
                Text(JoinCopy.prePromptDetail)
                    .saryText(.footnote)
                    .foregroundStyle(p.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(theme.space(.m))
        .frame(maxWidth: .infinity, alignment: .leading)
        .sarySurface(radius: SaryRadius.l)
        .accessibilityElement(children: .combine)
    }
}

#if DEBUG
/// DEBUG launch hooks of the join (UI tests).
enum JoinDebug {
    /// `-SaryJoinReduced allow|deny`: the location comes back approximate; the precise prompt is
    /// answered with `allow` (true) or `deny` (false). nil: the real iOS answers.
    static let reduced: Bool? = {
        let a = ProcessInfo.processInfo.arguments
        guard let i = a.firstIndex(of: "-SaryJoinReduced") else { return nil }
        return i + 1 < a.count ? a[i + 1] == "allow" : false
    }()
}
#endif

// MARK: - Notifications explainer (before the system prompt)

/// Shown once after joining an outing, and from notification settings. The
/// system prompt only ever comes after this.
struct NotifyExplainerSheet: View {
    var done: () -> Void
    @EnvironmentObject private var model: AppModel
    @Environment(\.sary) private var theme
    @State private var busy = false
    @State private var ring = 0

    var body: some View {
        let p = theme.palette
        /* Scrolls on an SE / large text; «فعّل التنبيهات» and «لاحقًا» stay pinned at the bottom. */
        SaryFitColumn {
            VStack(spacing: theme.space(.l)) {
                Image(systemName: "bell.badge.fill").font(.system(size: 52, weight: .semibold)).foregroundStyle(p.accentText)
                    /* The bell rings once as the sheet settles (bounded; nothing under Reduce Motion). */
                    .symbolEffect(.bounce, value: ring)
                    .onAppear {
                        guard OnboardingMotion.plays(reduceMotion: theme.reduceMotion) else { return }
                        DispatchQueue.main.asyncAfter(deadline: .now() + SaryMotion.enter.duration) { ring &+= 1 }
                    }
                    .padding(.top, theme.space(.xl))
                Text("نبّهك إذا احتاجك أحد؟").saryText(.title, weight: .bold).foregroundStyle(p.textPrimary)
                    .multilineTextAlignment(.center)
                VStack(alignment: .leading, spacing: theme.space(.m)) {
                    line(SaryIcon.sos, p.emergency, "طوارئ من أحد في طلعتك — تنبيه عاجل بصوت.")
                    line(SaryIcon.note, nil, "رسالة قصيرة أو مقطع صوتي من الربع، بهدوء.")
                    line("lock.fill", nil, "لا إعلانات، ولا شيء خارج طلعاتك. توقفها من الإعدادات متى شئت.")
                }
                .padding(theme.space(.l))
                .sarySurface(radius: SaryRadius.l)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, theme.space(.l))
        } bottom: {
            VStack(spacing: theme.space(.l)) {
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
                Button("لاحقًا") {
                    model.push.explained = true
                    done()
                }
                .buttonStyle(.sary(.plain))
                .accessibilityIdentifier("notify.later")
            }
            .padding(.top, theme.space(.s))
            .padding(.horizontal, theme.space(.l))
            .padding(.bottom, theme.space(.l))
            .background(p.elevated)
        }
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
