import Foundation

/// The live stations «إذاعة الطلعة» offers — the app's offline copy of the server's
/// catalog (apps/api/lib/outings/group-audio-catalog.js, served at
/// GET /api/outings/group-audio/catalog, which wins when reachable).
/// Sources and licence notes: docs/GROUP-AUDIO.md.
struct GroupAudioStation: Codable, Equatable, Hashable, Identifiable {
    enum Group: String, Codable, CaseIterable {
        case quran, saudi, fm

        var title: String {
            switch self {
            case .quran: return "قرآن"
            case .saudi: return "الإذاعة السعودية"
            case .fm: return "FM"
            }
        }
    }

    var id: String
    var name: String
    var subtitle: String
    var group: Group
    var url: String
    var homepage: String

    var item: GroupAudioItem { GroupAudioItem(source: .radio, id: id, title: name, subtitle: subtitle, url: url, live: true) }
}

enum GroupAudioCatalog {
    static let bundled: [GroupAudioStation] = [
        .init(id: "sba-quran", name: "إذاعة القرآن الكريم", subtitle: "من مكة المكرمة", group: .quran,
              url: "https://live.kwikmotion.com/sbrksaquranradiolive/ksaquranradio/chunks.m3u8", homepage: "https://www.aloula.sa/ar/live/quranradio"),
        .init(id: "sba-nidaa", name: "إذاعة نداء الإسلام", subtitle: "من مكة المكرمة", group: .quran,
              url: "https://live.kwikmotion.com/sbrksanidaalislamradiolive/ksanidaalislamradio/chunks.m3u8", homepage: "https://www.aloula.sa/ar/live/nidaalislamadio"),
        .init(id: "mp3quran-mix", name: "إذاعة mp3quran", subtitle: "تلاوات متنوعة", group: .quran,
              url: "https://qurango.net/radio/mix", homepage: "https://www.mp3quran.net/ar/radio"),
        .init(id: "mp3quran-tarateel", name: "تراتيل قصيرة", subtitle: "mp3quran", group: .quran,
              url: "https://qurango.net/radio/tarateel", homepage: "https://www.mp3quran.net/ar/radio"),
        .init(id: "sba-riyadh", name: "إذاعة الرياض", subtitle: "هيئة الإذاعة والتلفزيون", group: .saudi,
              url: "https://live.kwikmotion.com/sbrksariyadhradiolive/ksariyadhradio/chunks.m3u8", homepage: "https://www.aloula.sa/ar/live/riyadhradio"),
        .init(id: "sba-jeddah", name: "إذاعة جدة", subtitle: "هيئة الإذاعة والتلفزيون", group: .saudi,
              url: "https://live.kwikmotion.com/sbrksajeddahradiolive/ksajeddahradio/chunks.m3u8", homepage: "https://www.aloula.sa/ar/live/jeddahradio"),
        .init(id: "sba-saudia", name: "راديو السعودية", subtitle: "هيئة الإذاعة والتلفزيون", group: .saudi,
              url: "https://live.kwikmotion.com/sbrksasaudiaradiolive/ksasaudiaradio/chunks.m3u8", homepage: "https://www.aloula.sa/ar/live/saudiaradio"),
        .init(id: "sba-khuzama", name: "إذاعة خزامى", subtitle: "هيئة الإذاعة والتلفزيون", group: .saudi,
              url: "https://live.kwikmotion.com/sbrksakhuzamaradiolive/khuzama/chunks.m3u8", homepage: "https://www.aloula.sa/ar/live/khuzamaradio"),
        .init(id: "mbc-fm", name: "MBC FM", subtitle: "أغاني خليجية وعربية", group: .fm,
              url: "https://radio-mbcfm.mbc.net/radio-mbcfm_1.m3u8", homepage: "https://www.mbc.net/"),
        .init(id: "panorama-fm", name: "بانوراما FM", subtitle: "MBC", group: .fm,
              url: "https://radio-panoramafm.mbc.net/radio-panoramafm_1.m3u8", homepage: "https://www.mbc.net/"),
        .init(id: "mbc-loud", name: "MBC Loud FM", subtitle: "MBC", group: .fm,
              url: "https://radio-loud-fm.mbc.net/radio-loud-fm.m3u8", homepage: "https://mbcloud.fm/"),
        .init(id: "alarabiya-fm", name: "العربية FM", subtitle: "أخبار", group: .fm,
              url: "https://fm.alarabiya.net/fm/myStream/playlist.m3u8", homepage: "https://www.alarabiya.net/ar/fm"),
        .init(id: "ufm", name: "UFM 95.5", subtitle: "الرياض", group: .fm,
              url: "https://stream.ufmradio.com:8003/", homepage: "https://ufmradio.com/"),
    ]

