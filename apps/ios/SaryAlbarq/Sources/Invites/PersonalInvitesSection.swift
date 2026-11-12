import SwiftUI
import UIKit

/// «ادعُ أصدقاءك» — personal invites: pick a contact (or type name + number), send
/// that person their own link (WhatsApp / SMS / share), and see per person
/// «أُرسلت / فتحها / انضم / لم يفتحها». Used in the live trip's «المجموعة» tab and
/// at the end of «طلعة جديدة». `legacy` is the old open-link card, shown only
/// while the leader keeps «الرابط المفتوح» on (for build 9–11 phones).
struct PersonalInvitesSection<Legacy: View>: View {
    @ObservedObject var model: PersonalInvitesModel
    var canLead: Bool
    var ended: Bool = false
    @ViewBuilder var legacy: Legacy
    @Environment(\.sary) private var theme
    @State private var picking = false
    @State private var adding: PickedContact?
    @State private var confirmRevoke: PersonalInvite?

    var body: some View {
        let p = theme.palette
        VStack(alignment: .leading, spacing: theme.space(.m)) {
            if !canLead {
                SaryStateView(kind: .empty(title: "الدعوات عند أمير الطلعة",
                                           message: "كل دعوة لشخص واحد باسمه. اطلب من أمير الطلعة يدعو من تبي.", systemImage: "person.badge.plus"))
            } else {
                Text("كل دعوة لشخص واحد تعرفه: يظهر في الطلعة بالاسم اللي حفظته له، والرابط يدخله هو فقط مرة وحدة.")
                    .saryText(.footnote).foregroundStyle(p.textSecondary).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("invite.personal.explainer")
                if !ended {
                    Button {
                        if let s = ContactPicker.stub { adding = s } else { picking = true }
                    } label: { SaryButtonLabel(title: "اختر من جهات الاتصال", systemImage: "person.crop.circle.badge.plus") }
                        .buttonStyle(.sary(.primary))
                        .accessibilityIdentifier("invite.pickContact")
                    Button { adding = PickedContact(name: "", phone: nil) } label: {
                        SaryButtonLabel(title: "اكتب الاسم والرقم", systemImage: "keyboard")
                    }
                    .buttonStyle(.sary(.secondary))
                    .accessibilityIdentifier("invite.manual")
                }
                if let e = model.errorText { SaryInlineMessage(text: e, tone: .error) }
                if model.invites.isEmpty {
                    Text("ما دعيت أحد بعد.").saryText(.footnote).foregroundStyle(p.textTertiary)
                        .accessibilityIdentifier("invite.list.empty")
                } else {
                    VStack(spacing: 0) {
                        ForEach(model.invites) { i in
                            row(i)
                            if i.id != model.invites.last?.id { SaryDivider() }
                        }
                    }
                    .sarySurface(radius: SaryRadius.m)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("invite.list")
                }
                if !ended {
                    Toggle(isOn: Binding(get: { model.openLinks ?? true }, set: { on in Task { await model.setOpenLinks(on) } })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("رابط مفتوح للنسخ القديمة").saryText(.callout, weight: .bold).foregroundStyle(p.textPrimary)
                            Text("يدخل أي أحد معه الرابط باسم يكتبه بنفسه. خلّه مقفل إلا للضرورة.")
                                .saryText(.caption).foregroundStyle(p.textSecondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .disabled(model.busy.contains("open"))
                    .accessibilityIdentifier("invite.openLinks")
                    if model.openLinks ?? true { legacy }
                }
            }
        }
        .sheet(isPresented: $picking) {
            ContactPicker { c in
                picking = false
                if let c { DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { adding = c } }
            }
            .ignoresSafeArea()
        }
        .sheet(item: Binding(get: { adding.map(IdentifiedContact.init) }, set: { adding = $0?.contact })) { c in
            AddPersonalInviteSheet(model: model, contact: c.contact) { adding = nil }
                .presentationDetents([.large])
        }
        .sheet(item: $model.draft) { d in
            SendPersonalInviteSheet(draft: d) { model.draft = nil }
                .presentationDetents([.medium, .large])
        }
        .confirmationDialog("ألغِ دعوة \(confirmRevoke?.invitee_name ?? "")؟", isPresented: Binding(get: { confirmRevoke != nil }, set: { if !$0 { confirmRevoke = nil } }),
                            titleVisibility: .visible) {
            Button("ألغِ الدعوة", role: .destructive) { if let i = confirmRevoke { Task { await model.revoke(i) } } }
            Button("إلغاء", role: .cancel) {}
        } message: { Text("الرابط يتوقف فورًا. تقدر ترسل له دعوة جديدة متى ما بغيت.") }
        .task { await model.load() }
    }

    private func row(_ i: PersonalInvite) -> some View {
        let p = theme.palette
        let busy = model.busy.contains(i.id)
        return HStack(spacing: theme.space(.m)) {
            VStack(alignment: .leading, spacing: 3) {
                Text(i.invitee_name).saryText(.bodyStrong).foregroundStyle(p.textPrimary).lineLimit(1)
                HStack(spacing: 6) {
                    SaryInviteStatusPill(text: PersonalInviteStatusText.label(i), tone: PersonalInviteStatusText.tone(i))
                        .accessibilityIdentifier("invite.status.\(i.status.rawValue)")
                    if let l4 = i.phone_last4 {
                        Text("•••• \(SaryFormat.digits(l4))").saryNumber(.caption, weight: .medium).foregroundStyle(p.textSecondary)
                            .environment(\.layoutDirection, .leftToRight)
                    }
                }
            }
            Spacer(minLength: 4)
            if busy { ProgressView() }
            if !ended {
                Menu {
                    if i.status == .sent || i.status == .opened, model.link(for: i) != nil {
                        Button { model.share(i) } label: { Label("أرسل الرابط", systemImage: SaryIcon.share) }
                    }
                    if PersonalInviteStatusText.canResend(i) {
                        Button { Task { await model.resend(i) } } label: { Label("أرسل دعوة جديدة", systemImage: "arrow.triangle.2.circlepath") }
                    }
                    if PersonalInviteStatusText.canRevoke(i) {
                        Button(role: .destructive) { confirmRevoke = i } label: { Label("ألغِ الدعوة", systemImage: "xmark.circle") }
                    }
                    if i.status == .joined {
                        Text("انضم بهذا الاسم")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.system(size: 22)).foregroundStyle(p.accentText)
                        .frame(width: theme.minTarget, height: theme.minTarget)
                }
                .disabled(busy)
                .accessibilityLabel(Text("خيارات دعوة \(i.invitee_name)"))
                .accessibilityIdentifier("invite.row.menu")
            }
        }
        .padding(.vertical, theme.space(.s))
        .padding(.horizontal, theme.space(.m))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("invite.row")
    }
}

extension PersonalInvitesSection where Legacy == EmptyView {
    init(model: PersonalInvitesModel, canLead: Bool, ended: Bool = false) {
        self.init(model: model, canLead: canLead, ended: ended) { EmptyView() }
    }
}

private struct IdentifiedContact: Identifiable {
    var contact: PickedContact
    var id: String { contact.name + "|" + (contact.phone ?? "") }
}

/// Small status capsule for an invite row.
struct SaryInviteStatusPill: View {
    var text: String
    var tone: SaryTone
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        let color: Color = {
            switch tone {
            case .success: return p.liveText
            case .warning: return p.warningText
            case .error: return p.emergency
            case .info: return p.accentText
            }
        }()
        Text(text)
            .saryText(.caption, weight: .bold)
            .foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.12)))
    }
}

