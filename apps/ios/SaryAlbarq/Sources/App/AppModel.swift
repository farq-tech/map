import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var identity: Identity?
    @Published private(set) var current: [OutingSummary] = []
    @Published private(set) var history: [OutingSummary] = []
    @Published var session: OutingSession?
    /// An invite that arrived by link and waits for the join sheet.
    @Published var pendingInvite: String?
    @Published var errorText: String?
    @Published var loading = false

    let api: OutingsAPI
    let location: LocationSharer
    let isDemo: Bool

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        let api = OutingsAPI(tokenProvider: { IdentityStore.load()?.token })
        self.api = api
        location = LocationSharer()
        isDemo = arguments.contains("-demo")
        if arguments.contains("-resetState") {
            IdentityStore.save(nil)
            ShareMemory.forgetAll()
            for k in [OutingSession.modeKey, OutingSession.batteryKey] { UserDefaults.standard.removeObject(forKey: k) }
        }
        /* v1 consent was not tied to an identity: never honour it. */
        ShareMemory.dropLegacy()
        if isDemo {
            identity = Identity(token: "", user: PublicUser(id: DemoData.meId, display_name: "أنا", avatar: nil, phone: nil))
        } else {
            identity = IdentityStore.load()
        }
        api.onUnauthorized = { [weak self] in
            Task { @MainActor in self?.signOut() }
        }
        if isDemo { openDemo() } else { resumeActiveShare() }
    }

    func createIdentity(name: String, phone: String) async {
        guard let clean = ServerRules.cleanText(name, max: ServerRules.nameMax) else {
            errorText = OutingAPIError(code: "invalid_name", status: 400).arabic
            return
        }
        let p = phone.trimmingCharacters(in: .whitespaces)
        if !p.isEmpty && ServerRules.normalizePhone(p) == nil {
            errorText = OutingAPIError(code: "invalid_phone", status: 400).arabic
            return
        }
        loading = true
        defer { loading = false }
        do {
            var id = try await api.createIdentity(name: clean)
            IdentityStore.save(id)
            if let e164 = ServerRules.normalizePhone(p) {
                id.user = try await api.updateProfile(phone: e164)
                IdentityStore.save(id)
            }
            identity = id
            await refresh()
        } catch let e as OutingAPIError { errorText = e.arabic } catch {}
    }

    func updateProfile(name: String, phone: String) async -> Bool {
        let p = phone.trimmingCharacters(in: .whitespaces)
        let e164 = p.isEmpty ? "" : ServerRules.normalizePhone(p)
        guard let e164 else {
            errorText = OutingAPIError(code: "invalid_phone", status: 400).arabic
            return false
        }
        do {
            let u = try await api.updateProfile(name: name, phone: e164)
            if var id = identity {
                id.user = u
                IdentityStore.save(id)
                identity = id
            }
            return true
        } catch let e as OutingAPIError { errorText = e.arabic } catch {}
        return false
    }

    func signOut() {
        if let u = identity?.user.id { ShareMemory.setActiveShare(user: u, outing: nil) }
        session?.close()
        session = nil
        IdentityStore.save(nil)
        identity = nil
        current = []
        history = []
    }

    func refresh() async {
        guard identity != nil, !isDemo else { return }
        do {
            let r = try await api.list()
            current = r.current
            history = r.history
        } catch let e as OutingAPIError { errorText = e.arabic } catch {}
    }

    func createOuting(name: String) async -> String? {
        guard let clean = ServerRules.cleanText(name, max: ServerRules.outingNameMax) else {
            errorText = OutingAPIError(code: "invalid_outing_name", status: 400).arabic
            return nil
        }
        do {
            let r = try await api.create(name: clean)
            InviteTokenStore.save(r.outing_id, r.invite.token)
            await refresh()
            open(r.outing_id)
            return r.outing_id
        } catch let e as OutingAPIError { errorText = e.arabic } catch {}
        return nil
    }

    func preview(_ token: String) async throws -> InvitePreview { try await api.preview(token: token) }

    func join(_ token: String) async {
        do {
            let r = try await api.join(token: token)
            pendingInvite = nil
            await refresh()
            open(r.outing_id)
        } catch let e as OutingAPIError { errorText = e.arabic } catch {}
    }

    func open(_ outingId: String) {
        if isDemo {
            if outingId == DemoData.outingId { openDemoSession() }
            return
        }
        guard let id = identity else { return }
        if session?.id == outingId { return }
        session?.close()
        let s = OutingSession(id: outingId, myUserId: id.user.id, api: api, token: id.token, location: location)
        session = s
        s.open()
        Notifier.requestPermission()
    }

    func closeSession() {
        session?.close()
        session = nil
        Task { await refresh() }
    }

    func handle(url: URL) {
        if let t = InviteLink.token(from: url) { pendingInvite = t }
    }

    func foreground(_ active: Bool) {
        session?.foreground(active)
        if active { Task { await refresh() } }
    }

    /// The app restarted mid-share: pick the share back up (this identity, this outing, consent given; foreground only).
    private func resumeActiveShare() {
        guard let me = identity?.user.id, let id = ShareMemory.activeShare(user: me) else { return }
        open(id)
        session?.resumeIfPreviouslySharing()
    }

    private func openDemo() {
        current = [OutingSummary(id: DemoData.outingId, name: "طلعة الثمامة (عرض تجريبي)", status: .active, role: "owner", my_status: "active", member_count: 4, created_at: nil, started_at: nil, ended_at: nil)]
        history = [OutingSummary(id: "demo-old", name: "كشتة نفود الثويرات", status: .ended, role: "member", my_status: "active", member_count: 6, created_at: nil, started_at: nil, ended_at: nil)]
        openDemoSession()
    }

    private func openDemoSession() {
        let s = OutingSession(id: DemoData.outingId, myUserId: DemoData.meId, api: api, token: "", location: location, demo: DemoData.view())
        session = s
        s.open()
    }
}

