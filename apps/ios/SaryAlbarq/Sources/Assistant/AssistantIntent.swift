import Foundation

// «مساعد سرى»: on the phone only. The language model (when downloaded) has ONE job: to say
// which of these intents a sentence asks for, as grammar-constrained JSON. Every fact in an
// answer comes from the app's own state through `AssistantAnswers` — never from the model.

/// What a person asked for. A closed set: anything else is `.unknown` (a short "ما فهمت" + suggestions).
enum AssistantIntent: Equatable {
    /// «وين الربع» (nil) / «وين سعود» (a member's name as the trip has it).
    case membersWhere(who: String?)
    /// «كم باقي» / «متى نوصل».
    case tripRemaining
    /// «أقرب محطة بنزين».
    case nearestFuel
    case weather(WeatherAspect)
    /// «متى المغرب» / «كم باقي على المغرب» / «نلحق نرجع قبل المغرب».
    case sunset(SunsetAspect)
    case rallyPoint
    /// «ابدأ التوجيه إلى …».
    case navigate(NavGoal)
    /// «شغّل / وقّف الإذاعة».
    case radio(play: Bool)
    /// «غيّر التردد إلى ٣» (a public channel, 1…5).
    case setChannel(Int)
    case openChat
    /// Anything about SOS / help: the assistant explains and shows the SOS button; it never sends SOS.
    case sosHelp
    case unknown

    enum WeatherAspect: String, CaseIterable { case general, wind, dust, temp, rain }
    enum SunsetAspect: String, CaseIterable { case time, remaining, wayBack = "way_back" }
    enum NavGoal: Equatable {
        case destination, rally, station, back
        case member(String)
    }

    /// The wire name (also the test set's `intent`).
    var key: String {
        switch self {
        case .membersWhere: return "members_where"
        case .tripRemaining: return "trip_remaining"
        case .nearestFuel: return "nearest_fuel"
        case .weather: return "weather"
        case .sunset: return "sunset"
        case .rallyPoint: return "rally_point"
        case .navigate: return "navigate"
        case .radio: return "radio"
        case .setChannel: return "set_channel"
        case .openChat: return "open_chat"
        case .sosHelp: return "sos_help"
        case .unknown: return "unknown"
        }
    }

    /// The one parameter, as the test set writes it ('' = everyone; member:<name> for a navigation to a member).
    var arg: String? {
        switch self {
        case let .membersWhere(who): return who ?? ""
        case let .weather(a): return a.rawValue
        case let .sunset(a): return a.rawValue
        case let .navigate(g):
            switch g {
            case .destination: return "destination"
            case .rally: return "rally"
            case .station: return "station"
            case .back: return "back"
            case let .member(n): return "member:\(n)"
            }
        case let .radio(play): return play ? "on" : "off"
        case let .setChannel(n): return String(n)
        default: return nil
        }
    }

    /// The model's JSON (`assistant-intent.gbnf`) → an intent. A name that is not one of the
    /// trip's members, or anything malformed, is nil (never a guess).
    static func decode(json: String, members: [String]) -> AssistantIntent? {
        guard let start = json.firstIndex(of: "{"), let end = json.lastIndex(of: "}"), start < end,
              let data = String(json[start...end]).data(using: .utf8),
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let intent = o["intent"] as? String else { return nil }
        func member(_ s: String?) -> String?? {
            guard let s else { return nil }
            if s == "everyone" { return .some(nil) }
            return members.first(where: { $0 == s }).map { .some($0) }
        }
        switch intent {
        case "members_where":
            guard let w = member(o["who"] as? String) else { return nil }
            return .membersWhere(who: w)
        case "trip_remaining": return .tripRemaining
        case "nearest_fuel": return .nearestFuel
        case "weather": return (o["aspect"] as? String).flatMap(WeatherAspect.init).map { .weather($0) }
        case "sunset": return (o["aspect"] as? String).flatMap(SunsetAspect.init).map { .sunset($0) }
        case "rally_point": return .rallyPoint
        case "navigate":
            switch o["to"] as? String {
            case "destination": return .navigate(.destination)
            case "rally": return .navigate(.rally)
            case "station": return .navigate(.station)
            case "back": return .navigate(.back)
            case let s?: return members.contains(s) ? .navigate(.member(s)) : nil
            case nil: return nil
            }
        case "radio":
            switch o["action"] as? String {
            case "play": return .radio(play: true)
            case "stop": return .radio(play: false)
            default: return nil
            }
        case "set_channel":
            guard let n = (o["channel"] as? NSNumber)?.intValue, (1...5).contains(n) else { return nil }
            return .setChannel(n)
        case "open_chat": return .openChat
        case "sos_help": return .sosHelp
        case "unknown": return .unknown
        default: return nil
        }
    }
}

/// Arabic text as people type and say it, made comparable: no diacritics or tatweel, one alef,
/// ة→ه، ى→ي، ؤ→و، ئ→ي، Arabic-Indic digits → ASCII, lower case, punctuation → spaces.
enum AssistantText {
    static func normalize(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for u in s.lowercased().unicodeScalars {
            switch u.value {
            case 0x064B...0x0652, 0x0670, 0x0640: continue
            case 0x0623, 0x0625, 0x0622, 0x0671: out.append("ا")
            case 0x0629: out.append("ه")
            case 0x0649: out.append("ي")
            case 0x0624: out.append("و")
            case 0x0626: out.append("ي")
            case 0x0660...0x0669: out.append(Character(String(u.value - 0x0660)))
            case 0x06F0...0x06F9: out.append(Character(String(u.value - 0x06F0)))
            default:
                if CharacterSet.letters.contains(u) || CharacterSet.decimalDigits.contains(u) { out.unicodeScalars.append(u) } else { out.append(" ") }
            }
        }
        return out.split(separator: " ").joined(separator: " ")
    }

    static func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var cur = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[b.count]
    }

    /// The trip member a sentence names («ابوفهد»، «نوره»، «لسعود»), if exactly one.
    static func member(in text: String, members: [String]) -> String? {
        let words = normalize(text).split(separator: " ").map(String.init)
        let joined = words.joined()
        var hits: [String] = []
        for m in members {
            let mn = normalize(m).replacingOccurrences(of: " ", with: "")
            guard mn.count >= 2 else { continue }
            if joined.contains(mn) { hits.append(m); continue }
            /* One mistyped letter in a name of four letters or more («سعوذ»); never a shorter word
             * («نور» in «والدنيا نور» is not «نورة»). */
            if mn.count >= 4, words.contains(where: { w in
                let w2 = w.hasPrefix("ل") && w.count > mn.count ? String(w.dropFirst()) : w
                return w2.count == mn.count && levenshtein(w2, mn) <= 1
            }) { hits.append(m) }
        }
        return hits.count == 1 ? hits[0] : nil
    }
}
