import Foundation

/// What the launch shows over the app.
enum IntroMode: Equatable {
    /// The cinematic intro (≈4 s, music if «صوت المقدمة» is on), then a crossfade into the app.
    case full
    /// Only the launch screen's night frame, crossfading into the app as soon as it is ready
    /// (the launch screen is the intro's first frame, so this is the seamless "no intro" path).
    case still
    /// Nothing at all: straight to the app (trip in progress, CarPlay, opened for something).
    case none
}

/// Why the intro does not play (for tests and the debug log).
enum IntroSkip: Equatable {
    case notForeground, automation, turnedOff, recentlyShown, openedForSomething, activeTrip, carPlay
}

/// The facts the decision needs, gathered once on a cold launch.
struct IntroFacts: Equatable {
    /// «مقدمة سينمائية عند الفتح» (on by default).
    var enabled = true
    var lastShown: Date?
    var now = Date()
    /// The process was started for the screen (not in the background by PushToTalk,
    /// a location relaunch, a background push…).
    var foregroundLaunch = true
    /// Started to handle something: a deep / invite link, a tapped notification, a Live
    /// Activity tap, a Handoff / universal link, a PushToTalk wake-up.
    var openedForSomething = false
    /// A trip (shared outing) is in progress: the person goes straight to the live map.
    var activeTrip = false
    /// The CarPlay screen is up: never put a show in front of the driver.
    var carPlay = false
    /// UI-test / screenshot automation (DEBUG launch arguments) without `-SaryIntro 1`.
    var automation = false
}

/// «مقدمة سينمائية»: when the cinematic intro plays. Pure — unit-tested in IntroPolicyTests.
enum IntroPolicy {
    /// At most once every 6 hours.
    static let minInterval: TimeInterval = 6 * 60 * 60

    static func skipReason(_ f: IntroFacts) -> IntroSkip? {
        if !f.foregroundLaunch { return .notForeground }
        if f.automation { return .automation }
        if f.carPlay { return .carPlay }
        if f.activeTrip { return .activeTrip }
        if f.openedForSomething { return .openedForSomething }
        if !f.enabled { return .turnedOff }
        /* A clock set backwards (last shown "in the future") does not block the intro forever. */
        if let last = f.lastShown, f.now >= last, f.now.timeIntervalSince(last) < minInterval { return .recentlyShown }
        return nil
    }

    static func mode(_ f: IntroFacts) -> IntroMode {
        switch skipReason(f) {
        case nil: return .full
        case .turnedOff?, .recentlyShown?: return .still
        case .notForeground?, .automation?, .carPlay?, .activeTrip?, .openedForSomething?: return .none
        }
    }

    /// The person's intro setting may also silence it; the silent switch is honoured by
    /// the `.ambient` audio session itself.
    static func playsSound(mode: IntroMode, soundOn: Bool) -> Bool { mode == .full && soundOn }

    /// `UserDefaults` keys (cleared by `-resetState` in DEBUG, see IntroController).
    static let enabledKey = "sary.intro.enabled"
    static let soundKey = "sary.intro.sound"
    static let lastShownKey = "sary.intro.lastShown"
    static var keys: [String] { [enabledKey, soundKey, lastShownKey] }

    static func enabled(_ d: UserDefaults = .standard) -> Bool { d.object(forKey: enabledKey) as? Bool ?? true }
    static func soundOn(_ d: UserDefaults = .standard) -> Bool { d.object(forKey: soundKey) as? Bool ?? true }
    static func lastShown(_ d: UserDefaults = .standard) -> Date? { d.object(forKey: lastShownKey) as? Date }
    static func markShown(_ at: Date = Date(), _ d: UserDefaults = .standard) { d.set(at, forKey: lastShownKey) }

    /// DEBUG launch arguments that mean "an automated run" (UI tests, screenshot scripts):
    /// those launches never see the intro unless they ask for it with `-SaryIntro 1`.
    static func isAutomation(_ args: [String], environment: [String: String] = [:]) -> Bool {
        if let i = args.firstIndex(of: "-SaryIntro"), i + 1 < args.count { return args[i + 1] != "1" }
        if environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil { return true }
        return args.contains { $0 == "-resetState" || $0 == "-demo" || ($0.hasPrefix("-Sary") && !$0.hasPrefix("-SaryIntro")) }
    }
}
