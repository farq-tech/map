import Foundation

/// The one rule for when this phone may put a position on the wire. Pure, so
/// it is tested on its own and then enforced at the last step before the
/// network (`LiveChannel` in the foreground, `BackgroundPositionSender` in the
/// background), not only in the screen.
///
/// The server's own `sharing` flag is NOT consent: the server sets it to true
/// when someone joins. A position leaves the phone only when ALL hold:
///
///   * this identity gave consent for this outing on this device (the consent
///     sheet) — recorded per identity, so a later sign-in never inherits it;
///   * iOS location permission is granted;
///   * the person pressed «شارك موقعي» (and has not pressed stop since);
///   * the server agrees sharing is on for this member;
///   * the outing is active and the session is not closed;
///   * the app is on screen — OR iOS permission is «دائمًا» (owner decision,
///     2026-11: once the member chose to share, sharing keeps going with the
///     screen locked / in another app until they stop, leave, are removed, or
///     the outing ends). With «أثناء الاستخدام» only, nothing is sent from the
///     background.
struct SendGate: Equatable {
    var consent = false
    var osAuthorized = false
    var userWantsShare = false
    var serverSharing = false
    var outingActive = false
    var foreground = false
    var closed = false
    /// iOS location permission is «دائمًا» (Always).
    var alwaysAuthorized = false

    /// Everything except where the app is (screen / background).
    private var intentOpen: Bool {
        consent && osAuthorized && userWantsShare && serverSharing && outingActive && !closed
    }

    var allowsPosition: Bool { intentOpen && (foreground || alwaysAuthorized) }

    /// Allowed, and the app is off screen: send over HTTP (`BackgroundPositionSender`), not the socket.
    var allowsBackgroundPosition: Bool { intentOpen && !foreground && alwaysAuthorized }

    /// An SOS goes out on a 1 s hold even with sharing off (it is the decision
    /// to be found), but it carries a position only when the same gate is open.
    var allowsSosFix: Bool { allowsPosition }
}

/// Per-identity, per-outing consent and "was sharing" memory.
///
/// Keys are `userId|outingId`, so signing out and in as someone else (or a new
/// test identity on the same phone) never inherits an earlier person's consent
/// or a share that was running before.
enum ShareMemory {
    static let consentKey = "sary.outings.consent.v2"
    static let activeShareKey = "sary.outings.activeShare.v2"
    /// v1 stored bare outing ids (not tied to an identity): never honoured, removed on launch.
    static let legacyKeys = ["sary.outings.consent.v1", "sary.outings.activeShare.v1"]

    static func key(user: String, outing: String) -> String { "\(user)|\(outing)" }

    static func hasConsent(user: String, outing: String, defaults: UserDefaults = .standard) -> Bool {
        (defaults.stringArray(forKey: consentKey) ?? []).contains(key(user: user, outing: outing))
    }

    static func recordConsent(user: String, outing: String, defaults: UserDefaults = .standard) {
        var all = defaults.stringArray(forKey: consentKey) ?? []
        let k = key(user: user, outing: outing)
        if !all.contains(k) { all.append(k) }
        defaults.set(all, forKey: consentKey)
    }

    /// The line shown on «انضم» (and on the creator's last wizard step): tapping it is the consent.
    static let joinStatement = "بانضمامك يشوف أعضاء الطلعة موقعك مباشرة، وتقدر توقف المشاركة أو تطلع متى ما بغيت"

    /// Owner decision (build 6): joining IS the consent. Tapping «انضم» (or creating the outing)
    /// records consent for this identity + outing at that moment and arms the share, so the
    /// member is visible without pressing «شارك موقعي». Every other `SendGate` condition still
    /// holds (iOS permission, active outing, server sharing on, not stopped / left / ended).
    static func consentByJoining(user: String, outing: String, defaults: UserDefaults = .standard) {
        recordConsent(user: user, outing: outing, defaults: defaults)
        setActiveShare(user: user, outing: outing, defaults: defaults)
    }

    static func activeShare(user: String, defaults: UserDefaults = .standard) -> String? {
        guard let v = defaults.string(forKey: activeShareKey) else { return nil }
        let parts = v.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[0] == user else { return nil }
        return parts[1]
    }

    static func setActiveShare(user: String, outing: String?, defaults: UserDefaults = .standard) {
        if let outing {
            defaults.set(key(user: user, outing: outing), forKey: activeShareKey)
        } else if activeShare(user: user, defaults: defaults) != nil {
            defaults.removeObject(forKey: activeShareKey)
        }
    }

    static func forgetAll(defaults: UserDefaults = .standard) {
        for k in [consentKey, activeShareKey] + legacyKeys { defaults.removeObject(forKey: k) }
    }

    static func dropLegacy(defaults: UserDefaults = .standard) {
        for k in legacyKeys { defaults.removeObject(forKey: k) }
    }
}
