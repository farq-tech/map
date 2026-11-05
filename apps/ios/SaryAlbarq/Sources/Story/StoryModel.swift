import Foundation

// «قصة الطلعة»: a shareable image (9:16 or square) or a short video of my trail,
// built ON THIS DEVICE from what the phone already has (my own trail, the outing
// totals, photos I pick). Nothing here is uploaded: the share sheet is the only
// way out, and only when I press it.

/// One point of my trail as the story sees it (my on-device trail, nothing else).
struct StoryPoint: Equatable {
    var lat: Double
    var lng: Double
    /// Device time, ms since 1970.
    var t: Double
    /// The stretch from the previous point was not recorded (drawn dashed, never as a known path).
    var gap = false

    var position: LngLat { LngLat(lng: lng, lat: lat) }
}

/// A shared waypoint (camp, water, danger…) — icon only on the story, never its title.
struct StoryWaypoint: Equatable {
    var kind: String
    var lat: Double
    var lng: Double

    var position: LngLat { LngLat(lng: lng, lat: lat) }

    /// SF Symbol for the kind (same kinds as `outing_waypoints.kind`).
    var symbol: String {
        switch kind {
        case "camp": return "tent.fill"
        case "water": return "drop.fill"
        case "danger": return "exclamationmark.triangle.fill"
        case "passable": return "checkmark.seal.fill"
        case "stuck_spot": return "exclamationmark.octagon.fill"
        default: return "mappin"
        }
    }
}

/// Where we stayed put the longest.
struct StoryStop: Equatable {
    var lat: Double
    var lng: Double
    var startMs: Double
    var durationS: Double

    var position: LngLat { LngLat(lng: lng, lat: lat) }
}

/// What the story says. Built from the trip summary (server snapshot + this device).
struct StoryFacts: Equatable {
    var outingName: String
    var startedAt: Date?
    var endedAt: Date?
    var distanceM: Double?
    var durationS: Int?
    var movingS: Int?
    /// Everyone in the outing, me included.
    var memberCount: Int
    /// The OTHER members' names (shown only when the person turns «أظهر أسماء الرفاق» on).
    var companionNames: [String]
    var trail: [StoryPoint]
    var waypoints: [StoryWaypoint] = []

    /// Longest stop from my trail (nil when there is no trail or no stop ≥ 3 min).
    var longestStop: StoryStop? { StoryStops.longest(trail) }

    /// The photo window: only pictures taken between these may go on the story.
    var photoWindow: ClosedRange<Date>? {
        let a = startedAt ?? trail.first.map { Date(timeIntervalSince1970: $0.t / 1000) }
        let b = endedAt ?? trail.last.map { Date(timeIntervalSince1970: $0.t / 1000) }
        guard let a, let b, b >= a else { return nil }
        /* A little slack either side: the camera clock and the outing clock are not the same clock. */
        return a.addingTimeInterval(-30 * 60)...b.addingTimeInterval(30 * 60)
    }
}

enum StoryFormat: String, CaseIterable, Identifiable {
    /// 1080×1920: Instagram / Snapchat stories, WhatsApp status.
    case vertical
    /// 1080×1080: a post or a chat.
    case square

    var id: String { rawValue }

    var pixelSize: CGSize {
        switch self {
        case .vertical: return CGSize(width: 1080, height: 1920)
        case .square: return CGSize(width: 1080, height: 1080)
        }
    }

    var label: String {
        switch self {
        case .vertical: return "قصة ٩:١٦"
        case .square: return "مربع"
        }
    }
}

/// The person's choices. Both privacy switches are OFF by default.
struct StoryOptions: Equatable {
    /// «أظهر نقطة البداية»: off = the first and last ~500 m are cut off the trail.
    var showStartEnd = false
    /// «أظهر أسماء الرفاق»: off = «مع ٥ رفاق», never names.
    var showNames = false
    var format: StoryFormat = .vertical
}

// MARK: - longest stop

enum StoryStops {
    /// Still = every fix within this radius of where the stop began.
    static let radiusM = 80.0
    /// Shorter than this is a pause, not a stop.
    static let minS = 180.0

    /// The longest time spent within `radiusM` of one place. A stretch that was
    /// not recorded (a gap) never counts: we do not know we were still.
    static func longest(_ pts: [StoryPoint], radiusM: Double = radiusM, minS: Double = minS) -> StoryStop? {
        guard pts.count >= 2 else { return nil }
        var best: StoryStop?
        var i = 0
        while i < pts.count - 1 {
            let anchor = pts[i].position
            var j = i
            /* Extend while the next point is still near the anchor and was recorded. */
            while j + 1 < pts.count, !pts[j + 1].gap, Vehicle.distanceMeters(anchor, pts[j + 1].position) <= radiusM { j += 1 }
            /* We left at the first point outside (if that step was recorded): the stop lasted until then. */
            let leftAt = (j + 1 < pts.count && !pts[j + 1].gap) ? pts[j + 1].t : pts[j].t
            let dur = (leftAt - pts[i].t) / 1000
            if dur >= minS, dur > (best?.durationS ?? 0) {
                best = StoryStop(lat: pts[i].lat, lng: pts[i].lng, startMs: pts[i].t, durationS: dur)
            }
            i = max(i + 1, j)
        }
        return best
    }
}

// MARK: - the trail on this device

/// Reads my on-device trail for an outing («مساري»: one JSON file per outing in
/// Application Support/trails-v1, written by the live session). Read-only: the
/// story never writes, moves or sends it.
///
/// It decodes the stored file itself (points `a` lat, `o` lng, `t` ms, `g` gap) so the
/// story does not depend on the recorder's in-memory types.
enum StoryTrailSource {
    static var directory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("trails-v1", isDirectory: true)
    }

    static func fileName(_ outingId: String) -> String {
        outingId.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") } + ".json"
    }

    static func load(_ outingId: String, in dir: URL? = directory) -> [StoryPoint] {
        guard let dir, let d = try? Data(contentsOf: dir.appendingPathComponent(fileName(outingId))) else { return [] }
        return decode(d)
    }

    static func decode(_ data: Data) -> [StoryPoint] {
        struct P: Decodable { var a: Double; var o: Double; var t: Double; var g: Bool? }
        struct F: Decodable { var points: [P] }
        guard let f = try? JSONDecoder().decode(F.self, from: data) else { return [] }
        return f.points.filter { $0.a.isFinite && $0.o.isFinite && abs($0.a) <= 90 && abs($0.o) <= 180 }
            .map { StoryPoint(lat: $0.a, lng: $0.o, t: $0.t, gap: $0.g ?? false) }
    }
}