/// A fixed outing for screenshots and UI tests (`-demo` launch argument). Clearly
/// labelled in the UI; never talks to the server.
enum DemoData {
    static let meId = "00000000-0000-4000-8000-000000000001"
    static let outingId = "00000000-0000-4000-8000-0000000000aa"

    static func view(now: Date = Date()) -> OutingView {
        func ago(_ s: Double) -> String { ISODate.string(now.addingTimeInterval(-s)) }
        let members: [Member] = [
            Member(user_id: meId, display_name: "أنا", phone: nil, role: "owner", sharing: true, joined_at: "2026-11-03T10:00:00.000Z", online: true, last_seen_at: ago(1)),
            Member(user_id: "00000000-0000-4000-8000-000000000002", display_name: "أبو فهد", phone: "+966500000001", role: "member", sharing: true, joined_at: "2026-11-03T10:01:00.000Z", online: true, last_seen_at: ago(2), note: MemberNote(text: "بوقف عند المحطة", at: ago(30))),
            Member(user_id: "00000000-0000-4000-8000-000000000003", display_name: "سلطان", phone: nil, role: "member", sharing: true, joined_at: "2026-11-03T10:02:00.000Z", online: true, last_seen_at: ago(20)),
            Member(user_id: "00000000-0000-4000-8000-000000000004", display_name: "نورة", phone: "+966500000002", role: "member", sharing: true, joined_at: "2026-11-03T10:03:00.000Z", online: false, last_seen_at: ago(240)),
        ]
        let positions: [Position] = [
            Position(user_id: members[1].user_id, lat: 24.7128, lng: 46.67395, accuracy: 8, heading: 340, speed: 22, mode: .balanced, recorded_at: ago(3)),
            Position(user_id: members[2].user_id, lat: 24.7105, lng: 46.6747, accuracy: 15, heading: nil, speed: 0, mode: .balanced, recorded_at: ago(95)),
            Position(user_id: members[3].user_id, lat: 24.7119, lng: 46.6770, accuracy: 25, heading: 180, speed: 10, mode: .saver, recorded_at: ago(300)),
        ]
        let snap = OutingSnapshot(
            outing: OutingInfo(id: outingId, name: "طلعة الثمامة (عرض تجريبي)", status: .active, owner_id: meId, created_at: ago(3600), started_at: ago(3000), ended_at: nil),
            me: SnapshotMe(user_id: meId, role: "owner", sharing: true),
            members: members, positions: positions, invite: InviteState(active: true, expires_at: nil),
            server_now: ISODate.string(now)
        )
        return OutingView(snap, deviceNow: now)
    }
}

private extension Member {
    init(user_id: String, display_name: String, phone: String?, role: String, sharing: Bool, joined_at: String, online: Bool, last_seen_at: String, note: MemberNote? = nil) {
        self.init(user_id: user_id, display_name: display_name, avatar: nil, phone: phone, role: role, sharing: sharing, joined_at: joined_at, online: online, away: false, last_seen_at: last_seen_at, gps: .ok, note: note)
    }
}
