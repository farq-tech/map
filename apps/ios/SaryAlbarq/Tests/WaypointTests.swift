import UIKit
import XCTest
@testable import SaryAlbarq

/// Shared waypoints: the server's rules, photo compression, the wire format and the cache.
final class WaypointTests: XCTestCase {
    private func draft(title: String = "مخيم", note: String? = nil, lat: Double = 24.71, lng: Double = 46.67, photo: String? = nil) -> WaypointDraft {
        WaypointDraft(kind: .camp, title: title, note: note, lat: lat, lng: lng, photo: photo)
    }

    func testTitleIsCleanedAndCappedAndRequired() throws {
        guard case let .success(d) = WaypointRules.validate(draft(title: "  مخيم\u{202E}   الشباب  ")) else { return XCTFail() }
        XCTAssertEqual(d.title, "مخيم الشباب", "bidi override dropped, spaces collapsed")
        guard case let .success(long) = WaypointRules.validate(draft(title: String(repeating: "ب", count: 60))) else { return XCTFail() }
        XCTAssertEqual(long.title.count, WaypointRules.titleMax)
        XCTAssertEqual(WaypointRules.validate(draft(title: "   \n ")), .failure(.titleMissing))
    }

    func testNoteIsOptionalAndCappedAt140() throws {
        guard case let .success(a) = WaypointRules.validate(draft(note: "   ")) else { return XCTFail() }
        XCTAssertNil(a.note, "an empty note is not sent")
        guard case let .success(b) = WaypointRules.validate(draft(note: String(repeating: "ن", count: 300))) else { return XCTFail() }
        XCTAssertEqual(b.note?.count, WaypointRules.noteMax)
    }

    func testCoordinatesMustBeReal() {
        XCTAssertEqual(WaypointRules.validate(draft(lat: 91)), .failure(.coordinates))
        XCTAssertEqual(WaypointRules.validate(draft(lng: -181)), .failure(.coordinates))
        XCTAssertEqual(WaypointRules.validate(draft(lat: .nan)), .failure(.coordinates))
        XCTAssertEqual(WaypointRules.validate(draft(lat: 0, lng: 0)), .failure(.coordinates), "null island is a missing fix, not a place")
    }

    func testPhotoMustBeJpegDataURLWithinLimit() {
        XCTAssertEqual(WaypointRules.validate(draft(photo: "data:image/png;base64,AAAA")), .failure(.photoNotJpeg))
        let big = WaypointRules.photoPrefix + String(repeating: "A", count: WaypointRules.photoMaxBytes)
        XCTAssertEqual(WaypointRules.validate(draft(photo: big)), .failure(.photoTooLarge))
        let ok = WaypointRules.photoPrefix + String(repeating: "A", count: 1000)
        guard case .success = WaypointRules.validate(draft(photo: ok)) else { return XCTFail() }
    }

    /// A noisy 4000×3000 photo (worst case for JPEG) still fits, as a valid JPEG, with no metadata.
    func testCompressionFitsTheServerLimit() throws {
        let size = CGSize(width: 4000, height: 3000)
        let f = UIGraphicsImageRendererFormat()
        f.scale = 1
        var rng = SystemRandomNumberGenerator()
        let img = UIGraphicsImageRenderer(size: size, format: f).image { ctx in
            for _ in 0..<6000 {
                UIColor(red: .random(in: 0...1, using: &rng), green: .random(in: 0...1, using: &rng), blue: .random(in: 0...1, using: &rng), alpha: 1).setFill()
                ctx.fill(CGRect(x: .random(in: 0...size.width, using: &rng), y: .random(in: 0...size.height, using: &rng), width: 40, height: 40))
            }
        }
        let url = try XCTUnwrap(WaypointPhoto.dataURL(from: img))
        XCTAssertTrue(url.hasPrefix("data:image/jpeg;base64,"))
        XCTAssertLessThanOrEqual(url.utf8.count, WaypointRules.photoMaxBytes)
        XCTAssertLessThanOrEqual(url.utf8.count, 150 * 1000, "fits either reading of 150 KB")
        let back = try XCTUnwrap(WaypointPhoto.image(fromDataURL: url))
        XCTAssertLessThanOrEqual(max(back.size.width, back.size.height), 1280)
        XCTAssertEqual(back.size.width / back.size.height, 4.0 / 3.0, accuracy: 0.01, "aspect kept")
        guard case .success = WaypointRules.validate(draft(photo: url)) else { return XCTFail("the app's own photo passes its own rules") }
        /* Re-drawn: no EXIF / GPS from the camera goes to the server. */
        let data = try XCTUnwrap(Data(base64Encoded: String(url.dropFirst(WaypointRules.photoPrefix.count))))
        let src = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        XCTAssertNil(props?[kCGImagePropertyGPSDictionary], "no location inside the photo")
    }

