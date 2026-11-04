import Foundation

/// What «احذف حسابي» needs from the server (fake in tests).
protocol AccountBackend {
    /// DELETE /api/outings/me — leaves every outing, deletes the identity. 404/405 while not deployed.
    func deleteAccount() async throws
    /* The older partial wipe, used only while the server has no DELETE /me yet. */
    func updateProfile(name: String?, phone: String?, avatar: String?) async throws -> PublicUser
    func list() async throws -> OutingsAPI.ListBox
    func withdrawSummary(_ id: String) async throws
    func leave(_ id: String) async throws
}

extension OutingsAPI: AccountBackend {}

/// How «احذف حسابي» ended, said honestly to the person.
enum AccountDeletionOutcome: Equatable {
    /// The server deleted the account; this device forgot it too.
    case deleted
    /// The server cannot delete accounts yet (404/405): we removed what its API allows
    /// (phone, photo, summaries, current outings) and forgot the identity here.
    case wipedLocally(leftOutings: Int)
    /// Nothing was deleted (network, rate limit…): the account is as it was, try again.
    case failed(String)
}

/// The deletion steps in order. Pure orchestration: the server, push and local
/// storage come in from outside, so the unit tests drive it with fakes.
@MainActor
struct AccountDeleter {
    var backend: AccountBackend
    var myUserId: String?
    /// After a server delete: forget the APNs token and stop pushes (nothing to send — the server dropped it).
    var forgetPush: () -> Void
    /// Fallback only: the token still works, so tell the server to drop this device's push token.
    var unregisterPushOnServer: () async -> Void
    /// Identity (Keychain), consent, trip logs, invite links, onboarding — not the downloaded map areas.
    var wipeLocal: () -> Void

    /// The endpoint is missing on an older server (Express 404 / a proxy's 405).
    static func notDeployed(_ e: OutingAPIError) -> Bool { e.status == 404 || e.status == 405 }

    func run() async -> AccountDeletionOutcome {
        do {
            try await backend.deleteAccount()
        } catch let e as OutingAPIError where Self.notDeployed(e) {
            let left = await legacyWipe()
            await unregisterPushOnServer()
            forgetPush()
            wipeLocal()
            return .wipedLocally(leftOutings: left)
        } catch let e as OutingAPIError {
            return .failed(e.arabic)
        } catch {
            return .failed("تعذّر حذف الحساب. أعد المحاولة.")
        }
        forgetPush()
        wipeLocal()
        return .deleted
    }

    /// What the API allows without DELETE /me: phone and photo, my shared summaries, every current outing.
    private func legacyWipe() async -> Int {
        _ = try? await backend.updateProfile(name: nil, phone: "", avatar: "")
        guard let lists = try? await backend.list() else { return 0 }
        for o in lists.history where o.summaries?.contains(where: { $0.user_id == myUserId }) == true {
            try? await backend.withdrawSummary(o.id)
        }
        var left = 0
        for o in lists.current where (try? await backend.leave(o.id)) != nil { left += 1 }
        return left
    }
}

/// Everything this app keeps on the device about the person, except downloaded map
/// areas (Mapbox TileStore), which are map tiles — not about anyone — and stay.
@MainActor
enum LocalAccountData {
    static var keys: [String] {
        [ShareMemory.consentKey, ShareMemory.activeShareKey] + ShareMemory.legacyKeys + [
            TripLogStore.key, InviteTokenStore.key, OnboardingProgress.key,
            PushRegistrar.tokenKey, PushRegistrar.explainedKey, PushRegistrar.enabledKey,
            OutingSession.modeKey, OutingSession.batteryKey,
        ] + TrailPrefs.keys + SpeedPrefs.keys
    }

    static func wipe(defaults: UserDefaults = .standard) {
        IdentityStore.save(nil)
        for k in keys { defaults.removeObject(forKey: k) }
        TrailStore.forgetAll()
    }
}

extension AccountDeletionOutcome {
    /// The notice shown on the onboarding screen afterwards (nil for a failure: that stays on the page).
    var notice: (title: String, message: String)? {
        switch self {
        case .deleted:
            return ("حُذف حسابك", "حذفنا من الخادم اسمك وصورتك ورقمك وعضويتك في كل الطلعات ومواقعك وملخصاتك وتنبيهات هذا الجهاز، ومسحنا هويتك من هذا الجهاز. الخرائط التي نزّلتها بلا إنترنت باقية على جوالك؛ تحذفها من «الخرائط بلا إنترنت».")
        case .wipedLocally(let n):
            return ("مُسحت بياناتك، والحساب لم يُحذف بعد",
                    "الخادم لا يدعم حذف الحساب بعد. مسحنا رقمك وصورتك وملخصاتك، وأخرجناك من \(SaryFormat.number(n)) طلعة، ومسحنا هويتك من هذا الجهاز. يبقى على الخادم اسمك وسجل عضويتك في الطلعات السابقة حتى يُفعّل الحذف. الخرائط التي نزّلتها بلا إنترنت باقية على جوالك.")
        case .failed:
            return nil
        }
    }
}
