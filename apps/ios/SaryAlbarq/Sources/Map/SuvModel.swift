import Foundation

/// The member's car on the map. The modelled expedition SUV (bundled `SuvExpedition.glb`,
/// built in Blender by scripts/suv/blender_suv.py from the CC0 "Offroader SUV") is painted per member at runtime (BODY material only);
/// this file's procedural car is the fallback.
///
/// Procedural fallback: the same low-poly overland 4×4 the web draws (port of `apps/web/src/lib/sary/suvModel.ts`):
/// boxy body, round headlights, black flares and bumpers, platform rack with a rolled awning,
/// spare on the tailgate. Built in code as a glTF 2.0 binary — same parts, same sizes, same
/// materials — so there is no third-party asset and the body takes each member's colour.
///
/// Units are metres; glTF axes: +Y up, +Z is the vehicle's nose, +X its left side.
enum SuvModel {
    typealias Vec3 = (Double, Double, Double)
    typealias Rgb = [Double]

    struct MaterialDef {
        var color: Rgb
        var metallic: Double
        var roughness: Double
        var emissive: Rgb?
    }

    struct Part {
        var positions: [Double] = []
        var normals: [Double] = []
        var indices: [Int] = []
    }

    /// Material order is the glTF material index order (body first), as on the web.
    static let materialNames = ["body", "glass", "trim", "tire", "rim", "awning", "indicator", "headlight", "taillight"]

    static let materials: [String: MaterialDef] = [
        "body": MaterialDef(color: [0.92, 0.93, 0.94], metallic: 0.25, roughness: 0.38),
        "glass": MaterialDef(color: [0.05, 0.07, 0.09], metallic: 0.5, roughness: 0.08),
        "trim": MaterialDef(color: [0.12, 0.12, 0.13], metallic: 0.1, roughness: 0.7),
        "tire": MaterialDef(color: [0.04, 0.04, 0.045], metallic: 0, roughness: 0.95),
        "rim": MaterialDef(color: [0.22, 0.23, 0.25], metallic: 0.7, roughness: 0.35),
        "awning": MaterialDef(color: [0.2, 0.2, 0.21], metallic: 0, roughness: 0.85),
        "indicator": MaterialDef(color: [1, 0.55, 0.08], metallic: 0, roughness: 0.3, emissive: [0.7, 0.35, 0.02]),
        "headlight": MaterialDef(color: [1, 0.97, 0.88], metallic: 0, roughness: 0.2, emissive: [1, 0.95, 0.8]),
        "taillight": MaterialDef(color: [0.75, 0.05, 0.05], metallic: 0, roughness: 0.3, emissive: [0.6, 0.02, 0.02]),
    ]

    // MARK: geometry primitives

    private static func normal(_ u: Vec3, _ v: Vec3) -> Vec3 {
        let n = (u.1 * v.2 - u.2 * v.1, u.2 * v.0 - u.0 * v.2, u.0 * v.1 - u.1 * v.0)
        let len = (n.0 * n.0 + n.1 * n.1 + n.2 * n.2).squareRoot()
        let l = len == 0 ? 1 : len
        return (n.0 / l, n.1 / l, n.2 / l)
    }

    private static func sub(_ a: Vec3, _ b: Vec3) -> Vec3 { (a.0 - b.0, a.1 - b.1, a.2 - b.2) }

    static func quad(_ p: inout Part, _ a: Vec3, _ b: Vec3, _ c: Vec3, _ d: Vec3) {
        let n = normal(sub(b, a), sub(d, a))
        let base = p.positions.count / 3
        for q in [a, b, c, d] {
            p.positions += [q.0, q.1, q.2]
            p.normals += [n.0, n.1, n.2]
        }
        p.indices += [base, base + 1, base + 2, base, base + 2, base + 3]
    }

    static func tri(_ p: inout Part, _ a: Vec3, _ b: Vec3, _ c: Vec3) {
        let n = normal(sub(b, a), sub(c, a))
        let base = p.positions.count / 3
        for q in [a, b, c] {
            p.positions += [q.0, q.1, q.2]
            p.normals += [n.0, n.1, n.2]
        }
        p.indices += [base, base + 1, base + 2]
    }

