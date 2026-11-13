import Foundation

/// «ابحث أو أدخل إحداثية»: turns whatever a person pastes or types into a point.
///
/// Accepts decimal degrees ("24.7136, 46.6753", "24.7136N 46.6753E", "N24.7 E46.6"),
/// degrees-minutes-seconds ("24°42'49"N 46°40'31"E"), degrees-decimal-minutes
/// ("24 42.817N 46 40.517E"), Arabic-Indic / Persian digits and the Arabic comma and
/// decimal separator, Google / Apple Maps links, and full Open Location Codes (plus codes).
enum CoordinateParser {
    struct Parsed: Equatable {
        var point: LngLat
        /// Outside Saudi Arabia and its neighbours: a warning, never a block.
        var outsideRegion: Bool
        /// Read as "lng, lat" because the first number cannot be a latitude.
        var swapped = false
    }

    /// Generous box around the Kingdom (Gulf, Red Sea coasts and the borders).
    static let region = (minLat: 15.0, maxLat: 33.5, minLng: 33.5, maxLng: 56.5)

    static func inRegion(_ p: LngLat) -> Bool {
        (region.minLat...region.maxLat).contains(p.lat) && (region.minLng...region.maxLng).contains(p.lng)
    }

    static func parse(_ raw: String) -> Parsed? {
        let s = normalize(raw)
        guard !s.isEmpty, s.count <= 2048 else { return nil }
        if let p = fromLink(s) ?? plusCode(s) ?? dms(s) ?? decimal(s) {
            return finish(p.0, swapped: p.1)
        }
        return nil
    }

    private static func finish(_ p: LngLat, swapped: Bool) -> Parsed? {
        guard PlanGeo.valid(lat: p.lat, lng: p.lng) else { return nil }
        return Parsed(point: p, outsideRegion: !inRegion(p), swapped: swapped)
    }

    // MARK: normalisation

    /// Western digits, "." decimals, "," separators, ASCII symbols; trimmed.
    static func normalize(_ s: String) -> String {
        var o = ""
        for ch in s {
            switch ch {
            case "٠"..."٩": o.append(Character(String(ch.unicodeScalars.first!.value - 0x0660)))
            case "۰"..."۹": o.append(Character(String(ch.unicodeScalars.first!.value - 0x06F0)))
            case "٫": o.append(".")
            case "،", "؛", ";": o.append(",")
            case "″", "”", "“": o.append("\"")
            case "′", "’", "‘", "´": o.append("'")
            case "º", "˚": o.append("°")
            case "\u{200F}", "\u{200E}", "\u{061C}": continue
            case "−", "–": o.append("-")
            default: o.append(ch)
            }
        }
        /* Arabic hemisphere letters: ش شمال، ج جنوب، ق شرق، غ غرب. */
        var t = o.trimmingCharacters(in: .whitespacesAndNewlines)
        for (ar, en) in [("شمالا", "N"), ("شمال", "N"), ("جنوبا", "S"), ("جنوب", "S"), ("شرقا", "E"), ("شرق", "E"), ("غربا", "W"), ("غرب", "W")] {
            t = t.replacingOccurrences(of: ar, with: en)
        }
        return t
    }

    // MARK: decimal

    /// Two numbers, optionally with N/S/E/W before or after each.
    static func decimal(_ s: String) -> (LngLat, Bool)? {
        let pattern = #"^\s*([NSEW])?\s*([-+]?\d{1,3}(?:\.\d+)?)\s*°?\s*([NSEW])?\s*[, ]\s*([NSEW])?\s*([-+]?\d{1,3}(?:\.\d+)?)\s*°?\s*([NSEW])?\s*$"#
        guard let m = match(pattern, s.uppercased()) else { return nil }
        guard var a = Double(m[2]), var b = Double(m[5]) else { return nil }
        let h1 = m[1].isEmpty ? m[3] : m[1], h2 = m[4].isEmpty ? m[6] : m[4]
        return orient(&a, h1, &b, h2)
    }

    /// Applies hemispheres and decides which number is the latitude.
    private static func orient(_ a: inout Double, _ h1: String, _ b: inout Double, _ h2: String) -> (LngLat, Bool)? {
        if h1 == "S" || h1 == "W" { a = -abs(a) }
        if h2 == "S" || h2 == "W" { b = -abs(b) }
        /* Explicit letters decide. */
        if h1 == "E" || h1 == "W" || h2 == "N" || h2 == "S" {
            guard abs(b) <= 90, abs(a) <= 180 else { return nil }
            return (LngLat(lng: a, lat: b), false)
        }
        if h1 == "N" || h1 == "S" || h2 == "E" || h2 == "W" {
            guard abs(a) <= 90, abs(b) <= 180 else { return nil }
            return (LngLat(lng: b, lat: a), false)
        }
        /* Plain numbers: "lat, lng" as Google writes it, unless the first cannot be a latitude. */
        if abs(a) <= 90, abs(b) <= 180 { return (LngLat(lng: b, lat: a), false) }
        if abs(b) <= 90, abs(a) <= 180 { return (LngLat(lng: a, lat: b), true) }
        return nil
    }

    // MARK: DMS / DDM