    func testSmallPhotoKeepsItsSize() throws {
        let img = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 200)).image { c in UIColor.orange.setFill(); c.fill(CGRect(x: 0, y: 0, width: 300, height: 200)) }
        let back = try XCTUnwrap(WaypointPhoto.image(fromDataURL: WaypointPhoto.dataURL(from: img)))
        XCTAssertEqual(back.size.width, 300, accuracy: 1, "a small photo is not upscaled")
    }

    func testWireFormatAndUnknownKind() throws {
        let json = """
        {"id":"w1","outing_id":"o","user_id":"u","kind":"oasis","title":"واحة","note":null,"lat":24.7,"lng":46.6,"photo":null,"created_at":"2026-11-04T10:00:00.000Z"}
        """
        let w = try JSONDecoder().decode(Waypoint.self, from: Data(json.utf8))
        XCTAssertEqual(w.kind, .other, "a kind this app does not know is shown as «أخرى», not dropped")
        let body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(draft(note: "x"))) as? [String: Any]
        XCTAssertEqual(Set(body?.keys.map { $0 } ?? []), ["kind", "title", "note", "lat", "lng"], "nil photo is not sent")
        XCTAssertEqual(body?["kind"] as? String, "camp")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: JSONEncoder().encode(WaypointKind.stuck_spot), options: .fragmentsAllowed) as? String, "stuck_spot")
    }

    func testEveryKindHasArabicLabelAndARealSymbol() {
        XCTAssertEqual(WaypointKind.allCases.map(\.label), ["مخيم", "ماء", "خطر", "طريق سالك", "مكان تغريز", "أخرى"])
        for k in WaypointKind.allCases { XCTAssertNotNil(UIImage(systemName: k.symbol), "\(k): \(k.symbol)") }
    }

    func testDeleteIsForCreatorOrLeader() {
        let w = Waypoint(id: "w", outing_id: "o", user_id: "a", kind: .water, title: "بئر", note: nil, lat: 1, lng: 1, photo: nil, created_at: "")
        XCTAssertTrue(WaypointRules.canDelete(w, myId: "a", iLead: false))
        XCTAssertTrue(WaypointRules.canDelete(w, myId: "b", iLead: true))
        XCTAssertFalse(WaypointRules.canDelete(w, myId: "b", iLead: false))
    }

    func testCacheRoundTripListsPastOutingsAndWipes() throws {
        let saved = WaypointCache.directory
        WaypointCache.directory = FileManager.default.temporaryDirectory.appendingPathComponent("wp-test-\(UUID().uuidString)")
        defer { WaypointCache.wipeAll(); WaypointCache.directory = saved }
        let w = Waypoint(id: "w", outing_id: "o1", user_id: "a", kind: .camp, title: "مخيم", note: nil, lat: 24, lng: 46, photo: nil, created_at: "2026-11-01T00:00:00.000Z")
        WaypointCache.save("o1", name: "طلعة قديمة", [w], now: Date(timeIntervalSince1970: 100))
        WaypointCache.save("o2", name: "طلعة أحدث", [w], now: Date(timeIntervalSince1970: 200))
        WaypointCache.save("o3", name: "بلا نقاط", [], now: Date(timeIntervalSince1970: 300))
        XCTAssertEqual(WaypointCache.load("o1")?.waypoints, [w])
        XCTAssertEqual(WaypointCache.all().map(\.outing_id), ["o2", "o1"], "newest first; empty ones are not listed")
        let excluded = try WaypointCache.directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        XCTAssertEqual(excluded, true, "outing data stays off iCloud backups")
        WaypointCache.wipeAll()
        XCTAssertNil(WaypointCache.load("o1"))
        XCTAssertTrue(WaypointCache.all().isEmpty)
    }

    @MainActor func testAccountWipeRemovesTheCache() {
        let saved = WaypointCache.directory
        WaypointCache.directory = FileManager.default.temporaryDirectory.appendingPathComponent("wp-wipe-\(UUID().uuidString)")
        defer { WaypointCache.wipeAll(); WaypointCache.directory = saved }
        WaypointCache.save("o", name: "x", [Waypoint(id: "w", outing_id: "o", user_id: "a", kind: .camp, title: "t", note: nil, lat: 1, lng: 1, photo: nil, created_at: "")])
        let d = UserDefaults(suiteName: "wp-wipe-\(UUID().uuidString)")!
        LocalAccountData.wipe(defaults: d)
        XCTAssertNil(WaypointCache.load("o"), "«احذف حسابي» forgets the waypoints this device kept")
    }

    func testLiveEventsDecode() {
        let added = LiveEvent.decode(["type": "waypoint_added", "waypoint": ["id": "w", "user_id": "u", "kind": "water", "title": "بئر", "lat": 24.0, "lng": 46.0, "created_at": "2026-11-04T10:00:00.000Z"]])
        guard case let .waypointAdded(w)? = added else { return XCTFail("\(String(describing: added))") }
        XCTAssertEqual(w.kind, .water)
        XCTAssertEqual(LiveEvent.decode(["type": "waypoint_removed", "id": "w"]), .waypointRemoved(id: "w"))
    }
}

