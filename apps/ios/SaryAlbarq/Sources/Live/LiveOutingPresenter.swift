import CoreGraphics
import Foundation
import UIKit

/// Everything the live screen needs to decide what to show, as plain values.
/// The controller fills it from the session, the GPS and its own UI state.
struct LivePresenterInput {
    var view: OutingView?
    var myFix: DeviceFix?
    var gpsState: GpsState = .unavailable
    var locationAuthorized = false
    var link: LiveChannel.State = .connecting
    var closed: LiveCloseReason?
    var wantsToShare = false
    var isSharingNow = false
    var sosSending = false
    /// `userId|sos.at` of incoming SOS alerts the person already saw («أظهره»).
    var acknowledgedSOS: Set<String> = []
    var alerts: [LiveAlertUI] = []
    var ptt: PTTStateUI = .idle
    var sheetDetent: SheetDetentUI = .peek
    var selectedTab: LiveTabUI = .participants
    var inviteLink: String?
    var isRevoking = false
    var driveMode: TriModeUI = .automatic
    var nightMode: TriModeUI = .automatic
    var notificationsOn = true
    var batterySharing = false
    /// Clips already played (no waveform icon over that car).
    var heardClips: Set<String> = []
    /// Map rotation, degrees: arrows are relative to the top of the screen.
    var mapBearing: Double = 0
    var now = Date()
    /// Members whose shown position came phone to phone (`NearbyMesh`).
    var nearbyVia: Set<String> = []
    /// Members' cars heard directly phone to phone right now.
    var nearbyCars = 0
    /// iOS «الموقع الدقيق» is off (reduced accuracy: km-level fixes).
    var preciseOff = false
}

/// Pure mapper from the app's real data (OutingView + GPS + local UI state) to
/// the screen contracts. No views, no network: every rule here is unit-tested.
enum LiveOutingPresenter {
    /// A note is a passing word: shown for 15 minutes after it was posted.
    static let noteTTL: TimeInterval = 15 * 60
    /// A rally point counts you as "arrived" inside this radius, with a live fix.
    static let arrivedRadiusM = 150.0
    /// My own GPS fix older than this is never drawn as live.
    static let myLiveMaxAgeMs = 30_000.0

    static func state(_ i: LivePresenterInput) -> LiveOutingUIState {
        let parts = participants(i)
        let v = i.view
        let me = v?.me
        return LiveOutingUIState(
            outingName: v?.snapshot.outing.name ?? "…",
            status: status(v?.status),
            connection: connection(i.link, closed: i.closed),
            sharing: sharing(i),
            warnings: warnings(i),
            alerts: i.alerts,
            ptt: i.ptt,
            sos: sos(i),
            sheetDetent: i.sheetDetent,
            selectedTab: i.selectedTab,
            participantsTab: ParticipantsTabUIState(rally: rally(i), participants: parts, myPhoneMissing: me != nil && (me?.phone ?? "").isEmpty),
            inviteTab: InviteTabUIState(link: i.inviteLink, canRevoke: v?.iOwn == true && v?.status != .ended, isRevoking: i.isRevoking),
            settingsTab: SettingsTabUIState(
                isSharingPaused: !i.wantsToShare,
                driveMode: i.driveMode,
                nightMode: i.nightMode,
                myPhone: me?.phone.flatMap(localPhone),
                notificationsOn: i.notificationsOn,
                batterySharingOn: i.batterySharing,
                offline: OfflineAreasUIState(areas: []),
                isLeader: v?.iOwn == true,
                outingStatus: status(v?.status)
            ),
            now: i.now,
            nearbyCars: i.nearbyCars
        )
    }

    // MARK: top bar

    static func status(_ s: OutingStatus?) -> OutingStatusUI {
        switch s {
        case .created?, nil: return .notStarted
        case .active?: return .active
        case .paused?: return .paused
        case .ended?: return .ended
        }
    }

    /// «متصل مباشرة بـ ٢ سيارات» — nil when no car is directly connected.
    static func nearbyLabel(_ n: Int) -> String? {
        guard n > 0 else { return nil }
        if n == 1 { return "متصل مباشرة بسيارة واحدة" }
        return "متصل مباشرة بـ \(ArabicFormat.number(Double(n))) سيارات"
    }

