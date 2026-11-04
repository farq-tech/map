import SwiftUI
import UIKit
import WebKit

/// The one player both channels share. Two implementations: YouTube's official
/// embedded IFrame player in a WKWebView (the app), and a stub (UI tests only).
@MainActor
protocol MediaPlayerEngine: AnyObject {
    var onEvent: (MediaPlayerEvent) -> Void { get set }
    var view: UIView { get }
    func load(videoId: String, start: Double, play: Bool)
    func play()
    func pause()
    func seek(to seconds: Double)
    func setRate(_ rate: Double)
    func unload()
    func reading() async -> MediaSync.PlayerReading?
}

enum MediaPlayerEvent: Equatable {
    case ready
    case playing
    case paused
    case buffering
    case ended
    /// YouTube error codes: 2 bad id, 5 HTML5, 100 gone/private, 101/150 owner disallows embedding.
    case error(Int)

    var arabicError: String? {
        guard case let .error(c) = self else { return nil }
        switch c {
        case 100: return "الفيديو محذوف أو خاص."
        case 101, 150, 152, 153: return "صاحب الفيديو ما يسمح بتشغيله خارج يوتيوب."
        case 2: return "الرابط مو صحيح."
        default: return "تعذّر تشغيل الفيديو."
        }
    }
}

/// YouTube's official embedded player (IFrame Player API) — nothing else.
/// We never extract streams, download, play audio-only, hide or cover the
/// player, or keep it playing in the background. Picture-in-Picture and AirPlay
/// are off so the video stays on the phone screen (and never on CarPlay).
@MainActor
final class YouTubeIFramePlayer: NSObject, MediaPlayerEngine, WKScriptMessageHandler, WKNavigationDelegate {
    var onEvent: (MediaPlayerEvent) -> Void = { _ in }
    private let web: WKWebView
    private var isReady = false
    private var pending: [String] = []
    var view: UIView { web }

    /// The page's origin. YouTube asks embedders to send a real origin/referrer;
    /// the app's bundle id is the convention for native apps.
    static var origin: String { "https://\((Bundle.main.bundleIdentifier ?? "sa.sary.albarq").lowercased())" }

    override init() {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsPictureInPictureMediaPlayback = false
        config.allowsAirPlayForMediaPlayback = false
        config.websiteDataStore = .default()
        let ucc = WKUserContentController()
        config.userContentController = ucc
        web = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 180), configuration: config)
        super.init()
        ucc.add(WeakScriptHandler(self), name: "yt")
        web.navigationDelegate = self
        web.isOpaque = false
        web.backgroundColor = .black
        web.scrollView.isScrollEnabled = false
        web.scrollView.bounces = false
        web.semanticContentAttribute = .forceLeftToRight
        web.accessibilityIdentifier = "media.player"
        web.loadHTMLString(Self.html(origin: Self.origin), baseURL: URL(string: Self.origin))
    }

    static func html(origin: String) -> String {
        """
        <!DOCTYPE html><html><head>
        <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
        <meta name="referrer" content="strict-origin-when-cross-origin">
        <style>html,body{margin:0;padding:0;background:#000;width:100%;height:100%;overflow:hidden}#p{position:absolute;inset:0;width:100%;height:100%}</style>
        </head><body><div id="p"></div>
        <script>
        var player=null;
        function post(m){try{window.webkit.messageHandlers.yt.postMessage(m)}catch(e){}}
        var tag=document.createElement('script');tag.src='https://www.youtube.com/iframe_api';document.head.appendChild(tag);
        function onYouTubeIframeAPIReady(){
          player=new YT.Player('p',{width:'100%',height:'100%',
            playerVars:{playsinline:1,rel:0,enablejsapi:1,origin:'\(origin)',widget_referrer:'\(origin)'},
            events:{
              onReady:function(){post({e:'ready'})},
              onStateChange:function(ev){post({e:'state',s:ev.data})},
              onError:function(ev){post({e:'error',c:ev.data})}
            }});
        }
        function saryLoad(id,start,play){if(!player)return;var o={videoId:id,startSeconds:start};if(play){player.loadVideoById(o)}else{player.cueVideoById(o)}}
        function saryRead(){if(!player||!player.getCurrentTime)return null;var d=player.getVideoData?player.getVideoData():null;
          return JSON.stringify({t:player.getCurrentTime()||0,s:player.getPlayerState(),r:player.getPlaybackRate()||1,v:(d&&d.video_id)||null})}
        </script></body></html>
        """
    }

    private func js(_ code: String) {
        guard isReady else { pending.append(code); return }
        web.evaluateJavaScript(code, completionHandler: nil)
    }

    func load(videoId: String, start: Double, play: Bool) {
        guard YouTubeLink.isVideoId(videoId) else { return }
        js("saryLoad('\(videoId)',\(Self.num(start)),\(play ? "true" : "false"))")
    }

    func play() { js("player&&player.playVideo()") }
    func pause() { js("player&&player.pauseVideo()") }
    func seek(to seconds: Double) { js("player&&player.seekTo(\(Self.num(seconds)),true)") }
    func setRate(_ rate: Double) { js("player&&player.setPlaybackRate(\(Self.num(rate)))") }
    func unload() {
        pending.removeAll()
        js("player&&player.stopVideo()")
    }

    func reading() async -> MediaSync.PlayerReading? {
        guard isReady, let s = try? await web.evaluateJavaScript("saryRead()") as? String,
              let d = s.data(using: .utf8), let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return nil }
        let state = (o["s"] as? Int) ?? -1
        return MediaSync.PlayerReading(videoId: o["v"] as? String, position: (o["t"] as? Double) ?? 0,
                                       playing: state == 1 || state == 3, rate: (o["r"] as? Double) ?? 1)
    }

    private static func num(_ d: Double) -> String { String(format: "%.3f", d.isFinite ? d : 0) }

    // MARK: WK

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let o = message.body as? [String: Any], let e = o["e"] as? String else { return }
        switch e {
        case "ready":
            isReady = true
            let queued = pending
            pending.removeAll()
            for c in queued { web.evaluateJavaScript(c, completionHandler: nil) }
            onEvent(.ready)
        case "state":
            switch o["s"] as? Int {
            case 0: onEvent(.ended)
            case 1: onEvent(.playing)
            case 2: onEvent(.paused)
            case 3: onEvent(.buffering)
            default: break
            }
        case "error":
            onEvent(.error((o["c"] as? Int) ?? -1))
        default: break
        }
    }

    /// Links inside the player (the YouTube logo, "Watch on YouTube") open YouTube itself, not our web view.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        if action.navigationType == .linkActivated, let url = action.request.url {
            UIApplication.shared.open(url)
            return decisionHandler(.cancel)
        }
        decisionHandler(.allow)
    }
}

