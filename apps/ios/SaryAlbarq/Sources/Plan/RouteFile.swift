import Foundation

/// GPX / KML import and GPX export for the planned route.
///
/// Safety: a streaming XMLParser (no DOM), external entities never resolved,
/// a file-size cap, a raw-point cap, every coordinate range-checked, and the
/// result simplified to ≤ 5000 points before it can reach the server.
enum RouteFile {
    static let maxBytes = 25 * 1024 * 1024
    /// More raw points than this is not a route anyone drew; refuse rather than chew on it.
    static let maxRawPoints = 1_000_000
    static let maxWaypoints = 500

    struct Waypoint: Equatable {
        var name: String?
        var point: LngLat
    }

    struct Imported: Equatable {
        var name: String?
        /// Simplified, ≤ TripPlan.maxPoints.
        var points: [LngLat]
        var waypoints: [Waypoint]
        /// How many points the file had before simplification.
        var rawCount: Int
        var source: Source
        enum Source: Equatable { case track, route, waypoints, kmlLine }
    }

    enum ImportError: Error, Equatable {
        case tooLarge
        case tooManyPoints
        case malformed
        case unsupported
        case noRoute

        var arabic: String {
            switch self {
            case .tooLarge: return "الملف كبير جدًا (الحد ٢٥ م.ب)."
            case .tooManyPoints: return "الملف فيه نقاط كثيرة جدًا. صدّر جزءًا أصغر من المسار."
            case .malformed: return "تعذّرت قراءة الملف. تأكد أنه GPX أو KML سليم."
            case .unsupported: return "نوع الملف غير مدعوم. استخدم GPX أو KML (ملفات KMZ: فكّ ضغطها أولًا)."
            case .noRoute: return "ما وجدنا مسارًا في الملف (نحتاج نقطتين على الأقل)."
            }
        }
    }

    enum Format { case gpx, kml }

    static func format(of data: Data, fileName: String?) -> Format? {
        let ext = (fileName as NSString?)?.pathExtension.lowercased() ?? ""
        if ext == "gpx" { return .gpx }
        if ext == "kml" { return .kml }
        if ext == "kmz" { return nil }
        /* Sniff the first KB. */
        let head = String(decoding: data.prefix(1024), as: UTF8.self).lowercased()
        if head.contains("<gpx") { return .gpx }
        if head.contains("<kml") { return .kml }
        return nil
    }

    static func parse(_ data: Data, fileName: String? = nil) -> Result<Imported, ImportError> {
        guard data.count <= maxBytes else { return .failure(.tooLarge) }
        if data.starts(with: [0x50, 0x4B, 0x03, 0x04]) { return .failure(.unsupported) } // zip (KMZ)
        guard let fmt = format(of: data, fileName: fileName) else { return .failure(.unsupported) }
        let handler = Handler(format: fmt)
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = false
        parser.delegate = handler
        let ok = parser.parse()
        if handler.overflow { return .failure(.tooManyPoints) }
        guard ok, handler.sawRoot else { return .failure(.malformed) }

        let raw: [LngLat], source: Imported.Source
        if !handler.track.isEmpty {
            (raw, source) = (handler.track, .track)
        } else if !handler.route.isEmpty {
            (raw, source) = (handler.route, fmt == .kml ? .kmlLine : .route)
        } else {
            (raw, source) = (handler.waypoints.map(\.point), .waypoints)
        }
        let pts = PlanSimplify.capped(raw, simplify: true)
        guard pts.count >= 2 else { return .failure(.noRoute) }
        return .success(Imported(name: handler.name, points: pts, waypoints: Array(handler.waypoints.prefix(maxWaypoints)),
                                 rawCount: raw.count, source: source))
    }

    // MARK: export

