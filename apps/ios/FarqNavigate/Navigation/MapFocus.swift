import CoreLocation
import Foundation

/// A request to move the camera, carried as a value.
///
/// The token is what makes "take me back to where I am" work twice in a row:
/// without it the second tap sets the same value, SwiftUI sees no change, and
/// the button appears broken exactly when someone is lost.
struct MapFocus: Equatable {
    enum Target: Equatable {
        /// Frame a حي by its own extent — west, south, east, north.
        case bounds([Double])
        /// Put the observed position back under the camera.
        case user(lat: Double, lng: Double)
    }

    let token: Int
    let target: Target

    static func bounds(_ box: [Double], token: Int) -> MapFocus {
        MapFocus(token: token, target: .bounds(box))
    }

    static func user(_ coordinate: CLLocationCoordinate2D, token: Int) -> MapFocus {
        MapFocus(token: token, target: .user(lat: coordinate.latitude, lng: coordinate.longitude))
    }
}
