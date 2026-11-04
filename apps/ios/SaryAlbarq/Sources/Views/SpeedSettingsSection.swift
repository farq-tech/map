import SwiftUI

/// «السرعة» in the live sheet's settings: the optional over-speed nudge
/// (off by default, this device only).
struct SpeedSettingsSection: View {
    @AppStorage(SpeedPrefs.alertKey) private var alertOn = false
    @AppStorage(SpeedPrefs.limitKey) private var limit = SpeedPrefs.defaultLimitKmh
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        let current = SpeedPrefs.limits.contains(limit) ? limit : SpeedPrefs.defaultLimitKmh
        SarySection(title: "السرعة", footer: "تنبيه خفيف (اهتزاز ورسالة قصيرة) مرة واحدة كل فترة. سرعتك تُحسب على جوالك ولا تُرسل.") {
            SaryToggleRow(title: "نبّهني إذا تجاوزت", subtitle: alertOn ? SaryFormat.speed(kmh: Double(current)) : "مقفل",
                          systemImage: "gauge.with.needle", isOn: $alertOn, id: "speed.alert")
            if alertOn {
                SaryDivider()
                HStack(spacing: theme.space(.m)) {
                    Button { step(-1, from: current) } label: { Image(systemName: "minus") }
                        .buttonStyle(.sary(.secondary, width: .hug, compact: true))
                        .disabled(current <= SpeedPrefs.limits.first!)
                        .accessibilityLabel(Text("أقل"))
                        .accessibilityIdentifier("speed.limit.down")
                    Text(SaryFormat.speed(kmh: Double(current)))
                        .saryNumber(.title2, weight: .bold)
                        .foregroundStyle(p.textPrimary)
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("speed.limit")
                    Button { step(1, from: current) } label: { Image(systemName: "plus") }
                        .buttonStyle(.sary(.secondary, width: .hug, compact: true))
                        .disabled(current >= SpeedPrefs.limits.last!)
                        .accessibilityLabel(Text("أكثر"))
                        .accessibilityIdentifier("speed.limit.up")
                }
                .padding(.vertical, theme.space(.s))
                .sensoryFeedback(.selection, trigger: current)
            }
        }
    }

    private func step(_ d: Int, from v: Int) {
        guard let i = SpeedPrefs.limits.firstIndex(of: v) else { limit = SpeedPrefs.defaultLimitKmh; return }
        limit = SpeedPrefs.limits[min(max(0, i + d), SpeedPrefs.limits.count - 1)]
    }
}
