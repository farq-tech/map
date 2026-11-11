@_spi(Experimental) import MapboxMaps
import Combine
import SwiftUI
import UIKit

/// App-wide state of «أماكن مقترحة للكشتة»: the layer toggle, tonight's top five (numbered on
/// the map) and a tapped site (the live screen opens its card).
@MainActor
final class CampSitesHub: ObservableObject {
    static let shared = CampSitesHub()
    static let layerKey = "sary.map.campSites.v1"

    @Published var layerOn: Bool { didSet { UserDefaults.standard.set(layerOn, forKey: Self.layerKey) } }
    /// Site id → its number in «أحلى ٥» (drawn bigger, numbered).
    @Published var highlighted: [String: Int] = [:]
    /// A site tapped on the map.
    @Published var tapped: String?

    private init() {
        layerOn = UserDefaults.standard.object(forKey: Self.layerKey) as? Bool ?? false
    }
}

/// The map layer: one GeoJSON source from the bundled candidates, a circle per site and a
/// number on tonight's five. Attached once per `MapView`; re-adds itself after a style load.
@MainActor
final class CampSitesMapLayer {
    static let source = "sary-camp-sites"
    static let circleLayer = "sary-camp-sites-circle"
    static let labelLayer = "sary-camp-sites-label"
    static let routeSource = "sary-desert-routes"
    static let routeLayer = "sary-desert-routes-line"
    static let routeHardLayer = "sary-desert-routes-hard"
    /// The routes not picked (thinner, softer), under the picked one.
    static let routeAltLayer = "sary-desert-routes-alt"

    private weak var map: MapView?
    private var bag = Set<AnyCancellable>()
    private var cancelables = Set<AnyCancelable>()
    private static var key: UInt8 = 0

    static func attach(_ map: MapView) {
        guard objc_getAssociatedObject(map, &key) == nil else { return }
        let c = CampSitesMapLayer(map)
        objc_setAssociatedObject(map, &key, c, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    private init(_ map: MapView) {
        self.map = map
        map.mapboxMap.onStyleLoaded.observe { [weak self] _ in self?.install() }.store(in: &cancelables)
        if map.mapboxMap.isStyleLoaded { install() }
        let hub = CampSitesHub.shared
        hub.$layerOn.combineLatest(hub.$highlighted).dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }.store(in: &bag)
        let routes = DesertRoutesHub.shared
        routes.$options.combineLatest(routes.$selected).dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshRoutes() }.store(in: &bag)
        map.gestures.onLayerTap(Self.circleLayer) { feature, _ in
            if let v = feature.feature.properties?["id"], case let .string(id)? = v { CampSitesHub.shared.tapped = id }
            return true
        }.store(in: &cancelables)
    }

    /// The features with what the layer styles on (`h`: highlighted, `n`: its number).
    static func collection(_ sites: [CampSite], highlighted: [String: Int]) -> FeatureCollection {
        FeatureCollection(features: sites.map { s in
            var f = Feature(geometry: .point(Point(CLLocationCoordinate2D(latitude: s.lat, longitude: s.lng))))
            let n = highlighted[s.id]
            f.properties = ["id": .string(s.id), "h": .boolean(n != nil), "n": .string(n.map { SaryFormat.number($0) } ?? "")]
            return f
        })
    }

