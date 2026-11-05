import Foundation

/// The share extension → app hand-off: ONE pending video id (and start time)
/// in the App Group's defaults, taken once, ignored after an hour. Compiled
/// into both the app and the share extension.
enum MediaShareInbox {
    static let group = "group.sa.sary.albarq"
    private static let key = "sary.media.shared.v1"
    static let maxAge: TimeInterval = 3600

    static var defaults: UserDefaults? { UserDefaults(suiteName: group) }

    static func put(_ link: YouTubeLink, now: Date = Date(), in d: UserDefaults? = defaults) {
        d?.set(["v": link.videoId, "t": link.startSeconds ?? 0, "at": now.timeIntervalSince1970], forKey: key)
    }

    static func take(now: Date = Date(), from d: UserDefaults? = defaults) -> YouTubeLink? {
        guard let d, let o = d.dictionary(forKey: key) else { return nil }
        d.removeObject(forKey: key)
        guard let v = o["v"] as? String, YouTubeLink.isVideoId(v),
              let at = o["at"] as? Double, now.timeIntervalSince1970 - at < maxAge else { return nil }
        let t = o["t"] as? Double ?? 0
        return YouTubeLink(videoId: v, startSeconds: t > 0 ? t : nil)
    }

    /// Account deletion / `-resetState`: drop a pending shared link.
    static func forget(in d: UserDefaults? = defaults) { d?.removeObject(forKey: key) }
}
