import Foundation
import UIKit

// Shared waypoints («نقاط مشتركة») — contract §3. Wire types, the server's
// input rules mirrored, photo compression, and the offline-readable cache.

enum WaypointKind: String, Codable, CaseIterable, Identifiable {
    case camp, water, danger, passable, stuck_spot, other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .camp: return "مخيم"
        case .water: return "ماء"
        case .danger: return "خطر"
        case .passable: return "طريق سالك"
        case .stuck_spot: return "مكان تغريز"
        case .other: return "أخرى"
        }
    }

    /// SF Symbol for the kind (picker, map pin, list).
    var symbol: String {
        switch self {
        case .camp: return "tent.fill"
        case .water: return "drop.fill"
        case .danger: return "exclamationmark.triangle.fill"
        case .passable: return "road.lanes"
        case .stuck_spot: return "car.rear.and.tire.marks"
        case .other: return "mappin"
        }
    }

    /// A newer server may add kinds: show them as «أخرى» instead of dropping the point.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = WaypointKind(rawValue: raw) ?? .other
    }
}

/// One shared point, as `GET /:id/waypoints` returns it.
struct Waypoint: Codable, Equatable, Identifiable {
    var id: String
    var outing_id: String?
    /// The member who added it.
    var user_id: String
    var kind: WaypointKind
    var title: String
    var note: String?
    var lat: Double
    var lng: Double
    /// `data:image/jpeg;base64,…` (≤ 150 KB) or nil.
    var photo: String?
    var created_at: String
    /// The creator's name, if the server sends it (a member who left is no longer in the list).
    var display_name: String?

    var position: LngLat { LngLat(lng: lng, lat: lat) }
}

/// What the person filled in, before it goes to the server.
struct WaypointDraft: Equatable, Encodable {
    var kind: WaypointKind
    var title: String
    var note: String?
    var lat: Double
    var lng: Double
    var photo: String?
}

/// The server's rules for a waypoint (contract §3), mirrored so the app never sends what it would refuse.
enum WaypointRules {
    static let titleMax = 40
    static let noteMax = 140
    /// The whole data URL, in bytes. Stricter than either reading of "150 KB" (150 000 / 153 600).
    static let photoMaxBytes = 150_000
    static let photoPrefix = "data:image/jpeg;base64,"

    enum Problem: Error, Equatable {
        case titleMissing
        case coordinates
        case photoTooLarge
        case photoNotJpeg

        var arabic: String {
            switch self {
            case .titleMissing: return "اكتب اسمًا للنقطة."
            case .coordinates: return "مكان النقطة غير صحيح."
            case .photoTooLarge: return "الصورة أكبر من المسموح."
            case .photoNotJpeg: return "الصورة بصيغة غير مدعومة."
            }
        }
    }

    /// The draft as it will be sent (cleaned text, trimmed note), or why it cannot be.
    static func validate(_ d: WaypointDraft) -> Result<WaypointDraft, Problem> {
        guard let title = ServerRules.cleanText(d.title, max: titleMax) else { return .failure(.titleMissing) }
        guard d.lat.isFinite, d.lng.isFinite, (-90...90).contains(d.lat), (-180...180).contains(d.lng), !(d.lat == 0 && d.lng == 0) else {
            return .failure(.coordinates)
        }
        var out = d
        out.title = title
        out.note = d.note.flatMap { ServerRules.cleanText($0, max: noteMax) }
        if let p = d.photo {
            guard p.hasPrefix(photoPrefix) else { return .failure(.photoNotJpeg) }
            guard p.utf8.count <= photoMaxBytes else { return .failure(.photoTooLarge) }
        }
        return .success(out)
    }

    /// Creator, owner or «نائب الأمير» (the server checks too).
    static func canDelete(_ w: Waypoint, myId: String, iLead: Bool) -> Bool { w.user_id == myId || iLead }
}

/// Turns a photo into a JPEG data URL that fits the server's limit. Re-drawing
/// the image also drops its metadata (EXIF, including where it was taken).
enum WaypointPhoto {
    static let sides: [CGFloat] = [1280, 1024, 800, 640, 480, 360, 256]
    static let qualities: [CGFloat] = [0.7, 0.55, 0.42, 0.3]

