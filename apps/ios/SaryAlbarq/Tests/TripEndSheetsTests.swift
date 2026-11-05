import XCTest
@testable import SaryAlbarq

/// QA build 15: the sheet open when the trip ends is closed only if it means nothing afterwards.
final class TripEndSheetsTests: XCTestCase {
    func testSafetyAndChatsStayOpenWhenTheTripEnds() {
        XCTAssertFalse(LiveModal.enjad(.stuck).closesWhenTripEnds, "«اطلب إنجاد» never closes by itself")
        XCTAssertFalse(LiveModal.chat(nil).closesWhenTripEnds)
        XCTAssertFalse(LiveModal.participant("u2").closesWhenTripEnds)
        XCTAssertFalse(LiveModal.weather.closesWhenTripEnds)
        XCTAssertFalse(LiveModal.actions.closesWhenTripEnds)
    }

    func testGuidanceAndNoteSheetsClose() {
        XCTAssertTrue(LiveModal.navOptions.closesWhenTripEnds)
        XCTAssertTrue(LiveModal.navStartChoice.closesWhenTripEnds)
        XCTAssertTrue(LiveModal.note.closesWhenTripEnds)
    }
}

/// QA build 15: a member whose fix is old is drawn grey, not only faded.
final class StaleCarColourTests: XCTestCase {
    func testOnlyALiveFixKeepsTheCarsColour() {
        let red: UInt32 = 0xD6452F
        XCTAssertEqual(Vehicle.displayColor(red, .live), red)
        XCTAssertEqual(Vehicle.displayColor(red, .recent), Vehicle.staleRGB)
        XCTAssertEqual(Vehicle.displayColor(red, .lost), Vehicle.staleRGB)
        XCTAssertLessThan(Vehicle.opacity(.lost), Vehicle.opacity(.live), "and still faded")
    }
}

/// QA build 15: a quick reply right after a friend let go must not go out silent.
final class PTTMicRestartTests: XCTestCase {
    func testTheMicIsWiredEvenWhileAFriendsTailIsStillPlaying() {
        XCTAssertEqual(PTTAudioEngine.micRestart(engineRunning: true, inputWired: false, playing: true, draining: true), .endTailThenRestart,
                       "the friend's buffered tail is cut so the engine restarts with the mic")
        XCTAssertEqual(PTTAudioEngine.micRestart(engineRunning: true, inputWired: false, playing: false, draining: false), .restart, "a cue was playing")
        XCTAssertEqual(PTTAudioEngine.micRestart(engineRunning: true, inputWired: true, playing: true, draining: true), .none, "already wired")
        XCTAssertEqual(PTTAudioEngine.micRestart(engineRunning: false, inputWired: false, playing: false, draining: false), .none, "starts fresh with the mic")
        XCTAssertEqual(PTTAudioEngine.micRestart(engineRunning: true, inputWired: false, playing: true, draining: false), .none, "a friend still talking holds the floor")
    }
}