    /// A box whose top face can be smaller than its bottom (a cabin with raked pillars).
    static func frustum(_ p: inout Part, _ cx: Double, _ cz: Double, _ y0: Double, _ y1: Double, _ w0: Double, _ l0: Double, _ w1In: Double? = nil, _ l1In: Double? = nil, _ shift: Double = 0) {
        let w1 = w1In ?? w0, l1 = l1In ?? l0
        func b(_ sx: Double, _ sz: Double) -> Vec3 { (cx + sx * w0 / 2, y0, cz + sz * l0 / 2) }
        func t(_ sx: Double, _ sz: Double) -> Vec3 { (cx + sx * w1 / 2, y1, cz + shift + sz * l1 / 2) }
        quad(&p, t(-1, -1), t(-1, 1), t(1, 1), t(1, -1)) // top
        quad(&p, b(-1, -1), b(1, -1), b(1, 1), b(-1, 1)) // bottom
        quad(&p, b(-1, 1), b(1, 1), t(1, 1), t(-1, 1)) // front (+Z)
        quad(&p, b(1, -1), b(-1, -1), t(-1, -1), t(1, -1)) // back
        quad(&p, b(1, 1), b(1, -1), t(1, -1), t(1, 1)) // +X side
        quad(&p, b(-1, -1), b(-1, 1), t(-1, 1), t(-1, -1)) // -X side
    }

    static func box(_ p: inout Part, _ c: Vec3, _ s: Vec3) {
        frustum(&p, c.0, c.2, c.1 - s.1 / 2, c.1 + s.1 / 2, s.0, s.2)
    }

    /// A cylinder along X (a wheel) or along Z (the spare on the tailgate).
    static func cylinder(_ p: inout Part, _ c: Vec3, _ r: Double, _ width: Double, alongX: Bool, seg: Int = 18) {
        func ring(_ side: Double) -> [Vec3] {
            (0 ..< seg).map { i in
                let a = Double(i) / Double(seg) * Double.pi * 2
                let u = cos(a) * r, v = sin(a) * r
                return alongX ? (c.0 + side * width / 2, c.1 + v, c.2 + u) : (c.0 + u, c.1 + v, c.2 + side * width / 2)
            }
        }
        let A = ring(-1), B = ring(1)
        for i in 0 ..< seg {
            let j = (i + 1) % seg
            if alongX { quad(&p, A[i], A[j], B[j], B[i]) } else { quad(&p, A[j], A[i], B[i], B[j]) }
        }
        let capA: Vec3 = alongX ? (c.0 - width / 2, c.1, c.2) : (c.0, c.1, c.2 - width / 2)
        let capB: Vec3 = alongX ? (c.0 + width / 2, c.1, c.2) : (c.0, c.1, c.2 + width / 2)
        for i in 0 ..< seg {
            let j = (i + 1) % seg
            if alongX {
                tri(&p, capA, A[j], A[i])
                tri(&p, capB, B[i], B[j])
            } else {
                tri(&p, capA, A[i], A[j])
                tri(&p, capB, B[j], B[i])
            }
        }
    }

    // MARK: the vehicle

