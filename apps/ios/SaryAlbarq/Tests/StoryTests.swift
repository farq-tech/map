import AVFoundation
import XCTest
@testable import SaryAlbarq

/// «قصة الطلعة»: privacy trimming, layout metrics, video frame timing, and real renders from fixtures.
final class StoryPrivacyTests: XCTestCase {
    /// A straight line north from (24.7, 46.6), one point every `stepM` metres.
    private func line(_ lengthM: Double, stepM: Double = 50, lat0: Double = 24.7, lng0: Double = 46.6) -> [StoryPoint] {
        let n = Int(lengthM / stepM)
        return (0...n).map { i in StoryPoint(lat: lat0 + Double(i) * stepM / 111_195, lng: lng0, t: Double(i) * 5000) }
    }

    func testDefaultHidesFirstAndLast500m() {
        let pts = line(5000)
        let r = StoryPrivacy.apply(pts, showStartEnd: false)
        XCTAssertEqual(r.runs.count, 1)
        let run = r.runs[0]
        XCTAssertTrue(run.fadeStart)
        XCTAssertTrue(run.fadeEnd)
        let start = pts.first!.position, end = pts.last!.position
        for p in run.points {
            XCTAssertGreaterThanOrEqual(Vehicle.distanceMeters(start, p.position), 499.9)
            XCTAssertGreaterThanOrEqual(Vehicle.distanceMeters(end, p.position), 499.9)
        }
        /* The line is clipped exactly at the zone edge, not at the next kept fix. */
        XCTAssertEqual(Vehicle.distanceMeters(start, run.points.first!.position), 500, accuracy: 1)
        XCTAssertEqual(Vehicle.distanceMeters(end, run.points.last!.position), 500, accuracy: 1)
    }

    func testShowStartKeepsEverything() {
        let pts = line(3000)
        let r = StoryPrivacy.apply(pts, showStartEnd: true)
        XCTAssertEqual(r.runs, [StoryPrivacy.Run(points: pts)])
        XCTAssertNil(r.startZone)
    }

    func testTrailThatComesBackHomeIsCutThereToo() {
        /* Out 3 km north, back to 200 m from home, then away east: the return near home is hidden. */
        var pts = line(3000)
        let back = line(2800).reversed().map { StoryPoint(lat: $0.lat, lng: $0.lng + 0.00001, t: 0) }
        pts += back.dropFirst()
        let last = pts.last!
        for i in 1...60 { pts.append(StoryPoint(lat: last.lat, lng: last.lng + Double(i) * 50 / 101_000, t: 0)) }
        for i in pts.indices { pts[i].t = Double(i) * 5000 }
        let r = StoryPrivacy.apply(pts, showStartEnd: false)
        let home = pts[0].position
        XCTAssertGreaterThanOrEqual(r.runs.count, 2, "the pass near home splits the trail")
        for run in r.runs { for p in run.points { XCTAssertGreaterThanOrEqual(Vehicle.distanceMeters(home, p.position), 499.9) } }
    }

    func testLongStraightStepThroughAZoneIsCut() {
        /* A gap step that jumps straight across the end zone (both ends outside it). */
        let a = StoryPoint(lat: 24.70, lng: 46.60, t: 0)
        let b = StoryPoint(lat: 24.73, lng: 46.60, t: 60_000)
        let c = StoryPoint(lat: 24.73, lng: 46.64, t: 120_000, gap: true)
        let d = StoryPoint(lat: 24.70, lng: 46.64, t: 180_000)
        /* End zone at d; the step b→c passes far from it; add a final hop so the step c→d ends in the zone. */
        let r = StoryPrivacy.apply([a, b, c, d], showStartEnd: false)
        for run in r.runs {
            for p in run.points {
                XCTAssertGreaterThanOrEqual(Vehicle.distanceMeters(a.position, p.position), 499.9)
                XCTAssertGreaterThanOrEqual(Vehicle.distanceMeters(d.position, p.position), 499.9)
            }
        }
        /* The unrecorded stretch stays marked as a gap (dashed). */
        XCTAssertTrue(r.runs.flatMap(\.points).contains { $0.gap })
    }

    func testShortTrailShowsNothing() {
        let r = StoryPrivacy.apply(line(900), showStartEnd: false)
        XCTAssertTrue(r.isEmpty)
        XCTAssertNil(StoryRenderer.camera(StoryFacts(outingName: "x", memberCount: 1, companionNames: [], trail: line(900)), StoryOptions(), photoCount: 0),
                     "no map is framed around a hidden start")
    }

