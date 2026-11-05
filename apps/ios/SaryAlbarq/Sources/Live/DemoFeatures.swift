import Foundation

/// Waypoints and convoy mode for the `-demo` outing (screenshots, UI tests).
/// Clearly a demo, like `DemoData`; never talks to the server.
///   `-demoConvoy`            convoy on: «أبو فهد» leads, «سلطان» is the tail, «ماجد» has fallen behind.
///   `-demoFeaturesMissing`   the server answers like one without these routes («غير متاح بعد»).
///   `-demoNoWaypoints`       start with an empty list.
enum DemoFeatures {
    static let args = ProcessInfo.processInfo.arguments

    static let backend = DemoFeaturesBackend(
        myId: DemoData.currentMe,
        seed: args.contains("-demoNoWaypoints") ? [:] : seed(),
        notDeployed: args.contains("-demoFeaturesMissing")
    )

    static let abuFahd = "00000000-0000-4000-8000-000000000002"
    static let sultan = "00000000-0000-4000-8000-000000000003"
    static let majid = "00000000-0000-4000-8000-000000000020"

    static func seed(now: Date = Date()) -> [String: [Waypoint]] {
        func ago(_ s: Double) -> String { ISODate.string(now.addingTimeInterval(-s)) }
        func w(_ id: String, _ outing: String, _ user: String, _ kind: WaypointKind, _ title: String, _ note: String?, _ lat: Double, _ lng: Double, _ at: Double) -> Waypoint {
            Waypoint(id: id, outing_id: outing, user_id: user, kind: kind, title: title, note: note, lat: lat, lng: lng, photo: nil, created_at: ago(at), display_name: nil)
        }
        let o = DemoData.outingId
        return [
            o: [
                w("demo-wp-1", o, abuFahd, .camp, "مخيم الشباب", "ورا الطعس، أرض مستوية تكفي ٤ سيارات", 24.7141, 46.6727, 1500),
                w("demo-wp-2", o, sultan, .danger, "نزلة قوية", "انتبهوا، فيها حجر تحت الرمل", 24.7090, 46.6773, 1100),
                w("demo-wp-3", o, DemoData.meId, .stuck_spot, "رمل ناعم", "غرّزت هنا، نفّس كفراتك قبلها", 24.7101, 46.6721, 800),
                w("demo-wp-4", o, abuFahd, .passable, "طريق سالك", nil, 24.71335, 46.67628, 600),
                w("demo-wp-5", o, sultan, .water, "قليب", "ماء للغسيل فقط", 24.71348, 46.67645, 420),
            ],
            "demo-old": [
                w("demo-old-1", "demo-old", "00000000-0000-4000-8000-0000000002\(1)", .camp, "مخيم ليلة الخميس", "فيه ظل وقت العصر", 25.142, 45.212, 86400 * 3 + 10_000),
                w("demo-old-2", "demo-old", "00000000-0000-4000-8000-0000000002\(2)", .stuck_spot, "تغريز الجيب الأبيض", nil, 25.131, 45.236, 86400 * 3 + 7_000),
                w("demo-old-3", "demo-old", DemoData.meId, .passable, "مدخل النفود السالك", "من جهة الشرق أسهل", 25.118, 45.251, 86400 * 3 + 5_000),
            ],
        ]
    }

    /// `-demoConvoy`: convoy on, with one car behind the tail. Parked cars stay live
    /// for 45 s (Policy), long enough for a screenshot — and then honestly go stale.
    static func convoyView(_ base: OutingView, now: Date = Date()) -> OutingView {
        var v = base
        func ago(_ s: Double) -> String { ISODate.string(now.addingTimeInterval(-s)) }
        v.members[majid] = Member(user_id: majid, display_name: "ماجد", avatar: nil, phone: nil, role: "member", sharing: true, joined_at: "2026-11-03T10:09:00.000Z",
                                  online: true, away: false, last_seen_at: ago(1), gps: .ok, note: nil)
        v.positions[majid] = Position(user_id: majid, lat: 24.7013, lng: 46.6790, accuracy: 6, heading: nil, speed: 0, mode: .balanced, recorded_at: ago(1))
        if var lead = v.positions[abuFahd] {
            lead.speed = 0
            lead.heading = nil
            lead.recorded_at = ago(1)
            v.positions[abuFahd] = lead
        }
        /* The tail is «سلطان» (not this phone), so the demo never depends on the simulator's GPS. */
        if var tail = v.positions[sultan] {
            tail.lat = 24.7090
            tail.lng = 46.6758
            tail.speed = 0
            tail.heading = nil
            tail.recorded_at = ago(1)
            v.positions[sultan] = tail
            v.members[sultan]?.last_seen_at = ago(1)
        }
        v.snapshot.outing.convoy = ConvoyInfo(lead_user_id: abuFahd, tail_user_id: sultan, max_gap_m: 500)
        return v
    }
}
