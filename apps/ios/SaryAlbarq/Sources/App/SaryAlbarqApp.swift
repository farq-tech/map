import MapboxCommon
import MapboxMaps
import SwiftUI
import UserNotifications

@main
struct SaryAlbarqApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    @State private var appearance = AppearanceSettings.launch()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .onAppear { AppDelegate.model = model }
                .environmentObject(model)
                .environmentObject(model.location)
                .environment(\.layoutDirection, .rightToLeft)
                .environment(\.locale, Locale(identifier: "ar"))
                .onOpenURL { model.handle(url: $0) }
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { a in
                    if let u = a.webpageURL { model.handle(url: u) }
                }
                .saryAppearance(appearance)
                .saryShowcaseIfRequested() // DESIGN-SHOWCASE HOOK: DEBUG + `-SaryShowcase` only (Sources/UI/Showcase)
        }
        .onChange(of: phase) { p in model.foreground(p == .active) }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    /// The app's model, for the push callbacks UIKit delivers here.
    @MainActor static weak var model: AppModel?

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in
            guard let m = Self.model, !m.isDemo else { return }
            await m.push.didReceive(deviceToken: deviceToken, signedIn: m.signedIn)
        }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in Self.model?.push.didFail() }
    }

    /// A tapped notification (push or local) opens its outing.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let id = PushRegistrar.outingId(from: info) ?? Self.localOutingId(response.notification.request)
        guard let id else { return }
        await MainActor.run { NotificationCenter.default.post(name: .saryOpenOuting, object: id) }
    }

    /// Local notifications carry the outing in their thread id ("outing-<id>").
    nonisolated static func localOutingId(_ r: UNNotificationRequest) -> String? {
        let t = r.content.threadIdentifier
        for p in ["sary-outing-", "outing-"] where t.hasPrefix(p) { return String(t.dropFirst(p.count)) }
        return nil
    }

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        /* Arabic first: UIKit-hosted pieces (sheets, the map's own controls) lay out RTL too. */
        UIView.appearance().semanticContentAttribute = .forceRightToLeft
        /* No background location: nothing to resume for a location relaunch. */
        return true
    }

    /// While the app is open, notes and SOS go to the in-app alert lane / SOS screen, not a banner.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        /* On screen, the live map's alert lane already shows notes and SOS; a banner would say it twice. */
        notification.request.identifier.hasPrefix("sos-") ? [.sound, .list] : [.list]
    }
}

extension AppearanceSettings {
    /// The app's one settings object. DEBUG builds accept screenshot overrides:
    /// `-SaryScheme light|dark`, `-SaryDrive 1`, `-SaryNight 1`, `-SaryFallback 1`.
    static func launch(_ args: [String] = ProcessInfo.processInfo.arguments) -> AppearanceSettings {
        let s = AppearanceSettings()
        #if DEBUG
        func arg(_ k: String) -> String? { args.firstIndex(of: k).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        if let v = arg("-SaryScheme") { s.prefs.colorScheme = v == "dark" ? .dark : v == "light" ? .light : .system }
        if arg("-SaryDrive") == "1" { s.prefs.driveMode = .on }
        if arg("-SaryDrive") == "0" { s.prefs.driveMode = .off }
        if arg("-SaryNight") == "1" { s.prefs.nightMode = .on }
        if arg("-SaryNight") == "0" { s.prefs.nightMode = .off }
        if arg("-SaryFallback") == "1" { s.forceGlassFallback = true }
        /* Offline proof: cut the Mapbox stack off the network; the map must draw from the TileStore. */
        if args.contains("-SaryMapboxOffline") { OfflineSwitch.getInstance().setMapboxStackConnectedForConnected(false) }
        /* …and with the ambient cache emptied, whatever draws comes from a saved tile region. */
        if args.contains("-SaryClearAmbient") { TileStore.default.clearAmbientCache(completion: { (_: Result<UInt32, any Error>) in }) }
        #endif
        return s
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