    /// "24°42'49.5"N 46°40'31"E", "24 42 49 N 46 40 31 E", "24°42.817'N 46°40.517'E", "N24 42.817 E46 40.517".
    static func dms(_ s: String) -> (LngLat, Bool)? {
        let u = s.uppercased()
        let part = #"([NSEW])?\s*(\d{1,3})\s*(?:°|\s|D)\s*(\d{1,2}(?:\.\d+)?)\s*(?:'|M|\s)?\s*(?:(\d{1,2}(?:\.\d+)?)\s*(?:"|''|S(?![EW]?\s*\d))?)?\s*([NSEW])?"#
        let pattern = "^\\s*" + part + "\\s*,?\\s*" + part + "\\s*$"
        guard let m = match(pattern, u) else { return nil }
        func value(_ d: String, _ mi: String, _ se: String) -> Double? {
            guard let dd = Double(d), let mm = Double(mi), mm < 60 else { return nil }
            let ss = se.isEmpty ? 0 : (Double(se) ?? 99)
            guard ss < 60 else { return nil }
            return dd + mm / 60 + ss / 3600
        }
        guard var a = value(m[2], m[3], m[4]), var b = value(m[7], m[8], m[9]) else { return nil }
        let h1 = m[1].isEmpty ? m[5] : m[1], h2 = m[6].isEmpty ? m[10] : m[6]
        return orient(&a, h1, &b, h2)
    }

    // MARK: links

    /// Google Maps (`@lat,lng`, `q=`, `ll=`, `query=`, `destination=`, `!3d…!4d…`), Waze (`ll=`) and,
    /// for links people paste from elsewhere, Apple Maps (`ll=`, `q=`, `daddr=`, `coordinate=`).
    static func fromLink(_ s: String) -> (LngLat, Bool)? {
        guard let url = URL(string: s.trimmingCharacters(in: .whitespaces)), let host = url.host?.lowercased(),
              host.contains("google") || host.contains("waze.com") || host.contains("apple.com") || host.contains("goo.gl") || host == "maps.app.goo.gl" else { return nil }
        let full = s.removingPercentEncoding ?? s
        if let m = match(#"!3d(-?\d+(?:\.\d+)?)!4d(-?\d+(?:\.\d+)?)"#, full), let la = Double(m[1]), let lo = Double(m[2]) {
            return (LngLat(lng: lo, lat: la), false)
        }
        if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            for key in ["ll", "q", "query", "destination", "daddr", "sll", "coordinate", "center"] {
                if let v = comps.queryItems?.first(where: { $0.name == key })?.value, let p = decimal(v.replacingOccurrences(of: "+", with: " ")) {
                    return p
                }
            }
        }
        if let m = match(#"@(-?\d+(?:\.\d+)?),(-?\d+(?:\.\d+)?)"#, full), let la = Double(m[1]), let lo = Double(m[2]) {
            return (LngLat(lng: lo, lat: la), false)
        }
        if let m = match(#"/(-?\d{1,2}\.\d+),\+?(-?\d{1,3}\.\d+)"#, full), let la = Double(m[1]), let lo = Double(m[2]) {
            return (LngLat(lng: lo, lat: la), false)
        }
        return nil
    }

    // MARK: plus codes (full codes only; short codes need a reference place)

    private static let olc = Array("23456789CFGHJMPQRVWX")

    /// "7HQQ6MGG+2V" → centre of the code's area. Short codes ("6MGG+2V الرياض") are not decoded.
    static func plusCode(_ s: String) -> (LngLat, Bool)? {
        let code = s.uppercased().split(separator: " ").first.map(String.init) ?? ""
        guard let plus = code.firstIndex(of: "+"), code.distance(from: code.startIndex, to: plus) == 8 else { return nil }
        let clean = code.replacingOccurrences(of: "+", with: "")
        guard clean.count >= 8, clean.count <= 15, clean.allSatisfy({ olc.contains($0) }) else { return nil }
        let d = clean.map { Double(olc.firstIndex(of: $0)!) }
        let res = [20.0, 1, 0.05, 0.0025, 0.000125]
        var lat = -90.0, lng = -180.0
        let pairs = min(5, d.count / 2)
        for i in 0..<pairs {
            lat += d[2 * i] * res[i]
            lng += d[2 * i + 1] * res[i]
        }
        var latSize = res[pairs - 1], lngSize = res[pairs - 1]
        if d.count > 10 {
            for g in d.dropFirst(10) {
                latSize /= 5
                lngSize /= 4
                lat += (g / 4).rounded(.down) * latSize
                lng += g.truncatingRemainder(dividingBy: 4) * lngSize
            }
        }
        let p = LngLat(lng: lng + lngSize / 2, lat: lat + latSize / 2)
        return PlanGeo.valid(lat: p.lat, lng: p.lng) ? (p, false) : nil
    }

    // MARK: output

    /// "24.713600, 46.675300" (lat, lng — how people paste it into other apps).
    static func decimalString(_ p: LngLat) -> String {
        String(format: "%.6f, %.6f", p.lat, p.lng)
    }

    /// "24°42'49.0"N 46°40'31.1"E".
    static func dmsString(_ p: LngLat) -> String {
        func one(_ v: Double, _ pos: String, _ neg: String) -> String {
            let a = abs(v)
            var d = Int(a)
            var m = Int((a - Double(d)) * 60)
            var s = ((a - Double(d) - Double(m) / 60) * 3600 * 10).rounded() / 10
            if s >= 60 { s -= 60; m += 1 }
            if m >= 60 { m -= 60; d += 1 }
            return String(format: "%d°%02d'%04.1f\"%@", d, m, s, v < 0 ? neg : pos)
        }
        return one(p.lat, "N", "S") + " " + one(p.lng, "E", "W")
    }

    // MARK: regex helper

    static func match(_ pattern: String, _ s: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            return r.location == NSNotFound ? "" : ns.substring(with: r)
        }
    }
}
