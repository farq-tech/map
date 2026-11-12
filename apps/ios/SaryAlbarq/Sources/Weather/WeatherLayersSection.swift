import SwiftUI

/// «الطقس» in exploration's «الطبقات»: none / «السحاب الآن» / «وين نزل مطر» / «وين ربّع»,
/// one at a time over the base layer, and the period for rain (١ / ٣ / ٧ أيام).
struct WeatherLayersSection: View {
    @ObservedObject var layers = WeatherLayers.shared
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        SarySection(title: "الطقس", footer: footer) {
            VStack(spacing: 0) {
                ForEach(Array(WeatherOverlayKind.allCases.enumerated()), id: \.element) { i, k in
                    let on = layers.kind == k
                    Button { layers.kind = k } label: {
                        HStack(spacing: theme.space(.m)) {
                            SaryRowIcon(systemImage: k.systemImage, color: on ? p.accent : p.textTertiary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(k.label).saryText(.body, weight: .medium).foregroundStyle(p.textPrimary)
                                Text(k.detail).saryText(.footnote).foregroundStyle(p.textSecondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(on ? p.accent : p.textTertiary)
                        }
                        .frame(minHeight: theme.minTarget)
                        .padding(.vertical, theme.space(.xs))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(SaryRowPressStyle())
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
                    .accessibilityIdentifier("weather.layer.\(k.rawValue)")
                    if k == .rain && on {
                        SarySegmented(options: WeatherLayers.allowedDays, selection: $layers.rainDays,
                                      label: { WeatherLayers.daysLabel($0) },
                                      optionID: { "weather.rain.days.\($0)" })
                            .padding(.bottom, theme.space(.s))
                    }
                    if i < WeatherOverlayKind.allCases.count - 1 { SaryDivider() }
                }
            }
            .padding(.horizontal, theme.space(.m))
        }
    }

    private var footer: String { Self.footer(for: layers.kind) }

    /// The source/attribution text of the chosen overlay (also shown by the shared layers sheet).
    static func footer(for kind: WeatherOverlayKind) -> String {
        switch kind {
        case .none: return "طبقات الطقس من الأقمار الصناعية، تظهر فوق الخريطة في الاستكشاف."
        case .clouds: return "صور الأشعة تحت الحمراء من القمر الأوروبي Meteosat (EUMETSAT)، كل ١٠ دقائق لآخر ساعتين. آخر صورة عمرها ٢٠–٦٠ دقيقة. \(kind.attribution())"
        case .rain: return "تقدير المطر من أقمار ناسا (GPM IMERG) بدقة ~١٠ كم، يتأخر ٤–٧ ساعات. الزخات الصغيرة قد لا تظهر. اتجاه الحركة من صورتين متتاليتين، وهو ماضٍ مو توقع. \(kind.attribution())"
        case .wind: return "توقّع نموذج جوي عالمي (ECMWF عبر MET Norway) للساعة الحالية على شبكة ~١٥٠ كم، مو قياس ولا بث حي. الرياح المحلية (الأودية، العواصف) ما تظهر. \(kind.attribution())"
        case .green: return "الاخضرار المرصود الآن (مؤشر NDVI من قمر VIIRS لآخر ٨ أيام مقارنة بالصيف، دقة ~١ كم)، مو توقّع ربيع. نحاول نستبعد المزارع المروية، لكن بعضها قد يظهر أخضر، خصوصًا حول المدن الزراعية. \(kind.attribution())"
        }
    }
}
