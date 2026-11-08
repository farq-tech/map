import Foundation

/// Invite links: `https://farq-map-investor.vercel.app/outings/join#<token>`.
/// The token rides in the fragment so no server log ever sees it; the app
/// accepts the Universal Link, the `saryalbarq://` fallback, or a pasted link
/// or bare token.
enum InviteLink {
    static let webOrigin = "https://farq-map-investor.vercel.app"
    static let scheme = "saryalbarq"

    /// 32 random bytes, base64url, unpadded — `validate.isSecretShaped`.
    static func isTokenShaped(_ s: String) -> Bool {
        s.count == 43 && s.unicodeScalars.allSatisfy { c in
            (c >= "A" && c <= "Z") || (c >= "a" && c <= "z") || (c >= "0" && c <= "9") || c == "-" || c == "_"
        }
    }

    static func url(for token: String) -> URL {
        URL(string: "\(webOrigin)/outings/join#\(token)")!
    }

    /// The token alphabet (base64url).
    static func isTokenScalar(_ c: Unicode.Scalar) -> Bool {
        (c >= "A" && c <= "Z") || (c >= "a" && c <= "z") || (c >= "0" && c <= "9") || c == "-" || c == "_"
    }

    /// Drops what people never see but paste anyway: Arabic diacritics stuck to the link
    /// («ً» after the last letter), RTL / LRM / ALM / zero-width marks, BOMs.
    static func stripInvisible(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for c in s.unicodeScalars {
            switch c.properties.generalCategory {
            case .format, .nonspacingMark, .enclosingMark, .spacingMark, .control where c != "\n" && c != "\t": continue
            default: out.append(c)
            }
        }
        return String(out)
    }

    /// The token at the start of `s` (after invisible marks are gone): the whole run of
    /// token characters, exactly 43 of them — never trimmed down from a longer run.
    static func leadingToken<S: StringProtocol>(_ s: S) -> String? {
        let run = stripInvisible(String(s)).unicodeScalars.prefix(while: isTokenScalar)
        let t = String(String.UnicodeScalarView(run))
        return isTokenShaped(t) ? t : nil
    }

    /// The token from a URL the system handed us, or nil if it is not an invite.
    static func token(from url: URL) -> String? {
        let isWeb = (url.scheme == "https" || url.scheme == "http") && url.path.hasPrefix("/outings/join")
        let isApp = url.scheme == scheme && (url.host == "join" || url.path.hasPrefix("/outings/join") || url.host == "outings")
        guard isWeb || isApp else { return nil }
        if let f = url.fragment, let t = leadingToken(f.removingPercentEncoding ?? f) { return t }
        /* saryalbarq://join/<token> — some apps strip fragments from custom schemes. */
        if isApp, let last = url.pathComponents.last, let t = leadingToken(last) { return t }
        return nil
    }

    /// Whatever someone pasted: a full link, a link with spaces, text or a stray «ً» around it, or the token alone.
    static func token(fromPasted raw: String) -> String? {
        let t = stripInvisible(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        if isTokenShaped(t) { return t }
        for word in t.split(whereSeparator: { $0.isWhitespace }) {
            if let u = URL(string: String(word)), let tok = token(from: u) { return tok }
        }
        if let hash = t.lastIndex(of: "#") {
            let tail = t[t.index(after: hash)...].drop(while: { $0.isWhitespace })
            if let tok = leadingToken(tail) { return tok }
        }
        return nil
    }
}

/// What the invite sheet shows for a preview / an error (the claim matrix, kept pure for tests).
/// The server decides who a personal invite belongs to: the same account («yours»), the same
/// person back with a new account whose phone matches the leader's contact (`reclaim`, sent as
/// «open» to older apps), or someone else («taken»). A broken link is never «taken».
enum InviteClaim {
    enum Outcome: Equatable { case join, taken, expired, invalid, other }

    static func outcome(_ p: InvitePreview) -> Outcome {
        p.isPersonal && p.claim == "taken" ? .taken : .join
    }

    static func outcome(errorCode code: String) -> Outcome {
        switch code {
        case "invite_expired", "invite_revoked", "open_links_disabled": return .expired
        case "invite_taken": return .taken
        case "invite_invalid", "not_found", "http_404", "http_400": return .invalid
        default: return .other
        }
    }
}
