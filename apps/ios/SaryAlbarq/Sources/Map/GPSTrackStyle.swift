import SwiftUI
import UIKit
@_spi(Experimental) import MapboxMaps

/// «أثري (GPS)»: the one definition of how a GPS track (an imported / saved / followed «أثر») is drawn on every map:
/// the outing map while following a track, the track detail and «اسلك هذا المسار» screen, and the track library
/// in exploration. Thin, an neon aqua that no road, dirt-track overlay, navigation route or participant
/// trail uses, a thin dark-teal edge, a semi-transparent core (the street and dirt-track detail stays readable
/// through it) and small direction chevrons. No glow, no wide fill.
/// The recorded car trail («مساري») keeps its own style (`TrackLineStyle` default) and is not part of this.
enum GPSTrackStyle {
    // MARK: Colours (the only place they are defined)
    static let coreRGB: UInt32 = 0x00FFE0
    static let edgeRGB: UInt32 = 0x052E38
    static let core = hex(coreRGB)
    static let edge = hex(edgeRGB)
    static func hex(_ rgb: UInt32) -> String { String(format: "#%06X", rgb) }

    // MARK: Geometry (points at zoom 14; scaled by `width(_:)`)
    static let coreWidth = 2.6
    /// Extra width of the dark edge over the core (both sides together): ≈1 pt each side.
    static let edgeExtra = 2.0
    static let coreOpacity = 0.88
    static let edgeOpacity = 0.62
    /// Chevron spacing along the line, in points.
    static let chevronSpacing = 56.0
    static let chevronImage = "sary-gps-chevron"
    /// «أثري (GPS)» in the legend / VoiceOver.
    static let legendTitle = "أثري (GPS)"
    static let legendDetail = "خط رفيع فيروزي نيون بأسهم اتجاه: أثر GPS محفوظ أو مستورد"

    /// Line width in points for `k` points at zoom 14: gentle growth, so it stays narrow when zoomed in.
    static func width(_ k: Double) -> [Any] {
        ["interpolate", ["linear"], ["zoom"], 8, k * 0.5, 14, k, 18, k * 1.3, 20, k * 1.5]
    }

    /// Colours the track must stay away from (roads, dirt-track overlay, navigation route and its surfaces,
    /// traffic bands, the car trail's speed ramp). `GPSTrackStyleTests` checks the distance.
    static var avoided: [(name: String, rgb: UInt32)] {
        var out: [(String, UInt32)] = [
            ("osm tracks unpaved", 0xD9AD6C), ("osm tracks paved", 0xEFE6D2), ("osm tracks unknown", 0xC99A5A),
            ("nav blue", SaryPalette.navBlueDay), ("nav dirt", NavMapDrawer.SurfaceStyle.dirtRGB),
            ("nav off-road", NavMapDrawer.SurfaceStyle.offRoadRGB), ("nav unknown", NavMapDrawer.SurfaceStyle.unknownRGB),
            ("traffic slow", 0xF08A24), ("traffic heavy", 0xE0362C), ("traffic standstill", 0x8E1B1B),
        ]
        out += TrackGradient.ramp.enumerated().map { ("car trail ramp \($0.offset)", $0.element.rgb) }
        return out
    }

    /// Representative ground under the track: sand, city asphalt and concrete, green, dark night.
    static let grounds: [(name: String, rgb: UInt32)] = [
        ("sand", 0xD2B48C), ("warm sand grade", 0xC9A878), ("city concrete", 0xB8B8B8), ("city asphalt", 0x6E6E70),
        ("green", 0x5E7A45), ("night", 0x0D141C),
    ]

    // MARK: CIE76 colour distance and edge contrast
    static func lab(_ rgb: UInt32) -> (l: Double, a: Double, b: Double) {
        func lin(_ v: UInt32) -> Double {
            let c = Double(v) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let r = lin((rgb >> 16) & 0xFF), g = lin((rgb >> 8) & 0xFF), b = lin(rgb & 0xFF)
        let x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047
        let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883
        func f(_ t: Double) -> Double { t > 0.008856 ? cbrt(t) : 7.787 * t + 16.0 / 116 }
        return (116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z)))
    }

    static func distance(_ a: UInt32, _ b: UInt32) -> Double {
        let p = lab(a), q = lab(b)
        return ((p.l - q.l) * (p.l - q.l) + (p.a - q.a) * (p.a - q.a) + (p.b - q.b) * (p.b - q.b)).squareRoot()
    }

    /// The best contrast the track offers against `ground`: its core, or its dark edge around the core.
    static func contrast(on ground: UInt32) -> Double {
        max(SaryContrast.ratio(coreRGB, ground), SaryContrast.ratio(edgeRGB, ground))
    }

    // MARK: Layers
    /// Chevron pointing along the line (drawn once per style load; the same id replaces the image).
    static func chevron() -> UIImage {
        let s: CGFloat = 24
        return UIGraphicsImageRenderer(size: CGSize(width: s, height: s)).image { _ in
            let p = UIBezierPath()
            p.move(to: CGPoint(x: 6, y: 4))
            p.addLine(to: CGPoint(x: 19, y: s / 2))
            p.addLine(to: CGPoint(x: 6, y: s - 4))
            p.lineCapStyle = .round
            p.lineJoinStyle = .round
            p.lineWidth = 6
            UIColor(red: 5.0 / 255, green: 46.0 / 255, blue: 56.0 / 255, alpha: 0.8).setStroke()
            p.stroke()
            p.lineWidth = 3
            UIColor.white.setStroke()
            p.stroke()
        }
    }

    static func addImages(_ m: MapboxMap) { try? m.addImage(chevron(), id: chevronImage) }

    static func chevronLayer(id: String, source: String) -> [String: Any] {
        ["id": id, "type": "symbol", "source": source, "minzoom": 11,
         "layout": ["symbol-placement": "line", "symbol-spacing": chevronSpacing, "icon-image": chevronImage,
                    "icon-size": ["interpolate", ["linear"], ["zoom"], 11, 0.4, 14, 0.5, 18, 0.62],
                    "icon-rotation-alignment": "map", "icon-pitch-alignment": "map",
                    "icon-allow-overlap": true, "icon-ignore-placement": true] as [String: Any],
         "paint": ["icon-opacity": 0.95, "icon-emissive-strength": 1] as [String: Any]]
    }
}

/// One line naming the GPS track line: its swatch and «أثري (GPS)» (the follow panel).
struct GPSTrackLegend: View {
    @Environment(\.sary) private var theme

    var body: some View {
        HStack(spacing: 6) {
            ZStack {
                Capsule().fill(Color(rgb: GPSTrackStyle.edgeRGB).opacity(0.8)).frame(width: 28, height: 6)
                Capsule().fill(Color(rgb: GPSTrackStyle.coreRGB)).frame(width: 26, height: 3)
                Image(systemName: "chevron.forward").font(.system(size: 6, weight: .heavy)).foregroundStyle(.white)
            }
            .accessibilityHidden(true)
            Text(GPSTrackStyle.legendTitle)
                .saryText(.caption, weight: .medium)
                .foregroundStyle(theme.palette.textSecondary)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(GPSTrackStyle.legendTitle))
        .accessibilityIdentifier("follow.legend")
    }
}
