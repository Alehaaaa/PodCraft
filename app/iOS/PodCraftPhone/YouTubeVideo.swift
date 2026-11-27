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
    /// The video floats in Picture in Picture, and so keeps playing (and leads) while PodCraft is in the background.
    private(set) var isInPictureInPicture = false
    /// Picture in Picture can be asked for: the player's frame inside the page has loaded.
    var canPictureInPicture: Bool { playerFrame != nil && isReady && !failed }

    /// The frame inside the page that holds YouTube's player (and its <video>).
    @ObservationIgnored private var playerFrame: WKFrameInfo?

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
        config.userContentController.addUserScript(WKUserScript(source: Self.playerFrameScript, injectionTime: .atDocumentStart,
                                                                forMainFrameOnly: false))
        webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        // Only the picture: no YouTube controls, menus or links to tap.
        webView.isUserInteractionEnabled = false
        messages.receive = { [weak self] message in self?.handle(message) }
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
        stopPictureInPicture()
        run("player.pauseVideo()")
        isPlaying = false
        isInPictureInPicture = false
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "yt")
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
    }

    private func run(_ js: String) {
        guard isReady else { return }
        webView.evaluateJavaScript("if (window.player && player.getPlayerState) { \(js) }", completionHandler: nil)
    }

    // MARK: Picture in Picture

    /// Floats the video. Called from a tap on PodCraft's button: iOS starts Picture in Picture only for a person's
    /// action, and a script run by the app at that moment counts as one.
    func startPictureInPicture() {
        guard let playerFrame, canPictureInPicture else { return }
        webView.evaluateJavaScript(Self.presentation("picture-in-picture"), in: playerFrame, in: .page) { _ in }
    }

    func stopPictureInPicture() {
        guard let playerFrame, isInPictureInPicture else { return }
        webView.evaluateJavaScript(Self.presentation("inline"), in: playerFrame, in: .page) { _ in }
    }

    private static func presentation(_ mode: String) -> String {
        """
        (function(){var v=document.querySelector('video');if(!v)return false;
        if(v.webkitSupportsPresentationMode&&v.webkitSupportsPresentationMode('\(mode)')){v.webkitSetPresentationMode('\(mode)');return true}
        if('\(mode)'==='picture-in-picture'&&v.requestPictureInPicture){v.requestPictureInPicture().catch(function(){});return true}
        if(document.pictureInPictureElement&&document.exitPictureInPicture){document.exitPictureInPicture().catch(function(){});return true}
        return false})()
        """
    }

    private func handle(_ message: WKScriptMessage) {
        guard let msg = message.body as? [String: Any], let event = msg["event"] as? String else { return }
        if event == "frame" {
            if !message.frameInfo.isMainFrame { playerFrame = message.frameInfo }
            return
        }
        if event == "pip" {
            isInPictureInPicture = (msg["on"] as? Bool) ?? false
            return
        }
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

    /// Runs inside YouTube's own player frame (the page above can't reach into it). It hides everything YouTube draws
    /// over the picture, including the big play button and the play/pause flash in the middle, and WebKit's own
    /// start-playback button, so only the video shows. It also says when the video enters or leaves Picture in Picture.
    private static let playerFrameScript = """
    (function(){
      var h=location.hostname;
      if(window.top===window||!(h.endsWith('youtube.com')||h.endsWith('youtube-nocookie.com')))return;
      function post(m){try{window.webkit.messageHandlers.yt.postMessage(m)}catch(e){}}
      var css=document.createElement('style');
      css.textContent=[
        '.ytp-large-play-button','.ytp-bezel','.ytp-bezel-text-wrapper','.ytp-pause-overlay','.ytp-spinner',
        '.ytp-chrome-top','.ytp-chrome-bottom','.ytp-gradient-top','.ytp-gradient-bottom','.ytp-watermark',
        '.ytp-youtube-button','.ytp-title','.ytp-show-cards-title','.ytp-impression-link','.ytp-cued-thumbnail-overlay',
        '.ytp-ce-element','.ytp-endscreen-content','.ytp-autonav-endscreen','.ytp-paid-content-overlay',
        '.ytp-cards-teaser','.ytp-iv-player-content','.ytp-tooltip','.ytp-contextmenu','.ytp-popup',
        '.iv-branding','.annotation','.branding-img',
        'video::-webkit-media-controls','video::-webkit-media-controls-start-playback-button',
        'video::-webkit-media-controls-overlay-play-button','video::-webkit-media-controls-panel'
      ].join(',')+'{display:none!important;opacity:0!important;pointer-events:none!important}';
      (document.head||document.documentElement).appendChild(css);
      function mode(e){var v=e.target;
        post({event:'pip',on:(v.webkitPresentationMode==='picture-in-picture')||document.pictureInPictureElement===v})}
      document.addEventListener('webkitpresentationmodechanged',mode,true);
      document.addEventListener('enterpictureinpicture',mode,true);
      document.addEventListener('leavepictureinpicture',mode,true);
      post({event:'frame'});
    })();
    """

    /// WebKit keeps its message handlers alive; this keeps it from keeping the video alive too.
    private final class MessageProxy: NSObject, WKScriptMessageHandler {
        var receive: ((WKScriptMessage) -> Void)?
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            receive?(message)
        }
    }
}

/// The embedded player's page.
struct YouTubeVideoView: UIViewRepresentable {
    let video: YouTubeVideo
    func makeUIView(context: Context) -> WKWebView { video.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