    func testWaypointsAndStopInsideZonesAreHidden() {
        let facts = StoryFixtures.facts()
        let r = StoryPrivacy.apply(facts.trail, showStartEnd: false)
        let water = facts.waypoints.first { $0.kind == "water" }!
        XCTAssertFalse(StoryPrivacy.isVisible(water.position, in: r))
        let camp = facts.waypoints.first { $0.kind == "camp" }!
        XCTAssertTrue(StoryPrivacy.isVisible(camp.position, in: r))
        let scene = StoryRenderer.scene(facts, StoryOptions(), photos: [], mapImage: nil, mark: nil)
        XCTAssertFalse(scene.waypoints.contains { $0.wp.kind == "water" })
        XCTAssertNil(scene.start)
        XCTAssertNil(scene.end)
        let open = StoryRenderer.scene(facts, StoryOptions(showStartEnd: true), photos: [], mapImage: nil, mark: nil)
        XCTAssertNotNil(open.start)
        XCTAssertTrue(open.waypoints.contains { $0.wp.kind == "water" })
    }

    func testFramingNeverIncludesHiddenEnds() {
        let facts = StoryFixtures.facts()
        let opts = StoryOptions()
        let cam = StoryRenderer.camera(facts, opts, photoCount: 0)!
        let layout = StoryLayout.make(.vertical, photoCount: 0)
        let frame = layout.trailFrame.insetBy(dx: -2, dy: -2)
        for p in StoryPrivacy.apply(facts.trail, showStartEnd: false).visiblePoints {
            XCTAssertTrue(frame.contains(cam.pixel(p)), "visible trail fits the frame")
        }
    }

    func testNamesHiddenByDefault() {
        var f = StoryFixtures.facts()
        XCTAssertEqual(StoryRenderer.companionsLine(f, show: false), "مع ٥ من الأصدقاء")
        XCTAssertFalse(StoryRenderer.companionsLine(f, show: false).contains("سلطان"))
        XCTAssertEqual(StoryRenderer.companionsLine(f, show: true), "مع أبو فهد، سلطان، نورة واثنين آخرين")
        f.companionNames = ["سلطان", "نورة"]
        XCTAssertEqual(StoryRenderer.companionsLine(f, show: true), "مع سلطان ونورة")
        f.memberCount = 2
        XCTAssertEqual(StoryRenderer.companionsLine(f, show: false), "مع واحد من الأصدقاء")
        f.memberCount = 1
        XCTAssertEqual(StoryRenderer.companionsLine(f, show: false), "طلعة فردية")
        f.memberCount = 14
        XCTAssertEqual(StoryRenderer.companionsLine(f, show: false), "مع ١٣ من الأصدقاء")
    }

    func testTrailFileDecoding() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let json = #"{"points":[{"a":24.7,"o":46.6,"t":1000},{"a":24.71,"o":46.61,"t":2000,"g":true}],"gapNext":false,"pending":[],"simplifiedUpTo":0}"#
        try Data(json.utf8).write(to: dir.appendingPathComponent("abc-1.json"))
        let pts = StoryTrailSource.load("abc-1", in: dir)
        XCTAssertEqual(pts, [StoryPoint(lat: 24.7, lng: 46.6, t: 1000), StoryPoint(lat: 24.71, lng: 46.61, t: 2000, gap: true)])
        XCTAssertEqual(StoryTrailSource.load("missing", in: dir), [])
    }

    /// The story reads exactly what «مساري» writes (TrailStore on feat/ios-ui).
    func testTrailStoreRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        var trail = Trail()
        trail.points = [TrailPoint(lat: 24.7, lng: 46.6, t: 1000), TrailPoint(lat: 24.71, lng: 46.61, t: 2000, gap: true)]
        TrailStore.save(trail, outingId: "out-9", in: dir)
        XCTAssertEqual(StoryTrailSource.load("out-9", in: dir),
                       [StoryPoint(lat: 24.7, lng: 46.6, t: 1000), StoryPoint(lat: 24.71, lng: 46.61, t: 2000, gap: true)])
    }
}

