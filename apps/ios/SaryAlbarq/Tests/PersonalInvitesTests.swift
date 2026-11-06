import XCTest
@testable import SaryAlbarq

/// «دعوة شخصية»: numbers, the message, statuses, the wire shapes, the model
/// (no server: demo path) and how invited members read in the group list.
@MainActor
final class PersonalInvitesTests: XCTestCase {
    private let now = ISODate.parse("2026-11-05T12:00:00.000Z")!

    func testSaudiNumbersFromContactsNormaliseLikeTheServer() {
        XCTAssertEqual(KSAPhone.normalize("0501234567"), "+966501234567")
        XCTAssertEqual(KSAPhone.normalize("050 123 4567"), "+966501234567")
        XCTAssertEqual(KSAPhone.normalize("+966 50 123 4567"), "+966501234567")
        XCTAssertEqual(KSAPhone.normalize("+966 050 123 4567"), "+966501234567", "the trunk 0 kept after +966")
        XCTAssertEqual(KSAPhone.normalize("00966501234567"), "+966501234567")
        XCTAssertEqual(KSAPhone.normalize("966501234567"), "+966501234567")
        XCTAssertEqual(KSAPhone.normalize("٠٥٠١٢٣٤٥٦٧"), "+966501234567", "Arabic-Indic digits")
        XCTAssertEqual(KSAPhone.normalize("(050) 123-4567"), "+966501234567")
        XCTAssertEqual(KSAPhone.normalize("+971501234567"), "+971501234567", "other countries pass as E.164")
        XCTAssertNil(KSAPhone.normalize("123"))
        XCTAssertNil(KSAPhone.normalize("فهد"))
        XCTAssertEqual(KSAPhone.last4("+966501234567"), "4567")
        XCTAssertEqual(KSAPhone.display("+966501234567"), "050 123 4567")
    }

    func testMessageAndDirectLinks() throws {
        let link = InviteLink.url(for: String(repeating: "A", count: 43))
        let text = PersonalInviteText.message(inviteeName: "فهد أخوي", outingName: "طلعة الثمامة", link: link)
        XCTAssertTrue(text.contains("فهد أخوي"))
        XCTAssertTrue(text.contains("«طلعة الثمامة»"))
        XCTAssertTrue(text.contains(link.absoluteString))
        XCTAssertTrue(text.contains("لك أنت فقط"))
        let wa = try XCTUnwrap(PersonalInviteText.whatsAppURL(phone: "+966501234567", text: text))
        XCTAssertTrue(wa.absoluteString.hasPrefix("https://wa.me/966501234567?text="), wa.absoluteString)
        let waAny = try XCTUnwrap(PersonalInviteText.whatsAppURL(phone: nil, text: "x"))
        XCTAssertTrue(waAny.absoluteString.hasPrefix("https://wa.me/?text="))
        let sms = try XCTUnwrap(PersonalInviteText.smsURL(phone: "+966501234567", text: "هلا"))
        XCTAssertTrue(sms.absoluteString.hasPrefix("sms:+966501234567&body="), sms.absoluteString)
    }

    private func invite(_ s: PersonalInvite.Status, opened: Bool = false) -> PersonalInvite {
        PersonalInvite(id: "i", invitee_name: "فهد", phone_last4: "4567", status: s, opened: opened, created_at: nil, expires_at: "2026-11-06T12:00:00Z", member_user_id: nil, token: nil)
    }

    func testStatusLabelsForTheLeader() {
        XCTAssertEqual(PersonalInviteStatusText.label(invite(.sent)), "أُرسلت")
        XCTAssertEqual(PersonalInviteStatusText.label(invite(.opened, opened: true)), "فتحها ولم ينضم")
        XCTAssertEqual(PersonalInviteStatusText.label(invite(.joined)), "انضم")
        XCTAssertEqual(PersonalInviteStatusText.label(invite(.expired)), "لم يفتحها")
        XCTAssertEqual(PersonalInviteStatusText.label(invite(.expired, opened: true)), "انتهت قبل أن ينضم")
        XCTAssertEqual(PersonalInviteStatusText.label(invite(.revoked)), "أُلغيت")
        XCTAssertFalse(PersonalInviteStatusText.canResend(invite(.joined)), "once in, no resend")
        XCTAssertTrue(PersonalInviteStatusText.canResend(invite(.expired)))
        XCTAssertTrue(PersonalInviteStatusText.canRevoke(invite(.opened)))
        XCTAssertFalse(PersonalInviteStatusText.canRevoke(invite(.joined)))
    }

