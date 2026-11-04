import Foundation

/// A YouTube video picked from a link someone pasted or shared into the app.
/// Only the 11-character video id leaves this file — we never fetch, extract
/// or download a stream; the id is handed to YouTube's own embedded player.
///
/// Accepted: youtu.be/<id>, (www.|m.|music.)youtube.com/watch?v=<id>,
/// /shorts/<id>, /embed/<id>, /live/<id>, /v/<id>, youtube-nocookie.com/embed/<id>,
/// with or without a scheme, anywhere inside shared text. `t=` / `start=` is kept.
struct YouTubeLink: Equatable {
    var videoId: String
    var startSeconds: Double?

    static let idPattern = try! NSRegularExpression(pattern: "^[A-Za-z0-9_-]{11}$")

    static func isVideoId(_ s: String) -> Bool {
        idPattern.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    private static let hosts: Set<String> = [
        "youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com",
        "youtu.be", "www.youtu.be", "youtube-nocookie.com", "www.youtube-nocookie.com",
    ]

    /// First YouTube video link found in `text`, or nil.
    static func parse(_ text: String) -> YouTubeLink? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 4000 else { return nil }
        for candidate in candidates(trimmed) {
            if let link = parse(url: candidate) { return link }
        }
        return nil
    }

    /// Tokens that could be links: whitespace-separated words, with a scheme added if missing.
    private static func candidates(_ text: String) -> [URL] {
        text.split(whereSeparator: { $0.isWhitespace || $0 == "<" || $0 == ">" || $0 == "\"" })
            .map(String.init)
            .compactMap { word -> URL? in
                let w = word.trimmingCharacters(in: CharacterSet(charactersIn: "()[]{}،,.;!؟?«»'"))
                    .replacingOccurrences(of: "\u{200f}", with: "")
                    .replacingOccurrences(of: "\u{200e}", with: "")
                guard w.lowercased().contains("youtu") else { return nil }
                let withScheme = w.lowercased().hasPrefix("http://") || w.lowercased().hasPrefix("https://") ? w : "https://" + w
                return URL(string: withScheme)
            }
    }

    static func parse(url: URL) -> YouTubeLink? {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host?.lowercased(), hosts.contains(host),
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let items = comps.queryItems ?? []
        func q(_ name: String) -> String? { items.first { $0.name == name }?.value }
        let parts = url.path.split(separator: "/").map(String.init)
        var id: String?
        if host.hasSuffix("youtu.be") {
            id = parts.first
        } else if parts.first == "watch" || parts.isEmpty {
            id = q("v")
        } else if let first = parts.first, ["shorts", "embed", "live", "v"].contains(first), parts.count >= 2 {
            id = parts[1]
        }
        guard let id, isVideoId(id) else { return nil }
        let start = (q("t") ?? q("start")).flatMap(seconds(from:))
        return YouTubeLink(videoId: id, startSeconds: start)
    }

    /// "90", "90s", "1m30s", "1h2m3s" → seconds.
    static func seconds(from raw: String) -> Double? {
        if let n = Double(raw), n >= 0 { return n }
        var total = 0.0, num = "", seen = false
        for ch in raw.lowercased() {
            if ch.isNumber { num.append(ch); continue }
            guard let n = Double(num) else { return nil }
            switch ch {
            case "h": total += n * 3600
            case "m": total += n * 60
            case "s": total += n
            default: return nil
            }
            num = ""
            seen = true
        }
        if !num.isEmpty { return nil }
        return seen ? total : nil
    }

    /// The canonical watch URL (used for YouTube's oEmbed title lookup).
    var watchURL: URL { URL(string: "https://www.youtube.com/watch?v=\(videoId)")! }
}
