import MapKit
import SwiftUI

/// «الوضع الواقعي»: Apple's realistic 3D imagery (photoreal cities where Apple has them, realistic
/// terrain elsewhere) with our cars, track, plan and markers over it. For looking, not driving:
/// it refuses while guiding, above 15 km/h, and offline (see `RealisticRules`).
///
/// Apple's logo and «Legal» link are MapKit's own and stay visible: our bars are safe-area insets,
/// so MapKit moves its attribution clear of them. Nothing here caches or exports Apple imagery
/// (no snapshots, no tile access), and none of it reaches the Mapbox map.
struct RealisticMapView: View {
    var scene: RealisticScene
    var close: () -> Void
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var location: LocationSharer
    @Environment(\.sary) private var theme

    @State private var position: MapCameraPosition = .automatic
    /// The camera as last reported by the map (the drone orbits from here; a touch freezes here).
    @State private var current: RealisticRules.Camera?
    @State private var droneTask: Task<Void, Never>?
    @State private var droneOn = false
    @State private var labels = false
    @State private var tilted = true
    @State private var selected: String?
    @Namespace private var mapScope

    private var gate: RealisticGate {
        /* Only a recent fix's speed counts (an old one says nothing about now). */
        let fix = location.lastFix
        let fresh = fix.map { Date().timeIntervalSince1970 * 1000 - $0.atMs < 60_000 } ?? false
        return RealisticRules.gate(speedMps: fresh ? fix?.speed : nil, navigating: scene.navigating, online: app.online)
    }

