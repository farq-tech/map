import SwiftUI

enum SafetyIcon {
    static let stuck = "car.side.and.exclamationmark"
    static let timer = "timer"
    static let overdue = "clock.badge.exclamationmark.fill"
    static let arrived = "checkmark.seal.fill"
    static let sunset = "sunset.fill"
    static let wayBack = "arrow.uturn.backward.circle.fill"
    static let all = [stuck, timer, overdue, arrived, sunset, wayBack] + StuckReplyKind.allCases.map(\.systemImage)
}

private struct SafetyActionsKey: EnvironmentKey {
    static let defaultValue = SafetyAlertActions()
}

extension EnvironmentValues {
    /// Buttons for the safety cards in the shared alert lane.
    var safetyAlertActions: SafetyAlertActions {
        get { self[SafetyActionsKey.self] }
        set { self[SafetyActionsKey.self] = newValue }
    }
}

// MARK: - Alert lane cards

/// The safety cards in the alert lane (drawn by `SaryAlertCard` for `.safety`).
struct SafetyAlertCard: View {
    var alert: SafetyAlertUI
    var tapped: () -> Void = {}
    var dismiss: () -> Void = {}
    @Environment(\.sary) private var theme
    @Environment(\.safetyAlertActions) private var actions

    var body: some View {
        let p = theme.palette
        VStack(alignment: .leading, spacing: theme.space(.s)) {
            HStack(alignment: .top, spacing: theme.space(.m)) {
                Button(action: tapped) {
                    HStack(alignment: .top, spacing: theme.space(.m)) {
                        glyph
                        texts.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                SaryDismissButton(action: dismiss)
            }
            buttons
        }
        .padding(.leading, theme.space(.m))
        .padding(.trailing, theme.space(.xs))
        .padding(.vertical, theme.space(.s))
        .overlay(alignment: .leading) {
            Rectangle().fill(tone).frame(width: 4).padding(.vertical, theme.space(.s))
        }
        .saryGlass(RoundedRectangle(cornerRadius: SaryRadius.l, style: .continuous), role: .panel)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(accessibilityID)
        .foregroundStyle(p.textPrimary)
    }

    private var tone: Color {
        switch alert {
        case .friendStuck, .myTimerOverdue, .friendTimerOverdue: return theme.palette.warning
        case .sunset: return theme.palette.warning
        }
    }

    private var accessibilityID: String {
        switch alert {
        case .friendStuck: return "safety-stuck-card"
        case .sunset: return "safety-sunset-card"
        case .myTimerOverdue: return "safety-overdue-card"
        case .friendTimerOverdue: return "safety-friend-overdue-card"
        }
    }

    @ViewBuilder private var glyph: some View {
        let p = theme.palette
        switch alert {
        case let .friendStuck(s):
            ZStack(alignment: .bottomTrailing) {
                SaryAvatar(name: s.name, color: s.color, size: theme.drive ? 44 : 36)
                Image(systemName: SafetyIcon.stuck)
                    .saryGlyph(10, weight: .bold, maxGrowth: SaryGlyph.tightGrowth)
                    .foregroundStyle(p.onAccent)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(p.warningText))
                    .overlay(Circle().stroke(p.background, lineWidth: 1.5))
                    /* Out past the avatar's bottom-trailing corner in RTL and LTR alike
                     * (a hard-coded `offset(x: 4)` pulled it inward under RTL). */
                    .padding(.trailing, -4)
                    .padding(.bottom, -4)
            }
        case .sunset: icon(SafetyIcon.sunset)
        case .myTimerOverdue, .friendTimerOverdue: icon(SafetyIcon.overdue)
        }
    }

    private func icon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: theme.drive ? 20 : 16, weight: .bold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(theme.palette.warningText)
            .frame(width: theme.drive ? 44 : 36, height: theme.drive ? 44 : 36)
            .background(Circle().fill(theme.palette.warning.opacity(0.18)))
            .accessibilityHidden(true)
    }

