import Foundation

/// What the safety pack needs from the server (a fake in tests).
/// A 404/405 without an error code means «not deployed yet» (`OutingAPIError.isNotDeployed`).
protocol SafetyBackend: AnyObject {
    /// `GET /:id/return-timer` → my timer or null.
    func returnTimer(_ outingId: String) async throws -> ReturnTimerBox
    /// `POST /:id/return-timer {due_at, contact_name}` → `{timer, watch_url}` (replaces my earlier one).
    func setReturnTimer(_ outingId: String, dueAt: Date, contactName: String) async throws -> ReturnTimerBox
    /// `POST /:id/return-timer/arrived`.
    func returnTimerArrived(_ outingId: String) async throws -> ReturnTimerBox
    /// `DELETE /:id/return-timer`.
    func cancelReturnTimer(_ outingId: String) async throws
    /// `POST /:id/stuck {note?}`.
    func reportStuck(_ outingId: String, note: String?) async throws
    /// `POST /:id/stuck/:userId/reply {kind}`.
    func replyStuck(_ outingId: String, to userId: String, kind: StuckReplyKind) async throws
    /// `DELETE /:id/stuck`.
    func clearStuck(_ outingId: String) async throws
}

extension OutingsAPI: SafetyBackend {
    func returnTimer(_ outingId: String) async throws -> ReturnTimerBox {
        try await call("GET", "/\(outingId)/return-timer")
    }

    func setReturnTimer(_ outingId: String, dueAt: Date, contactName: String) async throws -> ReturnTimerBox {
        struct B: Encodable { var due_at: String; var contact_name: String }
        return try await call("POST", "/\(outingId)/return-timer", body: B(due_at: ISODate.string(dueAt), contact_name: contactName))
    }

    func returnTimerArrived(_ outingId: String) async throws -> ReturnTimerBox {
        try await call("POST", "/\(outingId)/return-timer/arrived", body: [String: String]())
    }

    func cancelReturnTimer(_ outingId: String) async throws {
        let _: OkBox = try await call("DELETE", "/\(outingId)/return-timer")
    }

    func reportStuck(_ outingId: String, note: String?) async throws {
        struct B: Encodable { var note: String? }
        let _: OkBox = try await call("POST", "/\(outingId)/stuck", body: B(note: note))
    }

    func replyStuck(_ outingId: String, to userId: String, kind: StuckReplyKind) async throws {
        let _: OkBox = try await call("POST", "/\(outingId)/stuck/\(userId)/reply", body: ["kind": kind.rawValue])
    }

    func clearStuck(_ outingId: String) async throws {
        let _: OkBox = try await call("DELETE", "/\(outingId)/stuck")
    }
}

/// The watch link is shown once by the server (it keeps only a hash), so this
/// device keeps it to share again. Forgotten on «وصلت», cancel and account wipe.
enum WatchLinkStore {
    static let key = "sary.safety.watch.v1"

    static func load(_ outingId: String, defaults: UserDefaults = .standard) -> URL? {
        ((defaults.dictionary(forKey: key) as? [String: String])?[outingId]).flatMap(URL.init(string:))
    }

    static func save(_ outingId: String, _ url: URL?, defaults: UserDefaults = .standard) {
        var all = (defaults.dictionary(forKey: key) as? [String: String]) ?? [:]
        all[outingId] = url?.absoluteString
        defaults.set(all, forKey: key)
    }

    /// Only the link format the contract promises: `https://<host>/watch#<43-char base64url token>`.
    static func valid(_ s: String?) -> URL? {
        guard let s, let u = URL(string: s), u.scheme == "https", u.path == "/watch",
              let frag = u.fragment, frag.count == 43,
              frag.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
        return u
    }
}
