import Foundation
// End-to-end smoke test of the app's network layer against the production API (macOS).
var token: String?
let api = OutingsAPI(tokenProvider: { token })
func log(_ s: String) { print(s); fflush(stdout) }
Task { @MainActor in
    do {
        let id = try await api.createIdentity(name: "اختبار iOS")
        token = id.token
        log("identity ok \(id.user.id)")
        let u = try await api.updateProfile(phone: ServerRules.normalizePhone("0550000000")!)
        log("phone -> \(u.phone ?? "nil")")
        let c = try await api.create(name: "اختبار تطبيق iOS")
        log("outing \(c.outing_id) invite token shaped: \(InviteLink.isTokenShaped(c.invite.token))")
        let pv = try await api.preview(token: c.invite.token)
        log("preview: \(pv.name) by \(pv.owner_name)")
        _ = try await api.setStatus(c.outing_id, action: "start")
        /* This throwaway identity shares on purpose: say so explicitly (the server's
         * join default is not consent), and open the channel's privacy gate only for it. */
        _ = try await api.setSharing(c.outing_id, sharing: true)
        let ch = LiveChannel(outingId: c.outing_id, token: id.token, deps: .init(
            makeSocket: { URLSessionLiveSocket(url: $0) },
            poll: { try await api.poll($0) }, post: { try await api.sendPosition($0, fix: $1) },
            beat: { try await api.heartbeat($0, gps: $1, battery: $2) }, scheduler: MainScheduler(),
            canSendPosition: { true }))
        var acks = 0
        ch.handlers = .init(
            onSnapshot: { s in log("ready snapshot: status=\(s.outing.status) members=\(s.members.count) positions=\(s.positions.count)") },
            onEvent: { e in log("event \(e)") },
            onState: { s in log("state \(s)") },
            onClosed: { r in log("closed \(r)") },
            onAck: { ok, r in acks += 1; log("ack ok=\(ok) reason=\(r ?? "-")") })
        ch.start()
        try await Task.sleep(nanoseconds: 3_000_000_000)
        let now = Date().timeIntervalSince1970 * 1000
        ch.sendFix(DeviceFix(lat: 24.7136, lng: 46.6753, accuracy: 8, heading: 45, speed: 12, atMs: now - 500), mode: .balanced)
        try await Task.sleep(nanoseconds: 2_000_000_000)
        ch.heartbeat(gps: .ok)
        _ = ch.sendNote("بوقف عند المحطة")
        try await Task.sleep(nanoseconds: 2_000_000_000)
        let snap = try await api.get(c.outing_id)
        log("GET positions=\(snap.positions.count) note=\(snap.members.first?.note?.text ?? "nil") phone=\(snap.members.first?.phone ?? "nil")")
        _ = try await api.setStatus(c.outing_id, action: "end")
        try await Task.sleep(nanoseconds: 2_000_000_000)
        log("ended; acks=\(acks) state=\(ch.state)")
        exit(0)
    } catch { log("FAILED \(error)"); exit(1) }
}
RunLoop.main.run()
