import SwiftUI

/// «الإعدادات ← المقدمة»: the cinematic intro and its music (both on by default).
struct IntroSettingsSection: View {
    @AppStorage(IntroPolicy.enabledKey) private var enabled = true
    @AppStorage(IntroPolicy.soundKey) private var sound = true

    var body: some View {
        SarySection(title: "المقدمة", footer: "سماء البر بالليل وشعار سَرى البارق مع موسيقى قصيرة، مرة كل ٦ ساعات على الأكثر. اضغط في أي مكان لتخطيها. لا تظهر إذا فتحت التطبيق من رابط أو تنبيه أو اللاسلكي أو CarPlay، ولا أثناء طلعة شغّالة. الصوت يحترم زر الصامت ولا يوقف أغانيك ولا المكالمات.") {
            SaryToggleRow(title: "مقدمة سينمائية عند الفتح", subtitle: "سماء ونجوم لثوانٍ ثم التطبيق", systemImage: "sparkles",
                          isOn: $enabled, id: "settings.intro")
            SaryDivider()
            SaryToggleRow(title: "صوت المقدمة", subtitle: "موسيقى قصيرة هادئة", systemImage: "music.note",
                          isOn: $sound, id: "settings.introSound")
                .disabled(!enabled)
                .opacity(enabled ? 1 : 0.5)
        }
    }
}
