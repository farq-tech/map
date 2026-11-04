import XCTest
@testable import SaryAlbarq

/// «احذف حسابي» against a fake API: the order of steps, the 404/405 fallback, and
/// that a failure deletes nothing.
@MainActor
final class AccountDeletionTests: XCTestCase {
    final class FakeAPI: AccountBackend {
        var deleteError: OutingAPIError?
        var calls: [String] = []
        var current: [OutingSummary] = []
        var history: [OutingSummary] = []
        var leaveFails: Set<String> = []

        func deleteAccount() async throws {
            calls.append("DELETE /me")
            if let deleteError { throw deleteError }
        }
        func updateProfile(name: String?, phone: String?, avatar: String?) async throws -> PublicUser {
            calls.append("PATCH /me phone=\(phone ?? "nil") avatar=\(avatar ?? "nil")")
            return PublicUser(id: "me", display_name: "أنا", avatar: nil, phone: nil)
        }
        func list() async throws -> OutingsAPI.ListBox {
            calls.append("GET /")
            return .init(current: current, history: history)
        }
        func withdrawSummary(_ id: String) async throws { calls.append("DELETE /\(id)/summary") }
        func leave(_ id: String) async throws {
            calls.append("POST /\(id)/leave")
            if leaveFails.contains(id) { throw OutingAPIError(code: "not_a_member", status: 404) }
        }
    }

    var api: FakeAPI!
    var steps: [String] = []

    override func setUp() { reset() }

    private func reset() {
        api = FakeAPI()
        steps = []
    }

    private func deleter() -> AccountDeleter {
        AccountDeleter(
            backend: api,
            myUserId: "me",
            forgetPush: { [unowned self] in steps.append("forgetPush") },
            unregisterPushOnServer: { [unowned self] in steps.append("unregisterPushOnServer") },
            wipeLocal: { [unowned self] in steps.append("wipeLocal") }
        )
    }

    private func outing(_ id: String, status: OutingStatus = .active, summaries: [TripShare]? = nil) -> OutingSummary {
        OutingSummary(id: id, name: id, status: status, role: "member", my_status: "active", member_count: 2,
                      created_at: nil, started_at: nil, ended_at: nil, summaries: summaries)
    }

    func testServerDeleteThenPushAndLocalWipe() async {
        let r = await deleter().run()
        XCTAssertEqual(r, .deleted)
        XCTAssertEqual(api.calls, ["DELETE /me"], "one call: the server does the leaving and deleting")
        XCTAssertEqual(steps, ["forgetPush", "wipeLocal"], "no server push call afterwards: the token is dead and the server dropped it")
        XCTAssertNotNil(r.notice)
        XCTAssertTrue(r.notice!.message.contains("الخرائط التي نزّلتها بلا إنترنت باقية"), "says the offline areas stay")
    }

    func testNotDeployedFallsBackToTheOldWipeAndSaysSo() async {
        for status in [404, 405] {
            reset()
            api.deleteError = OutingAPIError(code: "http_\(status)", status: status)
            api.current = [outing("o1"), outing("o2"), outing("gone")]
            api.leaveFails = ["gone"]
            let mine = TripShare(user_id: "me", display_name: "أنا", distance_m: 1, duration_s: 1, moving_s: 1)
            let theirs = TripShare(user_id: "x", display_name: "س", distance_m: 1, duration_s: 1, moving_s: 1)
            api.history = [outing("h1", status: .ended, summaries: [mine]), outing("h2", status: .ended, summaries: [theirs])]
            let r = await deleter().run()
            XCTAssertEqual(r, .wipedLocally(leftOutings: 2), "status \(status)")
            XCTAssertEqual(api.calls, ["DELETE /me", "PATCH /me phone= avatar=", "GET /", "DELETE /h1/summary",
                                       "POST /o1/leave", "POST /o2/leave", "POST /gone/leave"])
            XCTAssertEqual(steps, ["unregisterPushOnServer", "forgetPush", "wipeLocal"], "token still valid: tell the server first")
            let n = r.notice!
            XCTAssertTrue(n.title.contains("لم يُحذف"), "honest: the account itself is not deleted")
            XCTAssertTrue(n.message.contains("الخادم لا يدعم حذف الحساب بعد"))
        }
    }