    static func connection(_ l: LiveChannel.State, closed: LiveCloseReason?) -> ConnectionStateUI {
        if closed != nil { return .offline }
        switch l {
        case .live: return .connected
        case .connecting: return .connecting
        case .polling: return .limited
        case .offline, .closed: return .offline
        }
    }

    static func sharing(_ i: LivePresenterInput) -> MySharingUI {
        if i.isSharingNow { return .sharing }
        if i.wantsToShare { return .starting }
        return .paused
    }

    static func warnings(_ i: LivePresenterInput) -> [LiveWarningUI] {
        var w: [LiveWarningUI] = []
        if !i.locationAuthorized && i.gpsState == .denied { w.append(.locationOff) }
        /* Reduced accuracy is kilometres off: the map, the trail and «طريق العودة» are all wrong. */
        if i.locationAuthorized && i.preciseOff { w.append(.preciseOff) }
        if i.link == .offline { w.append(.noInternet) }
        if i.wantsToShare && i.gpsState == .weak { w.append(.weakGPS) }
        /* Positions go out only while the app is on screen. */
        if i.isSharingNow { w.append(.keepScreenOn) }
        return w
    }

    // MARK: participants

    static func role(_ m: Member) -> ParticipantRole {
        if m.role == "owner" { return .leader }
        return m.co_leader == true ? .coLeader : .member
    }

    /// Device time of a server timestamp (the server's clock may differ).
    static func deviceDate(_ iso: String?, view: OutingView) -> Date? {
        ISODate.parse(iso).map { $0.addingTimeInterval(-view.clockOffsetMs / 1000) }
    }

    static func presence(of m: Member, in v: OutingView, myFix: DeviceFix?, isMe: Bool, isSharingNow: Bool, now: Date) -> ParticipantPresence {
        if isMe {
            guard isSharingNow, let f = myFix else { return .paused }
            let age = now.timeIntervalSince1970 * 1000 - f.atMs
            return age <= myLiveMaxAgeMs ? .live : .stale(since: Date(timeIntervalSince1970: f.atMs / 1000))
        }
        guard m.sharing else { return .paused }
        guard let p = v.positions[m.user_id], let fr = v.freshness(of: m.user_id, deviceNow: now) else {
            /* Sharing on the server but no fix yet: nothing to show as live. */
            return .stale(since: deviceDate(m.last_seen_at ?? m.joined_at, view: v) ?? now)
        }
        if fr == .live { return .live }
        return .stale(since: deviceDate(p.recorded_at, view: v) ?? now)
    }

    /// Where a member is, honestly: the last real fix (never estimated).
    static func position(of uid: String, in v: OutingView, myFix: DeviceFix?) -> Geo.LatLng? {
        if uid == v.myId { return myFix?.coordinate }
        return v.positions[uid].map { Geo.LatLng(lat: $0.lat, lng: $0.lng) }
    }

