import Foundation

// docs/EXPLORE-MERGE.md EM1: the navigation map without a trip («الوضع الخامل»). Pure rules, no UI.

/// `sary.oneMap`: the internal switch for the idle navigation map as the first screen. Off by default.
enum OneMapFlag {
    static let key = "sary.oneMap"
    static let argument = "-SaryOneMap"

    /// UserDefaults key (TestFlight internal builds), or the launch argument (DEBUG, tests and screenshots).
    static func isOn(defaults: UserDefaults = .standard, arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        #if DEBUG
        if arguments.contains(argument) { return true }
        #endif
        return defaults.bool(forKey: key)
    }
}

enum IdleMapRules {
    /// The idle camera's tilt (degrees): the navigation map's 3D look instead of the flat home map (R02).
    /// Lower in low-power mode / a hot device (R05): the 3D buildings and lighting cost the most there.
    static let pitch = 40.0
    static let reducedPitch = 20.0

    static func idlePitch(lowPower: Bool, thermalHot: Bool) -> Double {
        lowPower || thermalHot ? reducedPitch : pitch
    }

    /// Who presents an invite link: the root when nothing else is presented, else the live sheet (session or idle map).
    /// Two presenters at once would show it twice, or (a sheet over the always-presented live sheet) not at all.
    static func rootShowsInvite(hasSession: Bool, idleMapShown: Bool) -> Bool { !hasSession && !idleMapShown }

    /// «طلعاتي» rows in the idle sheet: the active one first, then paused, then not started; ended ones never; at most `limit`.
    static func visibleOutings(_ all: [OutingSummary], limit: Int = 3) -> [OutingSummary] {
        func rank(_ s: OutingStatus) -> Int {
            switch s {
            case .active: return 0
            case .paused: return 1
            case .created: return 2
            default: return 9
            }
        }
        return Array(all.filter { rank($0.status) < 9 }.enumerated()
            .sorted { (rank($0.element.status), $0.offset) < (rank($1.element.status), $1.offset) }
            .map(\.element).prefix(limit))
    }
}

extension OutingSession {
    /// A solo session that only carries the map: on this phone, in a private in-memory preference
    /// store, with no trail file, no road matching and no trail recording (nothing about the idle
    /// map is kept). It is never `AppModel.session`, so nothing in the app sees it as an outing.
    static func idleMap(me: PublicUser, location: LocationSharer, env base: SessionEnv = SessionEnv()) -> OutingSession {
        var env = base
        let suite = "sary.idlemap"
        let d = UserDefaults(suiteName: suite) ?? .standard
        d.removePersistentDomain(forName: suite)
        d.set(false, forKey: TrailPrefs.recordKey)
        d.set(false, forKey: TrailPrefs.backgroundKey)
        env.defaults = d
        env.trailDirectory = nil
        env.trailMatching = nil
        return OutingSession.solo(me: me, name: "الخريطة", location: location, env: env)
    }
}

extension LiveOutingController {
    /// On the idle map «اتجه» does not plan on the carrier session: it hands the destination to the app, which opens the solo outing.
    func handOffToSolo(_ t: NavTarget) -> Bool {
        guard idleHome, let go = idleNavigate else { return false }
        modal = nil
        let d = OutingDestination(name: String(t.name.prefix(TripPlan.destinationNameMax)), lat: t.position.lat, lng: t.position.lng)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { go(d) }
        return true
    }

    /// A place picked in the idle search: the camera goes there and its brief opens (the same card a tap on the map opens).
    func idlePickPlace(_ d: OutingDestination) {
        let p = LngLat(lng: d.lng, lat: d.lat)
        ask(.point(p))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            self?.modal = .plan(.brief(p, name: d.name))
        }
    }
}
