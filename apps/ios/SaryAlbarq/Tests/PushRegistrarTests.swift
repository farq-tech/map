import UserNotifications
import XCTest
@testable import SaryAlbarq

/// iOS push registration against a fake server and a fake system.
@MainActor
final class PushRegistrarTests: XCTestCase {
    final class FakeBackend: PushBackend {
        var enabled = true
        var registerError: OutingAPIError?
        var registered: [(token: String, env: String, bundle: String)] = []
        var unregistered: [String] = []
        func apnsConfig() async throws -> OutingsAPI.ApnsConfig { .init(enabled: enabled, bundle_id: "sa.sary.albarq") }
        func registerApns(token: String, environment: String, bundleId: String) async throws {
            if let registerError { throw registerError }
            registered.append((token, environment, bundleId))
        }
        func unregisterApns(token: String) async throws { unregistered.append(token) }
    }

    final class FakeSystem: PushSystem {
        var status: UNAuthorizationStatus = .notDetermined
        var grant = true
        var asked = 0
        var registerCalls = 0
        func authorization() async -> UNAuthorizationStatus { status }
        func requestAuthorization() async -> Bool { asked += 1; status = grant ? .authorized : .denied; return grant }
        func registerForRemoteNotifications() { registerCalls += 1 }
        var unregisterCalls = 0
        func unregisterForRemoteNotifications() { unregisterCalls += 1 }
    }

    var defaults: UserDefaults!
    var backend: FakeBackend!
    var system: FakeSystem!

    override func setUp() {
        defaults = UserDefaults(suiteName: "push-\(UUID().uuidString)")
        backend = FakeBackend()
        system = FakeSystem()
    }

    func make(env: String = "sandbox") -> PushRegistrar {
        PushRegistrar(backend: backend, system: system, defaults: defaults, bundleId: "sa.sary.albarq", environment: env)
    }

    func testNeverAsksOnLaunchOnlyAfterExplainer() async {
        let r = make()
        await r.refresh(signedIn: true)
        XCTAssertEqual(r.state, .notAsked)
        XCTAssertEqual(system.asked, 0, "launch never shows the system prompt")
        XCTAssertEqual(system.registerCalls, 0)
        let ok = await r.ask(signedIn: true)
        XCTAssertTrue(ok)
        XCTAssertEqual(system.asked, 1)
        XCTAssertTrue(r.explained)
        XCTAssertEqual(system.registerCalls, 1)
        XCTAssertEqual(r.state, .waitingForToken)
    }

    func testRegistersTokenWithEnvironmentAndBundle() async {
        let r = make(env: "production")
        await r.didReceive(deviceToken: Data([0xAB, 0x01, 0xFF]), signedIn: true)
        XCTAssertEqual(r.state, .registered)
        XCTAssertEqual(backend.registered.count, 1)
        XCTAssertEqual(backend.registered[0].token, "ab01ff")
        XCTAssertEqual(backend.registered[0].env, "production")
        XCTAssertEqual(backend.registered[0].bundle, "sa.sary.albarq")
        XCTAssertEqual(r.registeredToken, "ab01ff")
    }

    func testServerWithoutApnsIsNotAnError() async {
        backend.enabled = false
        let r = make()
        await r.register("aa", signedIn: true)
        XCTAssertEqual(r.state, .serverNotReady)
        XCTAssertTrue(backend.registered.isEmpty)

        backend.enabled = true
        backend.registerError = OutingAPIError(code: "apns_disabled", status: 503)
        await r.register("aa", signedIn: true)
        XCTAssertEqual(r.state, .serverNotReady)
        XCTAssertNil(r.registeredToken)
    }

    func testOtherErrorsAreShownHonestly() async {
        backend.registerError = OutingAPIError(code: "rate_limited", status: 429)
        let r = make()
        await r.register("aa", signedIn: true)
        guard case .failed = r.state else { return XCTFail("\(r.state)") }
    }

    func testTokenChangeReplacesTheOldOne() async {
        let r = make()
        await r.register("old", signedIn: true)
        await r.register("new", signedIn: true)
        XCTAssertEqual(backend.unregistered, ["old"])
        XCTAssertEqual(r.registeredToken, "new")
        /* Same token again: nothing to remove. */
        await r.register("new", signedIn: true)
        XCTAssertEqual(backend.unregistered, ["old"])
    }

    func testTurningOffUnregistersAndStaysOff() async {
        let r = make()
        await r.register("tok", signedIn: true)
        await r.setEnabled(false, signedIn: true)
        XCTAssertEqual(backend.unregistered, ["tok"])
        XCTAssertNil(r.registeredToken)
        XCTAssertEqual(r.state, .off)
        await r.register("tok", signedIn: true)
        XCTAssertEqual(backend.registered.count, 1, "off means off, even if Apple hands us a token")
    }

    func testSignOutUnregisters() async {
        let r = make()
        await r.register("tok", signedIn: true)
        await r.unregister()
        XCTAssertEqual(backend.unregistered, ["tok"])
        XCTAssertNil(r.registeredToken)
    }

    func testNoIdentityNoRegistration() async {
        let r = make()
        await r.register("tok", signedIn: false)
        XCTAssertTrue(backend.registered.isEmpty)
    }

    func testDeniedIsReported() async {
        system.grant = false
        let r = make()
        let ok = await r.ask(signedIn: true)
        XCTAssertFalse(ok)
        XCTAssertEqual(r.state, .denied)
    }

    func testTappedNotificationOpensItsOuting() {
        XCTAssertEqual(PushRegistrar.outingId(from: ["outing_id": "abc", "type": "sos"]), "abc")
        XCTAssertEqual(PushRegistrar.outingId(from: ["url": "/outings/xyz"]), "xyz")
        XCTAssertNil(PushRegistrar.outingId(from: ["type": "note"]))
    }

    func testBuildEnvironmentIsSandboxInDebug() {
        #if DEBUG
        XCTAssertEqual(PushRegistrar.buildEnvironment, "sandbox")
        #else
        XCTAssertEqual(PushRegistrar.buildEnvironment, "production")
        #endif
    }
}