final class StoryStopsTests: XCTestCase {
    func testLongestStopFromTrail() {
        let f = StoryFixtures.facts()
        let s = try! XCTUnwrap(f.longestStop)
        XCTAssertEqual(s.durationS, StoryFixtures.stopS, accuracy: 120)
        XCTAssertEqual(StoryRenderer.stats(f)[3].label, "أطول وقفة")
        XCTAssertEqual(StoryRenderer.stats(f)[3].value, SaryFormat.duration(seconds: Int(s.durationS)))
    }

    func testGapIsNeverAStop() {
        let a = StoryPoint(lat: 24.7, lng: 46.6, t: 0)
        let b = StoryPoint(lat: 24.7001, lng: 46.6, t: 3_600_000, gap: true)
        let c = StoryPoint(lat: 24.71, lng: 46.6, t: 3_700_000)
        XCTAssertNil(StoryStops.longest([a, b, c]))
    }

    func testShortPauseIsNotAStop() {
        let pts = [StoryPoint(lat: 24.7, lng: 46.6, t: 0), StoryPoint(lat: 24.7002, lng: 46.6, t: 60_000), StoryPoint(lat: 24.72, lng: 46.6, t: 120_000)]
        XCTAssertNil(StoryStops.longest(pts))
    }
}

final class StoryLayoutTests: XCTestCase {
    func testCanvasSizes() {
        XCTAssertEqual(StoryFormat.vertical.pixelSize, CGSize(width: 1080, height: 1920))
        XCTAssertEqual(StoryFormat.square.pixelSize, CGSize(width: 1080, height: 1080))
        XCTAssertEqual(StoryFormat.vertical.pixelSize.width / StoryFormat.vertical.pixelSize.height, 9.0 / 16.0, accuracy: 0.0001)
    }

    func testEverythingInsideTheCanvasAndNoOverlaps() {
        for format in StoryFormat.allCases {
            for n in 0...4 {
                let L = StoryLayout.make(format, photoCount: n)
                let canvas = CGRect(origin: .zero, size: L.canvas)
                for r in [L.header, L.map, L.title, L.subtitle] + L.stats + L.photos {
                    XCTAssertTrue(canvas.contains(r), "\(format) \(n): \(r) inside canvas")
                }
                XCTAssertEqual(L.photos.count, min(n, StoryLayout.maxPhotos))
                XCTAssertEqual(L.photoTilts.count, L.photos.count)
                XCTAssertFalse(L.title.intersects(L.map))
                for p in L.photos { XCTAssertTrue(p.intersects(L.map), "photos overlap the map edge"); XCTAssertFalse(p.intersects(L.title)) }
                for i in L.stats.indices {
                    XCTAssertFalse(L.stats[i].intersects(L.subtitle))
                    XCTAssertFalse(L.stats[i].intersects(L.map))
                    for j in L.stats.indices where j != i { XCTAssertFalse(L.stats[i].intersects(L.stats[j])) }
                }
                XCTAssertGreaterThan(L.trailFrame.width, 300)
                XCTAssertGreaterThan(L.trailFrame.height, 250)
            }
        }
    }

    func testVerticalKeepsTextInsideTheAppsFreeBand() {
        for n in 0...3 {
            let L = StoryLayout.make(.vertical, photoCount: n)
            for r in [L.title, L.subtitle] + L.stats {
                XCTAssertGreaterThanOrEqual(r.minY, StoryLayout.safeTop)
                XCTAssertLessThanOrEqual(r.maxY, StoryLayout.safeBottom)
            }
            XCTAssertEqual(L.stats.last!.maxY, StoryLayout.safeBottom, accuracy: 0.5)
        }
    }

    func testStatsReadRightToLeft() {
        for format in StoryFormat.allCases {
            let L = StoryLayout.make(format, photoCount: 0)
            XCTAssertGreaterThan(L.stats[0].minX, L.stats[1].minX, "the first number is on the right (RTL)")
            XCTAssertEqual(L.stats[0].width, L.stats[1].width, accuracy: 0.5)
        }
    }

    func testPhotosShrinkTheMapAndStayClearOfMapboxLogo() {
        let a = StoryLayout.make(.vertical, photoCount: 0), b = StoryLayout.make(.vertical, photoCount: 3)
        XCTAssertLessThan(b.map.height, a.map.height)
        for format in StoryFormat.allCases {
            let L = StoryLayout.make(format, photoCount: 3)
            /* Mapbox's logo: bottom-left of the card, ~10 pt margin, ~85 pt wide at 2×. */
            let logo = CGRect(x: L.map.minX, y: L.map.maxY - 70, width: 200, height: 70)
            for p in L.photos { XCTAssertFalse(p.insetBy(dx: -10, dy: -10).intersects(logo), "\(format): photo clear of the Mapbox logo") }
        }
    }

