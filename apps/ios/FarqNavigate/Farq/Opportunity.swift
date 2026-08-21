import CoreLocation
import Foundation

/// Where to actually send someone, decided by the API rather than here.
///
/// This mirrors `navigate_to` in apps/api/lib/place-navigation.js, and the
/// reason it is a server decision is measured: a canonical restaurant carries
/// one pin, but each delivery app lists its own branch, and 591 Riyadh
/// opportunities have the cheapest branch more than a kilometre from the pin —
/// the worst by 28.7 km. The client must not second-guess it, and must not
/// invent a destination when the server declined to name one.
struct NavigateTo: Decodable {
    /// `branch` the cheapest app's own pin · `place` the restaurant pin · nil unknown
    enum Source: String, Decodable { case branch, place }

    enum Confidence: String, Decodable {
        case exactBranch = "exact-branch"
        case placePin = "place-pin"
        case placePinApproximate = "place-pin-approximate"
        /// The listing covers several branches and the server will not guess.
        case ambiguousBranch = "ambiguous-branch"
        case unknown
    }

    let lat: Double?
    let lng: Double?
    let source: Source?
    let provider: String?
    let confidence: Confidence
    let reason: String?

    /// Nil is the honest answer whenever either half is missing. A partially
    /// supplied coordinate is not a place; it is half of one.
    var coordinate: CLLocationCoordinate2D? {
        guard let lat, let lng, lat.isFinite, lng.isFinite else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }

    /// What to say when there is no destination, or when there is a weaker one
    /// than the button implies. Nil for the ordinary case — 96% of destinations
    /// are the exact branch, and labelling all of them would be noise.
    var caution: String? {
        switch confidence {
        case .ambiguousBranch:
            return "هذا الاسم يغطي أكثر من فرع، وما نعرف أي فرع فيه هذا السعر"
        case .placePinApproximate:
            return "الموقع تقريبي — التطبيق ما نشر إحداثيات فرعه"
        case .unknown:
            return "ما عندنا موقع مرصود لهذا المكان"
        case .exactBranch, .placePin:
            return nil
        }
    }
}

/// One observed price difference at one place.
///
/// Built from the wire format rather than decoded from it: a coordinate is a
/// CoreLocation type and the API speaks GeoJSON, and forcing one to be the
/// other would put decoding concerns inside the model.
struct Opportunity: Identifiable {
    let id: String
    let name: String
    let gap: Double?
    let productName: String?
    let cheapestProvider: String?
    let cheapestPrice: Double?
    let expensivePrice: Double?
    let comparisons: Int
    let districtId: String?
    let navigateTo: NavigateTo?
    let coordinate: CLLocationCoordinate2D

    /// Can we honestly offer to take someone here?
    var destination: CLLocationCoordinate2D? { navigateTo?.coordinate }
}

// MARK: - GeoJSON decoding

/// The API answers GeoJSON, so the shapes below exist only to unwrap it. They
/// are deliberately separate from `Opportunity`: the wire format is the API's
/// business and the model is the app's.
struct OpportunityCollection: Decodable {
    let features: [Feature]
    let city: String?
    let generatedAt: String?

    struct Feature: Decodable {
        let geometry: Geometry
        let properties: Properties
    }

    struct Geometry: Decodable {
        let coordinates: [Double]
    }

    struct Properties: Decodable {
        let placeId: String
        let name: String
        let gap: Double?
        let productName: String?
        let cheapestProviderId: String?
        let cheapestPrice: Double?
        let expensivePrice: Double?
        let comparisons: Int?
        let districtId: String?
        let navigateTo: NavigateTo?

        enum CodingKeys: String, CodingKey {
            case placeId = "place_id"
            case name
            case gap
            case productName = "product_name"
            case cheapestProviderId = "cheapest_provider_id"
            case cheapestPrice = "cheapest_price"
            case expensivePrice = "expensive_price"
            case comparisons
            case districtId = "district_id"
            case navigateTo = "navigate_to"
        }
    }

    enum CodingKeys: String, CodingKey {
        case features, city
        case generatedAt = "generated_at"
    }

    var opportunities: [Opportunity] {
        features.compactMap { feature in
            /* GeoJSON is [longitude, latitude] — in that order, always. Getting
             * this backwards puts Riyadh in the Indian Ocean and nothing errors. */
            guard feature.geometry.coordinates.count >= 2 else { return nil }
            let lng = feature.geometry.coordinates[0]
            let lat = feature.geometry.coordinates[1]
            guard lat.isFinite, lng.isFinite else { return nil }
            let p = feature.properties
            return Opportunity(
                id: p.placeId,
                name: p.name,
                gap: p.gap,
                productName: p.productName,
                cheapestProvider: p.cheapestProviderId,
                cheapestPrice: p.cheapestPrice,
                expensivePrice: p.expensivePrice,
                comparisons: p.comparisons ?? 0,
                districtId: p.districtId,
                navigateTo: p.navigateTo,
                coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lng)
            )
        }
    }
}