    /// A GPX 1.1 track of the plan (and the destination as a waypoint), for the share sheet.
    static func gpx(name: String, plan: TripPlan) -> String {
        var s = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="Sary Albarq" xmlns="http://www.topografix.com/GPX/1/1">
          <metadata><name>\(escape(name))</name></metadata>

        """
        if let d = plan.destination {
            s += "  <wpt lat=\"\(num(d.lat))\" lon=\"\(num(d.lng))\"><name>\(escape(d.name))</name><type>destination</type></wpt>\n"
        }
        if plan.hasRoute {
            s += "  <trk>\n    <name>\(escape(name))</name>\n"
            let notes = plan.notes.trimmingCharacters(in: .whitespacesAndNewlines)
            if !notes.isEmpty { s += "    <desc>\(escape(notes))</desc>\n" }
            s += "    <trkseg>\n"
            for p in plan.points { s += "      <trkpt lat=\"\(num(p.lat))\" lon=\"\(num(p.lng))\"/>\n" }
            s += "    </trkseg>\n  </trk>\n"
        }
        s += "</gpx>\n"
        return s
    }

    /// Writes the GPX into a temporary file named after the outing (the share sheet shows that name).
    static func exportFile(name: String, plan: TripPlan, dir: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let safe = name.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>\n")).joined().trimmingCharacters(in: .whitespaces)
        let url = dir.appendingPathComponent("\(safe.isEmpty ? "خطة" : safe).gpx")
        try gpx(name: name, plan: plan).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func escape(_ s: String) -> String {
        var o = ""
        for ch in s {
            switch ch {
            case "&": o += "&amp;"
            case "<": o += "&lt;"
            case ">": o += "&gt;"
            case "\"": o += "&quot;"
            case "'": o += "&apos;"
            default:
                /* XML 1.0 forbids most control characters. */
                if let v = ch.unicodeScalars.first?.value, v < 0x20, ch != "\n", ch != "\t" { continue }
                o.append(ch)
            }
        }
        return o
    }

    private static func num(_ v: Double) -> String { String(format: "%.6f", v) }

    // MARK: SAX handler

    private final class Handler: NSObject, XMLParserDelegate {
        let format: Format
        var track: [LngLat] = []
        var route: [LngLat] = []
        var waypoints: [Waypoint] = []
        var name: String?
        var sawRoot = false
        var overflow = false

        private var stack: [String] = []
        private var text = ""
        private var pendingWpt: LngLat?
        private var pendingWptName: String?
        private var placemarkName: String?
        private var count = 0

        init(format: Format) { self.format = format }

        private static func local(_ n: String) -> String {
            (n.split(separator: ":").last.map(String.init) ?? n).lowercased()
        }

        private func add(_ p: LngLat, to list: inout [LngLat], parser: XMLParser) {
            count += 1
            if count > RouteFile.maxRawPoints {
                overflow = true
                parser.abortParsing()
                return
            }
            list.append(p)
        }

        private func latLon(_ a: [String: String]) -> LngLat? {
            guard let la = a["lat"].flatMap({ Double($0.trimmingCharacters(in: .whitespaces)) }),
                  let lo = a["lon"].flatMap({ Double($0.trimmingCharacters(in: .whitespaces)) }),
                  PlanGeo.valid(lat: la, lng: lo) else { return nil }
            return LngLat(lng: lo, lat: la)
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes a: [String: String] = [:]) {
            let n = Self.local(elementName)
            if stack.isEmpty { sawRoot = (format == .gpx && n == "gpx") || (format == .kml && n == "kml") }
            stack.append(n)
            text = ""
            guard format == .gpx else { return }
            switch n {
            case "trkpt": if let p = latLon(a) { add(p, to: &track, parser: parser) }
            case "rtept": if let p = latLon(a) { add(p, to: &route, parser: parser) }
            case "wpt":
                pendingWpt = latLon(a)
                pendingWptName = nil
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            /* Only text we read: names and KML coordinates (bounded by the point cap). */
            let n = stack.last
            if n == "name" || n == "coordinates" || n == "coord" { text += string }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            let n = Self.local(elementName)
            defer { if !stack.isEmpty { stack.removeLast() } }
            let parent = stack.dropLast().last
            switch (format, n) {
            case (.gpx, "name"):
                let t = clean(text)
                if parent == "wpt" { pendingWptName = t } else if (parent == "trk" || parent == "metadata" || parent == "rte"), name == nil { name = t }
            case (.gpx, "wpt"):
                if let p = pendingWpt, waypoints.count < RouteFile.maxWaypoints { waypoints.append(Waypoint(name: pendingWptName, point: p)) }
                pendingWpt = nil
            case (.kml, "name"):
                let t = clean(text)
                if parent == "placemark" { placemarkName = t } else if parent == "document" || parent == "folder", name == nil { name = t }
            case (.kml, "coordinates"):
                let inLine = stack.contains("linestring") || stack.contains("linearring")
                let inPoint = stack.contains("point")
                let pts = Self.kmlTuples(text)
                if inLine {
                    for p in pts { add(p, to: &route, parser: parser); if overflow { return } }
                } else if inPoint, let p = pts.first, waypoints.count < RouteFile.maxWaypoints {
                    waypoints.append(Waypoint(name: placemarkName, point: p))
                }
            case (.kml, "coord"):
                /* gx:Track: "lng lat alt". */
                let parts = text.split(whereSeparator: { $0 == " " || $0.isNewline || $0 == "\t" }).compactMap { Double($0) }
                if parts.count >= 2, PlanGeo.valid(lat: parts[1], lng: parts[0]) { add(LngLat(lng: parts[0], lat: parts[1]), to: &track, parser: parser) }
            case (.kml, "placemark"):
                placemarkName = nil
            default: break
            }
            text = ""
        }

        private func clean(_ s: String) -> String? {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : String(t.prefix(80))
        }

        /// "lng,lat[,alt] lng,lat …" — invalid tuples are skipped.
        static func kmlTuples(_ s: String) -> [LngLat] {
            s.split(whereSeparator: { $0 == " " || $0.isNewline || $0 == "\t" }).compactMap { t in
                let c = t.split(separator: ",").compactMap { Double($0) }
                guard c.count >= 2, PlanGeo.valid(lat: c[1], lng: c[0]) else { return nil }
                return LngLat(lng: c[0], lat: c[1])
            }
        }
    }
}
