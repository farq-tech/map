import Foundation

/// Live events from the socket (`live.ts` `LiveEvent`).
enum LiveEvent: Equatable {
    case position(Position)
    case presence(userId: String, online: Bool, away: Bool)
    case memberJoined(Member)
    case memberUpdated(userId: String, displayName: String?, avatar: String?, phone: String?)
    case memberLeft(userId: String)
    case memberSharing(userId: String, sharing: Bool)
    case ownerChanged(ownerId: String)
    case memberLink(userId: String, lastSeenAt: String, gps: GpsState?, battery: BatteryInfo? = nil)
    case memberNote(userId: String, note: MemberNote?)
    case outingStatus(OutingStatus)
    /// `sos: nil` = «أنا بخير» (cleared). `refresh` = a newer fix, not a new alarm.
    case sos(userId: String, sos: SosInfo?, refresh: Bool)
    case rally(RallyInfo?)
    case memberRole(userId: String, coLeader: Bool)
    case voiceClip(VoiceClip)
    /// «انقطع الإرسال» (see MemberSilence.swift).
    case memberSilent(SilentInfo)
    /// `reason` nil = a fresh fix arrived; else left / removed / sharing_off / going_offline.
    case memberResumed(userId: String, reason: String?)

    /// Decode one server frame; nil for frames that are not events (ack, pong, ready…).
    static func decode(_ obj: [String: Any]) -> LiveEvent? {
        guard let type = obj["type"] as? String else { return nil }
        func decodeJSON<T: Decodable>(_ v: Any?) -> T? {
            guard let v, JSONSerialization.isValidJSONObject(v),
                  let d = try? JSONSerialization.data(withJSONObject: v) else { return nil }
            return try? JSONDecoder().decode(T.self, from: d)
        }
        let uid = obj["user_id"] as? String
        switch type {
        case "position":
            return (decodeJSON(obj["position"]) as Position?).map(LiveEvent.position)
        case "presence":
            guard let uid else { return nil }
            return .presence(userId: uid, online: obj["online"] as? Bool ?? false, away: obj["away"] as? Bool ?? false)
        case "member_joined":
            guard var raw = obj["member"] as? [String: Any] else { return nil }
            if raw["joined_at"] == nil { raw["joined_at"] = ISODate.string(Date()) }
            return (decodeJSON(raw) as Member?).map(LiveEvent.memberJoined)
        case "member_updated":
            guard let m = obj["member"] as? [String: Any], let id = m["user_id"] as? String else { return nil }
            return .memberUpdated(userId: id, displayName: m["display_name"] as? String, avatar: m["avatar"] as? String, phone: m["phone"] as? String)
        case "member_left":
            return uid.map { .memberLeft(userId: $0) }
        case "member_sharing":
            guard let uid else { return nil }
            return .memberSharing(userId: uid, sharing: obj["sharing"] as? Bool ?? false)
        case "owner_changed":
            return (obj["owner_id"] as? String).map { .ownerChanged(ownerId: $0) }
        case "member_link":
            guard let uid, let at = obj["last_seen_at"] as? String else { return nil }
            return .memberLink(userId: uid, lastSeenAt: at, gps: (obj["gps"] as? String).flatMap(GpsState.init(rawValue:)), battery: decodeJSON(obj["battery"]))
        case "member_note":
            guard let uid else { return nil }
            return .memberNote(userId: uid, note: decodeJSON(obj["note"]))
        case "outing_status":
            return (obj["status"] as? String).flatMap(OutingStatus.init(rawValue:)).map(LiveEvent.outingStatus)
        case "sos":
            guard let uid else { return nil }
            return .sos(userId: uid, sos: decodeJSON(obj["sos"]), refresh: obj["refresh"] as? Bool ?? false)
        case "rally":
            return .rally(decodeJSON(obj["rally"]))
        case "member_role":
            guard let uid else { return nil }
            return .memberRole(userId: uid, coLeader: obj["co_leader"] as? Bool ?? false)
        case "voice_clip":
            return (decodeJSON(obj["clip"]) as VoiceClip?).map(LiveEvent.voiceClip)
        default:
            return decodeSilence(type, obj)
        }
    }
}

