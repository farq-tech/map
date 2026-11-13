import UIKit

/// The controller's speed bits (kept in their own file so the live controller stays small).
struct LiveSpeedState {
    var gate = SpeedAlertGate(thresholdKmh: Double(SpeedPrefs.defaultLimitKmh))
    var trip: TripSpeedSummary?
    var tripLoadedAtMs: Double = 0
}

extension LiveOutingController {
    /// Called on every location change and on the session's 1 s tick.
    func updateSpeed() {
        let now = Date()
        speed.ingest(location.lastFix, now: now)
        let nowMs = now.timeIntervalSince1970 * 1000
        /* The stored trip log changes only with shared fixes: re-read it every few seconds, not every render. */
        if nowMs - speedState.tripLoadedAtMs > 5_000 {
            speedState.tripLoadedAtMs = nowMs
            let stored = session.isDemo ? nil : storedTripLog()?.speedSummary
            let local = speed.local.speedSummary
            let t = (stored?.isEmpty == false) ? stored : local
            speedState.trip = t?.isEmpty == false ? t : nil
        }
        guard SpeedPrefs.alertOn() else { return }
        let limit = SpeedPrefs.limitKmh()
        if speedState.gate.thresholdKmh != Double(limit) { speedState.gate = SpeedAlertGate(thresholdKmh: Double(limit)) }
        if speedState.gate.update(speed.current, nowMs: nowMs) {
            /* A gentle nudge: soft tap + one line in the alert lane (rate-limited by the gate). */
            UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.8)
            pushAlert(LiveAlertUI(id: "speed-limit", kind: .toast("تجاوزت \(SaryFormat.speed(kmh: Double(limit))) • خفّف السرعة")), ttl: 6)
        }
    }

    var speedometerUI: SpeedometerUI {
        let over = SpeedPrefs.alertOn() && (speed.current.kmh ?? 0) > Double(SpeedPrefs.limitKmh())
        return SpeedometerUI(current: speed.current, trip: speedState.trip, overLimit: over)
    }
}
