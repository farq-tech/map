import Foundation

/// Arabic ↔ English for place search: «ستاربكس» and "Starbucks", «صيدلية النهدي» and "Nahdi pharmacy",
/// «مستشفى الملك فيصل» and "King Faisal hospital" are the same search.
///
/// A query is read as a sequence of *concepts* (a brand, a kind of place, a name, a place-type word),
/// each with its Arabic and English spellings. A query whose every word is known becomes one canonical
/// Arabic form and one canonical English form, and *those two* are what the sources are asked — so an
/// Arabic query and its English twin ask exactly the same questions and get exactly the same list.
///
/// A query with an unknown word is asked as typed (we do not guess a translation for a source to
/// chase); the transliteration skeleton below still lets results in the two scripts merge.
enum SearchLexicon {
    /// How a word sits in a name.
    enum Role: Equatable {
        /// A chain or a named landmark («ستاربكس», «الرياض بارك»). A place named exactly this gets the
        /// other spelling as its second name.
        case brand
        /// A proper name or modifier («الملك», «فيصل», «التخصصي», «العليا»).
        case name
        /// A kind of place: first in Arabic, last in English («مستشفى الملك فيصل» ↔ "King Faisal Hospital").
        case head
        /// A place-type word that stays in front in English too («روضة خريم» ↔ "Rawdat Khuraim").
        case toponym
    }

    struct Entry: Equatable {
        let id: String
        /// First is the display spelling; the rest are what people type.
        let ar: [String]
        let en: [String]
        let role: Role
    }

    /// One piece of a read query.
    enum Segment: Equatable {
        case known(Entry)
        case unknown(String)
    }

    struct Plan: Equatable {
        /// What the sources are asked, Arabic first. Two forms when every word is known, else the query as typed.
        let forms: [String]
        let segments: [Segment]
        /// Every word was in the lexicon.
        var complete: Bool { !segments.isEmpty && segments.allSatisfy { if case .known = $0 { return true } else { return false } } }
    }

    // MARK: - reading a query

    static func plan(_ query: String) -> Plan {
        let raw = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var segs = segments(raw)
        segs = canonicalOrder(segs)
        let entries = segs.compactMap { s -> Entry? in if case let .known(e) = s { return e } else { return nil } }
        guard !segs.isEmpty, entries.count == segs.count else { return Plan(forms: raw.isEmpty ? [] : [raw], segments: segs) }
        let ar = entries.map { $0.ar[0] }.joined(separator: " ")
        let en = englishOrder(entries).map { $0.en[0] }.joined(separator: " ")
        let forms = PlaceSearch.normalize(ar) == PlaceSearch.normalize(en) ? [ar] : [ar, en]
        return Plan(forms: forms, segments: segs)
    }

    /// Longest-match segmentation (up to four words; «عبد العزيز» and "abdulaziz" both hit).
    static func segments(_ text: String) -> [Segment] {
        let words = rawWords(text)
        let ks = words.map { key($0) }
        var out: [Segment] = []
        var i = 0
        while i < ks.count {
            if ks[i].isEmpty { i += 1; continue }
            var hit: (Entry, Int)?
            for n in stride(from: min(4, ks.count - i), through: 1, by: -1) {
                let span = ks[i..<(i + n)].filter { !$0.isEmpty }
                guard !span.isEmpty else { continue }
                if let e = lookup(span.joined(separator: " ")) ?? lookup(span.joined()) { hit = (e, n); break }
            }
            if let (e, n) = hit {
                out.append(.known(e)); i += n
            } else {
                out.append(.unknown(words[i])); i += 1
            }
        }
        return out
    }

    /// The order a query is asked in is Arabic's: a kind of place written last («النهدي صيدلية», "Nahdi pharmacy")
    /// moves to the front, so both languages read as the same sequence.
    static func canonicalOrder(_ segs: [Segment]) -> [Segment] {
        guard segs.count > 1, case let .known(last) = segs.last!, last.role == .head else { return segs }
        if case let .known(first) = segs.first!, first.role == .head || first.role == .toponym { return segs }
        return [segs.last!] + segs.dropLast()
    }

