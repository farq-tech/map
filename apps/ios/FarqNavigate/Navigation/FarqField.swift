import Foundation
import MapboxMaps
import UIKit

/// The district field and the opportunity pins — the same two things the web
/// map draws, with the same numbers and the same thresholds.
///
/// Sources and layers are added imperatively because this SDK version makes
/// layers declarable but not sources, and a layer without its source is a
/// runtime error rather than a compile one. The thresholds below are copied
/// from `apps/web/src/lib/farqDistrictTiles.ts` deliberately: they were chosen
/// by measuring colour separation on the live map, and a phone that picks its
/// own numbers is a second map claiming to be the first.
enum FarqField {
    static let districtSource = "farq-districts"
    static let districtFill = "farq-district-fill"
    static let districtLine = "farq-district-line"
    static let districtLabels = "farq-district-labels"
    static let opportunitySource = "farq-opportunities"
    static let clusterCircles = "farq-price-clusters"
    static let pinCircles = "farq-price-pins"

    /// The handover contract, unchanged from the web: the field fades out as the
    /// clusters fade in, so one picture changes resolution instead of two layers
    /// trading places.
    static let fillMaxZoom = 11.5
    static let fadeStart = 10.6
    static let appLensMaxZoom = 13.6
    static let lineMinZoom = 9.0
    static let lineMaxZoom = 14.5
    /// Clusters appear inside the district field's fade, so one picture hands
    /// over to the next instead of two layers trading places.
    static let handoverZoom = 10.9
    /// Above this a lone opportunity owns its own pin.
    static let clusterBreakZoom = 14.0

    static let mint = "#83f1b1"
    static let brand900 = "#043434"
    static let tooCloseGrey = "#94a3b8"

    static let providerColor: [String: String] = [
        "jahez": "#e8382a",
        "mrsool": "#1f52c8",
        "hungerstation": "#f2b500",
        "thechefz": "#9c3070",
        "toyou": "#00e5cd",
        "ninja": "#054e58",
        "keeta": "#d9a400",
        "brand_app": "#7a2a86",
        "mrmandoob": "#0f9b7a",
    ]

    // MARK: Install

