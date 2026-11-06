import Foundation

/// «مساعد سرى» without the model (and its fast path with it): plain keyword rules over the
/// normalised sentence. They answer only when a sentence clearly says one thing; otherwise nil,
/// and the model (if downloaded) or a clarifying question takes over.
///
/// Safety first: anything that sounds like an emergency is `.sosHelp` before anything else.
enum AssistantKeywords {
    struct Context: Equatable {
        var members: [String]
        var destinationName: String?
    }

    static func match(_ raw: String, _ ctx: Context) -> AssistantIntent? {
        let n = AssistantText.normalize(raw)
        guard !n.isEmpty else { return nil }
        let words = n.split(separator: " ").map(String.init)
        func has(_ keys: [String]) -> Bool { keys.contains { k in n.contains(k) } }
        func word(_ keys: [String]) -> Bool { words.contains { w in keys.contains(w) } }

        // 1. Emergencies: explained, never sent.
        /* «حادث» as its own word only: «المحادثة» (the chat) contains it. */
        let accident = words.contains { w in ["حادث", "الحادث", "بحادث", "حادثه", "حوادث"].contains(w) }
        if accident || has(["فزع", "استغاث", "طوارئ", "طواري", "sos", "غرز", "الدفاع المدني", "اسعاف", "انقذ", "ساعدوني", "ساعدونا", "النجده", "نجده",
                            "انقلب", "مصاب", "انصاب", "اصابه", "نزيف", "emergency"]) {
            return .sosHelp
        }

        // 2. The walkie-talkie channel.
        if has(["تردد", "channel"]) {
            if let c = channelNumber(words) { return .setChannel(c) }
            return nil
        }

        // 3. The trip radio.
        if has(["اذاع", "راديو", "radio", "قران"]) {
            let stop = word(["وقف", "وقفها", "طف", "اطف", "طفي", "اطفي", "سكر", "سكرها", "قفل", "بند", "اسكت", "كتم", "stop", "off"])
                || has(["طفها", "وقفوا", "سكت"])
            return .radio(play: !stop)
        }

        // 4. The group chat.
        if has(["محادث", "شات", "دردش", "رسايل", "رسائل", "القروب", "قروب", "chat"]) || (has(["اكتب"]) && has(["للربع", "للعيال", "للشباب", "للجماعه"])) {
            return .openChat
        }

        // 5. «ودني / خذني / وجهني / ابدأ التوجيه …»: guidance somewhere.
        let navVerb = words.contains { w in
            ["ودني", "ودنا", "خذني", "خذنا", "وجهني", "وجهنا", "وصلني", "رجعني", "رجعنا", "navigate"].contains(w)
        } || has(["التوجيه", "الملاحه", "ابي اروح", "ابغى اروح", "ابغي اروح", "نبي نروح", "ودني", "خذني"])
        if navVerb {
            if let m = AssistantText.member(in: raw, members: ctx.members) { return .navigate(.member(m)) }
            if has(["تجمع", "نتلاقي", "نتقابل"]) { return .navigate(.rally) }
            if has(["محط", "بنزين", "بانزين", "وقود"]) { return .navigate(.station) }
            if has(["بدايه", "البيت", "نفس الطريق", "الرجعه"]) || word(["رجعني", "رجعنا"]) { return .navigate(.back) }
            if mentionsDestination(words, ctx) { return .navigate(.destination) }
            return nil
        }

        // 6. The meeting point.
        if has(["تجمع", "نتلاقي", "نتقابل", "rally", "meeting point"]) { return .rallyPoint }

        // 7. Sunset and the way back.
        let sun = has(["مغرب", "غروب", "يغرب", "تغيب", "غابت", "الظلام", "يظلم", "تظلم", "sunset"])
        let wayBack = has(["طريق الرجعه", "الرجعه", "نرجع", "نلحق نرجع"]) && (sun || has(["كم ياخذ", "كم تاخذ", "كم ياخذ", "وقت"]))
        if wayBack { return .sunset(.wayBack) }
        if sun {
            if has(["كم باقي", "باقي", "قبل", "بقي", "كم ساعه"]) { return .sunset(.remaining) }
            return .sunset(.time)
        }

        // 8. Petrol.
        if has(["بنزين", "بانزين", "محطه", "محطات", "وقود", "اعبي", "نعبي", "ازود", "gas", "fuel", "petrol"]) { return .nearestFuel }

        // 9. Weather (the specific aspect wins over «الجو»).
        if has(["عجاج", "غبار", "غبره", "مغبر", "dust"]) { return .weather(.dust) }
        if has(["ريح", "رياح", "الهوا", "هوا ", "هبوب", "wind"]) || word(["هوا"]) { return .weather(.wind) }
        if has(["مطر", "تمطر", "امطار", "سحاب", "rain"]) { return .weather(.rain) }
        if has(["حراره", "حار", "الحر", "برد", "بارد", "temperature"]) { return .weather(.temp) }
        if has(["الطقس", "طقس", "الجو", "weather"]) { return .weather(.general) }

        // 10. Where the others are.
        let whereWord = word(["وين", "فين", "وينه", "وينها", "وينهم", "ويين", "where"]) || has(["يبعد", "بعيد", "قريب", "بعاد", "مكان"])
        let member = AssistantText.member(in: raw, members: ctx.members)
        if whereWord, let member { return .membersWhere(who: member) }
        let group = has(["الربع", "العيال", "الشباب", "الجماعه", "الجميع", "guys", "everyone"]) || word(["الكل"])
        if whereWord && group { return .membersWhere(who: nil) }

        // 11. What is left to the destination.
        if has(["كم باقي", "متى نوصل", "متى بنوصل", "نوصل", "كم كيلو", "المسافه", "قدامنا", "بقي لنا", "بقي علينا", "قربنا", "eta"]) || word(["باقي"]) {
            return .tripRemaining
        }
        return nil
    }

    /// «تردد ٣»، «التردد خمسة»، «لاربعه».
    static func channelNumber(_ words: [String]) -> Int? {
        let table: [(Int, [String])] = [(1, ["واحد", "1"]), (2, ["اثنين", "ثنين", "اثنان", "2"]), (3, ["ثلاث", "ثلاثه", "3"]),
                                        (4, ["اربع", "اربعه", "4"]), (5, ["خمس", "خمسه", "5"])]
        var found: Set<Int> = []
        for w in words {
            let bare = ["لل", "ل", "ب", "ع", "ال"].reduce(w) { s, p in s.hasPrefix(p) && s.count > p.count + 1 ? String(s.dropFirst(p.count)) : s }
            for (n, keys) in table where keys.contains(w) || keys.contains(bare) { found.insert(n) }
            /* «تردد3» typed together. */
            if w.hasPrefix("تردد"), let d = w.last?.wholeNumberValue, (1...5).contains(d) { found.insert(d) }
        }
        return found.count == 1 ? found.first : nil
    }

    private static func mentionsDestination(_ words: [String], _ ctx: Context) -> Bool {
        if words.contains(where: { ["الوجهه", "للوجهه", "وجهتنا", "وجهتي", "destination"].contains($0) }) { return true }
        guard let d = ctx.destinationName else { return false }
        var keys: [String] = []
        for part in AssistantText.normalize(d).split(separator: " ") {
            var w = String(part)
            if w.hasPrefix("ال"), w.count > 4 { w = String(w.dropFirst(2)) }
            if w.count >= 3 { keys.append(w) }
        }
        return words.contains { w in keys.contains { k in w.contains(k) } }
    }
}
