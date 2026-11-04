import Foundation

extension AppModel {
    /// My top and average moving speed for this outing, from this device only.
    /// Never part of «شارك ملخصي» (that sends distance and times only).
    func mySpeed(_ id: String) -> TripSpeedSummary? {
        if isDemo { return TripSpeedSummary(maxKmh: 118, avgMovingKmh: 64) }
        guard let s = TripLogStore.load(id)?.speedSummary, !s.isEmpty else { return nil }
        return s
    }
}
