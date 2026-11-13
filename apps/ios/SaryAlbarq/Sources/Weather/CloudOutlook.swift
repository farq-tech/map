import Foundation

/// «السحاب يمشي وين؟» (phase 2): where the cloud over a point is heading and when dense cloud
/// would reach it, as estimated by our API from two MTG frames 30 min apart
/// (`GET /api/weather/clouds/outlook`, docs/weather-clouds-phase2.md).
///
/// The satellite pictures are delayed (≥ 1 h, or the newest on-the-hour one), so every sentence
/// says how old the picture is, carries a margin, and the whole thing disappears when the server's
/// confidence is low: silence is better than a confident wrong arrow.
struct CloudOutlook: Decodable, Equatable {
    struct Motion: Decodable, Equatable {
        var bearing_deg: Double?
        var speed_kmh: Double
    }

    var ok: Bool
    /// `approaching` / `overhead` / `arrived` / `clear` / `stationary` / `uncertain`.
    var state: String
    var confidence: Double
    var min_confidence: Double?
    var motion: Motion?
    var eta_minutes: Int?
    var clearing_minutes: Int?
    var margin_minutes: Int?
    var distance_km: Int?
    var scanned_km: Int?
    var image_age_min: Int?
}

/// Who the estimate is for: the person's own position or the chosen destination.
enum CloudOutlookSubject: Equatable {
    case me
    case destination
    /// No destination and no fix: the middle of the map being looked at.
    case mapCenter

    var at: String {
        switch self {
        case .me: return "عندك"
        case .destination: return "عند وجهتك"
        case .mapCenter: return "عند منتصف الخريطة"
        }
    }
    var reach: String {
        switch self {
        case .me: return "يصلك"
        case .destination: return "يصل وجهتك"
        case .mapCenter: return "يصل منتصف الخريطة"
        }
    }
    var over: String {
        switch self {
        case .me: return "السحاب فوقك"
        case .destination: return "السحاب فوق وجهتك"
        case .mapCenter: return "السحاب فوق منتصف الخريطة"
        }
    }
}

enum CloudOutlookPresenter {
    /// Below this the arrow and the line are hidden (the server applies the same floor).
    static let minConfidence = 0.45

    struct Display: Equatable {
        /// Where the cloud moves toward, degrees clockwise from north; nil = no arrow (stationary).
        var arrowDegrees: Double?
        /// Estimated cloud speed (km/h) when there is a direction; drives the on-map streaks.
        var speedKmh: Double?
        var headline: String
        var detail: String
        /// Always present: the picture's age and what the estimate is not.
        var footnote: String
    }

    static func display(_ o: CloudOutlook, subject: CloudOutlookSubject = .me) -> Display? {
        guard o.ok, o.state != "uncertain", o.confidence >= max(minConfidence, o.min_confidence ?? 0) else { return nil }
        guard let motion = o.motion else { return nil }
        let age = o.image_age_min.map { "بحسب صور قبل \(ageText($0))" } ?? "بحسب آخر صور القمر"
        let foot = "\(age) · مو حيّة، وهذا تقدير لحركة السحاب فقط، مو توقع مطر"
        let at = subject.at
        let reach = subject.reach
        let margin = o.margin_minutes.map { " (±\(durationText($0)))" } ?? ""

        if o.state == "stationary" {
            return Display(arrowDegrees: nil, speedKmh: nil, headline: "السحاب شبه ثابت", detail: "ما نقدّر وقت وصوله \(at)", footnote: foot)
        }
        guard let bearing = motion.bearing_deg else { return nil }
        let head = "السحاب يتجه \(directionText(bearing)) بسرعة ~\(SaryFormat.number(Int(motion.speed_kmh.rounded()))) كم/س"
        switch o.state {
        case "approaching":
            guard let eta = o.eta_minutes else { return nil }
            return Display(arrowDegrees: bearing, speedKmh: motion.speed_kmh, headline: head, detail: "سحاب كثيف \(reach) بعد ~\(durationText(eta))\(margin)", footnote: foot)
        case "overhead":
            var d = subject.over + " وقت الصورة"
            if let c = o.clearing_minutes { d += "، ويبتعد بعد ~\(durationText(c))\(margin)" }
            return Display(arrowDegrees: bearing, speedKmh: motion.speed_kmh, headline: head, detail: d, footnote: foot)
        case "arrived":
            return Display(arrowDegrees: bearing, speedKmh: motion.speed_kmh, headline: head, detail: "غالبًا وصل \(at) أو مرّ؛ الصورة أقدم من وصوله", footnote: foot)
        case "clear":
            let km = o.scanned_km.map { " ضمن ~\(SaryFormat.number($0)) كم" } ?? ""
            return Display(arrowDegrees: bearing, speedKmh: motion.speed_kmh, headline: head, detail: "ما نشوف سحابًا كثيفًا جاي \(at)\(km)", footnote: foot)
        default:
            return nil
        }
    }

