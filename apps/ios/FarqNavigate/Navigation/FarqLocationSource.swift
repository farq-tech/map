import CoreLocation
import FerrostarCore
import FerrostarCoreFFI
import Foundation
import MapboxMaps

/// One position, for everything on this screen that draws one.
///
/// The bug this exists to kill: the app had three independent location
/// sources. Mapbox's puck ran on the map SDK's own `CLLocationManager`, the
/// photo above the car ran on a second manager in `LocationProvider` (ten-metre
/// distance filter, so it lagged), and the route ran on Ferrostar's, which is
/// the only one that is snapped to the road. Three managers, three answers,
/// and the car was drawn at whichever raw fix arrived last — beside the route,
/// over a building — while the route was drawn from road geometry.
///
/// Raw GPS in a city is not wrong so much as unusable for this: reflections off
/// towers put a fix tens of metres off, which is a building's width. Every
/// navigation product on the market draws the *snapped* position for exactly
/// this reason, and Ferrostar already computes it — nothing was consuming it.
///
/// So this is the single source, and `preferred` is the whole decision:
///
///   · navigating and on route → the snapped position, on the road
///   · navigating and off route → the raw fix, because a snap to a road you
///     have left is a lie about where you are
///   · not navigating → the raw fix
///
/// The rule is Ferrostar's own `preferredUserLocation`; this type does not
/// invent a second opinion, it only makes sure the map hears the first one.
enum FarqLocationSource {
    /// Pure, so the decision can be tested without a map, a GPS or a route.
    static func preferred(
        navigation: NavigationState?,
        raw: UserLocation?
    ) -> UserLocation? {
        navigation?.preferredUserLocation ?? raw
    }
}

/// Feeds Mapbox's puck from that single source.
///
/// `LocationManager.override` takes a stream, so this owns one and pushes into
/// it. Nothing here adjusts a pixel: the puck is told a coordinate and Mapbox
/// projects it like any other point on the map, which is why the car stays put
/// through zoom, pitch and rotation.
final class FarqLocationStream {
    private var observers: [UUID: ([Location]) -> Void] = [:]
    private(set) var latest: Location?

    var signal: Signal<[Location]> {
        Signal { [weak self] handler in
            guard let self else { return AnyCancelable {} }
            let key = UUID()
            observers[key] = handler
            if let latest { handler([latest]) }
            return AnyCancelable { [weak self] in
                self?.observers[key] = nil
            }
        }
    }

    func send(_ location: UserLocation) {
        let mapped = Location(
            coordinate: location.coordinates.clLocationCoordinate2D,
            timestamp: location.timestamp,
            horizontalAccuracy: location.horizontalAccuracy,
            /* Course, not heading: the puck's bearing must describe where the
             * car is going, and a phone lying on a passenger seat has a compass
             * heading that has nothing to do with the road. */
            bearing: location.courseOverGround.map { Double($0.degrees) }
        )
        latest = mapped
        for handler in observers.values { handler([mapped]) }
    }
}
