@_spi(Experimental) import MapboxMaps
import SwiftUI
import UIKit

/// The planned route, destination and a long-pressed point, as plain data for a map.
struct MapPlan: Equatable {
    var route: [LngLat] = []
    var destination: OutingDestination?
    /// The long-pressed / searched point being looked at (a small pin).
    var picked: LngLat?
    /// «اتبع الخطة»: drawn a little bolder.
    var emphasised = false

    var isEmpty: Bool { route.count < 2 && destination == nil && picked == nil }
}

/// The planned route's look, shared by the live map and the plan editor: a DASHED
/// line in its own colour (trails are solid in car colours), with a contrasting casing.
enum PlanMapStyle {
    static let source = "sary-plan"
    static let casing = "sary-plan-casing"
    static let line = "sary-plan-line"
    /// Blue-violet: not a car colour, not the orange «مساري», reads on sand and at night.
    static let color: UInt32 = 0x4C6FFF

    static func ensureLayers(_ m: MapboxMap, emphasised: Bool, night: Bool) {
        if !m.sourceExists(withId: source) {
            var s = GeoJSONSource(id: source)
            s.data = .featureCollection(FeatureCollection(features: []))
            try? m.addSource(s)
        }
        let width = emphasised ? 6.0 : 4.5
        if m.layerExists(withId: casing) { try? m.removeLayer(withId: casing) }
        if m.layerExists(withId: line) { try? m.removeLayer(withId: line) }
        var c = LineLayer(id: casing, source: source)
        c.lineColor = .constant(StyleColor(night ? UIColor(white: 0.05, alpha: 1) : .white))
        c.lineWidth = .constant(width + 3)
        c.lineOpacity = .constant(0.85)
        c.lineJoin = .constant(.round)
        c.lineCap = .constant(.round)
        c.lineEmissiveStrength = .constant(1)
        var l = LineLayer(id: line, source: source)
        l.lineColor = .constant(StyleColor(UIColor(rgb: color)))
        l.lineWidth = .constant(width)
        l.lineDasharray = .constant([1.6, 1.1])
        l.lineJoin = .constant(.round)
        l.lineEmissiveStrength = .constant(1)
        try? m.addLayer(c)
        try? m.addLayer(l)
    }

    static func update(_ m: MapboxMap, route: [LngLat]) {
        let feats: [Feature] = route.count >= 2 ? [Feature(geometry: .lineString(LineString(route.map(\.coordinate))))] : []
        m.updateGeoJSONSource(withId: source, geoJSON: .featureCollection(FeatureCollection(features: feats)))
    }
}

/* `UIColor(rgb:)` is declared once, in Story/StoryRenderer.swift. */

/// «الوجهة» on the map: a chequered flag in the plan's colour (distinct from the rally flag).
struct PlanDestinationPin: View {
    var name: String
    let theme: SaryTheme
    var onTap: () -> Void = {}

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 2) {
                Text(name)
                    .saryText(.caption, weight: .bold)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Capsule().fill(Color(UIColor(rgb: PlanMapStyle.color))))
                    .overlay(Capsule().strokeBorder(.white.opacity(0.9), lineWidth: 1.5))
                Image(systemName: "flag.checkered.circle.fill")
                    .font(.system(size: 30, weight: .bold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color(UIColor(rgb: PlanMapStyle.color)))
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
            }
            .frame(maxWidth: 180)
        }
        .buttonStyle(.plain)
        .saryTheme(theme)
        .accessibilityLabel("الوجهة: \(name)")
        .accessibilityIdentifier("map.destination")
    }
}

/// The long-pressed point.
struct PlanPickedPin: View {
    var body: some View {
        Image(systemName: "mappin.circle.fill")
            .font(.system(size: 32, weight: .bold))
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, Color(red: 0.86, green: 0.18, blue: 0.2))
            .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
            .accessibilityIdentifier("map.picked")
    }
}

