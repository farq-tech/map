import Accelerate
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
        /* Geometry and colour stay the photo's: only the model's fine detail is kept, and a tile
           that would gain a straight line (a "track") is not shown at all. */
        guard let merged = Self.mergeDetail(ai: cg, source: crop, factor: plan.factor) else { return nil }
        guard !merged.addsLine else {
            rejected += 1
            return nil
        }
        return UIImage(cgImage: merged.image)
    }

    /// Tiles refused by the line check (for the debug stats).
    private(set) var rejected = 0

    /// How much of the model's high-frequency detail is kept (it tends to over-sharpen).
    static let detailGain: Float = 0.85

    struct Merged {
        var image: CGImage
        var addsLine: Bool
        var scores: (source: Float, enhanced: Float)
    }

    /// Frequency split: `blur(source) + gain × (ai − blur(ai))` at 512 px. The low frequencies —
    /// every shape, dune, road, colour and shadow — come from the real photo; the model only
    /// contributes texture finer than the blur (≈ the parent's own pixel), so it can neither
    /// move nor invent a landform, and cannot shift the `SandGrade` colours. Then `LineGuard`
    /// compares the result with the plain up-sampled photo.
    static func mergeDetail(ai: CGImage, source: CGImage, factor: Int, gain: Float = detailGain) -> Merged? {
        let n = outputSize
        guard let a = rgba(ai, n), let s = rgba(source, n) else { return nil }
        let r = max(1, factor)
        let ba = blur(a, n, radius: r), bs = blur(s, n, radius: r)
        var out = [UInt8](repeating: 255, count: n * n * 4)
        for i in 0..<(n * n) {
            let o = i * 4
            for c in 0..<3 {
                let v = Float(bs[o + c]) + gain * (Float(a[o + c]) - Float(ba[o + c]))
                out[o + c] = UInt8(max(0, min(255, v.rounded())))
            }
        }
        let side = 256
        let src = LineGuard.score(LineGuard.gray(rgba: s, width: n, height: n, to: side), width: side, height: side)
        let enh = LineGuard.score(LineGuard.gray(rgba: out, width: n, height: n, to: side), width: side, height: side)
        guard let img = cgImage(out, n) else { return nil }
        return Merged(image: img, addsLine: LineGuard.addsLine(enhanced: enh, source: src), scores: (src, enh))
    }

    /// `image` drawn at n×n, RGBA8 (opaque), high-quality interpolation.
    static func rgba(_ image: CGImage, _ n: Int) -> [UInt8]? {
        var d = [UInt8](repeating: 0, count: n * n * 4)
        let ok: Bool = d.withUnsafeMutableBytes { p in
            guard let ctx = CGContext(data: p.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n))
            return true
        }
        return ok ? d : nil
    }

    static func cgImage(_ d: [UInt8], _ n: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(d) as CFData) else { return nil }
        return CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: n * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil,
                       shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Tent blur (≈ two box passes, σ ≈ radius) with Accelerate, edges extended.
    static func blur(_ src: [UInt8], _ n: Int, radius r: Int) -> [UInt8] {
        var input = src, out = [UInt8](repeating: 0, count: src.count)
        let k = UInt32(4 * r + 1)
        input.withUnsafeMutableBytes { ip in
            out.withUnsafeMutableBytes { op in
                var a = vImage_Buffer(data: ip.baseAddress, height: vImagePixelCount(n), width: vImagePixelCount(n), rowBytes: n * 4)
                var b = vImage_Buffer(data: op.baseAddress, height: vImagePixelCount(n), width: vImagePixelCount(n), rowBytes: n * 4)
                _ = vImageTentConvolve_ARGB8888(&a, &b, nil, 0, 0, k, k, nil, vImage_Flags(kvImageEdgeExtend))
            }
        }
        return out
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
