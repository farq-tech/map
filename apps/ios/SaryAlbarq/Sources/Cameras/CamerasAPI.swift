import Foundation

/// Thin client for `/api/cameras`. Reads are public (no token); a report may
/// carry the device's Bearer token so the server can dedupe by user, but it is
/// never required — an anonymous driver can still say «كاميرا هنا».
enum CamerasAPI {
    struct Report: Decodable {
        struct R: Decodable { var id: String; var status: String }
        var ok: Bool
        var report: R?
        var camera_id: String?
        var promoted: Bool?
    }

    private struct CamerasBox: Decodable { var cameras: [SpeedCamera] }

    /// Cameras inside a `[west, south, east, north]` box for the layer.
    static func fetch(bbox: [Double], base: URL = Endpoints.apiBase, session: URLSession = .shared) async throws -> [SpeedCamera] {
        var c = URLComponents(url: base.appendingPathComponent("api/cameras"), resolvingAgainstBaseURL: false)!
        c.queryItems = [.init(name: "bbox", value: bbox.map { String($0) }.joined(separator: ","))]
        var req = URLRequest(url: c.url!, timeoutInterval: 12)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data, resp: URLResponse
        do { (data, resp) = try await session.data(for: req) } catch { throw OutingAPIError(code: "network", status: 0) }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw OutingAPIError(code: "http_\(status)", status: status) }
        return try JSONDecoder().decode(CamerasBox.self, from: data).cameras
    }

    /// A driver's «كاميرا هنا». `clientId` makes a retried tap idempotent; `token`
    /// ties it to the user server-side for dedupe (never sent on the public layer).
    @discardableResult
    static func report(lat: Double, lon: Double, kind: CameraKind, clientId: String?, token: String?,
                       base: URL = Endpoints.apiBase, session: URLSession = .shared) async throws -> Report {
        let url = base.appendingPathComponent("api/cameras/report")
        var req = URLRequest(url: url, timeoutInterval: 12)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        var body: [String: Any] = ["lat": lat, "lon": lon, "kind": kind.rawValue]
        if let clientId { body["client_id"] = clientId }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data, resp: URLResponse
        do { (data, resp) = try await session.data(for: req) } catch { throw OutingAPIError(code: "network", status: 0) }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(status), obj?["ok"] as? Bool != false else {
            throw OutingAPIError(code: obj?["error"] as? String ?? "http_\(status)", status: status)
        }
        return try JSONDecoder().decode(Report.self, from: data)
    }

    /// A stable per-device id for idempotent reports (not an identity).
    static var deviceClientId: String {
        let key = "sary.cameras.deviceId"
        if let v = UserDefaults.standard.string(forKey: key) { return v }
        let v = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(32).description
        UserDefaults.standard.set(v, forKey: key)
        return v
    }
}
