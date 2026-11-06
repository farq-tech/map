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

    /// A JPEG decoded right away (off the main thread), for handing to Mapbox.
    static func decodeNow(_ data: Data) -> UIImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// The enhanced display tile for `plan` (`profile.outputSize` px), made from the decoded
    /// 512 px parent; nil when the model fails or `LineGuard` refuses the result.
    func enhance(parent: CGImage, plan: HiResTilePlan, profile: HiResProfile = .light) -> UIImage? {
        let scale = CGFloat(parent.width) / 512
        let rect = CGRect(x: CGFloat(plan.cropX) * scale, y: CGFloat(plan.cropY) * scale,
                          width: CGFloat(plan.cropSize) * scale, height: CGFloat(plan.cropSize) * scale)
        guard let crop = parent.cropping(to: rect) else { return nil }
        let n = profile.outputSize
        let ai: CGImage?
        if plan.factor == 1 {
            /* The tile itself: four 256 px quarters, each ×4, put together at n px (×2 over the photo). */
            let half = crop.width / 2
            ai = Self.draw(n) { ctx in
                for (qx, qy) in [(0, 0), (1, 0), (0, 1), (1, 1)] {
                    guard let q = crop.cropping(to: CGRect(x: qx * half, y: qy * half, width: half, height: half)),
                          let out = self.infer(q) else { return false }
                    /* CG's origin is bottom-left: quarter row 0 (north) goes on top. */
                    ctx.draw(out, in: CGRect(x: qx * n / 2, y: (1 - qy) * n / 2, width: n / 2, height: n / 2))
                }
                return true
            }
        } else {
            ai = infer(crop).flatMap { out in out.width == n ? out : Self.draw(n) { $0.draw(out, in: CGRect(x: 0, y: 0, width: n, height: n)); return true } }
        }
        guard let ai else { return nil }
        /* Geometry and colour stay the photo's: only the model's fine detail is kept, and a tile
           that would gain a straight line (a "track") is not shown at all. */
        guard let merged = Self.mergeDetail(ai: ai, source: crop, ratio: n / plan.cropSize, profile: profile) else { return nil }
        if merged.softened { softened += 1 }
        guard !merged.refused else {
            rejected += 1
            return nil
        }
        return UIImage(cgImage: merged.image)
    }

    /// One model run: a crop (doubled to 256 px when smaller) → its 1024 px ×4 image.
    private func infer(_ crop: CGImage) -> CGImage? {
        guard let input = Self.pixelBuffer(crop, size: Self.inputSize) else { return nil }
        let t0 = CFAbsoluteTimeGetCurrent()
        guard let provider = try? MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: input)]),
              let out = try? model.prediction(from: provider, options: MLPredictionOptions()),
              let buf = out.featureValue(for: "enhanced")?.imageBufferValue else { return nil }
        record((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        let big = CIImage(cvPixelBuffer: buf)
        return ci.createCGImage(big, from: big.extent)
    }

    /// An n×n opaque sRGB canvas, high-quality interpolation.
    static func draw(_ n: Int, _ body: (CGContext) -> Bool) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        guard body(ctx) else { return nil }
        return ctx.makeImage()
    }

    /// Tiles refused by the line / object checks, and tiles shown at half strength (debug stats).
    private(set) var rejected = 0
    private(set) var softened = 0

    /// How much of the model's high-frequency detail is kept by «خفيف» (it tends to over-sharpen).
    static let detailGain: Float = 0.85

    struct Merged {
        var image: CGImage
        var addsLine: Bool
        var scores: (source: Float, enhanced: Float)
        /// A new dark elongated object (`ObjectGuard`) is still there after softening.
        var addsObject = false
        /// The first try failed a guard; this is the half-strength one.
        var softened = false
        var refused: Bool { addsLine || addsObject }
    }

    /// The round-2 merge (512 px, no post-sharpening): kept for the tests' reference cases.
    static func mergeDetail(ai: CGImage, source: CGImage, factor: Int, gain: Float = detailGain) -> Merged? {
        var p = HiResProfile.light
        p.outputSize = outputSize
        p.gain = gain
        p.sharpen = 0
        p.localContrast = 0
        return mergeDetail(ai: ai, source: source, ratio: factor, profile: p)
    }

    /// At `profile.outputSize`: `blur(source) + gain × (ai − blur(ai))`, blur radius = `splitScale`
    /// source pixels (`ratio` output px each). «خفيف» / cities (1 px): a frequency split, the model
    /// only adds texture finer than a source pixel. «قوي» desert (8 px): full SR with a local
    /// colour transfer — the photo's colour and broad shading, the model's picture. Then an
    /// unsharp mask (½ source pixel) and local contrast (6 source pixels), and the guards
    /// (`LineGuard`, `ObjectGuard`) against the plain up-sampled photo.
    static func mergeDetail(ai: CGImage, source: CGImage, ratio: Int, profile: HiResProfile) -> Merged? {
        let n = profile.outputSize
        guard let a = rgba(ai, n), let s = rgba(source, n) else { return nil }
        let r = max(1, Int((Float(max(1, ratio)) * profile.splitScale).rounded()))
        let ba = blur(a, n, radius: r), bs = blur(s, n, radius: r)
        let gain = profile.gain
        var base = [Float](repeating: 0, count: n * n * 3)
        for i in 0..<(n * n) {
            let o = i * 4
            for c in 0..<3 { base[i * 3 + c] = Float(bs[o + c]) + gain * (Float(a[o + c]) - Float(ba[o + c])) }
        }
        var out = [UInt8](repeating: 255, count: n * n * 4)
        let sh = profile.sharpen, lc = profile.localContrast
        if sh > 0 || lc > 0 {
            /* The unsharp and clarity blurs run on the 8-bit merge (clamped), the result on the floats. */
            var b8 = [UInt8](repeating: 255, count: n * n * 4)
            for i in 0..<(n * n) { for c in 0..<3 { b8[i * 4 + c] = UInt8(max(0, min(255, base[i * 3 + c].rounded()))) } }
            let fine = sh > 0 ? blur(b8, n, radius: max(1, ratio / 2)) : b8
            let wide = lc > 0 ? blur(b8, n, radius: max(2, ratio * 6)) : b8
            for i in 0..<(n * n) {
                let o = i * 4
                for c in 0..<3 {
                    let v = base[i * 3 + c]
                    let f = v + sh * (Float(b8[o + c]) - Float(fine[o + c])) + lc * (Float(b8[o + c]) - Float(wide[o + c]))
                    out[o + c] = UInt8(max(0, min(255, f.rounded())))
                }
            }
        } else {
            for i in 0..<(n * n) { for c in 0..<3 { out[i * 4 + c] = UInt8(max(0, min(255, base[i * 3 + c].rounded()))) } }
        }
        /* The guards: no new straight line (a track: refused outright), no new dark sliver (a
           pole: tried once at half strength towards the plain photo, then refused). */
        let side = 256
        let gs = LineGuard.gray(rgba: s, width: n, height: n, to: side)
        let src = LineGuard.score(gs, width: side, height: side)
        func check(_ o: [UInt8]) -> (line: Bool, object: Bool, score: Float) {
            let ge = LineGuard.gray(rgba: o, width: n, height: n, to: side)
            let enh = LineGuard.score(ge, width: side, height: side)
            return (LineGuard.addsLine(enhanced: enh, source: src),
                    ObjectGuard.addsObject(enhanced: ge, source: gs, width: side, height: side), enh)
        }
        var c = check(out)
        var softened = false
        if !c.line && c.object {
            for i in 0..<(n * n) {
                let o = i * 4
                for k in 0..<3 { out[o + k] = UInt8((Float(s[o + k]) + 0.5 * (Float(out[o + k]) - Float(s[o + k]))).rounded()) }
            }
            softened = true
            c = check(out)
        }
        guard let img = cgImage(out, n) else { return nil }
        return Merged(image: img, addsLine: c.line, scores: (src, c.score), addsObject: c.object, softened: softened)
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
