import CoreLocation
import SwiftUI
import UIKit

/// The waypoint pins in the map's chip overlay (under the cars' chips), placed by
/// `WaypointLayout` each time the chips are laid out.
final class WaypointPins {
    var onTap: (String) -> Void = { _ in }
    /// A cluster was tapped: frame these points.
    var onClusterTap: ([LngLat]) -> Void = { _ in }
    private var items: [String: MapWaypoint] = [:]
    private var pins: [String: HostBox<MapWaypointPin>] = [:]
    private var labels: [String: HostBox<MapWaypointLabel>] = [:]
    private var clusters: [String: HostBox<MapWaypointCluster>] = [:]
    private(set) var last: WaypointLayout.Result?
    private var theme: SaryTheme = .default
    private weak var overlay: UIView?

    func set(_ list: [MapWaypoint], theme: SaryTheme, in overlay: UIView) {
        self.overlay = overlay
        let themeChanged = theme != self.theme
        self.theme = theme
        let ids = Set(list.map(\.id))
        for (id, b) in pins where !ids.contains(id) || themeChanged {
            b.removeFromSuperview()
            pins[id] = nil
            labels[id]?.removeFromSuperview()
            labels[id] = nil
        }
        if themeChanged { for b in clusters.values { b.removeFromSuperview() }; clusters = [:] }
        for w in list {
            let pin = MapWaypointPin(kind: w.kind, title: w.title, theme: theme) { [weak self] in self?.onTap(w.id) }
            let label = MapWaypointLabel(title: w.title, theme: theme)
            if let b = pins[w.id] { b.update(pin) } else {
                let b = HostBox(pin)
                overlay.insertSubview(b, at: 0)
                pins[w.id] = b
            }
            if let b = labels[w.id] { b.update(label) } else {
                let b = HostBox(label)
                b.isUserInteractionEnabled = false
                overlay.insertSubview(b, at: 0)
                labels[w.id] = b
            }
            items[w.id] = w
        }
        for id in items.keys where !ids.contains(id) { items[id] = nil }
    }

    /// Labels only from `labelMinZoom` (close in); the pins themselves always show.
    static let labelMinZoom = 14.5

    func layout(screen: (CLLocationCoordinate2D) -> CGPoint, bounds: CGRect, obstacles: [CGRect], zoom: Double = 20) {
        var input: [WaypointLayout.Item] = []
        for (id, w) in items {
            guard let pin = pins[id] else { continue }
            input.append(.init(id: id, anchor: screen(w.position.coordinate), pin: pin.ideal, label: labels[id]?.ideal))
        }
        var o = WaypointLayout.Options(bounds: bounds, obstacles: obstacles)
        o.showLabels = !theme.drive && zoom >= Self.labelMinZoom
        if theme.drive { o.clusterSize = CGSize(width: 56, height: 42) }
        let r = WaypointLayout.solve(input, o)
        last = r
        let shown = Set(r.pins.map(\.id))
        for (id, b) in pins { b.isHidden = !shown.contains(id) }
        for b in labels.values { b.isHidden = true }
        for p in r.pins {
            pins[p.id]?.frame = p.frame
            if let lf = p.labelFrame, let lb = labels[p.id] {
                lb.isHidden = false
                lb.frame = lf
            }
        }
        var live = Set<String>()
        for c in r.clusters {
            live.insert(c.key)
            let kinds = c.ids.compactMap { items[$0]?.kind }
            let pts = c.ids.compactMap { items[$0]?.position }
            let view = MapWaypointCluster(count: c.ids.count, kinds: kinds, theme: theme) { [weak self] in self?.onClusterTap(pts) }
            let box: HostBox<MapWaypointCluster>
            if let b = clusters[c.key] { b.update(view); box = b } else {
                box = HostBox(view)
                overlay?.insertSubview(box, at: 0)
                clusters[c.key] = box
            }
            box.isHidden = false
            box.frame = CGRect(x: c.anchor.x - box.ideal.width / 2, y: c.anchor.y - box.ideal.height, width: box.ideal.width, height: box.ideal.height)
        }
        for (k, b) in clusters where !live.contains(k) {
            b.removeFromSuperview()
            clusters[k] = nil
        }
    }

    /// What the pins cover now, for the Mapbox ornaments.
    var frames: [CGRect] { last?.frames ?? [] }
}

/// One waypoint on the map: the kind's glyph on a short stem; the tip is the spot.
struct MapWaypointPin: View, Equatable {
    let kind: WaypointKind
    let title: String
    let theme: SaryTheme
    var onTap: () -> Void

    static func == (a: MapWaypointPin, b: MapWaypointPin) -> Bool { a.kind == b.kind && a.title == b.title && a.theme == b.theme }

    var body: some View {
        let size: CGFloat = theme.drive ? 40 : 30
        Button(action: onTap) {
            VStack(spacing: -2) {
                SaryWaypointGlyph(kind: kind, size: size)
                    .saryShadow(.raised, theme)
                PinStem().fill(kind.color(theme.palette)).frame(width: 10, height: 8)
            }
            .padding(.horizontal, 2)
        }
        .buttonStyle(SaryPressStyle())
        .saryTheme(theme)
        .accessibilityLabel(Text("نقطة \(kind.label): \(title)"))
        .accessibilityIdentifier("map.waypoint")
    }
}

struct MapWaypointLabel: View, Equatable {
    let title: String
    let theme: SaryTheme

    var body: some View {
        Text(title.count > 18 ? String(title.prefix(17)) + "…" : title)
            .saryText(.micro, weight: .bold)
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(theme.palette.textPrimary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(theme.palette.chromeOpaque.opacity(0.9)))
            .saryTheme(theme)
            .accessibilityHidden(true)
    }
}

/// Pins folded together: up to three kind dots and the count.
struct MapWaypointCluster: View, Equatable {
    let count: Int
    let kinds: [WaypointKind]
    let theme: SaryTheme
    var onTap: () -> Void

    static func == (a: MapWaypointCluster, b: MapWaypointCluster) -> Bool { a.count == b.count && a.kinds == b.kinds && a.theme == b.theme }

    var body: some View {
        let p = theme.palette
        Button(action: onTap) {
            HStack(spacing: 4) {
                HStack(spacing: -6) {
                    ForEach(Array(kinds.prefix(3).enumerated()), id: \.offset) { _, k in
                        SaryWaypointGlyph(kind: k, size: theme.drive ? 26 : 20)
                    }
                }
                Text(SaryFormat.number(count)).saryNumber(.footnote, weight: .bold).foregroundStyle(p.textPrimary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(Capsule().fill(p.chromeOpaque.opacity(0.94)))
            .overlay(Capsule().strokeBorder(p.stroke, lineWidth: 0.5))
            .saryShadow(.raised, theme)
        }
        .buttonStyle(SaryPressStyle())
        .saryTheme(theme)
        .accessibilityLabel(Text("\(SaryFormat.number(count)) نقاط متقاربة، اضغط للتقريب"))
        .accessibilityIdentifier("map.waypoint.cluster")
    }
}

private struct PinStem: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}
