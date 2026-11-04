import Foundation

/// «آخر جزء بدون طريق»: a router snaps an off-road target to the nearest road it
/// knows and the route ends there. We never draw a road that is not there: the
/// remainder is shown as what it is — a straight line, its length and its bearing.
enum NavOffRoad {
    /// Below this the router's end is "at" the target (parking, a gate, GPS noise).
    static let thresholdM = 120.0
    /// Inside this, in the last leg, you have arrived.
    static let arriveM = 35.0

    static func lastLeg(routeEnd: LngLat?, target: LngLat) -> NavOffRoadLeg? {
        guard let end = routeEnd else { return nil }
        let a = Geo.LatLng(lat: end.lat, lng: end.lng), b = Geo.LatLng(lat: target.lat, lng: target.lng)
        let d = Geo.haversineMeters(a, b)
        guard d >= thresholdM else { return nil }
        return NavOffRoadLeg(from: end, to: target, distanceM: d, bearing: Geo.bearingDeg(a, b))
    }

    /// No route at all: the whole way is "off road", from me.
    static func direct(from me: LngLat, to target: LngLat) -> NavOffRoadLeg {
        let a = Geo.LatLng(lat: me.lat, lng: me.lng), b = Geo.LatLng(lat: target.lat, lng: target.lng)
        return NavOffRoadLeg(from: me, to: target, distanceM: Geo.haversineMeters(a, b), bearing: Geo.bearingDeg(a, b))
    }

    /// Live, while driving the last leg: what is left from where I am now.
    static func remaining(_ leg: NavOffRoadLeg, me: LngLat) -> (distanceM: Double, bearing: Double, arrived: Bool) {
        let a = Geo.LatLng(lat: me.lat, lng: me.lng), b = Geo.LatLng(lat: leg.to.lat, lng: leg.to.lng)
        let d = Geo.haversineMeters(a, b)
        return (d, Geo.bearingDeg(a, b), d <= arriveM)
    }

    /// «آخر جزء بدون طريق: ٣٫٢ كم باتجاه الجنوب الغربي».
    static func summary(_ leg: NavOffRoadLeg) -> String {
        "آخر جزء بدون طريق: \(SaryFormat.distance(meters: leg.distanceM)) باتجاه \(NavText.compassDefinite(leg.bearing))"
    }

    /// The arrow, relative to where the car (or the map) points; never mirrored by RTL.
    static func arrowDegrees(bearing: Double, reference: Double) -> Double {
        var d = (bearing - reference).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d < -180 { d += 360 }
        return d
    }
}
