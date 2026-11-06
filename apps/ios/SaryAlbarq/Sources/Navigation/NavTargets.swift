import Foundation

/// Every place «ابدأ الملاحة» can start from, checked honestly.
enum NavTargets {
    static func destination(_ d: OutingDestination?) -> Result<NavTarget, NavRefusal> {
        guard let d else { return .failure(.missing) }
        return .success(NavTarget(source: .destination, name: d.name.isEmpty ? "الوجهة" : d.name, position: LngLat(lng: d.lng, lat: d.lat)))
    }

    static func rally(_ r: MapRallyPoint?) -> Result<NavTarget, NavRefusal> {
        guard let r else { return .failure(.missing) }
        return .success(NavTarget(source: .rally, name: r.label.isEmpty ? "نقطة التجمع" : r.label, position: r.position))
    }

    /// A long-pressed or searched point.
    static func point(_ p: LngLat?, name: String? = nil) -> Result<NavTarget, NavRefusal> {
        guard let p else { return .failure(.missing) }
        return .success(NavTarget(source: .point, name: name?.isEmpty == false ? name! : "النقطة المحددة", position: p))
    }

    /// «اتجه» on a silent member's card: their LAST KNOWN fix, allowed only from that card and
    /// always labelled as old (`NavTarget.staleNote`). «روح له» (`member`) still refuses it.
    static func lastKnown(name: String, lat: Double?, lng: Double?, at: Date?) -> Result<NavTarget, NavRefusal> {
        guard let lat, let lng else { return .failure(.missing) }
        return .success(NavTarget(source: .lastKnown, name: "آخر موقع \(name)", position: LngLat(lng: lng, lat: lat), lastKnownAt: at))
    }

    /// «اتجه» on a fuel station.
    static func station(name: String?, lat: Double, lng: Double) -> Result<NavTarget, NavRefusal> {
        point(LngLat(lng: lng, lat: lat), name: name?.isEmpty == false ? name : "محطة بنزين")
    }

    /// «اتجه» on a waypoint («نقاط الطلعة»).
    static func waypoint(title: String, lat: Double, lng: Double) -> Result<NavTarget, NavRefusal> {
        point(LngLat(lng: lng, lat: lat), name: title.isEmpty ? "النقطة" : title)
    }

    /// The last point of the plan's drawn route.
    static func planRouteEnd(_ route: [LngLat]) -> Result<NavTarget, NavRefusal> {
        guard route.count >= 2, let end = route.last else { return .failure(.missing) }
        return .success(NavTarget(source: .planRouteEnd, name: "نهاية مسار الخطة", position: end))
    }

    /// «روح له»: only to a LIVE position. A stale one is refused, never "estimated".
    static func member(id: String, name: String, isMe: Bool, position: LngLat?, presence: ParticipantPresence) -> Result<NavTarget, NavRefusal> {
        if isMe { return .failure(.isMe) }
        switch presence {
        case .live:
            guard let position else { return .failure(.memberHidden(name: name)) }
            return .success(NavTarget(source: .member, name: name, position: position, memberId: id))
        case let .stale(since):
            return .failure(.memberStale(name: name, since: since))
        default:
            return .failure(.memberHidden(name: name))
        }
    }

    /// The member moved this far from where we routed to: offer «حدّث الطريق».
    /// (Not automatic: a new destination more than 100 m away is billed as a new trip.)
    static let memberMovedM = 300.0

    static func memberMoved(_ target: NavTarget, now: LngLat?) -> Double? {
        guard target.source == .member, let now else { return nil }
        let d = Vehicle.distanceMeters(target.position, now)
        return d >= memberMovedM ? d : nil
    }
}
