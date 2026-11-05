import AVFoundation
import CoreLocation
import ImageIO
import MapboxMaps
import Photos
import UIKit

// MARK: - satellite snapshot

/// The map card's satellite image, taken with Mapbox's snapshotter (satellite, no labels:
/// no street names near home). Only the Mapbox tile requests leave the phone — the same
/// tiles the live map loads; the trail is drawn by us afterwards and never sent.
enum StoryMapSnapshot {
    static let style = StyleURI.satellite

    @MainActor
    static func take(_ cam: StoryCamera, timeout: TimeInterval = 20) async -> UIImage? {
        let opts = MapSnapshotOptions(size: cam.sizePt, pixelRatio: cam.pixelRatio, showsLogo: true, showsAttribution: false)
        let snap = Snapshotter(options: opts)
        snap.styleURI = style
        snap.setCamera(to: CameraOptions(center: CLLocationCoordinate2D(latitude: cam.centerLat, longitude: cam.centerLng), zoom: cam.zoom, bearing: 0, pitch: 0))
        return await withCheckedContinuation { (k: CheckedContinuation<UIImage?, Never>) in
            var done = false
            let finish: (UIImage?) -> Void = { img in
                guard !done else { return }
                done = true
                k.resume(returning: img)
            }
            snap.start(overlayHandler: nil) { result in
                _ = snap
                if case .success(let img) = result { finish(img) } else { finish(nil) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                snap.cancel()
                finish(nil)
            }
        }
    }
}

// MARK: - photos from the outing

/// A picked photo: pixels only (decoded and downscaled, so no EXIF / GPS survives into the story).
struct StoryPhoto: Identifiable, Equatable {
    let id = UUID()
    var image: UIImage
    var takenAt: Date

    static func == (a: StoryPhoto, b: StoryPhoto) -> Bool { a.id == b.id }
}

enum StoryPhotoReader {
    enum Outcome: Equatable {
        case ok(Date)
        case outsideWindow
        case noDate
        case unreadable
    }

    /// When the photo was taken, from its own metadata (no Photos-library permission needed).
    static func takenAt(_ data: Data) -> Date? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let raw = (exif?[kCGImagePropertyExifDateTimeOriginal] as? String) ?? (exif?[kCGImagePropertyExifDateTimeDigitized] as? String) ?? (tiff?[kCGImagePropertyTIFFDateTime] as? String)
        let offset = (exif?[kCGImagePropertyExifOffsetTimeOriginal] as? String) ?? (exif?[kCGImagePropertyExifOffsetTime] as? String)
        return raw.flatMap { parseExifDate($0, offset: offset) }
    }

    /// "2026:10:31 15:42:07" (+ optional "+03:00") → Date. Without an offset, the phone's time zone.
    static func parseExifDate(_ s: String, offset: String?, timeZone: TimeZone = .current) -> Date? {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.calendar = Calendar(identifier: .gregorian)
        if let offset, !offset.isEmpty {
            df.dateFormat = "yyyy:MM:dd HH:mm:ssxxx"
            return df.date(from: s + offset)
        }
        df.timeZone = timeZone
        df.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return df.date(from: s)
    }

    static func check(_ data: Data, window: ClosedRange<Date>?) -> Outcome {
        guard let d = takenAt(data) else { return .noDate }
        if let window, !window.contains(d) { return .outsideWindow }
        return .ok(d)
    }

    /// Decode and downscale (the long side ≤ `maxSide`): the story keeps pixels only.
    static func image(_ data: Data, maxSide: CGFloat = 1400) -> UIImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
}

// MARK: - video

/// A short video of the trail drawing itself (H.264, the story's canvas size, ~7 s, no audio).
enum StoryVideo {
    enum Failure: Error { case writer, frame }

    static func write(_ scene: StoryScene, to url: URL, timing: StoryVideoTiming = .init(), scale: CGFloat = 1,
                      progress: (@Sendable (Double) -> Void)? = nil) async throws {
        try? FileManager.default.removeItem(at: url)
        let canvas = scene.layout.canvas
        /* H.264 wants even dimensions. */
        let w = Int((canvas.width * scale / 2).rounded()) * 2, h = Int((canvas.height * scale / 2).rounded()) * 2
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: w,
            AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: Int(Double(w * h) * 5.5), AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w,
            kCVPixelBufferHeightKey as String: h,
        ])
        guard writer.canAdd(input) else { throw Failure.writer }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? Failure.writer }
        writer.startSession(atSourceTime: .zero)

        let base = StoryRenderer.baseImage(scene)
        let n = timing.frameCount
        for i in 0..<n {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            guard let pool = adaptor.pixelBufferPool else { throw writer.error ?? Failure.writer }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
            guard let pb else { throw Failure.frame }
            render(scene, base: base, frame: i, timing: timing, into: pb, width: w, height: h)
            let t = CMTime(value: CMTimeValue(i), timescale: timing.fps)
            guard adaptor.append(pb, withPresentationTime: t) else { throw writer.error ?? Failure.frame }
            progress?(Double(i + 1) / Double(n))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? Failure.writer }
    }

    static func render(_ scene: StoryScene, base: UIImage, frame i: Int, timing: StoryVideoTiming, into pb: CVPixelBuffer, width w: Int, height h: Int) {
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
        /* UIKit coordinates (top-left origin), scaled to the video size. */
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: CGFloat(w) / scene.layout.canvas.width, y: -CGFloat(h) / scene.layout.canvas.height)
        UIGraphicsPushContext(ctx)
        base.draw(in: CGRect(origin: .zero, size: scene.layout.canvas))
        StoryRenderer.drawTrail(ctx, scene, progress: CGFloat(timing.progress(i)), head: true)
        StoryRenderer.drawTop(ctx, scene, finale: CGFloat(timing.finale(i)))
        UIGraphicsPopContext()
    }
}

// MARK: - out: files + Photos

enum StoryExport {
    /// A temp file for the share sheet (JPEG: generated pixels only, no location metadata).
    static func jpeg(_ img: UIImage, name: String = "قصة-الطلعة") -> URL? {
        guard let data = img.jpegData(compressionQuality: 0.92) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).jpg")
        do { try data.write(to: url, options: .atomic); return url } catch { return nil }
    }

    static func videoURL() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("قصة-الطلعة.mp4") }

    enum SaveResult: Equatable { case saved, denied, failed }

    /// «احفظ في الصور»: add-only access (we never read the library).
    static func saveToPhotos(image: UIImage? = nil, video: URL? = nil) async -> SaveResult {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return .denied }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let req = PHAssetCreationRequest.forAsset()
                if let video { req.addResource(with: .video, fileURL: video, options: nil) } else if let image, let d = image.jpegData(compressionQuality: 0.92) {
                    req.addResource(with: .photo, data: d, options: nil)
                }
            }
            return .saved
        } catch { return .failed }
    }

    static func cleanUp() {
        let tmp = FileManager.default.temporaryDirectory
        for n in ["قصة-الطلعة.jpg", "قصة-الطلعة.mp4"] { try? FileManager.default.removeItem(at: tmp.appendingPathComponent(n)) }
    }
}