    /// English puts the kind of place last: [hospital, king, faisal] → "King Faisal Hospital".
    static func englishOrder(_ entries: [Entry]) -> [Entry] {
        guard entries.count > 1, entries[0].role == .head else { return entries }
        return Array(entries.dropFirst()) + [entries[0]]
    }

    /// The other-language name of a place named exactly a brand («Starbucks» → «ستاربكس»), else nil.
    static func brandCounterpart(_ name: String) -> String? {
        let segs = segments(name)
        guard segs.count == 1, case let .known(e) = segs[0], e.role == .brand else { return nil }
        return PlaceSearch.isArabic(name) ? e.en[0] : e.ar[0]
    }

    /// A name every word of which is known, as its concepts in Arabic order («روضة خريم» and "Rawdat Khuraim"
    /// are both "rawdat khuraim"), else nil.
    static func conceptKey(_ name: String) -> String? {
        let segs = canonicalOrder(segments(name))
        let ids = segs.compactMap { s -> String? in if case let .known(e) = s { return e.id } else { return nil } }
        return !ids.isEmpty && ids.count == segs.count ? ids.joined(separator: " ") : nil
    }

    /// The brand a place name is (or starts with), for merging «ستاربكس» and "Starbucks Olaya" on one spot.
    static func brandId(_ name: String) -> String? {
        guard case let .known(e)? = segments(name).first, e.role == .brand else { return nil }
        return e.id
    }

    // MARK: - keys

    /// Words as typed (for unknown segments), split the way `key` splits them.
    static func rawWords(_ text: String) -> [String] {
        let cleaned = text.replacingOccurrences(of: "['’`ʼ]", with: "", options: .regularExpression)
        return cleaned.split(whereSeparator: { $0.isWhitespace || ($0.isPunctuation && $0 != "&") }).map(String.init)
    }

    /// A word's lookup key: `PlaceSearch.normalize`, then no article («ال», "al", "el").
    static func key(_ word: String) -> String {
        let n = PlaceSearch.normalize(word).replacingOccurrences(of: " ", with: "")
        if n == "al" || n == "el" { return "" }
        if PlaceSearch.isArabic(n), n.hasPrefix("ال"), n.count > 3 { return String(n.dropFirst(2)) }
        return n
    }

    static func aliasKey(_ alias: String) -> String { rawWords(alias).map(key).filter { !$0.isEmpty }.joined(separator: " ") }

    static func lookup(_ k: String) -> Entry? { index[k].map { entries[$0] } }

    /// alias key (spaced and unspaced) → entry.
    static let index: [String: Int] = {
        var m: [String: Int] = [:]
        for (i, e) in entries.enumerated() {
            for a in e.ar + e.en {
                let k = aliasKey(a)
                guard !k.isEmpty else { continue }
                if m[k] == nil { m[k] = i }
                let joined = k.replacingOccurrences(of: " ", with: "")
                if m[joined] == nil { m[joined] = i }
            }
        }
        return m
    }()

    /// Alias keys claimed by two different entries (a lexicon mistake; the test keeps this empty).
    static var collisions: [String] {
        var owner: [String: String] = [:]
        var clash: [String] = []
        for e in entries {
            for a in e.ar + e.en {
                let k = aliasKey(a)
                if let o = owner[k], o != e.id { clash.append("\(k): \(o) / \(e.id)") }
                owner[k] = e.id
            }
        }
        return clash
    }

    // MARK: - transliteration skeleton

    /// The consonant skeleton both scripts share: «ستاربكس» and "Starbucks" are both "strbks",
    /// «ماكدونالدز» and "McDonald's" "mkdnlds". Used only to merge results on (almost) one spot.
    static func skeleton(_ s: String) -> String {
        let words = rawWords(s).map(key).filter { !$0.isEmpty }
        var out = ""
        for w in words {
            out += PlaceSearch.isArabic(w) ? arabicSkeleton(w) : latinSkeleton(w)
        }
        var collapsed = ""
        for ch in out where collapsed.last != ch { collapsed.append(ch) }
        return collapsed
    }

