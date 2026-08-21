import Foundation
import MapboxMaps

/// The live Farq map API. Public, read-only, no key.
///
/// It answers 503 rather than an empty 200 when its read layer produced nothing
/// for a city we serve, so an empty list here really does mean "nothing
/// matched" and not "the pipeline broke" — that distinction is enforced on the
/// server and this client is allowed to rely on it.
struct FarqAPI {
    enum Failure: LocalizedError {
        case unreachable(String)
        case dataUnavailable
        case unexpected(Int)

        var errorDescription: String? {
            switch self {
            case .unreachable(let why): return "ما قدرنا نوصل للخدمة: \(why)"
            case .dataUnavailable: return "بيانات المدينة غير متاحة الآن"
            case .unexpected(let code): return "رد غير متوقع من الخدمة (\(code))"
            }
        }
    }

    var baseURL = URL(string: "https://farq-map-investor.vercel.app")!
    var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.waitsForConnectivity = true
        return URLSession(configuration: config)
    }()

    func opportunities(city: String = "riyadh") async throws -> [Opportunity] {
        let url = baseURL
            .appendingPathComponent("api/intelligence/map/city/\(city)/opportunities")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: url)
        } catch {
            throw Failure.unreachable(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else { throw Failure.unexpected(0) }
        switch http.statusCode {
        case 200: break
        /* The server says its own data is not worth serving. Believe it rather
         * than showing an empty map as if the city had nothing in it. */
        case 503: throw Failure.dataUnavailable
        default: throw Failure.unexpected(http.statusCode)
        }

        let collection = try JSONDecoder().decode(OpportunityCollection.self, from: data)
        return collection.opportunities
    }
}

extension FarqAPI {
    /// The city's أحياء, as the server decided them — geometric membership, its
    /// own opportunity counts, and its own verdict on which app wins where.
    ///
    /// Returned as a `FeatureCollection` because every number the map paints
    /// with lives in the feature properties, and re-deriving any of them here
    /// would let the phone and the web disagree about the same city.
    func districts(city: String = "riyadh") async throws -> FeatureCollection {
        let url = baseURL
            .appendingPathComponent("api/intelligence/map/city/\(city)/districts")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: url)
        } catch {
            throw Failure.unreachable(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw Failure.unexpected(0) }
        switch http.statusCode {
        case 200: break
        case 503: throw Failure.dataUnavailable
        default: throw Failure.unexpected(http.statusCode)
        }
        return try JSONDecoder().decode(FeatureCollection.self, from: data)
    }
}
