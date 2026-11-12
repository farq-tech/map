import SwiftUI

/// «ترددات» — the walkie-talkie's channels on the live screen.
///
///   * `PTTChannelChip` beside the talk button: «تردد ٣» (a lock for a private one,
///     a dot for an invitation not seen yet). Tap → `PTTChannelSheet`.
///   * `PTTChannelSheet`: a channel knob (١…٥) that clicks into place, the five public
///     channels and the private ones I am in — who is listening on each and who is
///     talking — and, for the trip leader, «+ تردد خاص».
///   * `PTTPrivateChannelEditor`: name + the members who may listen (the server enforces it).
struct PTTChannelChip: View {
    @ObservedObject var walkie: OutingWalkieTalkie
    var open: () -> Void
    @Environment(\.sary) private var theme

    var body: some View {
        let c = walkie.currentChannel
        Button(action: open) {
            HStack(spacing: 5) {
                Image(systemName: c?.isPrivate == true ? "lock.fill" : "dot.radiowaves.left.and.right")
                    .font(.system(size: 12, weight: .bold))
                    .environment(\.layoutDirection, .leftToRight)
                Text(PTTChannels.chipLabel(c))
                    .font(.system(.footnote, design: .rounded).weight(.semibold))
                    .lineLimit(1)
                    .frame(maxWidth: 120)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .foregroundStyle(c?.isPrivate == true ? theme.palette.accentText : theme.palette.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .saryGlass(Capsule(), role: .control, interactive: true)
            .overlay(alignment: .topTrailing) {
                if walkie.pendingInvite != nil {
                    Circle().fill(theme.palette.accent).frame(width: 9, height: 9).offset(x: 2, y: -2)
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(.plain)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .accessibilityIdentifier("ptt-channel-chip")
        .accessibilityLabel(Text("التردد: \(PTTChannels.chipLabel(c))"))
        .accessibilityValue(Text(walkie.pendingInvite != nil ? "دعوة جديدة إلى تردد خاص" : ""))
        .accessibilityHint(Text("اضغط لتغيّر التردد"))
    }
}

struct PTTChannelSheet: View {
    struct Person: Identifiable, Equatable {
        var id: String
        var name: String
    }

    @ObservedObject var walkie: OutingWalkieTalkie
    var members: [Person]
    var me: String
    var close: () -> Void

    @Environment(\.sary) private var theme
    @State private var editing: Editing?
    @State private var error: String?

    enum Editing: Identifiable {
        case create
        case edit(PTTChannelInfo)
        var id: String {
            switch self {
            case .create: return "create"
            case let .edit(c): return "edit:\(c.id)"
            }
        }
    }

    private var publicChannels: [PTTChannelInfo] { walkie.channels.filter { !$0.isPrivate } }
    private var privateChannels: [PTTChannelInfo] { walkie.channels.filter(\.isPrivate) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    PTTChannelKnob(selection: PTTChannels.isPublic(walkie.channelId) ? walkie.channelId : nil,
                                   busy: Set(publicChannels.filter { $0.talker != nil }.map(\.id)),
                                   select: { walkie.switchChannel($0) })
                        .listRowBackground(Color.clear)
                        .frame(maxWidth: .infinity)
                } footer: {
                    Text("تسمع ترددًا واحدًا وتتكلم فيه. كل تردد يتكلم فيه شخص واحد في نفس الوقت.")
                }

                Section("الترددات العامة") {
                    ForEach(publicChannels) { c in row(c) }
                }

                if !privateChannels.isEmpty || walkie.canCreatePrivate {
                    Section {
                        ForEach(privateChannels) { c in row(c) }
                        if walkie.canCreatePrivate {
                            Button {
                                editing = .create
                            } label: {
                                Label("تردد خاص", systemImage: "plus.circle.fill")
                                    .font(.body.weight(.semibold))
                            }
                            .disabled(privateChannels.count >= PTTChannels.maxPrivate)
                            .accessibilityIdentifier("ptt-channel-create")
                            .accessibilityHint(Text("افتح ترددًا لا يسمعه إلا من تدعوهم"))
                        }
                    } header: {
                        Text("ترددات خاصة")
                    } footer: {
                        Text(walkie.canCreatePrivate
                             ? "التردد الخاص لا يسمعه ولا يراه إلا من تدعوهم — حتى ٥ ترددات في الطلعة."
                             : "يفتحها أمير الطلعة لمن يدعوهم فقط.")
                    }
                }

                /* «رسالة صوتية»: this channel's recent notes, ▶︎ each (after the channels, so the knob and rows stay where they were). */
                if let vn = VoiceNoteCenters.of(walkie.outingId) {
                    VoiceNoteSection(center: vn)
                }
            }
            .navigationTitle("الترددات")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("خلاص", action: close).accessibilityIdentifier("ptt-channels-done")
                }
            }
            .sheet(item: $editing) { e in
                PTTPrivateChannelEditor(walkie: walkie, members: members.filter { $0.id != me }, editing: e, done: { editing = nil })
                    .presentationDetents([.large])
            }
            .alert("الترددات", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("حسنًا", role: .cancel) {}
            } message: { Text(error ?? "") }
        }
        .accessibilityIdentifier("ptt-channels-sheet")
        .onAppear { walkie.invitationSeen() }
    }

