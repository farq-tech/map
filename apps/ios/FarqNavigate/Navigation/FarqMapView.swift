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
    /// Where the phone is, so the camera can follow it while navigating.
    let userLocation: CLLocationCoordinate2D?
    /// True once guidance is running — the camera behaves differently then.
    let isNavigating: Bool
    /// Your photo and your car, if you chose them.
    @ObservedObject var profile: UserProfile
    /// A pin was tapped. Clusters are handled here; places go up to the screen.
    let onSelectPlace: (String) -> Void

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

            /* Bearing from the course while moving; Mapbox leaves it alone when
             * the device reports none, which is the honest behaviour — a parked
             * car pointing north is a claim nobody made.
             *
             * The car appears only once a photo does. Drawing one under someone
             * who might be walking is a guess about how they are travelling,
             * and this map does not guess — without a photo the marker stays
             * the pulsing dot it has always been: a position, undecorated. */
            if let avatar = profile.avatar {
                Puck2D(bearing: .course)
                    .bearingImage(FarqVehicle.cachedCar(hex: profile.vehicleColor.hex))
                    .topImage(FarqVehicle.noTopImage)
                    .shadowImage(FarqVehicle.vehicleShadow())
                    /* A car is a thing of a fixed size on a road, not a fixed
                     * size on a screen: drawn at one scale it is a toy at city
                     * zoom and a bus at street zoom. This keeps it roughly the
                     * size of the lane it is in. */
                    .scale(
                        Exp(.interpolate) {
                            Exp(.linear)
                            Exp(.zoom)
                            10; 0.32
                            14; 0.55
                            17; 0.9
                        }
                    )
                    .showsAccuracyRing(false)

                /* The portrait rides as its own symbol rather than the puck's
                 * top image. The puck lies flat on the map, so under a tilted
                 * navigation camera the photo flattened into an ellipse — a
                 * face squashed into the asphalt. A symbol stays upright. */
                if let userLocation {
                    PointAnnotationGroup {
                        PointAnnotation(coordinate: userLocation)
                            .image(.init(
                                image: FarqVehicle.cachedAvatarPin(avatar),
                                name: "farq-user-avatar"
                            ))
                            .iconAnchor(.bottom)
                            .iconOffset(x: 0, y: -14)
                            .iconEmissiveStrength(1)
                    }
                    .layerId("farq-user-avatar-layer")
                    .iconAllowOverlap(true)
                    .iconIgnorePlacement(true)
                    .slot(.top)
                }
            } else {
                Puck2D(bearing: .course)
                    .showsAccuracyRing(true)
            }
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
        .onStyleLoaded { _ in
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
