import CoreImage
import CoreML
import CoreVideo
import ImageIO
import UIKit

/// Runs the bundled Core ML model (Real-ESRGAN x4plus, BSD-3-Clause, fp16, fixed 256 px input
/// → 1024 px output; `SatelliteEnhancer.mlpackage`, rebuilt with scripts/ai-sat/convert.py)
/// on one crop of a parent tile and returns the 512 px display tile.
///
/// Not thread-safe by itself: `HiResImagery` calls it from one serial utility queue.
final class HiResEnhancer {
    static let inputSize = 256
    static let outputSize = 512
    static let modelName = "SatelliteEnhancer"

    private let model: MLModel
    private let ci = CIContext(options: [.cacheIntermediates: false, .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
    /// Recent inference times (ms), for the debug log and the performance notes.
    private(set) var recentMs: [Double] = []

    /// Is the compiled model in the app bundle? (The feature is off without it.)
    static var bundledURL: URL? { Bundle.main.url(forResource: modelName, withExtension: "mlmodelc") }

    init(url: URL, units: MLComputeUnits = .cpuAndNeuralEngine) throws {
        let cfg = MLModelConfiguration()
        #if targetEnvironment(simulator)
        cfg.computeUnits = .cpuOnly
        #else
        cfg.computeUnits = units
        #endif
        model = try MLModel(contentsOf: url, configuration: cfg)
    }

    static func decode(_ data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
    }

    /// The enhanced 512 px tile for `plan`, made from the decoded 512 px parent.
    func enhance(parent: CGImage, plan: HiResTilePlan) -> UIImage? {
        let scale = CGFloat(parent.width) / 512
        let rect = CGRect(x: CGFloat(plan.cropX) * scale, y: CGFloat(plan.cropY) * scale,
                          width: CGFloat(plan.cropSize) * scale, height: CGFloat(plan.cropSize) * scale)
        guard let crop = parent.cropping(to: rect), let input = Self.pixelBuffer(crop, size: Self.inputSize) else { return nil }
        let t0 = CFAbsoluteTimeGetCurrent()
        guard let provider = try? MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: input)]),
              let out = try? model.prediction(from: provider, options: MLPredictionOptions()),
              let buf = out.featureValue(for: "enhanced")?.imageBufferValue else { return nil }
        record((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        /* 1024 → 512 (Lanczos): the display tile; ×2 effective for a 256 crop, ×4 for a 128 crop. */
        let big = CIImage(cvPixelBuffer: buf)
        let s = CGFloat(Self.outputSize) / big.extent.width
        guard let f = CIFilter(name: "CILanczosScaleTransform") else { return nil }
        f.setValue(big, forKey: kCIInputImageKey)
        f.setValue(s, forKey: kCIInputScaleKey)
        f.setValue(1.0, forKey: kCIInputAspectRatioKey)
        guard let small = f.outputImage,
              let cg = ci.createCGImage(small, from: CGRect(x: 0, y: 0, width: Self.outputSize, height: Self.outputSize)) else { return nil }
        return UIImage(cgImage: cg)
    }

    private func record(_ ms: Double) {
        recentMs.append(ms)
        if recentMs.count > 64 { recentMs.removeFirst(recentMs.count - 64) }
    }

    /// Median of the recent inference times (ms), nil before the first.
    var medianMs: Double? {
        guard !recentMs.isEmpty else { return nil }
        return recentMs.sorted()[recentMs.count / 2]
    }

    /// `image` drawn into a size × size BGRA buffer (a 128 crop is doubled, high-quality).
    static func pixelBuffer(_ image: CGImage, size: Int) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferCGImageCompatibilityKey: true,
                     kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary
        guard CVPixelBufferCreate(nil, size, size, kCVPixelFormatType_32BGRA, attrs, &pb) == kCVReturnSuccess, let pb else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: size, height: size, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        return pb
    }
}