    @ViewBuilder
    private func row(_ c: PTTChannelInfo) -> some View {
        let on = c.id == walkie.channelId
        Button {
            walkie.switchChannel(c.id)
        } label: {
            HStack(spacing: theme.space(.s)) {
                ZStack {
                    Circle().fill(on ? theme.palette.accent : theme.palette.textSecondary.opacity(0.15))
                        .frame(width: 34, height: 34)
                    if c.isPrivate {
                        Image(systemName: "lock.fill").font(.system(size: 14, weight: .bold))
                            .foregroundStyle(on ? theme.palette.onAccent : theme.palette.textPrimary)
                    } else {
                        Text(PTTChannels.arabicDigits(c.id)).font(.system(.headline, design: .rounded))
                            .foregroundStyle(on ? theme.palette.onAccent : theme.palette.textPrimary)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.name).font(.body.weight(on ? .semibold : .regular)).foregroundStyle(theme.palette.textPrimary)
                    if let t = c.talker {
                        Label("يتكلم: \(name(t.userId) ?? t.name)", systemImage: "waveform")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(theme.palette.accentText)
                    } else {
                        Text(PTTChannels.listenersLine(c, me: me, name: name))
                            .font(.caption)
                            .foregroundStyle(theme.palette.textSecondary)
                    }
                    if c.isPrivate {
                        Text("\(PTTChannels.arabicDigits(String(c.members.count))) مدعوين")
                            .font(.caption2)
                            .foregroundStyle(theme.palette.textSecondary)
                    }
                }
                Spacer(minLength: 0)
                if on {
                    Image(systemName: "checkmark").font(.body.weight(.bold)).foregroundStyle(theme.palette.accentText)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("ptt-channel-row-\(c.isPrivate ? "private-\(c.name)" : c.id)")
        .accessibilityLabel(Text(c.name))
        .accessibilityValue(Text([on ? "التردد الحالي" : nil, c.talker.map { "يتكلم \(name($0.userId) ?? $0.name)" },
                                  PTTChannels.listenersLine(c, me: me, name: name)].compactMap { $0 }.joined(separator: "، ")))
        .accessibilityAddTraits(on ? [.isSelected, .isButton] : .isButton)
        .swipeActions(edge: .trailing) {
            if c.isPrivate, c.canManage {
                Button("إدارة") { editing = .edit(c) }.tint(theme.palette.accent)
            }
        }
        .contextMenu {
            if c.isPrivate, c.canManage {
                Button("إدارة التردد", systemImage: "person.2.badge.gearshape") { editing = .edit(c) }
            }
        }
        if c.isPrivate, c.canManage {
            Button("إدارة «\(c.name)»") { editing = .edit(c) }
                .font(.footnote)
                .accessibilityIdentifier("ptt-channel-manage-\(c.name)")
        }
    }

    private func name(_ id: String) -> String? {
        id == me ? "أنت" : members.first { $0.id == id }?.name
    }
}

/// The channel knob: turn it (tap a number, drag across, or swipe up/down with VoiceOver) and it
/// clicks into the next detent. The click is the radio's (`PTTRadioCue.channelClick`) + a haptic.
struct PTTChannelKnob: View {
    /// nil: on a private channel (the knob points at none of the public ones).
    var selection: String?
    var busy: Set<String> = []
    var select: (String) -> Void

    @Environment(\.sary) private var theme

    private var index: Int? { selection.flatMap { PTTChannels.publicIds.firstIndex(of: $0) } }
    /// −72° … +72° across the five detents (RTL: ١ on the right, like the list).
    private var angle: Double { Double((index ?? 2) - 2) * -36 }

    var body: some View {
        VStack(spacing: theme.space(.s)) {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [theme.palette.textSecondary.opacity(0.35), theme.palette.textSecondary.opacity(0.12)], startPoint: .top, endPoint: .bottom))
                    .frame(width: 92, height: 92)
                    .overlay(Circle().stroke(theme.palette.textPrimary.opacity(0.25), lineWidth: 1))
                ForEach(0..<24, id: \.self) { i in
                    Capsule().fill(theme.palette.textPrimary.opacity(0.18))
                        .frame(width: 2, height: 7)
                        .offset(y: -40)
                        .rotationEffect(.degrees(Double(i) * 15))
                }
                Capsule().fill(selection == nil ? theme.palette.textSecondary : theme.palette.accent)
                    .frame(width: 5, height: 26)
                    .offset(y: -26)
                    .rotationEffect(.degrees(angle))
                    .animation(theme.reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.62), value: angle)
            }
            /* The dial is a physical thing: ١ is on the right of the row below, the pointer turns right for it. */
            .environment(\.layoutDirection, .leftToRight)
            .accessibilityElement()
            .accessibilityLabel(Text("مفتاح التردد"))
            .accessibilityValue(Text(selection.map(PTTChannels.publicName) ?? "تردد خاص"))
            .accessibilityAdjustableAction { dir in
                let i = index ?? 0
                let next = dir == .increment ? min(4, i + 1) : max(0, i - 1)
                select(PTTChannels.publicIds[next])
            }
            .accessibilityIdentifier("ptt-channel-knob")

            HStack(spacing: 10) {
                ForEach(PTTChannels.publicIds, id: \.self) { id in
                    Button {
                        select(id)
                    } label: {
                        Text(PTTChannels.arabicDigits(id))
                            .font(.system(.title3, design: .rounded).weight(.bold))
                            .frame(width: 44, height: 44)
                            .foregroundStyle(id == selection ? theme.palette.onAccent : theme.palette.textPrimary)
                            .background(Circle().fill(id == selection ? theme.palette.accent : theme.palette.textSecondary.opacity(0.14)))
                            .overlay(alignment: .topTrailing) {
                                if busy.contains(id) {
                                    Image(systemName: "waveform").saryGlyph(9, weight: .bold)
                                        .foregroundStyle(theme.palette.accentText)
                                        .accessibilityHidden(true)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(PTTChannels.publicName(id)))
                    .accessibilityAddTraits(id == selection ? [.isSelected, .isButton] : .isButton)
                    .accessibilityIdentifier("ptt-knob-\(id)")
                }
            }
        }
        .padding(.vertical, theme.space(.s))
        .sensoryFeedback(.selection, trigger: selection)
    }
}

struct PTTPrivateChannelEditor: View {
    @ObservedObject var walkie: OutingWalkieTalkie
    var members: [PTTChannelSheet.Person]
    var editing: PTTChannelSheet.Editing
    var done: () -> Void

