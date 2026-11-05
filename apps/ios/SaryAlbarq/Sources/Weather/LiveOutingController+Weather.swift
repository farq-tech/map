import Foundation

/// Where the weather feature reads the outing's destination from.
///
/// The plan model (destination, route) lives on the plan branch; until it is
/// merged this adapter returns nil, so this branch compiles alone. After the
/// merge, return the plan's `destination` (and its route) here — one line each.
@MainActor
protocol WeatherPlanSource {
    var weatherDestination: OutingDestination? { get }
    var weatherRoute: [Geo.LatLng] { get }
}

extension LiveOutingController: WeatherPlanSource {
    var weatherDestination: OutingDestination? {
        #if DEBUG
        if let d = WeatherDemo.destination { return d }
        #endif
        return planModel?.plan.destination
    }

    var weatherRoute: [Geo.LatLng] { planModel?.plan.points.map { Geo.LatLng(lat: $0.lat, lng: $0.lng) } ?? [] }

    /// Real positions only (last real fixes, my GPS, the rally point) — never estimated.
    func feedWeather(force: Bool = false) {
        guard weather.feedDue(Date()) || force else { return }
        var pts = mapMembers(theme: .default).filter { !$0.isMe }.map { Geo.LatLng(lat: $0.position.lat, lng: $0.position.lng) }
        if let r = rallyPoint { pts.append(Geo.LatLng(lat: r.position.lat, lng: r.position.lng)) }
        weather.setDestination(weatherDestination)
        weather.setPositions(pts, me: location.lastFix, route: weatherRoute)
        weather.start()
    }

    /// The weather sheet's «غيّر الوجهة»: the search sheet (its point card has «اجعلها الوجهة»).
    func changeDestinationFromWeather() {
        modal = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in self?.modal = .plan(.search) }
    }

    /// «الطقس هنا»: for any point (search result, long-press, a waypoint).
    func showWeather(at point: OutingDestination) {
        modal = .weatherAt(point)
    }
}
