import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if let session = model.session {
                LiveOutingView(session: session)
            } else if model.identity == nil {
                OnboardingView()
            } else {
                OutingsListView()
            }
        }
        .sheet(item: Binding(get: { model.pendingInvite.map(InviteToken.init) }, set: { model.pendingInvite = $0?.id })) { inv in
            JoinView(token: inv.id)
        }
        .alert("تنبيه", isPresented: Binding(get: { model.errorText != nil }, set: { if !$0 { model.errorText = nil } })) {
            Button("حسنًا", role: .cancel) {}
        } message: {
            Text(model.errorText ?? "")
        }
    }
}

struct InviteToken: Identifiable { let id: String }

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
                        Text("طلعات البر مع أصحابك: كل سيارة على الخريطة بلونها، وموقعك يبقى مشتركًا ولو قفلت الشاشة — فقط في الطلعة التي تختار المشاركة فيها.")
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