    @ViewBuilder private var texts: some View {
        let p = theme.palette
        VStack(alignment: .leading, spacing: 2) {
            switch alert {
            case let .friendStuck(s):
                Text("\(s.name) غرّز").saryText(theme.drive ? .headline : .callout, weight: .heavy).lineLimit(1)
                HStack(spacing: 6) {
                    if s.distanceMeters != nil || s.bearingDegrees != nil {
                        SaryDistanceLabel(meters: s.distanceMeters, bearing: s.bearingDegrees, style: .footnote)
                    }
                    Text(s.distanceMeters == nil ? "مكانه غير معروف" : (s.positionStale ? "آخر موقع معروف" : "مباشر"))
                        .saryText(.footnote, weight: .medium).foregroundStyle(p.textSecondary)
                }
                if let n = s.note { Text("«\(n)»").saryText(.footnote).foregroundStyle(p.textSecondary).lineLimit(1) }
                if let o = s.others { Text(o).saryNumber(.footnote, weight: .medium).foregroundStyle(p.textSecondary) }
            case let .sunset(title, detail):
                Text(title).saryText(theme.drive ? .headline : .callout, weight: .heavy).lineLimit(3)
                if !theme.drive { Text(detail).saryText(.footnote).foregroundStyle(p.textSecondary).lineLimit(2) }
            case let .myTimerOverdue(contact, due):
                Text("تأخرت عن وقت الرجوع").saryText(theme.drive ? .headline : .callout, weight: .heavy)
                Text(contact.isEmpty ? "كان \(SafetyFormat.clock(due)) • ما وصل تنبيه لأحد" : "كان \(SafetyFormat.clock(due)) • وصل تنبيه لـ\(contact)").saryText(.footnote).foregroundStyle(p.textSecondary).lineLimit(2)
            case let .friendTimerOverdue(name, _):
                Text("\(name) تأخر عن وقت رجوعه").saryText(.callout, weight: .heavy).lineLimit(2)
                Text("تطمّن عليه").saryText(.footnote).foregroundStyle(p.textSecondary)
            }
        }
    }

    @ViewBuilder private var buttons: some View {
        switch alert {
        case let .friendStuck(s):
            HStack(spacing: theme.space(.xs)) {
                ForEach(StuckReplyKind.allCases, id: \.self) { k in
                    Button { actions.reply(s.userId, k) } label: {
                        Text(k.button).saryText(theme.drive ? .callout : .subhead, weight: .bold).lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .buttonStyle(.sary(s.myReply == k ? .primary : .secondary, compact: !theme.drive))
                    .accessibilityAddTraits(s.myReply == k ? .isSelected : [])
                    .accessibilityIdentifier("stuck-reply-\(k.rawValue)")
                }
            }
            .padding(.trailing, theme.space(.s))
        case .myTimerOverdue:
            HStack(spacing: theme.space(.s)) {
                Button { actions.arrived() } label: { SaryButtonLabel(title: "وصلت", systemImage: SafetyIcon.arrived) }
                    .buttonStyle(.sary(.primary, compact: !theme.drive))
                    .accessibilityIdentifier("overdue-arrived")
                Button { actions.extend(60) } label: { SaryButtonLabel(title: "مدّد ساعة", systemImage: "plus") }
                    .buttonStyle(.sary(.secondary, compact: !theme.drive))
                    .accessibilityIdentifier("overdue-extend")
            }
            .padding(.trailing, theme.space(.s))
        default:
            EmptyView()
        }
    }
}

// MARK: - My stuck strip (top chrome)

/// While I am stuck: who answered, and «طلعت».
struct MyStuckStrip: View {
    var report: StuckReport
    var sharing: Bool
    var now: Date
    var clear: () -> Void
    var busy = false
    /// «اطلب إنجاد» (nil: not offered).
    var enjad: (() -> Void)? = nil
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        HStack(spacing: theme.space(.m)) {
            Image(systemName: SafetyIcon.stuck).font(.system(size: theme.drive ? 20 : 16, weight: .heavy))
            VStack(alignment: .leading, spacing: 0) {
                Text("غرّزت").saryText(.headline)
                Text("\(StuckLogic.summary(report))\(sharing ? "" : " • موقعك غير مُشارَك") • \(SaryFormat.elapsed(since: report.at, now: now))")
                    .saryNumber(.footnote, weight: .medium).opacity(0.92).lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: clear) {
                SaryButtonLabel(title: "طلعت", busy: busy)
                    .saryText(.callout, weight: .heavy)
                    .foregroundStyle(p.warningText)
                    .padding(.horizontal, theme.space(.l))
                    .frame(minHeight: theme.minTarget)
                    .background(Capsule().fill(p.chromeOpaque))
            }
            .buttonStyle(SaryPressStyle())
            .disabled(busy)
            .accessibilityIdentifier("stuck-clear")
            if let enjad {
                Button(action: enjad) {
                    Text("إنجاد").saryText(.callout, weight: .heavy)
                        .foregroundStyle(p.onEmergency)
                        .padding(.horizontal, theme.space(.m))
                        .frame(minHeight: theme.minTarget)
                        .background(Capsule().fill(p.emergency))
                }
                .buttonStyle(SaryPressStyle())
                .accessibilityLabel(Text("اطلب إنجاد (واتساب)"))
                .accessibilityIdentifier("stuck-enjad")
            }
        }
        .foregroundStyle(p.onWarning)
        .padding(.leading, theme.space(.l))
        .padding(.trailing, theme.space(.s))
        .padding(.vertical, theme.space(.s))
        .background(RoundedRectangle(cornerRadius: SaryRadius.l, style: .continuous).fill(p.warning))
        .saryShadow(.floating, theme)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("my-stuck-strip")
    }
}

