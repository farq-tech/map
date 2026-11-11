@_spi(Experimental) import MapboxMaps
import SwiftUI
import UIKit

/// The map of the plan editor (and the small previews): the dashed planned route,
/// draggable vertices while drawing, the destination flag and a picked point.
/// Plain data in, gestures out.
struct PlanMapView: UIViewRepresentable {
    var route: [LngLat]
    var destination: OutingDestination? = nil
    var picked: LngLat? = nil
    /// Tap adds a point and vertices can be dragged.
    var editing = false
    /// false for a static preview (no gestures at all).
    var interactive = true
    var camera: PlanCamera? = nil
    var theme: SaryTheme = .default
    /// The blue dot of this phone, supplied by the app's permission-aware location owner.
    /// Do not enable Mapbox's built-in provider here: it can request location before the user
    /// has seen the app's own explanation (notably while a shared-outing invite is open).
    var userLocation: LngLat? = nil
    var onTap: (LngLat) -> Void = { _ in }
    var onLongPress: (LngLat) -> Void = { _ in }
    var onMove: (Int, LngLat) -> Void = { _, _ in }
    /// The camera's centre as the person moves the map («اختر من الخريطة»).
    var onCenter: ((LngLat) -> Void)? = nil
    /// A desert chip's results (outlines + numbered markers, «دليل البر»).
    var desert: DesertOverlay? = nil
    /// A desert marker tapped (its id).
    var onDesertTap: (String) -> Void = { _ in }

    /// More vertices than this are not drawn as handles (an imported track); the line still is.
    static let maxHandles = 150

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MapView {
        let start = PlanCamera.initial(route: route, destination: destination, picked: picked)
        let map = MapView(frame: .zero, mapInitOptions: MapInitOptions(cameraOptions: CameraOptions(center: start.coordinate, zoom: 11.5),
                                                                      styleURI: ArabicBasemap.cachedJSON == nil ? OutingMapboxView.styleURI : nil))
        if let json = ArabicBasemap.cachedJSON { map.mapboxMap.loadStyle(json) } else {
            ArabicBasemap.load { json in if let json { map.mapboxMap.loadStyle(json) } }
        }
        map.accessibilityIdentifier = "plan.map"
        map.location.options.puckType = nil
        SandGrade.follow(map)
        map.ornaments.options.scaleBar.visibility = .hidden
        map.ornaments.options.compass.visibility = .adaptive
        if !interactive { map.isUserInteractionEnabled = false }
        context.coordinator.attach(map, parent: self)
        return map
    }

    func updateUIView(_ map: MapView, context: Context) {
        context.coordinator.update(self)
    }

    static func dismantleUIView(_ map: MapView, coordinator: Coordinator) { coordinator.detach() }

    final class Coordinator {
        private weak var map: MapView?
        private var parent: PlanMapView?
        private var styleReady = false
        private var bag = Set<AnyCancelable>()
        private var interactions: [Cancelable] = []
        private var handles: CircleAnnotationManager?
        private var drawnRoute: [LngLat]?
        private var drawnHandles: [LngLat]?
        private var drawnEditing = false
        private var drawnDesert: DesertOverlay??
        private var lastCamera = -1
        /// Asked before the map had a size or a style: done once it has.
        private var pendingCamera: PlanCamera?
        private var dragging = false
        private let destination = PinSlot<PlanDestinationPin>()
        private let picked = PinSlot<PlanPickedPin>()
        private let user = PinSlot<PlanUserLocationPin>()

        func attach(_ map: MapView, parent: PlanMapView) {
            self.map = map
            self.parent = parent
            map.mapboxMap.onStyleLoaded.observe { [weak self] _ in self?.styleLoaded() }.store(in: &bag)
            map.mapboxMap.onCameraChanged.observe { [weak self, weak map] _ in
                guard let map, let report = self?.parent?.onCenter else { return }
                let c = map.mapboxMap.cameraState.center
                report(LngLat(lng: c.longitude, lat: c.latitude))
            }.store(in: &bag)
            guard parent.interactive else { return }
            map.gestures.onLayerTap(DesertGazetteerMapLayer.marker) { [weak self] feature, _ in
                guard let v = feature.feature.properties?["id"], case let .string(id)? = v else { return false }
                self?.parent?.onDesertTap(id)
                return true
            }.store(in: &bag)
            interactions.append(map.mapboxMap.addInteraction(TapInteraction { [weak self] ctx in
                guard let self, let p = self.parent, p.editing else { return false }
                p.onTap(LngLat(lng: ctx.coordinate.longitude, lat: ctx.coordinate.latitude))
                return true
            }))
            interactions.append(map.mapboxMap.addInteraction(LongPressInteraction { [weak self] ctx in
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                self?.parent?.onLongPress(LngLat(lng: ctx.coordinate.longitude, lat: ctx.coordinate.latitude))
                return true
            }))
        }

        func detach() {
            interactions.forEach { $0.cancel() }
            interactions = []
            bag.removeAll()
        }

