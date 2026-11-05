import Foundation

/// «ترددات» — the channels of one trip's walkie-talkie (server:
/// apps/api/lib/outings/ptt-channels.js).
///
///   * five public channels «تردد ١…٥» (ids "1"…"5"): everyone may listen and
///     talk; one talker per channel; everyone starts on ١;
///   * private channels «تردد خاص» (id = uuid) the trip leader opens for the
///     members he picks. The server enforces who may join, hear, talk and be
///     woken — the phone only shows what the server says.
///
/// One channel at a time: switching ends what we heard on the old one (no roger),
/// and the server sends the new one's current sentence from its start.
struct PTTChannelInfo: Equatable, Identifiable, Decodable {
    enum Kind: String, Decodable { case `public`, `private` }
    struct Talker: Equatable, Decodable {
        var userId: String
        var name: String
        enum CodingKeys: String, CodingKey { case userId = "user_id", name }
    }

    var id: String
    var kind: Kind
    var name: String
    var listeners: [String] = []
    var talker: Talker?
    /// Private only: who is invited (the leader included).
    var members: [String] = []
    var createdBy: String?
    /// Private only: may I rename it, add / remove people, close it.
    var canManage = false

    enum CodingKeys: String, CodingKey { case id, kind, name, listeners, talker, members, createdBy = "created_by", canManage = "can_manage" }

    init(id: String, kind: Kind, name: String, listeners: [String] = [], talker: Talker? = nil, members: [String] = [], createdBy: String? = nil, canManage: Bool = false) {
        self.id = id
        self.kind = kind
        self.name = name
        self.listeners = listeners
        self.talker = talker
        self.members = members
        self.createdBy = createdBy
        self.canManage = canManage
    }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = (try? c.decode(Kind.self, forKey: .kind)) ?? (PTTChannels.isPublic(id) ? .public : .private)
        name = (try? c.decode(String.self, forKey: .name)) ?? PTTChannels.publicName(id)
        listeners = (try? c.decode([String].self, forKey: .listeners)) ?? []
        talker = try? c.decodeIfPresent(Talker.self, forKey: .talker)
        members = (try? c.decode([String].self, forKey: .members)) ?? []
        createdBy = try? c.decodeIfPresent(String.self, forKey: .createdBy)
        canManage = (try? c.decode(Bool.self, forKey: .canManage)) ?? false
    }

    var isPrivate: Bool { kind == .private }
}

/// Server → phone channel messages (ptt_channels / ptt_channel_kicked / ptt_channel_invite).
enum PTTChannelEvent: Equatable {
    case list(current: String?, canCreate: Bool, channels: [PTTChannelInfo])
    /// Taken off `channel` (removed from it, it was closed, or never invited): we are on ١ now.
    case kicked(channel: String, reason: String)
    /// «أمير الرحلة دعاك إلى تردد خاص: …»
    case invited(channel: String, name: String, by: String?)

    static func decode(_ m: [String: Any]) -> PTTChannelEvent? {
        switch m["type"] as? String {
        case "ptt_channels":
            guard let raw = m["channels"], let d = try? JSONSerialization.data(withJSONObject: raw),
                  let list = try? JSONDecoder().decode([PTTChannelInfo].self, from: d) else { return nil }
            return .list(current: m["current"] as? String, canCreate: m["can_create"] as? Bool == true, channels: list)
        case "ptt_channel_kicked":
            guard let ch = m["channel"] as? String else { return nil }
            return .kicked(channel: ch, reason: (m["reason"] as? String) ?? "removed")
        case "ptt_channel_invite":
            guard let ch = m["channel"] as? String else { return nil }
            return .invited(channel: ch, name: (m["name"] as? String) ?? "تردد خاص", by: m["by"] as? String)
        default:
            return nil
        }
    }
}

enum PTTChannels {
    static let publicIds = ["1", "2", "3", "4", "5"]
    static let defaultId = "1"
    static let preferredKey = "sary.ptt.defaultChannel.v1"
    /// «التردد الافتراضي» (الإعدادات): where a new outing starts; one of the public channels.
    static var preferredDefault: String {
        get { UserDefaults.standard.string(forKey: preferredKey).flatMap { isPublic($0) ? $0 : nil } ?? defaultId }
        set { UserDefaults.standard.set(isPublic(newValue) ? newValue : defaultId, forKey: preferredKey) }
    }
    /// The leader's limit, as the server has it (`PTT_MAX_PRIVATE`).
    static let maxPrivate = 5
    static let nameMax = 40

