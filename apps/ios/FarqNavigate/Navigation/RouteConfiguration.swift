import Foundation

/// Where routes come from.
///
/// Farq does not run a routing engine and should not start by building one.
/// Ferrostar speaks to any Valhalla server, so this is the one decision that
/// has to be made deliberately rather than defaulted into:
///
///   · **Development** — the public OpenStreetMap Valhalla. Free, real routes
///     over real Saudi road data, and explicitly not for production use: it is
///     a courtesy service with no capacity guarantee and no SLA.
///   · **Production** — either a commercial Valhalla (Stadia Maps offers one)
///     or a self-hosted instance. Both need a decision about cost and coverage
///     that is not a client-side concern.
///
/// The endpoint is read from the environment so switching does not need a code
/// change, and the app says out loud which one it is using rather than leaving
/// someone to discover it from a network trace.
enum RouteConfiguration {
    /// A courtesy service. Fine for a simulator, not fine for customers.
    static let developmentValhalla = "https://valhalla1.openstreetmap.de/route"

    /// Driving. Farq's destinations are restaurants, reached by car far more
    /// often than on foot in the cities we cover.
    static let profile = "auto"

    static var endpoint: String {
        ProcessInfo.processInfo.environment["FARQ_VALHALLA_ENDPOINT"]
            ?? developmentValhalla
    }

    static var isDevelopmentEndpoint: Bool { endpoint == developmentValhalla }

    /// Shown in the UI, because a route drawn from a courtesy server should not
    /// look like a route from something we operate.
    static var provenance: String {
        isDevelopmentEndpoint
            ? "المسارات من خادم OpenStreetMap العام — للتطوير فقط"
            : "المسارات من \(URL(string: endpoint)?.host ?? endpoint)"
    }
}
