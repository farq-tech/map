import Foundation

/// What waypoints and convoy mode need from the server (contract §3, §4).
/// The real client is `OutingsAPI`; tests and the `-demo` build use fakes.
protocol OutingFeaturesBackend: AnyObject {
    func waypoints(_ outingId: String) async throws -> [Waypoint]
    func addWaypoint(_ outingId: String, _ draft: WaypointDraft) async throws -> Waypoint
    func deleteWaypoint(_ outingId: String, id: String) async throws
    func setConvoy(_ outingId: String, _ convoy: ConvoyInfo) async throws -> ConvoyInfo?
}

/// The server may not have these routes yet (they ship on their own branch):
/// Express answers an unknown route with a bare 404 page (no JSON error code), a proxy with 405.
enum FeatureAvailability {
    static func notDeployed(_ e: Error) -> Bool {
        guard let e = e as? OutingAPIError else { return false }
        return e.status == 405 || (e.status == 404 && (e.code.hasPrefix("http_") || e.code == "not_found"))
    }

    static let notDeployedText = "غير متاح بعد · الخادم لم يُحدَّث لهذه الميزة"

    /// A sentence for the person; the shared table plus this feature's own codes.
    static func arabic(_ e: Error) -> String {
        if notDeployed(e) { return notDeployedText }
        guard let e = e as? OutingAPIError else { return OutingAPIError(code: "network", status: 0).arabic }
        switch e.code {
        case "invalid_waypoint", "invalid_title": return "تأكد من اسم النقطة ونوعها."
        case "invalid_photo", "too_large": return "الصورة كبيرة أو بصيغة غير مدعومة. جرّب صورة ثانية."
        case "waypoint_not_found": return "هذه النقطة حُذفت."
        case "forbidden", "not_allowed": return "يحذف النقطة من أضافها أو أمير الطلعة فقط."
        case "invalid_convoy": return "تأكد من اختيار المقدمة والمؤخرة والمسافة."
        default: return e.arabic
        }
    }
}

extension OutingsAPI: OutingFeaturesBackend {
    struct WaypointsBox: Decodable { var waypoints: [Waypoint] }
    struct WaypointBox: Decodable { var waypoint: Waypoint }
    struct ConvoyBox: Decodable { var convoy: ConvoyInfo? }

    func waypoints(_ outingId: String) async throws -> [Waypoint] {
        let r: WaypointsBox = try await call("GET", "/\(outingId)/waypoints")
        return r.waypoints
    }

    func addWaypoint(_ outingId: String, _ draft: WaypointDraft) async throws -> Waypoint {
        /* A photo is up to 150 KB of text: give the upload time on a weak signal. */
        let r: WaypointBox = try await call("POST", "/\(outingId)/waypoints", body: draft, timeout: draft.photo == nil ? 12 : 30)
        return r.waypoint
    }

    func deleteWaypoint(_ outingId: String, id: String) async throws {
        let _: OkBox = try await call("DELETE", "/\(outingId)/waypoints/\(id)")
    }

    func setConvoy(_ outingId: String, _ convoy: ConvoyInfo) async throws -> ConvoyInfo? {
        let r: ConvoyBox = try await call("PATCH", "/\(outingId)/convoy", body: convoy)
        return r.convoy
    }
}

/// The `-demo` build's server: in memory, never on the network. `-demoFeaturesMissing`
/// makes it answer like a server without these routes, to show «غير متاح بعد».
final class DemoFeaturesBackend: OutingFeaturesBackend {
    var store: [String: [Waypoint]]
    var notDeployed: Bool
    let myId: String

    init(myId: String, seed: [String: [Waypoint]] = [:], notDeployed: Bool = false) {
        self.myId = myId
        store = seed
        self.notDeployed = notDeployed
    }

    private func gate() throws {
        if notDeployed { throw OutingAPIError(code: "http_404", status: 404) }
    }

    func waypoints(_ outingId: String) async throws -> [Waypoint] {
        try gate()
        return store[outingId] ?? []
    }

    func addWaypoint(_ outingId: String, _ d: WaypointDraft) async throws -> Waypoint {
        try gate()
        let w = Waypoint(id: UUID().uuidString.lowercased(), outing_id: outingId, user_id: myId, kind: d.kind, title: d.title, note: d.note,
                         lat: d.lat, lng: d.lng, photo: d.photo, created_at: ISODate.string(Date()), display_name: nil)
        store[outingId, default: []].append(w)
        return w
    }

    func deleteWaypoint(_ outingId: String, id: String) async throws {
        try gate()
        store[outingId]?.removeAll { $0.id == id }
    }

    func setConvoy(_ outingId: String, _ convoy: ConvoyInfo) async throws -> ConvoyInfo? {
        try gate()
        return convoy.isOn ? ConvoyInfo(lead_user_id: convoy.lead_user_id, tail_user_id: convoy.tail_user_id, max_gap_m: convoy.gapM) : nil
    }
}
