import Foundation

/// «اطلب إنجاد»: a prefilled help request to Enjad (the Saudi volunteer search-and-rescue
/// association; number from their official App Store listing). The PERSON sends it from
/// WhatsApp / Messages themselves — we never send anything automatically.
enum Enjad {
    /// Local form (call / SMS) and international form (wa.me).
    static let phoneLocal = "0507911999"
    static let phoneIntl = "966507911999"
    /// A fix older than this is said to be «آخر موقع معروف قبل X د», never presented as current.
    static let staleS = 120.0

    static let note = "إنجاد جمعية تطوعية، وللطوارئ الحكومية اتصل ٩١١ / ٩٩٧ / ٩٩٨"

    enum Situation: Equatable {
        case stuck, breakdown, emergency

        var label: String {
            switch self {
            case .stuck: return "غرّزت"
            case .breakdown: return "عطل"
            case .emergency: return "طوارئ"
            }
        }
    }

    struct Input: Equatable {
        var situation: Situation
        var name: String
        /// My phone in my profile (nil / empty: «لم يُضف»).
        var phone: String?
        var fix: DeviceFix?
        var now: Date
        /// 0…100, nil when unknown.
        var batteryPercent: Int?
        var memberCount: Int?
        var car: String?
        /// «أمير الرحلة» when it is someone else.
        var leaderName: String?
        var leaderPhone: String?
    }

    static func hasPhone(_ i: Input) -> Bool { !(i.phone ?? "").trimmingCharacters(in: .whitespaces).isEmpty }

    /// The message text, exactly as the person will see it before sending.
    static func message(_ i: Input) -> String {
        var l = ["طلب مساعدة — سَرى البارق", "الحالة: \(i.situation.label)", "الاسم: \(i.name)"]
        l.append("رقم التواصل: \(hasPhone(i) ? i.phone!.trimmingCharacters(in: .whitespaces) : "لم يُضف")")
        if let f = i.fix {
            let p = LngLat(lng: f.lng, lat: f.lat)
            let ll = String(format: "%.6f, %.6f", f.lat, f.lng)
            let age = max(0, i.now.timeIntervalSince1970 - f.atMs / 1000)
            if age > staleS {
                l.append("الموقع: آخر موقع معروف قبل \(SaryFormat.number(Int((age / 60).rounded(.down)))) د: \(ll)")
            } else {
                l.append("الموقع: \(ll)")
            }
            l.append("(\(CoordinateParser.dmsString(p)))")
            l.append("خرائط: https://maps.google.com/?q=\(String(format: "%.6f,%.6f", f.lat, f.lng))")
            var gps: [String] = []
            if let a = f.accuracy, a >= 0 { gps.append("دقة GPS: ±\(SaryFormat.number(Int(a.rounded()))) م") }
            gps.append("آخر تحديث: \(NavText.clock(Date(timeIntervalSince1970: f.atMs / 1000)))")
            l.append(gps.joined(separator: " · "))
        } else {
            l.append("الموقع: غير متوفر (ما وصل موقع من GPS)")
        }
        var extra: [String] = []
        if let b = i.batteryPercent { extra.append("البطارية: \(SaryFormat.percent(b))") }
        if let n = i.memberCount { extra.append("عدد الأفراد في الطلعة: \(SaryFormat.number(n))") }
        if let c = i.car, !c.isEmpty { extra.append("السيارة: \(c)") }
        if !extra.isEmpty { l.append(extra.joined(separator: " · ")) }
        if let ln = i.leaderName, !ln.isEmpty {
            l.append("أمير الرحلة: \(ln)\((i.leaderPhone ?? "").isEmpty ? "" : " — \(i.leaderPhone!)")")
        }
        return l.joined(separator: "\n")
    }

    /// Percent-encoding for a query value: everything but unreserved characters.
    static func encode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        /* `alphanumerics` includes non-ASCII letters: keep only ASCII ones unencoded. */
        return s.unicodeScalars.map { u in
            if u.isASCII, allowed.contains(u) { return String(u) }
            return String(u).utf8.map { String(format: "%%%02X", $0) }.joined()
        }.joined()
    }

    static func whatsappURL(_ text: String) -> URL { URL(string: "https://wa.me/\(phoneIntl)?text=\(encode(text))")! }
    static func smsURL(_ text: String) -> URL { URL(string: "sms:\(phoneLocal)&body=\(encode(text))")! }
    static var callURL: URL { URL(string: "tel:\(phoneLocal)")! }
    /// Is WhatsApp installed? (`LSApplicationQueriesSchemes` lists `whatsapp`.)
    static let whatsappScheme = URL(string: "whatsapp://")!

    /// WhatsApp when it is installed and there is data; Messages otherwise (same text).
    static func sendURL(_ text: String, whatsappInstalled: Bool, online: Bool) -> URL {
        whatsappInstalled && online ? whatsappURL(text) : smsURL(text)
    }
}