    var body: some View {
        let g = gate
        ZStack {
            if g.allowsMap {
                map
            } else {
                blocked(g)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .safeAreaInset(edge: .bottom, spacing: 0) { if g.allowsMap { controls } }
        .mapScope(mapScope)
        .background(Color.black.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .onChange(of: g) { _, now in if !now.allowsMap { stopDrone() } }
        /* Tapping a marker is a touch too. */
        .onChange(of: selected) { _, _ in if droneOn { stopDrone(freeze: true) } }
        .onDisappear { stopDrone() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("realistic.screen")
    }

    // MARK: map

    private var map: some View {
        Map(position: $position, selection: $selected, scope: mapScope) {
            if let line = scene.track, line.isDrawable {
                let coords = line.points.map(\.coordinate)
                /* A dark casing under the line keeps it readable on bright sand. */
                MapPolyline(coordinates: coords)
                    .stroke(Color.black.opacity(0.55), style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round))
                if let stops = RealisticRules.speedStops(line) {
                    MapPolyline(coordinates: coords)
                        .stroke(Gradient(stops: stops.map { .init(color: Color(rgb: $0.rgb), location: $0.location) }),
                                style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                } else {
                    MapPolyline(coordinates: coords)
                        .stroke(Color(rgb: 0xF7A53D), style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                }
            }
            if scene.plan.count >= 2 {
                MapPolyline(coordinates: scene.plan.map(\.coordinate))
                    .stroke(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: 4, lineCap: .round, dash: [8, 7]))
            }
            /* Waypoints: small glyphs, so a cluster of them never hides the cars. */
            ForEach(scene.markers.filter { $0.kind == .waypoint }) { m in
                Annotation(m.title, coordinate: m.position.coordinate, anchor: .center) {
                    Image(systemName: m.systemImage)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(markerTint(m.kind)))
                        .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
                }
                .annotationTitles(.hidden)
            }
            ForEach(scene.markers.filter { $0.kind != .waypoint }) { m in
                Marker(m.title, systemImage: m.systemImage, coordinate: m.position.coordinate)
                    .tint(markerTint(m.kind))
                    .tag(m.id)
            }
            ForEach(scene.members) { m in
                Annotation(m.isMe ? "أنا" : m.name, coordinate: m.position.coordinate, anchor: .center) {
                    RealisticCarDot(color: Color(rgb: m.color), isMe: m.isMe, heading: m.heading, stale: m.stale)
                        .onTapGesture { if droneOn { stopDrone(freeze: true) } }
                }
                .annotationTitles(m.isMe ? .hidden : .automatic)
            }
            if !scene.members.contains(where: \.isMe) {
                UserAnnotation()
            }
        }
        .mapStyle(labels ? .hybrid(elevation: .realistic, pointsOfInterest: .excludingAll) : .imagery(elevation: .realistic))
        /* MapKit's own controls would sit under the status bar (the map runs edge to edge):
         * the compass lives in our bar instead, scoped to this map. */
        .mapControls {}
        .onMapCameraChange(frequency: .continuous) { ctx in
            let c = ctx.camera
            current = .init(center: LngLat(lng: c.centerCoordinate.longitude, lat: c.centerCoordinate.latitude),
                            distance: c.distance, heading: c.heading, pitch: c.pitch)
        }
        /* Any touch on the map ends the drone flight (and the map then follows the finger as usual). */
        .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in if droneOn { stopDrone(freeze: true) } })
        .task { await flyIn() }
        .ignoresSafeArea()
        .accessibilityIdentifier("realistic.map")
    }

    private func markerTint(_ k: RealisticScene.Marker.Kind) -> Color {
        switch k {
        case .destination: return Color(rgb: 0xE5772A)
        case .rally: return Color(rgb: 0xC4501A)
        case .place: return Color(rgb: 0xF2B544)
        case .waypoint: return Color(rgb: 0x3A8DDE)
        case .point: return Color(rgb: 0xE5772A)
        }
    }

    // MARK: chrome

    private var header: some View {
        HStack(spacing: theme.space(.s)) {
            Button(action: { stopDrone(); close() }) {
                Image(systemName: "xmark").font(.system(size: 16, weight: .bold)).frame(width: 44, height: 44)
            }
            .foregroundStyle(.white)
            .saryGlass(Circle(), role: .control, interactive: true)
            .accessibilityLabel(Text("أغلق الوضع الواقعي"))
            .accessibilityIdentifier("realistic-close")
            VStack(alignment: .leading, spacing: 0) {
                Text("الوضع الواقعي").saryText(.headline, weight: .bold).foregroundStyle(.white).lineLimit(1)
                Text(scene.title).saryText(.caption).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
            }
            .padding(.horizontal, theme.space(.m))
            .frame(minHeight: 44)
            .saryGlass(Capsule(), role: .chrome)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("realistic.header")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, theme.space(.m))
        .padding(.bottom, theme.space(.s))
    }

    private var controls: some View {
        HStack(spacing: theme.space(.s)) {
            Button(action: { droneOn ? stopDrone(freeze: true) : startDrone() }) {
                Label(droneOn ? "أوقف الدرون" : "طيران درون", systemImage: droneOn ? "pause.fill" : "airplane.circle.fill")
                    .saryText(.subhead, weight: .bold)
                    .padding(.horizontal, theme.space(.m))
                    .frame(minHeight: 44)
            }
            .foregroundStyle(.white)
            .saryGlass(Capsule(), role: .control, tint: droneOn ? Color(rgb: 0xE5772A).opacity(0.55) : nil, interactive: true)
            .accessibilityValue(Text(droneOn ? "يطير" : "متوقف"))
            .accessibilityIdentifier("realistic-drone")

            Button(action: toggleTilt) {
                Text(tilted ? "من فوق" : "ثلاثي الأبعاد")
                    .saryText(.subhead, weight: .bold)
                    .padding(.horizontal, theme.space(.m))
                    .frame(minHeight: 44)
            }
            .foregroundStyle(.white)
            .saryGlass(Capsule(), role: .control, interactive: true)
            .accessibilityIdentifier("realistic-tilt")

            Button(action: { labels.toggle() }) {
                Image(systemName: labels ? "character.bubble.fill" : "character.bubble")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            .foregroundStyle(.white)
            .saryGlass(Circle(), role: .control, interactive: true)
            .accessibilityLabel(Text(labels ? "أخفِ الأسماء" : "أظهر الأسماء"))
            .accessibilityIdentifier("realistic-labels")
            Spacer(minLength: 0)
            MapCompass(scope: mapScope)
                .mapControlVisibility(.visible)
                .accessibilityIdentifier("realistic-compass")
        }
        .padding(.horizontal, theme.space(.m))
        .padding(.top, theme.space(.s))
        .padding(.bottom, theme.space(.xs))
    }

    private func blocked(_ g: RealisticGate) -> some View {
        VStack(spacing: theme.space(.m)) {
            Image(systemName: g.systemImage).font(.system(size: 40, weight: .semibold)).foregroundStyle(Color(rgb: 0xF7A53D))
            Text(g.title).saryText(.title2, weight: .bold).foregroundStyle(.white).multilineTextAlignment(.center)
                .accessibilityIdentifier("realistic.blocked")
            Text(g.detail).saryText(.body).foregroundStyle(.white.opacity(0.8)).multilineTextAlignment(.center)
            Button(action: close) { SaryButtonLabel(title: "رجوع", systemImage: "arrow.uturn.backward") }
                .buttonStyle(.sary(.primary))
                .accessibilityIdentifier("realistic-back")
        }
        .padding(theme.space(.xl))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: camera

    /// MapKit clamps the pitch of a camera set before the map has loaded (to ≈30°), so the
    /// first view starts from above and then tilts in (which also reads as a short arrival).
    private func flyIn() async {
        guard let c = RealisticRules.initialCamera(scene) else { return }
        var top = c
        top.pitch = 0
        top.distance = min(c.distance * 1.6, RealisticRules.maxDistance)
        position = .camera(top.mapCamera)
        try? await Task.sleep(nanoseconds: RealisticRules.flyInDelayNs)
        guard !Task.isCancelled, !droneOn else { return }
        withAnimation(.easeInOut(duration: 2.0)) { position = .camera(c.mapCamera) }
    }

    private func toggleTilt() {
        stopDrone(freeze: true)
        tilted.toggle()
        guard var c = current ?? RealisticRules.initialCamera(scene) else { return }
        c.pitch = tilted ? RealisticRules.tiltedPitch : 0
        withAnimation(.easeInOut(duration: 1.2)) { position = .camera(c.mapCamera) }
    }

    /// «طيران درون»: a slow orbit around what is in the middle, until a touch or «أوقف».
    private func startDrone() {
        guard gate.allowsMap, let start = current ?? RealisticRules.initialCamera(scene) else { return }
        droneTask?.cancel()
        droneOn = true
        tilted = true
        var cam = start
        droneTask = Task { @MainActor in
            while !Task.isCancelled {
                cam = RealisticRules.droneStep(cam)
                withAnimation(.linear(duration: RealisticRules.droneStepSeconds)) { position = .camera(cam.mapCamera) }
                try? await Task.sleep(nanoseconds: UInt64(RealisticRules.droneStepSeconds * 1_000_000_000))
            }
        }
    }

    /// `freeze`: hold the camera where it is now (cancels the step in flight).
    private func stopDrone(freeze: Bool = false) {
        droneTask?.cancel()
        droneTask = nil
        guard droneOn else { return }
        droneOn = false
        if freeze, let c = current {
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { position = .camera(c.mapCamera) }
        }
    }
}

/// A glassy round car marker in the member's colour (heading arrow when live).
struct RealisticCarDot: View {
    var color: Color
    var isMe: Bool
    var heading: Double?
    var stale: Bool

    var body: some View {
        ZStack {
            Circle().fill(color.opacity(0.28)).frame(width: isMe ? 46 : 38, height: isMe ? 46 : 38)
            Circle()
                .fill(.ultraThinMaterial)
                .overlay(Circle().fill(color.opacity(0.85)).padding(4))
                .overlay(Circle().stroke(Color.white, lineWidth: isMe ? 3 : 2))
                .frame(width: isMe ? 28 : 24, height: isMe ? 28 : 24)
                .shadow(color: .black.opacity(0.45), radius: 4, y: 2)
            if let heading {
                Image(systemName: "location.north.fill")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(.white)
                    .rotationEffect(.degrees(heading))
            } else {
                Image(systemName: "car.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
            }
        }
        .opacity(stale ? 0.55 : 1)
        .accessibilityHidden(true)
    }
}

extension RealisticRules.Camera {
    var mapCamera: MapCamera {
        MapCamera(centerCoordinate: center.coordinate, distance: distance, heading: heading, pitch: pitch)
    }
}