    func testOtherErrorsDeleteNothing() async {
        for e in [OutingAPIError(code: "network", status: 0), OutingAPIError(code: "rate_limited", status: 429),
                  OutingAPIError(code: "http_500", status: 500), OutingAPIError(code: "unauthorized", status: 401)] {
            reset()
            api.deleteError = e
            let r = await deleter().run()
            XCTAssertEqual(r, .failed(e.arabic), e.code)
            XCTAssertEqual(api.calls, ["DELETE /me"])
            XCTAssertEqual(steps, [], "nothing wiped on \(e.code): the person can try again")
            XCTAssertNil(r.notice)
        }
    }

    func testLocalWipeKeepsAppearanceAndOfflineAreas() {
        let d = UserDefaults(suiteName: "acct-\(UUID().uuidString)")!
        for k in LocalAccountData.keys { d.set("x", forKey: k) }
        d.set("dark", forKey: "sary.appearance.scheme")
        d.set(true, forKey: MapboxTelemetry.key)
        IdentityStore.save(Identity(token: "t".padding(toLength: 43, withPad: "t", startingAt: 0),
                                    user: PublicUser(id: "me", display_name: "أنا", avatar: nil, phone: nil)))
        XCTAssertNotNil(IdentityStore.load())
        LocalAccountData.wipe(defaults: d)
        XCTAssertNil(IdentityStore.load(), "Keychain identity gone")
        for k in LocalAccountData.keys { XCTAssertNil(d.object(forKey: k), k) }
        XCTAssertEqual(d.string(forKey: "sary.appearance.scheme"), "dark", "appearance stays")
        XCTAssertEqual(d.object(forKey: MapboxTelemetry.key) as? Bool, true)
        for k in [ShareMemory.consentKey, TripLogStore.key, InviteTokenStore.key, OnboardingProgress.key, PushRegistrar.tokenKey] {
            XCTAssertTrue(LocalAccountData.keys.contains(k), k)
        }
    }

    func testForgetDeviceStopsApnsWithoutCallingTheServer() async {
        final class Backend: PushBackend {
            var unregistered: [String] = []
            func apnsConfig() async throws -> OutingsAPI.ApnsConfig { .init(enabled: true, bundle_id: "sa.sary.albarq") }
            func registerApns(token: String, environment: String, bundleId: String) async throws {}
            func unregisterApns(token: String) async throws { unregistered.append(token) }
        }
        let backend = Backend()
        let system = PushRegistrarTests.FakeSystem()
        system.status = .authorized
        let d = UserDefaults(suiteName: "acct-push-\(UUID().uuidString)")!
        let r = PushRegistrar(backend: backend, system: system, defaults: d, bundleId: "sa.sary.albarq", environment: "sandbox")
        await r.register("ab".padding(toLength: 64, withPad: "ab", startingAt: 0), signedIn: true)
        XCTAssertEqual(r.state, .registered)
        r.forgetDevice()
        XCTAssertNil(r.registeredToken)
        XCTAssertEqual(system.unregisterCalls, 1)
        XCTAssertEqual(backend.unregistered, [], "the server already dropped it with the account")
        XCTAssertEqual(r.state, .notAsked)
        XCTAssertFalse(r.explained)
    }

    func testDemoModelDeletesAndReturnsToOnboarding() async {
        let m = AppModel(arguments: ["-demo", "-SaryScreen", "privacy"])
        XCTAssertNotNil(m.identity)
        let r = await m.deleteAccount()
        XCTAssertEqual(r, .deleted)
        XCTAssertNil(m.identity, "back to onboarding")
        XCTAssertNil(m.debugScreen)
        XCTAssertEqual(m.accountNotice, .deleted)
        XCTAssertFalse(OnboardingProgress.done)
    }
}
