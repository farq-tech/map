import Foundation

/// The text behind «انسخ الإحداثية» / «انسخ موقعي» / «شارك موقعي».
///
/// What a person READS uses Arabic-Indic digits; what is COPIED or put in a link
/// uses Western digits so it pastes into any other app. A stale fix is always
/// called «آخر موقع معروف قبل …», never «موقعي الحين».
enum CoordinateShare {
    /// Older than this, my fix is not "now".
    static let freshS = 60.0

    enum Format: String, CaseIterable { case decimal, dms }
    /// No Apple Maps: it does not work in Saudi Arabia (owner, build 21).
    enum MapLink: String, CaseIterable { case google, waze }

    struct Fix: Equatable {
        var point: LngLat
        var accuracyM: Double?
        var at: Date
    }

    // MARK: coordinates

    /// "24.71360, 46.67530" — lat, lng, 5 decimals (~1 m), Western digits.
    static func copyDecimal(_ p: LngLat) -> String { String(format: "%.5f, %.5f", p.lat, p.lng) }

    /// "24°42'49.0"N 46°40'31.1"E" — Western digits.
    static func copyDMS(_ p: LngLat) -> String { CoordinateParser.dmsString(p) }

    static func copy(_ p: LngLat, _ f: Format) -> String { f == .decimal ? copyDecimal(p) : copyDMS(p) }

    /// "٢٤٫٧١٣٦٠، ٤٦٫٦٧٥٣٠" for the screen: latitude first in Arabic reading order (right to left).
    static func displayDecimal(_ p: LngLat) -> String {
        SaryFormat.digits(String(format: "%.5f", p.lat)) + "، " + SaryFormat.digits(String(format: "%.5f", p.lng))
    }

    /// DMS for the screen, Arabic-Indic digits, the decimal separator «٫», in written order.
    static func displayDMS(_ p: LngLat) -> String {
        /* Arabic-Indic digits pull the °, ' and " between them into a right-to-left run;
         * an LRM after each symbol pins the order to how the notation is written. */
        var o = "\u{200E}"
        for ch in SaryFormat.digits(copyDMS(p)) {
            o.append(ch)
            if ch == "°" || ch == "'" || ch == "\"" || ch == " " { o.append("\u{200E}") }
        }
        return o
    }

    // MARK: links (Western digits only)

    static func link(_ p: LngLat, _ kind: MapLink, label: String? = nil) -> URL {
        ExternalNav.placeURL(kind.app, lat: p.lat, lng: p.lng)
    }

    /// Turn-by-turn in the other app, as a link (`ExternalNav.webURL`).
    static func directionsLink(_ p: LngLat, _ kind: MapLink) -> URL {
        ExternalNav.webURL(kind.app, lat: p.lat, lng: p.lng)
    }

    // MARK: my fix

    static func isFresh(_ f: Fix, now: Date) -> Bool { now.timeIntervalSince(f.at) <= freshS }

    /// «دقة ±٨ م».
    static func accuracyLabel(_ m: Double?) -> String? {
        guard let m, m.isFinite, m >= 0 else { return nil }
        return "دقة ±\(SaryFormat.distance(meters: max(1, m.rounded())))"
    }

    /// «٣:٤٥ م» in the device's time zone.
    static func clock(_ d: Date, timeZone: TimeZone = .current) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.hour, .minute], from: d)
        let h24 = c.hour ?? 0, m = c.minute ?? 0
        let h = h24 % 12 == 0 ? 12 : h24 % 12
        return SaryFormat.digits(String(format: "%d:%02d", h, m)) + (h24 < 12 ? " ص" : " م")
    }

    /// «موقعي الحين» or «آخر موقع معروف قبل ٥ د».
    static func headline(_ f: Fix, now: Date) -> String {
        isFresh(f, now: now) ? "موقعي الحين" : "آخر موقع معروف \(SaryFormat.elapsed(since: f.at, now: now))"
    }

    /// «انسخ موقعي»: "24.71360, 46.67530 — دقة ±٨ م — ٣:٤٥ م" (stale: led by «آخر موقع معروف قبل ٥ د:»).
    static func myLocationCopy(_ f: Fix, format: Format = .decimal, now: Date, timeZone: TimeZone = .current) -> String {
        var parts = [copy(f.point, format)]
        if let a = accuracyLabel(f.accuracyM) { parts.append(a) }
        parts.append(clock(f.at, timeZone: timeZone))
        let body = parts.joined(separator: " — ")
        return isFresh(f, now: now) ? body : "\(headline(f, now: now)): \(body)"
    }

    /// «شارك موقعي»: "موقعي الحين: <link> — 24.71360, 46.67530 — دقة ±٨ م — ٣:٤٥ م".
    static func myLocationMessage(_ f: Fix, link kind: MapLink = .google, now: Date, timeZone: TimeZone = .current) -> String {
        var parts = [link(f.point, kind).absoluteString, copyDecimal(f.point)]
        if let a = accuracyLabel(f.accuracyM) { parts.append(a) }
        parts.append(clock(f.at, timeZone: timeZone))
        return "\(headline(f, now: now)): " + parts.joined(separator: " — ")
    }

    /// Share text for any point on the map (not me): "<name>: <link> — 24.71360, 46.67530".
    static func pointMessage(_ p: LngLat, name: String? = nil, link kind: MapLink = .google) -> String {
        let head = name.map { "\($0): " } ?? "نقطة على الخريطة: "
        return head + link(p, kind, label: name).absoluteString + " — " + copyDecimal(p)
    }
}

extension CoordinateShare.MapLink {
    var app: ExternalNav.App {
        switch self {
        case .google: return .google
        case .waze: return .waze
        }
    }
}
