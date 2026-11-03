import SwiftUI

struct OutingsListView: View {
    @EnvironmentObject private var model: AppModel
    @State private var creating = false
    @State private var joining = false
    @State private var editingProfile = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { creating = true } label: { Label("طلعة جديدة", systemImage: "plus.circle.fill") }
                        .accessibilityIdentifier("list.create")
                    Button { joining = true } label: { Label("انضم برابط دعوة", systemImage: "link") }
                        .accessibilityIdentifier("list.join")
                }
                if !model.current.isEmpty {
                    Section("طلعاتك الآن") {
                        ForEach(model.current) { o in
                            Button { model.open(o.id) } label: { OutingRow(o: o) }
                        }
                    }
                }
                if !model.history.isEmpty {
                    Section("السابقة") {
                        ForEach(model.history) { o in OutingRow(o: o).foregroundStyle(.secondary) }
                    }
                }
                if model.current.isEmpty && model.history.isEmpty {
                    Section {
                        Text("لا توجد طلعات بعد. أنشئ طلعة وشارك رابطها، أو افتح رابط دعوة وصلك.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("الطلعات")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { editingProfile = true } label: { Image(systemName: "person.crop.circle") }
                        .accessibilityLabel("ملفي")
                }
            }
            .refreshable { await model.refresh() }
            .task { await model.refresh() }
            .sheet(isPresented: $creating) { CreateOutingView() }
            .sheet(isPresented: $joining) { PasteInviteView() }
            .sheet(isPresented: $editingProfile) { ProfileView() }
        }
    }
}

struct OutingRow: View {
    let o: OutingSummary
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(o.name).font(.headline)
                Text("\(ArabicFormat.number(Double(o.member_count))) مشارك · \(o.role == "owner" ? "صاحب الطلعة" : "عضو")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            StatusChip(status: o.status)
        }
    }
}

struct StatusChip: View {
    let status: OutingStatus
    var body: some View {
        let (t, c): (String, Color) = {
            switch status {
            case .created: return ("لم تبدأ", .gray)
            case .active: return ("جارية", Theme.accent)
            case .paused: return ("متوقفة مؤقتًا", Theme.amber)
            case .ended: return ("انتهت", .secondary)
            }
        }()
        Text(t).font(.caption.bold()).padding(.horizontal, 8).padding(.vertical, 3)
            .background(c.opacity(0.15), in: Capsule()).foregroundStyle(c)
    }
}

struct CreateOutingView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                TextField("اسم الطلعة، مثل: كشتة الثمامة", text: $name)
                    .accessibilityIdentifier("create.name")
                Section {
                    Button {
                        busy = true
                        Task {
                            if await model.createOuting(name: name) != nil { dismiss() }
                            busy = false
                        }
                    } label: { HStack { Spacer(); if busy { ProgressView() } else { Text("أنشئ الطلعة").bold() }; Spacer() } }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                } footer: {
                    Text("بعد الإنشاء تشارك رابط الدعوة مع أصحابك، ثم تبدأ الطلعة متى ما تحركتم.")
                }
            }
            .navigationTitle("طلعة جديدة")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("إلغاء") { dismiss() } } }
        }
    }
}

struct PasteInviteView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var invalid = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("الصق رابط الدعوة هنا", text: $text, axis: .vertical)
                        .environment(\.layoutDirection, .leftToRight)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("paste.field")
                    if UIPasteboard.general.hasURLs || UIPasteboard.general.hasStrings {
                        Button("لصق من الحافظة") { text = UIPasteboard.general.string ?? UIPasteboard.general.url?.absoluteString ?? "" }
                    }
                } footer: {
                    if invalid { Text("هذا ليس رابط دعوة صحيحًا.").foregroundStyle(.red) }
                }
                Button("متابعة") {
                    if let t = InviteLink.token(fromPasted: text) {
                        dismiss()
                        model.pendingInvite = t
                    } else { invalid = true }
                }
                .disabled(text.isEmpty)
            }
            .navigationTitle("انضم برابط")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("إلغاء") { dismiss() } } }
        }
    }
}

struct JoinView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let token: String
    @State private var preview: InvitePreview?
    @State private var error: String?
    @State private var name = ""
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                if let p = preview {
                    Section {
                        Text(p.name).font(.title2.bold())
                        Text("يدعوك \(p.owner_name) · \(ArabicFormat.number(Double(p.member_count))) مشارك")
                            .foregroundStyle(.secondary)
                        StatusChip(status: p.status)
                    }
                    if model.identity == nil {
                        Section("اسمك") { TextField("اسمك كما يراه أصحابك", text: $name) }
                    }
                    Section {
                        Button {
                            busy = true
                            Task {
                                if model.identity == nil { await model.createIdentity(name: name, phone: "") }
                                if model.identity != nil { await model.join(token) }
                                busy = false
                                if model.pendingInvite == nil { dismiss() }
                            }
                        } label: { HStack { Spacer(); if busy { ProgressView() } else { Text("انضم").bold() }; Spacer() } }
                            .disabled(busy || p.status == .ended || (model.identity == nil && name.trimmingCharacters(in: .whitespaces).isEmpty))
                    } footer: {
                        Text("الانضمام لا يشارك موقعك. تختار المشاركة بنفسك داخل الطلعة.")
                    }
                } else if let error {
                    Text(error).foregroundStyle(.red)
                } else {
                    HStack { Spacer(); ProgressView(); Spacer() }
                }
            }
            .navigationTitle("دعوة طلعة")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("إلغاء") { model.pendingInvite = nil; dismiss() } } }
            .task {
                do { preview = try await model.preview(token) } catch let e as OutingAPIError { error = e.arabic } catch { self.error = "حدث خطأ." }
            }
        }
    }
}

struct ProfileView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var phone = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("الاسم", text: $name)
                TextField("رقم الجوال (اختياري)", text: $phone)
                    .keyboardType(.phonePad)
                    .environment(\.layoutDirection, .leftToRight)
                Section {
                    Button("حفظ") { Task { if await model.updateProfile(name: name, phone: phone) { dismiss() } } }
                }
                Section {
                    Button("تسجيل الخروج من هذا الجهاز", role: .destructive) { model.signOut(); dismiss() }
                } footer: {
                    Text("الخروج يوقف أي مشاركة ويحذف هويتك من هذا الجهاز.")
                }
            }
            .navigationTitle("ملفي")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("إغلاق") { dismiss() } } }
            .onAppear {
                name = model.identity?.user.display_name ?? ""
                phone = model.identity?.user.phone ?? ""
            }
        }
    }
}
