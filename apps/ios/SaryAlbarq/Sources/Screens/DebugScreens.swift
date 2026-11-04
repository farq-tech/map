import SwiftUI

/// Screenshot hook: with `-demo -SaryScreen <name>` (DEBUG only; `AppModel.debugScreen`
/// is never set in Release) one page opens with demo data, so every screen can be
/// captured in light / dark without a server. See scripts/app-shots.sh.
struct DebugScreen: View {
    let name: String
    @EnvironmentObject private var model: AppModel
    @Environment(AppearanceSettings.self) private var appearance
    @Environment(\.sary) private var theme
    @State private var dialog = true

    var body: some View {
        switch name {
        case "splash": SplashView()
        case "onboarding": OnboardingFlow(start: .intro)
        case "onboarding-profile": OnboardingFlow(start: .profile)
        case "onboarding-location": OnboardingFlow(start: .locationExplainer)
        case "recovery-restore": RecoveryRestoreScreen(close: {})
        case "recovery-code": NavigationStack { RecoveryCodeScreen(back: {}) }
        case "recovery-code-shown": NavigationStack { RecoveryCodeScreen(back: {}, code: .init(code: "7K3Q-M9XD-2HPA-VR6T-WC4N-8B1F-ZJ5E", created_at: nil)) }
        case "home": HomeView()
        case "details": HomeView(initial: [.details(DemoData.outingId)])
        case "summary": HomeView(initial: [.summary("demo-old")])
        case "history": HomeView(initial: [.history])
        case "profile": HomeView(initial: [.profile])
        case "settings": HomeView(initial: [.settings])
        case "appearance": HomeView(initial: [.settings, .appearance])
        case "privacy": HomeView(initial: [.settings, .privacy])
        case "notifications": HomeView(initial: [.settings, .notifications])
        case "about": HomeView(initial: [.settings, .about])
        case "create": CreateOutingSheet()
        case "join": JoinByLinkSheet()
        case "invite-valid": InviteJoinSheet(token: "x", preset: .ready(InvitePreviewUI(outingName: "كشتة نفود الثويرات", inviterName: "أبو فهد", participantCount: 5, status: .active)))
        case "invite-expired": InviteJoinSheet(token: "x", preset: .expired)
        case "invite-invalid": InviteJoinSheet(token: "x", preset: .invalid)
        case "invite-error": InviteJoinSheet(token: "x", preset: .error("الشبكة بطيئة. أعد المحاولة."))
        case "notify-explainer": NotifyExplainerSheet(done: {})
        case "dialog-leave":
            HomeView().saryDialog($dialog, systemImage: "rectangle.portrait.and.arrow.right", title: "تغادر الطلعة؟",
                                  message: "يتوقف إرسال موقعك وتخرج منها. ترجع فقط برابط دعوة جديد.", confirmTitle: "غادر") {}
        case "dialog-wipe":
            HomeView(initial: [.settings, .privacy]).saryDialog($dialog, systemImage: "trash.fill", title: "تمسح بياناتك؟",
                                                                message: "تخرج من كل طلعاتك، ويُمسح رقمك وصورتك من الخادم، وتُمسح هويتك من هذا الجهاز. لا يمكن التراجع.", confirmTitle: "امسح") {}
        default: HomeView()
        }
    }
}