    /// Every part, grouped by material — identical to the web's `buildSuvParts()`.
    static func buildParts() -> [String: Part] {
        var body = Part(), glass = Part(), trim = Part(), tire = Part(), rim = Part()
        var awning = Part(), indicator = Part(), headlight = Part(), taillight = Part()
        let L = 4.8, W = 1.9, half = L / 2

        frustum(&body, 0, 0, 0.5, 1.12, W, L, W, L - 0.04)
        frustum(&body, 0, 1.38, 1.12, 1.17, W - 0.04, 1.95, W - 0.08, 1.9)
        frustum(&glass, 0, -0.62, 1.12, 1.82, W - 0.04, 3.5, W - 0.1, 3.3, -0.1)
        frustum(&body, 0, -0.72, 1.82, 1.9, W - 0.06, 3.32)
        for x in [-W / 2 + 0.02, W / 2 - 0.02] {
            for z in [1.02, 0.0, -1.05] { box(&trim, (x, 1.47, z), (0.05, 0.7, 0.1)) }
            box(&trim, (x, 1.15, -0.62), (0.05, 0.05, 3.4))
        }
        box(&trim, (0, 1.47, -2.36), (W - 0.1, 0.7, 0.06))

        box(&trim, (0, 0.86, half + 0.02), (W - 0.04, 0.42, 0.06))
        box(&trim, (0, 0.5, half + 0.12), (W + 0.08, 0.32, 0.26))
        box(&rim, (0, 0.3, half + 0.1), (1.0, 0.1, 0.24))
        box(&trim, (0, 0.52, -half - 0.08), (W + 0.04, 0.3, 0.18))

        for z in [1.5, -1.5] {
            for s in [-1.0, 1.0] {
                let x = s * (W / 2 + 0.07)
                box(&trim, (x, 0.98, z), (0.16, 0.08, 1.1))
                box(&trim, (x, 0.78, z + 0.53), (0.16, 0.36, 0.08))
                box(&trim, (x, 0.78, z - 0.53), (0.16, 0.36, 0.08))
            }
        }
        for s in [-1.0, 1.0] {
            box(&trim, (s * (W / 2 + 0.06), 0.4, 0), (0.18, 0.06, 1.9))
            box(&trim, (s * (W / 2 + 0.12), 1.28, 1.0), (0.1, 0.16, 0.22))
        }

        for x in [-0.82, 0.82] { box(&trim, (x, 2.0, -0.72), (0.06, 0.08, 3.1)) }
        for z in [0.78, -2.22] { box(&trim, (0, 2.0, z), (1.7, 0.08, 0.06)) }
        for i in 0 ..< 9 { box(&trim, (0, 2.0, 0.55 - Double(i) * 0.33), (1.6, 0.03, 0.06)) }
        for z in [0.7, -0.72, -2.14] { for x in [-0.8, 0.8] { box(&trim, (x, 1.94, z), (0.06, 0.1, 0.06)) } }
        box(&awning, (W / 2 + 0.02, 2.0, -0.72), (0.14, 0.14, 2.7))

        for s in [-1.0, 1.0] {
            cylinder(&headlight, (s * 0.68, 0.9, half + 0.06), 0.12, 0.04, alongX: false, seg: 16)
            box(&indicator, (s * 0.45, 0.82, half + 0.06), (0.1, 0.04, 0.03))
            box(&taillight, (s * 0.86, 1.0, -half - 0.01), (0.12, 0.34, 0.03))
        }

        for z in [1.5, -1.5] {
            for s in [-1.0, 1.0] {
                let x = s * (W / 2 - 0.02)
                cylinder(&tire, (x, 0.44, z), 0.44, 0.34, alongX: true)
                cylinder(&rim, (x + s * 0.02, 0.44, z), 0.22, 0.34, alongX: true, seg: 12)
            }
        }
        cylinder(&tire, (0.3, 1.0, -half - 0.17), 0.4, 0.28, alongX: false)
        cylinder(&rim, (0.3, 1.0, -half - 0.2), 0.2, 0.28, alongX: false, seg: 12)
        return ["body": body, "glass": glass, "trim": trim, "tire": tire, "rim": rim, "awning": awning,
                "indicator": indicator, "headlight": headlight, "taillight": taillight]
    }

