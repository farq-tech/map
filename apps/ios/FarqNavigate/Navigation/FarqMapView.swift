import CoreLocation
import FerrostarCore
import FerrostarCoreFFI
import MapboxMaps
import SwiftUI

/// The same map the web draws.
///
/// Farq's web map renders `mapbox://styles/mapbox/standard`, and a native app
/// that looks like a different product is a different product to whoever is
/// holding it. So this renders the identical style from the identical account,
/// and the app pays for that in one specific way worth naming: Ferrostar ships
/// a complete navigation map view, but only for MapLibre. Everything below the
/// style — the route line, the puck, the camera that follows you — is written
/// here instead of inherited.
///
/// What is *not* rewritten is the part that matters most: `FerrostarCore` never
/// imports a renderer, and neither does `FerrostarSwiftUI`. The guidance, the
/// manoeuvre banner, the trip progress and the spoken instructions are the same
/// code they would be on MapLibre.
struct FarqMapView: View {
    /// Every observed opportunity in the city, drawn as the field of pins the
    /// web draws — clustered while the whole city is in view.
    let opportunities: [Opportunity]
    /// The حي boundaries and their server-computed numbers.
    let districts: FeatureCollection?
    /// What the حي colour means right now.
    let lens: DistrictLens
    /// The route being followed, if any. Drawn as a line under the puck.
    let route: Route?
    /// Where the map should draw you: the snapped position while you are on a
    /// route, the raw fix otherwise. One value, shared by the car, the photo
    /// and the camera — see `FarqLocationSource`.
    let userLocation: CLLocationCoordinate2D?
    /// The same position as a stream, so Mapbox's own puck stops running on
    /// its own private CLLocationManager.
    let locationStream: FarqLocationStream
    /// True once guidance is running — the camera behaves differently then.
    let isNavigating: Bool
    /// Your photo and your car, if you chose them.
    @ObservedObject var profile: UserProfile
    /// A pin was tapped. Clusters are handled here; places go up to the screen.
    let onSelectPlace: (String) -> Void
    /// A حي was tapped: its id and the name to show for it.
    let onSelectDistrict: (String, String) -> Void
    /// Which حي is outlined right now.
    let selectedDistrictId: String?
    /// Where the camera has been asked to go, if anywhere.
    let focus: MapFocus?

    @State private var viewport: Viewport = .camera(
        /* Riyadh, as a starting view. Not presented as the user's location: the
         * puck appears only when the phone reports a real fix. */
        center: CLLocationCoordinate2D(latitude: 24.7136, longitude: 46.6753),
        zoom: 12.15,
        bearing: 0,
        pitch: 0
    )

    var body: some View {
        MapReader { proxy in
            farqMap(proxy)
        }
    }

    private var districtsSignature: Int { districts?.features.count ?? 0 }

    private func select(_ feature: QueriedFeature) -> Bool {
        guard case .string(let id)? = feature.feature.properties?["place_id"] ?? nil
        else { return false }
        onSelectPlace(id)
        return true
    }

    private func apply(to mapbox: MapboxMap) {
        if let districts { FarqField.setDistricts(districts, on: mapbox) }
        FarqField.setOpportunities(opportunities, on: mapbox)
        FarqField.setLens(lens, on: mapbox)
        FarqField.setSelectedDistrict(selectedDistrictId, on: mapbox)
    }