private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: (any WKScriptMessageHandler)?
    init(_ t: any WKScriptMessageHandler) { target = t }
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(ucc, didReceive: message)
    }
}

/// UI tests only (`-SaryStubPlayer`): a clock instead of YouTube, so tests never need the network.
@MainActor
final class StubMediaPlayer: MediaPlayerEngine {
    var onEvent: (MediaPlayerEvent) -> Void = { _ in }
    private let label = UILabel()
    private let box = UIView()
    private(set) var videoId: String?
    private var base: Double = 0
    private var since: Date?
    private var rate: Double = 1
    var view: UIView { box }

    init() {
        box.backgroundColor = .black
        box.accessibilityIdentifier = "media.player"
        box.isAccessibilityElement = false
        label.textColor = .white
        label.textAlignment = .center
        label.numberOfLines = 0
        label.font = .boldSystemFont(ofSize: 15)
        label.accessibilityIdentifier = "media.stub"
        label.text = "مشغّل تجريبي"
        label.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(label)
        NSLayoutConstraint.activate([label.centerXAnchor.constraint(equalTo: box.centerXAnchor), label.centerYAnchor.constraint(equalTo: box.centerYAnchor)])
        DispatchQueue.main.async { [weak self] in self?.onEvent(.ready) }
    }

    private var position: Double { base + (since.map { Date().timeIntervalSince($0) * rate } ?? 0) }

    func load(videoId: String, start: Double, play: Bool) {
        self.videoId = videoId
        base = start
        since = play ? Date() : nil
        label.text = "مشغّل تجريبي · \(videoId)"
        onEvent(play ? .playing : .paused)
    }
    func play() { guard since == nil, videoId != nil else { return }; since = Date(); onEvent(.playing) }
    func pause() { guard since != nil else { return }; base = position; since = nil; onEvent(.paused) }
    func seek(to seconds: Double) { base = seconds; if since != nil { since = Date() } }
    func setRate(_ r: Double) { base = position; if since != nil { since = Date() }; rate = r }
    func unload() { videoId = nil; since = nil; base = 0; label.text = "مشغّل تجريبي" }
    func reading() async -> MediaSync.PlayerReading? {
        MediaSync.PlayerReading(videoId: videoId, position: position, playing: since != nil, rate: rate)
    }
}

/// Puts the engine's view on screen. Always at least 200 × 200 pt (YouTube's minimum), never covered.
struct MediaPlayerHost: UIViewRepresentable {
    let engine: MediaPlayerEngine

    func makeUIView(context: Context) -> UIView {
        let host = UIView()
        host.backgroundColor = .black
        host.clipsToBounds = true
        attach(engine.view, to: host)
        return host
    }

    func updateUIView(_ host: UIView, context: Context) {
        if engine.view.superview !== host { attach(engine.view, to: host) }
    }

    private func attach(_ v: UIView, to host: UIView) {
        v.removeFromSuperview()
        v.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(v)
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: host.leadingAnchor), v.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            v.topAnchor.constraint(equalTo: host.topAnchor), v.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
    }
}
