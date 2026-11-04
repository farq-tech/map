import Foundation

/// The one rule for when this phone may put a position on the wire. Pure, so
/// it is tested on its own and then enforced at the last step before the
/// network (`LiveChannel`), not only in the screen.
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
///   * the app is in the foreground — nothing is sent from the background.
struct SendGate: Equatable {
    var consent = false
    var osAuthorized = false
    var userWantsShare = false
    var serverSharing = false
    var outingActive = false
    var foreground = false
    var closed = false

    var allowsPosition: Bool {
        consent && osAuthorized && userWantsShare && serverSharing && outingActive && foreground && !closed
    }

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
