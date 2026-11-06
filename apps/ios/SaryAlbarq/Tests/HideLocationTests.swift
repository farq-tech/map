import XCTest
@testable import SaryAlbarq

/// «أخفِ موقعي / أظهر موقعي»: still in the trip, position never sent, SOS overrides, no «نبّهه».
final class HideLocationTests: XCTestCase {
    private func gate(hidden: Bool, foreground: Bool = true) -> SendGate {
        SendGate(consent: true, osAuthorized: true, userWantsShare: true, serverSharing: true, outingActive: true,
                 foreground: foreground, closed: false, alwaysAuthorized: true, hidden: hidden)
    }

    func testHiddenSendsNoPositionButSosStillCarriesTheRealOne() {
        XCTAssertTrue(gate(hidden: false).allowsPosition)
        XCTAssertFalse(gate(hidden: true).allowsPosition, "hidden: nothing on the wire")
        XCTAssertFalse(gate(hidden: true, foreground: false).allowsBackgroundPosition)
        XCTAssertTrue(gate(hidden: true).allowsSosFix, "an SOS always sends the real position")
        XCTAssertTrue(gate(hidden: true, foreground: false).allowsSosFix)
    }

    private func view(now: Date = Date()) throws -> OutingView {
        let snap: [String: Any] = [
            "outing": ["id": "o1", "name": "x", "status": "active", "owner_id": "u1"],
            "me": ["user_id": "u1", "role": "owner", "sharing": true],
            "members": [
                ["user_id": "u1", "display_name": "احمد", "role": "owner", "sharing": true, "joined_at": "2026-11-06T10:00:00.000Z"],
                ["user_id": "u2", "display_name": "فهد", "role": "member", "sharing": true, "joined_at": "2026-11-06T10:00:00.000Z"],
            ],
            "positions": [["user_id": "u2", "lat": 24.7113, "lng": 46.6744, "recorded_at": ISODate.string(now.addingTimeInterval(-300))]],
            "server_now": ISODate.string(now),
        ]
        return OutingView(try JSONDecoder().decode(OutingSnapshot.self, from: JSONSerialization.data(withJSONObject: snap)), deviceNow: now)
    }

    func testHiddenEventMarksTheMemberAndDropsTheirLastPosition() throws {
        var v = try view()
        let e = try XCTUnwrap(LiveEvent.decode(["type": "member_hidden", "user_id": "u2", "hidden": true, "since": "2026-11-06T11:00:00.000Z", "reason": "self"]))
        v.apply(e)
        XCTAssertEqual(v.members["u2"]?.hidden, true, "still a member")
        XCTAssertNil(v.positions["u2"], "never drawn as if live")
        XCTAssertEqual(LiveOutingPresenter.presenceReason(v.members["u2"]!, in: v), .hidden)
        XCTAssertEqual(PresenceReason.hidden.text, "مخفي موقعه")
        /* A later fix from them (another device, a race) is not shown while hidden… */
        v.apply(.memberHidden(userId: "u2", hidden: false, since: nil, reason: "sos"))
        XCTAssertEqual(v.members["u2"]?.hidden, false)
        XCTAssertNotEqual(v.members["u2"]?.presence?.state, .hidden)
    }

    func testNoNudgeForSomeoneWhoHidOnPurpose() {
        let stale = ParticipantUI(id: "u2", name: "فهد", color: 0, role: .member, isMe: false, presence: .stale(since: Date()), hasPhone: false)
        var hidden = stale
        hidden.presenceReason = .hidden
        var live = stale
        live.presence = .live
        XCTAssertTrue(LiveOutingPresenter.canNudge(stale, leader: true, active: true))
        XCTAssertFalse(LiveOutingPresenter.canNudge(hidden, leader: true, active: true), "hidden by choice: no nudge")
        XCTAssertFalse(LiveOutingPresenter.canNudge(live, leader: true, active: true))
        XCTAssertFalse(LiveOutingPresenter.canNudge(stale, leader: false, active: true), "leaders only")
        XCTAssertFalse(LiveOutingPresenter.canNudge(stale, leader: true, active: false))
    }

    func testReminderAtThirtyMinutes() {
        let since = Date(timeIntervalSince1970: 1_762_423_200)
        XCTAssertEqual(HideReminder.dueDate(since: since, now: since), since.addingTimeInterval(30 * 60))
        XCTAssertNil(HideReminder.dueDate(since: since, now: since.addingTimeInterval(31 * 60)), "already past: no late reminder")
        XCTAssertNil(HideReminder.dueDate(since: nil))
        XCTAssertEqual(HideText.reminderBody, "موقعك مخفي من ٣٠ د، تبي تظهره؟")
        XCTAssertEqual(HideText.changed(name: "فهد", hidden: true), "فهد أخفى موقعه")
    }

    func testHideButtonIsSmallAndUnderTheCameraNeverWhileDriving() {
        let camera = SaryMapControlItem(id: "locate", systemImage: "scope", label: "تتبعني", accessibilityID: "outing-locate")
        let hide = SaryMapControlItem(id: "hide", systemImage: "eye", label: HideText.hideButton, accessibilityID: "outing-hide")
        XCTAssertEqual(LiveCalmRules.sideItems(camera: camera, backTrack: nil, plusBadge: nil, driving: false, ended: false, hide: hide).map(\.id),
                       ["locate", "hide", "actions"])
        XCTAssertTrue(LiveCalmRules.sideItems(camera: camera, backTrack: nil, plusBadge: nil, driving: true, ended: false, hide: hide).isEmpty)
        XCTAssertEqual(LiveCalmRules.sideItems(camera: camera, backTrack: nil, plusBadge: nil, driving: false, ended: true, hide: hide).map(\.id), ["locate"])
    }
}
