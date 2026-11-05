import ActivityKit
import Foundation

/// The Live Activity of an open outing (Lock Screen + Dynamic Island).
/// Compiled into both the app and the widget extension. Only this small,
/// already-decided picture crosses to the widget: no coordinates, no ids of
/// other people, nothing a member did not already show the outing.
struct OutingActivityAttributes: ActivityAttributes {
    typealias ContentState = OutingActivityState

    /// Opens the outing when the activity is tapped (`saryalbarq://outing/<id>`).
    var outingId: String
    var outingName: String
}

/// What the activity shows right now. Decided in the app (`OutingActivityBuilder`);
/// the widget only lays it out (`OutingActivityDisplay`).
struct OutingActivityState: Codable, Hashable {
    /// The most urgent thing in the outing, if any. Shown red and first.
    struct Alert: Codable, Hashable {
        enum Kind: String, Codable, Hashable { case sos, stuck }
        var kind: Kind
        /// Who raised it; empty when it is me.
        var name: String
        var isMe: Bool
        var since: Date
        /// Other alerts behind this one («+٢»).
        var more: Int = 0
    }

    /// Members with a live position (me included when I am sharing now).
    var liveCount: Int
    var memberCount: Int
    /// The farthest member whose position is live — never a stale one.
    var farthestName: String?
    var farthestMeters: Double?
    /// Along my trail back to its start, when back-track data exists.
    var backMeters: Double?
    var alert: Alert?
    /// My own GPS gives a usable fix.
    var gpsOK: Bool
    /// The live link to the server is up (socket or polling).
    var online: Bool
    /// When the app decided this picture. The widget ages it from here.
    var updatedAt: Date
    /// My current speed in whole km/h («سرعة المركبة»); nil shows «—» (no fresh fix / speed).
    var speedKmh: Int? = nil
}

extension OutingActivityState {
    /// Older than this and the picture is shown as old, with its age.
    static let staleAfter: TimeInterval = 120

    /// Where to send a tap on the activity.
    static func url(outingId: String) -> URL {
        var c = URLComponents()
        c.scheme = "saryalbarq"
        c.host = "outing"
        c.path = "/" + outingId
        return c.url ?? URL(string: "saryalbarq://outing")!
    }

    /// The outing id from a URL the activity opened, or nil.
    static func outingId(from url: URL) -> String? {
        guard url.scheme == "saryalbarq", url.host == "outing" else { return nil }
        let id = url.pathComponents.dropFirst().first ?? ""
        let ok = !id.isEmpty && id.count <= 64 && id.unicodeScalars.allSatisfy { c in
            (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || (c >= "0" && c <= "9") || c == "-"
        }
        return ok ? id : nil
    }
}
