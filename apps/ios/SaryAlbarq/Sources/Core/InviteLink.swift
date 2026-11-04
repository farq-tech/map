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

    /// The token from a URL the system handed us, or nil if it is not an invite.
    static func token(from url: URL) -> String? {
        let isWeb = (url.scheme == "https" || url.scheme == "http") && url.path.hasPrefix("/outings/join")
        let isApp = url.scheme == scheme && (url.host == "join" || url.path.hasPrefix("/outings/join") || url.host == "outings")
        guard isWeb || isApp else { return nil }
        if let f = url.fragment, isTokenShaped(f) { return f }
        /* saryalbarq://join/<token> — some apps strip fragments from custom schemes. */
        if isApp, let last = url.pathComponents.last, isTokenShaped(last) { return last }
        return nil
    }

    /// Whatever someone pasted: a full link, a link with spaces or text around it, or the token alone.
    static func token(fromPasted raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if isTokenShaped(t) { return t }
        for word in t.split(whereSeparator: { $0.isWhitespace }) {
            if let u = URL(string: String(word)), let tok = token(from: u) { return tok }
        }
        if let hash = t.lastIndex(of: "#") {
            let tail = String(t[t.index(after: hash)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            let tok = String(tail.prefix(43))
            if isTokenShaped(tok) { return tok }
        }
        return nil
    }
}