    /// «مخطط دروب البر»: each option's line (`c` colour, `s` selected) and its hard stretches (`hard`).
    static func routeCollection(_ options: [DesertRouter.Option], selected: DesertRouter.Mode) -> FeatureCollection {
        var fs: [Feature] = []
        /* The selected one last (on top). */
        for o in options.sorted(by: { ($0.mode == selected ? 1 : 0) < ($1.mode == selected ? 1 : 0) }) {
            let on = o.mode == selected
            var f = Feature(geometry: .lineString(LineString(o.points.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lng) })))
            f.properties = ["c": .string(DesertRouteSheet.hex(o.mode)), "s": .boolean(on), "hard": .boolean(false)]
            fs.append(f)
            guard on else { continue }
            for h in o.hard where h.points.count >= 2 {
                var hf = Feature(geometry: .lineString(LineString(h.points.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lng) })))
                hf.properties = ["c": .string("#ff0055"), "s": .boolean(true), "hard": .boolean(true), "why": .string(h.reason.text)]
                fs.append(hf)
            }
        }
        return FeatureCollection(features: fs)
    }

    /// Visible when the person turned the layer on, or while «أحلى ٥» is showing.
    nonisolated static func visible(layerOn: Bool, highlighted: [String: Int]) -> Bool { layerOn || !highlighted.isEmpty }

    private func install() {
        guard let m = map?.mapboxMap else { return }
        let hub = CampSitesHub.shared
        let shown = Self.visible(layerOn: hub.layerOn, highlighted: hub.highlighted)
        let sites = hub.layerOn ? CampSiteCatalog.all : CampSiteCatalog.all.filter { hub.highlighted[$0.id] != nil }
        if !m.sourceExists(withId: Self.source) {
            var s = GeoJSONSource(id: Self.source)
            s.data = .featureCollection(Self.collection(sites, highlighted: hub.highlighted))
            try? m.addSource(s)
        }
        let vis = shown ? "visible" : "none"
        if !m.layerExists(withId: Self.circleLayer) {
            FXLog.add(m, [
                "id": Self.circleLayer, "type": "circle", "source": Self.source, "minzoom": 6,
                "layout": ["visibility": vis, "circle-sort-key": ["case", ["get", "h"], 1, 0] as [Any]] as [String: Any],
                "paint": [
                    "circle-color": ["case", ["get", "h"], "#ff7a00", "#f2a65a"] as [Any],
                    "circle-radius": ["interpolate", ["linear"], ["zoom"], 6, ["case", ["get", "h"], 9, 4] as [Any],
                                      12, ["case", ["get", "h"], 15, 8] as [Any]] as [Any],
                    "circle-stroke-color": "#ffffff", "circle-stroke-width": 2,
                    "circle-opacity": 0.95, "circle-emissive-strength": 1,
                ] as [String: Any],
            ], layerPosition: nil)
        }
        if !m.layerExists(withId: Self.labelLayer) {
            FXLog.add(m, [
                "id": Self.labelLayer, "type": "symbol", "source": Self.source, "minzoom": 6,
                "filter": ["get", "h"],
                "layout": ["visibility": vis, "text-field": ["get", "n"], "text-size": 13,
                           "text-allow-overlap": true, "text-ignore-placement": true] as [String: Any],
                "paint": ["text-color": "#ffffff", "text-emissive-strength": 1] as [String: Any],
            ], layerPosition: nil)
        }
        if !m.sourceExists(withId: Self.routeSource) {
            var s = GeoJSONSource(id: Self.routeSource)
            s.data = .featureCollection(Self.routeCollection(DesertRoutesHub.shared.options, selected: DesertRoutesHub.shared.selected))
            try? m.addSource(s)
        }
        /* Constant opacities and widths (the selected route and the others are separate layers), so
           Mapbox can ease them: the preview fades in when it arrives, the picked line pops. */
        let shownNow = !DesertRoutesHub.shared.options.isEmpty
        if !m.layerExists(withId: Self.routeHardLayer) {
            FXLog.add(m, [
                "id": Self.routeHardLayer, "type": "line", "source": Self.routeSource, "filter": ["get", "hard"],
                "layout": ["line-join": "round", "line-cap": "round"],
                "paint": ["line-color": ["get", "c"], "line-width": 11, "line-opacity": RouteReveal.opacity(.hard, shown: shownNow),
                          "line-opacity-transition": RouteReveal.transition, "line-emissive-strength": 1] as [String: Any],
            ], layerPosition: m.layerExists(withId: Self.circleLayer) ? .below(Self.circleLayer) : nil)
        }
        if !m.layerExists(withId: Self.routeLayer) {
            FXLog.add(m, [
                "id": Self.routeLayer, "type": "line", "source": Self.routeSource, "filter": ["all", ["!", ["get", "hard"]], ["get", "s"]] as [Any],
                "layout": ["line-join": "round", "line-cap": "round"],
                "paint": ["line-color": ["get", "c"], "line-width": RouteReveal.selectedWidth,
                          "line-width-transition": RouteReveal.popTransition,
                          "line-opacity": RouteReveal.opacity(.selected, shown: shownNow),
                          "line-opacity-transition": RouteReveal.transition, "line-emissive-strength": 1] as [String: Any],
            ], layerPosition: .below(Self.routeHardLayer))
        }
        if !m.layerExists(withId: Self.routeAltLayer) {
            FXLog.add(m, [
                "id": Self.routeAltLayer, "type": "line", "source": Self.routeSource, "filter": ["all", ["!", ["get", "hard"]], ["!", ["get", "s"]]] as [Any],
                "layout": ["line-join": "round", "line-cap": "round"],
                "paint": ["line-color": ["get", "c"], "line-width": 3, "line-opacity": RouteReveal.opacity(.other, shown: shownNow),
                          "line-opacity-transition": RouteReveal.transition, "line-emissive-strength": 1] as [String: Any],
            ], layerPosition: .below(Self.routeLayer))
        }
        routesShown = shownNow
        drawnSelection = DesertRoutesHub.shared.selected
        refresh()
        refreshRoutes()
    }

    /// The preview is on the map (its layers at full opacity), and the route drawn as picked.
    private var routesShown = false
    private var drawnSelection: DesertRouter.Mode?
    private var popWork: DispatchWorkItem?

    private func refreshRoutes() {
        guard let m = map?.mapboxMap, m.sourceExists(withId: Self.routeSource) else { return }
        let r = DesertRoutesHub.shared
        m.updateGeoJSONSource(withId: Self.routeSource, geoJSON: .featureCollection(Self.routeCollection(r.options, selected: r.selected)))
        let shown = !r.options.isEmpty
        let reduce = MapCameraMotion.reduceMotionNow
        if shown != routesShown {
            routesShown = shown
            /* Reveal: from the zero the empty preview left (eased by the paint transition). */
            for (id, kind) in [(Self.routeLayer, RouteReveal.Kind.selected), (Self.routeAltLayer, .other), (Self.routeHardLayer, .hard)]
                where m.layerExists(withId: id) {
                try? m.setLayerProperty(for: id, property: "line-opacity", value: RouteReveal.opacity(kind, shown: shown))
            }
        } else if shown, r.selected != drawnSelection, !reduce, m.layerExists(withId: Self.routeLayer) {
            /* Another route picked: its line swells a moment, then settles. */
            popWork?.cancel()
            try? m.setLayerProperty(for: Self.routeLayer, property: "line-width", value: RouteReveal.popWidth)
            let w = DispatchWorkItem { [weak self] in
                guard let m = self?.map?.mapboxMap, m.layerExists(withId: Self.routeLayer) else { return }
                try? m.setLayerProperty(for: Self.routeLayer, property: "line-width", value: RouteReveal.selectedWidth)
            }
            popWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + RouteReveal.popSeconds, execute: w)
        }
        drawnSelection = r.selected
    }

    private func refresh() {
        guard let m = map?.mapboxMap, m.sourceExists(withId: Self.source) else { return }
        let hub = CampSitesHub.shared
        let sites = hub.layerOn ? CampSiteCatalog.all : CampSiteCatalog.all.filter { hub.highlighted[$0.id] != nil }
        m.updateGeoJSONSource(withId: Self.source, geoJSON: .featureCollection(Self.collection(sites, highlighted: hub.highlighted)))
        let vis = Self.visible(layerOn: hub.layerOn, highlighted: hub.highlighted) ? "visible" : "none"
        for id in [Self.circleLayer, Self.labelLayer] where m.layerExists(withId: id) {
            try? m.setLayerProperty(for: id, property: "visibility", value: vis)
        }
    }
}