// MARK: - Confirm who, then create

struct AddPersonalInviteSheet: View {
    @ObservedObject var model: PersonalInvitesModel
    var contact: PickedContact
    var done: () -> Void
    @Environment(\.sary) private var theme
    @State private var name = ""
    @State private var phone = ""

    var body: some View {
        let p = theme.palette
        let phoneOK = phone.trimmingCharacters(in: .whitespaces).isEmpty || KSAPhone.normalize(phone) != nil
        SaryPage(title: "دعوة شخصية", subtitle: model.outingName, close: done) {
            SaryTextField(title: "اسمه كما يظهر في الطلعة", placeholder: "مثال: فهد أخوي", text: $name, id: "invite.add.name", maxLength: ServerRules.nameMax,
                          help: "هذا الاسم يشوفه الكل في الطلعة، وما يقدر هو يغيّره. يقدر يضيف لقبه بجانبه.")
            SaryTextField(title: "رقم جواله", placeholder: "05XXXXXXXX", text: $phone, id: "invite.add.phone", keyboard: .phonePad,
                          state: phoneOK ? .normal : .error("اكتب رقم جوال صحيح، مثل 05XXXXXXXX."),
                          help: "نرسل له الرابط على واتساب أو رسالة. الرقم يبقى في جوالك؛ الخادم يحفظ آخر ٤ أرقام فقط.")
            if let e = model.errorText { SaryInlineMessage(text: e, tone: .error) }
            Button {
                Task {
                    if await model.invite(name: name, phone: phone) != nil { done() }
                }
            } label: {
                SaryButtonLabel(title: "أنشئ دعوته", systemImage: "paperplane.fill", busy: model.busy.contains("new"), busyTitle: "ننشئ الدعوة…")
            }
            .buttonStyle(.sary(.primary))
            .disabled(model.busy.contains("new") || name.trimmingCharacters(in: .whitespaces).isEmpty || !phoneOK)
            .accessibilityIdentifier("invite.add.create")
            Label("الرابط له وحده: أول من يفتحه ينضم باسم «\(name.isEmpty ? "…" : name)»، وبعدها ما يدخل به أحد غيره.", systemImage: "person.fill.checkmark")
                .saryText(.footnote).foregroundStyle(p.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
        .onAppear {
            name = contact.name
            phone = contact.phone.map { KSAPhone.normalize($0).map(KSAPhone.display) ?? $0 } ?? ""
            model.errorText = nil
        }
    }
}

// MARK: - Send it to that person

struct SendPersonalInviteSheet: View {
    var draft: InviteDraft
    var done: () -> Void
    @Environment(\.sary) private var theme
    @Environment(\.openURL) private var openURL
    @State private var sharing = false
    @State private var copied = false

    var body: some View {
        let p = theme.palette
        SaryPage(title: "أرسل لـ\(draft.invite.invitee_name)", close: done) {
            if let phone = draft.phone {
                Text(SaryFormat.digits(KSAPhone.display(phone))).saryNumber(.callout, weight: .bold).foregroundStyle(p.textSecondary)
                    .environment(\.layoutDirection, .leftToRight)
                    .accessibilityIdentifier("invite.send.phone")
            }
            Button { if let u = PersonalInviteText.whatsAppURL(phone: draft.phone, text: draft.text) { openURL(u) } } label: {
                SaryButtonLabel(title: "أرسل في واتساب", systemImage: "message.fill")
            }
            .buttonStyle(.sary(.primary))
            .accessibilityIdentifier("invite.send.whatsapp")
            if let phone = draft.phone {
                Button { if let u = PersonalInviteText.smsURL(phone: phone, text: draft.text) { openURL(u) } } label: {
                    SaryButtonLabel(title: "أرسل رسالة نصية", systemImage: "bubble.left.fill")
                }
                .buttonStyle(.sary(.secondary))
                .accessibilityIdentifier("invite.send.sms")
            }
            HStack(spacing: theme.space(.s)) {
                Button { sharing = true } label: { SaryButtonLabel(title: "مشاركة", systemImage: SaryIcon.share) }
                    .buttonStyle(.sary(.secondary))
                    .accessibilityIdentifier("invite.send.share")
                Button {
                    UIPasteboard.general.string = draft.text
                    copied = true
                } label: { SaryButtonLabel(title: copied ? "نُسخت" : "انسخ الرسالة", systemImage: copied ? SaryIcon.check : SaryIcon.copy) }
                    .buttonStyle(.sary(.secondary))
                    .accessibilityIdentifier("invite.send.copy")
            }
            SarySection(title: "نص الدعوة") {
                Text(draft.text).saryText(.footnote).foregroundStyle(p.textPrimary).fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, theme.space(.s))
                    .accessibilityIdentifier("invite.send.message")
            }
            Text("أرسله له هو فقط. لو وصل لغيره بالغلط، ألغِ الدعوة وأرسل له دعوة جديدة.")
                .saryText(.footnote).foregroundStyle(p.textTertiary).fixedSize(horizontal: false, vertical: true)
            Button("تم", action: done).buttonStyle(.sary(.plain)).accessibilityIdentifier("invite.send.done")
        }
        .sheet(isPresented: $sharing) { ShareSheet(items: [draft.text]).presentationDetents([.medium, .large]) }
    }
}

// MARK: - In the live trip («المجموعة»)

/// Owns the per-trip model and keeps it in step with the trip: the snapshot's
/// list for leaders, and a refetch whenever someone joins.
struct LivePersonalInvites<Legacy: View>: View {
    @ObservedObject var session: OutingSession
    @ViewBuilder var legacy: Legacy
    @StateObject private var model: PersonalInvitesModel

