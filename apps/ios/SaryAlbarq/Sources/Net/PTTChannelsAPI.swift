import Foundation

/// «ترددات»: the private channels of a trip («تردد خاص»), over REST
/// (server: apps/api/routes/outings.js → lib/outings/ptt-channels.js).
///
///   GET    /api/outings/:id/ptt/channels               five public + the private ones I am in
///   POST   /api/outings/:id/ptt/channels               { name, members }   (the trip leader)
///   PATCH  /api/outings/:id/ptt/channels/:channelId    { name?, add?, remove? }
///   DELETE /api/outings/:id/ptt/channels/:channelId
///
/// The live list, kicks and invitations come over the socket (`PTTChannelEvent`).
protocol PTTChannelBackend: AnyObject {
    func createPTTChannel(_ outingId: String, name: String, members: [String]) async throws -> PTTChannelInfo
    func updatePTTChannel(_ outingId: String, channel: String, name: String?, add: [String], remove: [String]) async throws -> PTTChannelInfo
    func closePTTChannel(_ outingId: String, channel: String) async throws
}

extension OutingsAPI: PTTChannelBackend {
    struct PTTChannelBox: Decodable { var channel: PTTChannelInfo }
    struct PTTChannelListBox: Decodable {
        var channels: [PTTChannelInfo]
        var current: String?
        var can_create: Bool?
    }
    private struct CreateBody: Encodable { var name: String; var members: [String] }
    private struct PatchBody: Encodable { var name: String?; var add: [String]; var remove: [String] }

    func listPTTChannels(_ outingId: String) async throws -> PTTChannelListBox {
        try await call("GET", "/\(outingId)/ptt/channels")
    }

    func createPTTChannel(_ outingId: String, name: String, members: [String]) async throws -> PTTChannelInfo {
        let r: PTTChannelBox = try await call("POST", "/\(outingId)/ptt/channels", body: CreateBody(name: name, members: members))
        return r.channel
    }

    func updatePTTChannel(_ outingId: String, channel: String, name: String?, add: [String], remove: [String]) async throws -> PTTChannelInfo {
        let r: PTTChannelBox = try await call("PATCH", "/\(outingId)/ptt/channels/\(channel)", body: PatchBody(name: name, add: add, remove: remove))
        return r.channel
    }

    func closePTTChannel(_ outingId: String, channel: String) async throws {
        let _: OkBox = try await call("DELETE", "/\(outingId)/ptt/channels/\(channel)", body: [String: String]())
    }
}

extension PTTChannels {
    /// The server's refusal in words.
    static func errorText(_ e: Error) -> String {
        switch (e as? OutingAPIError)?.code {
        case "leader_only": return "التردد الخاص لأمير الطلعة فقط"
        case "too_many_channels": return "وصلت للحد: ٥ ترددات خاصة في الطلعة"
        case "invalid_name": return "اكتب اسمًا للتردد"
        case "invalid_members": return "بعض الأصدقاء ما عادوا في الطلعة"
        case "cannot_remove_self": return "ما تقدر تخرج نفسك — أغلق التردد بدلًا من ذلك"
        case "channel_not_found": return "هذا التردد ما عاد موجود"
        case "outing_ended": return "انتهت الطلعة"
        case "network", "timeout": return "لا اتصال الآن — جرّب بعد قليل"
        default: return "ما تم — جرّب مرة ثانية"
        }
    }
}
