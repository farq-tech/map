import SwiftUI

/// Settings → «تنبيهات القافلة»: each rule on/off with its threshold (Core/ConvoyWatch.swift).
/// The rules run on this phone, from live positions only.
struct ConvoyAlertSettingsView: View {
    var back: (() -> Void)? = nil
    var close: (() -> Void)? = nil
    @ObservedObject private var prefs = ConvoyAlertPrefs.shared
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        let s = $prefs.settings
        SaryPage(title: "تنبيهات القافلة", subtitle: "تُحسب على جوالك من المواقع الحية فقط", back: back, close: close) {
            rule(title: "ابتعد عن أمير الطلعة", detail: "سيارة أبعد من المسافة عن أمير الطلعة (أو عن المقدمة في وضع القافلة) لمدة المهلة.",
                 icon: "arrow.up.left.and.arrow.down.right", isOn: s.separationOn, id: "rules.separation") {
                slider("المسافة", value: s.separationKm, range: ConvoyAlertSettings.separationKmRange, step: 0.5,
                       text: SaryFormat.distance(meters: prefs.settings.separationKm * 1000), id: "rules.separation.km")
                slider("المهلة قبل التنبيه", value: s.separationGraceS, range: ConvoyAlertSettings.separationGraceRange, step: 15,
                       text: seconds(prefs.settings.separationGraceS), id: "rules.separation.grace")
            }
            rule(title: "وقف فجأة", detail: "سيارة كانت تمشي فوق ٢٠ كم/س ثم وقفت والمجموعة تتحرك، بعيدًا عن الوجهة ونقطة التجمع والنقاط المعروفة.",
                 icon: "exclamationmark.octagon.fill", isOn: s.stopOn, id: "rules.stop") {
                slider("مدة الوقوف", value: s.stopMinutes, range: ConvoyAlertSettings.stopMinutesRange, step: 1,
                       text: "\(SaryFormat.number(Int(prefs.settings.stopMinutes))) د", id: "rules.stop.minutes")
            }
            rule(title: "انقطع الإرسال", detail: "الخادم يحدد الانقطاع (لا موقع من المشارك لمدة ١٠ دقائق ثم ٣٠).",
                 icon: "antenna.radiowaves.left.and.right.slash", isOn: s.silentOn, id: "rules.silent") {
                VStack(alignment: .leading, spacing: theme.space(.xs)) {
                    Text("نبهني بعد").saryText(.footnote, weight: .bold).foregroundStyle(p.textSecondary)
                    SarySegmented(options: ConvoyAlertSettings.silentChoices, selection: s.silentMinutes,
                                  label: { "\(SaryFormat.number($0)) د" }, id: "rules.silent.minutes")
                }
            }
            rule(title: "تأخر عن المؤخرة", detail: "في وضع القافلة: سيارة خلف المؤخرة أكثر من المسافة اللي حددها القائد.",
                 icon: "arrow.down.to.line", isOn: s.behindTailOn, id: "rules.tail") {
                slider("المهلة قبل التنبيه", value: s.behindTailGraceS, range: ConvoyAlertSettings.behindTailGraceRange, step: 15,
                       text: prefs.settings.behindTailGraceS == 0 ? "فورًا" : seconds(prefs.settings.behindTailGraceS), id: "rules.tail.grace")
            }
            Text("لا يتكرر التنبيه نفسه قبل ٥ دقائق، ولا يرجع بعد ما يزول إلا إذا رجع السبب فعلًا. السيارة اللي موقعها قديم لا تُنبّه أبدًا.")
                .saryText(.footnote).foregroundStyle(p.textTertiary)
            Button("ارجع للإعدادات الأصلية") { prefs.reset() }
                .buttonStyle(.sary(.plain, width: .hug, compact: true))
                .accessibilityIdentifier("rules.reset")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("convoy.rules")
    }

    private func seconds(_ s: Double) -> String {
        s < 60 ? "\(SaryFormat.number(Int(s))) ث" : (Int(s) % 60 == 0 ? "\(SaryFormat.number(Int(s) / 60)) د" : "\(SaryFormat.number(Int(s) / 60)) د \(SaryFormat.number(Int(s) % 60)) ث")
    }

    @ViewBuilder
    private func rule<C: View>(title: String, detail: String, icon: String, isOn: Binding<Bool>, id: String, @ViewBuilder content: () -> C) -> some View {
        SarySection(title: nil, footer: detail) {
            VStack(alignment: .leading, spacing: theme.space(.m)) {
                SaryToggleRow(title: title, systemImage: icon, isOn: isOn, id: id)
                if isOn.wrappedValue { content() }
            }
            .padding(theme.space(.m))
        }
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, text: String, id: String) -> some View {
        let p = theme.palette
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).saryText(.footnote, weight: .bold).foregroundStyle(p.textSecondary)
                Spacer()
                Text(text).saryNumber(.headline, weight: .bold).foregroundStyle(p.textPrimary)
            }
            Slider(value: value, in: range, step: step)
                .tint(p.accent)
                .accessibilityLabel(Text(title))
                .accessibilityValue(Text(text))
                .accessibilityIdentifier(id)
        }
    }
}
