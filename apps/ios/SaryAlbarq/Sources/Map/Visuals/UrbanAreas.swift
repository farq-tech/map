import Foundation

/// The Kingdom's dense cities, as plain bounding boxes (on the phone, no lookup, works offline).
///
/// Over a city the satellite imagery is a photo taken off-nadir and draped on the DEM: towers
/// lean in it, their shadows fall across the streets, and any terrain exaggeration stretches
/// all of that further. So in these boxes the terrain stays at its true height, neutral 3D
/// buildings stand in when tilted, and «اعرضها بالوضع الواقعي» is offered (`MapVisualsDirector`).
enum UrbanAreas {
    struct Area: Equatable {
        var name: String
        var south: Double
        var west: Double
        var north: Double
        var east: Double

        func contains(lat: Double, lng: Double) -> Bool { lat >= south && lat <= north && lng >= west && lng <= east }

        /// Distance outside the box in degrees (0 inside), longitude scaled by the latitude.
        func outside(lat: Double, lng: Double) -> Double {
            let dLat = max(south - lat, 0, lat - north)
            let dLng = max(west - lng, 0, lng - east) * cos(lat * .pi / 180)
            return (dLat * dLat + dLng * dLng).squareRoot()
        }
    }

    /// Built-up extents (generous: suburbs included, open desert left out).
    static let areas: [Area] = [
        Area(name: "مكة المكرمة", south: 21.30, west: 39.70, north: 21.52, east: 39.98),
        Area(name: "المدينة المنورة", south: 24.36, west: 39.48, north: 24.58, east: 39.74),
        Area(name: "الرياض", south: 24.45, west: 46.45, north: 25.05, east: 47.05),
        Area(name: "جدة", south: 21.28, west: 39.08, north: 21.85, east: 39.32),
        Area(name: "الدمام والخبر والظهران", south: 26.18, west: 49.90, north: 26.62, east: 50.25),
        Area(name: "الطائف", south: 21.18, west: 40.32, north: 21.36, east: 40.52),
        Area(name: "أبها وخميس مشيط", south: 18.17, west: 42.45, north: 18.36, east: 42.80),
        Area(name: "تبوك", south: 28.33, west: 36.47, north: 28.46, east: 36.65),
        Area(name: "حائل", south: 27.45, west: 41.62, north: 27.58, east: 41.77),
        Area(name: "بريدة وعنيزة", south: 26.02, west: 43.86, north: 26.42, east: 44.05),
        Area(name: "العلا", south: 26.58, west: 37.89, north: 26.66, east: 37.94),
    ]

    /// The edge blends over this many degrees (~3 km) so nothing jumps when panning out of town.
    static let edgeDegrees = 0.03

    /// 1 inside a city, falling smoothly to 0 within ~3 km outside it.
    static func weight(lat: Double, lng: Double) -> Double {
        var best = 0.0
        for a in areas {
            if a.contains(lat: lat, lng: lng) { return 1 }
            let d = a.outside(lat: lat, lng: lng)
            if d < edgeDegrees { best = max(best, 1 - Smooth.step(0, edgeDegrees, d)) }
        }
        return best
    }

    static func area(lat: Double, lng: Double) -> Area? { areas.first { $0.contains(lat: lat, lng: lng) } }
}
