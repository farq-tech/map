import SwiftUI

/// «اسأل سرى»: a small sheet over the live screen (nothing added to the map itself). One answer
/// card, a big mic, and — only when stopped — a text field. Driving: voice only, big targets.
struct AssistantSheet: View {
    @ObservedObject var assistant: AssistantController
    @ObservedObject var store: AssistantModelStore
    var driving: Bool
    var sosState: MySOSUI
    var sosTrigger: () -> Void
    var close: () -> Void
    @Environment(\.sary) private var theme
    @FocusState private var fieldFocused: Bool

    var body: some View {
        let p = theme.palette
        VStack(alignment: .leading, spacing: theme.space(.m)) {
            HStack(spacing: theme.space(.s)) {
                Image(systemName: "sparkles").foregroundStyle(p.accentText)
                Text("اسأل سرى").font(.sary(18, .bold)).foregroundStyle(p.textPrimary).accessibilityAddTraits(.isHeader)
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 14, weight: .bold)).foregroundStyle(p.textPrimary)
                        .frame(width: 44, height: 44).background(Circle().fill(p.sunken))
                }
                .buttonStyle(SaryPressStyle())
                .accessibilityLabel(Text("إغلاق"))
                .accessibilityIdentifier("assistant.close")
            }
            card
            Spacer(minLength: 0)
            if !driving {
                HStack(spacing: theme.space(.s)) {
                    TextField("اكتب سؤالك… مثل: وين الربع", text: $assistant.typed)
                        .font(.sary(16, .regular))
                        .submitLabel(.send)
                        .onSubmit { assistant.submitTyped() }
                        .focused($fieldFocused)
                        .padding(.horizontal, theme.space(.m))
                        .frame(minHeight: 48)
                        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(p.sunken))
                        .accessibilityIdentifier("assistant.field")
                    Button { assistant.submitTyped() } label: {
                        Image(systemName: "arrow.up").font(.system(size: 18, weight: .bold)).foregroundStyle(p.onAccent)
                            .frame(width: 48, height: 48).background(Circle().fill(p.accent))
                    }
                    .buttonStyle(SaryPressStyle())
                    .disabled(assistant.typed.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityLabel(Text("اسأل"))
                    .accessibilityIdentifier("assistant.send")
                }
            }
            mic
            Text(footer).font(.sary(11, .regular)).foregroundStyle(p.textTertiary)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("assistant.mode")
        }
        .padding(.horizontal, theme.space(.l))
        .padding(.vertical, theme.space(.m))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("assistant.sheet")
        /* Load the model (if any) while the person thinks of the question: the answer then waits only for it. */
        .onAppear { assistant.prewarm() }
        .onDisappear { assistant.reset() }
    }

    private var footer: String {
        if let r = AssistantPower.reason, store.modelURL != nil { return r }
        return assistant.modelActive ? "كل شي على جوالك، ما يطلع منه شي." : "الفهم الأساسي، على جوالك. فعّل «مساعد سرى» من الإعدادات ← متقدم لفهم أوسع."
    }

    @ViewBuilder private var card: some View {
        let p = theme.palette
        VStack(alignment: .leading, spacing: theme.space(.s)) {
            switch assistant.phase {
            case .idle:
                Text("وش تبي تعرف؟").font(.sary(driving ? 22 : 17, .bold)).foregroundStyle(p.textPrimary)
                chips(AssistantAnswers.suggestions)
            case let .listening(t):
                Text(t.isEmpty ? "أسمعك…" : t).font(.sary(driving ? 22 : 17, .bold)).foregroundStyle(p.textPrimary)
                    .accessibilityIdentifier("assistant.heard")
            case let .thinking(q):
                Text(q).font(.sary(14, .regular)).foregroundStyle(p.textSecondary)
                ProgressView().tint(p.accent)
            case let .answered(q, a):
                if !q.isEmpty { Text(q).font(.sary(13, .regular)).foregroundStyle(p.textSecondary).accessibilityIdentifier("assistant.question") }
                Text(a.text).font(.sary(driving ? 20 : 16, .bold)).foregroundStyle(p.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("assistant.answer")
                if let d = a.detail {
                    Label(d, systemImage: a.stale ? "clock.badge.exclamationmark" : "info.circle")
                        .font(.sary(12, .regular)).foregroundStyle(a.stale ? p.warningText : p.textSecondary)
                        .accessibilityIdentifier(a.stale ? "assistant.stale" : "assistant.detail")
                }
                if a.showsSOSButton {
                    HStack(spacing: theme.space(.m)) {
                        /* The real button: only the person's own one-second hold sends anything. */
                        SarySOSButton(state: sosState, trigger: sosTrigger, size: 64, compactLabel: true)
                        Text("اضغط عليه ثانية كاملة إذا تحتاج فزعة.").font(.sary(13, .regular)).foregroundStyle(p.textSecondary)
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("assistant.sos")
                }
                if !a.suggestions.isEmpty { chips(a.suggestions) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(theme.space(.m))
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(p.surface))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(p.stroke, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("assistant.card")
    }

    private func chips(_ items: [String]) -> some View {
        let p = theme.palette
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: theme.space(.s)) {
                ForEach(items, id: \.self) { s in
                    Button { assistant.ask(s) } label: {
                        Text(s).font(.sary(driving ? 17 : 14, .regular)).foregroundStyle(p.textPrimary)
                            .padding(.horizontal, theme.space(.m))
                            .frame(minHeight: driving ? 52 : 40)
                            .background(Capsule().fill(p.sunken))
                    }
                    .buttonStyle(SaryPressStyle())
                    .accessibilityIdentifier("assistant.suggestion")
                }
            }
        }
    }

    private var mic: some View {
        let p = theme.palette
        let on = assistant.speech.isListening
        let size: CGFloat = driving ? 96 : 72
        return Button { assistant.micTapped() } label: {
            Image(systemName: on ? "stop.fill" : "mic.fill")
                .font(.system(size: size * 0.38, weight: .bold))
                .foregroundStyle(p.onAccent)
                .frame(width: size, height: size)
                .background(Circle().fill(on ? p.emergency : p.accent))
                .shadow(color: p.shadow, radius: 8, y: 3)
        }
        .buttonStyle(SaryPressStyle())
        .frame(maxWidth: .infinity)
        .accessibilityLabel(Text(on ? "خلصت" : "تكلّم"))
        .accessibilityIdentifier("assistant.mic")
    }
}

/// Settings → «متقدم» → «مساعد سرى»: the optional on-device model (download, size, licence).
struct AssistantSettingsSection: View {
    @ObservedObject var store: AssistantModelStore
    @State private var confirmCellular = false
    @AppStorage(AssistantController.speakKey) private var speak = true
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        SarySection(title: "مساعد سرى", footer: "«اسأل سرى» من «أدوات» أو بضغطة مطوّلة على شريط الرحلة. يفهم الأسئلة الأساسية بدون تحميل. النموذج يوسّع الفهم للهجة والكلام الحر، ويشتغل على جوالك بالكامل بدون إنترنت. \(store.spec.title) · \(store.spec.license) · \(store.sizeText).") {
            switch store.state {
            case .notDownloaded:
                Button { start() } label: { SaryButtonLabel(title: "حمّل النموذج (\(store.sizeText))", systemImage: "arrow.down.circle") }
                    .buttonStyle(.sary(.secondary))
                    .accessibilityIdentifier("assistant.download")
            case let .downloading(f):
                VStack(alignment: .leading, spacing: theme.space(.s)) {
                    ProgressView(value: f).tint(p.accent)
                    Text("يتحمّل… \(SaryFormat.percent(Int(f * 100)))").saryText(.subhead).foregroundStyle(p.textSecondary)
                    Button("إلغاء", role: .cancel) { store.cancel() }.accessibilityIdentifier("assistant.cancel")
                }
            case .verifying:
                Text("نتأكد من الملف (sha256)…").saryText(.subhead).foregroundStyle(p.textSecondary)
            case .ready:
                Toggle("استخدم النموذج", isOn: $store.enabled).accessibilityIdentifier("assistant.enabled")
                Button(role: .destructive) { store.delete() } label: { SaryButtonLabel(title: "احذف النموذج", systemImage: "trash") }
                    .buttonStyle(.sary(.secondary))
            case let .failed(msg):
                Text(msg).saryText(.subhead).foregroundStyle(p.warningText)
                Button { start() } label: { SaryButtonLabel(title: "جرّب مرة ثانية", systemImage: "arrow.clockwise") }
                    .buttonStyle(.sary(.secondary))
            }
            Toggle("اقرأ الجواب بصوت", isOn: $speak).accessibilityIdentifier("assistant.speak")
        }
        .confirmationDialog("أنت على بيانات الجوال", isPresented: $confirmCellular, titleVisibility: .visible) {
            Button("حمّل على بيانات الجوال (\(store.sizeText))") { store.download(allowCellular: true) }
            Button("أنتظر Wi-Fi") { store.download(allowCellular: false) }
            Button("إلغاء", role: .cancel) {}
        } message: {
            Text("الحجم \(store.sizeText). الأفضل تحمّله على Wi-Fi.")
        }
    }

    private func start() {
        if AssistantNetworkPath.shared.expensive { confirmCellular = true } else { store.download(allowCellular: false) }
    }
}