    init(session: OutingSession, @ViewBuilder legacy: () -> Legacy) {
        self.session = session
        self.legacy = legacy()
        let snap = session.view?.snapshot
        _model = StateObject(wrappedValue: PersonalInvitesModel(
            outingId: session.id, outingName: snap?.outing.name ?? "", api: session.isLocal ? nil : session.api, isDemo: session.isDemo,
            initial: snap?.personal_invites, openLinks: snap?.invite?.open_links ?? (session.isDemo ? false : nil)))
    }

    var body: some View {
        let v = session.view
        if PersonalInvitesSupport.serverHasPersonal(loaded: v != nil, invite: v?.snapshot.invite, personalInvites: v?.snapshot.personal_invites,
                                                  iLead: v?.iLead == true, isDemo: session.isLocal), !model.serverLacksPersonal {
            PersonalInvitesSection(model: model, canLead: v?.iLead == true, ended: v?.status == .ended) { legacy }
                .onChange(of: v?.members.count ?? 0) { _, _ in Task { await model.load() } }
        } else {
            /* Older server (no «دعوة شخصية» yet): exactly the build-11 open-link card, no error. */
            legacy
        }
    }

}

/// «دعوة شخصية» against an older production server (no PR #61 routes yet).
enum PersonalInvitesSupport {
    /// A leader's snapshot from a server with personal invites always carries `invite.open_links`
    /// (and `personal_invites`); an older server sends neither. Members never get either, so they
    /// keep the new «الدعوات عند أمير الرحلة» state.
    static func serverHasPersonal(loaded: Bool, invite: InviteState?, personalInvites: [PersonalInvite]?, iLead: Bool, isDemo: Bool) -> Bool {
        if isDemo || !iLead || !loaded { return true }
        return invite?.open_links != nil || personalInvites != nil
    }
}
