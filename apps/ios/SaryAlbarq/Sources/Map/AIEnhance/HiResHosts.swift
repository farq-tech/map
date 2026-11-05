import Foundation

/// What the live map's host passes to `OutingMapboxView.hiRes` (one place, unit-tested via `HiResPolicy`).
extension LiveOutingController {
    func hiResRequest(_ ui: LiveOutingUIState, exploring: Bool) -> HiResRequest {
        let fresh = location.lastFix.flatMap { Date().timeIntervalSince1970 * 1000 - $0.atMs < 15_000 ? $0 : nil }
        var sosOn = !ui.sos.incoming.isEmpty
        if case .none = ui.sos.mine {} else { sosOn = true }
        return HiResRequest(
            surface: exploring ? .exploration : (planPicked != nil ? .pointView : .off),
            satellite: (exploring ? mapLayer : .satellite) == .satellite,
            navigating: nav.isActive,
            following: trackFollow != nil || backTrack != nil || following,
            sos: sosOn,
            speedMps: fresh?.speed.flatMap { $0 >= 0 ? $0 : nil })
    }
}