    static func install(on map: MapboxMap) throws {
        if map.sourceExists(withId: districtSource) == false {
            var source = GeoJSONSource(id: districtSource)
            source.data = .featureCollection(FeatureCollection(features: []))
            /* Feature state and selection key off the district's own id — never
             * off its name, which is not unique across a city. */
            source.promoteId = .string("district_id")
            try map.addSource(source)
        }
        if map.sourceExists(withId: opportunitySource) == false {
            var source = GeoJSONSource(id: opportunitySource)
            source.data = .featureCollection(FeatureCollection(features: []))
            source.cluster = true
            /* A thumb needs more room than a cursor. */
            source.clusterRadius = 84
            source.clusterMaxZoom = clusterBreakZoom - 1
            /* A cluster shows the biggest gap it contains, not a sum: adding up
             * separate restaurants' gaps would state a saving nobody can make. */
            source.clusterProperties = ["max_gap": Exp(.max) { Exp(.get) { "gap" } }]
            try map.addSource(source)
        }

        if map.layerExists(withId: districtFill) == false {
            var fill = FillLayer(id: districtFill, source: districtSource)
            fill.maxZoom = fillMaxZoom
            fill.fillColor = .constant(StyleColor(hex: mint))
            fill.fillEmissiveStrength = .constant(1)
            fill.fillOpacity = .expression(gapOpacity)
            /* No explicit position: the layers below are added in the order
             * they should stack, and naming a layer that does not exist yet
             * throws and takes the whole field down with it. */
            try map.addLayer(fill)
        }
        if map.layerExists(withId: districtLine) == false {
            var line = LineLayer(id: districtLine, source: districtSource)
            line.minZoom = lineMinZoom
            line.maxZoom = lineMaxZoom
            line.lineColor = .constant(StyleColor(hex: brand900))
            line.lineWidth = .constant(0.6)
            line.lineOpacity = .constant(0.22)
            try map.addLayer(line)
        }
        if map.layerExists(withId: districtLabels) == false {
            var labels = SymbolLayer(id: districtLabels, source: districtSource)
            /* These outlive the fill. With the basemap's own place labels off,
             * they are the only thing naming where you are, so they hold until
             * the pins own the picture. */
            labels.maxZoom = clusterBreakZoom
            /* Name above, biggest gap below with its unit — a bare number on a
             * polygon reads as a rank, and this is riyals. */
            labels.textField = .expression(
                Exp(.concat) {
                    Exp(.coalesce) { Exp(.get) { "name_ar" }; "" }
                    "\n"
                    Exp(.concat) {
                        Exp(.toString) { Exp(.coalesce) { Exp(.get) { "max_gap" }; "" } }
                        " ر.س"
                    }
                }
            )
            labels.textSize = .constant(12)
            labels.textColor = .constant(StyleColor(hex: brand900))
            labels.textHaloColor = .constant(StyleColor(UIColor.white))
            labels.textHaloWidth = .constant(1.2)
            /* Over the field, only the busiest few speak and the rest are
             * colour; once the field has faded there is nothing else naming the
             * city, so every حي may. */
            labels.filter = Exp(.any) {
                Exp(.gte) { Exp(.coalesce) { Exp(.get) { "opportunities" }; 0 }; 40 }
                Exp(.gt) { Exp(.zoom); fillMaxZoom }
            }
            labels.textOptional = .constant(false)
            try map.addLayer(labels)
        }

        try installDiscs(on: map)

        if map.layerExists(withId: clusterCircles) == false {
            var clusters = SymbolLayer(id: clusterCircles, source: opportunitySource)
            clusters.minZoom = handoverZoom
            clusters.maxZoom = clusterBreakZoom
            clusters.filter = Exp(.has) { "point_count" }
            clusters.iconImage = .expression(
                Exp(.step) {
                    Exp(.get) { "point_count" }
                    "farq-cluster-sm"
                    12; "farq-cluster-md"
                    40; "farq-cluster-lg"
                }
            )
            clusters.iconAllowOverlap = .constant(true)
            /* The biggest gap inside, then how many opportunities it stands for —
             * a cluster that showed only a count would say how crowded the area
             * is, which is not the question anyone came with. */
            clusters.textField = .expression(
                Exp(.concat) {
                    Exp(.toString) { Exp(.round) { Exp(.coalesce) { Exp(.get) { "max_gap" }; 0 } } }
                    "\n"
                    Exp(.toString) { Exp(.get) { "point_count" } }
                }
            )
            clusters.textSize = .constant(13)
            clusters.textLineHeight = .constant(1.05)
            clusters.textColor = .constant(StyleColor(hex: brand900))
            clusters.textAllowOverlap = .constant(true)
            try map.addLayer(clusters)
        }

        if map.layerExists(withId: pinCircles) == false {
            var pins = SymbolLayer(id: pinCircles, source: opportunitySource)
            pins.minZoom = handoverZoom
            pins.filter = Exp(.not) { Exp(.has) { "point_count" } }
            /* Sized by the approved tier, not by taste: a hero is a top-decile
             * gap (≥36 ر.س), a faint one is below the typical gap and shows no
             * number at all. */
            pins.iconImage = .expression(
                Exp(.step) {
                    gapValue
                    "farq-disc-faint"
                    5; "farq-disc-regular"
                    15; "farq-disc-strong"
                    36; "farq-disc-hero"
                }
            )
            /* Collision on, biggest gap first, so density never turns into noise
             * and the pixel a pin wins is the one worth the most riyals. */
            pins.iconAllowOverlap = .constant(false)
            pins.textAllowOverlap = .constant(false)
            pins.iconOptional = .constant(false)
            pins.symbolSortKey = .expression(Exp(.product) { gapValue; -1 })
            pins.textField = .expression(
                Exp(.switchCase) {
                    Exp(.gte) { gapValue; 5 }
                    Exp(.toString) { Exp(.round) { gapValue } }
                    ""
                }
            )
            pins.textSize = .expression(
                Exp(.step) {
                    gapValue
                    0.0
                    5; 12.0
                    15; 13.0
                    36; 15.0
                }
            )
            pins.textColor = .constant(StyleColor(hex: brand900))
            try map.addLayer(pins)
        }
    }

    /// The observed gap, as a number, with a missing one reading as zero *here
    /// only* — a pin with no gap falls into the faint tier and shows no number,
    /// which is the honest rendering of "no difference observed".
    private static var gapValue: Exp {
        Exp(.number) { Exp(.coalesce) { Exp(.get) { "gap" }; 0 } }
    }

    /// The mint discs, drawn once and handed to the GPU as images.
    ///
    /// Symbols rather than circles because collision is the whole point: 5,075
    /// opportunities drawn as circles is 5,075 circles, and the map stops being
    /// readable long before it stops being correct.
    private static func installDiscs(on map: MapboxMap) throws {
        let sizes: [(String, CGFloat)] = [
            ("farq-disc-faint", 14),
            ("farq-disc-regular", 24),
            ("farq-disc-strong", 30),
            ("farq-disc-hero", 38),
            ("farq-cluster-sm", 40),
            ("farq-cluster-md", 48),
            ("farq-cluster-lg", 56),
        ]
        for (id, diameter) in sizes where map.imageExists(withId: id) == false {
            try map.addImage(disc(diameter: diameter), id: id)
        }
    }

