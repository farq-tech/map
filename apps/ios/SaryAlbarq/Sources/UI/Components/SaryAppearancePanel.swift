import SwiftUI

/// The customisation UI for `AppearanceSettings` — the ONE place these
/// options are edited (an «المظهر» settings screen embeds it). Changes apply
/// live through the environment and persist automatically.
struct SaryAppearancePanel: View {
    @Bindable var settings: AppearanceSettings
    @Environment(\.sary) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space(.xl)) {
            SarySection(title: "المظهر") {
                row("الألوان") {
                    SarySegmented(options: SaryColorSchemePreference.allCases, selection: $settings.prefs.colorScheme,
                                  label: { $0.label }, id: "appearance-scheme")
                }
                SaryDivider()
                row("لون التمييز") { accentPicker }
            }

            SarySection(title: "القيادة والليل",
                        footer: "وضع القيادة يكبّر الأزرار ويخفي التفاصيل ويجعل الأسطح معتمة لتقرأ في الشمس. «تلقائي» يشتغل مع السرعة وبعد الغروب.") {
                row("وضع القيادة", icon: SaryIcon.drive) {
                    SarySegmented(options: SaryTriMode.allCases, selection: $settings.prefs.driveMode, label: { $0.label }, id: "appearance-drive")
                }
                SaryDivider()
                row("الوضع الليلي", icon: SaryIcon.night) {
                    SarySegmented(options: SaryTriMode.allCases, selection: $settings.prefs.nightMode, label: { $0.label }, id: "appearance-night")
                }
            }

            SarySection(title: "النص والأزرار", footer: "حجم النص يضاف فوق حجم النص في إعدادات الجهاز.") {
                row("حجم النص") {
                    SarySegmented(options: SaryTextSize.allCases, selection: $settings.prefs.textSize, label: { $0.label }, id: "appearance-text")
                }
                SaryDivider()
                row("حجم الأزرار") {
                    SarySegmented(options: SaryButtonSize.allCases, selection: $settings.prefs.buttonSize, label: { $0.label })
                }
                SaryDivider()
                row("الكثافة") {
                    SarySegmented(options: SaryDensity.allCases, selection: $settings.prefs.density, label: { $0.label })
                }
            }

            SarySection(title: "الأسطح") {
                row("شفافية الزجاج") {
                    SarySegmented(options: SaryGlassIntensity.allCases, selection: $settings.prefs.glass, label: { $0.label }, id: "appearance-glass")
                }
                SaryDivider()
                row("اللوحات فوق الخريطة") {
                    SarySegmented(options: SaryPanelLook.allCases, selection: $settings.prefs.panelLook, label: { $0.label })
                }
                SaryDivider()
                row("البطاقات") {
                    SarySegmented(options: SaryCardStyle.allCases, selection: $settings.prefs.cardStyle, label: { $0.label })
                }
            }

            SarySection(title: "الحركة والمشاركون") {
                row("الحركة") {
                    SarySegmented(options: SaryMotionPreference.allCases, selection: $settings.prefs.motion, label: { $0.label })
                }
                SaryDivider()
                row("شكل المشاركين") {
                    SarySegmented(options: SaryParticipantMarker.allCases, selection: $settings.prefs.participantMarker,
                                  label: { $0.label }, systemImage: { $0 == .cars ? SaryIcon.car : "circle.fill" })
                }
                SaryDivider()
                row("الأسماء على الخريطة") {
                    SarySegmented(options: SaryNameDisplay.allCases, selection: $settings.prefs.nameDisplay, label: { $0.label })
                }
            }

            Button("إرجاع الإعدادات الافتراضية") { settings.reset() }
                .buttonStyle(.sary(.plain))
                .disabled(settings.prefs == AppearancePreferences())
        }
    }

    private func row<C: View>(_ title: String, icon: String? = nil, @ViewBuilder _ control: () -> C) -> some View {
        VStack(alignment: .leading, spacing: theme.space(.s)) {
            HStack(spacing: 6) {
                if let icon { Image(systemName: icon).foregroundStyle(theme.palette.accentText) }
                Text(title).saryText(.body, weight: .medium).foregroundStyle(theme.palette.textPrimary)
            }
            control()
        }
        .padding(.vertical, theme.space(.m))
    }

    private var accentPicker: some View {
        /* Wraps instead of pushing «ورد طائفي» past the edge (320 pt Display Zoom, large text). */
        SaryFlowLayout(spacing: theme.space(.m), lineSpacing: theme.space(.s)) {
            ForEach(SaryAccent.allCases) { a in
                let selected = settings.prefs.accent == a
                Button { settings.prefs.accent = a } label: {
                    VStack(spacing: 4) {
                        Circle().fill(Color(rgb: a.fill))
                            .frame(width: 34, height: 34)
                            .overlay {
                                if selected {
                                    Image(systemName: SaryIcon.check).font(.system(size: 14, weight: .heavy)).foregroundStyle(Color(rgb: 0x1A1612))
                                }
                            }
                            .padding(3)
                            .overlay(Circle().stroke(selected ? Color(rgb: a.fill) : .clear, lineWidth: 2))
                        Text(a.label).saryText(.caption, weight: .medium).foregroundStyle(theme.palette.textSecondary)
                            .lineLimit(1).fixedSize()
                    }
                    .frame(minWidth: theme.minTarget, minHeight: theme.minTarget)
                }
                .buttonStyle(SaryPressStyle())
                .accessibilityLabel(Text("لون \(a.label)"))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .saryHaptic(.selection, trigger: settings.prefs.accent)
    }
}
