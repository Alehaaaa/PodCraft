import Observation
import SwiftUI
import WebKit

/// An episode's official YouTube upload, played inside PodCraft. YouTube's embedded player does the playing, but
/// none of its own interface shows or takes touches: PodCraft's player controls drive it.
/// The video id comes from the Mac (its library or Sync) or from the phone's own search (YouTubeFinder).
@MainActor
@Observable
final class YouTubeVideo {
    let videoID: String
    /// Where the video is, in seconds, as the embedded player last said.
    private(set) var time: Double
    private(set) var isPlaying = false
    private(set) var isReady = false
    /// The first frame is playing: until then (and after the end) the player covers YouTube's start and end screens.
    private(set) var hasStarted = false
    private(set) var ended = false
    /// YouTube refused to play it here (embedding turned off, private, removed…). Open it in YouTube instead.
    private(set) var failed = false

    @ObservationIgnored let webView: WKWebView
    @ObservationIgnored private let messages = MessageProxy()

    init(videoID: String, start: Double, rate: Float) {
        self.videoID = videoID
        time = max(0, start)
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsPictureInPictureMediaPlayback = true
        config.userContentController.add(messages, name: "yt")
        webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        // Only the picture: no YouTube controls, menus or links to tap.
        webView.isUserInteractionEnabled = false
        messages.receive = { [weak self] body in self?.handle(body) }
        guard Self.isValid(videoID) else { failed = true; return }
        // YouTube wants to know who embeds the player; an app uses an https origin made from its bundle id.
        let origin = "https://" + (Bundle.main.bundleIdentifier ?? "app.podcraft.ios").lowercased()
        webView.loadHTMLString(Self.page(videoID: videoID, start: time, rate: rate, origin: origin),
                               baseURL: URL(string: origin))
    }

    /// The video on youtube.com (the YouTube app opens it when installed), at the same moment.
    static func link(videoID: String, at seconds: Double) -> URL? {
        URL(string: "https://www.youtube.com/watch?v=\(videoID)&t=\(max(0, Int(seconds)))s")
    }

    nonisolated static func isValid(_ id: String) -> Bool {
        id.count == 11 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    // MARK: Controls

    func play() {
        if ended { seek(to: 0) }
        run("player.playVideo()"); isPlaying = true
    }
    func pause() { run("player.pauseVideo()"); isPlaying = false }
    func togglePlay() { isPlaying ? pause() : play() }

    func seek(to seconds: Double) {
        let t = max(0, seconds)
        time = t
        ended = false
        run("player.seekTo(\(t), true)")
    }

    func skip(_ delta: Double) { seek(to: time + delta) }
    func setRate(_ rate: Float) { run("player.setPlaybackRate(\(rate))") }

    /// Stops the video and lets the page go.
    func stop() {
        run("player.pauseVideo()")
        isPlaying = false
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "yt")
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
    }

    private func run(_ js: String) {
        guard isReady else { return }
        webView.evaluateJavaScript("if (window.player && player.getPlayerState) { \(js) }", completionHandler: nil)
    }

    private func handle(_ body: Any) {
        guard let msg = body as? [String: Any], let event = msg["event"] as? String else { return }
        if let t = msg["time"] as? Double, t.isFinite { time = t }
        switch event {
        case "ready":
            isReady = true
        case "state", "time":
            // -1 unstarted, 0 ended, 1 playing, 2 paused, 3 buffering, 5 cued
            if let s = msg["state"] as? Int {
                if s == 1 || s == 3 { isPlaying = true } else if s == 0 || s == 2 { isPlaying = false }
                if s == 1 { hasStarted = true; ended = false } else if s == 0 { ended = true }
            }
        case "error":
            failed = true
            isPlaying = false
        default: break
        }
    }

    private static func page(videoID: String, start: Double, rate: Float, origin: String) -> String {
        """
        <!doctype html><html><head>
        <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
        <style>
        html,body{margin:0;height:100%;background:#000;overflow:hidden}
        /* Taller than the view: the video stays full width in the middle, while YouTube's title bar (top) and
           logo (bottom) fall outside what's shown. Nothing in it takes touches. */
        #player{position:absolute;left:0;width:100%;top:-120px;height:calc(100% + 240px);pointer-events:none}
        </style>
        </head><body><div id="player"></div>
        <script>
        function post(m){try{window.webkit.messageHandlers.yt.postMessage(m)}catch(e){}}
        var player;
        function onYouTubeIframeAPIReady(){
          player=new YT.Player('player',{
            videoId:'\(videoID)',
            playerVars:{playsinline:1,autoplay:1,start:\(Int(start)),controls:0,disablekb:1,fs:0,rel:0,
                        iv_load_policy:3,cc_load_policy:0,modestbranding:1,origin:'\(origin)'},
            events:{
              onReady:function(e){e.target.setPlaybackRate(\(rate));e.target.seekTo(\(start),true);e.target.playVideo();post({event:'ready',time:e.target.getCurrentTime()})},
              onStateChange:function(e){post({event:'state',state:e.data,time:player.getCurrentTime()})},
              onError:function(e){post({event:'error',code:e.data})}
            }});
          setInterval(function(){if(player&&player.getCurrentTime){post({event:'time',time:player.getCurrentTime(),state:player.getPlayerState()})}},500);
        }
        </script>
        <script src="https://www.youtube.com/iframe_api" onerror="post({event:'error',code:-1})"></script>
        </body></html>
        """
    }

    /// WebKit keeps its message handlers alive; this keeps it from keeping the video alive too.
    private final class MessageProxy: NSObject, WKScriptMessageHandler {
        var receive: ((Any) -> Void)?
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            receive?(message.body)
        }
    }
}

/// The embedded player's page.
struct YouTubeVideoView: UIViewRepresentable {
    let video: YouTubeVideo
    func makeUIView(context: Context) -> WKWebView { video.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
