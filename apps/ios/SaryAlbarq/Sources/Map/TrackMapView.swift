@_spi(Experimental) import MapboxMaps
import SwiftUI

/// A track on clean satellite imagery (build 10): Standard Satellite with its labels off,
/// zoomable to the imagery's maximum, the track in the shared style (`TrackLineDrawer`),
/// optionally my live position and the road route to the track's nearest point.
struct TrackMapView: UIViewRepresentable {
    var line: TrackLine
    /// The followed track: glow under it.
    var highlight = false
    /// My position — only a fresh one (the caller drops it when old); nil hides the dot.
    var me: LngLat? = nil
    /// The road route to the track («وجّهني لأقرب نقطة»), drawn dashed.
    var approach: [LngLat] = []
    var interactive = true
    /// Screen area covered by our chrome (the bottom card, the top panel).
    var padding: UIEdgeInsets = .zero
    /// A new value re-frames the camera on the track (and me).
    var fitKey = 0
    /// The camera follows me (follow mode), until the map is moved by hand.
    var followMe = false
    var onUserGesture: () -> Void = {}
    /// «صور عالية الوضوح» (Sources/Map/AIEnhance): only the full-screen track detail turns it on.
    var hiRes = HiResRequest.off

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MapView {
        let start = line.points.first?.coordinate ?? CLLocationCoordinate2D(latitude: 24.7136, longitude: 46.6753)
        let map = MapView(frame: .zero, mapInitOptions: MapInitOptions(cameraOptions: CameraOptions(center: start, zoom: 13), styleURI: MapLayer.satellite.styleURI))
        map.accessibilityIdentifier = "track.map"
        map.ornaments.options.scaleBar.visibility = interactive ? .adaptive : .hidden
        map.ornaments.options.compass.visibility = .adaptive
        map.ornaments.options.attributionButton.margins = CGPoint(x: 8, y: padding.bottom + 4)
        map.ornaments.options.logo.margins = CGPoint(x: 8, y: padding.bottom + 4)
        /* The imagery's sharp maximum: no blurry over-zoom. */
        try? map.mapboxMap.setCameraBounds(with: CameraBoundsOptions(maxZoom: zoomCap))
        if !interactive {
            map.gestures.options.panEnabled = false
            map.gestures.options.pinchEnabled = false
            map.gestures.options.rotateEnabled = false
            map.gestures.options.pitchEnabled = false
            map.gestures.options.doubleTapToZoomInEnabled = false
            map.gestures.options.doubleTouchToZoomOutEnabled = false
            map.gestures.options.quickZoomEnabled = false
        }
        context.coordinator.attach(map, self)
        return map
    }

    func updateUIView(_ map: MapView, context: Context) {
        context.coordinator.update(self)
        HiResImagery.of(map).update(followMe ? .off : hiRes)
        if map.mapboxMap.cameraBounds.maxZoom != zoomCap { try? map.mapboxMap.setCameraBounds(with: CameraBoundsOptions(maxZoom: zoomCap)) }
    }

    /// z19 when this map shows «صور عالية الوضوح» (person + server on), z18 otherwise.
    private var zoomCap: Double {
        let s = HiResSettings.shared
        return SatelliteLabels.imageryMaxZoom(hiRes: hiRes.surface != .off && !followMe && s.userOn && s.remoteOn)
    }

    static func dismantleUIView(_ map: MapView, coordinator: Coordinator) { coordinator.cancelables.removeAll() }

    final class Coordinator: NSObject, GestureManagerDelegate {
        weak var map: MapView?
        var cancelables = Set<AnyCancelable>()
        private var ready = false
        private var props: TrackMapView?
        private var fittedKey: Int?
        private var drawnMe: LngLat??
        private var drawnApproach: [LngLat]?
        private var userMoved = false
        private let drawer = TrackLineDrawer(id: "sary-track-detail")
        static let meSource = "sary-track-me"
        static let approachSource = "sary-track-approach"

        func attach(_ map: MapView, _ p: TrackMapView) {
            self.map = map
            props = p
            map.gestures.delegate = self
            map.mapboxMap.onStyleLoaded.observe { [weak self] _ in self?.styleLoaded() }.store(in: &cancelables)
        }

        func gestureManager(_ gestureManager: GestureManager, didBegin gestureType: GestureType) {
            userMoved = true
            props?.onUserGesture()
        }
        func gestureManager(_ gestureManager: GestureManager, didEnd gestureType: GestureType, willAnimate: Bool) {}
        func gestureManager(_ gestureManager: GestureManager, didEndAnimatingFor gestureType: GestureType) {}