/// «مخطط دروب البر» on the map: how the route preview reveals and how a pick pops.
/// Pure (`CampSitesTests`); Mapbox paint transitions do the easing, never a frame loop.
enum RouteReveal {
    enum Kind { case selected, other, hard }

    static let selectedWidth = 5.5
    /// The picked line swells to this, then settles back.
    static let popWidth = 8.0
    static let popSeconds: TimeInterval = 0.18
    static let revealMs = 450

    static var transition: [String: Any] { ["duration": revealMs, "delay": 0] }
    static var popTransition: [String: Any] { ["duration": Int(popSeconds * 1000), "delay": 0] }

    /// Each layer's opacity: zero while there is no preview, so the next one fades in from nothing.
    static func opacity(_ k: Kind, shown: Bool) -> Double {
        guard shown else { return 0 }
        switch k {
        case .selected: return 1
        case .other: return 0.6
        case .hard: return 0.55
        }
    }
}

/// «الطبقات» → «أماكن مقترحة للكشتة».
struct CampSitesLayerSection: View {
    @ObservedObject var controller: LiveOutingController
    @ObservedObject private var hub = CampSitesHub.shared
    @Environment(\.sary) private var theme

    var body: some View {
        SarySection(title: "الكشتة", footer: "\(CampReason.estimateNote). مواقع مرشحة من صور أقمار وبيانات مفتوحة (الثمامة، الدهناء، النفود)، بعيدة عن مجاري السيول والسبخات والعمران. \(CampReason.legalNote).") {
            VStack(spacing: theme.space(.s)) {
                SaryToggleRow(title: "أماكن مقترحة للكشتة", subtitle: "نقاط برتقالية على الخريطة",
                              systemImage: "tent.fill", isOn: $hub.layerOn, id: "explore-camp-sites")
                    .padding(.horizontal, theme.space(.m))
                SaryNavRow(title: "اقترح لي مكان كشتة", detail: "أفضل خمسة مواقع وطقس الليلة",
                           systemImage: "tent", id: "explore-camp-suggest") {
                    controller.performAction("camp")
                }
                .padding(.horizontal, theme.space(.m))
            }
        }
    }
}

/// «حول» → the open data behind the camp sites (licences require the attribution).
struct CampSitesAttributionNotice: View {
    @Environment(\.sary) private var theme

    static let lines = [
        "أماكن الكشتة المقترحة: تقدير من صور الأقمار وبيانات مفتوحة.",
        "© ESA WorldCover project 2021 / Contains modified Copernicus Sentinel data (2021) processed by ESA WorldCover consortium (CC BY 4.0).",
        "Copernicus DEM GLO-30: produced using Copernicus WorldDEM-30 © DLR e.V. 2010-2014 and © Airbus Defence and Space GmbH 2014-2018 provided under COPERNICUS by the European Union and ESA; all rights reserved.",
        "Contains modified Copernicus Sentinel data 2025–2026.",
        "© OpenStreetMap contributors (ODbL).",
        "بيانات الطقس: Open-Meteo.com (CC BY 4.0).",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space(.xs)) {
            ForEach(Self.lines, id: \.self) { l in
                Text(l).saryText(.footnote).foregroundStyle(theme.palette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("about.campSites")
    }
}
