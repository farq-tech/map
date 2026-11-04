import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(AppearanceSettings.self) private var appearance

    var body: some View {
        Group {
            if let session = model.session {
                LiveOutingHost(session: session, model: model, appearance: appearance)
                    .id(session.id)
            } else if model.identity == nil {
                OnboardingView()
            } else {
                OutingsListView()
            }
        }
        .sheet(item: Binding(get: { model.pendingInvite.map(InviteToken.init) }, set: { model.pendingInvite = $0?.id })) { inv in
            JoinView(token: inv.id).rtl()
        }
        .alert("تنبيه", isPresented: Binding(get: { model.errorText != nil }, set: { if !$0 { model.errorText = nil } })) {
            Button("حسنًا", role: .cancel) {}
        } message: {
            Text(model.errorText ?? "")
        }
    }
}

struct InviteToken: Identifiable { let id: String }

/// Owns the live screen's controller for as long as that outing is open.
struct LiveOutingHost: View {
    @StateObject private var controller: LiveOutingController

    init(session: OutingSession, model: AppModel, appearance: AppearanceSettings) {
        _controller = StateObject(wrappedValue: {
            let c = LiveOutingController(session: session, location: model.location, appearance: appearance)
            c.onExit = { [weak model] in model?.closeSession() }
            c.savePhone = { [weak model, weak c] phone in
                guard let model else { return }
                Task {
                    let ok = await model.updateProfile(name: model.identity?.user.display_name ?? "", phone: phone ?? "")
                    if ok { c?.toast("تم حفظ رقمك") }
                }
            }
            return c
        }())
    }

    var body: some View { LiveOutingScreen(controller: controller) }
}

struct OnboardingView: View {
    @EnvironmentObject private var model: AppModel
    @State private var name = ""
    @State private var phone = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("سَرى البارق").font(.largeTitle.bold()).foregroundStyle(Theme.ink)
                        Text("طلعات البر مع أصحابك: كل سيارة على الخريطة بلونها. موقعك لا يُشارك إلا في الطلعة التي تختار المشاركة فيها، والتطبيق مفتوح أمامك.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                }
                Section {
                    TextField("اسمك كما يراه أصحابك", text: $name)
                        .textContentType(.nickname)
                        .accessibilityIdentifier("onboarding.name")
                    TextField("رقم الجوال (اختياري)", text: $phone)
                        .keyboardType(.phonePad)
                        .textContentType(.telephoneNumber)
                        .environment(\.layoutDirection, .leftToRight)
                        .accessibilityIdentifier("onboarding.phone")
                } footer: {
                    Text("الرقم يظهر لأعضاء طلعاتك فقط، ليتصلوا بك أو يراسلوك واتساب. يمكنك حذفه لاحقًا.")
                }
                Section {
                    Button {
                        Task { await model.createIdentity(name: name, phone: phone) }
                    } label: {
                        HStack {
                            Spacer()
                            if model.loading { ProgressView() } else { Text("ابدأ").bold() }
                            Spacer()
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || model.loading)
                    .accessibilityIdentifier("onboarding.start")
                }
            }
            .navigationTitle("مرحبًا")
        }
    }
}

extension View {
    /// Sheets and dialogs are new presentations and do not reliably inherit the
    /// root's layout direction, so every presented screen asks for RTL itself.
    func rtl() -> some View {
        environment(\.layoutDirection, .rightToLeft).environment(\.locale, Locale(identifier: "ar"))
    }
}