    func testCameraProjectionMatchesMercator() {
        let pts = [LngLat(lng: 46.60, lat: 24.70), LngLat(lng: 46.70, lat: 24.80)]
        let frame = CGRect(x: 90, y: 90, width: 772, height: 700)
        let cam = StoryCamera.fit(pts, frame: frame, mapPx: CGSize(width: 952, height: 900))!
        let a = cam.pixel(pts[0]), b = cam.pixel(pts[1])
        /* Fitted inside the frame, touching it on the tighter axis, centred on the other. */
        XCTAssertTrue(frame.insetBy(dx: -0.5, dy: -0.5).contains(a))
        XCTAssertTrue(frame.insetBy(dx: -0.5, dy: -0.5).contains(b))
        let touchesX = abs(a.x - frame.minX) < 0.5 && abs(b.x - frame.maxX) < 0.5
        let touchesY = abs(b.y - frame.minY) < 0.5 && abs(a.y - frame.maxY) < 0.5
        XCTAssertTrue(touchesX || touchesY)
        XCTAssertEqual((a.x + b.x) / 2, frame.midX, accuracy: 0.5)
        XCTAssertEqual((a.y + b.y) / 2, frame.midY, accuracy: 0.5)
        XCTAssertLessThan(a.x, b.x)
        XCTAssertGreaterThan(a.y, b.y, "north is up")
    }
}

final class StoryVideoTimingTests: XCTestCase {
    func testFrameCountAndExactTimes() {
        let t = StoryVideoTiming()
        XCTAssertEqual(t.frameCount, 210)
        XCTAssertEqual(t.seconds(0), 0)
        XCTAssertEqual(t.seconds(30), 1, accuracy: 1e-12)
        XCTAssertEqual(t.seconds(t.frameCount - 1), 7 - 1.0 / 30, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(t.duration, 6)
        XCTAssertLessThanOrEqual(t.duration, 8)
    }

    func testProgressHoldsThenDrawsThenHolds() {
        let t = StoryVideoTiming()
        let introFrames = Int(t.intro * Double(t.fps))
        for i in 0...introFrames { XCTAssertEqual(t.progress(i), 0, "hold on the map first") }
        let doneFrame = Int(((t.intro + t.draw) * Double(t.fps)).rounded(.up))
        for i in doneFrame..<t.frameCount { XCTAssertEqual(t.progress(i), 1) }
        var last = -1.0
        for i in 0..<t.frameCount { XCTAssertGreaterThanOrEqual(t.progress(i), last); last = t.progress(i) }
        /* Eased: halfway in time is halfway along, slow at both ends. */
        let mid = Int(((t.intro + t.draw / 2) * Double(t.fps)).rounded())
        XCTAssertEqual(t.progress(mid), 0.5, accuracy: 0.05)
        XCTAssertLessThan(t.progress(introFrames + 3), 0.01)
        XCTAssertGreaterThanOrEqual(t.finale(t.frameCount - 1), 1)
        XCTAssertEqual(t.finale(doneFrame - 2), 0)
        XCTAssertGreaterThan(t.duration - t.intro - t.draw, 1, "at least a second on the finished story")
    }

    func testPolylinePointAtLength() {
        let pl = StoryPolyline(runs: [([CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 50)], [false, false, true], false, false)])
        XCTAssertEqual(pl.total, 150)
        XCTAssertEqual(pl.point(at: 50), CGPoint(x: 50, y: 0))
        XCTAssertEqual(pl.point(at: 125), CGPoint(x: 100, y: 25))
        XCTAssertTrue(pl.segs[1].dashed)
    }
}

final class StoryPhotoTests: XCTestCase {
    func testExifDate() {
        let riyadh = TimeZone(identifier: "Asia/Riyadh")!
        let d = StoryPhotoReader.parseExifDate("2026:10:31 15:42:07", offset: nil, timeZone: riyadh)!
        XCTAssertEqual(d.timeIntervalSince1970, 1_793_450_527, accuracy: 0.5)
        let e = StoryPhotoReader.parseExifDate("2026:10:31 15:42:07", offset: "+03:00")!
        XCTAssertEqual(e, d)
        XCTAssertNil(StoryPhotoReader.parseExifDate("yesterday", offset: nil))
    }

