import AVKit
import CoreMedia
import CoreVideo
import SwiftUI
import UIKit

/// The compact, live navigation card streamed to iOS Picture in Picture.
struct NavPiPSnapshot: Equatable {
    var target: String
    var road: String
    var instruction: String
    var symbol: String
    var distanceToTurn: String
    var distanceRemaining: String
    var timeRemaining: String
    var route: [LngLat]
    var progress: Double

    @MainActor static func make(nav: NavSession) -> NavPiPSnapshot? {
        guard let step = nav.currentStep else { return nil }
        return NavPiPSnapshot(target: nav.target?.name ?? "وجهتك",
                              road: NavHUD.title(step, targetName: nav.target?.name),
                              instruction: NavText.action(step.maneuver),
                              symbol: NavGlyph.symbol(step.maneuver),
                              distanceToTurn: SaryFormat.distance(meters: nav.progress?.distanceToManeuverM ?? step.distanceM),
                              distanceRemaining: nav.remainingMeters.map(SaryFormat.distance(meters:)) ?? "",
                              timeRemaining: nav.remainingSeconds.map(NavText.remaining(seconds:)) ?? "",
                              route: nav.active?.coordinates ?? [],
                              progress: nav.active.map { route in
                                  guard route.distanceM > 0 else { return 0 }
                                  return min(1, max(0, 1 - (nav.remainingMeters ?? route.distanceM) / route.distanceM))
                              } ?? 0)
    }
}

/// Renders current guidance as a low-rate live video stream for the system PiP window.
/// The route remains active in the app; PiP is a read-only glance that returns to Sary on tap.
@MainActor
final class NavPictureInPicture: NSObject, ObservableObject {
    @Published private(set) var active = false
    @Published private(set) var supported = AVPictureInPictureController.isPictureInPictureSupported()
    @Published var startError: String?

    let displayLayer = AVSampleBufferDisplayLayer()
    private var controller: AVPictureInPictureController?
    private var snapshot: NavPiPSnapshot?
    private var timer: Timer?
    private var startTask: Task<Void, Never>?
    private var frame = 0
    private var automatic = false