    /// «شرقًا», «شمال شرقي»… (where it goes, 8 points).
    static func directionText(_ bearing: Double) -> String {
        let names = ["شمالًا", "شمال شرقي", "شرقًا", "جنوب شرقي", "جنوبًا", "جنوب غربي", "غربًا", "شمال غربي"]
        let i = Int(((bearing.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 45).rounded()) % 8
        return names[i]
    }

    /// «٤٥ دقيقة», «ساعة ونصف», «ساعتين», «٣ ساعات»: rounded so it never claims more precision than it has.
    static func durationText(_ minutes: Int) -> String {
        let m = max(0, minutes)
        if m < 5 { return "دقائق قليلة" }
        if m < 60 { return "\(SaryFormat.number(Int((Double(m) / 5).rounded()) * 5)) دقيقة" }
        let q = Int((Double(m) / 15).rounded()) * 15
        let h = q / 60, r = q % 60
        let hours: String
        switch h {
        case 1: hours = "ساعة"
        case 2: hours = "ساعتين"
        case 3...10: hours = "\(SaryFormat.number(h)) ساعات"
        default: hours = "\(SaryFormat.number(h)) ساعة"
        }
        switch r {
        case 0: return hours
        case 30: return "\(hours) ونصف"
        case 15: return "\(hours) وربع"
        default: return "\(hours) و\(SaryFormat.number(r)) دقيقة"
        }
    }

    /// «ساعة ونصف» for the picture's age (same wording as the timeline's age label).
    static func ageText(_ minutes: Int) -> String {
        if minutes < 1 { return "لحظات" }
        if minutes < 60 { return "\(SaryFormat.number(minutes)) دقيقة" }
        let h = minutes / 60, m = minutes % 60
        let hours = h == 1 ? "ساعة" : h == 2 ? "ساعتين" : h <= 10 ? "\(SaryFormat.number(h)) ساعات" : "\(SaryFormat.number(h)) ساعة"
        if m == 0 { return hours }
        if m == 30 { return "\(hours) ونصف" }
        return "\(hours) و\(SaryFormat.number(m)) دقيقة"
    }
}

/// «السحاب يمشي وين؟» is still being read on the server for this cell: say so, retry soon, never show an error.
enum CloudOutlookError: Error, Equatable {
    case warming(retryAfterS: Int)
}

extension WeatherLayerAPI {
    static func cloudOutlook(lat: Double, lng: Double, base: URL = Endpoints.apiBase, session: URLSession = .shared) async throws -> CloudOutlook {
        var c = URLComponents(url: base.appendingPathComponent("api/weather/clouds/outlook"), resolvingAgainstBaseURL: false)!
        c.queryItems = [.init(name: "lat", value: String(format: "%.3f", lat)), .init(name: "lng", value: String(format: "%.3f", lng))]
        /* The server reads three slow satellite pictures the first time for a 1° cell (measured 50–170 s). */
        var req = URLRequest(url: c.url!, timeoutInterval: 240)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode
        /* The server answers 202 {error:"warming", retry_after_s} while it reads the satellite pictures of a cold cell
         * (PR #267): that is «جارٍ التسخين», not a failure. */
        if status == 202 {
            let retry = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["retry_after_s"] as? Int ?? 30
            throw CloudOutlookError.warming(retryAfterS: min(max(retry, 10), 120))
        }
        guard status == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(CloudOutlook.self, from: data)
    }
}
