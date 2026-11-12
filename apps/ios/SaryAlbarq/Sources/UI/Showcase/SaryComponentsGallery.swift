import SwiftUI

#if DEBUG
/// DEBUG only, `-SaryComponents`: the Build 47 screen kit on one screen (screenshots + `ComponentsUITests`).
///   -SaryComponentsPage all|header|states|loading|list|chips   (default all)
///   -SaryComponentsScheme light|dark   (default dark)
///   -SaryComponentsType AX3 …          Dynamic Type size
struct SaryComponentsGallery: View {
    @State private var taps = 0
    @State private var chip = 0
    private var page: String { UserDefaults.standard.string(forKey: "SaryComponentsPage") ?? "all" }
    private var theme: SaryTheme {
        let light = UserDefaults.standard.string(forKey: "SaryComponentsScheme") == "light"
        return SaryTheme.resolve(prefs: AppearancePreferences(), scheme: light ? .light : .dark, night: false, drive: false)
    }
    private let people = [
        SaryAvatarStackPerson(id: "1", name: "ماجد", color: 0xE8842C),
        SaryAvatarStackPerson(id: "2", name: "سارة", color: 0x2FA56A),
        SaryAvatarStackPerson(id: "3", name: "فهد", color: 0x4C8DF6),
        SaryAvatarStackPerson(id: "4", name: "نورة", color: 0xC9A26B),
        SaryAvatarStackPerson(id: "5", name: "خالد", color: 0x9AA7B8),
    ]

    var body: some View {
        let p = theme.palette
        SaryScreenScaffold(title: "طلعاتي", onClose: { taps += 1 },
                           primaryTitle: "＋ ابدأ طلعة", primaryID: "components-primary", onPrimary: { taps += 1 }) {
            VStack(alignment: .leading, spacing: SarySpace.l.rawValue) {
                if show("states") {
                    SaryScreenState(kind: .empty, systemImage: "figure.hiking",
                                    message: "ما عندك طلعات للحين، سوّ أول طلعة", actionTitle: "سوّ أول طلعة",
                                    actionID: "components-empty-action") { taps += 1 }
                    SaryScreenState(kind: .error, systemImage: nil,
                                    message: "ما قدرنا نحمّل الطلعات. تأكد من الإنترنت وحاول مرة ثانية", actionTitle: "حاول مرة ثانية",
                                    actionID: "components-error-action") { taps += 1 }
                }
                if show("loading") { SarySkeletonList(rows: 4) }
                if show("list") {
                    SaryListGroup {
                        SaryListRow(title: "طلعة الثمامة", subtitle: "الجمعة · ٤ أصدقاء · ٦٢ كم", systemImage: "flag.fill",
                                    id: "components-row-1", action: { taps += 1 })
                        SaryListRow(title: "روضة الثمامة الشمالية الكبيرة عند نفود الثويرات الغربية", subtitle: "ربيع واضح · ٦ كم²",
                                    systemImage: "leaf.fill", trailing: "١٤ كم", id: "components-row-2", action: { taps += 1 })
                        SaryListRow(title: "إعدادات الخصوصية", systemImage: "lock.fill", id: "components-row-3", action: { taps += 1 })
                    }
                }
                if show("chips") {
                    HStack(spacing: SarySpace.s.rawValue) {
                        ForEach(Array(["الكل", "أسفلت", "ترابي", "بر مفتوح"].enumerated()), id: \.offset) { i, t in
                            SaryChip(title: t, selected: chip == i, id: "components-chip-\(i)") { chip = i }
                        }
                    }
                    HStack(spacing: SarySpace.s.rawValue) {
                        SaryPill(text: "مباشر", tone: .live)
                        SaryPill(text: "تحذير", tone: .warning, systemImage: "exclamationmark.triangle.fill")
                        SaryPill(text: "طوارئ", tone: .emergency)
                        SaryPill(text: "٤ أصدقاء", tone: .neutral)
                        SaryPill(text: "جديد", tone: .accent)
                    }
                    HStack(spacing: SarySpace.m.rawValue) {
                        SaryAvatarStack(people: people)
                        Text("٥ معك").saryType(.caption).foregroundStyle(p.textSecondary)
                    }
                }
                SarySecondaryButton("اختر من جهات الاتصال", id: "components-secondary") { taps += 1 }
                Text("taps \(taps)").saryType(.caption).foregroundStyle(p.textTertiary).accessibilityIdentifier("components-taps")
            }
        }
        .saryTheme(theme)
        .dynamicTypeSize(ShowcaseLab.parseType(UserDefaults.standard.string(forKey: "SaryComponentsType")) ?? .large)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("components-root")
    }

    private func show(_ s: String) -> Bool { page == "all" || page == s }
}
#endif