    private func farqMap(_ proxy: MapProxy) -> some View {
        Map(viewport: $viewport) {
            if let coordinates = routeCoordinates, coordinates.count > 1 {
                /* Casing under line, the way every legible route is drawn: the
                 * darker edge is what separates it from the road beneath it. */
                PolylineAnnotationGroup {
                    PolylineAnnotation(lineCoordinates: coordinates)
                        .lineColor(StyleColor(UIColor(red: 0.02, green: 0.20, blue: 0.20, alpha: 1)))
                        .lineWidth(13)
                        .lineJoin(.round)
                        .lineEmissiveStrength(1)
                }
                .layerId("farq-route-casing")
                .slot(.middle)

                PolylineAnnotationGroup {
                    PolylineAnnotation(lineCoordinates: coordinates)
                        /* Farq mint — the same accent the web map uses for the
                         * thing you are looking at. */
                        .lineColor(StyleColor(UIColor(red: 0.51, green: 0.95, blue: 0.69, alpha: 1)))
                        .lineWidth(8)
                        .lineJoin(.round)
                        /* Emissive, like every Farq layer over this basemap:
                         * dusk otherwise dims the mint into the road under it,
                         * and the route stops being the brightest thing on a
                         * screen someone is following at speed. */
                        .lineEmissiveStrength(1)
                }
                .layerId("farq-route")
                .slot(.middle)
            }

            /* Where you are, and nothing more.
             *
             * This was a car with your photo above it, and it is a plain puck
             * now because a car is a claim: it says you are driving, which the
             * map does not know, and it points somewhere, which a stationary
             * phone cannot tell it. The dot says the one thing that is true —
             * this is where you are — and says it at every zoom without
             * competing with the prices, which are the point of the screen.
             *
             * Bearing still comes from the course while moving; Mapbox leaves
             * it alone when the device reports none, which is the honest
             * behaviour rather than pointing north by default. */
            Puck2D(bearing: .course)
                .showsAccuracyRing(true)
        }
        /* The web's basemap: dusk, with every label the basemap wants to add
         * turned off. Farq's own labels are the point of the picture, and
         * Mapbox's shields and place names fight them for the same pixels.
         *
         * Place labels go too, which the web keeps — and that difference is
         * deliberate rather than an omission. The web turns them Arabic with
         * `map.setLanguage("ar")`, a GL JS call with no iOS equivalent: this
         * SDK's Standard import accepts a `language` config and ignores it
         * (measured — setting it to Japanese changed nothing either), and
         * `localizeLabels` rewrites `text-field` only on the root style, which
         * holds no symbol layers at all under Standard. Latin district names on
         * an Arabic product read worse than none, so the أحياء speak with
         * Farq's own names, from Farq's own data, at every zoom. */
        .mapStyle(
            MapStyle(
                uri: .standard,
                configuration: [
                    "lightPreset": "dusk",
                    "showPointOfInterestLabels": false,
                    "showTransitLabels": false,
                    "showRoadLabels": false,
                    "showPlaceLabels": false,
                    /* Off, exactly as the web turns them off on a phone. Riyadh
                     * at dusk with 3D buildings and landmarks is a beautiful
                     * still and a stuttering pan, and a map you are moving is
                     * worth more than a map you are admiring. */
                    "show3dObjects": false,
                ]
            )
        )
        /* Every layer that draws a place is tappable, because on a phone the
         * pin is the control: there is no hover to reveal what it is, and a map
         * that answers nothing when you touch it reads as a picture. */
        .onLayerTapGesture(FarqField.pinIcons) { feature, _ in
            select(feature)
        }
        .onLayerTapGesture(FarqField.pinCircles) { feature, _ in
            select(feature)
        }
        /* A cluster is not a place and must not pretend to be one; tapping it
         * goes in, which is the only honest answer to "what is in there". */
        .onLayerTapGesture(FarqField.clusterCircles) { _, context in
            let zoom = (proxy.map?.cameraState.zoom ?? 12) + 2
            withViewportAnimation(.easeOut(duration: 0.5)) {
                viewport = .camera(center: context.coordinate, zoom: zoom)
            }
            return true
        }
        /* The حي is the biggest thing on this map and was the only thing that
         * did not answer a touch. Its colour is a claim about the whole area;
         * tapping it should say which area, and what the claim is. */
        .onLayerTapGesture(FarqField.districtFill) { feature, _ in
            let properties = feature.feature.properties
            guard case .string(let id)? = properties?["district_id"] ?? nil
            else { return false }
            var name = id
            if case .string(let arabic)? = properties?["name_ar"] ?? nil, !arabic.isEmpty {
                name = arabic
            }
            onSelectDistrict(id, name)
            return true
        }
        .onStyleLoaded { _ in
            /* The map SDK ships its own location manager, and left alone the
             * puck listens to that one — a fourth opinion about where you are.
             * Overriding it is the fix: from here the car is drawn from the
             * same coordinate the route was built from. */
            proxy.location?.override(locationProvider: locationStream.signal)
            guard let mapbox = proxy.map else { return }
            do {
                try FarqField.install(on: mapbox)
            } catch {
                /* A field that fails to install must say so: silence here is
                 * indistinguishable from a city with nothing in it. */
                print("[farq-field] install failed: \(error)")
            }
            apply(to: mapbox)
        }
        .ignoresSafeArea()
        .onChange(of: districtsSignature) { _, _ in
            guard let mapbox = proxy.map else { return }
            apply(to: mapbox)
        }
        .onChange(of: opportunities.count) { _, _ in
            guard let mapbox = proxy.map else { return }
            apply(to: mapbox)
        }
        .onChange(of: lens) { _, next in
            guard let mapbox = proxy.map else { return }
            FarqField.setLens(next, on: mapbox)
        }
        .onChange(of: focus) { _, next in
            guard let next else { return }
            withViewportAnimation(.easeOut(duration: 0.7)) {
                switch next.target {
                case .bounds(let box) where box.count == 4:
                    /* Frame the whole حي from its own extent, with room for the
                     * chrome above and the sheet below. */
                    viewport = .overview(
                        geometry: Polygon([[
                            CLLocationCoordinate2D(latitude: box[1], longitude: box[0]),
                            CLLocationCoordinate2D(latitude: box[1], longitude: box[2]),
                            CLLocationCoordinate2D(latitude: box[3], longitude: box[2]),
                            CLLocationCoordinate2D(latitude: box[3], longitude: box[0]),
                            CLLocationCoordinate2D(latitude: box[1], longitude: box[0]),
                        ]]),
                        geometryPadding: .init(top: 150, leading: 30, bottom: 350, trailing: 30)
                    )
                case .bounds:
                    break
                case .user(let lat, let lng):
                    viewport = .camera(
                        center: CLLocationCoordinate2D(latitude: lat, longitude: lng),
                        zoom: 15.5,
                        bearing: 0,
                        pitch: 0
                    )
                }
            }
        }
        .onChange(of: selectedDistrictId) { _, next in
            guard let mapbox = proxy.map else { return }
            FarqField.setSelectedDistrict(next, on: mapbox)
        }
        .onChange(of: isNavigating) { _, navigating in
            withViewportAnimation(.easeOut(duration: 0.8)) {
                viewport = navigating
                    /* Following the puck, tilted, the way a driver reads a road
                     * ahead rather than a map from above. */
                    ? .followPuck(zoom: 16.5, bearing: .course, pitch: 45)
                    : .camera(zoom: 12, bearing: 0, pitch: 0)
            }
        }
        .onChange(of: route?.geometry.count ?? 0) { _, _ in
            guard !isNavigating, let coordinates = routeCoordinates, coordinates.count > 1 else { return }
            /* A route that has been planned but not started should be visible in
             * full — you are deciding whether to go, not going yet. */
            withViewportAnimation(.easeOut(duration: 0.6)) {
                viewport = .overview(
                    geometry: LineString(coordinates),
                    geometryPadding: .init(top: 90, leading: 40, bottom: 320, trailing: 40)
                )
            }
        }
    }

    private var routeCoordinates: [CLLocationCoordinate2D]? {
        guard let route else { return nil }
        return route.geometry.map {
            CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lng)
        }
    }
}
