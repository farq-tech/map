import XCTest
@testable import SaryAlbarq

/// Owner's Build 48 report (controls dead during guidance): the sheet's detent set must not change while guiding.
final class GuidanceShapeLatchTests: XCTestCase {
    func testShapeIsHeldWhileDriveAndSurfacesFlip() {
        let id = "latch-test-1"
        GuidanceShapeLatch.clear(id)
        let first = LiveSheetShape(drive: false, trip: false, surfaces: true, guide: true)
        XCTAssertEqual(GuidanceShapeLatch.shape(id, arrived: false, live: first), first)
        // The speed drops (drive flips) and a reroute drops the surfaces strip: the held shape stays.
        let flipped = LiveSheetShape(drive: true, trip: false, surfaces: false, guide: true)
        XCTAssertEqual(GuidanceShapeLatch.shape(id, arrived: false, live: flipped), first)
        XCTAssertEqual(GuidanceShapeLatch.shape(id, arrived: false, live: flipped).peekHeight, first.peekHeight)
    }

    func testArrivalMayChangeItAndEndingResets() {
        let id = "latch-test-2"
        GuidanceShapeLatch.clear(id)
        let a = LiveSheetShape(drive: false, trip: false, surfaces: true, guide: true)
        _ = GuidanceShapeLatch.shape(id, arrived: false, live: a)
        let b = LiveSheetShape(drive: false, trip: false, surfaces: false, guide: true)
        XCTAssertEqual(GuidanceShapeLatch.shape(id, arrived: true, live: b), b)
        GuidanceShapeLatch.clear(id)
        XCTAssertEqual(GuidanceShapeLatch.shape(id, arrived: false, live: b), b, "a new guidance starts from its own shape")
    }
}