    private static func arabicSkeleton(_ w: String) -> String {
        let map: [Character: String] = [
            "ب": "b", "پ": "b", "ت": "t", "ث": "t", "ج": "j", "چ": "j", "ح": "h", "خ": "k", "د": "d", "ذ": "d",
            "ر": "r", "ز": "s", "س": "s", "ش": "s", "ص": "s", "ض": "d", "ط": "t", "ظ": "s", "غ": "j", "گ": "j",
            "ف": "f", "ڤ": "f", "ق": "k", "ك": "k", "ل": "l", "م": "m", "ن": "n", "ه": "h",
        ]
        var s = w.compactMap { map[$0] }.joined()
        if s.hasSuffix("h") { s.removeLast() }
        return s
    }

    private static func latinSkeleton(_ w: String) -> String {
        var s = w.lowercased()
        for (a, b) in [("sh", "s"), ("th", "t"), ("kh", "k"), ("gh", "j"), ("dh", "d"), ("ph", "f"), ("ck", "k"), ("ch", "s"), ("x", "ks")] {
            s = s.replacingOccurrences(of: a, with: b)
        }
        let map: [Character: String] = [
            "b": "b", "p": "b", "t": "t", "d": "d", "j": "j", "g": "j", "h": "h", "k": "k", "c": "k", "q": "k",
            "s": "s", "z": "s", "f": "f", "v": "f", "l": "l", "m": "m", "n": "n", "r": "r",
        ]
        var out = s.compactMap { map[$0] }.joined()
        if out.hasSuffix("h") { out.removeLast() }
        return out
    }

    // MARK: - the lexicon

    private static func e(_ id: String, _ role: Role, ar: String, en: String) -> Entry {
        Entry(id: id, ar: ar.components(separatedBy: "|"), en: en.components(separatedBy: "|"), role: role)
    }

