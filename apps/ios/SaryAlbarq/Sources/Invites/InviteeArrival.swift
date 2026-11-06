import Foundation

/// The first seconds in the trip after an invite (build 21): the person lands in the trip's
/// atmosphere — the live map, the convoy, the destination, «تردد ١» and the voice notes ready —
/// with no tutorial over the map. Three small things sit at the top, none of them blocking:
///
///   * «نحدد موقعك… ±٣٥ م» until a good fix arrives (then the camera frames me, the live cars
///     and the destination together);
///   * a one-time welcome card «حياك في كشتة النفود الكبير — الوجهة روضة خريم، معك ٤» for a few seconds;
///   * «موقعك مو ظاهر للعيال» with «افتح الإعدادات» for as long as my position does not reach the group
///     (location refused, or «الموقع الدقيق» off: approximate fixes are never sent, `Policy.sendMaxAccuracyM`).
///
/// Pure, so the rules are unit tested (InviteeArrivalTests).
enum InviteeArrival {
    /// A fix this good frames the camera at once (the GPS state's own «ok» line).
    static let goodAccuracyM = Policy.weakAccuracyM
    /// After this long, anything we would send is good enough to frame (Low Power Mode parks the
    /// GPS at ~100 m; the camera should not wait for a fix that will not come).
    static let relaxAfterS: TimeInterval = 15
    /// Older fixes are not "where I am now" (never frame a stale position as live).
    static let freshS: TimeInterval = 15
    /// «نحدد موقعك…» adds a hint after this long without a good fix.
    static let slowAfterS: TimeInterval = 30
    /// How long the welcome card stays.
    static let welcomeSeconds: TimeInterval = 7

    /// Is this fix good enough to say "this is where you are" and frame the camera on it?
    static func isGoodFix(accuracyM: Double?, ageS: TimeInterval, sinceArrivalS: TimeInterval) -> Bool {
        guard let a = accuracyM, a >= 0, ageS >= 0, ageS <= freshS else { return false }
        if a <= goodAccuracyM { return true }
        return sinceArrivalS >= relaxAfterS && a <= Policy.sendMaxAccuracyM
    }

    /// «نحدد موقعك…» (with the accuracy of a fresh fix, if any), or nil when not shown.
    static func locatingText(accuracyM: Double?, ageS: TimeInterval?, sinceArrivalS: TimeInterval) -> String {
        var t = "نحدد موقعك…"
        if let a = accuracyM, let age = ageS, age <= freshS, a >= 0 {
            t += " الدقة ±\(SaryFormat.number(Int(a.rounded()))) م"
        }
        if sinceArrivalS >= slowAfterS { t += " — جرّب مكان مكشوف" }
        return t
    }

    /// «حياك في كشتة النفود الكبير — الوجهة روضة خريم، معك ٤». `others`: members besides me.
    static func welcome(trip: String, destination: String?, others: Int) -> String {
        let name = trip.trimmingCharacters(in: .whitespacesAndNewlines)
        var parts: [String] = []
        if let d = destination?.trimmingCharacters(in: .whitespacesAndNewlines), !d.isEmpty { parts.append("الوجهة \(d)") }
        if others > 0 { parts.append("معك \(SaryFormat.number(others))") }
        let head = name.isEmpty ? "حياك في الطلعة" : "حياك في \(name)"
        return parts.isEmpty ? head : "\(head) — \(parts.joined(separator: "، "))"
    }

    /// My position is not reaching the group although I am a member: refused, or approximate only.
    /// nil while it does (or while the trip is over).
    static func hidden(member: Bool, tripOver: Bool, permission: JoinPermission) -> JoinPermission? {
        guard member, !tripOver else { return nil }
        switch permission {
        case .denied, .reduced: return permission
        case .granted, .notAsked: return nil
        }
    }

    // MARK: one-time welcome

    static let welcomedKey = "sary.invite.welcomed.v1"

    /// The welcome card shows once per trip on this phone.
    static func shouldWelcome(outing: String, defaults: UserDefaults = .standard) -> Bool {
        !(defaults.stringArray(forKey: welcomedKey) ?? []).contains(outing)
    }

    static func markWelcomed(outing: String, defaults: UserDefaults = .standard) {
        var all = defaults.stringArray(forKey: welcomedKey) ?? []
        guard !all.contains(outing) else { return }
        all.append(outing)
        defaults.set(Array(all.suffix(50)), forKey: welcomedKey)
    }
}

/// The arrival's state on the live screen (`LiveOutingController+Arrival.swift`).
struct InviteeArrivalState: Equatable {
    /// Arrived by an invite on this screen.
    var startedAt: Date?
    /// The camera framed me (a good fix came) — «نحدد موقعك…» is gone.
    var located = false
    /// The welcome card is up until then (nil: not shown / not yet: waits for the trip's snapshot).
    var welcomeUntil: Date?
    var welcomePending = false
    /// The camera framed the trip without me (view mode / waiting for a fix).
    var framedWithoutMe = false

    var active: Bool { startedAt != nil }
}

/// The invite link waiting on the pasteboard after an App Store / TestFlight install (the web
/// invite page copies it on «نزّل التطبيق»). Nothing is read without the person's tap: the
/// first page only shows «كمّل دعوتك» with the system «لصق» button when iOS says the pasteboard
/// probably holds a link (`UIPasteboard.detectPatterns`, which does not show the paste banner).
enum DeferredInvite {
    /// The first launch on this phone (no identity yet) is the only time we look.
    static func shouldLook(hasIdentity: Bool, pendingInvite: Bool, isDemo: Bool) -> Bool {
        !hasIdentity && !pendingInvite && !isDemo
    }

    /// What the «لصق» button brought: an invite token, or nil (anything else is ignored).
    static func token(fromPasted strings: [String]) -> String? {
        for s in strings { if let t = InviteLink.token(fromPasted: s) { return t } }
        return nil
    }
}
