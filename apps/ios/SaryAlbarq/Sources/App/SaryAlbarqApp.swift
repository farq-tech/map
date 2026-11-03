import SwiftUI
import UserNotifications

@main
struct SaryAlbarqApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(model.location)
                .environment(\.layoutDirection, .rightToLeft)
                .environment(\.locale, Locale(identifier: "ar"))
                .onOpenURL { model.handle(url: $0) }
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { a in
                    if let u = a.webpageURL { model.handle(url: u) }
                }
                .tint(Theme.accent)
                .saryShowcaseIfRequested() // DESIGN-SHOWCASE HOOK: DEBUG + `-SaryShowcase` only (Sources/UI/Showcase)
        }
        .onChange(of: phase) { p in model.foreground(p == .active) }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        /* Arabic first: UIKit-hosted pieces (sheets, the map's own controls) lay out RTL too. */
        UIView.appearance().semanticContentAttribute = .forceRightToLeft
        /* A relaunch for a significant location change (`launchOptions[.location]`) needs no
         * special path: AppModel resumes the share it finds recorded, and nothing else. */
        return true
    }

    /// A note from a friend shows as a banner even while the map is open.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

enum Theme {
    /// Brand from the web's design tokens: brand-900 and mint.
    static let ink = Color(red: 0x04 / 255, green: 0x34 / 255, blue: 0x34 / 255)
    static let accent = Color(red: 0x18 / 255, green: 0xA6 / 255, blue: 0x6A / 255)
    static let mint = Color(red: 0x83 / 255, green: 0xF1 / 255, blue: 0xB1 / 255)
    static let amber = Color(red: 1, green: 0xCA / 255, blue: 0x3A / 255)
    static let lost = Color(red: 0.55, green: 0.58, blue: 0.6)

    static func car(_ rgb: UInt32) -> Color {
        Color(red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255)
    }
}
