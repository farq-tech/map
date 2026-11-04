#if DEBUG
import SwiftUI

/// Deterministic sample data for the showcase (fixed clock → stable screenshots).
enum Mock {
    static let now = Date(timeIntervalSince1970: 1_793_000_000)

    static func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }

    static let me = ParticipantUI(id: "me", name: "عبدالله", color: SaryCarColors.palette[0], role: .leader, isMe: true,
                                  presence: .live, distanceMeters: nil, bearingDegrees: nil, batteryPercent: 82,
                                  note: nil, hasPhone: true)
    static let fahad = ParticipantUI(id: "fahad", name: "فهد", color: SaryCarColors.palette[1], role: .coLeader, isMe: false,
                                     presence: .live, distanceMeters: 900, bearingDegrees: 35, batteryPercent: 64,
                                     note: "بوقف عند الطعس", hasVoice: true, hasPhone: true)
    static let noura = ParticipantUI(id: "noura", name: "نورة", color: SaryCarColors.palette[2], role: .member, isMe: false,
                                     presence: .live, distanceMeters: 2_400, bearingDegrees: 300, batteryPercent: 18,
                                     note: nil, hasPhone: true)
    static let saad = ParticipantUI(id: "saad", name: "سعد", color: SaryCarColors.palette[3], role: .member, isMe: false,
                                    presence: .stale(since: ago(4)), distanceMeters: 6_100, bearingDegrees: 160, batteryPercent: nil,
                                    note: nil, hasPhone: false)
    static let reem = ParticipantUI(id: "reem", name: "ريم", color: SaryCarColors.palette[4], role: .member, isMe: false,
                                    presence: .paused, distanceMeters: 12_300, bearingDegrees: 220, batteryPercent: 45,
                                    note: nil, hasPhone: true)
    static let longName = ParticipantUI(id: "long", name: "عبدالرحمن بن سليمان الدوسري", color: SaryCarColors.palette[9], role: .member,
                                        isMe: false, presence: .live, distanceMeters: 48, bearingDegrees: 90, batteryPercent: 100,
                                        note: nil, hasPhone: true)

    static let three = [me, fahad, saad]
    static let all = [me, fahad, noura, saad, reem, longName]

    static let rally = RallyPointUI(distanceMeters: 1_250, bearingDegrees: 20, arrivedCount: 3, totalCount: 5, label: "عند الطعس الكبير")
    static let rallyDone = RallyPointUI(distanceMeters: 12, bearingDegrees: 0, arrivedCount: 5, totalCount: 5, label: nil)

    static let stations = [
        StationUI(id: "s1", name: "محطة الثمامة", distanceMeters: 3_400, bearingDegrees: 40, detail: "مفتوحة ٢٤ ساعة"),
        StationUI(id: "s2", name: "محطة طريق الخرج", distanceMeters: 11_800, bearingDegrees: 190, detail: nil),
    ]

    static let voiceIdle = VoiceClipUI(id: "v1", senderName: "فهد", senderColor: SaryCarColors.palette[1], durationSeconds: 12, playback: .idle)
    static let voicePlaying = VoiceClipUI(id: "v2", senderName: "نورة", senderColor: SaryCarColors.palette[2], durationSeconds: 47, playback: .playing(progress: 0.42))
    static let voiceLoading = VoiceClipUI(id: "v3", senderName: "ريم", senderColor: SaryCarColors.palette[4], durationSeconds: 8, playback: .loading)

    static let alerts: [LiveAlertUI] = [
        .init(id: "a1", kind: .note(senderName: "فهد", senderColor: SaryCarColors.palette[1], text: "بوقف عند الطعس، تعالوا")),
        .init(id: "a2", kind: .drift(name: "سعد", color: SaryCarColors.palette[3], distanceMeters: 6_100)),
        .init(id: "a3", kind: .voice(voiceIdle)),
    ]

    static let sosIncoming = IncomingSOSUI(id: "sos1", participantId: "fahad", name: "فهد", color: SaryCarColors.palette[1],
                                           distanceMeters: 1_200, bearingDegrees: 60, hasPhone: true, since: ago(1), acknowledged: false)
}
#endif
