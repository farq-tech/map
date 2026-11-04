import Foundation
import UIKit
import UserNotifications

/// What the server's iOS push endpoints look like to the registrar (fake in tests).
protocol PushBackend {
    func apnsConfig() async throws -> OutingsAPI.ApnsConfig
    func registerApns(token: String, environment: String, bundleId: String) async throws
    func unregisterApns(token: String) async throws
}

extension OutingsAPI: PushBackend {}

/// The system side: permission and the APNs device token (fake in tests).
protocol PushSystem {
    func authorization() async -> UNAuthorizationStatus
    /// Shows the system prompt (only ever after our own Arabic explainer).
    func requestAuthorization() async -> Bool
    func registerForRemoteNotifications()
    /// Account deleted: this app stops receiving pushes on this device (a new identity registers again).
    func unregisterForRemoteNotifications()
}

struct LivePushSystem: PushSystem {
    func authorization() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }
    func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }
    func registerForRemoteNotifications() {
        Task { @MainActor in UIApplication.shared.registerForRemoteNotifications() }
    }
    func unregisterForRemoteNotifications() {
        Task { @MainActor in UIApplication.shared.unregisterForRemoteNotifications() }
    }
}

/// Where notifications stand, said honestly in settings.
enum PushState: Equatable {
    /// The person turned them off in the app.
    case off
    /// The system has not asked yet (we ask only after our explainer).
    case notAsked
    /// Refused in iOS Settings.
    case denied
    /// Allowed; waiting for Apple's device token.
    case waitingForToken
    /// Allowed, but the server does not send iOS notifications yet (APNs not switched on there).
    case serverNotReady
    /// Registered: SOS and messages arrive even with the app closed.
    case registered
    /// Allowed, registering failed (network, rate limit…); retried on next launch.
    case failed(String)
}

/// Registers this device's APNs token with the server for the signed-in identity,
/// replaces it when Apple rotates it, and removes it when notifications are turned
/// off or the person signs out.
@MainActor
final class PushRegistrar: ObservableObject {
    @Published private(set) var state: PushState = .notAsked

    private let backend: PushBackend
    private let system: PushSystem
    private let defaults: UserDefaults
    private let bundleId: String
    let environment: String

    static let enabledKey = "sary.outings.notify.v1"
    static let tokenKey = "sary.push.apns.token.v1"
    static let explainedKey = "sary.push.explained.v1"

    /// Debug builds talk to APNs sandbox, Release to production (from the build, not the entitlement file).
    nonisolated static var buildEnvironment: String {
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }

    init(backend: PushBackend, system: PushSystem = LivePushSystem(), defaults: UserDefaults = .standard,
         bundleId: String = Bundle.main.bundleIdentifier ?? "sa.sary.albarq", environment: String = PushRegistrar.buildEnvironment) {
        self.backend = backend
        self.system = system
        self.defaults = defaults
        self.bundleId = bundleId
        self.environment = environment
    }

    /// In-app switch (default on). Off removes this device from the server.
    var enabled: Bool { defaults.object(forKey: Self.enabledKey) as? Bool ?? true }
    /// The token the server has for this device, if any.
    var registeredToken: String? { defaults.string(forKey: Self.tokenKey) }
    /// The explainer was shown once (after joining, or in settings).
    var explained: Bool {
        get { defaults.bool(forKey: Self.explainedKey) }
        set { defaults.set(newValue, forKey: Self.explainedKey) }
    }

    /// On launch / foreground: re-read the system state; if allowed, ask Apple for the token again (cheap).
    func refresh(signedIn: Bool) async {
        guard enabled else { state = .off; return }
        switch await system.authorization() {
        case .notDetermined: state = .notAsked
        case .denied: state = .denied
        default:
            if signedIn {
                if state != .registered && state != .serverNotReady { state = .waitingForToken }
                system.registerForRemoteNotifications()
            }
        }
    }

    /// After our explainer: the system prompt, then the token.
    @discardableResult
    func ask(signedIn: Bool) async -> Bool {
        explained = true
        defaults.set(true, forKey: Self.enabledKey)
        let ok = await system.requestAuthorization()
        if ok {
            state = .waitingForToken
            if signedIn { system.registerForRemoteNotifications() }
        } else {
            state = .denied
        }
        return ok
    }

    /// Apple gave us a device token.
    func didReceive(deviceToken: Data, signedIn: Bool) async {
        await register(Self.hex(deviceToken), signedIn: signedIn)
    }

    #if DEBUG
    /// Screenshots in demo mode: show the state the production server gives today.
    func debugShow(_ s: PushState) { state = s }
    #endif

    func didFail() { if enabled { state = .failed("تعذّر الحصول على رمز التنبيهات من Apple.") } }

    func register(_ token: String, signedIn: Bool) async {
        guard enabled else { state = .off; return }
        guard signedIn else { return }
        do {
            let cfg = try await backend.apnsConfig()
            guard cfg.enabled else { state = .serverNotReady; return }
            try await backend.registerApns(token: token, environment: environment, bundleId: bundleId)
            /* Apple rotated the token: the old one is dead weight on the server. */
            if let old = registeredToken, old != token { try? await backend.unregisterApns(token: old) }
            defaults.set(token, forKey: Self.tokenKey)
            state = .registered
        } catch let e as OutingAPIError {
            if e.code == "apns_disabled" || e.status == 503 || e.status == 404 { state = .serverNotReady } else { state = .failed(e.arabic) }
        } catch {
            state = .failed("تعذّر تسجيل التنبيهات.")
        }
    }

    /// The in-app switch.
    func setEnabled(_ on: Bool, signedIn: Bool) async {
        defaults.set(on, forKey: Self.enabledKey)
        if on {
            await refresh(signedIn: signedIn)
        } else {
            await unregister()
            state = .off
        }
    }

    /// Remove this device from the server (switch off, or sign-out while the token still works).
    func unregister() async {
        guard let t = registeredToken else { return }
        try? await backend.unregisterApns(token: t)
        defaults.removeObject(forKey: Self.tokenKey)
    }

    /// After the account is deleted: the server already dropped this device's token with the
    /// identity, so nothing is sent; forget it here and stop APNs delivery to this install.
    func forgetDevice() {
        defaults.removeObject(forKey: Self.tokenKey)
        defaults.removeObject(forKey: Self.explainedKey)
        defaults.removeObject(forKey: Self.enabledKey)
        system.unregisterForRemoteNotifications()
        state = .notAsked
    }

    static func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

    /// Which outing a tapped notification is about (`outing_id`, or `url` "/outings/<id>").
    static func outingId(from userInfo: [AnyHashable: Any]) -> String? {
        if let id = userInfo["outing_id"] as? String, !id.isEmpty { return id }
        if let u = userInfo["url"] as? String, let r = u.range(of: "/outings/") {
            let id = u[r.upperBound...].split(separator: "/").first.map(String.init) ?? ""
            return id.isEmpty ? nil : id
        }
        return nil
    }
}

extension Notification.Name {
    /// A notification about an outing was tapped: open it.
    static let saryOpenOuting = Notification.Name("sary.openOuting")
}
