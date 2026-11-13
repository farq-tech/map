import Foundation

/// Build 46: the switch for the new interface («الواجهة الجديدة (تجريبي)»). Build 48.2: ON by default in release
/// builds (the owner asked to use it without opening Settings); an explicit choice in «متقدم» still wins.
/// DEBUG/test builds keep the legacy default so the UI suites stay valid (`-SaryNewUI` turns it on there).
/// Screens branch on `NewUI.enabled` while the redesign lands in small steps; the legacy UI stays the fallback.
enum NewUI {
    static let key = "sary.newUI"
    static let argument = "-SaryNewUI"
    static let legacyArgument = "-SaryLegacyUI"
    /// «متقدم» → the switch (the owner turns it on from TestFlight, no Terminal).
    static let settingsTitle = "الواجهة الجديدة (تجريبي)"
    static let settingsDetail = "تعرض الشاشات بالتصميم الجديد. ارجع للإيقاف إذا لقيت شي غريب."

    /// UserDefaults key (TestFlight internal builds); in DEBUG the launch arguments win
    /// (`-SaryLegacyUI` forces off over `-SaryNewUI`).
    static func isOn(defaults: UserDefaults = .standard, arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        #if DEBUG
        if arguments.contains(legacyArgument) { return false }
        if arguments.contains(argument) { return true }
        #endif
        if defaults.object(forKey: key) != nil { return defaults.bool(forKey: key) }
        return defaultOn
    }

    /// What an unset switch means: on in release builds, off in DEBUG/test builds (the Settings row shows the same).
    static var defaultOn: Bool {
        #if DEBUG
        return false
        #else
        return true
        #endif
    }

    static var enabled: Bool { isOn() }
}