// MARK: - Sheet section

/// «السلامة» in the participants tab: the return timer, «غرّزت», and the sunset line.
struct SafetySection: View {
    @ObservedObject var safety: SafetyController
    var now: Date
    var outingActive: Bool
    @Environment(\.sary) private var theme

    var body: some View {
        SarySection(title: "السلامة") {
            VStack(alignment: .leading, spacing: theme.space(.m)) {
                ReturnTimerCard(safety: safety, now: now)
                SaryDivider()
                stuckRow
                if let line = safety.sunsetLine {
                    SaryDivider()
                    HStack(spacing: theme.space(.m)) {
                        SaryRowIcon(systemImage: SafetyIcon.sunset, color: theme.palette.warning)
                        Text(line).saryNumber(.subhead, weight: .medium).foregroundStyle(theme.palette.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .accessibilityIdentifier("safety-sunset-line")
                }
            }
            .padding(.vertical, theme.space(.m))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("safety-section")
    }

    @ViewBuilder private var stuckRow: some View {
        let p = theme.palette
        if safety.stuckAvailability == .notDeployed {
            SaryBanner(text: "«غرّزت» غير متاح بعد • الخادم ما يدعمه للحين", tone: .info, systemImage: SafetyIcon.stuck)
        } else if let mine = safety.myStuck {
            VStack(alignment: .leading, spacing: theme.space(.s)) {
                HStack(spacing: theme.space(.m)) {
                    SaryRowIcon(systemImage: SafetyIcon.stuck, color: p.warning)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("غرّزت • \(SaryFormat.elapsed(since: mine.at, now: now))").saryText(.body, weight: .bold).foregroundStyle(p.textPrimary)
                        Text(StuckLogic.summary(mine)).saryNumber(.footnote).foregroundStyle(p.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(StuckLogic.replyLines(mine, name: safety.name, color: safety.color)) { r in
                    HStack(spacing: theme.space(.s)) {
                        SaryAvatar(name: r.name, color: r.color, size: 26)
                        Text(r.name).saryText(.subhead, weight: .medium).foregroundStyle(p.textPrimary)
                        Spacer()
                        Label(r.kind.label, systemImage: r.kind.systemImage)
                            .saryText(.subhead, weight: .bold)
                            .foregroundStyle(r.kind == .cant ? p.textSecondary : p.accentText)
                    }
                    .accessibilityElement(children: .combine)
                }
                Button { Task { await safety.clearStuck() } } label: { SaryButtonLabel(title: "طلعت", systemImage: SaryIcon.checkCircle, busy: safety.stuckBusy) }
                    .buttonStyle(.saryPrimary)
                    .disabled(safety.stuckBusy)
                    .accessibilityIdentifier("sheet-stuck-clear")
                Button { safety.openEnjad(.stuck) } label: { SaryButtonLabel(title: "اطلب إنجاد (واتساب)", systemImage: "message.fill") }
                    .buttonStyle(.sary(.secondary))
                    .accessibilityIdentifier("sheet-stuck-enjad")
            }
        } else {
            HStack(spacing: theme.space(.m)) {
                SaryRowIcon(systemImage: SafetyIcon.stuck, color: p.warning)
                VStack(alignment: .leading, spacing: 1) {
                    Text("غرّزت؟").saryText(.body, weight: .bold).foregroundStyle(p.textPrimary)
                    Text(safety.localOnly ? "يعلّم المكان على مسارك. ما فيه أحد معك يوصله التنبيه؛ اتصل بإنجاد أو ٩١١." : "ضغطة وحدة تنبّه الأصدقاء، ويشوفون مكانك إذا كنت تشارك موقعك.").saryText(.footnote).foregroundStyle(p.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button { safety.askStuck() } label: { SaryButtonLabel(title: "غرّزت", busy: safety.stuckBusy) }
                    .buttonStyle(.sary(.secondary, width: .hug, compact: true))
                    .disabled(!outingActive || safety.stuckBusy)
                    .accessibilityIdentifier("sheet-stuck")
            }
        }
    }
}

/// The timer card, one look per phase.
struct ReturnTimerCard: View {
    @ObservedObject var safety: SafetyController
    var now: Date
    @Environment(\.sary) private var theme
    @State private var confirmCancel = false

    var body: some View {
        let p = theme.palette
        VStack(alignment: .leading, spacing: theme.space(.s)) {
            switch safety.timerPhase {
            case .loading:
                if let e = safety.timerLoadError {
                    HStack {
                        header("مؤقت الرجوع", e)
                        Button("أعد المحاولة") { Task { await safety.load() } }.buttonStyle(.sary(.secondary, width: .hug, compact: true))
                    }
                } else {
                    HStack(spacing: theme.space(.s)) {
                        ProgressView().tint(p.accent)
                        Text("نتحقق من مؤقت الرجوع…").saryText(.subhead).foregroundStyle(p.textSecondary)
                    }
                }
            case .unavailable:
                SaryBanner(text: "مؤقت الرجوع غير متاح بعد • الخادم ما يدعمه للحين", tone: .info, systemImage: SafetyIcon.timer)
                    .accessibilityIdentifier("timer-unavailable")
            case .none:
                HStack(spacing: theme.space(.m)) {
                    header("مؤقت الرجوع", safety.localOnly ? (NewUI.enabled ? "منبّه على جوالك فقط. يذكّرك بوقت رجوعك، وما يوصل لأحد." : "منبّه على جوالك يذكّرك بوقت رجوعك. ما يوصل لأحد.") : "قل لأحد من أهلك متى ترجع. إذا تأخرت يوصله تنبيه.")
                    Button { safety.editorOpen = true } label: { SaryButtonLabel(title: "اضبط", systemImage: "plus") }
                        .buttonStyle(.sary(.primary, width: .hug, compact: true))
                        .accessibilityIdentifier("timer-set")
                }
            case let .armed(due, contact):
                header("ترجع \(SafetyFormat.dueLabel(due, now: now))", contact.isEmpty ? "\(SafetyFormat.remaining(until: due, now: now)) • على جوالك فقط" : "\(SafetyFormat.remaining(until: due, now: now)) • يتابعك \(contact)", numbers: true)
                if !safety.remindersAllowed {
                    SaryInlineMessage(text: "فعّل الإشعارات ليذكّرك التطبيق قبل الموعد بـ٣٠ و١٠ دقائق.", tone: .info)
                }
                buttons(arrivedKind: .secondary)
            case let .overdue(due, contact):
                header("تأخرت عن وقت الرجوع", contact.isEmpty ? "\(SafetyFormat.late(since: due, now: now)) • ما وصل تنبيه لأحد" : "\(SafetyFormat.late(since: due, now: now)) • وصل تنبيه لـ\(contact)", tone: p.warningText, numbers: true)
                buttons(arrivedKind: .primary)
            case let .arrived(contact):
                HStack(spacing: theme.space(.m)) {
                    header("وصلت بالسلامة", contact.isEmpty ? "الحمد لله على السلامة" : "وصل الخبر لـ\(contact)", icon: SafetyIcon.arrived, tone: p.liveText)
                    Button { safety.editorOpen = true } label: { Text("مؤقت جديد") }
                        .buttonStyle(.sary(.secondary, width: .hug, compact: true))
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("timer-card")
        .confirmationDialog("نلغي مؤقت الرجوع؟", isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("ألغِ المؤقت", role: .destructive) { Task { await safety.cancelTimer() } }
            Button("لا", role: .cancel) {}
        } message: { Text(safety.localOnly ? "يوقف المنبّه اللي على جوالك." : "الرابط اللي أرسلته يصير «أُلغي»، وما يوصل أي تنبيه.") }
    }

    private func header(_ title: String, _ sub: String, icon: String = SafetyIcon.timer, tone: Color? = nil, numbers: Bool = false) -> some View {
        HStack(spacing: theme.space(.m)) {
            SaryRowIcon(systemImage: icon, color: tone)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).saryText(.body, weight: .bold).foregroundStyle(tone ?? theme.palette.textPrimary)
                if numbers {
                    Text(sub).saryNumber(.footnote).foregroundStyle(theme.palette.textSecondary)
                } else {
                    Text(sub).saryText(.footnote).foregroundStyle(theme.palette.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func buttons(arrivedKind: SaryButtonKind) -> some View {
        HStack(spacing: theme.space(.s)) {
            Button { Task { await safety.arrived() } } label: { SaryButtonLabel(title: "وصلت", systemImage: SafetyIcon.arrived, busy: safety.timerBusy) }
                .buttonStyle(.sary(arrivedKind, compact: true))
                .disabled(safety.timerBusy)
                .accessibilityIdentifier("timer-arrived")
            if !safety.localOnly {
                Button { safety.offerShare() } label: { SaryButtonLabel(title: "شارك", systemImage: SaryIcon.share) }
                    .buttonStyle(.sary(.secondary, compact: true))
                    .accessibilityIdentifier("timer-share")
            }
            Menu {
                ForEach(ReturnTimerLogic.extendChoices, id: \.self) { m in
                    Button("مدّد \(SafetyFormat.span(minutes: m))") { Task { await safety.extend(minutes: m) } }
                }
                Button(safety.localOnly ? "غيّر الوقت" : "غيّر الوقت أو الاسم") { safety.editorOpen = true }
                Button("ألغِ المؤقت", role: .destructive) { confirmCancel = true }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(theme.palette.textPrimary)
                    .frame(width: max(theme.minTarget, 44), height: max(theme.minTarget, 44))
                    .background(RoundedRectangle(cornerRadius: SaryRadius.s, style: .continuous).fill(theme.palette.sunken))
            }
            .accessibilityLabel(Text("خيارات المؤقت"))
            .accessibilityIdentifier("timer-more")
        }
    }
}

// MARK: - Editor

/// «اضبط مؤقت الرجوع»: when, and who at home follows it. Says plainly what they will see.
struct ReturnTimerEditor: View {
    @ObservedObject var safety: SafetyController
    @Environment(\.sary) private var theme
    @State private var due = Date()
    @State private var contact = ""

    var body: some View {
        if NewUI.enabled { newBody } else { legacyBody }
    }

    /// New interface (Build 47, group C): the unified window title, the ONE primary «اضبط المنبّه» /
    /// «اضبط وأرسل الرابط» pinned at the bottom; a solo outing says «منبّه على جوالك فقط».
    private var newBody: some View {
        let n = safety.now()
        let p = theme.palette
        return SaryScreenScaffold(title: "مؤقت الرجوع", closeID: "timer-close", onClose: { safety.editorOpen = false }) {
          VStack(alignment: .leading, spacing: SarySpace.l.rawValue) {
            Text(safety.localOnly
                 ? "منبّه على جوالك فقط: يذكّرك بوقت رجوعك، وما يوصل لأحد. إذا تحتاج مساعدة اتصل بـ٩١١."
                 : "حدد متى ترجع، وأرسل رابطًا لأحد من أهلك. إذا ما ضغطت «وصلت» قبل الوقت، يوصله تنبيه.")
                .saryType(.body).foregroundStyle(p.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("timer-note")
            VStack(alignment: .leading, spacing: SarySpace.s.rawValue) {
                Text("وقت الرجوع").saryType(.headline).foregroundStyle(p.textPrimary)
                HStack(spacing: SarySpace.s.rawValue) {
                    ForEach([2, 3, 5], id: \.self) { h in
                        Button(SafetyFormat.span(minutes: h * 60)) { due = ReturnTimerLogic.clampDue(n.addingTimeInterval(TimeInterval(h * 3600)), now: n) }
                            .buttonStyle(.sary(.secondary, width: .hug, compact: true))
                            .accessibilityIdentifier("timer-quick-\(h)")
                    }
                }
                SaryListGroup {
Group {
                    VStack(alignment: .leading, spacing: SarySpace.s.rawValue) {
                        DatePicker("اليوم والساعة", selection: $due, in: n.addingTimeInterval(ReturnTimerLogic.minLead)...n.addingTimeInterval(ReturnTimerLogic.maxLead),
                                   displayedComponents: [.date, .hourAndMinute])
                            .datePickerStyle(.compact)
                            .environment(\.locale, Locale(identifier: "ar-SA@calendar=gregorian;numbers=arab"))
                            .saryType(.headline)
                            .tint(p.accent)
                            .accessibilityIdentifier("timer-due")
                        Text("\(SafetyFormat.dueLabel(due, now: n)) • \(SafetyFormat.remaining(until: due, now: n))")
                            .saryType(.numeric).foregroundStyle(p.accentText)
                    }
                }
.padding(SarySpace.m.rawValue).frame(maxWidth: .infinity, alignment: .leading)
}
            }
            if !safety.localOnly {
                SaryTextField(title: "اسم اللي يتابعك", placeholder: "مثل: أم فهد", text: $contact, id: "timer-contact", maxLength: ReturnTimerLogic.contactMax)
                VStack(alignment: .leading, spacing: SarySpace.s.rawValue) {
                    Text("وش يشوف من الرابط؟").saryType(.headline).foregroundStyle(p.textPrimary)
                    SaryListGroup {
Group {
                        VStack(alignment: .leading, spacing: SarySpace.m.rawValue) {
                            bullet("person.2.fill", "اسم الطلعة وأسماء اللي معك ووقت رجوعك.")
                            bullet("eye.slash.fill", "ما يشوف مواقعكم ما دام الوقت ما خلص.")
                            bullet(SafetyIcon.overdue, "إذا تأخرتوا يوصله تنبيه، ويظهر له آخر موقع معروف وقت التأخير لمن يشارك موقعه.")
                            bullet(SafetyIcon.arrived, "إذا ضغطت «وصلت» يوصله «وصلوا بالسلامة».")
                        }
                    }
.padding(SarySpace.m.rawValue).frame(maxWidth: .infinity, alignment: .leading)
}
                }
            }
            Text("نذكّرك قبل الموعد بـ٣٠ دقيقة و١٠ دقائق.").saryType(.caption).foregroundStyle(p.textTertiary)
          }
        } bottom: {
            Button { Task { await safety.arm(due: due, contact: contact) } } label: {
                SaryButtonLabel(title: safety.localOnly ? "اضبط المنبّه" : "اضبط وأرسل الرابط",
                                systemImage: safety.localOnly ? SafetyIcon.timer : SaryIcon.share, busy: safety.timerBusy, busyTitle: "جارٍ الضبط…")
            }
            .buttonStyle(SaryFoundationButtonStyle(kind: .primary))
            .disabled((!safety.localOnly && ReturnTimerLogic.cleanContact(contact) == nil) || safety.timerBusy)
            .accessibilityIdentifier("timer-save")
        }
        .onAppear { prefill(n) }
    }

    private func prefill(_ n: Date) {
        if let t = safety.timer, t.state == .armed || t.state == .overdue {
            contact = t.contact_name
            due = ReturnTimerLogic.clampDue(ReturnTimerLogic.due(t) ?? ReturnTimerLogic.suggestedDue(now: n), now: n)
        } else {
            due = ReturnTimerLogic.suggestedDue(now: n)
            if let last = safety.timer?.contact_name, !last.isEmpty { contact = last }
        }
    }

    private var legacyBody: some View {
        let n = safety.now()
        let p = theme.palette
        return ScrollView {
            VStack(alignment: .leading, spacing: theme.space(.l)) {
                HStack {
                    Text("مؤقت الرجوع").saryText(.title2).foregroundStyle(p.textPrimary)
                    Spacer()
                    SaryIconButton(systemImage: SaryIcon.close, label: "إغلاق") { safety.editorOpen = false }
                }
                Text(safety.localOnly
                     ? "حدد متى ترجع، ويذكّرك جوالك قبلها. هذا منبّه على جوالك بس: ما يوصل لأحد، فإذا تحتاج مساعدة اتصل بـ٩١١."
                     : "حدد متى ترجع، وأرسل رابطًا لأحد من أهلك. إذا ما ضغطت «وصلت» قبل الوقت، يوصله تنبيه.")
                    .saryText(.callout).foregroundStyle(p.textSecondary)

                VStack(alignment: .leading, spacing: theme.space(.s)) {
                    Text("وقت الرجوع").saryText(.footnote, weight: .bold).foregroundStyle(p.textSecondary)
                    HStack(spacing: theme.space(.s)) {
                        ForEach([2, 3, 5], id: \.self) { h in
                            Button(SafetyFormat.span(minutes: h * 60)) { due = ReturnTimerLogic.clampDue(n.addingTimeInterval(TimeInterval(h * 3600)), now: n) }
                                .buttonStyle(.sary(.secondary, width: .hug, compact: true))
                        }
                    }
                    DatePicker("اليوم والساعة", selection: $due, in: n.addingTimeInterval(ReturnTimerLogic.minLead)...n.addingTimeInterval(ReturnTimerLogic.maxLead),
                               displayedComponents: [.date, .hourAndMinute])
                        .datePickerStyle(.compact)
                        .environment(\.locale, Locale(identifier: "ar-SA@calendar=gregorian;numbers=arab"))
                        .saryText(.body, weight: .medium)
                        .tint(p.accent)
                        .accessibilityIdentifier("timer-due")
                    Text("\(SafetyFormat.dueLabel(due, now: n)) • \(SafetyFormat.remaining(until: due, now: n))")
                        .saryNumber(.subhead, weight: .bold).foregroundStyle(p.accentText)
                }
                .padding(theme.space(.m))
                .sarySurface(radius: SaryRadius.m)

                if !safety.localOnly {
                    SaryTextField(title: "اسم اللي يتابعك", placeholder: "مثل: أم فهد", text: $contact, id: "timer-contact", maxLength: ReturnTimerLogic.contactMax)

                    VStack(alignment: .leading, spacing: theme.space(.s)) {
                        Text("وش يشوف من الرابط؟").saryText(.headline).foregroundStyle(p.textPrimary)
                        bullet("person.2.fill", "اسم الطلعة وأسماء اللي معك ووقت رجوعك.")
                        bullet("eye.slash.fill", "ما يشوف مواقعكم ما دام الوقت ما خلص.")
                        bullet(SafetyIcon.overdue, "إذا تأخرتوا يوصله تنبيه، ويظهر له آخر موقع معروف وقت التأخير لمن يشارك موقعه.")
                        bullet(SafetyIcon.arrived, "إذا ضغطت «وصلت» يوصله «وصلوا بالسلامة».")
                    }
                    .padding(theme.space(.m))
                    .sarySurface(radius: SaryRadius.m)
                }

                Button { Task { await safety.arm(due: due, contact: contact) } } label: {
                    SaryButtonLabel(title: safety.localOnly ? "اضبط المنبّه" : "اضبط وأرسل الرابط",
                                    systemImage: safety.localOnly ? SafetyIcon.timer : SaryIcon.share, busy: safety.timerBusy, busyTitle: "جارٍ الضبط…")
                }
                .buttonStyle(.saryPrimary)
                .disabled((!safety.localOnly && ReturnTimerLogic.cleanContact(contact) == nil) || safety.timerBusy)
                .accessibilityIdentifier("timer-save")
                Text("نذكّرك قبل الموعد بـ٣٠ دقيقة و١٠ دقائق.").saryText(.footnote).foregroundStyle(p.textTertiary)
            }
            .padding(theme.space(.l))
        }
        .onAppear {
            if let t = safety.timer, t.state == .armed || t.state == .overdue {
                contact = t.contact_name
                due = ReturnTimerLogic.clampDue(ReturnTimerLogic.due(t) ?? ReturnTimerLogic.suggestedDue(now: n), now: n)
            } else {
                due = ReturnTimerLogic.suggestedDue(now: n)
                if let last = safety.timer?.contact_name, !last.isEmpty { contact = last }
            }
        }
    }

    private func bullet(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: theme.space(.m)) {
            Image(systemName: icon).foregroundStyle(theme.palette.accentText).frame(width: 22)
            Text(text).saryText(.subhead).foregroundStyle(theme.palette.textPrimary)
        }
    }
}

// MARK: - Prompts (attached once inside the live sheet)

/// The «غرّزت؟» confirm, the overdue prompt, the editor and the share sheet. Lives on a
/// background view in the live sheet (the top-most presentation over the map).
struct SafetyPrompts: View {
    @ObservedObject var safety: SafetyController
    @Environment(AppearanceSettings.self) private var appearance
    /// The live screen finished presenting: an alert asked for during its entrance waits until then.
    @State private var settled = false

    var body: some View {
        ZStack {
            Color.clear
                .confirmationDialog("غرّزت؟", isPresented: $safety.confirmStuck, titleVisibility: .visible) {
                    Button("إيه، غرّزت", role: .destructive) { Task { await safety.reportStuck() } }
                    Button("اطلب إنجاد (واتساب)") { safety.openEnjad(.stuck) }
                    Button("إلغاء", role: .cancel) {}
                } message: {
                    Text(safety.localOnly
                         ? "ما فيه أحد معك يوصله التنبيه؛ اتصل بإنجاد أو ٩١١. نعلّم المكان على مسارك بس."
                         : safety.isSharingNow()
                         ? "يوصل للأصدقاء في الطلعة إنك غرّزت، ويشوفون مكانك على الخريطة."
                         : "يوصل للأصدقاء في الطلعة إنك غرّزت. موقعك غير مُشارَك، فما يشوفون مكانك إلا إذا شاركته.")
                }
            Color.clear
                .alert("تأخرت عن وقت الرجوع", isPresented: Binding(get: { settled && safety.overduePrompt }, set: { safety.overduePrompt = $0 })) {
                    Button("وصلت") { Task { await safety.arrived() } }
                    Button("مدّد ساعة") { Task { await safety.extend(minutes: 60) } }
                    Button("مدّد ٣٠ دقيقة") { Task { await safety.extend(minutes: 30) } }
                    Button("لاحقًا", role: .cancel) {}
                } message: {
                    Text(overdueMessage)
                }
            Color.clear
                .alert("تنبيه", isPresented: Binding(get: { safety.errorText != nil }, set: { if !$0 { safety.errorText = nil } })) {
                    Button("حسنًا", role: .cancel) {}
                } message: { Text(safety.errorText ?? "") }
            Color.clear
                .sheet(isPresented: $safety.editorOpen) {
                    ReturnTimerEditor(safety: safety)
                        .saryPresented(appearance)
                        .presentationDetents([.large])
                }
            Color.clear
                .sheet(item: Binding(get: { safety.shareText.map(ShareText.init) }, set: { if $0 == nil { safety.shareText = nil } })) { s in
                    ShareSheet(items: [s.text]).presentationDetents([.medium, .large])
                }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            settled = true
        }
    }

    private var overdueMessage: String {
        if case let .overdue(_, contact) = safety.timerPhase, !contact.isEmpty {
            return "وصل تنبيه لـ\(contact). إذا وصلت اضغط «وصلت»، أو مدّد الوقت."
        }
        return "إذا وصلت اضغط «وصلت»، أو مدّد الوقت."
    }
}

private struct ShareText: Identifiable { let text: String; var id: String { text } }
