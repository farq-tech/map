#if DEBUG
import CoreGraphics
import simd
import SwiftUI
import UIKit

/// Procedural desert "satellite" terrain for the showcase map stage: linear
/// (seif) dunes with warped crests, gravel flats, scattered shrubs and a
/// hill-shade from the north-west. Generated in code — no downloaded imagery.
enum DesertTerrain {
    enum Variant { case day, night }

    private static var cache: [String: UIImage] = [:]
    private static let lock = NSLock()

    static func image(width: Int = 430, height: Int = 932, variant: Variant, seed: Int32 = 7) -> UIImage {
        let key = "\(width)x\(height)-\(variant)-\(seed)"
        lock.lock(); defer { lock.unlock() }
        if let c = cache[key] { return c }
        let img = render(width: width, height: height, variant: variant, seed: seed)
        cache[key] = img
        return img
    }

    // MARK: Noise

    @inline(__always) private static func hash(_ x: Int32, _ y: Int32, _ s: Int32) -> Float {
        var h = UInt32(bitPattern: x &* 374_761_393 &+ y &* 668_265_263 &+ s &* 1_442_695_041)
        h = (h ^ (h >> 13)) &* 1_274_126_177
        h ^= h >> 16
        return Float(h & 0xFFFFFF) / Float(0xFFFFFF)
    }

    @inline(__always) private static func noise(_ x: Float, _ y: Float, _ s: Int32) -> Float {
        let xi = Int32(floorf(x)), yi = Int32(floorf(y))
        let xf = x - floorf(x), yf = y - floorf(y)
        let u = xf * xf * (3 - 2 * xf), v = yf * yf * (3 - 2 * yf)
        let a = hash(xi, yi, s), b = hash(xi + 1, yi, s)
        let c = hash(xi, yi + 1, s), d = hash(xi + 1, yi + 1, s)
        return (a + (b - a) * u) + ((c + (d - c) * u) - (a + (b - a) * u)) * v
    }

    private static func fbm(_ x: Float, _ y: Float, _ s: Int32, octaves: Int = 4) -> Float {
        var amp: Float = 0.5, f: Float = 1, sum: Float = 0, norm: Float = 0
        for o in 0..<octaves {
            sum += amp * noise(x * f, y * f, s &+ Int32(o) &* 17)
            norm += amp
            amp *= 0.5
            f *= 2.03
        }
        return sum / norm
    }

    // MARK: Render

    private static func render(width w: Int, height h: Int, variant: Variant, seed: Int32) -> UIImage {
        // Height map
        var height = [Float](repeating: 0, count: w * h)
        let angle: Float = 0.42
        let ca = cosf(angle), sa = sinf(angle)
        for y in 0..<h {
            for x in 0..<w {
                let fx = Float(x), fy = Float(y)
                let u = fx * ca + fy * sa
                let v = -fx * sa + fy * ca
                let warp = fbm(v * 0.006, u * 0.004, seed, octaves: 3) * 9
                let ridgeRaw = sinf(u * 0.045 + warp)
                let ridge = powf(1 - fabsf(ridgeRaw), 2.2)
                let broad = fbm(fx * 0.004, fy * 0.004, seed &+ 3, octaves: 3)
                let fine = fbm(fx * 0.05, fy * 0.05, seed &+ 9, octaves: 2)
                height[y * w + x] = 0.55 * ridge * (0.6 + 0.6 * broad) + 0.3 * broad + 0.05 * fine
            }
        }

        // Colour ramp
        let dayLow: SIMD3<Float> = [0.70, 0.52, 0.36]
        let dayMid: SIMD3<Float> = [0.86, 0.69, 0.49]
        let dayHigh: SIMD3<Float> = [0.95, 0.84, 0.66]
        let gravel: SIMD3<Float> = [0.56, 0.47, 0.38]
        let nightTint: SIMD3<Float> = [0.20, 0.22, 0.30]

        var px = [UInt8](repeating: 255, count: w * h * 4)
        let light = simd_normalize(SIMD3<Float>(-0.55, -0.65, 0.55))
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                let hx = height[y * w + min(x + 1, w - 1)] - height[y * w + max(x - 1, 0)]
                let hy = height[min(y + 1, h - 1) * w + x] - height[max(y - 1, 0) * w + x]
                let n = simd_normalize(SIMD3<Float>(-hx * 6, -hy * 6, 1))
                let shade = max(0, simd_dot(n, light))
                let t = min(max(height[i], 0), 1)
                var c = t < 0.45
                    ? simd_mix(dayLow, dayMid, SIMD3(repeating: t / 0.45))
                    : simd_mix(dayMid, dayHigh, SIMD3(repeating: (t - 0.45) / 0.55))
                // Gravel flats in the dune corridors
                let flat = fbm(Float(x) * 0.008, Float(y) * 0.008, seed &+ 21, octaves: 3)
                let gravelMask = max(0, min(1, (flat - 0.58) * 6)) * max(0, 1 - t * 2.2)
                c = simd_mix(c, gravel, SIMD3(repeating: gravelMask * 0.8))
                // Grain
                let grain = (hash(Int32(x), Int32(y), seed &+ 5) - 0.5) * 0.05
                c *= (0.62 + 0.55 * shade) + grain
                // Shrubs (dark specks in corridors)
                if hash(Int32(x / 2), Int32(y / 2), seed &+ 77) > 0.9965 && t < 0.4 {
                    c = [0.33, 0.30, 0.20]
                }
                if variant == .night { c = c * nightTint * 1.15 + SIMD3(repeating: 0.012) }
                px[i * 4 + 0] = UInt8(max(0, min(255, c.x * 255)))
                px[i * 4 + 1] = UInt8(max(0, min(255, c.y * 255)))
                px[i * 4 + 2] = UInt8(max(0, min(255, c.z * 255)))
                px[i * 4 + 3] = 255
            }
        }

        let data = Data(px) as CFData
        let cg = CGImage(
            width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: CGDataProvider(data: data)!, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )!
        return UIImage(cgImage: cg)
    }
}

/// Terrain + a dirt track, filling its frame. Night mode swaps the image.
struct DesertTerrainView: View {
    @Environment(\.sary) private var theme
    var body: some View {
        GeometryReader { g in
            ZStack {
                Image(uiImage: DesertTerrain.image(variant: theme.night ? .night : .day))
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .frame(width: g.size.width, height: g.size.height)
                    .clipped()
                Canvas { ctx, size in
                    var track = Path()
                    track.move(to: CGPoint(x: size.width * 0.08, y: size.height * 1.02))
                    track.addCurve(to: CGPoint(x: size.width * 0.55, y: size.height * 0.48),
                                   control1: CGPoint(x: size.width * 0.32, y: size.height * 0.8),
                                   control2: CGPoint(x: size.width * 0.28, y: size.height * 0.58))
                    track.addCurve(to: CGPoint(x: size.width * 0.98, y: size.height * -0.02),
                                   control1: CGPoint(x: size.width * 0.8, y: size.height * 0.4),
                                   control2: CGPoint(x: size.width * 0.75, y: size.height * 0.15))
                    let edge = theme.night ? Color(rgb: 0x262833) : Color(rgb: 0x8A6E52)
                    let core = theme.night ? Color(rgb: 0x3A3D4A) : Color(rgb: 0xEBD9BE)
                    ctx.stroke(track, with: .color(edge.opacity(0.7)), style: StrokeStyle(lineWidth: 9, lineCap: .round))
                    ctx.stroke(track, with: .color(core.opacity(0.9)), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                }
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}
#endif