    override init() {
        super.init()
        displayLayer.videoGravity = .resizeAspect
        guard supported else { return }
        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: displayLayer,
                                                                 playbackDelegate: self)
        controller = AVPictureInPictureController(contentSource: source)
        controller?.delegate = self
        controller?.canStartPictureInPictureAutomaticallyFromInline = true
    }

    func update(_ snapshot: NavPiPSnapshot?, guiding: Bool) {
        self.snapshot = snapshot
        automatic = guiding && snapshot != nil
        controller?.canStartPictureInPictureAutomaticallyFromInline = automatic
        guard automatic else {
            if active { controller?.stopPictureInPicture() }
            stopFrames()
            return
        }
        enqueueFrame()
    }

    func start() {
        guard supported, let snapshot, snapshot.distanceToTurn.isEmpty == false else { return }
        guard automatic else { return }
        startTask?.cancel()
        startError = nil
        enqueueFrame()
        startFrames()
        startTask = Task { @MainActor [weak self] in
            /* The sample-buffer layer consumes its first frame asynchronously. PiP can report
             * `isPictureInPicturePossible == false` for a short time after enqueueFrame(); retry
             * briefly instead of silently dropping the user's tap. */
            for _ in 0..<20 {
                guard let self, !Task.isCancelled, self.automatic, self.snapshot != nil else { return }
                if self.controller?.isPictureInPicturePossible == true {
                    self.controller?.startPictureInPicture()
                    self.startTask = nil
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard let self, !Task.isCancelled, self.automatic else { return }
            self.startTask = nil
            self.startError = "لم تصبح نافذة الملاحة جاهزة. تأكد من ظهور تعليمات الطريق ثم حاول مرة أخرى."
        }
    }

    func stop() {
        startTask?.cancel()
        startTask = nil
        controller?.canStartPictureInPictureAutomaticallyFromInline = false
        if active { controller?.stopPictureInPicture() }
        automatic = false
        stopFrames()
        snapshot = nil
    }

    private func startFrames() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.enqueueFrame() }
        }
    }

    private func stopFrames() {
        timer?.invalidate()
        timer = nil
    }

    private func enqueueFrame() {
        guard let snapshot, let image = Self.render(snapshot), let cgImage = image.cgImage else { return }
        let width = cgImage.width, height = cgImage.height
        var pixelBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferCGImageCompatibilityKey: true,
                                           kCVPixelBufferCGBitmapContextCompatibilityKey: true]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                  attributes as CFDictionary, &pixelBuffer) == kCVReturnSuccess,
              let pixelBuffer,
              CVPixelBufferLockBaseAddress(pixelBuffer, []) == kCVReturnSuccess else { return }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer),
              let context = CGContext(data: base, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                            imageBuffer: pixelBuffer,
                                                            formatDescriptionOut: &format) == noErr,
              let format else { return }
        frame += 1
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 1),
                                        presentationTimeStamp: CMTime(value: Int64(frame), timescale: 1),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
                                                        imageBuffer: pixelBuffer,
                                                        formatDescription: format,
                                                        sampleTiming: &timing,
                                                        sampleBufferOut: &sample) == noErr,
              let sample else { return }
        displayLayer.enqueue(sample)
    }

    private static func render(_ snapshot: NavPiPSnapshot) -> UIImage? {
        let size = CGSize(width: 640, height: 360)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            let bounds = CGRect(origin: .zero, size: size)
            UIColor(red: 0.035, green: 0.045, blue: 0.065, alpha: 1).setFill()
            ctx.fill(bounds)
            UIColor(red: 0.16, green: 0.48, blue: 0.94, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: size.width, height: 9))

            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .right
            paragraph.baseWritingDirection = .rightToLeft
            let right: CGFloat = size.width - 32
            (snapshot.target as NSString).draw(in: CGRect(x: 180, y: 28, width: right - 180, height: 34),
                                               withAttributes: [.font: UIFont.systemFont(ofSize: 23, weight: .semibold),
                                                                .foregroundColor: UIColor(white: 0.8, alpha: 1),
                                                                .paragraphStyle: paragraph])
            UIImage(systemName: snapshot.symbol)?.withTintColor(.white, renderingMode: .alwaysOriginal)
                .draw(in: CGRect(x: 30, y: 94, width: 60, height: 60))
            (snapshot.distanceToTurn as NSString).draw(in: CGRect(x: 108, y: 88, width: 220, height: 68),
                                                       withAttributes: [.font: UIFont.systemFont(ofSize: 48, weight: .bold),
                                                                        .foregroundColor: UIColor.white])
            (snapshot.instruction as NSString).draw(in: CGRect(x: 108, y: 158, width: 220, height: 34),
                                                    withAttributes: [.font: UIFont.systemFont(ofSize: 22, weight: .semibold),
                                                                     .foregroundColor: UIColor(white: 0.86, alpha: 1),
                                                                     .paragraphStyle: paragraph])
            (snapshot.road as NSString).draw(in: CGRect(x: 30, y: 218, width: 300, height: 30),
                                             withAttributes: [.font: UIFont.systemFont(ofSize: 18, weight: .bold),
                                                              .foregroundColor: UIColor(red: 0.31, green: 0.74, blue: 0.58, alpha: 1),
                                                              .paragraphStyle: paragraph])
            drawMiniRoute(snapshot, in: ctx.cgContext)
            UIColor(white: 0.2, alpha: 1).setFill()
            ctx.fill(CGRect(x: 22, y: 270, width: size.width - 44, height: 1))
            let footer = [snapshot.timeRemaining, snapshot.distanceRemaining].filter { !$0.isEmpty }.joined(separator: "  ·  ")
            (footer as NSString).draw(in: CGRect(x: 30, y: 286, width: right - 30, height: 40),
                                      withAttributes: [.font: UIFont.systemFont(ofSize: 22, weight: .medium),
                                                       .foregroundColor: UIColor.white,
                                                       .paragraphStyle: paragraph])
        }
    }

    /// A continuously updated route preview makes the floating window read like live navigation,
    /// while keeping the frame light enough to refresh once a second in PiP.
    private static func drawMiniRoute(_ snapshot: NavPiPSnapshot, in context: CGContext) {
        let rect = CGRect(x: 360, y: 76, width: 250, height: 176)
        let clip = UIBezierPath(roundedRect: rect, cornerRadius: 20)
        UIColor(red: 0.075, green: 0.10, blue: 0.15, alpha: 1).setFill()
        clip.fill()
        context.saveGState()
        context.addPath(clip.cgPath)
        context.clip()
        UIColor(white: 1, alpha: 0.045).setStroke()
        let grid = UIBezierPath()
        for x in stride(from: rect.minX + 20, through: rect.maxX, by: 42) {
            grid.move(to: CGPoint(x: x, y: rect.minY)); grid.addLine(to: CGPoint(x: x - 18, y: rect.maxY))
        }
        for y in stride(from: rect.minY + 20, through: rect.maxY, by: 38) {
            grid.move(to: CGPoint(x: rect.minX, y: y)); grid.addLine(to: CGPoint(x: rect.maxX, y: y + 10))
        }
        grid.lineWidth = 1
        grid.stroke()

        guard snapshot.route.count > 1 else {
            context.restoreGState()
            return
        }
        let points = snapshot.route
        let minLon = points.map(\.lng).min()!, maxLon = points.map(\.lng).max()!
        let minLat = points.map(\.lat).min()!, maxLat = points.map(\.lat).max()!
        let lonSpan = max(maxLon - minLon, 0.0001), latSpan = max(maxLat - minLat, 0.0001)
        let inset = rect.insetBy(dx: 28, dy: 22)
        let projected = points.map { point in
            CGPoint(x: inset.minX + (point.lng - minLon) / lonSpan * inset.width,
                    y: inset.maxY - (point.lat - minLat) / latSpan * inset.height)
        }
        let routePath = UIBezierPath()
        routePath.move(to: projected[0])
        for point in projected.dropFirst() { routePath.addLine(to: point) }
        routePath.lineCapStyle = .round
        routePath.lineJoinStyle = .round
        UIColor(white: 1, alpha: 0.22).setStroke()
        routePath.lineWidth = 9
        routePath.stroke()
        UIColor(red: 0.16, green: 0.48, blue: 0.98, alpha: 1).setStroke()
        routePath.lineWidth = 5
        routePath.stroke()

        let head = min(projected.count - 1, Int(snapshot.progress * Double(projected.count - 1)))
        let car = projected[head]
        UIColor.white.withAlphaComponent(0.9).setFill()
        UIBezierPath(ovalIn: CGRect(x: car.x - 9, y: car.y - 9, width: 18, height: 18)).fill()
        UIColor(red: 0.16, green: 0.48, blue: 0.98, alpha: 1).setFill()
        UIBezierPath(ovalIn: CGRect(x: car.x - 6, y: car.y - 6, width: 12, height: 12)).fill()
        UIImage(systemName: "flag.fill")?.withTintColor(.systemGreen, renderingMode: .alwaysOriginal)
            .draw(in: CGRect(x: projected.last!.x - 8, y: projected.last!.y - 21, width: 16, height: 16))
        context.restoreGState()
    }
}

extension NavPictureInPicture: AVPictureInPictureControllerDelegate {
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: Error) {
        startTask?.cancel()
        startTask = nil
        startError = "تعذر فتح نافذة الملاحة. حاول مرة أخرى."
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        startTask?.cancel()
        startTask = nil
        startError = nil
        active = true
        startFrames()
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        active = false
        stopFrames()
    }
}

extension NavPictureInPicture: AVPictureInPictureSampleBufferPlaybackDelegate {
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {}
    func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .zero, duration: .positiveInfinity)
    }
    func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool { false }
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    skipByInterval skipInterval: CMTime,
                                    completion: @escaping () -> Void) { completion() }
    func pictureInPictureControllerShouldProhibitBackgroundAudioPlayback(_ pictureInPictureController: AVPictureInPictureController) -> Bool { true }
}

/// Keeps the sample-buffer layer in the active screen so PiP can animate from this navigation surface.
struct NavPiPLayerHost: UIViewRepresentable {
    var displayLayer: AVSampleBufferDisplayLayer

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.layer.addSublayer(displayLayer)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        displayLayer.frame = view.bounds
    }

}
