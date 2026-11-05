import Combine
import Foundation

/// My current speed, as one small observable value.
///
/// Fed with every fix the phone already takes (the live screen's location
/// changes) and re-read once a second, so a speed goes «—» by itself when the
/// fixes stop. Kept apart from the controller so a Live Activity (another
/// branch) can read `snapshot` without knowing the screen.
@MainActor
final class SpeedModel: ObservableObject {
    /// What a glanceable surface needs: whole km/h, or nil for «—».
    struct Snapshot: Equatable {
        var kmh: Int?
        var atMs: Double
    }

    @Published private(set) var current: SpeedReading = .unknown
    /// My speeds since this screen opened (fallback when no trip log is kept here).
    private(set) var local = TripLog()
    private var smoother = SpeedSmoother()

    var snapshot: Snapshot {
        Snapshot(kmh: current.kmh.map { Int($0.rounded()) }, atMs: smoother.latestAtMs ?? 0)
    }

    func ingest(_ fix: DeviceFix?, now: Date = Date()) {
        if let f = fix, f.atMs > (smoother.latestAtMs ?? -.infinity) {
            smoother.add(f)
            local.add(lat: f.lat, lng: f.lng, accuracy: f.accuracy, speed: f.speed, atMs: f.atMs, speedAccuracy: f.speedAccuracy)
        }
        refresh(now: now)
    }

    func refresh(now: Date = Date()) {
        let r = smoother.reading(nowMs: now.timeIntervalSince1970 * 1000)
        /* Whole km/h is what is shown: don't republish for sub-unit wobble. */
        if r.kmh.map({ $0.rounded() }) != current.kmh.map({ $0.rounded() }) || (r == .unknown) != (current == .unknown) { current = r }
    }
}