    /// sRGB hex (0xRRGGBB) → linear RGB, since glTF `baseColorFactor` is linear.
    static func linear(_ rgb: UInt32) -> Rgb {
        [(rgb >> 16) & 0xFF, (rgb >> 8) & 0xFF, rgb & 0xFF].map { v in
            let c = Double(v) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
    }

    /// The whole vehicle as a .glb, body in `body` (0xRRGGBB).
    static func glb(body: UInt32 = 0xE8EEF0) -> Data {
        let parts = buildParts()
        var bin = Data()
        var bufferViews: [[String: Any]] = []
        var accessors: [[String: Any]] = []
        var primitives: [[String: Any]] = []

        func push(_ data: Data, target: Int) -> Int {
            let padded = (data.count + 3) / 4 * 4
            bufferViews.append(["buffer": 0, "byteOffset": bin.count, "byteLength": data.count, "target": target])
            bin.append(data)
            bin.append(Data(count: padded - data.count))
            return bufferViews.count - 1
        }
        func floats(_ v: [Double]) -> Data {
            var f = v.map { Float($0) }
            return Data(bytes: &f, count: f.count * 4)
        }

        for (mi, name) in materialNames.enumerated() {
            guard let p = parts[name], !p.indices.isEmpty else { continue }
            var mn = [Double.infinity, .infinity, .infinity], mx = [-Double.infinity, -.infinity, -.infinity]
            let pos32 = p.positions.map { Double(Float($0)) }
            for i in stride(from: 0, to: pos32.count, by: 3) {
                for k in 0 ..< 3 {
                    mn[k] = min(mn[k], pos32[i + k])
                    mx[k] = max(mx[k], pos32[i + k])
                }
            }
            let posView = push(floats(p.positions), target: 34962)
            let nrmView = push(floats(p.normals), target: 34962)
            var idx = p.indices.map { UInt16($0) }
            let idxView = push(Data(bytes: &idx, count: idx.count * 2), target: 34963)
            let count = p.positions.count / 3
            accessors.append(["bufferView": posView, "componentType": 5126, "count": count, "type": "VEC3", "min": mn, "max": mx])
            let posAcc = accessors.count - 1
            accessors.append(["bufferView": nrmView, "componentType": 5126, "count": count, "type": "VEC3"])
            let nrmAcc = accessors.count - 1
            accessors.append(["bufferView": idxView, "componentType": 5123, "count": p.indices.count, "type": "SCALAR"])
            primitives.append(["attributes": ["POSITION": posAcc, "NORMAL": nrmAcc], "indices": accessors.count - 1, "material": mi])
        }

        let mats: [[String: Any]] = materialNames.map { name in
            let m = materials[name]!
            let color = name == "body" ? linear(body) : m.color
            var out: [String: Any] = [
                "name": name,
                "pbrMetallicRoughness": ["baseColorFactor": color + [1], "metallicFactor": m.metallic, "roughnessFactor": m.roughness],
            ]
            if let e = m.emissive { out["emissiveFactor"] = e }
            return out
        }

        let gltf: [String: Any] = [
            "asset": ["version": "2.0", "generator": "sary-albarq suvModel"],
            "scene": 0,
            "scenes": [["nodes": [0]]],
            "nodes": [["mesh": 0, "name": "suv"]],
            "meshes": [["name": "suv", "primitives": primitives]],
            "materials": mats,
            "accessors": accessors,
            "bufferViews": bufferViews,
            "buffers": [["byteLength": bin.count]],
        ]
        var json = (try? JSONSerialization.data(withJSONObject: gltf, options: [.sortedKeys])) ?? Data()
        while json.count % 4 != 0 { json.append(0x20) }

        var out = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; out.append(Data(bytes: &x, count: 4)) }
        u32(0x4654_6C67) // "glTF"
        u32(2)
        u32(UInt32(12 + 8 + json.count + 8 + bin.count))
        u32(UInt32(json.count))
        u32(0x4E4F_534A) // "JSON"
        out.append(json)
        u32(UInt32(bin.count))
        u32(0x004E_4942) // "BIN\0"
        out.append(bin)
        return out
    }

    // MARK: the bundled expedition SUV (Resources/Models/SuvExpedition.glb)

    /// The modelled car (scripts/suv/build_suv.py): an original boxy expedition 4×4 with
    /// bevelled edges, a contact shadow and a light rim, styled to read like a navigation
    /// puck. The procedural car above stays as the fallback if the asset cannot be used.
    static let assetName = "SuvExpedition"
    /// Material that takes the member's colour, and the parts that stay black.
    static let bodyMaterial = "BODY"
    static let trimMaterial = "TRIM"
    static let rimMaterial = "RIM"

    static let trimHex: UInt32 = 0x1A1B1D
    /// Trim for a near-black body (#15191C): lifted to a graphite so flares, bumpers and the
    /// rack stay distinct from the paint, with brighter wheels as a contrasting edge.
    static let darkBodyTrimHex: UInt32 = 0x4A5058
    static let darkBodyRimHex: UInt32 = 0xB4BAC2