/// The client's picture of one outing: a pure reducer over the server's snapshot
/// and live events (port of `outingState.ts`), so every transition is testable
/// without a map.
struct OutingView: Equatable {
    var snapshot: OutingSnapshot
    var members: [String: Member]
    var positions: [String: Position]
    /// Voice clips still on the server (newest last).
    var clips: [VoiceClip]
    /// Friends whose sharing went silent (server-decided), by user id.
    var silent: [String: SilentInfo]
    /// server clock − device clock, ms; ages are measured on the server's clock.
    var clockOffsetMs: Double

    init(_ s: OutingSnapshot, deviceNow: Date = Date()) {
        snapshot = s
        members = Dictionary(s.members.map { ($0.user_id, $0) }, uniquingKeysWith: { _, b in b })
        positions = Dictionary(s.positions.map { ($0.user_id, $0) }, uniquingKeysWith: { _, b in b })
        clips = s.voice_clips ?? []
        silent = Dictionary((s.silent ?? []).map { ($0.user_id, $0) }, uniquingKeysWith: { _, b in b })
        let server = ISODate.parse(s.server_now) ?? deviceNow
        clockOffsetMs = (server.timeIntervalSince1970 - deviceNow.timeIntervalSince1970) * 1000
    }

    /// A snapshot replaces what we had, but never moves a marker back to an older fix.
    static func merge(_ prev: OutingView?, _ s: OutingSnapshot, deviceNow: Date = Date()) -> OutingView {
        var next = OutingView(s, deviceNow: deviceNow)
        guard let prev else { return next }
        for (uid, p) in next.positions {
            if let old = prev.positions[uid], (ISODate.parse(old.recorded_at) ?? .distantPast) > (ISODate.parse(p.recorded_at) ?? .distantPast) {
                next.positions[uid] = old
            }
        }
        return next
    }

    var myId: String { snapshot.me.user_id }
    var status: OutingStatus { snapshot.outing.status }
    var me: Member? { members[myId] }

    mutating func apply(_ e: LiveEvent) {
        applySilence(e)
        switch e {
        case .memberSilent, .memberResumed:
            break
        case let .position(p):
            guard members[p.user_id]?.sharing == true, status == .active else { return }
            if let old = positions[p.user_id],
               (ISODate.parse(old.recorded_at) ?? .distantPast) >= (ISODate.parse(p.recorded_at) ?? .distantPast) { return }
            positions[p.user_id] = p
        case let .presence(uid, online, away):
            members[uid]?.online = online
            members[uid]?.away = away
        case let .memberLink(uid, at, gps, battery):
            guard members[uid] != nil else { return }
            members[uid]?.last_seen_at = at
            members[uid]?.gps = gps
            members[uid]?.online = true
            members[uid]?.battery = battery
        case let .memberNote(uid, note):
            members[uid]?.note = note
        case let .memberJoined(m):
            var m = m
            m.online = false
            members[m.user_id] = m
        case let .memberUpdated(uid, name, avatar, phone):
            guard members[uid] != nil else { return }
            if let name { members[uid]?.display_name = name }
            members[uid]?.avatar = avatar
            members[uid]?.phone = phone
        case let .memberLeft(uid):
            members[uid] = nil
            positions[uid] = nil
            clips.removeAll { $0.user_id == uid }
        case let .memberSharing(uid, sharing):
            members[uid]?.sharing = sharing
            if !sharing { positions[uid] = nil }
            if uid == myId { snapshot.me.sharing = sharing }
        case let .ownerChanged(owner):
            for id in members.keys { members[id]?.role = id == owner ? "owner" : "member" }
            members[owner]?.co_leader = false
            snapshot.me.role = owner == myId ? "owner" : "member"
            if owner == myId { snapshot.me.co_leader = false }
            snapshot.outing.owner_id = owner
        case let .outingStatus(st):
            snapshot.outing.status = st
            /* Paused or ended: the server deleted every fix; so do we. */
            if st != .active { positions = [:] }
            if st == .ended {
                snapshot.outing.rally = nil
                clips = []
                for id in members.keys {
                    members[id]?.sos = nil
                    members[id]?.note = nil
                }
            }
        case let .sos(uid, sos, _):
            members[uid]?.sos = sos
        case let .rally(r):
            snapshot.outing.rally = r
        case let .memberRole(uid, on):
            members[uid]?.co_leader = on
            if uid == myId { snapshot.me.co_leader = on }
        case let .voiceClip(c):
            guard !clips.contains(where: { $0.id == c.id }) else { return }
            clips.append(c)
            if clips.count > 30 { clips.removeFirst(clips.count - 30) }
        }
    }

