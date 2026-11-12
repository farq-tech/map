import SwiftUI

#if DEBUG
/// DEBUG only, `-SaryFoundations`: the Build 46 foundation components on one dark screen
/// (screenshots + `FoundationsUITests`). Optional `-SaryShowcaseType AX3`-style size via `-SaryFoundationsType`.
struct SaryFoundationsPreview: View {
    @State private var taps = 0
    /// `-SaryNewUITheme dark|light|dim` (default dark).
    private let theme = SaryThemeChoice.previewTheme(SaryThemeChoice.fromArguments(ProcessInfo.processInfo.arguments) ?? .dark)

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

extension SaryThemeChoice {
    /// A fixed theme for previews, the gallery and screenshots (not driving; `auto` previews as dark).
    static func previewTheme(_ choice: SaryThemeChoice) -> SaryTheme {
        let r = choice.resolve(autoNight: false, driving: false)
        return SaryTheme.resolve(prefs: AppearancePreferences(), scheme: r.scheme, night: r.night, drive: false)
    }
}

/// DEBUG `-SaryThemesGallery`: the three themes one under the other (dark, light, dim) with the same
/// components, palette swatches and the glass recipe, for design review and screenshots.
struct SaryThemesGallery: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach([SaryThemeChoice.dark, .light, .dim]) { choice in
                    panel(choice).accessibilityIdentifier("themes-panel-\(choice.rawValue)")
                }
            }
        }
        .accessibilityIdentifier("themes-gallery-root")
    }

    private func panel(_ choice: SaryThemeChoice) -> some View {
        let theme = SaryThemeChoice.previewTheme(choice)
        let p = theme.palette
        return VStack(alignment: .leading, spacing: SarySpace.m.rawValue) {
            Text(choice.label).saryType(.title).foregroundStyle(p.textPrimary)
            HStack(spacing: SarySpace.s.rawValue) {
                swatch(p.background, "خلفية", p); swatch(p.elevated, "مرتفع", p); swatch(p.surface, "سطح", p)
                swatch(p.accent, "مميز", p); swatch(p.navBlue, "ملاحة", p); swatch(p.live, "مباشر", p)
            }
            ZStack {
                LinearGradient(colors: [Color(rgb: 0xC9A26B), Color(rgb: 0x9AA7B8), Color(rgb: 0x6E7A55)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                SaryGlassSurface {
                    VStack(spacing: SarySpace.s.rawValue) {
                        Text("٢٤° صافي · المغرب ٥:١٢").saryType(.body).foregroundStyle(p.textPrimary)
                        Text("ملاحظة ثانوية").saryType(.caption).foregroundStyle(p.textSecondary)
                        SaryPrimaryButton("＋ ابدأ طلعة", id: "themes-primary-\(choice.rawValue)") {}
                        SarySecondaryButton("اختر من جهات الاتصال", id: "themes-secondary-\(choice.rawValue)") {}
                    }
                }.padding(SarySpace.l.rawValue)
            }
            .clipShape(RoundedRectangle(cornerRadius: SaryRadius.bar, style: .continuous))
        }
        .padding(SarySpace.l.rawValue)
        .frame(maxWidth: .infinity)
        .background(p.background)
        .saryTheme(theme)
    }

    private func swatch(_ c: Color, _ name: String, _ p: SaryPalette) -> some View {
        VStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 10).fill(c).frame(height: 36)
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(p.stroke, lineWidth: 1))
            Text(name).saryType(.caption).foregroundStyle(p.textSecondary)
        }.frame(maxWidth: .infinity)
    }
}
#endif