    func testOnlyPhotosFromTheOutingWindow() throws {
        let f = StoryFixtures.facts()
        let w = try XCTUnwrap(f.photoWindow)
        func jpeg(_ date: Date?) -> Data {
            let img = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30)).image { c in UIColor.orange.setFill(); c.fill(CGRect(x: 0, y: 0, width: 40, height: 30)) }
            let out = NSMutableData()
            let dst = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil)!
            var props: [CFString: Any] = [:]
            if let date {
                let df = DateFormatter()
                df.locale = Locale(identifier: "en_US_POSIX")
                df.timeZone = .current
                df.dateFormat = "yyyy:MM:dd HH:mm:ss"
                props[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifDateTimeOriginal: df.string(from: date)]
                props[kCGImagePropertyGPSDictionary] = [kCGImagePropertyGPSLatitude: 24.7, kCGImagePropertyGPSLongitude: 46.6]
            }
            CGImageDestinationAddImage(dst, img.cgImage!, props as CFDictionary)
            CGImageDestinationFinalize(dst)
            return out as Data
        }
        let mid = Date(timeIntervalSince1970: (w.lowerBound.timeIntervalSince1970 + w.upperBound.timeIntervalSince1970) / 2)
        if case .ok = StoryPhotoReader.check(jpeg(mid), window: w) {} else { XCTFail("a photo from the outing is accepted") }
        XCTAssertEqual(StoryPhotoReader.check(jpeg(w.lowerBound.addingTimeInterval(-86400)), window: w), .outsideWindow)
        XCTAssertEqual(StoryPhotoReader.check(jpeg(nil), window: w), .noDate)
        /* What goes on the story is pixels only: no EXIF / GPS left. */
        let img = try XCTUnwrap(StoryPhotoReader.image(jpeg(mid)))
        let reencoded = try XCTUnwrap(img.jpegData(compressionQuality: 0.9))
        let src = CGImageSourceCreateWithData(reencoded as CFData, nil)!
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
        XCTAssertNil(props[kCGImagePropertyGPSDictionary])
    }
}

/// Renders the sample outing (fixture trail) the way a person would get it.
/// With `SARY_STORY_SHOTS=1` it also takes the real Mapbox satellite snapshot and
/// writes the results to docs/app-shots/story-*.jpg.
final class StoryRenderTests: XCTestCase {
    private var shotsDir: URL? {
        guard ProcessInfo.processInfo.environment["SARY_STORY_SHOTS"] == "1" else { return nil }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("docs/app-shots")
    }

