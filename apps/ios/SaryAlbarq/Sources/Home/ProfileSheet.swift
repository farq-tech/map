import SwiftUI

/// The profile button's sheet (after Hudhud's): who I am, then مفضلتك · نشاطك ·
/// الإعدادات · المساعدة · الشروط. Each row opens its page behind the sheet.
struct ProfileSheet: View {
    var open: (HomeRoute) -> Void
    @EnvironmentObject private var model: AppModel
    @Environment(\.sary) private var theme
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    static let supportURL = URL(string: "\(InviteLink.webOrigin)/support")!
    static let termsURL = URL(string: "\(InviteLink.webOrigin)/privacy")!

    var body: some View {
        let p = theme.palette
        let me = model.identity?.user
        ScrollView {
            VStack(alignment: .leading, spacing: theme.space(.l)) {
                HStack {
                    Spacer()
                    SaryIconButton(systemImage: SaryIcon.close, label: "إغلاق", id: "profile.sheet.close", visual: 34) { dismiss() }
                }
                Button { open(.profile) } label: {
                    HStack(spacing: theme.space(.m)) {
                        SaryAvatar(name: me?.display_name ?? "؟", color: theme.accent.fill, photo: AvatarCodec.image(from: me?.avatar), size: 64)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(me?.display_name ?? "حسابي").saryText(.title2, weight: .bold).foregroundStyle(p.textPrimary)
                            Text(me?.phone.map { SaryFormat.digits($0) } ?? "عدّل اسمك وصورتك ورقمك").saryNumber(.footnote).foregroundStyle(p.textSecondary)
                        }
                        Spacer()
                        Image(systemName: SaryIcon.disclosure).foregroundStyle(p.textTertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("profile.sheet.me")

                VStack(spacing: 0) {
                    row("مفضلتك", detail: "البيت والشغل والأماكن المحفوظة", icon: "star.fill", id: "profile.sheet.favorites") { open(.favorites) }
                    SaryDivider()
                    row("نشاطك", detail: "طلعاتك السابقة وملخصاتها", icon: "clock.arrow.circlepath", id: "profile.sheet.activity") { open(.history) }
                }
                .sarySurface(radius: SaryRadius.l)

                VStack(spacing: 0) {
                    row("الإعدادات", detail: nil, icon: SaryIcon.settings, id: "profile.sheet.settings") { open(.settings) }
                    SaryDivider()
                    row("المساعدة", detail: "الدعم وعن التطبيق", icon: "questionmark.circle.fill", id: "profile.sheet.help") { open(.about) }
                    SaryDivider()
                    row("الشروط والخصوصية", detail: nil, icon: "doc.text.fill", id: "profile.sheet.terms") { openURL(Self.termsURL) }
                }
                .sarySurface(radius: SaryRadius.l)
            }
            .padding(theme.space(.l))
        }
        .background(p.background.ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("profile.sheet")
    }

    private func row(_ title: String, detail: String?, icon: String, id: String, run: @escaping () -> Void) -> some View {
        SaryNavRow(title: title, detail: detail, systemImage: icon, id: id, action: run)
            .padding(.horizontal, theme.space(.m))
    }
}

/// «مفضلتك»: البيت، الشغل and the saved places (this phone only).
struct FavoritesView: View {
    var back: () -> Void
    /// Build 48.2 (root cause of «الأماكن المحفوظة ما تضغط»): the rows were plain stacks with no action. A tap now hands
    /// the place to the home (the same path as a recent place), which shows it on the map with its «ابدأ» options.
    var choose: (OutingDestination, String, String) -> Void = { _, _, _ in }
    @Environment(\.sary) private var theme
    @ObservedObject private var saved = SavedPlacesStore.shared
    @State private var shortcuts = HomeShortcutStore.load()

    var body: some View {
        let p = theme.palette
        SaryPage(title: "مفضلتك", back: back) {
            SarySection(title: "اختصارات", footer: "تختارها من البحث في الصفحة الرئيسية («البيت» أو «الشغل» ← أضف). تبقى على جوالك فقط.") {
                ForEach(Array(HomeShortcut.allCases.enumerated()), id: \.element) { i, s in
                    if i > 0 { SaryDivider() }
                    HStack(spacing: theme.space(.m)) {
                        Button {
                            if let d = shortcuts[s] { choose(d, s.label, s.systemImage) }
                        } label: {
                            HStack(spacing: theme.space(.m)) {
                                SaryRowIcon(systemImage: s.systemImage)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(s.label).saryText(.body, weight: .bold).foregroundStyle(p.textPrimary)
                                    Text(shortcuts[s]?.name ?? "ما حددته بعد").saryText(.footnote).foregroundStyle(p.textSecondary)
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(shortcuts[s] == nil)
                        .accessibilityIdentifier("favorites.shortcut.\(s.rawValue)")
                        if shortcuts[s] != nil {
                            Button("امسح") {
                                HomeShortcutStore.set(s, nil)
                                shortcuts = HomeShortcutStore.load()
                            }
                            .buttonStyle(.sary(.plainDestructive, width: .hug, compact: true))
                            .accessibilityIdentifier("favorites.clear.\(s.rawValue)")
                        }
                    }
                    .frame(minHeight: theme.minTarget + 8)
                    .padding(.horizontal, theme.space(.m))
                }
            }
            SarySection(title: "أماكني المحفوظة") {
                if saved.places.isEmpty {
                    Text("ما حفظت أماكن بعد. اختر مكانًا من البحث واضغط «احفظ».")
                        .saryText(.subhead).foregroundStyle(p.textSecondary)
                        .padding(theme.space(.m))
                }
                ForEach(Array(saved.places.enumerated()), id: \.element.id) { i, s in
                    if i > 0 { SaryDivider() }
                    Button {
                        choose(OutingDestination(name: s.name, lat: s.position.lat, lng: s.position.lng), "محفوظ", s.icon.systemImage)
                    } label: {
                        HStack(spacing: theme.space(.m)) {
                            SaryRowIcon(systemImage: s.icon.systemImage)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.name).saryText(.body, weight: .bold).foregroundStyle(p.textPrimary).lineLimit(1)
                                Text(CoordinateShare.displayDecimal(s.position)).saryNumber(.footnote).foregroundStyle(p.textSecondary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: SaryIcon.disclosure).foregroundStyle(p.textTertiary)
                        }
                        .frame(minHeight: theme.minTarget + 8)
                        .padding(.horizontal, theme.space(.m))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("favorites.place")
                }
            }
        }
        .onAppear { shortcuts = HomeShortcutStore.load() }
    }
}
