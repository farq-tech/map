#if DEBUG
@_spi(Experimental) import MapboxMaps
import Foundation

/// Screenshot scenarios for the visuals pack (DEBUG only, never compiled into Release):
/// - `-SaryVisualsClock 2026-11-05T14:25:00Z`: the sun is computed for that real instant
///   (then the clock runs on), so «dusk over the Nafud» can be captured at any hour.
/// - `-SaryVisualsCamera "lat,lng,zoom,pitch,bearing"`: the camera goes there after the style loads.
/// - `-SaryVisualsDrone <seconds>`: a drone flight around the camera centre starts after that delay.
enum VisualsDemo {
    private static let launched = Date()
    private static var cameraDone = false

    private static func arg(_ name: String) -> String? {
        let a = ProcessInfo.processInfo.arguments
        guard let i = a.firstIndex(of: name), i + 1 < a.count else { return nil }
        return a[i + 1]
    }

    private static let fixedClock: Date? = arg("-SaryVisualsClock").flatMap { ISO8601DateFormatter().date(from: $0) }

    static func now() -> Date {
        guard let f = fixedClock else { return Date() }
        return f.addingTimeInterval(Date().timeIntervalSince(launched))
    }

    static func prepare() { _ = launched }

    static var camera: CameraOptions? {
        guard let s = arg("-SaryVisualsCamera") else { return nil }
        let v = s.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard v.count >= 2 else { return nil }
        return CameraOptions(center: CLLocationCoordinate2D(latitude: v[0], longitude: v[1]), zoom: v.count > 2 ? v[2] : 13,
                             bearing: v.count > 4 ? v[4] : 0, pitch: v.count > 3 ? v[3] : 0)
    }

    static func styleLoaded(_ d: MapVisualsDirector) {
        guard !cameraDone, let cam = camera else { return }
        cameraDone = true
        /* After the live screen's own first framing of the group. */
        for delay in [1.5, 4.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak d] in d?.demoCamera(cam) }
        }
        if let s = arg("-SaryVisualsDrone").flatMap(Double.init), let c = cam.center {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.5 + s) {
                MapVisualsHub.shared.fly(to: LngLat(lng: c.longitude, lat: c.latitude))
            }
        }
    }
}
#endif
