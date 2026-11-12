import SwiftUI

#if DEBUG
/// DEBUG only, `-SaryFoundations`: the Build 46 foundation components on one dark screen
/// (screenshots + `FoundationsUITests`). Optional `-SaryShowcaseType AX3`-style size via `-SaryFoundationsType`.
struct SaryFoundationsPreview: View {
    @State private var taps = 0
    private let theme = SaryTheme.resolve(prefs: AppearancePreferences(), scheme: .dark, night: false, drive: false)

    var body: some View {
        let p = theme.palette
        ScrollView {
            VStack(alignment: .leading, spacing: SarySpace.l.rawValue) {
                SaryWindowTitle("طلعاتي") { taps += 1 }
                VStack(alignment: .leading, spacing: SarySpace.s.rawValue) {
                    Text("عرض كبير").saryType(.display)
                    Text("عنوان الشاشة").saryType(.title)
                    Text("عنوان فرعي").saryType(.headline)
                    Text("نص عادي يوصف الشي بسطر واضح").saryType(.body)
                    Text("ملاحظة صغيرة").saryType(.caption)
                    Text(SaryFormat.digits("١٢٫٥ كم · 24.5")).saryType(.numeric)
                    Text("روضة الثمامة الشمالية الكبيرة عند نفود الثويرات الغربية").saryLongName().saryType(.headline)
                        .accessibilityIdentifier("foundations-longname")
                }
                .foregroundStyle(p.textPrimary)
                .padding(.horizontal, SarySpace.l.rawValue)
                SaryGlassSurface {
                    VStack(spacing: SarySpace.m.rawValue) {
                        Text("٢٤° صافي · المغرب ٥:١٢").saryType(.body).foregroundStyle(p.textPrimary)
                        SaryPrimaryButton("＋ ابدأ طلعة", id: "foundations-primary") { taps += 1 }
                        SarySecondaryButton("اختر من جهات الاتصال", id: "foundations-secondary") { taps += 1 }
                    }
                }
                .padding(.horizontal, SarySpace.l.rawValue)
                Text("taps \(taps)").saryType(.caption).foregroundStyle(p.textTertiary).padding(.horizontal, SarySpace.l.rawValue).accessibilityIdentifier("foundations-taps")
            }
            .padding(.vertical, SarySpace.l.rawValue)
        }
        .background(p.background.ignoresSafeArea())
        .saryTheme(theme)
        .dynamicTypeSize(SaryFoundationsPreview.typeSize)
        .accessibilityIdentifier("foundations-root")
    }

    static var typeSize: DynamicTypeSize {
        ShowcaseLab.parseType(UserDefaults.standard.string(forKey: "SaryFoundationsType")) ?? .large
    }
}
#endif
