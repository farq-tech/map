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
        case "home":
            if OneMapFlag.isOn(), let user = model.identity?.user { IdleMapHost(user: user, model: model, appearance: appearance).id(user.id) } else { HomeView() }
        case "details": HomeView(initial: [.details(DemoData.outingId)])
        case "summary": HomeView(initial: [.summary("demo-old")])
        case "history": HomeView(initial: [.history])
        #if DEBUG
        case "story": StoryComposerView(facts: StoryFixtures.facts()) {}
        case "track-detail":
            if let s = DemoTrail.dunesSubject() { TrackDetailView(subject: s, close: {}, follow: { _ in }) }
        case "follow":
            if let s = DemoTrail.dunesSubject(), let m = TrackFollowModel(s) { TrackFollowScreen(model: m, close: {}) }
        #endif
        case "profile": HomeView(initial: [.profile])
        case "settings": HomeView(initial: [.settings])
        case "appearance": HomeView(initial: [.settings, .appearance])
        case "privacy": HomeView(initial: [.settings, .privacy])
        case "notifications": HomeView(initial: [.settings, .notifications])
        case "about": HomeView(initial: [.settings, .about])
        case "advanced": HomeView(initial: [.settings, .advanced])
        case "offline-maps": HomeView(initial: [.settings, .offlineMaps])
        case "offline-flow": NavigationStack { OfflineMapsView(back: {}, suggested: .init(west: 46.666, south: 24.704, east: 46.684, north: 24.719), outingName: "طلعة الثمامة") }
        case "offline-picker": OfflineAreaPicker(initial: .init(west: 46.655, south: 24.70, east: 46.695, north: 24.725), outingName: "طلعة الثمامة", close: {})
        case "create": CreateOutingWizard()
        case "create-quick": CreateOutingWizard(quick: OutingDestination(name: "نقطة على الخريطة", lat: 24.7590, lng: 46.7491))
        case "create-coordinate": CreateOutingWizard(initialText: "24.7590, 46.7491")
        case "create-search": CreateOutingWizard(initialText: "24°45'32\"N 46°44'57\"E")
        case "join": JoinByLinkSheet()
        case "invite-valid": InviteJoinSheet(token: "x", preset: .ready(InvitePreviewUI(outingName: "كشتة نفود الثويرات", inviterName: "أبو فهد", participantCount: 5, status: .active)))
        case "invite-expired": InviteJoinSheet(token: "x", preset: .expired)
        case "invite-personal": InviteJoinSheet(token: "x", preset: .ready(InvitePreviewUI(outingName: "طلعة الثمامة", inviterName: "أبو فهد", participantCount: 4, status: .active, inviteeName: "فهد أخوي")))
        case "invite-taken": InviteJoinSheet(token: "x", preset: .taken)
        case "invite-invalid": InviteJoinSheet(token: "x", preset: .invalid)
        case "invite-error": InviteJoinSheet(token: "x", preset: .error("الشبكة بطيئة. أعد المحاولة."))
        case "notify-explainer": NotifyExplainerSheet(done: {})
        case "invite-needs-location": InviteJoinSheet(token: "x", preset: .ready(InvitePreviewUI(outingName: "طلعة الثمامة", inviterName: "أبو فهد", participantCount: 4, status: .active, inviteeName: "فهد أخوي")),
                                                      presetStep: .needsLocation(.denied))
        case "invite-needs-precise": InviteJoinSheet(token: "x", preset: .ready(InvitePreviewUI(outingName: "طلعة الثمامة", inviterName: "أبو فهد", participantCount: 4, status: .active)),
                                                     presetStep: .needsLocation(.reduced))
        case "share-always-explainer": ShareAlwaysExplainer(allow: {}, later: {})
        case "dialog-leave":
            HomeView().saryDialog($dialog, systemImage: "rectangle.portrait.and.arrow.right", title: "تغادر الطلعة؟",
                                  message: "يتوقف إرسال موقعك وتخرج منها. ترجع فقط برابط دعوة جديد.", confirmTitle: "غادر") {}
        case "privacy-account": HomeView(initial: [.settings, .privacy]).defaultScrollAnchor(.bottom)
        case "delete-account": HomeView(initial: [.settings, .privacy, .deleteAccount])
        case "delete-account-typed": NavigationStack { DeleteAccountView(back: {}, typed: DeleteAccountView.confirmWord) }.defaultScrollAnchor(.bottom)
        case "account-deleted", "account-wiped":
            OnboardingFlow(start: .intro)
                .alert((name == "account-deleted" ? AccountDeletionOutcome.deleted : .wipedLocally(leftOutings: 2)).notice?.title ?? "", isPresented: $dialog) {
                    Button("حسنًا", role: .cancel) {}
                } message: {
                    Text((name == "account-deleted" ? AccountDeletionOutcome.deleted : .wipedLocally(leftOutings: 2)).notice?.message ?? "")
                }
        #if DEBUG
        case "imagery": SatelliteImageryProbe().ignoresSafeArea()
        #endif
        #if DEBUG
        case "route-surfaces":
            /* The road-type window with known lengths (Riyadh → Thumamah: mostly asphalt), no network. */
            let km = { (k: Double) -> [LngLat] in [LngLat(lng: 46.6, lat: 24.7), LngLat(lng: 46.6, lat: 24.7 + k / 111.19)] }
            SaryPage(title: "نوع الطريق") {
                NavSurfaceLegend(runs: [NavSurfaceRun(kind: .paved, coordinates: km(71.4)), NavSurfaceRun(kind: .unpaved, coordinates: km(1.1)),
                                        NavSurfaceRun(kind: .terrain, coordinates: km(0.4))])
            }
        case "route-km":
            /* The km split of a route crossing asphalt, dirt and off-road (owner's example), no network. */
            SaryPage(title: "المسافات") {
                NavSurfaceKmStrip(km: NavSurfaceKm(paved: 23_400, unpaved: 8_100, offRoad: 3_000, unknown: 0))
                    .padding(12).sarySurface(radius: SaryRadius.m)
                NavSurfaceKmStrip(km: NavSurfaceKm(paved: 23_400, unpaved: 8_100, offRoad: 3_000, unknown: 1_200), labels: false)
                    .padding(12).sarySurface(radius: SaryRadius.m)
            }
        #endif
        case "plan-details": HomeView(initial: [.details("demo-new")])
        case "plan-editor", "plan-editor-draw":
            PlanEditorView(plan: model.plans.model(DemoData.outingId), outingName: "طلعة الثمامة (عرض تجريبي)", canEdit: true, myFix: nil, close: {})
        case "plan-search":
            CoordinateSearchSheet(near: nil, myFix: nil, actions: PointActions(setDestination: { _, _ in }, addPoint: { _ in }, rally: { _ in }),
                                  initialText: "24°42'49\"N 46°40'31\"E", close: {})
        case "plan-point":
            SaryPage(title: "") { PointCard(subject: .point(LngLat(lng: 46.67530, lat: 24.71360), name: nil), actions: PointActions(setDestination: { _, _ in }, addPoint: { _ in }, rally: { _ in })).sarySurface(radius: SaryRadius.m) }
        case "plan-me-stale":
            SaryPage(title: "") { PointCard(subject: .me(.init(point: LngLat(lng: 46.67530, lat: 24.71360), accuracyM: 8, at: Date().addingTimeInterval(-300)))).sarySurface(radius: SaryRadius.m) }
        case "weather-here": WeatherPointSheet(point: OutingDestination(name: "نفود الثويرات", lat: 25.7712, lng: 45.1043), close: {})
        default: HomeView()
        }
    }
}
