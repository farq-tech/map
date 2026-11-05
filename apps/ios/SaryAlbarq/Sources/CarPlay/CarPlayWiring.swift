import Combine
import Foundation

// The CarPlay seams (CarPlayFeatures.swift) wired to the features that now live in the
// same build: turn-by-turn through `NavigationSessionProviding` (feat/ios-navigation),
// the outing's destination («تخطيط الطلعة»), «غرّزت» (safety) and the convoy.
// CarPlay still only shows what the phone already has: nothing here talks to the network
// except what the phone's own features already do (routing, the stuck report).

/// `CarPlayRoadNavigationSource` over the phone's navigation session. CarPlay renders the
/// SAME navigation the phone runs: starting from the car plans on the phone and starts
/// guidance on the best route as soon as one arrives; «إنهاء» ends it on both.
@MainActor
final class CarPlayNavAdapter: CarPlayRoadNavigationSource {
    private weak var provider: NavigationSessionProviding?
    private var bag = Set<AnyCancellable>()
    /// A route asked for from CarPlay: start guidance when the routes are in.
    private var autoStart = false

    init(provider: NavigationSessionProviding) {
        self.provider = provider
        provider.snapshots.sink { [weak self] s in self?.snapshotChanged(s) }.store(in: &bag)
    }

    private func snapshotChanged(_ s: NavSnapshot) {
        if autoStart, s.phase == .planning, !s.routes.isEmpty {
            autoStart = false
            provider?.startGuidance(routeId: s.routes.first?.id)
        } else if s.phase != .planning {
            autoStart = false
        }
        CarPlayFeatures.changed()
    }

    var carPlayRoadActive: Bool {
        guard let p = provider?.snapshot.phase else { return false }
        return p == .guiding || p == .offRoad
    }

    func carPlayRoadProgress() -> CarPlayRoadProgress? {
        guard let s = provider?.snapshot, carPlayRoadActive else { return nil }
        return Self.progress(s)
    }

    /// Pure mapping (tested): the phone's snapshot → what CarPlay shows.
    nonisolated static func progress(_ s: NavSnapshot) -> CarPlayRoadProgress {
        var maneuvers = s.carPlayManeuvers.map { m in
            CarPlayRoadManeuver(instruction: m.instructionVariants.first ?? "",
                                shortInstruction: m.instructionVariants.count > 1 ? m.instructionVariants.last : nil,
                                distanceM: m.distanceM, symbol: m.symbolName)
        }
        if s.phase == .offRoad, let text = s.offRoadInstruction {
            /* «آخر جزء بدون طريق»: one straight-line step toward the target. */
            maneuvers = [CarPlayRoadManeuver(instruction: text, shortInstruction: nil,
                                             distanceM: s.offRoad.map(\.distanceM) ?? s.distanceRemainingM ?? 0,
                                             symbol: "location.north.fill")]
        }
        let line = s.routes.first(where: { $0.id == s.activeRouteId })?.coordinates ?? s.routes.first?.coordinates ?? []
        return CarPlayRoadProgress(destinationLabel: s.target?.name ?? "",
                                   remainingM: s.distanceRemainingM ?? 0,
                                   remainingS: s.durationRemainingS ?? 0,
                                   maneuvers: maneuvers,
                                   routeLine: line,
                                   rerouting: s.rerouting)
    }

    func carPlayStartRoadRoute(to target: LngLat, label: String) -> Bool {
        guard let provider else { return false }
        autoStart = true
        provider.startNavigation(to: NavTarget(source: .point, name: label.isEmpty ? "النقطة المحددة" : label, position: target))
        return true
    }

    func carPlayStopRoadRoute() {
        autoStart = false
        provider?.endNavigation()
    }
}

extension LiveOutingController: CarPlayFeatureSource {
    func carPlayDestination() -> CarPlayDestination? {
        guard let d = AppBoot.model.plans.model(session.id).plan.destination else { return nil }
        return CarPlayDestination(position: LngLat(lng: d.lng, lat: d.lat), label: d.name)
    }

    func carPlayTripProgress() -> CarPlayTripProgress? {
        guard tripDestination != nil else { return nil }
        let t = tripPanel
        switch t.phase {
        case .arrived:
            return CarPlayTripProgress(percent: 100, remainingM: 0, approximate: false, eta: nil, arrived: true)
        case .underway:
            let fresh = t.myFixStaleSince == nil
            return CarPlayTripProgress(percent: t.percent, remainingM: fresh ? t.remainingMeters : nil, approximate: t.remainingApprox,
                                       eta: fresh ? t.eta : nil, arrived: false)
        default:
            return nil
        }
    }

    func carPlayStuckMembers() -> [CarPlayStuck] {
        safety.stuck.values
            .filter { !StuckLogic.expired($0, now: Date()) }
            .sorted { $0.at > $1.at }
            .map { r in
                let fix = session.displayView?.positions[r.userId]
                return CarPlayStuck(memberId: r.userId, since: r.at, position: fix.map { LngLat(lng: $0.lng, lat: $0.lat) })
            }
    }

    func carPlayConvoy() -> CarPlayConvoy? {
        guard let v = session.displayView, let c = v.convoy, c.isOn else { return nil }
        let gap = features.convoyCheck?.alerts.first.map { features.alertUI($0, view: v) }
        return CarPlayConvoy(leaderId: c.lead_user_id, sweepId: c.tail_user_id,
                             gapWarning: gap.map { [$0.title, $0.detail].filter { !$0.isEmpty }.joined(separator: " ") })
    }

    var carPlayStuckReportSupported: Bool { session.view?.status == .active && !session.isDemo }

    func carPlayReportStuck() -> Bool {
        guard carPlayStuckReportSupported, safety.myStuck == nil else { return false }
        Task { await safety.reportStuck() }
        return true
    }

    /// Called once the controller is set up: CarPlay reads this screen's outing.
    func registerCarPlay() {
        carPlayNav = CarPlayNavAdapter(provider: nav)
        CarPlayFeatures.roadNavigation = carPlayNav
        CarPlayFeatures.source = self
        /* objectWillChange fires before the value moves: tell CarPlay on the next turn. */
        safety.objectWillChange.sink { DispatchQueue.main.async { CarPlayFeatures.changed() } }.store(in: &bag)
        features.objectWillChange.sink { DispatchQueue.main.async { CarPlayFeatures.changed() } }.store(in: &bag)
    }
}
