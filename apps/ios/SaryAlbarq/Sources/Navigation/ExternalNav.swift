import UIKit

/// «افتح في Google Maps» / «افتح في Waze»: the ONLY way out to another navigation app, and only
/// where the person picks it by name. Every «اتجه» is our own guidance (`directions(_:)`).
///
/// No Apple Maps anywhere (owner, build 21: «خرائط ابل لا تعمل بالسعودية اصلا»); people here
/// drive with Google Maps and Waze. The app when installed (`LSApplicationQueriesSchemes`
/// lists `comgooglemaps` and `waze`), else the universal link in the browser.
enum ExternalNav {
    enum App: String, CaseIterable, Identifiable {
        case google, waze
        var id: String { rawValue }

        /// «افتح في Google Maps».
        var openTitle: String {
            switch self {
            case .google: return "افتح في Google Maps"
            case .waze: return "افتح في Waze"
            }
        }

        /// The scheme probed with `canOpenURL`.
        var probe: URL {
            switch self {
            case .google: return URL(string: "comgooglemaps://")!
            case .waze: return URL(string: "waze://")!
            }
        }
    }

    /// "24.71360,46.67530": lat,lng, Western digits.
    static func coord(lat: Double, lng: Double) -> String { String(format: "%.5f,%.5f", lat, lng) }

    /// Turn-by-turn in the installed app.
    static func appURL(_ app: App, lat: Double, lng: Double) -> URL {
        let c = coord(lat: lat, lng: lng)
        switch app {
        case .google: return URL(string: "comgooglemaps://?daddr=\(c)&directionsmode=driving")!
        case .waze: return URL(string: "waze://?ll=\(c)&navigate=yes")!
        }
    }

    /// Turn-by-turn when the app is not installed (also the link we share).
    static func webURL(_ app: App, lat: Double, lng: Double) -> URL {
        let c = coord(lat: lat, lng: lng)
        switch app {
        case .google: return URL(string: "https://www.google.com/maps/dir/?api=1&destination=\(c)&travelmode=driving")!
        case .waze: return URL(string: "https://waze.com/ul?ll=\(c)&navigate=yes")!
        }
    }

    /// A point to look at (shared in «شارك»), not a drive.
    static func placeURL(_ app: App, lat: Double, lng: Double) -> URL {
        let c = coord(lat: lat, lng: lng)
        switch app {
        case .google: return URL(string: "https://www.google.com/maps/search/?api=1&query=\(c)")!
        case .waze: return URL(string: "https://waze.com/ul?ll=\(c)")!
        }
    }

    /// The app's own link if it can be opened, else the web one.
    static func url(_ app: App, lat: Double, lng: Double, canOpen: (URL) -> Bool) -> URL {
        canOpen(app.probe) ? appURL(app, lat: lat, lng: lng) : webURL(app, lat: lat, lng: lng)
    }

    static func open(_ app: App, lat: Double, lng: Double) {
        UIApplication.shared.open(url(app, lat: lat, lng: lng, canOpen: { UIApplication.shared.canOpenURL($0) }))
    }

    static func open(_ app: App, _ p: LngLat) { open(app, lat: p.lat, lng: p.lng) }
}