    /// Saudi chains, kinds of place, names and place-type words. Spellings are the common ones on signs,
    /// in delivery apps and in what people type («ماكدونالدز», «ماك»).
    static let entries: [Entry] = [
        // Coffee
        e("starbucks", .brand, ar: "ستاربكس|ستار بكس|ستاربوكس", en: "Starbucks|starbuck|starbucks coffee"),
        e("dunkin", .brand, ar: "دانكن|دانكن دونتس|دنكن", en: "Dunkin|dunkin donuts|dunkin' donuts"),
        e("tim-hortons", .brand, ar: "تيم هورتنز|تيم هورتونز", en: "Tim Hortons|tim horton|tims"),
        e("barns", .brand, ar: "بارنز", en: "Barn's|barns"),
        e("dr-cafe", .brand, ar: "د كيف|دكتور كيف|دكتور كافيه", en: "Dr. Cafe|dr cafe|doctor cafe"),
        e("half-million", .brand, ar: "هاف مليون", en: "Half Million"),
        e("caribou", .brand, ar: "كاريبو|كاريبو كوفي", en: "Caribou|caribou coffee"),
        e("costa", .brand, ar: "كوستا|كوستا كوفي", en: "Costa|costa coffee"),
        e("kyan", .brand, ar: "كيان", en: "Kyan"),
        e("joe-juice", .brand, ar: "جو اند ذا جوس|جو آند ذا جوس", en: "Joe & The Juice|joe and the juice"),
        // Fast food
        e("mcdonalds", .brand, ar: "ماكدونالدز|ماكدونالد|ماك دونالدز|ماكدونلدز|ماك", en: "McDonald's|mcdonalds|mcdonald|mc donalds|macdonalds"),
        e("kfc", .brand, ar: "كنتاكي|كي اف سي", en: "KFC|kentucky"),
        e("albaik", .brand, ar: "البيك", en: "Al Baik|albaik|baik"),
        e("kudu", .brand, ar: "كودو", en: "Kudu"),
        e("herfy", .brand, ar: "هرفي", en: "Herfy"),
        e("burger-king", .brand, ar: "برجر كنج|برجر كينج|برقر كنق|بيرغر كينغ", en: "Burger King"),
        e("hardees", .brand, ar: "هارديز", en: "Hardee's|hardees"),
        e("dominos", .brand, ar: "دومينوز|دومينوز بيتزا", en: "Domino's|dominos|domino's pizza|dominos pizza"),
        e("pizza-hut", .brand, ar: "بيتزا هت", en: "Pizza Hut"),
        e("papa-johns", .brand, ar: "بابا جونز", en: "Papa John's|papa johns"),
        e("little-caesars", .brand, ar: "ليتل سيزرز", en: "Little Caesars"),
        e("maestro", .brand, ar: "مايسترو بيتزا|مايسترو", en: "Maestro Pizza|maestro"),
        e("shawarmer", .brand, ar: "شاورمر", en: "Shawarmer"),
        e("tazaj", .brand, ar: "الطازج", en: "Al Tazaj|tazaj|altazaj"),
        e("subway", .brand, ar: "صب واي|صبواي", en: "Subway"),
        e("texas-chicken", .brand, ar: "تكساس تشكن", en: "Texas Chicken"),
        e("five-guys", .brand, ar: "فايف جايز", en: "Five Guys"),
        e("shake-shack", .brand, ar: "شيك شاك", en: "Shake Shack"),
        e("applebees", .brand, ar: "ابلبيز", en: "Applebee's|applebees"),
        e("chilis", .brand, ar: "تشيليز", en: "Chili's|chilis"),
        e("baskin", .brand, ar: "باسكن روبنز", en: "Baskin Robbins"),
        // Pharmacies, groceries, retail
        e("nahdi", .brand, ar: "النهدي", en: "Nahdi|al nahdi|alnahdi"),
        e("aldawaa", .brand, ar: "الدواء", en: "Al Dawaa|aldawaa|dawaa"),
        e("whites", .brand, ar: "وايتس", en: "Whites"),
        e("panda", .brand, ar: "بنده|بندة", en: "Panda"),
        e("hyperpanda", .brand, ar: "هايبر بنده", en: "Hyper Panda|hyperpanda"),
        e("danube", .brand, ar: "الدانوب", en: "Danube"),
        e("tamimi", .brand, ar: "التميمي|أسواق التميمي", en: "Tamimi|tamimi markets"),
        e("othaim", .brand, ar: "العثيم|أسواق العثيم", en: "Othaim|al othaim|othaim markets"),
        e("lulu", .brand, ar: "لولو|لولو هايبر", en: "LuLu|lulu hypermarket"),
        e("carrefour", .brand, ar: "كارفور", en: "Carrefour"),
        e("nesto", .brand, ar: "نستو", en: "Nesto"),
        e("jarir", .brand, ar: "جرير|مكتبة جرير", en: "Jarir|jarir bookstore"),
        e("extra", .brand, ar: "اكسترا|إكسترا", en: "eXtra|extra stores"),
        e("ikea", .brand, ar: "ايكيا|إيكيا", en: "IKEA"),
        e("centrepoint", .brand, ar: "سنتربوينت|سنتر بوينت", en: "Centrepoint|centerpoint|center point"),
        e("saco", .brand, ar: "ساكو", en: "SACO"),
        // Fuel and cars
        e("aldrees", .brand, ar: "الدريس", en: "Aldrees|al drees|drees"),
        e("sasco", .brand, ar: "ساسكو", en: "SASCO"),
        e("petromin", .brand, ar: "بترومين", en: "Petromin"),
        e("naft", .brand, ar: "نفط", en: "Naft"),
        e("aramco", .brand, ar: "أرامكو|ارامكو", en: "Aramco"),
        // Banks and telecom
        e("alrajhi", .brand, ar: "الراجحي|مصرف الراجحي", en: "Al Rajhi|alrajhi|al rajhi bank|rajhi"),
        e("snb", .brand, ar: "الأهلي|البنك الأهلي", en: "SNB|alahli|ncb"),
        e("riyad-bank", .brand, ar: "بنك الرياض", en: "Riyad Bank"),
        e("alinma", .brand, ar: "الإنماء|مصرف الإنماء", en: "Alinma|alinma bank"),
        e("stc", .brand, ar: "اس تي سي|إس تي سي", en: "stc"),
        e("mobily", .brand, ar: "موبايلي", en: "Mobily"),
        // Malls and landmarks people search by name
        e("kingdom-centre", .brand, ar: "برج المملكة|مركز المملكة|المملكة مول", en: "Kingdom Centre|kingdom center|kingdom tower|kingdom mall"),
        e("faisaliah", .brand, ar: "برج الفيصلية|الفيصلية", en: "Al Faisaliah|faisaliah|faisaliah tower"),
        e("riyadh-park", .brand, ar: "الرياض بارك", en: "Riyadh Park"),
        e("riyadh-front", .brand, ar: "واجهة الرياض", en: "Riyadh Front"),
        e("riyadh-gallery", .brand, ar: "الرياض جاليري|رياض جاليري", en: "Riyadh Gallery"),
        e("nakheel-mall", .brand, ar: "النخيل مول|نخيل مول", en: "Nakheel Mall|al nakheel mall"),
        e("granada", .brand, ar: "غرناطة مول|غرناطة", en: "Granada Mall|granada"),
        e("mall-of-arabia", .brand, ar: "مول العرب", en: "Mall of Arabia"),
        e("red-sea-mall", .brand, ar: "رد سي مول|ردسي مول", en: "Red Sea Mall"),
        e("boulevard", .brand, ar: "بوليفارد|بوليفارد رياض سيتي|البوليفارد", en: "Boulevard|boulevard riyadh city|riyadh boulevard"),
        e("diriyah", .brand, ar: "الدرعية", en: "Diriyah|ad diriyah|dariyah"),
        e("masmak", .brand, ar: "قصر المصمك|المصمك", en: "Masmak|masmak fort|masmak palace"),
        e("edge-of-world", .brand, ar: "حافة العالم", en: "Edge of the World|edge of world"),

        // Kinds of place (Arabic first, English last)
        e("hospital", .head, ar: "مستشفى|مستشفي", en: "Hospital"),
        e("hospitals", .head, ar: "مستشفيات", en: "Hospitals"),
        e("clinic", .head, ar: "مستوصف|عيادة|مجمع طبي|مركز صحي", en: "Clinic|medical center|health center"),
        e("pharmacy", .head, ar: "صيدلية", en: "Pharmacy"),
        e("pharmacies", .head, ar: "صيدليات", en: "Pharmacies"),
        e("gas-station", .head, ar: "محطة بنزين|محطة وقود|بنزين|محطه بنزينه", en: "Gas station|petrol station|fuel station|gas|petrol|fuel"),
        e("gas-stations", .head, ar: "محطات بنزين|محطات وقود", en: "Gas stations|petrol stations|fuel stations"),
        e("restaurant", .head, ar: "مطعم", en: "Restaurant"),
        e("restaurants", .head, ar: "مطاعم", en: "Restaurants"),
        e("cafe", .head, ar: "مقهى|كافيه|كوفي|كوفي شوب|قهوة", en: "Cafe|café|coffee|coffee shop"),
        e("cafes", .head, ar: "مقاهي|كافيهات", en: "Cafes|coffee shops"),
        e("hotel", .head, ar: "فندق", en: "Hotel"),
        e("hotels", .head, ar: "فنادق", en: "Hotels"),
        e("mosque", .head, ar: "مسجد|جامع", en: "Mosque"),
        e("school", .head, ar: "مدرسة", en: "School"),
        e("university", .head, ar: "جامعة", en: "University"),
        e("college", .head, ar: "كلية", en: "College"),
        e("park", .head, ar: "حديقة|منتزه|متنزه|منتزة", en: "Park|garden"),
        e("mall", .head, ar: "مول|مجمع تجاري", en: "Mall|shopping mall|shopping center"),
        e("market", .head, ar: "سوق|أسواق", en: "Market|souq|souk"),
        e("supermarket", .head, ar: "سوبرماركت|سوبر ماركت|بقالة|تموينات|هايبر ماركت", en: "Supermarket|grocery|hypermarket"),
        e("bank", .head, ar: "بنك|مصرف", en: "Bank"),
        e("atm", .head, ar: "صراف|صراف آلي", en: "ATM|cash machine"),
        e("airport", .head, ar: "مطار", en: "Airport"),
        e("station", .head, ar: "محطة", en: "Station"),
        e("metro", .head, ar: "مترو|محطة مترو", en: "Metro|metro station"),
        e("center", .head, ar: "مركز", en: "Center|centre"),
        e("tower", .head, ar: "برج", en: "Tower"),
        e("street", .head, ar: "شارع", en: "Street|st|str"),
        e("road", .head, ar: "طريق", en: "Road|rd|highway"),
        e("district", .head, ar: "حي", en: "District|neighborhood|neighbourhood"),
        e("gate", .head, ar: "بوابة", en: "Gate"),
        e("stadium", .head, ar: "ملعب|استاد|إستاد", en: "Stadium"),
        e("club", .head, ar: "نادي", en: "Club"),
        e("gym", .head, ar: "نادي رياضي|جيم", en: "Gym|fitness"),
        e("museum", .head, ar: "متحف", en: "Museum"),
        e("palace", .head, ar: "قصر", en: "Palace"),
        e("beach", .head, ar: "شاطئ|شاطيء", en: "Beach"),
        e("island", .head, ar: "جزيرة", en: "Island"),
        e("corniche", .head, ar: "كورنيش", en: "Corniche"),
        e("roundabout", .head, ar: "دوار", en: "Roundabout"),
        e("exit", .head, ar: "مخرج", en: "Exit"),
        e("square", .head, ar: "ميدان|ساحة", en: "Square|plaza"),
        e("chalet", .head, ar: "شاليه", en: "Chalet"),
        e("chalets", .head, ar: "شاليهات", en: "Chalets"),
        e("istiraha", .head, ar: "استراحة", en: "Istiraha|rest house|resthouse"),
        e("istirahat", .head, ar: "استراحات", en: "Istirahat|rest houses"),
        e("camp", .head, ar: "مخيم|مخيمات", en: "Camp|camping|campsite"),
        e("parking", .head, ar: "موقف|مواقف", en: "Parking|car park"),
        e("police", .head, ar: "شرطة|مركز شرطة", en: "Police|police station"),
        e("civil-defense", .head, ar: "دفاع مدني", en: "Civil Defense|civil defence"),
        e("embassy", .head, ar: "سفارة", en: "Embassy"),
        e("ministry", .head, ar: "وزارة", en: "Ministry"),
        e("court", .head, ar: "محكمة", en: "Court"),
        e("laundry", .head, ar: "مغسلة|مغسلة ملابس", en: "Laundry"),
        e("car-wash", .head, ar: "مغسلة سيارات", en: "Car wash"),
        e("bakery", .head, ar: "مخبز|مخابز", en: "Bakery"),
        e("cinema", .head, ar: "سينما", en: "Cinema|movie theater"),
        e("zoo", .head, ar: "حديقة حيوان|حديقة الحيوان", en: "Zoo"),

        // Place-type words kept in front in English (desert and nature names)
        e("rawdat", .toponym, ar: "روضة|روضه", en: "Rawdat|rawdah|rawda|rawdhat|raudat"),
        e("faydat", .toponym, ar: "فيضة", en: "Faydat|faydah|faidat|faidah|fayda"),
        e("nafud", .toponym, ar: "نفود|النفود", en: "Nafud|nefud|nufud"),
        e("wadi", .toponym, ar: "وادي", en: "Wadi|valley"),
        e("jabal", .toponym, ar: "جبل", en: "Jabal|jebel|mount|mountain"),
        e("ain", .toponym, ar: "عين", en: "Ain|ayn"),
        e("bir", .toponym, ar: "بئر|بير", en: "Bir|well"),
        e("irq", .toponym, ar: "عرق", en: "Irq|erg"),
        e("khashm", .toponym, ar: "خشم", en: "Khashm"),
        e("shaib", .toponym, ar: "شعيب", en: "Shaib|shaeeb|shuaib"),
        e("dahl", .toponym, ar: "دحل", en: "Dahl"),

        // Names and modifiers
        e("king", .name, ar: "الملك", en: "King"),
        e("prince", .name, ar: "الأمير", en: "Prince|emir|amir"),
        e("princess", .name, ar: "الأميرة", en: "Princess"),
        e("sheikh", .name, ar: "الشيخ", en: "Sheikh|shaikh|shaykh"),
        e("imam", .name, ar: "الإمام", en: "Imam"),
        e("faisal", .name, ar: "فيصل", en: "Faisal|faysal|feisal"),
        e("fahd", .name, ar: "فهد", en: "Fahd|fahad"),
        e("abdulaziz", .name, ar: "عبدالعزيز|عبد العزيز", en: "Abdulaziz|abdul aziz|abdelaziz|abd al aziz"),
        e("abdullah", .name, ar: "عبدالله|عبد الله", en: "Abdullah|abdallah|abdulla"),
        e("abdulrahman", .name, ar: "عبدالرحمن|عبد الرحمن", en: "Abdulrahman|abdul rahman|abdurrahman"),
        e("khalid", .name, ar: "خالد", en: "Khalid|khaled"),
        e("salman", .name, ar: "سلمان", en: "Salman"),
        e("saud", .name, ar: "سعود", en: "Saud"),
        e("mohammed", .name, ar: "محمد", en: "Mohammed|muhammad|mohammad|mohamed|muhammed"),
        e("nourah", .name, ar: "نورة", en: "Nourah|noura|norah|nora"),
        e("turki", .name, ar: "تركي", en: "Turki"),
        e("sultan", .name, ar: "سلطان", en: "Sultan"),
        e("specialist", .name, ar: "التخصصي", en: "Specialist|takhassusi"),
        e("military", .name, ar: "العسكري", en: "Military"),
        e("national", .name, ar: "الوطني", en: "National"),
        e("guard", .name, ar: "الحرس", en: "Guard"),
        e("international", .name, ar: "الدولي", en: "International"),
        e("general", .name, ar: "العام", en: "General"),
        e("central", .name, ar: "المركزي", en: "Central"),
        e("children", .name, ar: "الأطفال", en: "Children|children's|kids"),
        e("maternity", .name, ar: "الولادة", en: "Maternity"),
        e("medical-city", .name, ar: "المدينة الطبية", en: "Medical City"),
        e("security-forces", .name, ar: "قوى الأمن", en: "Security Forces"),
        e("grand", .name, ar: "الكبير", en: "Grand"),
        e("old", .name, ar: "القديم", en: "Old"),
        e("new", .name, ar: "الجديد", en: "New"),
        e("north", .name, ar: "الشمالي|الشمالية|شمال", en: "North|northern"),
        e("south", .name, ar: "الجنوبي|الجنوبية|جنوب", en: "South|southern"),
        e("east", .name, ar: "الشرقي|الشرقية|شرق", en: "East|eastern"),
        e("west", .name, ar: "الغربي|الغربية|غرب", en: "West|western"),
        e("ring", .name, ar: "الدائري", en: "Ring"),
        e("northern-ring", .brand, ar: "الدائري الشمالي|الطريق الدائري الشمالي", en: "Northern Ring Road|north ring road|northern ring"),
        e("eastern-ring", .brand, ar: "الدائري الشرقي|الطريق الدائري الشرقي", en: "Eastern Ring Road|east ring road|eastern ring"),

        // Cities and regions
        e("riyadh", .name, ar: "الرياض", en: "Riyadh|riyad|ar riyadh"),
        e("jeddah", .name, ar: "جدة", en: "Jeddah|jiddah|jedda"),
        e("makkah", .name, ar: "مكة|مكة المكرمة", en: "Makkah|mecca|makka"),
        e("madinah", .name, ar: "المدينة|المدينة المنورة", en: "Madinah|medina|madina"),
        e("dammam", .name, ar: "الدمام", en: "Dammam"),
        e("khobar", .name, ar: "الخبر", en: "Khobar|al khobar|alkhobar"),
        e("dhahran", .name, ar: "الظهران", en: "Dhahran"),
        e("taif", .name, ar: "الطائف", en: "Taif|ta'if"),
        e("abha", .name, ar: "أبها", en: "Abha"),
        e("tabuk", .name, ar: "تبوك", en: "Tabuk"),
        e("hail", .name, ar: "حائل", en: "Hail|ha'il|hayil"),
        e("qassim", .name, ar: "القصيم", en: "Qassim|qasim|al qassim"),
        e("buraidah", .name, ar: "بريدة", en: "Buraidah|buraydah|buraida"),
        e("unaizah", .name, ar: "عنيزة", en: "Unaizah|unayzah|onaizah"),
        e("ahsa", .name, ar: "الأحساء|الاحساء", en: "Al Ahsa|ahsa|al hasa|hasa"),
        e("hofuf", .name, ar: "الهفوف", en: "Hofuf|al hofuf"),
        e("najran", .name, ar: "نجران", en: "Najran"),
        e("jazan", .name, ar: "جازان|جيزان", en: "Jazan|jizan|gizan"),
        e("yanbu", .name, ar: "ينبع", en: "Yanbu"),
        e("alula", .name, ar: "العلا", en: "AlUla|al ula|ula|al-ula"),
        e("kharj", .name, ar: "الخرج", en: "Al Kharj|kharj"),
        e("jubail", .name, ar: "الجبيل", en: "Jubail|al jubail"),
        e("qatif", .name, ar: "القطيف", en: "Qatif|al qatif"),
        e("baha", .name, ar: "الباحة", en: "Al Baha|baha"),
        e("jouf", .name, ar: "الجوف", en: "Al Jouf|jouf|jawf"),
        e("sakaka", .name, ar: "سكاكا", en: "Sakaka"),
        e("arar", .name, ar: "عرعر", en: "Arar"),
        e("kingdom", .name, ar: "المملكة", en: "Kingdom"),
        e("saudi", .name, ar: "السعودية", en: "Saudi|saudi arabia|ksa"),

        // Riyadh districts and roads people name
        e("olaya", .name, ar: "العليا", en: "Olaya|olaia|al olaya|ulaya"),
        e("malaz", .name, ar: "الملز", en: "Malaz|al malaz"),
        e("sulaimaniyah", .name, ar: "السليمانية", en: "Sulaimaniyah|sulaymaniyah|sulimaniyah"),
        e("nakheel", .name, ar: "النخيل", en: "Nakheel|al nakheel|nakhil"),
        e("yasmin", .name, ar: "الياسمين", en: "Yasmin|yasmeen|al yasmin"),
        e("malqa", .name, ar: "الملقا", en: "Malqa|al malqa|malga"),
        e("hittin", .name, ar: "حطين", en: "Hittin|hattin|hiteen"),
        e("sahafa", .name, ar: "الصحافة", en: "Sahafa|al sahafa"),
        e("rabwah", .name, ar: "الربوة", en: "Rabwah|al rabwah|rabwa"),
        e("batha", .name, ar: "البطحاء", en: "Batha|al batha"),
        e("murabba", .name, ar: "المربع", en: "Murabba|al murabba"),
        e("wurud", .name, ar: "الورود", en: "Wurud|al wurud|worood"),
        e("naseem", .name, ar: "النسيم", en: "Naseem|al naseem|nasim"),
        e("shifa", .name, ar: "الشفا", en: "Shifa|al shifa"),
        e("tahlia", .name, ar: "التحلية", en: "Tahlia|tahliya"),
        e("thumamah", .name, ar: "الثمامة", en: "Thumamah|thumama|al thumamah"),
        e("hanifa", .name, ar: "حنيفة", en: "Hanifa|hanifah"),
        e("tuwaiq", .name, ar: "طويق", en: "Tuwaiq|tuwayq"),
        e("khuraim", .name, ar: "خريم", en: "Khuraim|khuraym|khraim|khurayim"),
        e("thuwayrat", .name, ar: "الثويرات", en: "Thuwayrat|thuwairat|al thuwayrat"),
        e("dahna", .name, ar: "الدهناء", en: "Dahna|ad dahna|al dahna"),
        e("tinhat", .name, ar: "التنهات", en: "Tinhat|at tinhat"),
        e("nourah-university", .brand, ar: "جامعة الأميرة نورة|جامعة نورة", en: "Princess Nourah University|pnu|princess noura university"),
        e("kfsh", .brand, ar: "مستشفى الملك فيصل التخصصي", en: "King Faisal Specialist Hospital|kfsh|kfshrc"),
        e("ksu", .brand, ar: "جامعة الملك سعود", en: "King Saud University|ksu"),
        e("kkia", .brand, ar: "مطار الملك خالد|مطار الملك خالد الدولي|مطار الرياض", en: "King Khalid International Airport|king khalid airport|kkia|riyadh airport|ruh"),
    ]
}