    static func relative(_ bearing: Double, mapBearing: Double) -> Double {
        ((bearing - mapBearing).truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
    }

    static func activeNote(_ n: MemberNote?, view v: OutingView, now: Date) -> String? {
        guard let n, !n.text.isEmpty else { return nil }
        if let at = deviceDate(n.at, view: v), now.timeIntervalSince(at) > noteTTL { return nil }
        return n.text
    }

    static func participants(_ i: LivePresenterInput) -> [ParticipantUI] {
        guard let v = i.view else { return [] }
        let colors = v.colors
        let mine = i.myFix?.coordinate
        var out: [(ParticipantUI, Int)] = []
        for (idx, m) in v.orderedMembers.enumerated() {
            let isMe = m.user_id == v.myId
            var dist: Double?
            var bearing: Double?
            if !isMe, let a = mine, let b = position(of: m.user_id, in: v, myFix: i.myFix) {
                dist = Geo.haversineMeters(a, b)
                bearing = relative(Geo.bearingDeg(a, b), mapBearing: i.mapBearing)
            }
            var battery: Int?
            if isMe {
                if i.batterySharing, let b = OutingSession.batteryNowIfAvailable() { battery = b }
            } else if let b = m.battery {
                battery = Int((b.level * 100).rounded())
            }
            let hasVoice = v.clips.contains { $0.user_id == m.user_id && !i.heardClips.contains($0.id) && !isMe }
            out.append((ParticipantUI(
                id: m.user_id,
                name: m.display_name,
                color: colors[m.user_id] ?? 0xFFFFFF,
                role: role(m),
                isMe: isMe,
                presence: presence(of: m, in: v, myFix: i.myFix, isMe: isMe, isSharingNow: i.isSharingNow, now: i.now),
                distanceMeters: dist,
                bearingDegrees: bearing,
                batteryPercent: battery,
                note: activeNote(m.note, view: v, now: i.now),
                hasVoice: hasVoice,
                hasPhone: !(m.phone ?? "").isEmpty,
                photo: nil,
                viaNearby: !isMe && i.nearbyVia.contains(m.user_id),
                speedKmh: isMe ? nil : friendSpeedKmh(m.user_id, in: v, now: i.now)
            ), idx))
        }
        /* Me first, then nearest, then the ones with no distance in join order. */
        return out.sorted { a, b in
            if a.0.isMe != b.0.isMe { return a.0.isMe }
            switch (a.0.distanceMeters, b.0.distanceMeters) {
            case let (x?, y?) where x != y: return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.1 < b.1
            }
        }.map(\.0)
    }

    /// A friend's speed, only while their position is live (Policy freshness); never from an old fix.
    static func friendSpeedKmh(_ uid: String, in v: OutingView, now: Date) -> Double? {
        guard v.members[uid]?.sharing == true, v.freshness(of: uid, deviceNow: now) == .live,
              let s = v.positions[uid]?.speed, s.isFinite, s >= 0, s <= Policy.maxPlausibleMps else { return nil }
        return Speed.kmh(s)
    }

    // MARK: SOS

    static func sosKey(_ uid: String, _ s: SosInfo) -> String { "\(uid)|\(s.at)" }

    static func sos(_ i: LivePresenterInput) -> SOSUIState {
        guard let v = i.view else { return SOSUIState() }
        var mine: MySOSUI = .none
        if i.sosSending { mine = .sending }
        else if let s = v.me?.sos { mine = .active(since: deviceDate(s.at, view: v) ?? i.now) }
        let colors = v.colors
        var incoming: [IncomingSOSUI] = []
        for m in v.orderedMembers where m.user_id != v.myId {
            guard let s = m.sos else { continue }
            /* Where to look: the SOS's own fix, else their last real fix — never a guess. */
            let target = s.fix.map { Geo.LatLng(lat: $0.lat, lng: $0.lng) } ?? position(of: m.user_id, in: v, myFix: i.myFix)
            var dist: Double?
            var bearing: Double?
            if let a = i.myFix?.coordinate, let b = target {
                dist = Geo.haversineMeters(a, b)
                bearing = relative(Geo.bearingDeg(a, b), mapBearing: i.mapBearing)
            }
            incoming.append(IncomingSOSUI(
                id: sosKey(m.user_id, s), participantId: m.user_id, name: m.display_name,
                color: colors[m.user_id] ?? 0xFFFFFF, distanceMeters: dist, bearingDegrees: bearing,
                hasPhone: !(m.phone ?? "").isEmpty, since: deviceDate(s.at, view: v) ?? i.now,
                acknowledged: i.acknowledgedSOS.contains(sosKey(m.user_id, s))
            ))
        }
        incoming.sort { $0.since > $1.since }
        return SOSUIState(mine: mine, incoming: incoming)
    }

    // MARK: rally

    static func rally(_ i: LivePresenterInput) -> RallyPointUI? {
        guard let v = i.view, let r = v.snapshot.outing.rally else { return nil }
        let p = Geo.LatLng(lat: r.lat, lng: r.lng)
        var dist: Double?
        var bearing: Double?
        if let a = i.myFix?.coordinate {
            dist = Geo.haversineMeters(a, p)
            bearing = relative(Geo.bearingDeg(a, p), mapBearing: i.mapBearing)
        }
        var arrived = 0
        for m in v.members.values {
            let isMe = m.user_id == v.myId
            let live: Bool
            if isMe { live = i.isSharingNow } else { live = v.freshness(of: m.user_id, deviceNow: i.now) == .live }
            guard live, let at = position(of: m.user_id, in: v, myFix: i.myFix) else { continue }
            if Geo.haversineMeters(at, p) <= arrivedRadiusM { arrived += 1 }
        }
        return RallyPointUI(distanceMeters: dist, bearingDegrees: bearing, arrivedCount: arrived, totalCount: v.members.count, label: r.label)
    }

    // MARK: map

    /// Cars for the map. My own car comes from my own GPS (it is mine to see,
    /// shared or not); everyone else's from their last real fix. Freshness is
    /// decided by Policy on the server's clock — an old fix is never live.
    static func mapMembers(_ i: LivePresenterInput, hideNotes: Bool) -> [MapMember] {
        guard let v = i.view else { return [] }
        let colors = v.colors
        var out: [MapMember] = []
        for m in v.orderedMembers {
            let isMe = m.user_id == v.myId
            let note = hideNotes ? nil : activeNote(m.note, view: v, now: i.now)
            if isMe {
                guard let f = i.myFix else { continue }
                let age = i.now.timeIntervalSince1970 * 1000 - f.atMs
                let fr: Policy.Freshness = i.gpsState == .denied ? .lost : Policy.freshness(fixAgeMs: max(0, age), speedMps: f.speed, lastSeenAgeMs: 0)
                out.append(MapMember(id: m.user_id, position: LngLat(lng: f.lng, lat: f.lat), color: colors[m.user_id] ?? 0xFFFFFF, name: m.display_name,
                                     presence: fr, heading: fr == .live ? Policy.trustedHeading(f.heading, speed: f.speed) : nil,
                                     accuracyM: f.accuracy, speedMps: f.speed, atMs: f.atMs, note: note, isMe: true))
                continue
            }
            guard let p = v.positions[m.user_id], let fr = v.freshness(of: m.user_id, deviceNow: i.now) else { continue }
            let at = (ISODate.parse(p.recorded_at)?.timeIntervalSince1970 ?? 0) * 1000
            out.append(MapMember(id: m.user_id, position: LngLat(lng: p.lng, lat: p.lat), color: colors[m.user_id] ?? 0xFFFFFF, name: m.display_name,
                                 presence: fr, heading: fr == .live ? Policy.trustedHeading(p.heading, speed: p.speed) : nil,
                                 accuracyM: p.accuracy, speedMps: p.speed, atMs: at, note: note, isMe: false, viaNearby: i.nearbyVia.contains(m.user_id)))
        }
        return out
    }

    static func localPhone(_ e164: String) -> String {
        e164.hasPrefix("+966") ? "0" + e164.dropFirst(4) : e164
    }
}

extension OutingSession {
    /// Battery percent when iOS can tell (nil on the simulator).
    nonisolated static func batteryNowIfAvailable() -> Int? {
        let level = MainActor.assumeIsolated { UIDevice.current.batteryLevel }
        return level >= 0 ? Int((Double(level) * 100).rounded()) : nil
    }
}

// MARK: - Edge arrows

/// Where to put a small arrow chip for a friend who is off the visible map —
/// a port of the web's `edgeArrows.ts`, plus keep-out rectangles so a chip
/// never sits under the control cluster, the SOS dock, the status capsule or «أنت».
enum EdgeArrows {
    struct Spot: Equatable {
        var id: String
        /// Chip centre, screen points.
        var center: CGPoint
        /// Direction to the member, degrees clockwise from screen-up.
        var angle: Double
        var edge: Edge
    }

