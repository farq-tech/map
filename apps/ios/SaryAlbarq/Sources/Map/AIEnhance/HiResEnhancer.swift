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
        /* Matched to the imagery it covers (colour, contrast, a share of the plain upscale) and
           feathered at its edge, so neither the tile's colour nor its border shows (`HiResBlend`). */
        let n = Self.outputSize
        guard let sr = HiResBlend.rgba(cg, size: n), let base = HiResBlend.rgba(crop, size: n),
              let out = HiResBlend.image(HiResBlend.blend(enhanced: sr, base: base, size: n), size: n) else { return UIImage(cgImage: cg) }
        return UIImage(cgImage: out)
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

/// How an enhanced tile sits on the imagery under it (pure, unit-tested in `HiResImageryTests`).
///
/// Build 36 (owner's recording): enhanced tiles read as patches. The model shifts colour and
/// contrast a little, flattens low-texture sand into smooth areas, and each 512 px tile is
/// enhanced alone, so its border did not continue into its neighbour or into the original
/// imagery around it. Three corrections, all on the tile's own pixels:
/// 1. colour: each channel brought to the mean and contrast of a plain upscale of the same crop;
/// 2. texture: only `detail` of the model's difference from that upscale is kept;
/// 3. edge: the alpha fades to 0 over `feather` px, so the original imagery under the tile
///    (the same picture, Mapbox's own over-zoom) shows through at every tile border.
enum HiResBlend {
    /// Share of the model's own detail kept over the plain upscale (1 = model only).
    static let detail = 0.7
    /// Output pixels (of 512) over which the edge fades into the imagery underneath.
    static let feather = 14
    /// Bounds of the per-channel contrast correction (never a strong re-grade).
    static let gainRange = 0.8...1.25

    /// Per-channel (R, G, B) mean and standard deviation of RGBA pixels; alpha ignored.
    static func stats(_ px: [UInt8]) -> (mean: [Double], std: [Double]) {
        let n = px.count / 4
        guard n > 0 else { return ([0, 0, 0], [0, 0, 0]) }
        var sum = [0.0, 0.0, 0.0], sq = [0.0, 0.0, 0.0]
        var i = 0
        while i < n * 4 {
            for c in 0..<3 {
                let v = Double(px[i + c])
                sum[c] += v
                sq[c] += v * v
            }
            i += 4
        }
        let mean = sum.map { $0 / Double(n) }
        let std = (0..<3).map { c in max(0, sq[c] / Double(n) - mean[c] * mean[c]).squareRoot() }
        return (mean, std)
    }

    /// 1 inside, fading smoothly to 0 at the tile's border over `feather` px.
    static func edgeAlpha(x: Int, y: Int, size: Int, feather: Int) -> Double {
        guard feather > 0 else { return 1 }
        let d = Double(min(min(x, size - 1 - x), min(y, size - 1 - y))) + 0.5
        let t = min(1, max(0, d / Double(feather)))
        return t * t * (3 - 2 * t)
    }

    /// `enhanced` (opaque RGBA) matched to `base` (the same crop, plainly upscaled), mixed by
    /// `detail`, with the edge feather; premultiplied RGBA, `size` × `size`.
    static func blend(enhanced: [UInt8], base: [UInt8], size: Int, detail: Double = HiResBlend.detail, feather: Int = HiResBlend.feather) -> [UInt8] {
        let count = size * size * 4
        guard enhanced.count == count, base.count == count else { return enhanced }
        let e = stats(enhanced), b = stats(base)
        let gain = (0..<3).map { c -> Double in
            guard e.std[c] > 0.5 else { return 1 }
            return min(gainRange.upperBound, max(gainRange.lowerBound, b.std[c] / e.std[c]))
        }
        var out = [UInt8](repeating: 0, count: count)
        for y in 0..<size {
            for x in 0..<size {
                let i = (y * size + x) * 4
                let a = edgeAlpha(x: x, y: y, size: size, feather: feather)
                for c in 0..<3 {
                    let matched = (Double(enhanced[i + c]) - e.mean[c]) * gain[c] + b.mean[c]
                    let plain = Double(base[i + c])
                    let v = min(255, max(0, plain + detail * (matched - plain)))
                    out[i + c] = UInt8((v * a).rounded())
                }
                out[i + 3] = UInt8((255 * a).rounded())
            }
        }
        return out
    }

    /// `image` drawn into a `size` × `size` premultiplied RGBA buffer (high-quality resampling).
    static func rgba(_ image: CGImage, size: Int) -> [UInt8]? {
        var px = [UInt8](repeating: 0, count: size * size * 4)
        let ok = px.withUnsafeMutableBytes { buf -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(data: buf.baseAddress, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
            return true
        }
        return ok ? px : nil
    }

    /// A premultiplied RGBA buffer as an image.
    static func image(_ px: [UInt8], size: Int) -> CGImage? {
        guard px.count == size * size * 4, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(px) as CFData) else { return nil }
        return CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
