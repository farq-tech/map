import UIKit

/// The member's car as a 2D icon (map marker and list badge), painted in the member's colour.
///
/// Rendered in Blender Cycles from the CC0 "Offroader SUV", restyled (scripts/suv/blender_suv.py,
/// baked by scripts/suv/bake_icons.py): clear-coat paint, studio softbox + rim lights, soft
/// contact shadow, light outline; no logo or badge, no reference pixels.
///
/// The ten member colours ship pre-rendered (`CarIcon-<hex>.png`; the near-black one with
/// graphite trim). Any other colour is painted from two layers: `CarIconBase.png` (everything
/// that is not paint, outline and shadow; premultiplied) and `CarIconBody.png` (R = diffuse
/// factor D, G = reflection K, both sRGB-encoded; B = paint coverage), from renders with white
/// and black paint: paint (linear) = colour • D + K, then sRGB, over the base.
enum CarIcon {
    static let baseName = "CarIconBase"
    static let bodyName = "CarIconBody"
    /// Point size: the masters are 200×360 px drawn at this scale (50×90 pt at icon-size 1).
    static let imageScale: CGFloat = 4

    /// Mapbox image id per colour: `sary-car-d6452f`.
    static func imageId(_ rgb: UInt32) -> String { "sary-car-" + Vehicle.hex(rgb) }

    /// `icon-size` by zoom: a constant ~38 pt car on screen up to street zoom, then it grows
    /// towards its true size (never tiny, never covering a block).
    static let sizeStops: [(zoom: Double, size: Double)] = [(10, 0.52), (16.5, 0.52), (18, 0.64), (19, 0.85), (20, 1.05), (22, 1.3)]

    static var sizeExpression: [Any] {
        var e: [Any] = ["interpolate", ["linear"], ["zoom"]]
        for s in sizeStops { e += [s.zoom, s.size] }
        return e
    }

    /// The art faces north (nose up), so `icon-rotate` is the compass heading itself.
    static func rotate(_ heading: Double?) -> Double {
        let h = heading.flatMap { $0.isFinite ? $0 : nil } ?? 0
        return (h.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
    }

    // MARK: painting

    struct Layers {
        var width: Int
        var height: Int
        /// Premultiplied RGBA.
        var base: [UInt8]
        /// RGBA from an opaque image: R = D, G = K, B = coverage.
        var body: [UInt8]
    }

    static func decode(_ v: UInt8) -> Double {
        let c = Double(v) / 255
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    static func encode(_ c: Double) -> Double {
        let x = min(1, max(0, c))
        return x <= 0.0031308 ? x * 12.92 : 1.055 * pow(x, 1 / 2.4) - 0.055
    }

    /// The renderer's tone curve (Cycles "Standard" view transform: none, just the clamp).
    static func tone(_ c: Double) -> Double { c }

    /// File name of a pre-rendered member colour.
    static func renderedName(_ rgb: UInt32) -> String { "CarIcon-" + Vehicle.hex(rgb) }

    static func rendered(_ rgb: UInt32, bundle: Bundle = .main) -> UIImage? {
        guard let url = bundle.url(forResource: renderedName(rgb), withExtension: "png"),
              let cg = UIImage(contentsOfFile: url.path)?.cgImage else { return nil }
        return UIImage(cgImage: cg, scale: imageScale, orientation: .up)
    }

    /// Premultiplied RGBA of the car in `rgb` — the same maths as `compose()` in bake_icons.py.
    static func paint(_ l: Layers, color rgb: UInt32) -> [UInt8] {
        let lin = SuvModel.linear(rgb)
        var dec = [Double](repeating: 0, count: 256)
        for i in 0 ..< 256 { dec[i] = decode(UInt8(i)) }
        var out = [UInt8](repeating: 0, count: l.width * l.height * 4)
        for i in 0 ..< l.width * l.height {
            let o = i * 4
            let m = Double(l.body[o + 2]) / 255
            let a0 = Double(l.base[o + 3]) / 255
            let alpha = m + a0 * (1 - m)
            guard alpha > 0 else { continue }
            let d = dec[Int(l.body[o])], k = dec[Int(l.body[o + 1])]
            for c in 0 ..< 3 {
                let p = m > 0 ? encode(tone(lin[c] * d + k)) : 0
                let v = p * m + Double(l.base[o + c]) / 255 * (1 - m) // base is premultiplied
                out[o + c] = UInt8(min(255, max(0, (v * 255).rounded())))
            }
            out[o + 3] = UInt8(min(255, max(0, (alpha * 255).rounded())))
        }
        return out
    }

    // MARK: images

    static func rgba(_ image: CGImage, premultiplied: Bool) -> (Int, Int, [UInt8])? {
        let w = image.width, h = image.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let info = premultiplied ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        let ok = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? (w, h, px) : nil
    }

    static func loadLayers(_ bundle: Bundle = .main) -> Layers? {
        guard let bu = bundle.url(forResource: baseName, withExtension: "png"),
              let pu = bundle.url(forResource: bodyName, withExtension: "png"),
              let b = UIImage(contentsOfFile: bu.path)?.cgImage, let p = UIImage(contentsOfFile: pu.path)?.cgImage,
              let base = rgba(b, premultiplied: true), let body = rgba(p, premultiplied: false),
              base.0 == body.0, base.1 == body.1 else { return nil }
        return Layers(width: base.0, height: base.1, base: base.2, body: body.2)
    }

    private static var cachedLayers: Layers?
    private static var cache: [UInt32: UIImage] = [:]

    /// The member's car: pre-rendered for the ten member colours, else painted from the layers;
    /// nil if neither is bundled (then the map uses the 3D model).
    static func image(_ rgb: UInt32, bundle: Bundle = .main) -> UIImage? {
        if bundle == .main, let hit = cache[rgb] { return hit }
        if let r = rendered(rgb, bundle: bundle) {
            if bundle == .main { cache[rgb] = r }
            return r
        }
        let p = painted(rgb, bundle: bundle)
        if bundle == .main, let p { cache[rgb] = p }
        return p
    }

    /// The car painted from the two layers (any colour).
    static func painted(_ rgb: UInt32, bundle: Bundle = .main) -> UIImage? {
        guard let l = bundle == .main ? (cachedLayers ?? loadLayers(bundle)) : loadLayers(bundle) else { return nil }
        if bundle == .main { cachedLayers = l }
        var px = paint(l, color: rgb)
        let img: UIImage? = px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: l.width, height: l.height, bitsPerComponent: 8, bytesPerRow: l.width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let cg = ctx.makeImage() else { return nil }
            return UIImage(cgImage: cg, scale: imageScale, orientation: .up)
        }
        return img
    }
}
