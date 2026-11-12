import XCTest
@testable import SaryAlbarq

/// «أثري (GPS)»: the GPS-track style is one definition, thin, and far from every road / route colour.
final class GPSTrackStyleTests: XCTestCase {
    func testColourIsFarFromRoadsRoutesAndTraffic() {
        for a in GPSTrackStyle.avoided {
            XCTAssertGreaterThanOrEqual(GPSTrackStyle.distance(GPSTrackStyle.coreRGB, a.rgb), 40, "too close to \(a.name)")
        }
    }

    func testColourIsFarFromTheOrangeDefaultOfTheOldTrackStyle() {
        XCTAssertGreaterThanOrEqual(GPSTrackStyle.distance(GPSTrackStyle.coreRGB, 0xFF9F1C), 80)
        XCTAssertGreaterThanOrEqual(GPSTrackStyle.distance(GPSTrackStyle.coreRGB, 0xE5772A), 80)
    }

    func testColourIsFarFromEveryParticipantCarColour() {
        /* Friends' trails take their car's colour; the nearest are the teal and green cars, and those have no chevrons. */
        for (i, c) in SaryCarColors.palette.enumerated() {
            XCTAssertGreaterThanOrEqual(GPSTrackStyle.distance(GPSTrackStyle.coreRGB, c), 30, "car colour \(i)")
        }
    }

    func testReadsOnSandCityGreenAndNightGrounds() {
        for g in GPSTrackStyle.grounds {
            XCTAssertGreaterThanOrEqual(GPSTrackStyle.contrast(on: g.rgb), 3, "contrast on \(g.name)")
        }
        XCTAssertGreaterThanOrEqual(SaryContrast.ratio(GPSTrackStyle.coreRGB, GPSTrackStyle.edgeRGB), 7)
    }

    func testDistanceHelperBasics() {
        XCTAssertEqual(GPSTrackStyle.distance(0x123456, 0x123456), 0, accuracy: 1e-9)
        XCTAssertGreaterThan(GPSTrackStyle.distance(0x000000, 0xFFFFFF), 99)
        XCTAssertEqual(GPSTrackStyle.distance(0xFF0000, 0x00FF00), GPSTrackStyle.distance(0x00FF00, 0xFF0000), accuracy: 1e-9)
    }

    func testStaysThinAndSemiTransparent() {
        XCTAssertTrue((2.0 ... 3.0).contains(GPSTrackStyle.coreWidth))
        XCTAssertLessThanOrEqual(GPSTrackStyle.edgeExtra, 2.5)
        XCTAssertLessThan(GPSTrackStyle.coreOpacity, 1)
        XCTAssertLessThan(GPSTrackStyle.edgeOpacity, GPSTrackStyle.coreOpacity)
        /* Narrower than the old track line (5.5 + a 3.5 casing). */
        XCTAssertLessThan(GPSTrackStyle.coreWidth + GPSTrackStyle.edgeExtra, TrackLineStyle.width)
    }

    func testSharedStyleHasNoGlowAndIsUniform() {
        let s = TrackLineStyle.gpsTrack
        XCTAssertTrue(s.gps)
        XCTAssertFalse(s.glow)
        XCTAssertFalse(s.speedColours)
        XCTAssertEqual(s.color, GPSTrackStyle.coreRGB)
        XCTAssertNotEqual(s, TrackLineStyle())
    }

    func testChevronLayerIsALineSymbolAndTheLegendIsNamed() {
        let l = GPSTrackStyle.chevronLayer(id: "c", source: "src")
        XCTAssertEqual(l["type"] as? String, "symbol")
        XCTAssertEqual((l["layout"] as? [String: Any])?["symbol-placement"] as? String, "line")
        XCTAssertEqual(GPSTrackStyle.legendTitle, "أثري (GPS)")
    }

    func testChevronImageRenders() {
        XCTAssertEqual(GPSTrackStyle.chevron().size, CGSize(width: 24, height: 24))
    }

    func testGlowDirectorNoLongerGlowsGPSTracks() {
        let ids = MapVisualsDirector.glowTargets.map(\.id)
        XCTAssertFalse(ids.contains("sary-track-follow-line"))
        XCTAssertFalse(ids.contains("sary-explore-tracks-line"))
    }
}
