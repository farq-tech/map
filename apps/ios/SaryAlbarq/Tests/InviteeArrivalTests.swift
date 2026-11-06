import XCTest
@testable import SaryAlbarq

/// Build 21: the first seconds in the trip after an invite, and the deferred invite after install.
final class InviteeArrivalTests: XCTestCase {
    func testAGoodFreshFixFramesAtOnce() {
        XCTAssertTrue(InviteeArrival.isGoodFix(accuracyM: 12, ageS: 1, sinceArrivalS: 0))
        XCTAssertTrue(InviteeArrival.isGoodFix(accuracyM: Policy.weakAccuracyM, ageS: 1, sinceArrivalS: 0))
        XCTAssertFalse(InviteeArrival.isGoodFix(accuracyM: 120, ageS: 1, sinceArrivalS: 3), "coarse first fix: keep «نحدد موقعك…»")
        XCTAssertFalse(InviteeArrival.isGoodFix(accuracyM: nil, ageS: 1, sinceArrivalS: 3))
        XCTAssertFalse(InviteeArrival.isGoodFix(accuracyM: -1, ageS: 1, sinceArrivalS: 3))
    }

    func testAStaleFixIsNeverWhereIAm() {
        XCTAssertFalse(InviteeArrival.isGoodFix(accuracyM: 5, ageS: 60, sinceArrivalS: 60), "an old cached fix is not shown as live")
        XCTAssertFalse(InviteeArrival.isGoodFix(accuracyM: 5, ageS: -3, sinceArrivalS: 0))
    }

    func testLowPowerModeStillFramesAfterAWhile() {
        /* Low Power parks the GPS around 100 m: anything we would send frames the camera after 15 s. */
        XCTAssertFalse(InviteeArrival.isGoodFix(accuracyM: 100, ageS: 2, sinceArrivalS: 10))
        XCTAssertTrue(InviteeArrival.isGoodFix(accuracyM: 100, ageS: 2, sinceArrivalS: 16))
        XCTAssertFalse(InviteeArrival.isGoodFix(accuracyM: 1500, ageS: 2, sinceArrivalS: 60), "approximate is never «located»")
    }

    func testLocatingWords() {
        XCTAssertEqual(InviteeArrival.locatingText(accuracyM: nil, ageS: nil, sinceArrivalS: 2), "نحدد موقعك…")
        XCTAssertEqual(InviteeArrival.locatingText(accuracyM: 34.6, ageS: 1, sinceArrivalS: 2), "نحدد موقعك… الدقة ±٣٥ م")
        XCTAssertEqual(InviteeArrival.locatingText(accuracyM: 34.6, ageS: 40, sinceArrivalS: 2), "نحدد موقعك…", "no accuracy from a stale fix")
        XCTAssertTrue(InviteeArrival.locatingText(accuracyM: nil, ageS: nil, sinceArrivalS: 31).hasSuffix("جرّب مكان مكشوف"))
    }

    func testWelcomeCard() {
        XCTAssertEqual(InviteeArrival.welcome(trip: "كشتة النفود الكبير", destination: "روضة خريم", others: 4),
                       "حياك في كشتة النفود الكبير — الوجهة روضة خريم، معك ٤")
        XCTAssertEqual(InviteeArrival.welcome(trip: "كشتة النفود الكبير", destination: nil, others: 4), "حياك في كشتة النفود الكبير — معك ٤")
        XCTAssertEqual(InviteeArrival.welcome(trip: "طلعة", destination: " ", others: 0), "حياك في طلعة")
        XCTAssertEqual(InviteeArrival.welcome(trip: "", destination: "الثمامة", others: 1), "حياك في الطلعة — الوجهة الثمامة، معك ١")
    }

    func testWelcomeIsOncePerTrip() {
        let d = UserDefaults(suiteName: "arrival-\(UUID().uuidString)")!
        XCTAssertTrue(InviteeArrival.shouldWelcome(outing: "o1", defaults: d))
        InviteeArrival.markWelcomed(outing: "o1", defaults: d)
        XCTAssertFalse(InviteeArrival.shouldWelcome(outing: "o1", defaults: d))
        XCTAssertTrue(InviteeArrival.shouldWelcome(outing: "o2", defaults: d))
    }

    func testHiddenFromTheGroup() {
        XCTAssertEqual(InviteeArrival.hidden(member: true, tripOver: false, permission: .denied), .denied)
        XCTAssertEqual(InviteeArrival.hidden(member: true, tripOver: false, permission: .reduced), .reduced, "approximate fixes are never sent")
        XCTAssertNil(InviteeArrival.hidden(member: true, tripOver: false, permission: .granted))
        XCTAssertNil(InviteeArrival.hidden(member: false, tripOver: false, permission: .denied))
        XCTAssertNil(InviteeArrival.hidden(member: true, tripOver: true, permission: .denied))
    }

    func testDeferredInvite() {
        XCTAssertTrue(DeferredInvite.shouldLook(hasIdentity: false, pendingInvite: false, isDemo: false))
        XCTAssertFalse(DeferredInvite.shouldLook(hasIdentity: true, pendingInvite: false, isDemo: false), "only the first launch")
        XCTAssertFalse(DeferredInvite.shouldLook(hasIdentity: false, pendingInvite: true, isDemo: false), "a link already opened the app")
        let tok = String(repeating: "A", count: 42) + "b"
        XCTAssertEqual(DeferredInvite.token(fromPasted: ["https://farq-map-investor.vercel.app/outings/join#\(tok)"]), tok)
        XCTAssertEqual(DeferredInvite.token(fromPasted: ["hello", "شوف: https://farq-map-investor.vercel.app/outings/join#\(tok)"]), tok)
        XCTAssertNil(DeferredInvite.token(fromPasted: ["https://example.com/x"]))
        XCTAssertNil(DeferredInvite.token(fromPasted: []))
    }
}