    private func samplePhotos() -> [UIImage] {
        /* Stand-ins for picked photos (drawn here: sky, dunes, a fire). */
        let palettes: [[UInt32]] = [[0x2B4C7E, 0xE8A15A, 0xC0662A], [0x1B1F3A, 0x6B3A2A, 0xF2B630], [0x87A9C9, 0xE2B07A, 0xB8661F]]
        return palettes.enumerated().map { i, c in
            UIGraphicsImageRenderer(size: CGSize(width: 600, height: 600)).image { ctx in
                let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [UIColor(rgb: c[0]).cgColor, UIColor(rgb: c[1]).cgColor] as CFArray, locations: [0, 1])!
                ctx.cgContext.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: 420), options: [.drawsAfterEndLocation])
                let dune = UIBezierPath()
                dune.move(to: CGPoint(x: 0, y: 430 - CGFloat(i) * 20))
                dune.addCurve(to: CGPoint(x: 600, y: 380), controlPoint1: CGPoint(x: 200, y: 300), controlPoint2: CGPoint(x: 380, y: 470))
                dune.addLine(to: CGPoint(x: 600, y: 600)); dune.addLine(to: CGPoint(x: 0, y: 600)); dune.close()
                UIColor(rgb: c[2]).setFill(); dune.fill()
                if i == 1 {
                    UIColor(rgb: 0xFFE3A3).setFill()
                    UIBezierPath(ovalIn: CGRect(x: 270, y: 440, width: 60, height: 80)).fill()
                    UIColor.white.withAlphaComponent(0.9).setFill()
                    for k in 0..<40 { UIBezierPath(ovalIn: CGRect(x: CGFloat((k * 97) % 600), y: CGFloat((k * 53) % 260), width: 4, height: 4)).fill() }
                } else {
                    UIColor(rgb: 0xFFF1C9).setFill()
                    UIBezierPath(ovalIn: CGRect(x: 380, y: 150 + CGFloat(i) * 60, width: 90, height: 90)).fill()
                }
            }
        }
    }

    @MainActor
    private func render(_ facts: StoryFacts, _ opts: StoryOptions, photos: [UIImage], snapshot: Bool) async -> (UIImage, StoryScene) {
        var map: UIImage?
        if snapshot, let cam = StoryRenderer.camera(facts, opts, photoCount: photos.count) { map = await StoryMapSnapshot.take(cam) }
        let scene = StoryRenderer.scene(facts, opts, photos: photos, mapImage: map, mark: StoryRenderer.markImage())
        return (StoryRenderer.image(scene), scene)
    }

    private func write(_ img: UIImage, _ name: String) {
        guard let dir = shotsDir, let d = img.jpegData(compressionQuality: 0.86) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? d.write(to: dir.appendingPathComponent("story-\(name).jpg"))
    }

    @MainActor
    func testRenderFixtureStories() async throws {
        let facts = StoryFixtures.facts()
        let shots = shotsDir != nil
        let cases: [(String, StoryOptions, Int)] = [
            ("vertical", StoryOptions(), 0),
            ("vertical-photos", StoryOptions(), 3),
            ("square", StoryOptions(format: .square), 0),
            ("square-photos", StoryOptions(format: .square), 2),
            ("vertical-start-names", StoryOptions(showStartEnd: true, showNames: true), 1),
        ]
        for (name, opts, n) in cases {
            let (img, scene) = await render(facts, opts, photos: Array(samplePhotos().prefix(n)), snapshot: shots)
            XCTAssertEqual(img.size, opts.format.pixelSize, name)
            XCTAssertEqual(img.scale, 1)
            XCTAssertFalse(scene.line.segs.isEmpty, name)
            if shots { XCTAssertNotNil(scene.mapImage, "\(name): satellite snapshot") }
            write(img, name)
        }
        /* A short outing: the trail is hidden entirely by default and the card says why. */
        var short = facts
        short.trail = Array(facts.trail.prefix(12))
        let (img, scene) = await render(short, StoryOptions(), photos: [], snapshot: false)
        XCTAssertTrue(scene.line.segs.isEmpty)
        XCTAssertNil(scene.camera)
        XCTAssertEqual(img.size, StoryFormat.vertical.pixelSize)
    }

    @MainActor
    func testVideoFromFixture() async throws {
        let facts = StoryFixtures.facts()
        let shots = shotsDir != nil
        var map: UIImage?
        if shots, let cam = StoryRenderer.camera(facts, StoryOptions(), photoCount: 0) { map = await StoryMapSnapshot.take(cam) }
        let scene = StoryRenderer.scene(facts, StoryOptions(), photos: [], mapImage: map, mark: StoryRenderer.markImage())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("story-test.mp4")
        let timing = StoryVideoTiming()
        /* Quarter size keeps the test quick; the app writes full 1080×1920. */
        try await StoryVideo.write(scene, to: url, timing: timing, scale: shots ? 1 : 0.25)
        let asset = AVURLAsset(url: url)
        let dur = try await asset.load(.duration).seconds
        XCTAssertEqual(dur, timing.duration, accuracy: 0.1)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let size = try await track.load(.naturalSize)
        XCTAssertEqual(size.width / size.height, 1080.0 / 1920.0, accuracy: 0.01)
        let fps = try await track.load(.nominalFrameRate)
        XCTAssertEqual(fps, 30, accuracy: 1)
        /* Frames from the middle of the draw: part of the line, with the head. */
        if shots, let dir = shotsDir {
            let gen = AVAssetImageGenerator(asset: asset)
            gen.requestedTimeToleranceBefore = .zero
            gen.requestedTimeToleranceAfter = .zero
            let cg = try await gen.image(at: CMTime(value: 90, timescale: 30)).image
            try? UIImage(cgImage: cg).jpegData(compressionQuality: 0.86)?.write(to: dir.appendingPathComponent("story-video-frame.jpg"))
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("story-video.mp4"))
        }
        try? FileManager.default.removeItem(at: url)
    }
}