    enum Edge: Equatable { case top, right, bottom, left }

    static let margin: CGFloat = 6

    static func screenAngle(dx: CGFloat, dy: CGFloat) -> Double {
        (atan2(Double(dx), Double(-dy)) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    /// nil when the point is inside the clear area (its car is visible).
    static func spot(id: String, point p: CGPoint, area r: CGRect, chip: CGSize) -> Spot? {
        guard p.x.isFinite, p.y.isFinite, r.width > 1, r.height > 1 else { return nil }
        if r.contains(p) { return nil }
        let c = CGPoint(x: r.midX, y: r.midY)
        let dx = p.x - c.x, dy = p.y - c.y
        let hx = max(0, r.width / 2 - chip.width / 2 - margin)
        let hy = max(0, r.height / 2 - chip.height / 2 - margin)
        let tx = dx == 0 ? CGFloat.infinity : hx / abs(dx)
        let ty = dy == 0 ? CGFloat.infinity : hy / abs(dy)
        let t = min(tx, ty)
        let edge: Edge = tx <= ty ? (dx > 0 ? .right : .left) : (dy > 0 ? .bottom : .top)
        return Spot(id: id, center: CGPoint(x: c.x + dx * t, y: c.y + dy * t), angle: screenAngle(dx: dx, dy: dy), edge: edge)
    }

    /// All chips: placed on the edge, slid clear of keep-out rects, spread so
    /// none covers another.
    static func place(points: [(id: String, point: CGPoint)], area r: CGRect, chip: CGSize, avoid: [CGRect], gap: CGFloat = 4) -> [Spot] {
        var spots = points.compactMap { spot(id: $0.id, point: $0.point, area: r, chip: chip) }
        for idx in spots.indices { spots[idx] = slide(spots[idx], area: r, chip: chip, avoid: avoid) }
        /* Spread along each edge. */
        for edge in [Edge.top, .right, .bottom, .left] {
            let vertical = edge == .left || edge == .right
            let step = (vertical ? chip.height : chip.width) + gap
            let ids = spots.indices.filter { spots[$0].edge == edge }
                .sorted { vertical ? spots[$0].center.y < spots[$1].center.y : spots[$0].center.x < spots[$1].center.x }
            guard ids.count > 1 else { continue }
            for k in 1..<ids.count {
                let prev = spots[ids[k - 1]].center, cur = spots[ids[k]].center
                if vertical, cur.y < prev.y + step { spots[ids[k]].center.y = prev.y + step }
                if !vertical, cur.x < prev.x + step { spots[ids[k]].center.x = prev.x + step }
            }
            /* Overflowed the end: push the run back inside. */
            let hi = (vertical ? r.maxY - chip.height / 2 : r.maxX - chip.width / 2) - margin
            if let last = ids.last {
                let over = (vertical ? spots[last].center.y : spots[last].center.x) - hi
                if over > 0 { for k in ids { if vertical { spots[k].center.y -= over } else { spots[k].center.x -= over } } }
            }
            for k in ids { spots[k] = slide(spots[k], area: r, chip: chip, avoid: avoid) }
        }
        return spots
    }

    /// Move a chip along its edge (both ways, nearest first) until it touches no keep-out rect.
    static func slide(_ s: Spot, area r: CGRect, chip: CGSize, avoid: [CGRect]) -> Spot {
        func rect(_ c: CGPoint) -> CGRect { CGRect(x: c.x - chip.width / 2, y: c.y - chip.height / 2, width: chip.width, height: chip.height) }
        func clear(_ c: CGPoint) -> Bool { !avoid.contains { $0.insetBy(dx: -2, dy: -2).intersects(rect(c)) } }
        if clear(s.center) { return s }
        let vertical = s.edge == .left || s.edge == .right
        let lo = (vertical ? r.minY + chip.height / 2 : r.minX + chip.width / 2) + margin
        let hi = (vertical ? r.maxY - chip.height / 2 : r.maxX - chip.width / 2) - margin
        let start = vertical ? s.center.y : s.center.x
        var d: CGFloat = 4
        while d < max(r.width, r.height) {
            for v in [start - d, start + d] where v >= lo && v <= hi {
                var c = s.center
                if vertical { c.y = v } else { c.x = v }
                if clear(c) { var o = s; o.center = c; return o }
            }
            d += 4
        }
        return s
    }
}
