import XCTest
@testable import SaryAlbarq

/// CarPlay renders the phone's navigation (NavigationSessionProviding → CarPlayRoadNavigationSource).
final class CarPlayWiringTests: XCTestCase {
    private func snapshot(_ phase: NavPhase) -> NavSnapshot {
        var s = NavSnapshot.idle
        s.phase = phase
        s.target = NavTarget(source: .point, name: "حطين", position: LngLat(lng: 46.665, lat: 24.722))
        s.routes = [NavRoute(id: "r1", coordinates: [LngLat(lng: 46.67, lat: 24.71), LngLat(lng: 46.665, lat: 24.722)],
                             distanceM: 2100, durationS: 120, steps: [])]
        s.activeRouteId = "r1"
        s.distanceRemainingM = 1800
        s.durationRemainingS = 100
        s.carPlayManeuvers = [
            NavCarPlayManeuver(instructionVariants: ["انعطف يمين على طريق الملك فهد", "انعطف يمين"], symbolName: "arrow.turn.up.right",
                               distanceM: 250, durationS: 20, lanes: [], maneuver: NavManeuver(kind: .turn, direction: nil), cpManeuverType: "rightTurn")
        ]
        return s
    }

    func testGuidingMapsManeuversEstimatesAndLine() {
        let p = CarPlayNavAdapter.progress(snapshot(.guiding))
        XCTAssertEqual(p.destinationLabel, "حطين")
        XCTAssertEqual(p.remainingM, 1800)
        XCTAssertEqual(p.remainingS, 100)
        XCTAssertEqual(p.maneuvers.first?.instruction, "انعطف يمين على طريق الملك فهد")
        XCTAssertEqual(p.maneuvers.first?.shortInstruction, "انعطف يمين")
        XCTAssertEqual(p.maneuvers.first?.symbol, "arrow.turn.up.right")
        XCTAssertEqual(p.routeLine.count, 2)
        XCTAssertFalse(p.rerouting)
    }

    func testOffRoadIsOneStraightLineStep() {
        var s = snapshot(.offRoad)
        s.offRoadInstruction = "آخر جزء بدون طريق: ٣٠٠ م شمال"
        let p = CarPlayNavAdapter.progress(s)
        XCTAssertEqual(p.maneuvers.count, 1)
        XCTAssertEqual(p.maneuvers.first?.instruction, "آخر جزء بدون طريق: ٣٠٠ م شمال")
    }

    func testReroutingPassesThrough() {
        var s = snapshot(.guiding)
        s.rerouting = true
        XCTAssertTrue(CarPlayNavAdapter.progress(s).rerouting)
    }
}