    /// sRGB relative luminance (0…1).
    static func luminance(_ rgb: UInt32) -> Double {
        let c = linear(rgb)
        return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]
    }

    /// A body this dark would melt into black trim.
    static func needsLightTrim(_ body: UInt32) -> Bool { luminance(body) < 0.03 }

    static func trim(for body: UInt32) -> UInt32 { needsLightTrim(body) ? darkBodyTrimHex : trimHex }

    static func bundledGlb(_ bundle: Bundle = .main) -> Data? {
        guard let url = bundle.url(forResource: assetName, withExtension: "glb") else { return nil }
        return try? Data(contentsOf: url)
    }

    /// The .glb with BODY painted `body` (and TRIM/RIM lifted for a near-black body). Only the
    /// JSON chunk changes; the binary chunk is copied as is. nil if it is not a glTF 2.0
    /// binary with a BODY material.
    static func recolored(_ glb: Data, body: UInt32) -> Data? {
        let b = [UInt8](glb)
        func u32(_ o: Int) -> Int? {
            guard o + 4 <= b.count else { return nil }
            return Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16 | Int(b[o + 3]) << 24
        }
        guard u32(0) == 0x4654_6C67, u32(4) == 2, let jsonLen = u32(12), u32(16) == 0x4E4F_534A,
              20 + jsonLen <= b.count,
              var gltf = (try? JSONSerialization.jsonObject(with: Data(b[20 ..< 20 + jsonLen]))) as? [String: Any],
              var mats = gltf["materials"] as? [[String: Any]] else { return nil }
        let rest = Data(b[(20 + jsonLen)...]) // BIN chunk header + payload
        func paint(_ name: String, _ rgb: UInt32) -> Bool {
            guard let i = mats.firstIndex(where: { $0["name"] as? String == name }) else { return false }
            var pbr = mats[i]["pbrMetallicRoughness"] as? [String: Any] ?? [:]
            let alpha = (pbr["baseColorFactor"] as? [Double])?.last ?? 1
            pbr["baseColorFactor"] = linear(rgb) + [alpha]
            mats[i]["pbrMetallicRoughness"] = pbr
            return true
        }
        guard paint(bodyMaterial, body) else { return nil }
        if needsLightTrim(body) {
            _ = paint(trimMaterial, darkBodyTrimHex)
            _ = paint(rimMaterial, darkBodyRimHex)
        }
        gltf["materials"] = mats
        guard var json = try? JSONSerialization.data(withJSONObject: gltf, options: [.sortedKeys]) else { return nil }
        while json.count % 4 != 0 { json.append(0x20) }
        var out = Data()
        func put(_ v: Int) { var x = UInt32(v).littleEndian; out.append(Data(bytes: &x, count: 4)) }
        put(0x4654_6C67)
        put(2)
        put(12 + 8 + json.count + rest.count)
        put(json.count)
        put(0x4E4F_534A)
        out.append(json)
        out.append(rest)
        return out
    }

    /// The car for one body colour: the modelled SUV, else the procedural one.
    static func modelData(body: UInt32, bundle: Bundle = .main) -> (data: Data, modelled: Bool) {
        if let src = bundledGlb(bundle), let painted = recolored(src, body: body) { return (painted, true) }
        return (glb(body: body), false)
    }

    /// Cache version of the modelled car: a hash of the bundled .glb, so a new asset in an app
    /// update never reuses an old cached file. The procedural fallback keeps a fixed version.
    static func geometryVersion(_ asset: Data) -> String {
        var h: UInt64 = 0xCBF2_9CE4_8422_2325
        for b in asset { h = (h ^ UInt64(b)) &* 0x100_0000_01B3 }
        return "x" + String(h, radix: 36)
    }

    static let fallbackGeometryVersion = "v1"

    /// A file URL for Mapbox's `addStyleModel`, one .glb per body colour, written once.
    static func fileURL(body: UInt32, bundle: Bundle = .main) -> URL? {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("sary-suv", isDirectory: true)
        let asset = bundledGlb(bundle)
        let painted = asset.flatMap { recolored($0, body: body) }
        let version = asset.map(geometryVersion) ?? fallbackGeometryVersion
        let url = dir.appendingPathComponent("\(Vehicle.modelId(body))-\(painted == nil ? fallbackGeometryVersion : version).glb")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try (painted ?? glb(body: body)).write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}