    func testWireShapesFromTheServer() throws {
        let snap = """
        {"outing":{"id":"o","name":"طلعة","status":"active","owner_id":"me","open_links":false},
         "me":{"user_id":"me","role":"owner","sharing":true,"can_lead":true},
         "members":[{"user_id":"f","display_name":"فهد أخوي","nickname":"جوس","invited":true,"phone_last4":"4567","avatar":null,"phone":null,
                     "role":"member","co_leader":false,"sharing":true,"joined_at":"2026-11-05T10:00:00.000Z"}],
         "positions":[],"invite":{"active":false,"expires_at":null,"open_links":false},
         "personal_invites":[{"id":"i1","kind":"personal","invitee_name":"فهد أخوي","phone_last4":"4567","status":"joined","opened":true,
                              "created_at":"2026-11-05T09:00:00.000Z","expires_at":"2026-11-06T09:00:00.000Z","member_user_id":"f"}],
         "server_now":"2026-11-05T12:00:00.000Z"}
        """
        let s = try JSONDecoder().decode(OutingSnapshot.self, from: Data(snap.utf8))
        XCTAssertEqual(s.members.first?.display_name, "فهد أخوي")
        XCTAssertEqual(s.members.first?.nickname, "جوس")
        XCTAssertEqual(s.members.first?.phone_last4, "4567")
        XCTAssertEqual(s.invite?.open_links, false)
        XCTAssertEqual(s.personal_invites?.first?.status, .joined)

        /* A build-11 era snapshot (no new fields) still decodes. */
        let old = """
        {"outing":{"id":"o","name":"طلعة","status":"active","owner_id":"me"},"me":{"user_id":"me","role":"owner","sharing":true},
         "members":[{"user_id":"me","display_name":"أنا","role":"owner","sharing":true,"joined_at":"2026-11-05T10:00:00.000Z"}],
         "positions":[],"invite":{"active":true,"expires_at":null},"server_now":"2026-11-05T12:00:00.000Z"}
        """
        let o = try JSONDecoder().decode(OutingSnapshot.self, from: Data(old.utf8))
        XCTAssertNil(o.personal_invites)
        XCTAssertNil(o.invite?.open_links)

        let pv = """
        {"outing_id":"o","name":"طلعة","status":"active","owner_name":"أبو فهد","member_count":3,"expires_at":"2026-11-06T09:00:00.000Z",
         "join_locked":false,"kind":"personal","invitee_name":"فهد أخوي","claim":"taken","already_member":false}
        """
        let p = try JSONDecoder().decode(InvitePreview.self, from: Data(pv.utf8))
        XCTAssertTrue(p.isPersonal)
        XCTAssertEqual(p.claim, "taken")
        XCTAssertEqual(p.invitee_name, "فهد أخوي")

        /* A personal-only trip comes back without an open link. */
        let created = try JSONDecoder().decode(OutingsAPI.CreatedBox.self, from: Data(#"{"ok":true,"outing_id":"o","invite":null,"open_links":false}"#.utf8))
        XCTAssertNil(created.invite)
        XCTAssertTrue(OutingAPIError(code: "invite_taken", status: 409).arabic.hasPrefix("هذه الدعوة لشخص آخر."))
        XCTAssertEqual(OutingAPIError(code: "invite_invalid", status: 404).arabic, "الرابط ناقص أو فيه خطأ.")
    }

    func testInvitePreviewDestinationIsOptional() throws {
        let base = #""outing_id":"o","name":"طلعة","status":"active","owner_name":"أبو فهد","member_count":3,"expires_at":"2026-11-06T09:00:00.000Z""#
        /* The current production server: no field → nothing shown. */
        let old = try JSONDecoder().decode(InvitePreview.self, from: Data("{\(base)}".utf8))
        XCTAssertNil(old.destination_name)
        XCTAssertNil(InvitePreviewUI.destination(old.destination_name))
        /* Newer server: «الوجهة: روضة الثمامة». */
        let new = try JSONDecoder().decode(InvitePreview.self, from: Data("{\(base),\"destination_name\":\" روضة الثمامة \"}".utf8))
        XCTAssertEqual(new.destination_name, " روضة الثمامة ")
        XCTAssertEqual(InvitePreviewUI.destination(new.destination_name), "روضة الثمامة")
        /* Explicit null or blank: nothing. */
        let null = try JSONDecoder().decode(InvitePreview.self, from: Data("{\(base),\"destination_name\":null}".utf8))
        XCTAssertNil(null.destination_name)
        XCTAssertNil(InvitePreviewUI.destination("  "))
    }

    func testModelInvitesResendsRevokesAndKeepsTheNumberOnThisPhoneOnly() async throws {
        let d = UserDefaults(suiteName: "pi-\(UUID().uuidString)")!
        let m = PersonalInvitesModel(outingId: "o1", outingName: "طلعة الثمامة", api: nil, isDemo: true, defaults: d, initial: [])
        let none = await m.invite(name: "  ", phone: nil)
        XCTAssertNil(none)
        XCTAssertEqual(m.errorText, "اكتب اسم الشخص كما تعرفه.")
        let bad = await m.invite(name: "فهد", phone: "12")
        XCTAssertNil(bad)
        XCTAssertEqual(m.errorText, OutingAPIError(code: "invalid_phone", status: 400).arabic)

        let made = await m.invite(name: "فهد أخوي", phone: "050 123 4567")
        let draft = try XCTUnwrap(made)
        XCTAssertNil(m.errorText)
        XCTAssertEqual(draft.phone, "+966501234567")
        XCTAssertEqual(draft.invite.phone_last4, "4567")
        XCTAssertNil(draft.invite.token, "the token is not kept in the list row")
        XCTAssertTrue(draft.text.contains(draft.link.absoluteString))
        XCTAssertEqual(m.draft, draft, "the send sheet opens")
        XCTAssertEqual(m.invites.count, 1)
        XCTAssertEqual(m.phone(for: m.invites[0]), "+966501234567", "full number on this phone")
        XCTAssertEqual(m.link(for: m.invites[0]), draft.link)

        /* Same number again: the newer one replaces the older unused line. */
        _ = await m.invite(name: "فهد", phone: "0501234567")
        XCTAssertEqual(m.invites.count, 1)
        XCTAssertEqual(m.invites[0].invitee_name, "فهد")

        let first = m.invites[0]
        let resent = await m.resend(first)
        let again = try XCTUnwrap(resent)
        XCTAssertNotEqual(again.invite.id, first.id)
        XCTAssertNotEqual(again.link, draft.link)
        XCTAssertEqual(again.phone, "+966501234567", "the number follows the re-send")
        XCTAssertNil(PersonalInviteBook.entry("o1", first.id, defaults: d))
        XCTAssertEqual(m.invites.count, 1)

        await m.revoke(m.invites[0])
        XCTAssertEqual(m.invites[0].status, .revoked)

        await m.setOpenLinks(true)
        XCTAssertEqual(m.openLinks, true)
        XCTAssertTrue(LocalAccountData.keys.contains(PersonalInviteBook.key), "«احذف حسابي» clears the numbers")
    }

    func testInvitedMemberReadsUnderTheLeadersNameAndNeverSharedIsSaid() {
        func mem(_ id: String, _ name: String, nick: String? = nil, sharing: Bool = true) -> Member {
            Member(user_id: id, display_name: name, phone: nil, role: id == "me" ? "owner" : "member", sharing: sharing, joined_at: "2026-11-05T10:00:00.000Z",
                   online: true, last_seen_at: ISODate.string(now), nickname: nick, invited: nick != nil)
        }
        let snap = OutingSnapshot(
            outing: OutingInfo(id: "o", name: "طلعة", status: .active, owner_id: "me"),
            me: SnapshotMe(user_id: "me", role: "owner", sharing: true),
            members: [mem("me", "أنا"), mem("f", "فهد أخوي", nick: "جوس"), mem("s", "سعد"), mem("p", "ريم", sharing: false)],
            positions: [Position(user_id: "s", lat: 24.7, lng: 46.7, accuracy: 5, heading: nil, speed: 0, mode: .balanced, recorded_at: ISODate.string(now))],
            invite: nil, server_now: ISODate.string(now))
        var i = LivePresenterInput()
        i.view = OutingView(snap, deviceNow: now)
        i.now = now
        let rows = LiveOutingPresenter.participants(i)
        let f = rows.first { $0.id == "f" }
        XCTAssertEqual(f?.name, "فهد أخوي", "the inviter's name is the name")
        XCTAssertEqual(f?.nickname, "جوس", "their own name, secondarily")
        XCTAssertEqual(f?.neverShared, true, "in the list even without a location: «ما شارك موقعه»")
        XCTAssertEqual(rows.first { $0.id == "s" }?.neverShared, false)
        XCTAssertEqual(rows.first { $0.id == "p" }?.neverShared, false, "paused on purpose stays «متوقف»")
        XCTAssertEqual(rows.first { $0.id == "me" }?.neverShared, false)
        XCTAssertNil(rows.first { $0.id == "s" }?.nickname)
    }

    // MARK: Production before the server update (no PR #61 routes)

    func testOlderServerFallsBackToTheOpenLinkWithoutAnError() async throws {
        /* Create on an older server: `invites: "personal"` is ignored and an open link comes back. */
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [OldServerProtocol.self]
        let api = OutingsAPI(base: URL(string: "https://old.example")!, session: URLSession(configuration: cfg), tokenProvider: { "t" })
        let created = try await api.create(name: "طلعة")
        XCTAssertEqual(created.invite?.token, "open-token", "the old open link is what the wizard shows")
        XCTAssertNil(created.open_links)

        /* The personal routes are missing (Express «Cannot POST», no JSON): silent fallback. */
        let d = UserDefaults(suiteName: "pi-old-\(UUID().uuidString)")!
        let m = PersonalInvitesModel(outingId: "o1", outingName: "طلعة", api: api, isDemo: false, defaults: d)
        await m.load()
        XCTAssertTrue(m.serverLacksPersonal)
        XCTAssertNil(m.errorText)
        let m2 = PersonalInvitesModel(outingId: "o1", outingName: "طلعة", api: api, isDemo: false, defaults: d)
        let draft = await m2.invite(name: "فهد", phone: nil)
        XCTAssertNil(draft)
        XCTAssertNil(m2.errorText, "no error for the leader — the open-link card replaces the section")
        XCTAssertTrue(m2.serverLacksPersonal)

        /* A JSON 404 is a real answer from a server that has the feature: it is shown. */
        XCTAssertFalse(PersonalInvitesModel.isMissingRoute(OutingAPIError(code: "invite_not_found", status: 404)))
        XCTAssertTrue(PersonalInvitesModel.isMissingRoute(OutingAPIError(code: "http_404", status: 404)))
    }

    func testLeaderSnapshotTellsWhetherTheServerHasPersonalInvites() throws {
        let old = try JSONDecoder().decode(InviteState.self, from: Data(#"{"active":true,"expires_at":null}"#.utf8))
        let new = try JSONDecoder().decode(InviteState.self, from: Data(#"{"active":false,"expires_at":null,"open_links":false}"#.utf8))
        XCTAssertFalse(PersonalInvitesSupport.serverHasPersonal(loaded: true, invite: old, personalInvites: nil, iLead: true, isDemo: false))
        XCTAssertFalse(PersonalInvitesSupport.serverHasPersonal(loaded: true, invite: nil, personalInvites: nil, iLead: true, isDemo: false))
        XCTAssertTrue(PersonalInvitesSupport.serverHasPersonal(loaded: true, invite: new, personalInvites: [], iLead: true, isDemo: false))
        XCTAssertTrue(PersonalInvitesSupport.serverHasPersonal(loaded: true, invite: nil, personalInvites: nil, iLead: false, isDemo: false), "members keep the new state")
        XCTAssertTrue(PersonalInvitesSupport.serverHasPersonal(loaded: true, invite: old, personalInvites: nil, iLead: true, isDemo: true))
    }
}

/// An `/api/outings` server from before «دعوة شخصية»: open links only, no personal routes.
final class OldServerProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url?.path ?? ""
        let method = request.httpMethod ?? "GET"
        let (status, body): (Int, String) = {
            if path.contains("/invites/personal") || path.hasSuffix("/invites/settings") {
                return (404, "<!DOCTYPE html><html><body><pre>Cannot \(method) \(path)</pre></body></html>")
            }
            if method == "POST", path == "/api/outings" {
                return (201, #"{"ok":true,"outing_id":"o1","invite":{"token":"open-token","expires_at":"2026-11-06T12:00:00.000Z"}}"#)
            }
            return (404, #"{"ok":false,"error":"not_found"}"#)
        }()
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// Who a personal invite belongs to, as the sheet shows it, and the pasted-link hygiene.
final class InviteClaimMatrixTests: XCTestCase {
    private func preview(kind: String = "personal", claim: String?, reclaim: Bool? = nil) throws -> InvitePreview {
        var o: [String: Any] = ["outing_id": "o", "name": "طلعة", "status": "active", "owner_name": "أبو فهد", "member_count": 3,
                                "expires_at": "2026-11-07T10:00:00Z", "kind": kind, "invitee_name": "فهد أخوي"]
        if let claim { o["claim"] = claim }
        if let reclaim { o["reclaim"] = reclaim }
        return try JSONDecoder().decode(InvitePreview.self, from: JSONSerialization.data(withJSONObject: o))
    }

    func testClaimMatrix() throws {
        /* Not used yet → join. */
        XCTAssertEqual(InviteClaim.outcome(try preview(claim: "open")), .join)
        /* Same account (rejoin) → join. */
        XCTAssertEqual(InviteClaim.outcome(try preview(claim: "yours")), .join)
        /* The same person, signed in again with a new account whose phone matches → the server says open + reclaim. */
        let back = try preview(claim: "open", reclaim: true)
        XCTAssertEqual(back.reclaim, true)
        XCTAssertEqual(InviteClaim.outcome(back), .join)
        /* Someone else → «هذه الدعوة لشخص آخر». */
        XCTAssertEqual(InviteClaim.outcome(try preview(claim: "taken")), .taken)
        /* Anonymous preview of a used invite: joining decides. */
        XCTAssertEqual(InviteClaim.outcome(try preview(claim: "claimed")), .join)
        /* An open group link is never «taken». */
        XCTAssertEqual(InviteClaim.outcome(try preview(kind: "group", claim: "taken")), .join)
        /* A broken link is «الرابط ناقص أو فيه خطأ», never «لشخص آخر». */
        XCTAssertEqual(InviteClaim.outcome(errorCode: "invite_invalid"), .invalid)
        XCTAssertEqual(InviteClaim.outcome(errorCode: "http_404"), .invalid)
        XCTAssertEqual(InviteClaim.outcome(errorCode: "invite_taken"), .taken)
        XCTAssertEqual(InviteClaim.outcome(errorCode: "invite_expired"), .expired)
        XCTAssertEqual(InviteClaim.outcome(errorCode: "network"), .other)
    }

    func testSanitisedPastedTokens() {
        let tok = "ausZSm0nMZSeUyFs4ZNbHV27qdY91tBprcAXBS9687Y"
        let link = "https://farq-map-investor.vercel.app/outings/join#\(tok)"
        XCTAssertEqual(InviteLink.token(fromPasted: link + "\u{064B}"), tok, "the owner's paste: a trailing «ً»")
        XCTAssertEqual(InviteLink.token(fromPasted: "\u{200F}" + link + " \u{200E}"), tok, "RTL / LRM marks")
        XCTAssertEqual(InviteLink.token(fromPasted: "تعال معنا: " + link + "\u{064B} 👍"), tok)
        XCTAssertEqual(InviteLink.token(fromPasted: tok + "\u{0651}"), tok, "a bare token with a shadda")
        XCTAssertEqual(InviteLink.token(fromPasted: "\u{FEFF}" + tok), tok, "a BOM")
        XCTAssertEqual(InviteLink.token(from: URL(string: link + "%D9%8B")!), tok, "opened with the mark percent-encoded")
        XCTAssertNil(InviteLink.token(fromPasted: String(link.dropLast())), "one character short stays broken")
        XCTAssertNil(InviteLink.token(fromPasted: link + "A"), "a longer run is not trimmed into a token")
        XCTAssertNil(InviteLink.token(fromPasted: "https://example.com/x"))
    }
}