    /// The list to show (QA build 15): the server's catalog is the source of truth; the copy in
    /// the app is only the fallback when the server cannot be reached (or a local-only radio).
    static func resolve(server: [GroupAudioStation]?, shared: Bool) -> (stations: [GroupAudioStation], offline: Bool) {
        if shared, let server, !server.isEmpty { return (server, false) }
        return (bundled, shared)
    }

    /// Decodes `GET /api/outings/group-audio/catalog`; https stations only.
    static func decode(_ data: Data) -> [GroupAudioStation]? {
        struct Wire: Decodable { var stations: [GroupAudioStation] }
        guard let w = try? JSONDecoder().decode(Wire.self, from: data) else { return nil }
        let ok = w.stations.filter { URL(string: $0.url)?.scheme == "https" }
        return ok.isEmpty ? nil : ok
    }
}

/// Quran recitations from mp3quran.net (one surah file each, synced on the server clock).
struct QuranReciter: Equatable, Hashable, Identifiable {
    var id: String { server }
    var name: String
    /// e.g. https://cdn.mp3quran.net/audio/abdulrahman-sudais/r1/ — 114 surahs.
    var server: String

    func item(surah n: Int) -> GroupAudioItem {
        let file = server + String(format: "%03d.mp3", n)
        return GroupAudioItem(source: .quran, id: file, title: "سورة \(QuranSurahs.name(n))", subtitle: name, url: file, live: false)
    }

    static let all: [QuranReciter] = [
        .init(name: "عبدالرحمن السديس", server: "https://cdn.mp3quran.net/audio/abdulrahman-sudais/r1/"),
        .init(name: "سعود الشريم", server: "https://cdn.mp3quran.net/audio/saud-shuraim/r1/"),
        .init(name: "ماهر المعيقلي", server: "https://cdn.mp3quran.net/audio/maher-muaiqly/r3/"),
        .init(name: "مشاري العفاسي", server: "https://cdn.mp3quran.net/audio/mishary-alafasy/r1/"),
        .init(name: "ياسر الدوسري", server: "https://cdn.mp3quran.net/audio/yasser-dosari/r1/"),
        .init(name: "سعد الغامدي", server: "https://cdn.mp3quran.net/audio/saad-ghamdi/r1/"),
        .init(name: "بندر بليلة", server: "https://cdn.mp3quran.net/audio/bandar-baleela/r1/"),
        .init(name: "عبدالباسط عبدالصمد", server: "https://cdn.mp3quran.net/audio/abdulbasit-abdulsamad/r3/"),
        .init(name: "محمد صديق المنشاوي", server: "https://cdn.mp3quran.net/audio/muhammad-minshawi/r3/"),
    ]
}

enum QuranSurahs {
    static let names: [String] = [
        "الفاتحة", "البقرة", "آل عمران", "النساء", "المائدة", "الأنعام", "الأعراف", "الأنفال", "التوبة", "يونس",
        "هود", "يوسف", "الرعد", "إبراهيم", "الحجر", "النحل", "الإسراء", "الكهف", "مريم", "طه",
        "الأنبياء", "الحج", "المؤمنون", "النور", "الفرقان", "الشعراء", "النمل", "القصص", "العنكبوت", "الروم",
        "لقمان", "السجدة", "الأحزاب", "سبأ", "فاطر", "يس", "الصافات", "ص", "الزمر", "غافر",
        "فصلت", "الشورى", "الزخرف", "الدخان", "الجاثية", "الأحقاف", "محمد", "الفتح", "الحجرات", "ق",
        "الذاريات", "الطور", "النجم", "القمر", "الرحمن", "الواقعة", "الحديد", "المجادلة", "الحشر", "الممتحنة",
        "الصف", "الجمعة", "المنافقون", "التغابن", "الطلاق", "التحريم", "الملك", "القلم", "الحاقة", "المعارج",
        "نوح", "الجن", "المزمل", "المدثر", "القيامة", "الإنسان", "المرسلات", "النبأ", "النازعات", "عبس",
        "التكوير", "الانفطار", "المطففين", "الانشقاق", "البروج", "الطارق", "الأعلى", "الغاشية", "الفجر", "البلد",
        "الشمس", "الليل", "الضحى", "الشرح", "التين", "العلق", "القدر", "البينة", "الزلزلة", "العاديات",
        "القارعة", "التكاثر", "العصر", "الهمزة", "الفيل", "قريش", "الماعون", "الكوثر", "الكافرون", "النصر",
        "المسد", "الإخلاص", "الفلق", "الناس",
    ]

    static func name(_ n: Int) -> String { (1...114).contains(n) ? names[n - 1] : SaryFormat.digits("\(n)") }
}
