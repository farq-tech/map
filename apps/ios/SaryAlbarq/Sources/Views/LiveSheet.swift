import SwiftUI

/// The native 3-detent sheet: summary line, then the tabs المشاركون / الدعوة /
/// الإعدادات. Everything presented over the live screen (participant card,
/// note composer, stations, consent, rally label, a friend's SOS) is presented
/// from here, because the sheet is the top-most presentation.
struct LiveSheet: View {
    @ObservedObject var controller: LiveOutingController
    @Environment(\.sary) private var theme
    @Environment(AppearanceSettings.self) private var appearance

    var body: some View {
        let ui = controller.ui
        let actions = controller.actions
        VStack(spacing: theme.space(.s)) {
            SarySheetSummary(participants: ui.participantsTab.participants, detent: ui.sheetDetent,
                             expand: { actions.setSheetDetent(ui.sheetDetent == .peek ? .half : .peek) })
            if ui.sheetDetent != .peek {
                SaryTabBar(selection: Binding(get: { ui.selectedTab }, set: { actions.selectTab($0) }))
                    .padding(.horizontal, theme.space(.l))
                ScrollView {
                    VStack(spacing: theme.space(.m)) {
                        switch ui.selectedTab {
                        case .participants: ParticipantsTab(controller: controller, ui: ui)
                        case .invite: InviteTab(controller: controller, ui: ui)
                        case .settings: SettingsTab(controller: controller, ui: ui)
                        }
                    }
                    .padding(.horizontal, theme.space(.l))
                    .padding(.bottom, theme.space(.xl))
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .padding(.top, theme.space(.s))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .sheet(item: $controller.modal) { m in
            modal(m)
                .saryAppearance(appearance)
        }
        .fullScreenCover(item: Binding(get: { ui.sos.incoming.first { !$0.acknowledged } }, set: { _ in })) { a in
            SaryFriendSOSAlert(alert: a, now: Date(), show: { controller.showSOS(a.id) }, call: { actions.sos.call(a.id) })
                .saryAppearance(appearance)
                .accessibilityIdentifier("friend-sos-alert")
        }
        .sheet(item: Binding(get: { controller.shareItem.map(ShareURL.init) }, set: { if $0 == nil { controller.shareItem = nil } })) { s in
            ShareSheet(items: [s.url]).presentationDetents([.medium, .large])
        }
        .confirmationDialog("أنت تشارك موقعك الآن", isPresented: Binding(get: { controller.confirm == .backWhileSharing }, set: { if !$0 { controller.confirm = nil } }), titleVisibility: .visible) {
            Button("أوقف المشاركة وارجع", role: .destructive) {
                Task { await controller.session.stopSharing(); controller.onExit() }
            }
            Button("ابقَ في الطلعة", role: .cancel) {}
        } message: {
            Text("الرجوع إلى قائمة الطلعات يوقف مشاركة موقعك.")
        }
        .alert("تنبيه", isPresented: Binding(get: { controller.session.errorText != nil }, set: { if !$0 { controller.session.errorText = nil } })) {
            Button("حسنًا", role: .cancel) {}
        } message: { Text(controller.session.errorText ?? "") }
    }

    @ViewBuilder
    private func modal(_ m: LiveModal) -> some View {
        switch m {
        case let .participant(id):
            if let s = controller.participantCard(id) {
                ScrollView { SaryParticipantCard(state: s, actions: controller.participantActions(id)) }
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    .accessibilityIdentifier("participant-card")
            }
        case .note:
            NoteComposer(state: NoteComposerUIState(currentNote: controller.ui.participantsTab.participants.first(where: \.isMe)?.note,
                                                   isSending: controller.session.busy.contains("note")),
                         actions: NoteComposerActions(
                            send: { t in Task { if await controller.session.sendNote(t) { controller.modal = nil; controller.toast("رسالتك فوق سيارتك ١٥ دقيقة") } } },
                            clearNote: { Task { if await controller.session.sendNote("") { controller.modal = nil } } },
                            cancel: { controller.modal = nil }))
                .presentationDetents([.medium, .large])
        case .stations:
            NearestStationsView(state: NearestStationsUIState(phase: controller.stations), actions: controller.stationActions)
                .presentationDetents([.medium, .large])
        case .consent:
            ConsentView(accept: controller.acceptConsent, cancel: { controller.modal = nil })
                .presentationDetents([.large])
        case let .rallyLabel(p, moving):
            RallyLabelView(moving: moving, save: { controller.saveRally(p, label: $0) }, cancel: { controller.modal = nil })
                .presentationDetents([.medium])
        case .notify:
            NotifyExplainerSheet(done: { controller.modal = nil })
        }
    }
}

private struct ShareURL: Identifiable { let url: URL; var id: String { url.absoluteString } }

extension IncomingSOSUI: @retroactive Hashable {
    func hash(into h: inout Hasher) { h.combine(id) }
}

// MARK: - Participants tab

private struct ParticipantsTab: View {
    @ObservedObject var controller: LiveOutingController
    var ui: LiveOutingUIState
    @Environment(\.sary) private var theme

    var body: some View {
        let actions = controller.actions
        let v = controller.session.view
        Group {
            ShareCallout(controller: controller, ui: ui)
            if ui.participantsTab.myPhoneMissing {
                Button(action: actions.participantsTab.addMyPhone) {
                    SaryBanner(text: "لم تضف رقمك · أضف رقمك ليتصل بك أصحابك", tone: .info, systemImage: SaryIcon.phone)
                }
                .buttonStyle(.plain)
            }
            if ui.status != .ended {
                SaryRallyCard(rally: ui.participantsTab.rally, canManage: v?.iLead == true, actions: actions.participantsTab)
            }
            VStack(spacing: 0) {
                let list = ui.participantsTab.participants
                ForEach(list) { p in
                    SaryParticipantRow(participant: p, now: ui.now) { actions.participantsTab.openParticipant(p.id) }
                        .accessibilityIdentifier("participant-row")
                    if p.id != list.last?.id { SaryDivider().padding(.leading, 60) }
                }
            }
            .padding(.vertical, theme.space(.xs))
            .sarySurface(radius: SaryRadius.l)
        }
    }
}

/// The one clear call to action for my own sharing, and the outing's state.
private struct ShareCallout: View {
    @ObservedObject var controller: LiveOutingController
    var ui: LiveOutingUIState
    @Environment(\.sary) private var theme

    var body: some View {
        let v = controller.session.view
        if let r = controller.session.closedReason {
            SaryBanner(text: closedText(r), tone: .warning, systemImage: SaryIcon.warning)
        } else {
            switch ui.status {
            case .notStarted:
                VStack(spacing: theme.space(.s)) {
                    SaryBanner(text: v?.iLead == true ? "الطلعة لم تبدأ. ابدأها ليشارك الجميع مواقعهم." : "تبدأ المشاركة عندما يبدأ صاحب الطلعة.", tone: .info)
                    if v?.iLead == true {
                        Button { controller.startOuting() } label: { SaryButtonLabel(title: "ابدأ الطلعة", systemImage: SaryIcon.play) }
                            .buttonStyle(.saryPrimary)
                            .accessibilityIdentifier("live.start")
                    }
                }
            case .paused:
                SaryBanner(text: "الطلعة متوقفة مؤقتًا. لا أحد يشارك موقعه الآن.", tone: .warning, systemImage: SaryIcon.pause)
            case .ended:
                SaryBanner(text: "انتهت هذه الطلعة.", tone: .info)
            case .active:
                if ui.sharing == .paused {
                    Button { controller.setSharingPaused(false) } label: { SaryButtonLabel(title: "شارك موقعي", systemImage: SaryIcon.locate) }
                        .buttonStyle(.saryPrimary)
                        .accessibilityIdentifier("live.share")
                } else {
                    HStack(spacing: theme.space(.s)) {
                        Circle().fill(ui.sharing == .sharing ? theme.palette.live : theme.palette.warning).frame(width: 8, height: 8)
                        Text(ui.sharing == .sharing ? "موقعك مُشارَك الآن مع أعضاء الطلعة" : "جارٍ تحديد موقعك…")
                            .saryText(.callout, weight: .bold)
                            .foregroundStyle(theme.palette.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("live.sharing")
                        Button { controller.setSharingPaused(true) } label: { Text("أوقف") }
                            .buttonStyle(.sary(.secondary, width: .hug, compact: true))
                            .accessibilityIdentifier("live.stopSharing")
                    }
                    .padding(theme.space(.m))
                    .sarySurface(radius: SaryRadius.l)
                }
            }
        }
    }

    private func closedText(_ r: LiveCloseReason) -> String {
        switch r {
        case .outingEnded: return "انتهت هذه الطلعة."
        case .removed: return "أزالك صاحب الطلعة منها."
        case .left: return "غادرت هذه الطلعة."
        case .notAMember: return "لست عضوًا في هذه الطلعة."
        case .unauthorized: return "انتهت جلستك على هذا الجهاز."
        case .replaced: return "فتحت الطلعة من جهاز آخر."
        }
    }
}

// MARK: - Invite tab

private struct InviteTab: View {
    @ObservedObject var controller: LiveOutingController
    var ui: LiveOutingUIState
    @Environment(\.sary) private var theme
    @State private var confirmRevoke = false
    @State private var copied = false

    var body: some View {
        let s = ui.inviteTab
        let actions = controller.actions.inviteTab
        VStack(spacing: theme.space(.m)) {
            if let link = s.link {
                SaryQRCode(text: link, size: theme.drive ? 200 : 170)
                    .accessibilityIdentifier("invite-qr")
                Text(link.replacingOccurrences(of: "https://", with: ""))
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(theme.palette.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .environment(\.layoutDirection, .leftToRight)
                    .textSelection(.enabled)
                HStack(spacing: theme.space(.s)) {
                    Button {
                        actions.copyLink()
                        copied = true
                        Task { try? await Task.sleep(nanoseconds: 1_500_000_000); copied = false }
                    } label: { SaryButtonLabel(title: copied ? "تم النسخ" : "نسخ", systemImage: copied ? SaryIcon.check : SaryIcon.copy) }
                        .buttonStyle(.sarySecondary)
                        .accessibilityIdentifier("invite-copy")
                    Button(action: actions.shareLink) { SaryButtonLabel(title: "مشاركة", systemImage: SaryIcon.share) }
                        .buttonStyle(.saryPrimary)
                        .accessibilityIdentifier("invite-share")
                }
                Text("الرابط يدخل أي شخص يفتحه إلى الطلعة. شاركه مع أصحابك فقط.")
                    .saryText(.footnote)
                    .foregroundStyle(theme.palette.textSecondary)
                    .multilineTextAlignment(.center)
            } else if s.canRevoke {
                SaryStateView(kind: .empty(title: "لا يوجد رابط على هذا الجهاز",
                                           message: "الخادم لا يحفظ الروابط. أنشئ رابطًا جديدًا، وأي رابط قديم يتوقف.", systemImage: "link"))
            } else {
                SaryStateView(kind: .empty(title: "اطلب الرابط من صاحب الطلعة", message: "الرابط عند من أنشأه فقط.", systemImage: "link"))
            }
            if s.canRevoke {
                Button { if s.link == nil { actions.revokeLink() } else { confirmRevoke = true } } label: {
                    SaryButtonLabel(title: s.link == nil ? "أنشئ رابطًا" : "إلغاء الرابط وإنشاء جديد", systemImage: "arrow.triangle.2.circlepath",
                                    busy: s.isRevoking, busyTitle: "جارٍ الإنشاء…")
                }
                .buttonStyle(.sary(s.link == nil ? .primary : .plainDestructive))
                .disabled(s.isRevoking)
                .accessibilityIdentifier("invite-revoke")
            }
        }
        .padding(theme.space(.l))
        .sarySurface(radius: SaryRadius.l)
        .confirmationDialog("رابط جديد؟", isPresented: $confirmRevoke, titleVisibility: .visible) {
            Button("ألغِ القديم وأنشئ جديدًا", role: .destructive, action: actions.revokeLink)
            Button("إلغاء", role: .cancel) {}
        } message: { Text("الرابط القديم يتوقف فورًا، ومن انضم يبقى في الطلعة.") }
    }
}

// MARK: - Settings tab

private struct SettingsTab: View {
    @ObservedObject var controller: LiveOutingController
    var ui: LiveOutingUIState
    @Environment(\.sary) private var theme
    @State private var confirm: Kind?
    @State private var phone = ""

    enum Kind: Identifiable { case pause, end, leave; var id: Self { self } }

    var body: some View {
        let s = ui.settingsTab
        let a = controller.actions.settingsTab
        Group {
            SarySection(title: "مشاركتي", footer: "يُرسل موقعك فقط والتطبيق مفتوح أمامك. إذا قفلت الشاشة يتوقف الإرسال ويظهر لأصحابك «آخر موقع».") {
                SaryToggleRow(title: "أوقف مشاركة موقعي", systemImage: SaryIcon.pause,
                              isOn: Binding(get: { s.isSharingPaused }, set: { a.setSharingPaused($0) }), id: "settings-pause-sharing")
                SaryDivider()
                SaryToggleRow(title: "شارك البطارية", subtitle: "نسبة الشحن تظهر لأعضاء الطلعة", systemImage: SaryIcon.battery(60),
                              isOn: Binding(get: { s.batterySharingOn }, set: { a.setBatterySharing($0) }), id: "settings-battery")
                SaryDivider()
                SaryToggleRow(title: "الإشعارات", subtitle: "رسائل وطوارئ الأصحاب", systemImage: "bell.fill",
                              isOn: Binding(get: { s.notificationsOn }, set: { a.setNotifications($0) }), id: "settings-notify")
            }
            SarySection(title: "وضع القيادة") {
                SarySegmented(options: TriModeUI.allCases, selection: Binding(get: { s.driveMode }, set: { a.setDriveMode($0) }), label: { $0.label }, id: "settings-drive")
                    .padding(theme.space(.s))
            }
            SarySection(title: "الوضع الليلي") {
                SarySegmented(options: TriModeUI.allCases, selection: Binding(get: { s.nightMode }, set: { a.setNightMode($0) }), label: { $0.label }, id: "settings-night")
                    .padding(theme.space(.s))
            }
            SarySection(title: "رقمي", footer: "يظهر لأعضاء طلعاتك فقط، ليتصلوا بك أو يراسلوك واتساب.") {
                VStack(spacing: theme.space(.s)) {
                    SaryTextField(title: "رقم الجوال", placeholder: "05XXXXXXXX", text: $phone, id: "settings-phone", keyboard: .phonePad, maxLength: 14)
                    Button { a.saveMyPhone(phone.isEmpty ? nil : phone) } label: { SaryButtonLabel(title: "حفظ", systemImage: SaryIcon.check) }
                        .buttonStyle(.saryPrimary)
                        .disabled(!phone.isEmpty && SaryFormat.normalizeSaudiMobile(phone) == nil)
                }
                .padding(theme.space(.m))
            }
            .onAppear { phone = s.myPhone ?? "" }
            SarySection(title: "الطلعة") {
                if s.isLeader && s.outingStatus != .ended {
                    if s.outingStatus != .notStarted {
                        actionRow(s.outingStatus == .paused ? "استأنف الطلعة" : "أوقف مؤقتًا", icon: s.outingStatus == .paused ? SaryIcon.play : SaryIcon.pause, id: "settings-pause-outing") { confirm = .pause }
                        SaryDivider()
                    }
                    actionRow("أنهِ الطلعة", icon: "flag.checkered", destructive: true, id: "settings-end") { confirm = .end }
                    SaryDivider()
                }
                actionRow("غادر الطلعة", icon: "rectangle.portrait.and.arrow.right", destructive: true, id: "settings-leave") { confirm = .leave }
            }
            .confirmationDialog(title, isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), titleVisibility: .visible, presenting: confirm) { k in
                switch k {
                case .pause: Button(s.outingStatus == .paused ? "استأنف" : "أوقف مؤقتًا", action: a.pauseOrResumeOuting)
                case .end: Button("أنهِ الطلعة للجميع", role: .destructive, action: a.endOuting)
                case .leave: Button("غادر", role: .destructive, action: a.leaveOuting)
                }
                Button("إلغاء", role: .cancel) {}
            } message: { k in
                switch k {
                case .pause: Text(s.outingStatus == .paused ? "يرجع الأعضاء يشاركون مواقعهم." : "تتوقف مشاركة المواقع عند الجميع وتُحذف المواقع حتى تستأنف.")
                case .end: Text("بتنتهي الطلعة عند الكل ويتوقف تتبع المواقع. ما تقدر ترجعها.")
                case .leave: Text("بيتوقف إرسال موقعك وتخرج من الطلعة.")
                }
            }
        }
    }

    private var title: String {
        switch confirm {
        case .pause?: return ui.settingsTab.outingStatus == .paused ? "استئناف الطلعة؟" : "إيقاف الطلعة مؤقتًا؟"
        case .end?: return "أنهِ الطلعة؟"
        case .leave?: return "غادر الطلعة؟"
        case nil: return ""
        }
    }

    private func actionRow(_ title: String, icon: String, destructive: Bool = false, id: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: theme.space(.m)) {
                SaryRowIcon(systemImage: icon, color: destructive ? theme.palette.emergency : nil)
                Text(title).saryText(.body, weight: .bold)
                    .foregroundStyle(destructive ? theme.palette.emergency : theme.palette.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, theme.space(.m))
            .frame(minHeight: theme.minTarget + 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }
}

// MARK: - Note composer («رسالة»)

struct NoteComposer: View {
    var state: NoteComposerUIState
    var actions: NoteComposerActions
    @Environment(\.sary) private var theme
    @State private var text = ""

    var body: some View {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        VStack(alignment: .leading, spacing: theme.space(.m)) {
            Text("رسالة فوق سيارتك").saryText(.title2).foregroundStyle(theme.palette.textPrimary)
            Text("يشوفها أصحابك فوق سيارتك ١٥ دقيقة.").saryText(.footnote).foregroundStyle(theme.palette.textSecondary)
            SaryTextField(title: "الرسالة", placeholder: "مثل: بوقف عند المحطة", text: $text, id: "note-input", maxLength: state.maxLength)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: theme.space(.s)) {
                    ForEach(state.presets, id: \.self) { p in
                        Button(p) { text = p }.buttonStyle(.sary(.secondary, width: .hug, compact: true))
                    }
                }
            }
            if let e = state.errorMessage { SaryInlineMessage(text: e, tone: .error) }
            Button { actions.send(clean) } label: { SaryButtonLabel(title: "أرسل", systemImage: SaryIcon.send, busy: state.isSending, busyTitle: "جارٍ الإرسال…") }
                .buttonStyle(.saryPrimary)
                .disabled(clean.isEmpty || clean.count > state.maxLength || state.isSending)
                .accessibilityIdentifier("note-send")
            if let cur = state.currentNote {
                Button(role: .destructive, action: actions.clearNote) { SaryButtonLabel(title: "احذف رسالتي «\(cur)»", systemImage: "trash") }
                    .buttonStyle(.sary(.plainDestructive))
            }
            Button("إلغاء", action: actions.cancel).buttonStyle(.saryPlain)
        }
        .padding(theme.space(.l))
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Nearest stations

struct NearestStationsView: View {
    var state: NearestStationsUIState
    var actions: NearestStationsActions
    @Environment(\.sary) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space(.m)) {
            HStack {
                Text("أقرب محطة").saryText(.title2).foregroundStyle(theme.palette.textPrimary)
                Spacer()
                SaryIconButton(systemImage: SaryIcon.close, label: "إغلاق", action: actions.close)
            }
            switch state.phase {
            case .loading:
                SaryStateView(kind: .loading("جارٍ البحث عن أقرب محطة…"))
            case .empty:
                SaryStateView(kind: .empty(title: "لا توجد محطة مسجّلة قريبة", message: "لا نخمّن مكانها.", systemImage: SaryIcon.nearest))
            case let .error(msg):
                SaryStateView(kind: .error(title: "تعذّر التحميل", message: msg), actionTitle: "حاول مرة ثانية", action: actions.retry)
            case let .loaded(rows):
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(rows) { s in
                            SaryStationRow(station: s, go: { actions.go(s.id) }, show: { actions.show(s.id) })
                            if s.id != rows.last?.id { SaryDivider() }
                        }
                    }
                    .padding(.horizontal, theme.space(.l))
                    .sarySurface(radius: SaryRadius.l)
                }
            }
            Text("© OpenStreetMap contributors · ODbL").saryText(.micro).foregroundStyle(theme.palette.textTertiary)
                .environment(\.layoutDirection, .leftToRight)
        }
        .padding(theme.space(.l))
        .frame(maxHeight: .infinity, alignment: .top)
        .accessibilityIdentifier("stations")
    }
}

// MARK: - Consent

struct ConsentView: View {
    var accept: () -> Void
    var cancel: () -> Void
    @Environment(\.sary) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space(.l)) {
            ScrollView {
                VStack(alignment: .leading, spacing: theme.space(.l)) {
                    Image(systemName: "location.circle.fill").font(.system(size: 52)).foregroundStyle(theme.palette.accent)
                    Text("مشاركة موقعك في هذه الطلعة").saryText(.title2).foregroundStyle(theme.palette.textPrimary)
                    bullet("lock.fill", "يرى موقعك أعضاء هذه الطلعة فقط، ولا أحد غيرهم.")
                    bullet("iphone", "يُرسل موقعك فقط والتطبيق مفتوح أمامك. إذا قفلت الشاشة أو خرجت من التطبيق يتوقف الإرسال، ويظهر لأصحابك «آخر موقع» بعمره.")
                    bullet("stop.circle.fill", "تتوقف إذا أوقفتها، أو غادرت، أو أوقف صاحب الطلعة الطلعة أو أنهاها.")
                    bullet("clock.arrow.circlepath", "يحفظ الخادم آخر موقع لك فقط، لا مسارك، ويحذفه عند انتهاء الطلعة.")
                }
            }
            Button(action: accept) { SaryButtonLabel(title: "أوافق، شارك موقعي", systemImage: SaryIcon.locate) }
                .buttonStyle(.saryPrimary)
                .accessibilityIdentifier("consent.accept")
            Button("ليس الآن", action: cancel).buttonStyle(.saryPlain)
        }
        .padding(theme.space(.l))
    }

    private func bullet(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: theme.space(.m)) {
            Image(systemName: icon).foregroundStyle(theme.palette.accentText).frame(width: 24)
            Text(text).saryText(.body).foregroundStyle(theme.palette.textPrimary)
        }
    }
}

// MARK: - Rally label

private struct RallyLabelView: View {
    var moving: Bool
    var save: (String) -> Void
    var cancel: () -> Void
    @Environment(\.sary) private var theme
    @State private var label = ""

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space(.m)) {
            Text(moving ? "نقل نقطة التجمع" : "نقطة تجمع جديدة").saryText(.title2).foregroundStyle(theme.palette.textPrimary)
            SaryTextField(title: "اسم النقطة (اختياري)", placeholder: "مثل: عند الطعس الكبير", text: $label, id: "rally-label", maxLength: 40)
            Button { save(label) } label: { SaryButtonLabel(title: moving ? "انقلها هنا" : "حددها هنا", systemImage: SaryIcon.rally) }
                .buttonStyle(.saryPrimary)
                .accessibilityIdentifier("rally-save")
            Button("إلغاء", action: cancel).buttonStyle(.saryPlain)
        }
        .padding(theme.space(.l))
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Share sheet

struct ShareSheet: UIViewControllerRepresentable {
    var items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