    @State private var name = ""
    @State private var picked: Set<String> = []
    @State private var busy = false
    @State private var error: String?
    @State private var confirmClose = false

    private var existing: PTTChannelInfo? {
        if case let .edit(c) = editing { return c }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("اسم التردد") {
                    TextField("مثلًا: السيارات الأمامية", text: $name)
                        .textInputAutocapitalization(.never)
                        .submitLabel(.done)
                        .onChange(of: name) { _, v in if v.count > PTTChannels.nameMax { name = String(v.prefix(PTTChannels.nameMax)) } }
                        .accessibilityIdentifier("ptt-private-name")
                }
                Section {
                    if members.isEmpty {
                        SaryInlineState(systemImage: "person.2.slash", text: "ما فيه أحد ثاني من الأصدقاء في الطلعة بعد. ادعُهم من «المجموعة» وارجع هنا.")
                    }
                    ForEach(members) { p in
                        Button {
                            if picked.contains(p.id) { picked.remove(p.id) } else { picked.insert(p.id) }
                        } label: {
                            HStack {
                                Text(p.name).foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: picked.contains(p.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(picked.contains(p.id) ? Color.accentColor : .secondary)
                                    .accessibilityHidden(true)
                            }
                        }
                        .accessibilityIdentifier("ptt-private-member-\(p.name)")
                        .accessibilityAddTraits(picked.contains(p.id) ? [.isSelected, .isButton] : .isButton)
                    }
                } header: {
                    Text("من يسمع هذا التردد")
                } footer: {
                    Text("لا يدخله ولا يسمعه إلا من تختارهم. يوصلهم إشعار «أمير الطلعة دعاك إلى تردد خاص». من تزيله يخرج منه فورًا.")
                }
                if existing != nil {
                    Section {
                        Button("أغلق التردد", role: .destructive) { confirmClose = true }
                            .accessibilityIdentifier("ptt-private-close")
                    } footer: {
                        Text("يرجع كل من عليه إلى تردد ١.")
                    }
                }
            }
            .navigationTitle(existing == nil ? "تردد خاص جديد" : existing!.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("إلغاء", action: done) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(existing == nil ? "افتح التردد" : "حفظ") { save() }
                        .disabled(busy || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("ptt-private-save")
                }
            }
            .confirmationDialog("أغلق «\(existing?.name ?? "")»؟", isPresented: $confirmClose, titleVisibility: .visible) {
                Button("أغلق التردد", role: .destructive) { close() }
                Button("تراجع", role: .cancel) {}
            }
            .alert("التردد الخاص", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("حسنًا", role: .cancel) {}
            } message: { Text(error ?? "") }
            .onAppear {
                if let c = existing {
                    name = c.name
                    picked = Set(c.members).subtracting([walkie.me])
                }
            }
        }
    }

    private func save() {
        busy = true
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { @MainActor in
            defer { busy = false }
            do {
                if let c = existing {
                    let before = Set(c.members).subtracting([walkie.me])
                    try await walkie.updatePrivate(c.id, name: n == c.name ? nil : n, add: Array(picked.subtracting(before)), remove: Array(before.subtracting(picked)))
                } else {
                    let c = try await walkie.createPrivate(name: n, members: Array(picked))
                    walkie.switchChannel(c.id)
                }
                done()
            } catch {
                self.error = PTTChannels.errorText(error)
            }
        }
    }

    private func close() {
        guard let c = existing else { return }
        Task { @MainActor in
            do {
                try await walkie.closePrivate(c.id)
                done()
            } catch {
                self.error = PTTChannels.errorText(error)
            }
        }
    }
}