/// The home map's location marker uses LocationSharer's permission and fix, not Mapbox's
/// implicit location provider. This keeps the app in control of when iOS asks for permission.
struct PlanUserLocationPin: View {
    var body: some View {
        Circle()
            .fill(Color(red: 0.12, green: 0.52, blue: 0.98))
            .frame(width: 16, height: 16)
            .overlay(Circle().stroke(.white, lineWidth: 3))
            .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
            .accessibilityIdentifier("map.user-location")
    }
}

/// Keeps a view annotation for one point (create, move, remove).
final class PinSlot<V: View> {
    private(set) var annotation: ViewAnnotation?
    private var host: UIHostingController<V>?
    private var key: String?
    /// Where the annotation is (re-placing it at the same point every SwiftUI pass is wasted work).
    private var point: LngLat?

    func set(_ point: LngLat?, key: String, on map: MapView, anchor: ViewAnnotationAnchor = .bottom, priority: Int = 110, view: () -> V) {
        guard let point else { clear(); return }
        if key == self.key, let a = annotation {
            if point != self.point {
                a.annotatedFeature = .geometry(Point(point.coordinate))
                self.point = point
            }
            return
        }
        clear()
        let h = UIHostingController(rootView: view())
        h.view.backgroundColor = .clear
        h.view.frame = CGRect(origin: .zero, size: h.sizeThatFits(in: CGSize(width: 200, height: 120)))
        let a = ViewAnnotation(coordinate: point.coordinate, view: h.view)
        a.variableAnchors = [ViewAnnotationAnchorConfig(anchor: anchor)]
        a.allowOverlap = true
        a.priority = priority
        map.viewAnnotations.add(a)
        annotation = a
        host = h
        self.key = key
        self.point = point
    }

    func clear() {
        annotation?.remove()
        annotation = nil
        host = nil
        key = nil
        point = nil
    }
}

/// Plan drawing for the live map's coordinator (state kept in one box so the
/// coordinator only gains one stored property).
final class LivePlanDrawing {
    var plan = MapPlan()
    var layerKey: String?
    /// The route last sent to the plan source (nil: send again).
    var drawnRoute: [LngLat]?
    let destination = PinSlot<PlanDestinationPin>()
    let picked = PinSlot<PlanPickedPin>()
    var longPress: Cancelable?
}

extension OutingMapboxView.Coordinator {
    func setPlan(_ p: MapPlan) {
        guard p != planDrawing.plan else { return }
        planDrawing.plan = p
        drawPlan()
    }

    /// Call after the style (re)loads or the theme changes.
    func drawPlan(force: Bool = false) {
        guard let map, styleReady, let m = map.mapboxMap else { return }
        let p = planDrawing.plan
        let key = "\(p.emphasised)|\(theme.night)"
        if force || key != planDrawing.layerKey || !m.layerExists(withId: PlanMapStyle.line) {
            PlanMapStyle.ensureLayers(m, emphasised: p.emphasised, night: theme.night)
            planDrawing.layerKey = key
            planDrawing.drawnRoute = nil
        }
        /* A picked point or the destination changing does not touch the route line. */
        if force || planDrawing.drawnRoute != p.route {
            PlanMapStyle.update(m, route: p.route)
            planDrawing.drawnRoute = p.route
        }
        let theme = self.theme
        planDrawing.destination.set(p.destination.map { LngLat(lng: $0.lng, lat: $0.lat) }, key: "\(p.destination?.name ?? "")|\(theme.night)", on: map) {
            PlanDestinationPin(name: p.destination?.name ?? "الوجهة", theme: theme)
        }
        planDrawing.picked.set(p.picked, key: "picked", on: map, priority: 130) { PlanPickedPin() }
    }

    /// The single long-press entry point on the live map: reports the coordinate and its screen point.
    func installLongPress(_ map: MapView) {
        planDrawing.longPress = map.mapboxMap.addInteraction(LongPressInteraction { [weak self] ctx in
            guard let self, !self.picking else { return false }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            self.onLongPress(LngLat(lng: ctx.coordinate.longitude, lat: ctx.coordinate.latitude), ctx.point)
            return true
        })
    }
}