    private static func disc(diameter: CGFloat) -> UIImage {
        let border: CGFloat = 1.5
        let size = CGSize(width: diameter + border * 2, height: diameter + border * 2)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: border / 2, dy: border / 2)
            let path = UIBezierPath(ovalIn: rect)
            UIColor(hex: mint).setFill()
            path.fill()
            UIColor.white.setStroke()
            path.lineWidth = border
            path.stroke()
        }
    }

    // MARK: Data

    static func setDistricts(_ collection: FeatureCollection, on map: MapboxMap) {
        map.updateGeoJSONSource(withId: districtSource, geoJSON: .featureCollection(collection))
    }

    static func setOpportunities(_ opportunities: [Opportunity], on map: MapboxMap) {
        let features: [Feature] = opportunities.map { opportunity in
            var feature = Feature(geometry: .point(Point(opportunity.coordinate)))
            feature.identifier = .string(opportunity.id)
            feature.properties = [
                "place_id": .string(opportunity.id),
                /* No observed gap stays absent rather than becoming a zero — a
                 * pin labelled 0 claims a comparison that found no difference. */
                "gap": opportunity.gap.map { JSONValue.number($0) },
                "name": .string(opportunity.name),
            ]
            return feature
        }
        map.updateGeoJSONSource(
            withId: opportunitySource,
            geoJSON: .featureCollection(FeatureCollection(features: features))
        )
    }

    // MARK: Lens

    /// Repaint the field for the chosen lens without touching the source or the
    /// camera — the two lenses read the same server numbers.
    static func setLens(_ lens: DistrictLens, on map: MapboxMap) {
        let app = lens == .app
        try? map.updateLayer(withId: districtFill, type: FillLayer.self) { layer in
            layer.maxZoom = app ? appLensMaxZoom : fillMaxZoom
            layer.fillColor = app ? .expression(appColor) : .constant(StyleColor(hex: mint))
            layer.fillOpacity = .expression(app ? appOpacity : gapOpacity)
        }
    }

    // MARK: Expressions

    /// How strongly a حي is tinted by how many observed opportunities it holds.
    private static var fillByCount: Exp {
        Exp(.step) {
            Exp(.coalesce) { Exp(.get) { "opportunities" }; 0 }
            0.0
            1; 0.12
            10; 0.22
            40; 0.34
            120; 0.46
        }
    }

    private static var gapOpacity: Exp {
        Exp(.interpolate) {
            Exp(.linear)
            Exp(.zoom)
            fadeStart; fillByCount
            fillMaxZoom; 0.0
        }
    }

    /// Enough comparisons and a clear leader — anything else is not painted for
    /// an app, because "no clear winner" and "not enough data" are two different
    /// answers and neither of them is a win.
    private static var appColor: Exp {
        Exp(.switchCase) {
            Exp(.eq) { Exp(.get) { "app_verdict_too_close" }; true }
            UIColor(hex: tooCloseGrey)
            Exp(.match) {
                Exp(.coalesce) { Exp(.get) { "cheapest_app" }; "" }
                "jahez"; UIColor(hex: "#e8382a")
                "mrsool"; UIColor(hex: "#1f52c8")
                "hungerstation"; UIColor(hex: "#f2b500")
                "thechefz"; UIColor(hex: "#9c3070")
                "toyou"; UIColor(hex: "#00e5cd")
                "ninja"; UIColor(hex: "#054e58")
                "keeta"; UIColor(hex: "#d9a400")
                "brand_app"; UIColor(hex: "#7a2a86")
                "mrmandoob"; UIColor(hex: "#0f9b7a")
                /* An app we have no colour for is still not "an opportunity" —
                 * grey, never mint. */
                UIColor(hex: tooCloseGrey)
            }
        }
    }

    /// Opacity carries confidence, so a narrow win is drawn faintly on purpose.
    /// The ladder starts at 0.34 because at the old 0.20 floor the two closest
    /// app colours sat ΔE 8.4 apart — a difference you find only by looking for
    /// it, in the most common case on the map.
    private static var appOpacityAtFull: Exp {
        Exp(.switchCase) {
            Exp(.all) {
                Exp(.eq) { Exp(.get) { "enough_for_app_verdict" }; true }
                Exp(.has) { "cheapest_app" }
            }
            Exp(.step) {
                Exp(.coalesce) { Exp(.get) { "cheapest_app_margin" }; 0 }
                0.34
                15; 0.44
                30; 0.56
            }
            Exp(.eq) { Exp(.get) { "app_verdict_too_close" }; true }
            0.24
            0.0
        }
    }

    private static var appOpacity: Exp {
        Exp(.interpolate) {
            Exp(.linear)
            Exp(.zoom)
            fadeStart; appOpacityAtFull
            12.6; appOpacityAtFull
            appLensMaxZoom; 0.0
        }
    }
}

extension UIColor {
    /// `#rrggbb`, the way every colour in this app is written down.
    convenience init(hex: String) {
        let clean = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        let value = UInt32(clean, radix: 16) ?? 0
        let red = CGFloat((value >> 16) & 0xFF) / 255
        let green = CGFloat((value >> 8) & 0xFF) / 255
        let blue = CGFloat(value & 0xFF) / 255
        self.init(red: red, green: green, blue: blue, alpha: 1)
    }
}

extension StyleColor {
    init(hex: String) { self.init(UIColor(hex: hex)) }
}