        private func styleLoaded() {
            guard let map, let m = map.mapboxMap else { return }
            styleReady = true
            for (k, v) in [("show3dObjects", false), ("showPointOfInterestLabels", true), ("showTransitLabels", false), ("showRoadLabels", true)] as [(String, Bool)] {
                try? m.setStyleImportConfigProperty(for: "basemap", config: k, value: v)
            }
            PlanMapStyle.ensureLayers(m, emphasised: true, night: parent?.theme.night ?? false)
            /* Every building, flat and light, from a neighbourhood zoom (the home map is satellite). */
            BuildingFootprints.install(m)
            drawnRoute = nil
            drawnHandles = nil
            drawnDesert = nil
            if let p = parent { update(p) }
            if let c = pendingCamera {
                pendingCamera = nil
                DispatchQueue.main.async { [weak self] in
                    guard let self, let map = self.map else { return }
                    self.move(c, on: map)
                }
            }
        }

        func update(_ p: PlanMapView) {
            parent = p
            guard let map else { return }
            if styleReady, let m = map.mapboxMap, !dragging, drawnRoute != p.route {
                PlanMapStyle.update(m, route: p.route)
                drawnRoute = p.route
            }
            if styleReady { drawHandles(p, on: map) }
            if styleReady, let m = map.mapboxMap, drawnDesert != .some(p.desert), p.desert != nil || drawnDesert != nil {
                DesertGazetteerMapLayer.apply(m, p.desert)
                drawnDesert = .some(p.desert)
            }
            let theme = p.theme
            destination.set(p.destination.map { LngLat(lng: $0.lng, lat: $0.lat) }, key: p.destination?.name ?? "", on: map) {
                PlanDestinationPin(name: p.destination?.name ?? "الوجهة", theme: theme)
            }
            picked.set(p.picked, key: "picked", on: map, priority: 130) { PlanPickedPin() }
            user.set(p.userLocation, key: "user", on: map, anchor: .center, priority: 140) { PlanUserLocationPin() }
            if let c = p.camera, c.id != lastCamera {
                lastCamera = c.id
                if styleReady && map.bounds.height > 0 { move(c, on: map) } else { pendingCamera = c }
            }
        }

        private func drawHandles(_ p: PlanMapView, on map: MapView) {
            let show = p.editing && p.route.count <= PlanMapView.maxHandles ? p.route : (p.route.count >= 2 && p.editing ? [p.route.first!, p.route.last!] : [])
            guard !dragging, show != drawnHandles || p.editing != drawnEditing else { return }
            drawnHandles = show
            drawnEditing = p.editing
            if handles == nil { handles = map.annotations.makeCircleAnnotationManager(id: "plan-handles") }
            let draggable = p.editing && p.route.count <= PlanMapView.maxHandles
            handles?.annotations = show.enumerated().map { i, pt in
                var a = CircleAnnotation(id: "h\(i)", centerCoordinate: pt.coordinate, isDraggable: draggable)
                let ends = i == 0 || i == show.count - 1
                a.circleRadius = ends ? 9 : 7
                a.circleColor = StyleColor(ends ? .white : UIColor(rgb: PlanMapStyle.color))
                a.circleStrokeColor = StyleColor(ends ? UIColor(rgb: PlanMapStyle.color) : .white)
                a.circleStrokeWidth = 3
                a.dragBeginHandler = { [weak self] _, _ in self?.dragging = true; return true }
                a.dragChangeHandler = { [weak self] ann, _ in
                    guard let self, let map = self.map, let m = map.mapboxMap, var r = self.drawnRoute, i < r.count else { return }
                    r[i] = LngLat(lng: ann.point.coordinates.longitude, lat: ann.point.coordinates.latitude)
                    PlanMapStyle.update(m, route: r)
                    self.drawnRoute = r
                }
                a.dragEndHandler = { [weak self] ann, _ in
                    guard let self else { return }
                    self.dragging = false
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    self.parent?.onMove(i, LngLat(lng: ann.point.coordinates.longitude, lat: ann.point.coordinates.latitude))
                }
                return a
            }
        }

        private func move(_ c: PlanCamera, on map: MapView) {
            let pad = UIEdgeInsets(top: 60, left: 40, bottom: 60, right: 40)
            switch c.kind {
            case let .point(p, zoom):
                map.camera.ease(to: CameraOptions(center: p.coordinate, zoom: zoom), duration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.6)
            case let .fit(pts):
                guard pts.count >= 2, map.bounds.height > 0 else {
                    if let p = pts.first { map.camera.ease(to: CameraOptions(center: p.coordinate, zoom: 13), duration: 0) }
                    return
                }
                if let cam = try? map.mapboxMap.camera(for: pts.map(\.coordinate), camera: CameraOptions(), coordinatesPadding: pad, maxZoom: 15, offset: nil) {
                    map.camera.ease(to: cam, duration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.6)
                }
            }
        }
    }
}

/// A one-shot camera request for the plan map; a new `id` asks again.
struct PlanCamera: Equatable {
    enum Kind: Equatable {
        case fit([LngLat])
        case point(LngLat, zoom: Double)
    }

    var kind: Kind
    var id: Int

    /// Where to open: the route, else the destination, else the picked point, else Riyadh.
    static func initial(route: [LngLat], destination: OutingDestination?, picked: LngLat?) -> LngLat {
        if let p = picked { return p }
        if let f = route.first { return f }
        if let d = destination { return LngLat(lng: d.lng, lat: d.lat) }
        return LngLat(lng: 46.6753, lat: 24.7136)
    }
}