/// Layout of the pins next to the cars' chips.
final class WaypointLayoutTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 100, width: 400, height: 700)
    private let pin = CGSize(width: 34, height: 40)
    private let label = CGSize(width: 70, height: 18)

    func testPinStandsOnItsSpotWithItsTitleBelow() {
        let r = WaypointLayout.solve([.init(id: "a", anchor: CGPoint(x: 200, y: 400), pin: pin, label: label)], .init(bounds: bounds))
        XCTAssertEqual(r.pins.first?.frame.midX, 200)
        XCTAssertEqual(r.pins.first?.frame.maxY, 400, "the tip is the spot")
        XCTAssertEqual(r.pins.first?.labelFrame?.minY ?? 0, 403, accuracy: 0.1)
    }

    func testTouchingPinsFoldIntoACluster() {
        let items: [WaypointLayout.Item] = [
            .init(id: "a", anchor: CGPoint(x: 200, y: 400), pin: pin, label: label),
            .init(id: "b", anchor: CGPoint(x: 215, y: 405), pin: pin, label: label),
            .init(id: "c", anchor: CGPoint(x: 300, y: 600), pin: pin, label: label),
        ]
        let r = WaypointLayout.solve(items, .init(bounds: bounds))
        XCTAssertEqual(r.clusters.map(\.ids), [["a", "b"]])
        XCTAssertEqual(r.pins.map(\.id), ["c"])
        XCTAssertEqual(r.clusters[0].anchor.x, 207.5, accuracy: 0.01)
    }

    func testTitleGivesWayToCarChipsAndIsHiddenInDriveMode() {
        let it = WaypointLayout.Item(id: "a", anchor: CGPoint(x: 200, y: 400), pin: pin, label: label)
        let chip = CGRect(x: 180, y: 404, width: 90, height: 26)
        var o = WaypointLayout.Options(bounds: bounds, obstacles: [chip])
        XCTAssertNil(WaypointLayout.solve([it], o).pins[0].labelFrame, "a car's name chip wins")
        o.obstacles = []
        o.showLabels = false
        XCTAssertNil(WaypointLayout.solve([it], o).pins[0].labelFrame)
        XCTAssertEqual(WaypointLayout.solve([it], o).pins.count, 1, "the pin itself always shows")
    }

    func testOffscreenPinsAreNotDrawnAndOrderIsStable() {
        let items: [WaypointLayout.Item] = [
            .init(id: "z", anchor: CGPoint(x: 100, y: 300), pin: pin, label: nil),
            .init(id: "far", anchor: CGPoint(x: 2000, y: 300), pin: pin, label: nil),
            .init(id: "a", anchor: CGPoint(x: 300, y: 300), pin: pin, label: nil),
        ]
        let r1 = WaypointLayout.solve(items, .init(bounds: bounds))
        let r2 = WaypointLayout.solve(items.reversed(), .init(bounds: bounds))
        XCTAssertEqual(r1, r2)
        XCTAssertEqual(Set(r1.pins.map(\.id)), ["a", "z"])
        XCTAssertFalse(r1.pins.contains { $0.id == "far" })
    }
}