        private func styleLoaded() {
            guard let m = map?.mapboxMap else { return }
            ready = true
            /* Clean imagery: the track is the subject. Flat (no 3D buildings over the line). */
            try? m.setStyleImportConfigProperty(for: "basemap", config: "show3dObjects", value: false)
            SatelliteLabels.clean.apply(m)
            for src in [Self.approachSource, Self.meSource] where !m.sourceExists(withId: src) {
                var s = GeoJSONSource(id: src)
                s.data = .featureCollection(FeatureCollection(features: []))
                try? m.addSource(s)
            }
            if !m.layerExists(withId: "\(Self.approachSource)-line") {
                try? m.addLayer(with: ["id": "\(Self.approachSource)-line", "type": "line", "source": Self.approachSource,
                                       "layout": ["line-join": "round", "line-cap": "round"],
                                       "paint": ["line-color": "#2b7bf0", "line-width": 5, "line-dasharray": [0.8, 1.4],
                                                 "line-emissive-strength": 1] as [String: Any]], layerPosition: nil)
            }
            if !m.layerExists(withId: "\(Self.meSource)-dot") {
                try? m.addLayer(with: ["id": "\(Self.meSource)-halo", "type": "circle", "source": Self.meSource,
                                       "paint": ["circle-radius": 16, "circle-color": "#2b7bf0", "circle-opacity": 0.22,
                                                 "circle-pitch-alignment": "map", "circle-emissive-strength": 1] as [String: Any]], layerPosition: nil)
                try? m.addLayer(with: ["id": "\(Self.meSource)-dot", "type": "circle", "source": Self.meSource,
                                       "paint": ["circle-radius": 7.5, "circle-color": "#2b7bf0", "circle-stroke-color": "#ffffff",
                                                 "circle-stroke-width": 3, "circle-pitch-alignment": "map", "circle-emissive-strength": 1] as [String: Any]],
                                   layerPosition: nil)
            }
            drawer.styleLoaded()
            drawnMe = nil
            drawnApproach = nil
            if let p = props { update(p) }
        }

        func update(_ p: TrackMapView) {
            let refit = p.fitKey != props?.fitKey
            props = p
            guard ready, let map else { return }
            let m: MapboxMap = map.mapboxMap
            drawer.update(m, line: p.line, style: TrackLineStyle(width: TrackLineStyle.width + 0.5, glow: p.highlight),
                          below: m.layerExists(withId: "\(Self.approachSource)-line") ? "\(Self.approachSource)-line" : nil)
            if drawnApproach != p.approach {
                drawnApproach = p.approach
                let f = p.approach.count >= 2 ? [Feature(geometry: .lineString(LineString(p.approach.map(\.coordinate))))] : []
                m.updateGeoJSONSource(withId: Self.approachSource, geoJSON: .featureCollection(FeatureCollection(features: f)))
            }
            if drawnMe != .some(p.me) {
                drawnMe = .some(p.me)
                let f = p.me.map { [Feature(geometry: .point(Point($0.coordinate)))] } ?? []
                m.updateGeoJSONSource(withId: Self.meSource, geoJSON: .featureCollection(FeatureCollection(features: f)))
            }
            if fittedKey == nil || refit {
                fittedKey = p.fitKey
                userMoved = false
                fit(p)
            } else if p.followMe, !userMoved, let me = p.me {
                map.camera.ease(to: CameraOptions(center: me.coordinate, padding: p.padding, zoom: max(m.cameraState.zoom, 16)),
                                duration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.6)
            }
        }

        private func fit(_ p: TrackMapView) {
            guard let map, map.bounds.height > 0 else {
                /* Not laid out yet: once it is. */
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in if let p = self?.props { self?.fit(p) } }
                return
            }
            var pts = p.line.points
            if let me = p.me { pts.append(me) }
            pts += p.approach
            guard let b = GroupFraming.bounds(pts) else { return }
            let coords = [CLLocationCoordinate2D(latitude: b.south, longitude: b.west), CLLocationCoordinate2D(latitude: b.north, longitude: b.east)]
            let pad = UIEdgeInsets(top: p.padding.top + 36, left: 36, bottom: p.padding.bottom + 36, right: 36)
            guard let cam = try? map.mapboxMap.camera(for: coords, camera: CameraOptions(bearing: 0, pitch: 0), coordinatesPadding: pad,
                                                      maxZoom: SatelliteLabels.trackMaxZoom, offset: nil) else { return }
            map.mapboxMap.setCamera(to: cam)
        }
    }
}