    static func base64Length(_ bytes: Int) -> Int { 4 * ((bytes + 2) / 3) }

    static func dataURL(from image: UIImage, maxBytes: Int = WaypointRules.photoMaxBytes) -> String? {
        let budget = maxBytes - WaypointRules.photoPrefix.utf8.count
        guard image.size.width > 0, image.size.height > 0 else { return nil }
        for side in sides {
            let scaled = resized(image, maxSide: side)
            for q in qualities {
                guard let d = scaled.jpegData(compressionQuality: q) else { continue }
                if base64Length(d.count) <= budget { return WaypointRules.photoPrefix + d.base64EncodedString() }
            }
        }
        return nil
    }

    static func resized(_ image: UIImage, maxSide: CGFloat) -> UIImage {
        let s = image.size
        let k = min(1, maxSide / max(s.width, s.height))
        let size = CGSize(width: max(1, (s.width * k).rounded()), height: max(1, (s.height * k).rounded()))
        let f = UIGraphicsImageRendererFormat()
        f.scale = 1
        f.opaque = true
        return UIGraphicsImageRenderer(size: size, format: f).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    }

    /// Views call this from `body`, so every redraw used to base64-decode and JPEG-decode the
    /// photo again on the main thread. Decoded images are kept in a small bounded cache.
    static func image(fromDataURL s: String?) -> UIImage? {
        guard let s else { return nil }
        let key = s as NSString
        if let hit = decoded.object(forKey: key) { return hit }
        guard let comma = s.firstIndex(of: ","), let d = Data(base64Encoded: String(s[s.index(after: comma)...])),
              let img = UIImage(data: d) else { return nil }
        /* Decode once now, so drawing the cached image never decodes it again. */
        let ready = img.preparingForDisplay() ?? img
        decoded.setObject(ready, forKey: key, cost: Int(ready.size.width * ready.size.height * ready.scale * ready.scale) * 4)
        return ready
    }

    /// At most a handful of photos (≤1280 px each); NSCache also empties itself under memory pressure.
    private static let decoded: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 24
        c.totalCostLimit = 48 * 1024 * 1024
        return c
    }()
}

/// The last list each outing's waypoints were seen with, on this device — so they
/// still read with no network (in the desert) and after the outing ended.
/// Files in Application Support, excluded from backup; wiped on sign-out / account deletion.
enum WaypointCache {
    struct Entry: Codable, Equatable {
        var outing_id: String
        var outing_name: String
        var saved_at: String
        var waypoints: [Waypoint]
    }

    static var directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("waypoints", isDirectory: true)
    }()

    private static func file(_ outingId: String) -> URL {
        let safe = outingId.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return directory.appendingPathComponent("\(safe).json")
    }

    static func save(_ outingId: String, name: String, _ list: [Waypoint], now: Date = Date()) {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var dir = directory
        var rv = URLResourceValues()
        rv.isExcludedFromBackup = true
        try? dir.setResourceValues(rv)
        let e = Entry(outing_id: outingId, outing_name: name, saved_at: ISODate.string(now), waypoints: list)
        guard let d = try? JSONEncoder().encode(e) else { return }
        try? d.write(to: file(outingId), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func load(_ outingId: String) -> Entry? {
        guard let d = try? Data(contentsOf: file(outingId)) else { return nil }
        return try? JSONDecoder().decode(Entry.self, from: d)
    }

    /// Every outing with saved points, newest first («نقاط من طلعات سابقة»).
    static func all() -> [Entry] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls.compactMap { u in (try? Data(contentsOf: u)).flatMap { try? JSONDecoder().decode(Entry.self, from: $0) } }
            .filter { !$0.waypoints.isEmpty }
            .sorted { $0.saved_at > $1.saved_at }
    }

    static func forget(_ outingId: String) { try? FileManager.default.removeItem(at: file(outingId)) }

    static func wipeAll() { try? FileManager.default.removeItem(at: directory) }
}