    /// Owner or «مساعد»: may start/pause the outing and manage the rally point.
    var iLead: Bool { snapshot.me.role == "owner" || snapshot.me.co_leader == true || snapshot.me.can_lead == true }
    var iOwn: Bool { snapshot.me.role == "owner" }

    func serverNowMs(deviceNow: Date = Date()) -> Double {
        deviceNow.timeIntervalSince1970 * 1000 + clockOffsetMs
    }

    /// Time since the server last heard this member at all; nil when unknown.
    func lastSeenAgeMs(_ m: Member, deviceNow: Date = Date()) -> Double? {
        guard let d = ISODate.parse(m.last_seen_at) else { return nil }
        return max(0, serverNowMs(deviceNow: deviceNow) - d.timeIntervalSince1970 * 1000)
    }

    func positionAgeMs(_ p: Position, deviceNow: Date = Date()) -> Double {
        guard let d = ISODate.parse(p.recorded_at) else { return .infinity }
        return max(0, serverNowMs(deviceNow: deviceNow) - d.timeIntervalSince1970 * 1000)
    }

    func freshness(of uid: String, deviceNow: Date = Date()) -> Policy.Freshness? {
        guard let p = positions[uid], let m = members[uid] else { return nil }
        /* The server says their fixes stopped: never live, whatever the clocks say. */
        if silent[uid] != nil { return .lost }
        return Policy.freshness(fixAgeMs: positionAgeMs(p, deviceNow: deviceNow), speedMps: p.speed, lastSeenAgeMs: lastSeenAgeMs(m, deviceNow: deviceNow))
    }

    /// Members in join order (the colour order), me first.
    var orderedMembers: [Member] {
        members.values.sorted { a, b in
            if (a.user_id == myId) != (b.user_id == myId) { return a.user_id == myId }
            if a.joined_at != b.joined_at { return a.joined_at < b.joined_at }
            return a.user_id < b.user_id
        }
    }

    var colors: [String: UInt32] { CarColors.assign(Array(members.values)) }
}

/// Arabic display formatting (Arabic-Indic digits, as `toLocaleString("ar-SA")`).
enum ArabicFormat {
    private static let nf: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "ar-SA")
        f.numberStyle = .decimal
        f.maximumFractionDigits = 1
        return f
    }()

    static func number(_ v: Double) -> String { nf.string(from: NSNumber(value: v)) ?? String(v) }

    static func distance(_ m: Double) -> String {
        if m < 1000 {
            let v = max(10, (m / 10).rounded() * 10)
            return "\(number(v)) م"
        }
        let km = m < 10_000 ? (m / 100).rounded() / 10 : (m / 1000).rounded()
        return "\(number(km)) كم"
    }

    static func ago(_ ms: Double) -> String {
        let s = max(0, (ms / 1000).rounded())
        if s < 10 { return "الآن" }
        if s < 60 { return "قبل \(number(s)) ث" }
        let m = (s / 60).rounded()
        if m < 60 { return "قبل \(number(m)) د" }
        return "قبل \(number((m / 60).rounded())) س"
    }

    static func freshnessLabel(_ f: Policy.Freshness) -> String {
        switch f {
        case .live: return "مباشر"
        case .recent: return "آخر موقع"
        case .lost: return "انقطع"
        }
    }
}