    static func isPublic(_ id: String) -> Bool { publicIds.contains(id) }

    private static let digits: [Character] = ["٠", "١", "٢", "٣", "٤", "٥", "٦", "٧", "٨", "٩"]
    static func arabicDigits(_ s: String) -> String {
        String(s.map { c in c.wholeNumberValue.map { digits[$0] } ?? c })
    }

    /// «تردد ٣»
    static func publicName(_ id: String) -> String { "تردد \(arabicDigits(id))" }

    /// The five public channels before the server's list arrives (and on an older server).
    static var publicList: [PTTChannelInfo] { publicIds.map { PTTChannelInfo(id: $0, kind: .public, name: publicName($0)) } }

    /// What the system Push to Talk UI shows on the Lock Screen / Dynamic Island.
    static func systemLabel(_ channelName: String) -> String { "قناة الطلعة · \(channelName)" }

    /// The chip on the button: «تردد ٣» / «🔒 الأمامية» (the lock is an icon in the view).
    static func chipLabel(_ c: PTTChannelInfo?) -> String { c?.name ?? publicName(defaultId) }

    /// «٣ يسمعون» / «يسمعك فهد» … for one row of the sheet.
    static func listenersLine(_ c: PTTChannelInfo, me: String, name: (String) -> String?) -> String {
        let others = c.listeners.filter { $0 != me }
        let names = others.compactMap(name)
        switch others.count {
        case 0: return c.listeners.contains(me) ? "لا أحد غيرك" : "لا أحد يسمع"
        case 1: return "يسمع: \(names.first ?? "عضو")"
        case 2: return "يسمع: \(names.prefix(2).joined(separator: " و"))"
        default:
            let first = names.prefix(2).joined(separator: "، ")
            return "يسمع: \(first) +\(arabicDigits(String(others.count - min(2, names.count))))"
        }
    }

    static func kickedText(_ reason: String, name: String?) -> String {
        let n = name ?? "التردد الخاص"
        switch reason {
        case "closed": return "أغلق أمير الرحلة «\(n)» — رجعت إلى تردد ١"
        case "not_invited": return "«\(n)» للمدعوين فقط — أنت على تردد ١"
        default: return "أُخرجت من «\(n)» — رجعت إلى تردد ١"
        }
    }

    static func inviteText(_ name: String) -> String { "أمير الرحلة دعاك إلى تردد خاص: \(name)" }
}

/// When the first word of a friend reaches the ear, and why it is no later.
///
/// The squelch («كشش») starts the moment the server says someone is on air
/// (`ptt_talker`, sent before their first frame). Their voice waits only for the
/// shorter of the cue and `maxVoiceLead`, and the jitter buffer fills in
/// parallel, so the two delays overlap instead of adding up: the tail of the
/// squelch and the chirp sound under the first syllable, like a real radio.
enum PTTPlayout {
    /// The voice never waits longer than this for the squelch.
    static let maxVoiceLead: TimeInterval = 0.12
    /// What the owner asked for: the voice within ~150 ms of its first frame.
    static let budget: TimeInterval = 0.15

    /// Silence before the voice (seconds) for an opening cue of `cue` seconds (nil: no cue).
    static func voiceLead(cue: TimeInterval?) -> TimeInterval { min(cue ?? 0, maxVoiceLead) }

    /// From the first audio frame's arrival to the first voice sample, in seconds:
    /// `talkerToFrame` = how long after `ptt_talker` (when the squelch starts) that frame
    /// came; frames then arrive every `frameInterval`; playout starts once `targetDepth`
    /// are queued and the lead is over; the pull is clocked in `frameInterval` steps.
    static func firstVoiceDelay(cue: TimeInterval?, talkerToFrame: TimeInterval, targetDepth: Int = 3,
                                frameInterval: TimeInterval = PTTFrame.packetMs / 1000, burstFrames: Int = 0) -> TimeInterval {
        let lead = voiceLead(cue: cue)
        /* A pre-roll burst (frames recorded while the floor was asked for) fills the buffer at once. */
        let fill = Double(max(0, targetDepth - 1 - burstFrames)) * frameInterval
        let leadLeft = max(0, lead - talkerToFrame)
        let ready = max(fill, leadLeft)
        /* No cue: silence buffers are pulled every frameInterval, so the start rounds up to the next pull. */
        if cue == nil {
            let since = talkerToFrame + ready
            /* …and plays after the one silent buffer already queued ahead of it. */
            return (since / frameInterval).rounded(.up) * frameInterval - talkerToFrame + frameInterval
        }
        return ready
    }
}
