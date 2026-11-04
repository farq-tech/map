import CoreGraphics
import Foundation

/// Web-Mercator camera fitted to the visible trail, and the projection that puts
/// a coordinate on the map card. Mapbox renders 512-point tiles, so with pitch 0
/// and bearing 0 this is exactly where the snapshot draws a coordinate.
struct StoryCamera: Equatable {
    var centerLng: Double
    var centerLat: Double
    var zoom: Double
    /// Map card size in points (pixels ÷ `pixelRatio`).
    var sizePt: CGSize
    var pixelRatio: CGFloat

    static let minZoom = 3.0
    /// Beyond this the satellite imagery gets soft; a short trail just sits smaller.
    static let maxZoom = 15.2

    static func mercX(_ lng: Double) -> Double { (lng + 180) / 360 }
    static func mercY(_ lat: Double) -> Double {
        let s = sin(max(-85.0511, min(85.0511, lat)) * .pi / 180)
        return 0.5 - log((1 + s) / (1 - s)) / (4 * .pi)
    }
    static func lat(fromMercY y: Double) -> Double {
        let n = .pi - 2 * .pi * y
        return 180 / .pi * atan(0.5 * (exp(n) - exp(-n)))
    }

    var worldPt: Double { 512 * pow(2, zoom) }

    /// Map-local pixel position of a coordinate.
    func pixel(_ p: LngLat) -> CGPoint {
        let w = worldPt
        let x = (Self.mercX(p.lng) - Self.mercX(centerLng)) * w + sizePt.width / 2
        let y = (Self.mercY(p.lat) - Self.mercY(centerLat)) * w + sizePt.height / 2
        return CGPoint(x: x * pixelRatio, y: y * pixelRatio)
    }

    /// Fit `points` into `frame` (map-local pixels) of a map card `mapPx` big.
    static func fit(_ points: [LngLat], frame: CGRect, mapPx: CGSize, pixelRatio: CGFloat = 2) -> StoryCamera? {
        guard !points.isEmpty else { return nil }
        let xs = points.map { mercX($0.lng) }, ys = points.map { mercY($0.lat) }
        let minX = xs.min()!, maxX = xs.max()!, minY = ys.min()!, maxY = ys.max()!
        let fw = Double(frame.width / pixelRatio), fh = Double(frame.height / pixelRatio)
        let dx = max(maxX - minX, 1e-9), dy = max(maxY - minY, 1e-9)
        let z = max(minZoom, min(maxZoom, log2(min(fw / (dx * 512), fh / (dy * 512)))))
        let world = 512 * pow(2, z)
        /* The frame may sit off-centre in the card (photos below): shift the camera to match. */
        let offX = Double((frame.midX - mapPx.width / 2) / pixelRatio) / world
        let offY = Double((frame.midY - mapPx.height / 2) / pixelRatio) / world
        let cx = (minX + maxX) / 2 - offX
        let cy = (minY + maxY) / 2 - offY
        return StoryCamera(centerLng: cx * 360 - 180, centerLat: lat(fromMercY: cy), zoom: z,
                           sizePt: CGSize(width: mapPx.width / pixelRatio, height: mapPx.height / pixelRatio), pixelRatio: pixelRatio)
    }
}

/// Timing of the short video: hold, the trail draws itself, hold on the finished story.
struct StoryVideoTiming: Equatable {
    var fps: Int32 = 30
    var duration: Double = 7.0
    /// The map and the numbers alone first.
    var intro: Double = 0.7
    /// The trail drawing itself.
    var draw: Double = 4.6

    var frameCount: Int { Int((duration * Double(fps)).rounded()) }

    /// Presentation time of frame `i`, in seconds (exact: i / fps).
    func seconds(_ i: Int) -> Double { Double(i) / Double(fps) }

    /// How much of the trail is drawn at frame `i` (0…1), eased in and out.
    func progress(_ i: Int) -> Double {
        let t = (seconds(i) - intro) / draw
        if t <= 0 { return 0 }
        if t >= 1 { return 1 }
        return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }

    /// The end marker / final details fade in after the line is done (0…1 over 0.4 s).
    func finale(_ i: Int) -> Double {
        let t = (seconds(i) - intro - draw) / 0.4
        return max(0, min(1, t))
    }
}

/// Lengths along a polyline in pixels, to draw "the first x %" of it.
struct StoryPolyline {
    struct Seg { var a: CGPoint; var b: CGPoint; var dashed: Bool; var startLen: CGFloat; var len: CGFloat }
    var segs: [Seg] = []
    var total: CGFloat = 0
    /// Per run: (first segment index, last segment index, fade at start, fade at end).
    var runs: [(first: Int, last: Int, fadeStart: Bool, fadeEnd: Bool)] = []

    init(runs input: [(points: [CGPoint], gaps: [Bool], fadeStart: Bool, fadeEnd: Bool)]) {
        for r in input where r.points.count >= 2 {
            let first = segs.count
            for i in 1..<r.points.count {
                let a = r.points[i - 1], b = r.points[i]
                let l = hypot(b.x - a.x, b.y - a.y)
                segs.append(Seg(a: a, b: b, dashed: r.gaps[i], startLen: total, len: l))
                total += l
            }
            runs.append((first, segs.count - 1, r.fadeStart, r.fadeEnd))
        }
    }

    /// The point `len` pixels along (for the moving head of the line).
    func point(at len: CGFloat) -> CGPoint? {
        guard let last = segs.last else { return nil }
        for s in segs where s.startLen + s.len >= len {
            let u = s.len > 0 ? (len - s.startLen) / s.len : 0
            return CGPoint(x: s.a.x + (s.b.x - s.a.x) * u, y: s.a.y + (s.b.y - s.a.y) * u)
        }
        return last.b
    }
}
