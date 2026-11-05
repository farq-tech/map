import Foundation
import SwiftUI

/// «دعوة شخصية»: the leader invites a person they know — picked from Contacts
/// or typed (name + number). Each invite is ONE single-use link bound to that
/// person: whoever opens it joins the trip AS them, under the name the leader
/// gave them («فهد أخوي»). The server keeps only the last 4 digits of the number
/// and a salted digest; the full number stays on this phone (`PersonalInviteBook`).
/// Server side: apps/api/lib/outings/invites.js.

// MARK: - Saudi numbers (same rules as the server's `validate.phone`)

enum KSAPhone {
    /// Any form people keep in Contacts → E.164 (+9665XXXXXXXX), or nil when it is not a number.
    /// 05…, 5…, 9665…, 009665…, +966 05…, Arabic-Indic digits, spaces/dashes/brackets.
    static func normalize(_ raw: String) -> String? {
        var t = ""
        for ch in raw {
            if let d = arabicDigit(ch) { t.append(d) } else if !" -().\u{00A0}\u{200E}\u{200F}\u{202A}\u{202C}".contains(ch) { t.append(ch) }
        }
        if t.hasPrefix("00") { t = "+" + t.dropFirst(2) }
        if t.range(of: #"^\+?96605\d{8}$"#, options: .regularExpression) != nil {
            t = "+966" + t.replacingOccurrences(of: #"^\+?9660"#, with: "", options: .regularExpression)
        }
        if t.range(of: #"^05\d{8}$"#, options: .regularExpression) != nil { t = "+966" + t.dropFirst() }
        else if t.range(of: #"^5\d{8}$"#, options: .regularExpression) != nil { t = "+966" + t }
        else if t.range(of: #"^9665\d{8}$"#, options: .regularExpression) != nil { t = "+" + t }
        return t.range(of: #"^\+\d{8,15}$"#, options: .regularExpression) != nil ? t : nil
    }

    static func last4(_ e164: String) -> String? {
        let d = e164.filter(\.isNumber)
        return d.count >= 4 ? String(d.suffix(4)) : nil
    }

    /// «05X XXX XXXX» for a Saudi mobile, the E.164 otherwise.
    static func display(_ e164: String) -> String {
        guard e164.hasPrefix("+9665"), e164.count == 13 else { return e164 }
        let local = "0" + e164.dropFirst(4)
        let a = local.prefix(3), b = local.dropFirst(3).prefix(3), c = local.suffix(4)
        return "\(a) \(b) \(c)"
    }

    private static func arabicDigit(_ ch: Character) -> Character? {
        guard let v = ch.unicodeScalars.first?.value else { return nil }
        if (0x0660...0x0669).contains(v) { return Character(String(v - 0x0660)) }
        if (0x06F0...0x06F9).contains(v) { return Character(String(v - 0x06F0)) }
        return nil
    }
}

// MARK: - The message the leader sends

enum PersonalInviteText {
    /// Prefilled Arabic text, addressed to the person by the name the leader saved.
    static func message(inviteeName: String, outingName: String, link: URL) -> String {
        [
            "هلا \(inviteeName)، هذي دعوتك لطلعة «\(outingName)» على سَرى البارق.",
            "الرابط لك أنت فقط ويُستخدم مرة وحدة، لا ترسله لأحد:",
            link.absoluteString,
        ].joined(separator: "\n")
    }

    /// Straight to that person's WhatsApp chat (or WhatsApp's picker without a number).
    static func whatsAppURL(phone: String?, text: String) -> URL? {
        var c = URLComponents(string: "https://wa.me/" + (phone.map { $0.filter(\.isNumber) } ?? ""))!
        c.queryItems = [.init(name: "text", value: text)]
        return c.url
    }

    /// Messages, to that number, with the text filled in.
    static func smsURL(phone: String, text: String) -> URL? {
        var c = URLComponents()
        c.scheme = "sms"
        c.path = phone
        c.queryItems = [.init(name: "body", value: text)]
        /* iOS reads `sms:+966…&body=…` (no `?`). */
        return c.url.flatMap { URL(string: $0.absoluteString.replacingOccurrences(of: "?body=", with: "&body=")) }
    }
}

// MARK: - Status as the leader reads it

enum PersonalInviteStatusText {
    static func label(_ i: PersonalInvite) -> String {
        switch i.status {
        case .sent: return "أُرسلت"
        case .opened: return "فتحها ولم ينضم"
        case .joined: return "انضم"
        case .expired: return i.opened == true ? "انتهت قبل أن ينضم" : "لم يفتحها"
        case .revoked: return "أُلغيت"
        }
    }

    static func tone(_ i: PersonalInvite) -> SaryTone {
        switch i.status {
        case .joined: return .success
        case .sent, .opened: return .info
        case .expired: return .warning
        case .revoked: return .error
        }
    }

    /// Can «أرسل من جديد» help? Not once they are in.
    static func canResend(_ i: PersonalInvite) -> Bool { i.status != .joined }
    static func canRevoke(_ i: PersonalInvite) -> Bool { i.status == .sent || i.status == .opened }
}

// MARK: - What only this phone knows (full number, the link)

/// Per outing, per invite: the full number from the leader's contacts and the
/// link token. On this phone only; cleared with «احذف حسابي».
enum PersonalInviteBook {
    static let key = "sary.outings.personalInvites.v1"
    struct Entry: Codable, Equatable { var phone: String?; var token: String? }

    static func all(_ outingId: String, defaults: UserDefaults = .standard) -> [String: Entry] {
        guard let d = defaults.data(forKey: key), let m = try? JSONDecoder().decode([String: [String: Entry]].self, from: d) else { return [:] }
        return m[outingId] ?? [:]
    }

    static func entry(_ outingId: String, _ inviteId: String, defaults: UserDefaults = .standard) -> Entry? {
        all(outingId, defaults: defaults)[inviteId]
    }

    static func save(_ outingId: String, _ inviteId: String, _ e: Entry?, defaults: UserDefaults = .standard) {
        var m = (defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([String: [String: Entry]].self, from: $0) }) ?? [:]
        var room = m[outingId] ?? [:]
        room[inviteId] = e
        m[outingId] = room.isEmpty ? nil : room
        defaults.set(try? JSONEncoder().encode(m), forKey: key)
    }

    /// A re-send makes a new invite id: carry the number over.
    static func move(_ outingId: String, from old: String, to new: String, token: String?, defaults: UserDefaults = .standard) {
        let phone = entry(outingId, old, defaults: defaults)?.phone
        save(outingId, old, nil, defaults: defaults)
        save(outingId, new, Entry(phone: phone, token: token), defaults: defaults)
    }
}

// MARK: - The model behind the «ادعُ ربعك» section

/// A ready-to-send invite: who, the link, the text, and how to reach them.
struct InviteDraft: Identifiable, Equatable {
    var id: String { invite.id }
    var invite: PersonalInvite
    var link: URL
    var phone: String?
    var text: String
}

@MainActor
final class PersonalInvitesModel: ObservableObject {
    @Published private(set) var invites: [PersonalInvite] = []
    @Published private(set) var busy: Set<String> = []
    @Published var errorText: String?
    /// nil = unknown yet (older server: treat as on).
    @Published private(set) var openLinks: Bool?
    /// Set after create / resend: the send options sheet shows it.
    @Published var draft: InviteDraft?
    /// The server has no «دعوة شخصية» routes yet (production before PR #61): the
    /// section falls back to the old open link, silently — no error for the leader.
    @Published private(set) var serverLacksPersonal = false

    let outingId: String
    let outingName: String
    private let api: OutingsAPI?
    private let defaults: UserDefaults
    private let isDemo: Bool

    init(outingId: String, outingName: String, api: OutingsAPI?, isDemo: Bool, defaults: UserDefaults = .standard,
         initial: [PersonalInvite]? = nil, openLinks: Bool? = nil) {
        self.outingId = outingId
        self.outingName = outingName
        self.api = api
        self.isDemo = isDemo
        self.defaults = defaults
        self.openLinks = openLinks
        if let initial { invites = initial } else if isDemo { invites = Self.demoInvites() }
    }

    /// Server rows plus what this phone knows (the full number).
    func phone(for i: PersonalInvite) -> String? { PersonalInviteBook.entry(outingId, i.id, defaults: defaults)?.phone }
    func link(for i: PersonalInvite) -> URL? {
        (i.token ?? PersonalInviteBook.entry(outingId, i.id, defaults: defaults)?.token).map(InviteLink.url(for:))
    }

    var joinedCount: Int { invites.filter { $0.status == .joined }.count }

    func apply(snapshotInvites: [PersonalInvite]?, openLinks: Bool?) {
        if let s = snapshotInvites { invites = s }
        if let openLinks { self.openLinks = openLinks }
    }

    func load() async {
        guard let api, !isDemo else { return }
        do { invites = try await api.personalInvites(outingId) } catch let e as OutingAPIError where Self.isMissingRoute(e) { serverLacksPersonal = true } catch {}
    }

    /// An Express "Cannot GET …" 404 (no JSON `error`): the route does not exist on this server.
    /// A JSON 404 (`invite_not_found`, `not_found`) is a real answer from a server that has it.
    nonisolated static func isMissingRoute(_ e: OutingAPIError) -> Bool { e.status == 404 && e.code == "http_404" }

    /// Invite one person. `phone` is whatever the contact card / field holds; nil or "" = no number.
    @discardableResult
    func invite(name rawName: String, phone rawPhone: String?) async -> InviteDraft? {
        errorText = nil
        guard let name = ServerRules.cleanText(rawName, max: ServerRules.nameMax) else {
            errorText = OutingAPIError(code: "invalid_invitee_name", status: 400).arabic
            return nil
        }
        var phone: String?
        if let raw = rawPhone?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            guard let p = KSAPhone.normalize(raw) else {
                errorText = OutingAPIError(code: "invalid_phone", status: 400).arabic
                return nil
            }
            phone = p
        }
        var made: PersonalInvite?
        await run("new") {
            if isDemo || api == nil {
                made = PersonalInvite(id: UUID().uuidString.lowercased(), invitee_name: name, phone_last4: phone.flatMap(KSAPhone.last4), status: .sent,
                                      opened: false, created_at: ISODate.string(Date()), expires_at: ISODate.string(Date().addingTimeInterval(86_400)),
                                      member_user_id: nil, token: Self.demoToken())
            } else {
                made = try await api!.createPersonalInvite(outingId, name: name, phone: phone)
            }
        }
        guard var inv = made else { return nil }
        PersonalInviteBook.save(outingId, inv.id, .init(phone: phone, token: inv.token), defaults: defaults)
        if let p = phone {
            /* Same number again: the server superseded the older unused link. */
            invites.removeAll { $0.status != .joined && self.phone(for: $0) == p && $0.id != inv.id }
        }
        let token = inv.token
        inv.token = nil
        invites.insert(inv, at: 0)
        return makeDraft(inv, token: token, phone: phone)
    }

    /// «أرسل من جديد»: a fresh link for the same person; the old link stops working.
    @discardableResult
    func resend(_ i: PersonalInvite) async -> InviteDraft? {
        errorText = nil
        var fresh: PersonalInvite?
        await run(i.id) {
            if isDemo || api == nil {
                var n = i
                n.id = UUID().uuidString.lowercased()
                n.status = .sent
                n.opened = false
                n.token = Self.demoToken()
                n.expires_at = ISODate.string(Date().addingTimeInterval(86_400))
                fresh = n
            } else {
                fresh = try await api!.resendPersonalInvite(outingId, invite: i.id)
            }
        }
        guard var n = fresh else { return nil }
        PersonalInviteBook.move(outingId, from: i.id, to: n.id, token: n.token, defaults: defaults)
        let token = n.token
        n.token = nil
        if let k = invites.firstIndex(where: { $0.id == i.id }) { invites[k] = n } else { invites.insert(n, at: 0) }
        return makeDraft(n, token: token, phone: phone(for: n))
    }

    /// «ألغِ الدعوة».
    func revoke(_ i: PersonalInvite) async {
        errorText = nil
        var out: PersonalInvite?
        await run(i.id) {
            if isDemo || api == nil { var n = i; n.status = .revoked; out = n } else { out = try await api!.revokePersonalInvite(outingId, invite: i.id) }
        }
        guard let out, let k = invites.firstIndex(where: { $0.id == i.id }) else { return }
        invites[k] = out
    }

    /// «الرابط المفتوح» (for older versions of the app). Off: only personal invites admit people.
    func setOpenLinks(_ on: Bool) async {
        errorText = nil
        await run("open") {
            if isDemo || api == nil { openLinks = on } else { openLinks = try await api!.setOpenLinks(outingId, on: on) }
        }
    }

    /// Present the send options again for an invite whose link this phone still has.
    func share(_ i: PersonalInvite) {
        guard let link = link(for: i) else { return }
        draft = InviteDraft(invite: i, link: link, phone: phone(for: i),
                            text: PersonalInviteText.message(inviteeName: i.invitee_name, outingName: outingName, link: link))
    }

    private func makeDraft(_ inv: PersonalInvite, token: String?, phone: String?) -> InviteDraft? {
        guard let token else { return nil }
        let link = InviteLink.url(for: token)
        let d = InviteDraft(invite: inv, link: link, phone: phone,
                            text: PersonalInviteText.message(inviteeName: inv.invitee_name, outingName: outingName, link: link))
        draft = d
        return d
    }

    private func run(_ key: String, _ work: () async throws -> Void) async {
        busy.insert(key)
        defer { busy.remove(key) }
        do { try await work() } catch let e as OutingAPIError where Self.isMissingRoute(e) {
            serverLacksPersonal = true
        } catch let e as OutingAPIError { errorText = e.arabic } catch { errorText = OutingAPIError(code: "network", status: 0).arabic }
    }

    private static func demoToken() -> String {
        let a = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        return String((0..<43).map { _ in a.randomElement()! })
    }

    /// `-demo`: a believable list (one per status) so the section can be seen without a server.
    static func demoInvites(now: Date = Date()) -> [PersonalInvite] {
        func at(_ s: Double) -> String { ISODate.string(now.addingTimeInterval(s)) }
        return [
            PersonalInvite(id: "demo-inv-1", invitee_name: "فهد أخوي", phone_last4: "4567", status: .joined, opened: true, created_at: at(-3600), expires_at: at(20 * 3600), member_user_id: DemoData.invitedId, token: nil),
            PersonalInvite(id: "demo-inv-2", invitee_name: "سعد ولد عمي", phone_last4: "1111", status: .opened, opened: true, created_at: at(-1800), expires_at: at(22 * 3600), member_user_id: nil, token: nil),
            PersonalInvite(id: "demo-inv-3", invitee_name: "ناصر", phone_last4: nil, status: .sent, opened: false, created_at: at(-600), expires_at: at(23 * 3600), member_user_id: nil, token: nil),
            PersonalInvite(id: "demo-inv-4", invitee_name: "خالد الدوسري", phone_last4: "9090", status: .expired, opened: false, created_at: at(-30 * 3600), expires_at: at(-6 * 3600), member_user_id: nil, token: nil),
        ]
    }
}
