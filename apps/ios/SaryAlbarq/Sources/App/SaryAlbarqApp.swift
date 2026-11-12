import MapboxCommon
import MapboxMaps
import SwiftUI
import UserNotifications

@main
struct SaryAlbarqApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppBoot.model
    @State private var appearance = AppearanceSettings.launch()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .onAppear { AppDelegate.model = model }
                /* Farq's streets and places (apps/tiles): once the server answers, maps switch to them. */
                .task { await FarqTiles.check() }
                /* Older bare «نقطة على الخريطة» recent places get their names once per launch (`PlaceNamer`). */
                .task { RecentPlaces.nameOncePerLaunch() }
                /* «دليل البر» (a large bundled file): read off the main thread soon after launch. */
                .task { DesertGazetteer.prewarm() }
                .environmentObject(model)
                .environmentObject(model.location)
                .environment(\.layoutDirection, .rightToLeft)
                .environment(\.locale, Locale(identifier: "ar"))
                .onOpenURL { IntroController.shared.interrupt(); model.handle(url: $0) }
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { a in
                    IntroController.shared.interrupt()
                    if let u = a.webpageURL { model.handle(url: u) }
                }
                .saryCinematicIntro(model) // CINEMATIC INTRO HOOK: cold launch only, rules in Sources/Intro/IntroPolicy.swift
                .saryAppearance(appearance)
                .saryShowcaseIfRequested() // DESIGN-SHOWCASE HOOK: DEBUG + `-SaryShowcase` only (Sources/UI/Showcase)
                .saryCarPlayPreviewIfRequested() // CARPLAY PREVIEW HOOK: DEBUG + `-SaryCarPlayPreview` only (Sources/CarPlay)
        }
        /* Only .background is "left the screen". `.inactive` (Control Center, notification shade,
         * an incoming-call banner, a system prompt) used to stop the GPS and cut «مساري» into gaps. */
        .onChange(of: phase) { p in
            switch p {
            case .active: model.foreground(true)
            case .background: model.foreground(false)
            default: break
            }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    /// The app's model, for the push callbacks UIKit delivers here.
    @MainActor static weak var model: AppModel? {
        /* CarPlay may connect before the phone UI: it waits for this. */
        didSet { NotificationCenter.default.post(name: .saryModelReady, object: nil) }
    }

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
        let chat = PushRegistrar.chatWith(from: info)
        await MainActor.run {
            /* «المحادثات»: a chat notification opens that conversation, inside its trip. */
            if let chat { ChatDeepLink.request(outingId: id, with: chat) }
            NotificationCenter.default.post(name: .saryOpenOuting, object: id)
        }
    }

    /// Local notifications carry the outing in their thread id ("outing-<id>").
    nonisolated static func localOutingId(_ r: UNNotificationRequest) -> String? {
        let t = r.content.threadIdentifier
        for p in ["sary-outing-", "outing-"] where t.hasPrefix(p) { return String(t.dropFirst(p.count)) }
        return nil
    }

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        /* «أداء التطبيق» (docs/METRICS.md): only the MetricKit registration and one signpost here;
         * payloads are parsed and saved on the collector's own queue when iOS delivers them. */
        MetricsCollector.shared.start()
        /* A background relaunch (location) has no map until the person opens the app: not a launch. */
        if MainActor.assumeIsolated({ application.applicationState != .background }) { PerfSignpost.begin(.launchToMap) }
        /* Arabic first: UIKit-hosted pieces (sheets, the map's own controls) lay out RTL too. */
        UIView.appearance().semanticContentAttribute = .forceRightToLeft
        /* Relaunched by iOS in the background for location (significant change / region exit
         * while sharing with «دائمًا»): build the model now so the share resumes without UI. */
        if launchOptions?[.location] != nil {
            MainActor.assumeIsolated {
                let m = AppBoot.model
                Self.model = m
            }
        } else {
            /* The Arabic satellite style every first map loads: read and graded off the main thread
             * now, before SwiftUI builds the first screen (no map, no UI work here). */
            ArabicBasemap.prewarm()
        }
        return true
    }

    /// Swiped away / terminated while running: tell the trip why we go quiet (presence hint).
    func applicationWillTerminate(_ application: UIApplication) {
        MainActor.assumeIsolated { Self.model?.session?.appWillTerminate() }
    }

    /// The offline backfill finished uploading while the app was suspended / not running.
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier == BackfillUploader.sessionId else { return completionHandler() }
        BackfillUploader.shared.backgroundCompletion = completionHandler
        BackfillUploader.shared.resume()
    }

    /// While the app is open, notes and SOS go to the in-app alert lane / SOS screen, not a banner.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        /* On screen, the live map's alert lane already shows notes and SOS; a banner would say it twice. */
        let id = notification.request.identifier
        /* «موقعك مخفي من ٣٠ د، تبي تظهره؟» is for this person now, even on screen. */
        if id.hasPrefix("sary-hidden-") { return [.banner, .list] }
        return id.hasPrefix("sos-") ? [.sound, .list] : [.list]
    }
}

extension AppearanceSettings {
    /// The app's one settings object. DEBUG builds accept screenshot overrides:
    /// `-SaryScheme light|dark`, `-SaryDrive 1`, `-SaryNight 1`, `-SaryFallback 1`.
    static func launch(_ args: [String] = ProcessInfo.processInfo.arguments) -> AppearanceSettings {
        #if DEBUG
        /* Test isolation: `-SaryDrive 1` etc. are saved like the person's own choice, so a
           `-resetState` run starts from the default appearance, not the previous test's. */
        if args.contains("-resetState") { UserDefaults.standard.removeObject(forKey: storageKey) }
        #endif
        let s = AppearanceSettings()
        #if DEBUG
        func arg(_ k: String) -> String? { args.firstIndex(of: k).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        if let v = arg("-SaryScheme") { s.prefs.colorScheme = v == "dark" ? .dark : v == "light" ? .light : .system }
        if arg("-SaryDrive") == "1" { s.prefs.driveMode = .on }
        if arg("-SaryDrive") == "0" { s.prefs.driveMode = .off }
        if arg("-SaryNight") == "1" { s.prefs.nightMode = .on }
        if arg("-SaryNight") == "0" { s.prefs.nightMode = .off }
        if let c = SaryThemeChoice.fromArguments(args) { s.themeChoice = c }
        if arg("-SaryFallback") == "1" { s.forceGlassFallback = true }
        /* Offline proof: cut the Mapbox stack off the network; the map must draw from the TileStore. */
        if args.contains("-SaryMapboxOffline") { OfflineSwitch.getInstance().setMapboxStackConnectedForConnected(false) }
        /* …and with the ambient cache emptied, whatever draws comes from a saved tile region. */
        if args.contains("-SaryClearAmbient") { TileStore.default.clearAmbientCache(completion: { (_: Result<UInt32, any Error>) in }) }
        #endif
        return s
    }
}

extension Notification.Name {
    static let saryModelReady = Notification.Name("sary.model.ready")
}
