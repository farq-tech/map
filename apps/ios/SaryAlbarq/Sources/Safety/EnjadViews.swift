import SwiftUI
import UIKit

extension LiveOutingController {
    /// Everything «اطلب إنجاد» says, from this phone's freshest data (never a stale fix as live).
    func enjadInput(_ situation: Enjad.Situation) -> Enjad.Input {
        let v = session.displayView
        let me = v?.me
        let owner = v?.members.values.first { $0.role == "owner" }
        let leader = owner?.user_id == v?.myId ? nil : owner
        return Enjad.Input(situation: situation, name: me?.display_name ?? "—", phone: me?.phone,
                           fix: session.smoothedFix(location.lastFix) ?? location.lastFix, now: Date(),
                           batteryPercent: OutingSession.batteryNow().map { Int(($0.level * 100).rounded()) },
                           memberCount: v.map { $0.members.count }, car: nil,
                           leaderName: leader?.display_name, leaderPhone: leader?.phone)
    }

    func openEnjad(_ situation: Enjad.Situation) {
        UIDevice.current.isBatteryMonitoringEnabled = true
        modal = .enjad(situation)
    }
}

/// «اطلب إنجاد»: the message preview and the three ways to reach Enjad. The person sends it.
struct EnjadSheet: View {
    var input: Enjad.Input
    var online: Bool
    var addPhone: () -> Void
    var close: () -> Void
    /// A solo outing's SOS (docs/SOLO-OUTING.md (ج)): nobody gets an alert, so «اتصل ٩١١» comes
    /// first, then Enjad as the second option.
    var official911First = false
    @Environment(\.sary) private var theme
    @Environment(\.openURL) private var openURL

    var body: some View {
        let p = theme.palette
        let text = Enjad.message(input)
        SaryPage(title: official911First ? SoloCopy.sosTitle : "اطلب إنجاد", subtitle: official911First ? nil : "جمعية إنجاد للبحث والإنقاذ", close: close) {
            if official911First {
                VStack(alignment: .leading, spacing: theme.space(.s)) {
                    Text(SoloCopy.sosNote).saryText(.subhead, weight: .medium).foregroundStyle(p.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("solo.sos.note")
                    Button { openURL(Enjad.officialCallURL) } label: { SaryButtonLabel(title: SoloCopy.call911, systemImage: SaryIcon.phone) }
                        .buttonStyle(.sary(.destructive))
                        .accessibilityLabel(Text(SoloCopy.call911))
                        .accessibilityIdentifier("solo.sos.call911")
                }
            }
            if !Enjad.hasPhone(input) {
                VStack(alignment: .leading, spacing: theme.space(.s)) {
                    SaryBanner(text: "رقم جوالك مو مضاف: أضفه قبل الإرسال عشان يتواصلون معك، أو اكتبه في الرسالة بنفسك.", tone: .warning, systemImage: "phone.badge.plus")
                    Button(action: addPhone) { SaryButtonLabel(title: "أضف رقمي", systemImage: "phone.badge.plus") }
                        .buttonStyle(.sary(.secondary, compact: true))
                        .accessibilityIdentifier("enjad.addPhone")
                }
            }
            Button {
                let wa = UIApplication.shared.canOpenURL(Enjad.whatsappScheme)
                openURL(Enjad.sendURL(text, whatsappInstalled: wa, online: online))
            } label: { SaryButtonLabel(title: "اطلب إنجاد (واتساب)", systemImage: "message.fill") }
                /* One red button per screen: on a solo outing «اتصل ٩١١» above is it, Enjad comes second. */
                .buttonStyle(.sary(official911First ? .secondary : .destructive))
                .accessibilityIdentifier("enjad.whatsapp")
            Button { openURL(Enjad.callURL) } label: { SaryButtonLabel(title: "اتصل بإنجاد", systemImage: "phone.fill") }
                .buttonStyle(.sary(.secondary))
                .accessibilityIdentifier("enjad.call")
            Button { openURL(Enjad.smsURL(text)) } label: { SaryButtonLabel(title: "أرسل رسالة نصية بدل واتساب", systemImage: "text.bubble") }
                .buttonStyle(.sary(.plain))
                .accessibilityIdentifier("enjad.sms")
            SarySection(title: "الرسالة", footer: "تفتح في واتساب (أو الرسائل) جاهزة، وأنت اللي ترسلها. ما نرسل عنك شي.") {
                Text(text)
                    .saryText(.subhead)
                    .foregroundStyle(p.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, theme.space(.s))
                    .accessibilityIdentifier("enjad.message")
            }
            Text(Enjad.note).saryText(.footnote, weight: .medium).foregroundStyle(p.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("enjad.note")
        }
        .accessibilityIdentifier("enjad.sheet")
    }
}
