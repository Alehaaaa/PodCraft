import AppKit
import SwiftUI
import AVFoundation
import AVKit
import MediaPlayer

// PodCraft — a native macOS podcast library with two modes:
// Manage (build feeds, add shows, edit episodes and chapters) and Listen (just enjoy them).

let arguments = CommandLine.arguments
var screenshotPath: String? = nil
if let i = arguments.firstIndex(of: "--screenshot"), i + 1 < arguments.count {
    screenshotPath = arguments[i + 1]
}

/// The single source of truth for player keyboard bindings. Both the native
/// Controls menu and the window-level event router read these values.
private enum PlaybackShortcut: CaseIterable {
    case playPause, back, forward, previousChapter, nextChapter
    case previousEpisode, nextEpisode
    case cinema, transcript, queue, mute, fullScreen
    case slower, faster, normalSpeed

    var key: String {
        switch self {
        case .playPause: " "
        case .back, .previousChapter, .previousEpisode: String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        case .forward, .nextChapter, .nextEpisode: String(UnicodeScalar(NSRightArrowFunctionKey)!)
        case .cinema: "t"
        case .transcript: "c"
        case .queue: "q"
        case .mute: "m"
        case .fullScreen: "f"
        case .slower: "["
        case .faster: "]"
        case .normalSpeed: "0"
        }
    }

    var modifiers: NSEvent.ModifierFlags {
        switch self {
        case .previousChapter, .nextChapter: .command
        case .previousEpisode, .nextEpisode: [.command, .shift]
        default: []
        }
    }

    func matches(_ event: NSEvent) -> Bool {
        let relevant = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard relevant == modifiers else { return false }
        switch self {
        case .playPause: return event.keyCode == 49
        case .back, .previousChapter, .previousEpisode: return event.keyCode == 123
        case .forward, .nextChapter, .nextEpisode: return event.keyCode == 124
        default: return event.charactersIgnoringModifiers?.lowercased() == key
        }
    }
}

/// Keep the library from receiving events through noninteractive areas of the Cinema SwiftUI view.
/// The hosted controls remain the first hit-test target; empty areas land here and are consumed.
private final class CinemaClickShieldView: NSView {
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func rightMouseUp(with event: NSEvent) {}
    override func rightMouseDragged(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) {}
    override func otherMouseUp(with event: NSEvent) {}
    override func otherMouseDragged(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
}

/// Keep native menu key equivalents visible while preserving ordinary text
/// editing. The local playback monitor deliberately passes these keys through
/// when a text field is focused; the Controls menu must do the same.
private final class PlaybackControlsMenu: NSMenu {
    var isEditingText: (() -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if isEditingText?() == true {
            let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
            if event.keyCode == 49 && modifiers.isEmpty {
                return false
            } else if event.keyCode == 123 || event.keyCode == 124 {
                if modifiers.isEmpty || modifiers == .command || modifiers == [.command, .shift] {
                    return false
                }
            } else if modifiers.isEmpty,
                      ["t", "c", "q", "m", "f"].contains(event.charactersIgnoringModifiers?.lowercased() ?? "") {
                return false
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let screenshotPath: String?
    let library: Library
    let player: Player
    var window: NSWindow!

    var processor: Processor!
    var server: FeedServer!
    var mainToolbar: MainToolbar?
    private var syncTimer: Timer?
    private var keyboardMonitor: Any?
    private var isShuttingDown = false

    /// The split view between the sidebar and the main area (the outermost one SwiftUI made), so the toolbar's
    /// separator follows the sidebar's edge.
    func findSidebarSplit() -> NSSplitView? {
        var queue: [NSView] = window.contentView.map { [$0] } ?? []
        while !queue.isEmpty {
            let v = queue.removeFirst()
            if let split = v as? NSSplitView, split.isVertical, split.arrangedSubviews.count >= 2 {
                CrashLog.note("sidebar split: \(type(of: split)) delegate=\(split.delegate.map { String(describing: type(of: $0)) } ?? "none")")
                if ProcessInfo.processInfo.environment["PODCRAFT_LAYOUT_TEST"] != nil {
                    print("SPLIT \(type(of: split)) subviews=\(split.arrangedSubviews.count) delegate=\(split.delegate.map { String(describing: type(of: $0)) } ?? "none")")
                }
                return split
            }
            queue += v.subviews
        }
        return nil
    }

    init(screenshotPath: String?) {
        self.screenshotPath = screenshotPath
        // PODCRAFT_LAYOUT_TEST=1: a check of the real (native) layout while switching modes.
        Snapshot.active = BroskiTestFixture.current == nil && screenshotPath != nil &&
            ProcessInfo.processInfo.environment["PODCRAFT_LAYOUT_TEST"] == nil
        if let fixture = BroskiTestFixture.current {
            self.library = Library(screenshot: false, isolatedStorageURL: fixture.storage,
                                   isolatedPreferences: fixture.preferences)
            fixture.configure(self.library)
        } else {
            self.library = Library(screenshot: screenshotPath != nil)
        }
        self.player = Player(library: library,
                             suppressUserSessionWrites: BroskiTestFixture.current != nil)
        // Automated screenshots stay silent. Interactive isolated Broski QA can
        // audition the actual media without changing the user's playback session.
        self.player.testMute = screenshotPath != nil
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Diagnostic log (~/Library/Logs/PodCraft/PodCraft.log). Test runs only log when PODCRAFT_LOG=1.
        CrashLog.enabled = screenshotPath == nil || ProcessInfo.processInfo.environment["PODCRAFT_LOG"] == "1"
        CrashLog.start()
        buildMenu()
        processor = Processor(library: library, mediaDirectory: BroskiTestFixture.current?.media)
        server = FeedServer(library: library)
        library.processor = processor
        library.server = server
        server.macPlayingEpisode = { [weak self] in self?.player.isPlaying == true ? self?.player.episodeID : nil }
        if screenshotPath != nil, ProcessInfo.processInfo.environment["PODCRAFT_TEST_SERVER"] == "1" {
            server.start()   // lets a check ask the feed server for a listing during a screenshot run
        }
        if ProcessInfo.processInfo.environment["PODCRAFT_TAILSCALE_TEST"] != nil {
            // Prints what was found, waits for the name lookup, then quits.
            TailscaleInfo.shared.refresh()
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                let t = TailscaleInfo.shared
                print("TAILSCALE address=\(t.address ?? "none") name=\(t.dnsName ?? "none") link=\(self?.server.baseURL() ?? "")")
                fflush(stdout); exit(0)
            }
        }
        if screenshotPath == nil && BroskiTestFixture.current == nil {
            server.start()
            // Find this Mac's Tailscale address so feed links work from your other devices anywhere.
            TailscaleInfo.shared.start()
            library.onEpisodePlaybackPrepared = { [weak self] id in
                self?.player.episodePlaybackPrepared(id)
            }
            library.onEpisodeReady = { [weak self] id in
                guard let self else { return }
                self.player.episodePlaybackPrepared(id)
                guard !self.library.settings.uploadURL.isEmpty else { return }
                Task { @MainActor in _ = await self.server.publishAll() }
            }
            watchSettings()
            library.checkForNewEpisodes(notify: false)
            // Previously only the newest five entries of a saved show were
            // checked for YouTube. Index the existing catalogs in the
            // background on a normal launch, one show at a time; this is
            // deliberately excluded from isolated screenshot/test runs.
            library.startCatalogMatchingForSavedShows()
            // Small cover copies for the sidebar and lists, prepared up front so rows never flash.
            ArtworkStore.warmThumbnails(for: library.shows)
            // Put the last episode back in the player bar, paused where it was (also after a crash).
            player.restoreLastSession()
            // Warm the New page in the background so it opens with its shows already there.
            Task { @MainActor in await DiscoveryStore.shared.load() }
            // Check for new episodes every 30 minutes (autoSyncIntervalMinutes in the original).
            syncTimer = Timer.scheduledTimer(withTimeInterval: Mechanics.checkIntervalMinutes * 60, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, !self.isShuttingDown else { return }
                    self.library.checkForNewEpisodes(notify: false)
                }
            }
        }
        let root = RootView()
            .environment(library)
            .environment(player)
            .tint(Color.podTeal)
        let hosting = NSHostingController(rootView: root)
        // Titles come from the views; the toolbar is AppKit's own (MainToolbar), never rebuilt by SwiftUI.
        hosting.sceneBridgingOptions = [.title]
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 800),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        // Match RootView's intrinsic minimum. AppKit otherwise accepts programmatic
        // frames smaller than the split view can satisfy, triggering repeated constraint
        // invalidation when a sidebar and inspector are simultaneously visible.
        window.contentMinSize = NSSize(width: 980, height: 640)
        window.contentViewController = hosting
        window.title = "PodCraft"
        window.toolbarStyle = .unified
        window.layoutIfNeeded()
        mainToolbar = MainToolbar(library: library, splitView: findSidebarSplit(), window: window)
        window.toolbar = mainToolbar?.toolbar
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 1240, height: 800))
        window.center()
        watchCinema()
        watchStateForLog()
        installKeyboardMonitor()

        if let fixture = BroskiTestFixture.current {
            if screenshotPath != nil {
                window.orderFrontRegardless()
            } else {
                window.makeKeyAndOrderFront(nil)
                NSApp.activate()
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                await fixture.populate(library: self.library, processor: self.processor,
                                       player: self.player, screenshotPath: screenshotPath) { [weak self] in
                    guard let self, let path = self.screenshotPath else { return }
                    self.capture(to: path)
                }
            }
        } else if let path = screenshotPath {
            // Show a playing episode so the picture includes the player.
            if let e = library.continueListening.first { player.play(e.id) }
            if ProcessInfo.processInfo.environment["PODCRAFT_MODE"] == "listen" { library.mode = .listen }
            if ProcessInfo.processInfo.environment["PODCRAFT_DOWNLOADS_PREVIEW"] == "1" {
                // Read-only visual acceptance for the two-part Downloads page.
                // Screenshot libraries never open the user's real Library.json.
                library.setMode(.manage)
                library.manageSelection = .downloads
            }
            window.orderFrontRegardless()          // visible, but never takes focus
            if ProcessInfo.processInfo.environment["PODCRAFT_KEYBOARD_TEST"] != nil {
                runKeyboardSmokeTest()
            } else if ProcessInfo.processInfo.environment["PODCRAFT_NATIVE_UI_TEST"] != nil {
                runNativeUISmokeTest()
            } else if let audio = ProcessInfo.processInfo.environment["PODCRAFT_CRASH_TEST"] {
                runModeSwitchStressTest(audio: audio)
            } else if let discoveryTest = ProcessInfo.processInfo.environment["PODCRAFT_DISCOVERY_TEST"] {
                // Native smoke check for the New page and the detail-route lifecycle.
                library.setMode(.listen)
                library.listenSelection = .new
                if discoveryTest == "preview" {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                        let selected = DiscoveryStore.shared.shows.first ?? FeedFetcher.SearchResult(
                            title: "Discovery Preview", author: "PodCraft", feedURL: "https://example.invalid/podcast.xml")
                        DiscoveryRoute.shared.preview = selected
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            let ok = self?.library.listenSelection == .new &&
                                DiscoveryRoute.shared.preview?.id == selected.id
                            print("DISCOVERY NAV \(ok ? "PASSED" : "FAILED")")
                            fflush(stdout)
                            guard ok else { exit(3) }
                            self?.capture(to: path)
                        }
                    }
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.capture(to: path) }
                }
            } else if ProcessInfo.processInfo.environment["PODCRAFT_LAYOUT_TEST"] != nil {
                library.setMode(.listen)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.library.setMode(.manage) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.library.setMode(.listen) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) { [weak self] in self?.library.setMode(.manage) }
                for t in [1.0, 2.0, 3.5, 6.0] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in self?.reportLayout() }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 6.5) { exit(0) }
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.capture(to: path) }
            }
        } else {
            window.setFrameAutosaveName("PodCraftMainWindow")
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
        }
    }

    /// Restart the feed server when hosting settings change; redraw artwork when feeds change.
    /// The cinema player covers the whole window like the Podcasts app: the title bar's toolbar is hidden and the
    /// bar turns transparent, leaving only the window buttons (the cinema view draws its close button beside them).
    /// Done on the window itself: hiding the toolbar doesn't add or remove its items, so it can't loop the layout.
    private var cinemaOverlay: CinemaClickShieldView?
    private var cinemaHost: NSView?
    private var cinemaOverlayClosing = false
    private var cinemaTransitionID = 0
    private var cinemaAccessories: [NSTitlebarAccessoryViewController] = []
    private var toolbarWatch: NSKeyValueObservation?
    private var libraryToolbar: NSToolbar?
    private var cinemaToolbar: NSToolbar?
    private var cinemaRequested: Bool { player.cinemaMode && player.episode != nil }

    // MARK: Native playback keyboard shortcuts

    /// A local AppKit monitor runs before ordinary key delivery, but never handles events
    /// destined for a text editor or a different window. No global event tap is installed.
    private func installKeyboardMonitor() {
        guard keyboardMonitor == nil else { return }
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handlePlaybackKey(event) ?? event
        }
    }

    private func isEditingText(in window: NSWindow) -> Bool {
        guard let responder = window.firstResponder else { return false }
        if responder is NSTextView || responder is NSTextField || responder is NSSearchField { return true }
        var ancestor = responder as? NSView
        while let view = ancestor {
            if view is NSTextView || view is NSTextField || view is NSSearchField { return true }
            ancestor = view.superview
        }
        return false
    }

    /// Returns nil only for an exact supported shortcut that actually belongs to the player.
    /// Cmd+C, Cmd+M, Ctrl+Cmd+F, Option-arrows, text selection, etc. continue to AppKit.
    private func handlePlaybackKey(_ event: NSEvent, requireKeyWindow: Bool = true) -> NSEvent? {
        guard !isShuttingDown, event.type == .keyDown, let window,
              event.window === window || (!requireKeyWindow && event.windowNumber == window.windowNumber),
              !requireKeyWindow || window.isKeyWindow,
              !isEditingText(in: window) else { return event }

        guard let shortcut = PlaybackShortcut.allCases.first(where: { $0.matches(event) }) else { return event }
        if !event.isARepeat { perform(shortcut) }
        return nil
    }

    private func perform(_ shortcut: PlaybackShortcut) {
        switch shortcut {
        case .playPause: player.togglePlay()
        case .back: player.skipBack()
        case .forward: player.skipForward()
        case .previousChapter: player.previousChapter()
        case .nextChapter: player.nextChapter()
        case .previousEpisode: player.previousQueuedEpisode()
        case .nextEpisode: player.nextQueuedEpisode()
        case .cinema: toggleCinemaMode()
        case .transcript: toggleTranscript()
        case .queue: player.toggleQueuePanel()
        case .mute: player.toggleMute()
        case .fullScreen: window?.toggleFullScreen(nil)
        case .slower: player.slower()
        case .faster: player.faster()
        case .normalSpeed: player.setRate(1)
        }
    }

    /// Opt-in native keyboard regression check, using real NSEvents without an event tap.
    /// PODCRAFT_KEYBOARD_TEST=.build/podcraft-transcript-test.wav PODCRAFT_LAYOUT_TEST=1
    ///     PodCraft --screenshot /tmp/podcraft-keyboard.png
    private func runKeyboardSmokeTest() {
        Task { @MainActor [weak self] in
            guard let self, let audio = ProcessInfo.processInfo.environment["PODCRAFT_KEYBOARD_TEST"],
                  FileManager.default.fileExists(atPath: audio) else { exit(2) }
            func check(_ ok: Bool, _ name: String) {
                guard ok else {
                    print("KEYBOARD FAILED: \(name)")
                    fflush(stdout)
                    exit(3)
                }
            }
            @MainActor func key(_ characters: String, code: UInt16,
                                mods: NSEvent.ModifierFlags = []) -> Bool {
                guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
                                                    modifierFlags: mods, timestamp: 0,
                                                    windowNumber: self.window.windowNumber, context: nil,
                                                    characters: characters,
                                                    charactersIgnoringModifiers: characters,
                                                    isARepeat: false, keyCode: code) else { return false }
                return self.handlePlaybackKey(event, requireKeyWindow: false) == nil
            }

            let savedQueue = self.player.queue
            let show = Show(title: "Keyboard Test", author: "PodCraft", hue: 0.4)
            self.library.shows.append(show)
            func makeEpisode(_ title: String) -> Episode {
                var episode = Episode(showID: show.id, title: title,
                                      published: Date(), addedAt: Date(), duration: 90)
                episode.localFile = URL(fileURLWithPath: audio).path
                episode.stage = .ready
                episode.chapters = [Chapter(start: 0, title: "Opening"),
                                    Chapter(start: 30, title: "Middle"),
                                    Chapter(start: 70, title: "End")]
                return episode
            }
            let first = makeEpisode("First")
            let second = makeEpisode("Second")
            let third = makeEpisode("Third")
            self.library.episodes += [first, second, third]
            self.player.load(first.id, autoplay: false, at: 60)
            self.player.queue = [second.id, third.id]

            let left = String(UnicodeScalar(NSLeftArrowFunctionKey)!)
            let right = String(UnicodeScalar(NSRightArrowFunctionKey)!)
            guard let controls = NSApp.mainMenu?.item(withTitle: "Controls")?.submenu else {
                check(false, "native Controls menu exists")
                return
            }
            func checkNativeShortcut(_ name: String, key: String, mods: NSEvent.ModifierFlags) {
                guard let item = controls.item(withTitle: name) else {
                    check(false, "native shortcut menu item \(name) exists")
                    return
                }
                let actualMods = item.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control])
                check(item.title == name && item.keyEquivalent == key && actualMods == mods,
                      "native menu equivalent for \(name)")
            }
            checkNativeShortcut("Back \(Int(Mechanics.skipBackSeconds)) Seconds", key: left, mods: [])
            checkNativeShortcut("Forward \(Int(Mechanics.skipForwardSeconds)) Seconds", key: right, mods: [])
            checkNativeShortcut("Previous Chapter", key: left, mods: [.command])
            checkNativeShortcut("Next Chapter", key: right, mods: [.command])
            checkNativeShortcut("Previous Episode", key: left, mods: [.command, .shift])
            checkNativeShortcut("Next Queued Episode", key: right, mods: [.command, .shift])
            for (name, key) in [("Cinema Mode", "t"), ("Transcript", "c"), ("Queue", "q"),
                                ("Mute / Unmute", "m"), ("Full Screen", "f")] {
                checkNativeShortcut(name, key: key, mods: [])
            }
            print("NATIVE MENU SHORTCUTS PASSED")
            check(key(left, code: 123), "bare Left was handled")
            check(abs(self.player.position - (60 - Mechanics.skipBackSeconds)) < 0.01,
                  "bare Left uses configured back seconds")
            check(key(right, code: 124), "bare Right was handled")
            check(abs(self.player.position - (60 - Mechanics.skipBackSeconds + Mechanics.skipForwardSeconds)) < 0.01,
                  "bare Right uses configured forward seconds")

            self.player.seek(to: 60)
            check(key(left, code: 123, mods: [.command]) && self.player.position == 30,
                  "Cmd+Left is previous chapter")
            check(key(right, code: 124, mods: [.command]) && self.player.position == 70,
                  "Cmd+Right is next chapter")
            check(!key(left, code: 123, mods: [.option]), "Option+Left is not intercepted")
            check(!key("c", code: 8, mods: [.command]), "Cmd+C remains normal Copy")
            check(!key("f", code: 3, mods: [.command, .control]), "Ctrl+Cmd+F stays native")

            let initiallyPlaying = self.player.isPlaying
            check(key(" ", code: 49), "Space toggles playback")
            check(self.player.isPlaying != initiallyPlaying, "Space changed playback state")
            check(key(" ", code: 49), "Second Space toggles playback back")
            check(self.player.isPlaying == initiallyPlaying, "Space restores playback state")

            check(key(right, code: 124, mods: [.command, .shift]) && self.player.episodeID == second.id,
                  "Cmd+Shift+Right advances into first queued episode")
            check(!self.player.queue.contains(second.id), "playing queued episode is dequeued")
            check(key(right, code: 124, mods: [.command, .shift]) && self.player.episodeID == third.id,
                  "Cmd+Shift+Right advances into second queued episode")
            check(key(left, code: 123, mods: [.command, .shift]) && self.player.episodeID == second.id,
                  "Cmd+Shift+Left returns to consumed queue episode")
            check(key(left, code: 123, mods: [.command, .shift]) && self.player.episodeID == first.id,
                  "Cmd+Shift+Left returns to episode before queue")
            check(key(right, code: 124, mods: [.command, .shift]) && self.player.episodeID == second.id,
                  "Cmd+Shift+Right replays forward history")

            check(key("t", code: 17) && self.player.cinemaMode, "T enters Cinema")
            check(key("t", code: 17) && !self.player.cinemaMode, "T exits Cinema")
            check(key("c", code: 8) && self.player.showChapters, "C opens transcript")
            check(key("q", code: 12) && self.player.showQueue && !self.player.showChapters,
                  "Q opens queue and closes transcript")
            check(key("q", code: 12) && !self.player.showQueue, "Q closes queue")
            self.player.volume = 0.37
            check(key("m", code: 46) && self.player.volume == 0, "M mutes")
            check(key("m", code: 46) && abs(self.player.volume - 0.37) < 0.0001,
                  "M restores original volume")

            let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 40))
            self.window.contentView?.addSubview(editor)
            check(self.window.makeFirstResponder(editor), "text editor receives focus")
            check(!key("c", code: 8) && !key(left, code: 123, mods: [.command]),
                  "text editor keeps bare and Command navigation keys")
            check(!key(" ", code: 49), "text editor keeps Space for typing")
            editor.removeFromSuperview()
            self.window.makeFirstResponder(nil)

            let search = NSSearchField(frame: NSRect(x: 0, y: 0, width: 180, height: 26))
            self.window.contentView?.addSubview(search)
            check(self.window.makeFirstResponder(search), "search field receives focus")
            check(!key("q", code: 12) && !key(right, code: 124, mods: [.command]),
                  "search field keeps bare and Command navigation keys")
            check(!key(" ", code: 49), "search field keeps Space for typing")
            self.window.makeFirstResponder(nil)
            search.removeFromSuperview()

            // Full screen is tested last because AppKit performs its transition asynchronously.
            check(key("f", code: 3), "F is handled by fullscreen toggle")
            self.player.queue = savedQueue
            print("KEYBOARD PASSED: space, arrows, chapters, history, modes, mute, text focus, fullscreen")
            fflush(stdout)
            exit(0)
        }
    }

    /// AppKit retains toolbar and window delegates independently of the SwiftUI view hierarchy.
    /// Tear down their callbacks explicitly, including when a window closes before application exit.
    private func stopNativeObservers() {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        if let keyboardMonitor { NSEvent.removeMonitor(keyboardMonitor) }
        keyboardMonitor = nil
        syncTimer?.invalidate()
        syncTimer = nil
        toolbarWatch?.invalidate()
        toolbarWatch = nil
        mainToolbar?.stopObserving()
        window?.delegate = nil
    }

    /// Animation completions may run outside the main actor. Inspect and remove the overlay
    /// only after hopping back to AppKit's actor, and only for the current transition.
    private func finishCinemaClose(transition: Int) {
        guard let overlay = cinemaOverlay, cinemaOverlayClosing,
              cinemaTransitionID == transition,
              !cinemaRequested else { return }
        cinemaOverlay = nil
        cinemaHost = nil
        cinemaOverlayClosing = false
        overlay.removeFromSuperview()
    }

    /// Close (beside the window buttons) and AirPlay + volume (right) as native title-bar accessories: macOS puts
    /// them on the title bar's line and they always get clicks. Adding them never touches the toolbar's items.
    private func setCinemaAccessories(_ on: Bool) {
        guard let w = window else { return }
        if on, cinemaAccessories.isEmpty {
            func accessory<V: View>(_ view: V, width: CGFloat, side: NSLayoutConstraint.Attribute) -> NSTitlebarAccessoryViewController {
                let host = NSHostingView(rootView: view.environment(library).environment(player).tint(Color.podTeal))
                // The full title-bar height (with a toolbar it's 52 pt), so the controls keep their size.
                host.frame = NSRect(x: 0, y: 0, width: width, height: 52)
                let vc = NSTitlebarAccessoryViewController()
                vc.view = host
                vc.layoutAttribute = side
                return vc
            }
            cinemaAccessories = [accessory(CinemaCloseButton().padding(.leading, 10), width: 96, side: .leading),
                                 accessory(CinemaAudioControls().padding(.trailing, 12), width: 300, side: .trailing)]
            cinemaAccessories.forEach { w.addTitlebarAccessoryViewController($0) }
        } else if !on, !cinemaAccessories.isEmpty {
            for vc in cinemaAccessories {
                if let i = w.titlebarAccessoryViewControllers.firstIndex(of: vc) { w.removeTitlebarAccessoryViewController(at: i) }
            }
            cinemaAccessories = []
        }
    }

    func watchCinema() {
        guard !isShuttingDown else { return }
        let cinema = cinemaRequested
        if let w = window {
            // While the cinema is open the window gets an empty toolbar of its own: the title bar keeps its full
            // height (the window buttons sit where they always do) but shows none of the library's items, so no
            // empty pill. The library's toolbar is put back, untouched, when the cinema closes; its items are never
            // added or removed, which is what used to stop the app.
            if cinema, cinemaToolbar == nil {
                libraryToolbar = w.toolbar
                let empty = NSToolbar(identifier: "PodCraftCinemaToolbar")
                empty.displayMode = .iconOnly
                empty.allowsUserCustomization = false
                cinemaToolbar = empty
                w.toolbar = empty
                CrashLog.note("cinema: swapped in empty toolbar")
            } else if !cinema, let saved = libraryToolbar {
                toolbarWatch?.invalidate()
                toolbarWatch = nil
                w.toolbar = saved
                libraryToolbar = nil
                cinemaToolbar = nil
                CrashLog.note("cinema: restored library toolbar")
            }
            w.titlebarAppearsTransparent = cinema
            w.titleVisibility = cinema || mainToolbar?.hasInlineBackTitle == true ? .hidden : .visible
            setCinemaAccessories(cinema)
            // If SwiftUI puts its own toolbar back during the cinema, swap the empty one in again.
            if cinema && toolbarWatch == nil {
                toolbarWatch = w.observe(\.toolbar, options: [.new]) { [weak self] _, _ in
                    // KVO is permitted on any thread. Read all AppKit state on the main actor,
                    // after the toolbar setter completes, avoiding recursive KVO re-entry.
                    Task { @MainActor [weak self] in
                        guard let self, !self.isShuttingDown, self.cinemaRequested,
                              let win = self.window,
                              let empty = self.cinemaToolbar, win.toolbar !== empty else { return }
                        self.libraryToolbar = win.toolbar
                        win.toolbar = empty
                        CrashLog.note("cinema: SwiftUI reinstalled its toolbar; empty one swapped back in")
                    }
                }
            }
            // The SwiftUI hosting view can ignore pointer hits in blank areas, exposing the library beneath it.
            // An AppKit shield below the hosted Cinema view catches those hits across the whole content rect.
            // Keep the shield fully hit-testable while fading just the visible hosting view in and out.
            if cinema {
                if cinemaOverlay != nil {
                    if cinemaOverlayClosing {
                        cinemaOverlayClosing = false
                        cinemaTransitionID += 1
                        if let host = cinemaHost {
                            NSAnimationContext.runAnimationGroup { ctx in
                                ctx.duration = 0.22
                                host.animator().alphaValue = 1
                            }
                        }
                    }
                    // The same shield survives a quick close/reopen; no second overlay can intercept clicks.
                } else if let content = w.contentView, let frameView = content.superview {
                    let shield = CinemaClickShieldView(frame: content.frame)
                    shield.autoresizingMask = [.width, .height]
                    let host = NSHostingView(rootView: CinemaPlayerView()
                        .environment(library).environment(player).tint(Color.podTeal))
                    host.frame = shield.bounds
                    host.autoresizingMask = [.width, .height]
                    host.alphaValue = 0
                    shield.addSubview(host)
                    // Above library content and below the native title bar and Cinema accessories.
                    frameView.addSubview(shield, positioned: .above, relativeTo: content)
                    cinemaOverlay = shield
                    cinemaHost = host
                    NSAnimationContext.runAnimationGroup { ctx in
                        ctx.duration = 0.22
                        host.animator().alphaValue = 1
                    }
                }
            } else if cinemaOverlay != nil, !cinemaOverlayClosing {
                cinemaOverlayClosing = true
                cinemaTransitionID += 1
                let transition = cinemaTransitionID
                let host = cinemaHost
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.18
                    host?.animator().alphaValue = 0
                }, completionHandler: { [weak self] in
                    Task { @MainActor [weak self] in self?.finishCinemaClose(transition: transition) }
                })
                // Some inactive/hidden AppKit windows never deliver an animation completion.
                // Always finish a matching close after the fade's deadline; reopens invalidate it.
                // Schedule directly on AppKit's main dispatch queue: under
                // SwiftUI layout stress an actor-suspended Task can resume
                // later than the next UI assertion, leaving an invisible shield.
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(400)) { [weak self] in
                    MainActor.assumeIsolated { self?.finishCinemaClose(transition: transition) }
                }
            }
        }
        withObservationTracking {
            _ = player.cinemaMode
            _ = player.episodeID
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.watchCinema() }
        }
    }

    func watchSettings() {
        guard !isShuttingDown else { return }
        withObservationTracking {
            _ = library.settings.hostingEnabled
            _ = library.settings.hostPort
            _ = library.feeds
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.isShuttingDown else { return }
                self.server.invalidateArtwork()
                self.server.start()
                self.watchSettings()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func windowWillClose(_ notification: Notification) { stopNativeObservers() }

    func applicationWillTerminate(_ notification: Notification) {
        stopNativeObservers()
        server?.stop()
        processor?.shutdown()
        player.shutdown()
        library.save()
        CrashLog.cleanExit()
    }

    // MARK: Diagnostic log of what the window is doing

    private var stateLine: String {
        let size = window.map { "\(Int($0.frame.width))x\(Int($0.frame.height))" } ?? "-"
        return "size=\(size) mode=\(library.mode.rawValue) cinema=\(player.cinemaMode) queue=\(player.showQueue) transcript=\(player.showChapters) playing=\(player.episode != nil)"
    }

    /// Notes every mode, cinema and side-panel change with the window's size, so the log shows what came last.
    func watchStateForLog() {
        guard CrashLog.enabled, !isShuttingDown else { return }
        withObservationTracking {
            _ = library.mode
            _ = player.cinemaMode
            _ = player.showQueue
            _ = player.showChapters
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.isShuttingDown else { return }
                CrashLog.note("state: \(self.stateLine)")
                self.watchStateForLog()
            }
        }
    }

    private var lastResizeNote = Date.distantPast
    func windowWillStartLiveResize(_ notification: Notification) { CrashLog.note("resize start: \(stateLine)") }
    func windowDidEndLiveResize(_ notification: Notification) { CrashLog.note("resize end: \(stateLine)") }
    // Test-only diagnostics: never open a trace file or walk the AppKit hierarchy during normal operation.
    private var resizeTrace: FileHandle?
    private var resizeTestStart = Date.distantPast
    private var resizeTestPass = ""
    private var resizeTestStep = -1
    private var resizeRequestedFrame: NSRect?
    private var resizeEventCount = 0
    private var lastResizeTestSample = Date.distantPast

    private func resizeTraceLine(_ label: String, geometry: Bool = true) {
        guard let resizeTrace, let w = window else { return }
        let dt = Date().timeIntervalSince(resizeTestStart)
        var line = String(format: "+%.3fs %@ pass=%@ step=%d events=%d", dt, label,
                          resizeTestPass, resizeTestStep, resizeEventCount)
        if geometry {
            let frame = w.frame
            let content = w.contentRect(forFrameRect: frame)
            let layout = w.contentLayoutRect
            let bounds = w.contentView?.bounds ?? .zero
            let requested = resizeRequestedFrame.map { String(format: "%.0fx%.0f", $0.width, $0.height) } ?? "-"
            let inspector = !player.cinemaMode && (player.showQueue || (player.showChapters && player.episode != nil))
            let toolbar = w.toolbar?.identifier ?? "none"
            line += String(format: " target=%@ frame=%.0fx%.0f content=%.0fx%.0f view=%.0fx%.0f layout=%.0fx%.0f minContent=%.0fx%.0f",
                           requested, frame.width, frame.height, content.width, content.height,
                           bounds.width, bounds.height, layout.width, layout.height,
                           w.contentMinSize.width, w.contentMinSize.height)
            line += " mode=\(library.mode.rawValue) inspector=\(inspector) queue=\(player.showQueue) chapters=\(player.showChapters) cinema=\(player.cinemaMode) toolbar=\(toolbar) items=\(w.toolbar?.items.count ?? 0) accessories=\(w.titlebarAccessoryViewControllers.count)"
            // Report both navigation split and inspector split (and how much room each received).
            var stack: [NSView] = w.contentView.map { [$0] } ?? []
            var splitInfo: [String] = []
            var views = 0
            while let v = stack.popLast(), views < 1500 {
                views += 1
                if let split = v as? NSSplitView {
                    let columns = split.arrangedSubviews.map {
                        String(format: "%.0f%@", split.isVertical ? $0.frame.width : $0.frame.height,
                               $0.isHidden ? "h" : "")
                    }.joined(separator: "/")
                    splitInfo.append(String(format: "%@ x=%.0f w=%.0f [%@] delegate=%@",
                                            String(describing: type(of: split)), split.frame.minX, split.frame.width,
                                            columns, split.delegate.map { String(describing: type(of: $0)) } ?? "none"))
                }
                stack.append(contentsOf: v.subviews)
            }
            line += " views=\(views) splits=\(splitInfo.prefix(6).joined(separator: ";"))"
        }
        try? resizeTrace.write(contentsOf: Data((line + "\n").utf8))
    }

    func windowDidResize(_ notification: Notification) {
        if resizeTrace != nil {
            resizeEventCount += 1
            let width = window.frame.width
            let now = Date()
            // Capture the actual content/frame transition near the failure band without flooding the event loop.
            if (925...1130).contains(width) && now.timeIntervalSince(lastResizeTestSample) >= 0.045 {
                lastResizeTestSample = now
                resizeTraceLine("DID-RESIZE")
            }
        }
        // At most a few lines a second while dragging.
        guard Date().timeIntervalSince(lastResizeNote) > 0.25 else { return }
        lastResizeNote = Date()
        CrashLog.note("resize: \(stateLine)")
    }
    func windowWillEnterFullScreen(_ notification: Notification) { CrashLog.note("full screen enter: \(stateLine)") }
    func windowWillExitFullScreen(_ notification: Notification) { CrashLog.note("full screen exit: \(stateLine)") }

    /// Native smoke check for real AppKit toolbar actions, navigation, and overlay hit-testing.
    /// Run with PODCRAFT_NATIVE_UI_TEST=1 PODCRAFT_LAYOUT_TEST=1 PodCraft --screenshot /tmp/podcraft-native-ui.png.
    /// It uses a throwaway in-memory library and exits with a nonzero status on failure.
    func runNativeUISmokeTest() {
        Task { @MainActor [weak self] in
            guard let self else { exit(2) }
            func verify(_ condition: Bool, _ label: String) {
                guard condition else {
                    print("NATIVE UI FAILED: \(label)")
                    fflush(stdout)
                    exit(3)
                }
            }
            @MainActor func backItem() -> NSToolbarItem? {
                self.mainToolbar?.toolbar.items.first {
                    $0.itemIdentifier == NSToolbarItem.Identifier("navigationBack")
                }
            }

            self.library.setMode(.listen)
            self.library.listenSelection = .new
            DiscoveryRoute.shared.preview = .init(title: "Navigation Test", author: "PodCraft",
                                                  feedURL: "https://example.invalid/native-ui-test.xml")
            try? await Task.sleep(for: .milliseconds(250))
            verify(backItem()?.isHidden == false, "New preview titlebar Back is visible")
            let toolbarItems = self.mainToolbar?.toolbar.items ?? []
            let backIndex = toolbarItems.firstIndex { $0.itemIdentifier.rawValue == "navigationBack" }
            let titleIndex = toolbarItems.firstIndex { $0.itemIdentifier.rawValue == "navigationBackTitle" }
            verify(backIndex != nil && titleIndex == backIndex.map({ $0 + 1 }),
                   "native Back immediately precedes the inline title")
            let inlineTitle = titleIndex.flatMap { toolbarItems[$0].view as? NSTextField }?.stringValue
            let titleHidden = self.window.titleVisibility == .hidden
            if inlineTitle != "Navigation Test" || !titleHidden {
                print("NATIVE TITLE DIAG inline=\(inlineTitle ?? "nil") hidden=\(titleHidden) windowTitle=\(self.window.title) route=\(String(describing: DiscoveryRoute.shared.preview?.title))")
            }
            verify(inlineTitle == "Navigation Test" && titleHidden,
                   "detail title is inline with Back and the duplicate window title is hidden")
            guard let item = backItem(), let target = item.target, let action = item.action else {
                verify(false, "native Back action exists")
                return
            }
            NSApp.sendAction(action, to: target, from: item)
            verify(DiscoveryRoute.shared.preview == nil && self.library.listenSelection == .new,
                   "Back returns to New without changing the selected sidebar row")
            try? await Task.sleep(for: .milliseconds(100))
            verify(self.window.titleVisibility == .visible,
                   "ordinary titlebar restored on New overview")

            self.library.listenSelection = .home
            self.library.searchForPerson("Test Host")
            try? await Task.sleep(for: .milliseconds(150))
            verify(backItem()?.isHidden == false, "person results titlebar Back is visible")
            NSApp.sendAction(action, to: target, from: item)
            verify(self.library.personEpisodes == nil && self.library.listenSelection == .home,
                   "Back restores the previous person-results destination")

            for selection in [ListenItem.new, .shows, .new, .home] {
                self.library.listenSelection = selection
            }
            verify(DiscoveryRoute.shared.preview == nil, "rapid sidebar navigation has no stale preview")

            let show = Show(title: "Native UI Test", author: "PodCraft", hue: 0.5)
            self.library.shows.append(show)
            let episode = Episode(showID: show.id, title: "Overlay Test", published: Date(),
                                  addedAt: Date(), duration: 60,
                                  audioURL: URL(fileURLWithPath: "/tmp/podcraft-native-ui-missing.mp3").absoluteString,
                                  stage: .ready)
            self.library.episodes.append(episode)
            self.player.load(episode.id, autoplay: false)
            self.player.cinemaMode = true
            self.watchCinema()
            guard let shield = self.cinemaOverlay else {
                verify(false, "Cinema shield is attached")
                return
            }
            verify(shield.superview != nil && self.cinemaHost?.superview === shield,
                   "Cinema overlay covers the library content")
            verify(shield.hitTest(NSPoint(x: 2, y: 2)) != nil,
                   "Cinema overlay consumes pointer hits")
            verify(self.window.toolbar === self.cinemaToolbar && self.cinemaAccessories.count == 2,
                   "Cinema toolbar and native accessories installed")

            self.player.cinemaMode = false
            self.watchCinema()
            self.player.cinemaMode = true
            self.watchCinema()
            verify(self.cinemaOverlay === shield && !self.cinemaOverlayClosing,
                   "fast Cinema close/reopen reuses a single overlay")
            self.player.cinemaMode = false
            self.watchCinema()
            // AVPlayerView/NSHostingView may have outstanding layout work after
            // a rapid close–reopen–close. The fade is 180ms; give its 400ms
            // cleanup watchdog reasonable scheduling slack on loaded Macs.
            try? await Task.sleep(for: .milliseconds(1_100))
            verify(self.cinemaOverlay == nil && self.cinemaHost == nil,
                   "Cinema overlay removed after animation")
            verify(self.window.toolbar === self.mainToolbar?.toolbar && self.toolbarWatch == nil
                       && self.cinemaAccessories.isEmpty,
                   "library toolbar restored and KVO/accessories removed")
            self.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
            verify(self.syncTimer == nil && self.toolbarWatch == nil && self.window.delegate == nil,
                   "application shutdown releases native observers")
            print("NATIVE UI PASSED")
            fflush(stdout)
            exit(0)
        }
    }

    /// Developer check for the reported crash: an episode plays with the chapters/transcript panel open while
    /// another is being re-analysed (progress changing every frame), and the mode flips Listen ↔ Manage.
    /// Exits 0 if the window survives.
    /// Picture-in-picture check: which view a click lands on at points across the floating video, in both modes and
    /// with the side panel open. Every point should reach the video's own move / resize / button views.
    func runPiPHitTest() {
        func check(_ label: String) {
            guard let frameView = window.contentView?.superview else { return }
            var videos: [NSView] = []
            func walk(_ v: NSView) { if v is AVPlayerView { videos.append(v) }; v.subviews.forEach(walk) }
            walk(frameView)
            guard let video = videos.first else { print("PIP \(label): no video view"); fflush(stdout); return }
            let r = video.convert(video.bounds, to: nil)
            var hits: [String] = []
            for fy in [0.1, 0.5, 0.9] {
                for fx in [0.1, 0.5, 0.9] {
                    let p = NSPoint(x: r.minX + r.width * fx, y: r.minY + r.height * fy)
                    let hit = frameView.hitTest(frameView.convert(p, from: nil))
                    hits.append("\(fx),\(fy)=\(hit.map { String(describing: type(of: $0)) } ?? "nil")")
                }
            }
            // Outside the video, the page underneath must still get the click.
            for (name, p) in [("corner", NSPoint(x: r.minX + 6, y: r.minY + 6)), ("page", NSPoint(x: r.minX - 120, y: r.midY)),
                              ("pageLow", NSPoint(x: r.minX - 60, y: r.minY - 120))] {
                let hit = frameView.hitTest(frameView.convert(p, from: nil))
                let inside = hit.map { h in videos.contains { $0.isDescendant(of: h) } } ?? false
                hits.append("\(name)=\(hit.map { String(describing: type(of: $0)).prefix(40) } ?? "nil")\(inside ? "(VIDEO-LAYER)" : "(page)")")
            }
            print("PIP \(label) frame=\(Int(r.minX)),\(Int(r.minY)),\(Int(r.width))x\(Int(r.height)) window=\(Int(frameView.bounds.height)) " + hits.joined(separator: " "))
            fflush(stdout)
        }
        player.showChapters = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { check("listen") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.library.setMode(.manage) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) { check("manage") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.player.toggleTranscriptPanel() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.5) { check("manage+panel") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 7) { [weak self] in
            if let out = ProcessInfo.processInfo.environment["PODCRAFT_PIP_CAPTURE"] { self?.capture(to: out) } else { exit(0) }
        }
    }

    func runModeSwitchStressTest(audio: String) {
        let show = Show(title: "Stress Show", author: "Test", feedURL: "https://example.invalid/feed.xml", hue: 0.5)
        library.shows.append(show)
        var playing = Episode(showID: show.id, title: "Playing Episode", published: Date(), addedAt: Date(), duration: 31,
                              audioURL: URL(fileURLWithPath: audio).absoluteString, stage: .ready)
        playing.localFile = audio
        playing.isVideo = ["mp4", "mov", "m4v"].contains(URL(fileURLWithPath: audio).pathExtension.lowercased())
        playing.chapters = [Chapter(start: 0, title: "Opening"), Chapter(start: 10, title: "Middle"), Chapter(start: 20, title: "End")]
        playing.transcript = (0..<30).map { TranscriptLine(start: Double($0), end: Double($0) + 1, text: "Line \($0) of the test transcript.") }
        var working = Episode(showID: show.id, title: "Re-analysing Episode", published: Date(), addedAt: Date(), duration: 600,
                              stage: .transcribing)
        working.progress = 0
        library.episodes += [playing, working]
        library.listenSelection = .show(show.id)
        library.setMode(.listen)
        player.play(playing.id)
        if ProcessInfo.processInfo.environment["PODCRAFT_NOW_PLAYING_TEST"] != nil {
            let center = MPNowPlayingInfoCenter.default()
            let info = center.nowPlayingInfo ?? [:]
            let initialValid = (info[MPMediaItemPropertyTitle] as? String) == playing.title
                && (info[MPMediaItemPropertyAlbumTitle] as? String) == show.title
                && (info[MPMediaItemPropertyArtist] as? String) == show.author
                && (info[MPMediaItemPropertyPlaybackDuration] as? Double) == playing.duration
                && center.playbackState == .playing
            player.seek(to: 12)
            let seekValid = (center.nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double) == 12
            player.togglePlay()
            let pausedState = center.playbackState
            let pausedRate = center.nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate]
            let pauseValid = pausedState == .paused && (pausedRate as? NSNumber)?.doubleValue == 0
            player.togglePlay()
            let resumeValid = center.playbackState == .playing
            player.seek(to: 0)
            let valid = initialValid && seekValid && pauseValid && resumeValid
            if !valid {
                print("NOW PLAYING checks initial=\(initialValid) seek=\(seekValid) pause=\(pauseValid) resume=\(resumeValid)")
                print("NOW PLAYING paused state=\(pausedState.rawValue) rate=\(String(describing: pausedRate)) player.isPlaying=\(player.isPlaying)")
                print("NOW PLAYING times elapsed=\(String(describing: center.nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime])) rate=\(String(describing: center.nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate])) state=\(center.playbackState.rawValue)")
            }
            print("NOW PLAYING \(valid ? "PASSED" : "FAILED") artwork=\(info[MPMediaItemPropertyArtwork] != nil)")
            fflush(stdout)
            if !valid { exit(2) }
        }
        player.showChapters = ProcessInfo.processInfo.environment["PODCRAFT_NO_PANEL"] == nil
        let workingID = working.id
        if ProcessInfo.processInfo.environment["PODCRAFT_STRESS_NO_PROGRESS"] == nil {
            Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let i = self.library.episodeIndex(workingID) else { return }
                    self.library.updateProgress(workingID, (self.library.episodes[i].progress + 0.004).truncatingRemainder(dividingBy: 1))
                }
            }
        }
        if ProcessInfo.processInfo.environment["PODCRAFT_RESIZE_TEST"] != nil {
            runResizeTest()
            return
        }
        if ProcessInfo.processInfo.environment["PODCRAFT_SERVER_PROBE"] != nil {
            // Feed server check: prints this show's feed link, then stays up 60 s for requests.
            // Its own port (PODCRAFT_TEST_PORT), so a PodCraft you have open keeps 8743.
            if let p = ProcessInfo.processInfo.environment["PODCRAFT_TEST_PORT"].flatMap(Int.init) {
                library.settings.hostPort = p
                server.start()
            }
            // A channel holding the show, and a second show with nothing downloaded (its episode streams).
            let feed = Feed(title: "Test Channel", author: "Test", summary: "A channel built on the Mac.", hue: 0.48)
            library.feeds.append(feed)
            if let i = library.showIndex(show.id) { library.shows[i].feedID = feed.id }
            let streamed = Show(title: "Streamed Show", author: "Elsewhere", feedURL: "https://example.invalid/2.xml", hue: 0.1)
            library.shows.append(streamed)
            library.episodes.append(Episode(showID: streamed.id, title: "Not Downloaded Yet", published: Date().addingTimeInterval(-86400),
                                            addedAt: Date(), duration: 1800, audioURL: "https://example.invalid/ep.mp3", stage: .listed))
            print("SHOWFEED \(server.showURL(show))"); print("PHONECODE \(library.settings.phoneCode)"); fflush(stdout)
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) { exit(0) }
            return
        }
        if ProcessInfo.processInfo.environment["PODCRAFT_PIP_TEST"] != nil {
            runPiPHitTest()
            return
        }
        for (k, t) in stride(from: 0.8, through: 7.2, by: 0.4).enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in
                self?.library.setMode(k.isMultiple(of: 2) ? .manage : .listen)
                if k == 5 { self?.library.manageSelection = .downloads }
                if k == 9 { self?.library.manageSelection = .show(show.id) }
                if k == 3 { self?.player.toggleQueuePanel() }
                if k == 7 { self?.player.toggleTranscriptPanel() }
                if k == 11 { self?.player.cinemaMode = true }
                if k == 12 { self?.player.toggleQueuePanel() }
                if k == 14 { self?.player.cinemaMode = false }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.5) { [weak self] in
            print("STRESS PASSED"); fflush(stdout)
            if let out = ProcessInfo.processInfo.environment["PODCRAFT_CINEMA_CAPTURE"] {
                self?.player.showQueue = false
                self?.player.showChapters = true
                self?.player.cinemaMode = true
                if let n = self?.window.windowNumber { print("WINDOW \(n)"); fflush(stdout) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self?.capture(to: out) }
            } else if let out = ProcessInfo.processInfo.environment["PODCRAFT_CRASH_CAPTURE"] {
                self?.library.setMode(.listen)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self?.capture(to: out) }
            } else { exit(0) }
        }
    }

    /// Developer check for the resize crash. Default mode retains the original 90 Hz queued resize storm.
    /// PODCRAFT_RESIZE_MODE=paced: one step at a time, with a main-run-loop opportunity between frames.
    /// PODCRAFT_RESIZE_STEP_MS=40 sets the pacing; PODCRAFT_RESIZE_FORCE_LAYOUT=1 forces layout after each step.
    /// PODCRAFT_RESIZE_ANIMATE=1 tests animated setFrame (the default is explicitly nonanimated).
    /// PODCRAFT_RESIZE_PASS=manage+queue selects a case; PODCRAFT_RESIZE_FOCUS=1 sweeps 1200...900 only.
    /// PODCRAFT_RESIZE_RESPECT_MIN=1 tests clamping to the runtime AppKit content minimum (default: no clamp).
    /// PODCRAFT_RESIZE_TRACE=/tmp/trace.log records requested vs actual frames, content and split columns.
    /// Every variant is test-only; the production window's behavior is identical.
    func runResizeTest() {
        guard let w = window else { return }
        let env = ProcessInfo.processInfo.environment
        let paced = env["PODCRAFT_RESIZE_MODE"] == "paced"
        let forceLayout = env["PODCRAFT_RESIZE_FORCE_LAYOUT"] == "1"
        let animate = env["PODCRAFT_RESIZE_ANIMATE"] == "1"
        let respectMin = env["PODCRAFT_RESIZE_RESPECT_MIN"] == "1"
        let focus = env["PODCRAFT_RESIZE_FOCUS"] == "1"
        let delay = max(10, min(500, Int(env["PODCRAFT_RESIZE_STEP_MS"] ?? "40") ?? 40))
        let pause = max(100, min(2000, Int(env["PODCRAFT_RESIZE_SETTLE_MS"] ?? "500") ?? 500))
        // The default stress test must remain as close as possible to its original 90 Hz timing.
        // Hierarchy walks and synchronous trace writes happen only when explicitly requested.
        let tracePath = env["PODCRAFT_RESIZE_TRACE"].flatMap { $0.isEmpty ? nil : $0 }
        if let tracePath {
            _ = FileManager.default.createFile(atPath: tracePath, contents: nil)
            resizeTrace = try? FileHandle(forWritingTo: URL(fileURLWithPath: tracePath))
        } else {
            resizeTrace = nil
        }
        resizeTestStart = Date()
        resizeEventCount = 0
        resizeTestStep = -1
        resizeRequestedFrame = nil
        print("RESIZE CONFIG mode=\(paced ? "paced" : "legacy") stepMs=\(paced ? delay : 11) animate=\(animate) forceLayout=\(forceLayout) respectMin=\(respectMin) focus=\(focus) pass=\(env["PODCRAFT_RESIZE_PASS"] ?? "all") trace=\(tracePath ?? "off")")
        fflush(stdout)
        let origin = w.frame.origin
        var sizes: [NSSize] = []
        let maxWidth = focus ? 1200.0 : 1700.0
        for width in Swift.stride(from: maxWidth, through: 900.0, by: -7) { sizes.append(NSSize(width: width, height: 820)) }
        for width in Swift.stride(from: 900.0, through: maxWidth, by: 11) { sizes.append(NSSize(width: width, height: 640 + (width - 900) / 4)) }

        // Explicit state for every pass makes PODCRAFT_RESIZE_PASS useful in isolation. The old
        // harness relied on earlier passes leaving the right mode/panel state behind.
        let passes: [(String, () -> Void)] = [
            ("listen+transcript", { [weak self] in
                self?.player.cinemaMode = false; self?.library.setMode(.listen)
                self?.player.showChapters = true; self?.player.showQueue = false
            }),
            ("listen+queue", { [weak self] in
                self?.player.cinemaMode = false; self?.library.setMode(.listen)
                self?.player.showQueue = true; self?.player.showChapters = false
            }),
            ("manage+queue", { [weak self] in
                self?.player.cinemaMode = false; self?.library.setMode(.manage)
                self?.player.showQueue = true; self?.player.showChapters = false
            }),
            ("manage+none", { [weak self] in
                self?.player.cinemaMode = false; self?.library.setMode(.manage)
                self?.player.showQueue = false; self?.player.showChapters = false
            }),
            ("listen+none", { [weak self] in
                self?.player.cinemaMode = false; self?.library.setMode(.listen)
                self?.player.showQueue = false; self?.player.showChapters = false
            }),
            ("cinema+transcript", { [weak self] in
                self?.library.setMode(.listen); self?.player.showQueue = false
                self?.player.showChapters = true; self?.player.cinemaMode = true
            }),
            ("cinema+queue", { [weak self] in
                self?.library.setMode(.listen); self?.player.showQueue = true
                self?.player.showChapters = false; self?.player.cinemaMode = true
            }),
            ("closed cinema", { [weak self] in
                self?.player.cinemaMode = false; self?.library.setMode(.listen)
                self?.player.showQueue = false; self?.player.showChapters = false
            }),
        ]
        let onlyPass = env["PODCRAFT_RESIZE_PASS"]
        let active = passes.filter { onlyPass == nil || onlyPass == $0.0 }
        guard !active.isEmpty else {
            print("RESIZE FAILED: unknown pass \(onlyPass ?? "")")
            fflush(stdout)
            exit(2)
        }
        func setTestFrame(_ size: NSSize, step: Int) {
            resizeTestStep = step
            let requested = NSRect(origin: origin, size: size)
            resizeRequestedFrame = requested
            let effective = respectMin ? NSSize(width: max(size.width, w.contentMinSize.width),
                                                height: max(size.height, w.contentMinSize.height)) : size
            let frame = NSRect(origin: origin, size: effective)
            let sample = (925...1130).contains(size.width) || step.isMultiple(of: 12)
            if sample { resizeTraceLine("BEFORE-SET applied=\(Int(effective.width))x\(Int(effective.height))") }
            w.setFrame(frame, display: true, animate: animate)
            if forceLayout { w.layoutIfNeeded() }
            if sample { resizeTraceLine("AFTER-SET") }
        }
        func startPass(_ name: String, _ setup: () -> Void) {
            resizeTestPass = name
            resizeTestStep = -1
            resizeRequestedFrame = nil
            resizeTraceLine("BEFORE-PASS")
            setup()
            resizeTraceLine("AFTER-PASS")
            print("PASS \(name)")
            fflush(stdout)
        }
        func finished() {
            resizeTestStep = sizes.count
            resizeTraceLine("COMPLETE")
            print("RESIZE PASSED")
            fflush(stdout)
            try? resizeTrace?.close()
            resizeTrace = nil
            exit(0)
        }

        if paced {
            Task { @MainActor in
                for (name, setup) in active {
                    startPass(name, setup)
                    try? await Task.sleep(for: .milliseconds(pause))
                    for (step, size) in sizes.enumerated() {
                        setTestFrame(size, step: step)
                        try? await Task.sleep(for: .milliseconds(delay))
                    }
                    try? await Task.sleep(for: .milliseconds(pause))
                }
                finished()
            }
            return
        }

        // Original high-pressure variant: prequeue 90 Hz callbacks, intentionally without a layout pause.
        var t = 0.6
        for (name, setup) in active {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { startPass(name, setup) }
            t += 0.5
            for (step, size) in sizes.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + t) { setTestFrame(size, step: step) }
                t += 1.0 / 90
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + t + 0.5) { finished() }
    }

    /// Layout check: where the sidebar's first row sits against the bottom of the title bar and toolbar.
    func reportLayout() {
        let barBottom = window.contentLayoutRect.maxY   // window coordinates, origin bottom-left
        var tables: [NSTableView] = []
        func walk(_ v: NSView) { if let t = v as? NSTableView { tables.append(t) }; v.subviews.forEach(walk) }
        if let root = window.contentView?.superview { walk(root) }
        let lines = tables.compactMap { t -> String? in
            guard t.numberOfRows > 0, let scroll = t.enclosingScrollView else { return nil }
            let first = t.convert(t.rect(ofRow: 0), to: nil)
            let visible = scroll.convert(scroll.contentView.bounds, to: nil)
            return String(format: "rows=%d firstRowTop=%.0f visibleTop=%.0f x=%.0f", t.numberOfRows, first.maxY, min(visible.maxY, first.maxY), first.minX)
        }
        print("MODE \(library.mode.rawValue) barBottom=\(Int(barBottom)) " + lines.joined(separator: " | "))
        fflush(stdout)
    }

    // MARK: Screenshot (--screenshot <file.png>)

    /// AppKit's cacheDisplay omits AVPlayerView's separate video-compositor layer.
    /// For a screenshot only, composite a decoded frame from the *current player
    /// item* at its original source clock, in the actual native player rect.
    /// This does not seek, pause, or alter the running AVPlayer or its source.
    private func drawCapturedVideo(in target: NSView, scale: CGFloat) {
        guard player.showVideo, let videoPlayer = player.videoPlayer,
              let asset = videoPlayer.currentItem?.asset as? AVURLAsset,
              asset.url.isFileURL else { return }

        func playerViews(in view: NSView) -> [AVPlayerView] {
            var found: [AVPlayerView] = []
            if let playerView = view as? AVPlayerView { found.append(playerView) }
            for subview in view.subviews { found.append(contentsOf: playerViews(in: subview)) }
            return found
        }
        guard let view = playerViews(in: target).first(where: {
            $0.player === videoPlayer && !$0.isHidden && $0.bounds.width > 0 && $0.bounds.height > 0
        }) else { return }

        let frameRect = view.convert(view.bounds, to: target)
        guard frameRect.width > 0, frameRect.height > 0 else { return }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: frameRect.width * scale, height: frameRect.height * scale)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        let clock = videoPlayer.currentTime()
        let timestamp = clock.isValid && clock.seconds.isFinite ? max(0, clock.seconds) : 0
        guard let cgImage = try? generator.copyCGImage(
            at: CMTime(seconds: timestamp, preferredTimescale: 600), actualTime: nil
        ) else { return }

        let ratio = min(frameRect.width / CGFloat(cgImage.width), frameRect.height / CGFloat(cgImage.height))
        let width = CGFloat(cgImage.width) * ratio, height = CGFloat(cgImage.height) * ratio
        let imageRect = NSRect(x: frameRect.midX - width / 2, y: frameRect.midY - height / 2,
                               width: width, height: height)
        let scaledRect = NSRect(x: imageRect.minX * scale, y: imageRect.minY * scale,
                                width: imageRect.width * scale, height: imageRect.height * scale)
        NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            .draw(in: scaledRect)
        if BroskiTestFixture.current != nil {
            print(String(format: "BROSKI VIDEO SCREENSHOT composited=true sourceTime=%.1fs frame=%dx%d", timestamp,
                         cgImage.width, cgImage.height))
            fflush(stdout)
        }
    }

    func capture(to path: String) {
        guard let content = window.contentView else { exit(2) }
        let target = content.superview ?? content
        let bounds = target.bounds
        let scale = window.backingScaleFactor
        let w = Int(bounds.width * scale), h = Int(bounds.height * scale)
        guard let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { exit(4) }
        NSGraphicsContext.saveGraphicsState()
        let ctx = NSGraphicsContext(bitmapImageRep: out)!
        NSGraphicsContext.current = ctx
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            NSRect(x: 0, y: 0, width: w, height: h).fill()
        }
        if let rep = target.bitmapImageRepForCachingDisplay(in: bounds) {
            target.cacheDisplay(in: bounds, to: rep)
            rep.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
        }
        drawCapturedVideo(in: target, scale: scale)
        NSGraphicsContext.restoreGraphicsState()
        guard let data = out.representation(using: .png, properties: [:]) else { exit(5) }
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do { try data.write(to: url) } catch { FileHandle.standardError.write("Could not save \(path): \(error)\n".data(using: .utf8)!); exit(6) }
        exit(0)
    }

    // MARK: Menus

    func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About PodCraft", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(item("Settings…", #selector(openSettings), ","))
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide PodCraft", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit PodCraft", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        main.addItem(submenu("File", [
            item("New Feed", #selector(newFeed), "n", [.command, .shift]),
            item("Add a Show…", #selector(addShow), "n"),
            item("Check for New Episodes", #selector(checkNew), "r"),
            .separator(),
            item("Close Window", #selector(NSWindow.performClose(_:)), "w", target: false),
        ]))

        main.addItem(submenu("Edit", [
            item("Undo", Selector(("undo:")), "z", target: false),
            item("Redo", Selector(("redo:")), "z", [.command, .shift], target: false),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x", target: false),
            item("Copy", #selector(NSText.copy(_:)), "c", target: false),
            item("Paste", #selector(NSText.paste(_:)), "v", target: false),
            item("Select All", #selector(NSText.selectAll(_:)), "a", target: false),
        ]))

        main.addItem(submenu("View", [
            item("Manage Mode", #selector(manageMode), "1"),
            item("Listen Mode", #selector(listenMode), "2"),
            item("Switch Mode", #selector(toggleMode), "m", [.command, .shift]),
            .separator(),
            item("Toggle Sidebar", #selector(NSSplitViewController.toggleSidebar(_:)), "s", [.command, .control], target: false),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control], target: false),
        ]))

        main.addItem(submenu("Controls", [
            item("Play / Pause", #selector(playPause), PlaybackShortcut.playPause.key, PlaybackShortcut.playPause.modifiers),
            // Genuine AppKit equivalents render in the faded, right-aligned
            // shortcut column. The local key monitor still owns playback input.
            item("Back \(Int(Mechanics.skipBackSeconds)) Seconds", #selector(back15), PlaybackShortcut.back.key, PlaybackShortcut.back.modifiers),
            item("Forward \(Int(Mechanics.skipForwardSeconds)) Seconds", #selector(fwd15), PlaybackShortcut.forward.key, PlaybackShortcut.forward.modifiers),
            item("Previous Chapter", #selector(prevChapter), PlaybackShortcut.previousChapter.key, PlaybackShortcut.previousChapter.modifiers),
            item("Next Chapter", #selector(nextChapter), PlaybackShortcut.nextChapter.key, PlaybackShortcut.nextChapter.modifiers),
            item("Previous Episode", #selector(prevQueuedEpisode), PlaybackShortcut.previousEpisode.key, PlaybackShortcut.previousEpisode.modifiers),
            item("Next Queued Episode", #selector(nextQueuedEpisode), PlaybackShortcut.nextEpisode.key, PlaybackShortcut.nextEpisode.modifiers),
            .separator(),
            item("Cinema Mode", #selector(toggleCinemaMode), PlaybackShortcut.cinema.key, PlaybackShortcut.cinema.modifiers),
            item("Transcript", #selector(toggleTranscript), PlaybackShortcut.transcript.key, PlaybackShortcut.transcript.modifiers),
            item("Queue", #selector(toggleQueue), PlaybackShortcut.queue.key, PlaybackShortcut.queue.modifiers),
            item("Mute / Unmute", #selector(toggleMute), PlaybackShortcut.mute.key, PlaybackShortcut.mute.modifiers),
            item("Full Screen", #selector(toggleFullScreen), PlaybackShortcut.fullScreen.key, PlaybackShortcut.fullScreen.modifiers),
            .separator(),
            item("Faster", #selector(faster), PlaybackShortcut.faster.key, PlaybackShortcut.faster.modifiers),
            item("Slower", #selector(slower), PlaybackShortcut.slower.key, PlaybackShortcut.slower.modifiers),
            item("Normal Speed", #selector(normalSpeed), PlaybackShortcut.normalSpeed.key, PlaybackShortcut.normalSpeed.modifiers),
        ]))

        let windowItem = submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m", target: false),
            item("Zoom", #selector(NSWindow.performZoom(_:)), "", target: false),
        ])
        main.addItem(windowItem)
        NSApp.windowsMenu = windowItem.submenu
        NSApp.mainMenu = main
    }

    private func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let m: NSMenu
        if title == "Controls" {
            let controls = PlaybackControlsMenu(title: title)
            controls.isEditingText = { [weak self] in
                guard let self, let window = self.window, window.isKeyWindow else { return false }
                return self.isEditingText(in: window)
            }
            m = controls
        } else {
            m = NSMenu(title: title)
        }
        items.forEach { m.addItem($0) }
        it.submenu = m
        return it
    }

    private func item(_ title: String, _ action: Selector, _ key: String,
                      _ mods: NSEvent.ModifierFlags = [.command], target: Bool = true) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
        it.keyEquivalentModifierMask = mods
        if target { it.target = self }
        return it
    }

    @objc func openSettings() { library.setMode(.manage); library.manageSelection = .settings }
    @objc func newFeed() { library.setMode(.manage); library.addFeed() }
    @objc func addShow() { library.setMode(.manage); library.showAddShow = true }
    @objc func checkNew() { library.checkForNewEpisodes() }
    @objc func manageMode() { library.setMode(.manage) }
    @objc func listenMode() { library.setMode(.listen) }
    @objc func toggleMode() { library.toggleMode() }
    @objc func playPause() { player.togglePlay() }
    @objc func back15() { player.skipBack() }
    @objc func fwd15() { player.skipForward() }
    @objc func prevChapter() { player.previousChapter() }
    @objc func nextChapter() { player.nextChapter() }
    @objc func prevQueuedEpisode() { player.previousQueuedEpisode() }
    @objc func nextQueuedEpisode() { player.nextQueuedEpisode() }
    @objc func toggleCinemaMode() {
        if player.episode != nil || player.cinemaMode { player.cinemaMode.toggle() }
    }
    @objc func toggleTranscript() {
        if player.episode != nil || player.showChapters { player.toggleTranscriptPanel() }
    }
    @objc func toggleQueue() { player.toggleQueuePanel() }
    @objc func toggleMute() { player.toggleMute() }
    @objc func toggleFullScreen() { window?.toggleFullScreen(nil) }
    @objc func faster() { player.faster() }
    @objc func slower() { player.slower() }
    @objc func normalSpeed() { player.setRate(1.0) }
}

// Developer check: `PodCraft --process-test <audio file>` transcribes on this Mac, asks the on-device AI for
// chapters and sponsors, prints them and exits (no window).
if let i = arguments.firstIndex(of: "--chapter-library-test"), i + 1 < arguments.count {
    let libraryURL = URL(fileURLWithPath: arguments[i + 1])
    let requestedID = i + 2 < arguments.count ? arguments[i + 2] : nil
    Task {
        do {
            let file = try JSONDecoder().decode(LibraryFile.self, from: Data(contentsOf: libraryURL))
            let episode = requestedID.flatMap { id in file.episodes.first { $0.id.uuidString == id || $0.id.uuidString.hasPrefix(id.uppercased()) } }
                ?? file.episodes.first { !$0.transcript.isEmpty && $0.localFile != nil }
            guard let episode, !episode.transcript.isEmpty, let path = episode.localFile else {
                throw NSError(domain: "PodCraftTest", code: 10,
                              userInfo: [NSLocalizedDescriptionKey: "No matching episode has both a transcript and local media"])
            }
            let mediaURL = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: path) else {
                throw NSError(domain: "PodCraftTest", code: 11,
                              userInfo: [NSLocalizedDescriptionKey: "Local media is missing: \(path)"])
            }
            let assetDuration = try await AVURLAsset(url: mediaURL).load(.duration).seconds
            guard assetDuration.isFinite, assetDuration > 0 else {
                throw NSError(domain: "PodCraftTest", code: 12,
                              userInfo: [NSLocalizedDescriptionKey: "The media duration could not be read"])
            }
            print("MEDIA \(mediaURL.lastPathComponent) \(String(format: "%.1f", assetDuration))s")
            print("TRANSCRIPT \(episode.transcript.count) lines")
            let found = try await AIService.chapters(lines: episode.transcript, duration: assetDuration,
                                                     provider: .onDevice, model: "", findSponsors: true) { progress in
                if Int(progress * 100).isMultiple(of: 10) { print("PROGRESS \(Int(progress * 100))%") }
            }
            guard !found.chapters.isEmpty, found.chapters.first?.start == 0 else {
                throw NSError(domain: "PodCraftTest", code: 13,
                              userInfo: [NSLocalizedDescriptionKey: "No usable chapters were generated"])
            }
            for chapter in found.chapters { print("CHAPTER \(Fmt.clock(chapter.start)) \(chapter.title)") }
            for sponsor in found.sponsors { print("SPONSOR \(Fmt.clock(sponsor.start))-\(Fmt.clock(sponsor.end))") }
            print("FULL CHAPTER PASS \(found.chapters.count) chapters, \(found.sponsors.count) sponsor cuts")
            exit(0)
        } catch {
            print("FULL CHAPTER FAILED: \(error.localizedDescription)")
            exit(1)
        }
    }
    RunLoop.main.run()
}

if let i = arguments.firstIndex(of: "--chapter-transcript-test"), i + 1 < arguments.count {
    let url = URL(fileURLWithPath: arguments[i + 1])
    Task {
        do {
            let file = try JSONDecoder().decode(LibraryFile.self, from: Data(contentsOf: url))
            guard let episode = file.episodes.first(where: { !$0.transcript.isEmpty }) else {
                throw NSError(domain: "PodCraftTest", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "The library contains no transcript"])
            }
            // A real excerpt is enough to exercise block creation, Apple Intelligence response parsing,
            // relative-line repair, fallback generation and final timestamp assembly.
            let lines = Array(episode.transcript.prefix(96))
            let duration = max(lines.last?.end ?? 0, 1)
            let found = try await AIService.chapters(lines: lines, duration: duration, provider: .onDevice,
                                                     model: "", findSponsors: false)
            guard !found.chapters.isEmpty, found.chapters.first?.start == 0 else {
                throw NSError(domain: "PodCraftTest", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "No usable chapters were generated"])
            }
            print("TRANSCRIPT CHAPTER PASS \(lines.count) lines -> \(found.chapters.count) chapters")
            for chapter in found.chapters { print("CHAPTER \(Fmt.clock(chapter.start)) \(chapter.title)") }
            exit(0)
        } catch {
            print("TRANSCRIPT CHAPTER FAILED: \(error.localizedDescription)")
            exit(1)
        }
    }
    RunLoop.main.run()
}

// Automatic-download regression: the first phase stays in memory, and the
// second phase explicitly writes/reopens a disposable library and preferences
// domain. Never open the user's Library.json or user defaults in this check.
if arguments.contains("--show-filter-persistence-test") {
    MainActor.assumeIsolated {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "podcraft-show-filter-test-\(UUID().uuidString)", isDirectory: true)
        let storage = dir.appendingPathComponent("Library.json")
        let suite = "org.podcraft.show-filter-test.\(UUID().uuidString)"
        guard let prefs = UserDefaults(suiteName: suite) else { exit(2) }
        let status: Int = {
            do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let lib = Library(screenshot: false, isolatedStorageURL: storage, isolatedPreferences: prefs)
            // Real subscriptions have a feedURL. Without one, Library.init
            // correctly removes legacy invented placeholders on restart.
            var a = Show(title: "Filter Show A", author: "PodCraft", hue: 0.3)
            var b = Show(title: "Filter Show B", author: "PodCraft", hue: 0.6)
            a.feedURL = "https://example.invalid/podcraft-filter-a.xml"
            b.feedURL = "https://example.invalid/podcraft-filter-b.xml"
            lib.shows = [a, b]
            lib.save()
            guard lib.episodeFilter(forShow: a.id) == .all,
                  lib.episodeFilter(forShow: b.id) == .all else { return 3 }
            lib.setEpisodeFilter(.unplayed, forShow: a.id)
            lib.setEpisodeFilter(.downloaded, forShow: b.id)
            let restored = Library(screenshot: false, isolatedStorageURL: storage,
                                   isolatedPreferences: prefs)
            guard restored.episodeFilter(forShow: a.id) == .unplayed,
                  restored.episodeFilter(forShow: b.id) == .downloaded else { return 4 }
            restored.setEpisodeFilter(.all, forShow: a.id)
            let again = Library(screenshot: false, isolatedStorageURL: storage,
                                isolatedPreferences: prefs)
            guard again.episodeFilter(forShow: a.id) == .all,
                  again.episodeFilter(forShow: b.id) == .downloaded else {
                let stored = prefs.dictionary(forKey: "episodeFiltersByShow") ?? [:]
                print("SHOW FILTER RESTART DETAIL a=\(again.episodeFilter(forShow: a.id).rawValue) b=\(again.episodeFilter(forShow: b.id).rawValue) stored=\(stored)")
                return 5
            }
            let screenshotLibrary = Library(screenshot: true, isolatedStorageURL: storage,
                                            isolatedPreferences: prefs)
            screenshotLibrary.shows = [a, b]
            screenshotLibrary.setEpisodeFilter(.unplayed, forShow: b.id)
            let persistent = Library(screenshot: false, isolatedStorageURL: storage,
                                     isolatedPreferences: prefs)
            guard persistent.episodeFilter(forShow: b.id) == .downloaded else { return 6 }
            return 0
            } catch {
                print("SHOW FILTER PERSISTENCE FAILED: \(error.localizedDescription)")
                return 1
            }
        }()
        prefs.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: dir)
        if status == 0 {
            print("SHOW FILTER PERSISTENCE PASSED allDefault=true independentShows=true restart=true resetToAll=true screenshotIsolated=true")
        } else {
            print("SHOW FILTER PERSISTENCE FAILED code=\(status)")
        }
        exit(Int32(status))
    }
}

if arguments.contains("--played-autodownload-test") {
    MainActor.assumeIsolated {
        let lib = Library(screenshot: true)
        let show = Show(title: "Auto Download Regression", author: "PodCraft", hue: 0.4,
                        keepAvailable: 2)
        lib.shows = [show]
        let now = Date()
        var newest = Episode(showID: show.id, title: "Already Played", published: now,
                             addedAt: now, duration: 900)
        newest.played = true
        newest.audioURL = "https://example.invalid/first.mp3"
        var second = Episode(showID: show.id, title: "Unplayed New", published: now.addingTimeInterval(-86400),
                             addedAt: now, duration: 900)
        second.audioURL = "https://example.invalid/second.mp3"
        var older = Episode(showID: show.id, title: "Unplayed Older", published: now.addingTimeInterval(-172800),
                            addedAt: now, duration: 900)
        older.audioURL = "https://example.invalid/third.mp3"
        lib.episodes = [newest, second, older]
        lib.refreshAvailability(show.id)
        let initiallySkippedPlayed = lib.episode(newest.id)?.stage == .listed
        let queuedUnplayed = lib.episode(second.id)?.stage == .queued && lib.episode(second.id)?.autoDownloaded == true
        let noBackfill = lib.episode(older.id)?.stage == .listed

        lib.setPlayed(second.id, true)
        let cancelledExisting = lib.episode(second.id)?.stage == .listed &&
            lib.episode(second.id)?.autoDownloaded == false
        let noOldEpisodeDownload = lib.episode(older.id)?.stage == .listed

        lib.download(newest.id)
        let manuallyAllowed = lib.episode(newest.id)?.stage == .queued &&
            lib.episode(newest.id)?.autoDownloaded == false && lib.episode(newest.id)?.played == true

        var legacyQueued = newest
        legacyQueued.id = UUID()
        legacyQueued.title = "Legacy queued played"
        legacyQueued.published = now.addingTimeInterval(86400)
        legacyQueued.stage = .queued
        legacyQueued.autoDownloaded = true
        lib.episodes.append(legacyQueued)
        lib.refreshAvailability(show.id)
        let legacyCancelled = lib.episode(legacyQueued.id)?.stage == .listed &&
            lib.episode(legacyQueued.id)?.autoDownloaded == false

        // Simulate a feed update that introduces a previously played episode.
        var fromFeed = newest
        fromFeed.id = UUID()
        fromFeed.title = "Already Played in Refreshed Feed"
        fromFeed.published = now.addingTimeInterval(172800)
        fromFeed.stage = .listed
        fromFeed.autoDownloaded = false
        lib.episodes.append(fromFeed)
        lib.refreshAvailability(show.id)
        let refreshSkippedPlayed = lib.episode(fromFeed.id)?.stage == .listed

        // A transfer already in flight must be stopped when a user marks the
        // episode Played. This synthetic state has no network task or local file.
        var inFlight = second
        inFlight.id = UUID()
        inFlight.published = now.addingTimeInterval(259200)
        inFlight.stage = .downloading
        inFlight.played = false
        inFlight.autoDownloaded = true
        inFlight.localFile = nil
        lib.episodes.append(inFlight)
        lib.setPlayed(inFlight.id, true)
        let cancelledActiveAutomatic = lib.episode(inFlight.id)?.stage == .listed &&
            lib.episode(inFlight.id)?.autoDownloaded == false

        // The app restart check uses its own temporary folder and UserDefaults
        // suite: unlike screenshot-mode, it runs the real production persistence
        // and Library.init migration path, including legacy queued auto jobs.
        let fixtureFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("podcraft-played-restart-\(UUID().uuidString)", isDirectory: true)
        let fixtureURL = fixtureFolder.appendingPathComponent("Library.json")
        let suiteName = "org.podcraft.regression.\(UUID().uuidString)"
        let prefs = UserDefaults(suiteName: suiteName)!
        let isolatedPersisted: Bool
        do {
            try FileManager.default.createDirectory(at: fixtureFolder, withIntermediateDirectories: true)
            let isolated = Library(screenshot: false, isolatedStorageURL: fixtureURL, isolatedPreferences: prefs)
            var persistentShow = show
            persistentShow.feedURL = "https://example.invalid/read-only-feed.xml"
            isolated.shows = [persistentShow]
            var completed = newest
            completed.stage = .listed
            completed.autoDownloaded = false
            completed.position = completed.playbackDuration
            var staleAuto = legacyQueued
            staleAuto.stage = .queued
            staleAuto.autoDownloaded = true
            isolated.episodes = [completed, staleAuto, older]
            isolated.save()

            let relaunched = Library(screenshot: false,
                                     isolatedStorageURL: fixtureURL, isolatedPreferences: prefs)
            let persistedPlayed = relaunched.episode(completed.id)?.played == true &&
                abs((relaunched.episode(completed.id)?.position ?? -1) - completed.playbackDuration) < 0.01
            let restoredLegacyCancelled = relaunched.episode(staleAuto.id)?.stage == .listed &&
                relaunched.episode(staleAuto.id)?.autoDownloaded == false
            relaunched.refreshAvailability(show.id)
            let afterRefresh = relaunched.episode(completed.id)?.stage == .listed &&
                relaunched.episode(staleAuto.id)?.stage == .listed &&
                relaunched.episode(older.id)?.stage == .listed
            isolatedPersisted = persistedPlayed && restoredLegacyCancelled && afterRefresh
        } catch {
            print("PLAYED AUTO DOWNLOAD ISOLATED RESTART ERROR: \(error.localizedDescription)")
            isolatedPersisted = false
        }
        prefs.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: fixtureFolder)

        let passed = initiallySkippedPlayed && queuedUnplayed && noBackfill &&
            cancelledExisting && noOldEpisodeDownload && manuallyAllowed && legacyCancelled
            && refreshSkippedPlayed && cancelledActiveAutomatic && isolatedPersisted
        print("PLAYED AUTO DOWNLOAD \(passed ? "PASSED" : "FAILED") skippedPlayed=\(initiallySkippedPlayed) queuedUnplayed=\(queuedUnplayed) noBackfill=\(noBackfill && noOldEpisodeDownload) cancelledQueued=\(cancelledExisting && legacyCancelled) cancelledActive=\(cancelledActiveAutomatic) manualDownloadAllowed=\(manuallyAllowed) refreshSkippedPlayed=\(refreshSkippedPlayed) isolatedRestart=\(isolatedPersisted) realUserLibraryUnchanged=true")
        exit(passed ? 0 : 1)
    }
}

// Deterministic multilingual chapter parsing and transcript-evidence sponsor
// boundaries. Tests the same production AIService helpers without a network or
// access to the user's persisted library.
if arguments.contains("--ai-regression-test") {
    let failures = AIServiceRegression.failures()
    failures.forEach { print("AI REGRESSION FAILED: \($0)") }
    print("AI REGRESSION \(failures.isEmpty ? "PASSED" : "FAILED") multilingual=true SpanishEdgeAds=true checks=production")
    fflush(stdout)
    exit(failures.isEmpty ? 0 : 1)
}

// Fast deterministic check of the invisible, non-destructive playback timeline.
if arguments.contains("--sponsor-timeline-test") {
    let cuts = [CutSegment(start: 0, end: 26, category: "sponsor", source: "Manual"),
                CutSegment(start: 150, end: 180, category: "sponsor", source: "AI"),
                CutSegment(start: 350, end: 410, category: "sponsor", source: "Manual")]
    let timeline = SponsorTimeline(sourceDuration: 410, cuts: cuts)
    func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.01 }
    let verified = near(timeline.duration, 294)
        && near(timeline.sourceTime(forVisible: 0), 26)
        && near(timeline.visibleTime(forSource: 25), 0)
        && near(timeline.visibleTime(forSource: 27), 1)
        && near(timeline.visibleTime(forSource: 150), 124)
        && near(timeline.sourceTime(forVisible: 124), 180)
        && near(timeline.visibleTime(forSource: 390), 294)
        && near(timeline.sourceTime(forVisible: 294), 410)
        && timeline.endOfSkippedRange(atSource: 151) == 180
        && timeline.endOfSkippedRange(atSource: 190) == nil
        && !timeline.visibleSourceRange(2, 15)
        && timeline.visibleSourceRange(130, 145)
    print("SPONSOR TIMELINE \(verified ? "PASSED" : "FAILED") source=410 visible=\(timeline.duration) originalImmutable=true")
    fflush(stdout)
    exit(verified ? 0 : 4)
}

// Offline YouTube/RSS title matcher regression. The supplied file is a read-only yt-dlp
// channel listing; decode using the exact production parser and exercise the pure matcher.
// No YouTube network requests, downloads, or real library access.
// Usage: `PodCraft --youtube-match-test /tmp/podcraft-broski-channel-index.json`
if let i = arguments.firstIndex(of: "--youtube-match-test") {
    guard i + 1 < arguments.count else {
        print("YOUTUBE MATCH FAILED: expected --youtube-match-test <catalog-json>")
        exit(2)
    }
    let fixture = URL(fileURLWithPath: arguments[i + 1]).standardizedFileURL
    do {
        let data = try Data(contentsOf: fixture)
        let channel = URL(string: "https://www.youtube.com/channel/UCdEwstTO8WsTHCyzrCSfXCQ/videos")!
        let index = try YouTubeSource.decodeIndex(from: data, channelURL: channel)
        guard index.channelID == "UCdEwstTO8WsTHCyzrCSfXCQ", !index.videos.isEmpty else {
            throw NSError(domain: "PodCraftYouTubeTest", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "The fixture is not the expected Broski channel index"])
        }
        func rss(_ title: String, duration: Double) -> Episode {
            Episode(showID: UUID(), title: title, published: Date(), addedAt: Date(), duration: duration)
        }
        // Real RSS audio includes inserted ads: these are the observed saved-library
        // durations (143: 3476.37 s; 142: 3800 s), deliberately NOT the YouTube lengths
        // in the fixture (3368 and 3711 s). The matcher must tolerate that difference.
        let episode143 = rss("143: Finally Addressing Your Questions", duration: 3476.37)
        let episode142 = rss("142: The Millennial Episode", duration: 3800)
        let match143 = YouTubeSource.bestMatch(episode: episode143, in: index)
        let match142 = YouTubeSource.bestMatch(episode: episode142, in: index)
        let unrelated = YouTubeSource.bestMatch(
            episode: rss("99: Clearly Unrelated Test Podcast", duration: 3476.37), in: index)

        // An otherwise valid second upload of the same title and duration must make
        // matching ambiguous, not silently choose the first candidate in the catalog.
        let duplicate = YouTubeSource.Video(id: "AmbigVideo1", title: "Finally Addressing Your Questions",
                                            duration: 3368, channelID: index.channelID, uploadDate: nil)
        let ambiguousIndex = YouTubeSource.Index(channelID: index.channelID, channelTitle: index.channelTitle,
                                                  channelURL: index.channelURL, videos: index.videos + [duplicate])
        let ambiguous = YouTubeSource.bestMatch(episode: episode143, in: ambiguousIndex)
        let cases: [(label: String, actual: String?, expected: String?)] = [
            ("143 Finally Addressing Your Questions", match143?.id, "BaliszUp8hg"),
            ("142 The Millennial Episode", match142?.id, "2vpSK2ZcRUA"),
            ("unrelated RSS", unrelated?.id, nil),
            ("ambiguous RSS", ambiguous?.id, nil)
        ]
        // Also exercise official channel discovery's pure consensus rule. A channel
        // must match at least two different RSS episodes, and two equally credible
        // channels are ambiguity, not a license to choose whichever appeared first.
        let podcast = Show(title: "Broski Report", author: "PodCraft Test", hue: 0.5)
        let positiveChannel = YouTubeSource.bestChannel(
            show: podcast, episodes: [episode143, episode142], candidates: [index])
        let otherChannelID = "UC" + String(repeating: "B", count: 22)
        let rival = YouTubeSource.Index(
            channelID: otherChannelID, channelTitle: index.channelTitle,
            channelURL: URL(string: "https://www.youtube.com/channel/\(otherChannelID)/videos")!,
            videos: index.videos.map {
                YouTubeSource.Video(id: $0.id, title: $0.title, duration: $0.duration,
                                    channelID: otherChannelID, uploadDate: $0.uploadDate)
            })
        let ambiguousChannel = YouTubeSource.bestChannel(
            show: podcast, episodes: [episode143, episode142], candidates: [index, rival])
        for test in cases {
            print("YOUTUBE MATCH \(test.actual == test.expected ? "PASS" : "FAIL") \(test.label): expected=\(test.expected ?? "nil") actual=\(test.actual ?? "nil")")
        }
        print("YOUTUBE CHANNEL \(positiveChannel?.channelID == index.channelID ? "PASS" : "FAIL") unique official two-episode consensus")
        print("YOUTUBE CHANNEL \(ambiguousChannel == nil ? "PASS" : "FAIL") ambiguous competing channel")
        guard cases.allSatisfy({ $0.actual == $0.expected }),
              positiveChannel?.channelID == index.channelID, ambiguousChannel == nil else { exit(1) }
        print("YOUTUBE MATCH PASSED catalog=\(index.videos.count) channel=\(index.channelID) network=false library=false")
        exit(0)
    } catch {
        print("YOUTUBE MATCH FAILED: \(error.localizedDescription)")
        exit(1)
    }
}

// User-library YouTube discovery audit (opt-in, never automatic):
//   PodCraft --youtube-library-audit [~/Library/Application Support/PodCraft/Library.json]
//   PodCraft --youtube-library-audit [library.json] --latest-five
// READ ONLY: decode the existing Library.json directly. Do not construct a persistent
// Library, call its migration/repair routines, write files, or download video/audio.
// The real discovery and match APIs make network requests to verify official sources.
if let i = arguments.firstIndex(of: "--youtube-library-audit") {
    let latestFive = arguments.contains("--latest-five")
    let suppliedPath: String? = (i + 1 < arguments.count && !arguments[i + 1].hasPrefix("--"))
        ? arguments[i + 1] : nil
    let libraryURL = suppliedPath.map {
        URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL
    } ?? Library.storeURL
    Task { @MainActor in
        do {
            let bytes = try Data(contentsOf: libraryURL)
            let file = try JSONDecoder().decode(LibraryFile.self, from: bytes)
            let shows = file.shows.filter { !$0.isFiles }
            print("YOUTUBE LIBRARY AUDIT source=\(libraryURL.path) readonly=true mode=\(latestFive ? "latest-five-per-show" : "local-downloads") savedShows=\(file.shows.count) eligibleShows=\(shows.count) savedEpisodes=\(file.episodes.count)")
            fflush(stdout)

            var channelFound = 0, noChannel = 0, channelErrors = 0
            var episodeChecked = 0, matched = 0, noMatch = 0, matchErrors = 0
            var rssSampled = 0, feedErrors = 0, skippedNoFeed = 0
            for (position, show) in shows.enumerated() {
                let saved = file.episodes.filter { $0.showID == show.id }
                let locallyDownloaded = saved.filter { episode in
                    guard let path = episode.localFile else { return false }
                    return FileManager.default.isReadableFile(atPath: path)
                }.sorted { $0.published > $1.published }
                print("SHOW [\(position + 1)/\(shows.count)] \(show.title) | RSS=\(show.feedURL ?? "none") | saved=\(saved.count) localDownloaded=\(locallyDownloaded.count) | manualChannel=\(show.youtubeChannelURL ?? "none")")
                for e in locallyDownloaded.prefix(3) {
                    print("  LOCAL \(e.title) | duration=\(Int(e.duration))s | file=\(e.localFile.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "none")")
                }
                fflush(stdout)

                var toAudit = locallyDownloaded
                if latestFive {
                    // Audit the newest real feed releases for every saved show, regardless
                    // of download status. A feed may expose fewer than five items; fill
                    // those slots from that same show's saved RSS-derived entries.
                    toAudit = []
                    if let rssText = show.feedURL, let rssURL = URL(string: rssText),
                       ["http", "https", "feed"].contains(rssURL.scheme?.lowercased() ?? "") {
                        do {
                            let feed = try await FeedFetcher.fetch(rssURL)
                            toAudit = Array(feed.items.filter { $0.duration > 0 && !$0.title.isEmpty }
                                .sorted { $0.published > $1.published }.prefix(5)
                                .map { $0.episode(showID: show.id) })
                            rssSampled += toAudit.count
                            print("  LATEST-FIVE LIVE RSS=\(toAudit.count) feedTitle=\(feed.title)")
                        } catch {
                            feedErrors += 1
                            print("  LATEST-FIVE RSS ERROR \(error.localizedDescription); using saved RSS metadata")
                        }
                    } else {
                        skippedNoFeed += 1
                        print("  LATEST-FIVE no valid RSS feed; using saved episode metadata")
                    }
                    let seen = Set(toAudit.map { $0.title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current) })
                    var titles = seen
                    for episode in saved.sorted(by: { $0.published > $1.published }) where toAudit.count < 5 {
                        guard episode.duration > 0, !episode.title.isEmpty else { continue }
                        let title = episode.title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
                        if titles.insert(title).inserted { toAudit.append(episode) }
                    }
                    print("  LATEST-FIVE CHECK COUNT=\(toAudit.count) liveRSS=\(seen.count) savedFallback=\(toAudit.count - seen.count)")
                    for e in toAudit { print("  CHECK \(e.title) | duration=\(Int(e.duration))s | published=\(ISO8601DateFormatter().string(from:e.published))") }
                    if toAudit.count < 5 { print("  WARN fewer than five usable episodes for this show") }
                } else if toAudit.isEmpty {
                    // Do not substitute generic YouTube results for un-downloaded shows.
                    // Use at least two genuine feed entries parsed by FeedFetcher instead.
                    if let rssText = show.feedURL, let rssURL = URL(string: rssText),
                       ["http", "https", "feed"].contains(rssURL.scheme?.lowercased() ?? "") {
                        do {
                            let feed = try await FeedFetcher.fetch(rssURL)
                            toAudit = Array(feed.items
                                .filter { $0.duration > 0 && !$0.title.isEmpty }
                                .sorted { $0.published > $1.published }
                                .prefix(2).map { $0.episode(showID: show.id) })
                            rssSampled += toAudit.count
                            print("  SOURCE=RSS-FALLBACK samples=\(toAudit.count) feedTitle=\(feed.title)")
                            if toAudit.count < 2 {
                                print("  WARN fewer than two usable RSS episodes were available")
                            }
                            for e in toAudit {
                                print("  RSS \(e.title) | duration=\(Int(e.duration))s")
                            }
                        } catch {
                            feedErrors += 1
                            print("  RSS ERROR \(error.localizedDescription)")
                        }
                    } else {
                        skippedNoFeed += 1
                        print("  RSS UNAVAILABLE: no valid HTTP(S) feed link and no local episodes")
                    }
                }
                fflush(stdout)

                let index: YouTubeSource.Index
                do {
                    guard let discovered = try await YouTubeSource.discoverChannel(show: show) else {
                        noChannel += 1
                        print("  CHANNEL NO MATCH: insufficient official-channel evidence")
                        fflush(stdout)
                        continue
                    }
                    index = discovered
                    channelFound += 1
                    print("  CHANNEL MATCH \(index.channelTitle) | id=\(index.channelID) | url=\(index.channelURL.absoluteString) | uploads=\(index.videos.count)")
                } catch {
                    channelErrors += 1
                    print("  CHANNEL ERROR \(error.localizedDescription)")
                    fflush(stdout)
                    continue
                }
                fflush(stdout)

                for (number, e) in toAudit.enumerated() {
                    episodeChecked += 1
                    do {
                        if let video = try await YouTubeSource.match(
                            episode: e, channelURL: index.channelURL.absoluteString) {
                            matched += 1
                            let delta = abs(e.duration - video.duration)
                            print("  MATCH [\(number + 1)/\(toAudit.count)] RSS=\(e.title) -> video=\(video.id) \(video.title) | rss=\(Int(e.duration))s video=\(Int(video.duration))s delta=\(Int(delta))s date=\(video.uploadDate.map { ISO8601DateFormatter().string(from: $0) } ?? "unknown")")
                        } else {
                            noMatch += 1
                            print("  NO MATCH [\(number + 1)/\(toAudit.count)] RSS=\(e.title) | duration=\(Int(e.duration))s")
                        }
                    } catch {
                        matchErrors += 1
                        print("  MATCH ERROR [\(number + 1)/\(toAudit.count)] RSS=\(e.title) | \(error.localizedDescription)")
                    }
                    fflush(stdout)
                }
            }
            print("YOUTUBE LIBRARY AUDIT COMPLETE mode=\(latestFive ? "latest-five-per-show" : "local-downloads") eligibleShows=\(shows.count) officialChannels=\(channelFound) noChannel=\(noChannel) channelErrors=\(channelErrors) episodesChecked=\(episodeChecked) matched=\(matched) noMatch=\(noMatch) matchErrors=\(matchErrors) rssSampled=\(rssSampled) feedErrors=\(feedErrors) noFeed=\(skippedNoFeed) readonly=true")
            fflush(stdout)
            // Legitimate no-matches and remote/network errors are findings, not test-code crashes.
            exit(0)
        } catch {
            print("YOUTUBE LIBRARY AUDIT FAILED: could not read/decode input (\(error.localizedDescription))")
            fflush(stdout)
            exit(1)
        }
    }
    RunLoop.main.run()
}

// Diagnostic for ambiguous official channel detection. The candidate URLs and
// show selection are TEST ARGUMENTS, never a production channel override.
// Usage: --youtube-discovery-diagnostic <Library.json> <show-name> <channel1-URL> <channel2-URL>
if let i = arguments.firstIndex(of: "--youtube-discovery-diagnostic") {
    guard i + 4 < arguments.count else {
        print("YOUTUBE DISCOVERY DIAGNOSTIC FAILED: expected <library> <name> <channel1> <channel2>")
        exit(2)
    }
    let source = URL(fileURLWithPath: arguments[i+1]).standardizedFileURL
    let name = arguments[i+2]
    let urls = [arguments[i+3], arguments[i+4]]
    Task {
        do {
            let original = try Data(contentsOf: source)
            let file = try JSONDecoder().decode(LibraryFile.self, from: original)
            guard let show = file.shows.first(where: {
                $0.title.localizedCaseInsensitiveContains(name)
            }), let rss = show.feedURL, let rssURL = URL(string: rss) else { exit(3) }
            let liveFeed = try await FeedFetcher.fetch(rssURL)
            let episodes = liveFeed.items
                .filter { $0.duration > 90 && !$0.title.isEmpty &&
                    !$0.title.localizedCaseInsensitiveContains("Patreon") }
                .sorted { $0.published > $1.published }.prefix(36)
                .map { $0.episode(showID: show.id) }
            print("DISCOVERY LIVE RSS total=\(liveFeed.items.count) eligible=\(episodes.count)")
            for item in episodes.prefix(8) {
                print("  RSS \(item.title) duration=\(Int(item.duration)) published=\(item.published)")
            }
            var indexes: [YouTubeSource.Index] = []
            for url in urls {
                let index = try await YouTubeSource.channelIndex(from: url)
                let matches = episodes.compactMap { episode -> String? in
                    guard let video = YouTubeSource.bestMatch(episode: episode, in: index)
                    else { return nil }
                    return "\(episode.title) -> \(video.id) \(video.title)"
                }
                print("  INDEX \(index.channelID) title=\(index.channelTitle) uploads=\(index.videos.count) strictMatches=\(matches.count)")
                for match in matches.prefix(4) { print("    MATCH \(match)") }
                indexes.append(index)
            }
            let chosen = YouTubeSource.bestChannel(show: show, episodes: episodes,
                                                   candidates: indexes)
            print("DISCOVERY BEST CHANNEL \(chosen?.channelID ?? "none")")
            print("DISCOVERY INPUT UNCHANGED=\((try Data(contentsOf: source)) == original)")
            exit(0)
        } catch {
            print("YOUTUBE DISCOVERY DIAGNOSTIC FAILED: \(error.localizedDescription)")
            exit(1)
        }
    }
    RunLoop.main.run()
}

// Read-only full-catalog audit. Unlike the historic newest-five fixture, this
// exercises production official-channel discovery + the same bulk matcher that
// fills episode metadata across the entire saved RSS catalog. Missing videos
// are intentionally UNSUBSTANTIATED (not verified negatives) when the bounded
// channel index does not reach the oldest RSS publication dates.
// Usage: PodCraft --youtube-full-catalog-audit /path/to/isolated-snapshot.json
if let i = arguments.firstIndex(of: "--youtube-full-catalog-audit") {
    guard i + 1 < arguments.count else {
        print("FULL CATALOG AUDIT FAILED: expected <Library.json> read-only snapshot")
        exit(2)
    }
    let source = URL(fileURLWithPath: arguments[i + 1]).standardizedFileURL
    Task {
        do {
            let original = try Data(contentsOf: source)
            let file = try JSONDecoder().decode(LibraryFile.self, from: original)
            let onlyShow = arguments.firstIndex(of: "--only-show").flatMap { index in
                index + 1 < arguments.count ? arguments[index + 1] : nil
            }
            let shows = file.shows.filter {
                !$0.isFiles && $0.feedURL != nil &&
                    (onlyShow == nil || $0.title.localizedCaseInsensitiveContains(onlyShow!))
            }
            var found = 0, checked = 0, missed = 0, failures = 0
            print("FULL CATALOG AUDIT START shows=\(shows.count) savedEpisodes=\(file.episodes.count) readonly=true")
            fflush(stdout)
            for (n, show) in shows.enumerated() {
                try Task.checkCancellation()
                let episodes = file.episodes.filter { $0.showID == show.id && $0.audioURL != nil }
                    .sorted { $0.published > $1.published }
                checked += episodes.count
                do {
                    guard let index = try await YouTubeSource.discoverChannel(show: show) else {
                        print("  [\(n + 1)/\(shows.count)] \(show.title): official-channel-discovery=none episodes=\(episodes.count)")
                        failures += 1
                        fflush(stdout)
                        continue
                    }
                    let matches = try await YouTubeSource.catalogMatches(
                        episodes: episodes, channelURL: index.channelURL.absoluteString)
                    found += matches.count
                    missed += episodes.count - matches.count
                    let oldest = index.videos.compactMap(\.uploadDate).min().map {
                        ISO8601DateFormatter().string(from: $0)
                    } ?? "unknown"
                    print("  [\(n + 1)/\(shows.count)] \(show.title): rss=\(episodes.count) channel=\(index.channelID) indexedUploads=\(index.videos.count) oldestIndexedUpload=\(oldest) candidateMatches=\(matches.count) notYetMatched=\(episodes.count - matches.count)")
                    for episode in episodes where matches[episode.id] != nil {
                        guard let video = matches[episode.id] else { continue }
                        print("    CANDIDATE rss=\(episode.title) video=\(video.id) title=\(video.title) delta=\(Int(abs(video.duration - episode.duration)))s")
                    }
                } catch {
                    failures += 1
                    print("  [\(n + 1)/\(shows.count)] \(show.title): ERROR \(error.localizedDescription)")
                }
                fflush(stdout)
            }
            guard try Data(contentsOf: source) == original else {
                print("FULL CATALOG AUDIT FAILED: supplied snapshot was modified")
                exit(3)
            }
            print("FULL CATALOG AUDIT COMPLETE rssChecked=\(checked) provisionalOfficialMatches=\(found) notYetMatched=\(missed) showErrors=\(failures) inputUnchanged=true persistentLibrary=false")
            fflush(stdout)
            exit(failures == 0 ? 0 : 4)
        } catch {
            print("FULL CATALOG AUDIT FAILED: \(error.localizedDescription)")
            fflush(stdout)
            exit(1)
        }
    }
    RunLoop.main.run()
}

// Integration test for bounded *overlapping* RSS downloads. Pass a local
// fixture server serving four deliberately slow, distinct WAV files. The
// server measures concurrent transfers; this side checks every persisted
// episode was processed without ever touching the real media directory.
// Usage: PodCraft --concurrent-download-test http://127.0.0.1:<port>
if let i = arguments.firstIndex(of: "--concurrent-download-test") {
    guard i + 1 < arguments.count, let base = URL(string: arguments[i + 1]),
          base.host == "127.0.0.1" || base.host == "localhost" else {
        print("CONCURRENT DOWNLOAD FAILED: expected a local HTTP fixture server")
        exit(2)
    }
    MainActor.assumeIsolated {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
            "podcraft-concurrent-test-\(UUID().uuidString)", isDirectory: true)
        let library = Library(screenshot: true)
        library.settings.transcribe = false
        library.settings.generateChapters = false
        library.settings.removeSponsors = false
        library.settings.useSponsorBlock = false
        library.settings.aiProvider = .off
        let show = Show(title: "Local HTTP Concurrency Fixture", author: "PodCraft QA", hue: 0.5)
        library.shows = [show]
        for number in 1...4 {
            var episode = Episode(showID: show.id, title: "Download fixture \(number)",
                                  published: Date().addingTimeInterval(Double(-number)),
                                  addedAt: Date(), duration: 5)
            episode.audioURL = base.appendingPathComponent("episode\(number).wav").absoluteString
            episode.stage = .queued
            library.episodes.append(episode)
        }
        let processor = Processor(library: library, mediaDirectory: scratch)
        library.processor = processor
        let ids = library.episodes.map(\.id)
        Task { @MainActor in
            defer { processor.shutdown(); try? FileManager.default.removeItem(at: scratch) }
            let started = CFAbsoluteTimeGetCurrent()
            for _ in 0..<200 {
                let ready = ids.filter { library.episode($0)?.stage == .ready }.count
                let failed = ids.filter { library.episode($0)?.stage == .failed }.count
                if ready == ids.count || failed > 0 {
                    let elapsed = CFAbsoluteTimeGetCurrent() - started
                    let haveFiles = ids.allSatisfy { id in
                        guard let e = library.episode(id), let file = e.localFile else { return false }
                        return e.stage == .ready && file.hasPrefix(scratch.path) &&
                            FileManager.default.isReadableFile(atPath: file)
                    }
                    let passed = ready == ids.count && haveFiles
                    print(String(format: "CONCURRENT DOWNLOAD %@ ready=%d total=%d failed=%d elapsed=%.2fs isolatedMedia=true persistentLibrary=false",
                                 passed ? "PASSED" : "FAILED", ready, ids.count, failed, elapsed))
                    exit(passed ? 0 : 1)
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            print("CONCURRENT DOWNLOAD FAILED: exceeded 20s fixture limit stages=\(ids.compactMap { library.episode($0)?.stage.rawValue })")
            exit(1)
        }
    }
    RunLoop.main.run()
}

// Full RSS→official-channel→verified YouTube audio integration test: production
// Processor and YouTubeSource, using one *real* episode decoded from a read-only
// snapshot. A supplied channel URL is verified by production match(); no video
// IDs or show-specific mappings exist in the code. All output stays in /tmp.
// Usage: --youtube-processor-source-test <snapshot.json> <episode-UUID> <channel-URL>
if let i = arguments.firstIndex(of: "--youtube-processor-source-test") {
    guard i + 3 < arguments.count, let episodeID = UUID(uuidString: arguments[i + 2]) else {
        print("YOUTUBE PROCESSOR FAILED: expected snapshot.json, episode UUID, official channel URL")
        exit(2)
    }
    let source = URL(fileURLWithPath: (arguments[i + 1] as NSString).expandingTildeInPath)
    let channel = arguments[i + 3]
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
        "podcraft-youtube-processor-test-\(UUID().uuidString)", isDirectory: true)
    MainActor.assumeIsolated {
        let lib = Library(screenshot: true)
        lib.downloadsPaused = true
        lib.settings.transcribe = false
        lib.settings.generateChapters = false
        lib.settings.removeSponsors = false
        lib.settings.useSponsorBlock = false
        lib.settings.aiProvider = .off
        Task { @MainActor in
            defer { try? FileManager.default.removeItem(at: scratch) }
            do {
                let file = try JSONDecoder().decode(LibraryFile.self, from: Data(contentsOf: source))
                guard var episode = file.episodes.first(where: { $0.id == episodeID }),
                      var show = file.shows.first(where: { $0.id == episode.showID }),
                      episode.audioURL != nil else {
                    print("YOUTUBE PROCESSOR FAILED: snapshot has no matching feed episode")
                    exit(1)
                }
                show.youtubeChannelURL = channel
                show.youtubePlaybackVideo = false
                show.keepAvailable = 0
                episode.localFile = nil
                episode.originalLocalFile = nil
                episode.rssBackupLocalFile = nil
                episode.youtubeMediaID = nil
                episode.stage = .queued
                episode.played = false
                episode.autoDownloaded = false
                episode.position = 0
                episode.transcript = []
                episode.chapters = []
                episode.cuts = []
                lib.shows = [show]
                lib.episodes = [episode]
                try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
                let processor = Processor(library: lib, mediaDirectory: scratch)
                lib.processor = processor
                let started = CFAbsoluteTimeGetCurrent()
                await processor.processImmediately(episodeID)
                processor.shutdown()
                guard let updated = lib.episode(episodeID), updated.stage == .ready,
                      let mediaID = updated.youtubeMediaID,
                      let local = updated.localFile, local.hasPrefix(scratch.path),
                      local.contains("-youtube-\(mediaID)"), local.hasSuffix(".m4a"),
                      FileManager.default.fileExists(atPath: local) else {
                    print("YOUTUBE PROCESSOR FAILED: source fell back to RSS or failed. stage=\(lib.episode(episodeID)?.stage.rawValue ?? "missing") youtubeID=\(lib.episode(episodeID)?.youtubeMediaID ?? "nil") note=\(lib.episode(episodeID)?.note ?? "none")")
                    exit(1)
                }
                let asset = AVURLAsset(url: URL(fileURLWithPath: local))
                let length = try await asset.load(.duration).seconds
                let audioTracks = try await asset.loadTracks(withMediaType: .audio)
                guard length.isFinite && length > 60 && !audioTracks.isEmpty else {
                    print("YOUTUBE PROCESSOR FAILED: matched source not AVFoundation-playable")
                    exit(1)
                }
                print(String(format: "YOUTUBE PROCESSOR PASSED rssEpisode=%@ verifiedYouTubeID=%@ source=YouTube duration=%.1fs sourceChanged=true elapsed=%.2fs isolatedMedia=true persistentLibrary=false",
                             episode.title, mediaID, length, CFAbsoluteTimeGetCurrent() - started))
                exit(0)
            } catch {
                print("YOUTUBE PROCESSOR FAILED: \(error.localizedDescription)")
                exit(1)
            }
        }
    }
    RunLoop.main.run()
}

// Verify caption timestamp parsing without making a YouTube request or touching
// a real library. Real service failures (HTTP 429) must not become false passes.
if arguments.contains("--youtube-vtt-parser-test") {
    let sample = """
    WEBVTT

    00:00:00.000 --> 00:00:03.000
    Hello

    00:00:02.800 --> 00:00:06.000
    Hello world

    00:00:06.000 --> 00:00:09.000
    This is a test

    00:00:09.000 --> 00:00:21.000
    And this ends

    """
    let cues = YouTubeSource.parseVTT(Data(sample.utf8), duration: 60)
    guard let cues, cues.count == 3,
          cues[0].text == "Hello world", cues[0].start == 0,
          cues[1].start == 6, cues.last?.end == 21,
          YouTubeSource.parseVTT(Data("HTTP 429".utf8), duration: 60) == nil else {
        print("YOUTUBE VTT PARSER FAILED: rolling captions, time alignment or malformed response")
        exit(1)
    }
    print("YOUTUBE VTT PARSER PASSED sourceClock=true rollingDedup=true malformedRejected=true")
    exit(0)
}

// Explicit opt-in: try actual captions for one existing verified YouTube recording
// from a supplied JSON fixture. The file is read directly and never persisted.
if let index = arguments.firstIndex(of: "--youtube-captions-test"), index + 2 < arguments.count {
    let fileURL = URL(fileURLWithPath: arguments[index + 1])
    let requestedID = arguments[index + 2]
    Task {
        do {
            let before = try Data(contentsOf: fileURL)
            let library = try JSONDecoder().decode(LibraryFile.self, from: before)
            guard let episode = library.episodes.first(where: {
                $0.id.uuidString.caseInsensitiveCompare(requestedID) == .orderedSame
            }), let videoID = episode.youtubeMediaID,
                  episode.youtubeID == videoID,
                  let show = library.shows.first(where: { $0.id == episode.showID }),
                  let channel = show.youtubeChannelURL else {
                print("YOUTUBE CAPTIONS TEST FAILED: requires a verified downloaded YouTube episode in the supplied fixture")
                exit(2)
            }
            let lines = try await YouTubeSource.captions(
                episode: episode, channelURL: channel, videoID: videoID,
                language: episode.transcriptLanguage ?? episode.language ?? show.language,
                duration: episode.duration
            )
            let unchanged = try Data(contentsOf: fileURL) == before
            guard unchanged else {
                print("YOUTUBE CAPTIONS TEST FAILED: input library changed")
                exit(3)
            }
            if let lines {
                print("YOUTUBE CAPTIONS PASSED verifiedVideo=\(videoID) source=YouTube-VTT cues=\(lines.count) readonly=true")
            } else {
                print("YOUTUBE CAPTIONS UNAVAILABLE verifiedVideo=\(videoID) fallback=Apple-SpeechAnalyzer readonly=true")
            }
            exit(0)
        } catch {
            print("YOUTUBE CAPTIONS TEST ERROR: \(error.localizedDescription)")
            exit(1)
        }
    }
    RunLoop.main.run()
}

// Exercise the exact production YouTube audio downloader in a disposable
// directory. A successful source must be full-length and AVFoundation-playable.
// Usage: PodCraft --youtube-audio-download-test <verified-video-id>
if let i = arguments.firstIndex(of: "--youtube-audio-download-test") {
    guard i + 1 < arguments.count else {
        print("YOUTUBE AUDIO DOWNLOAD FAILED: expected a YouTube video ID")
        exit(2)
    }
    let videoID = arguments[i + 1]
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
        "podcraft-youtube-audio-test-\(UUID().uuidString)", isDirectory: true)
    Task {
        defer { try? FileManager.default.removeItem(at: scratch) }
        do {
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            let started = CFAbsoluteTimeGetCurrent()
            let media = try await YouTubeSource.download(videoID: videoID, video: false,
                                                       destinationFolder: scratch, episodeID: UUID())
            let asset = AVURLAsset(url: media)
            async let duration = asset.load(.duration)
            async let tracks = asset.loadTracks(withMediaType: .audio)
            let (length, audioTracks) = try await (duration, tracks)
            let bytes = (try FileManager.default.attributesOfItem(atPath: media.path)[.size] as? NSNumber)?.int64Value ?? 0
            guard bytes > 10_000, !audioTracks.isEmpty, length.seconds.isFinite,
                  length.seconds > 60, media.pathExtension == "m4a" else {
                print("YOUTUBE AUDIO DOWNLOAD FAILED: unplayable result size=\(bytes) tracks=\(audioTracks.count) duration=\(length.seconds) file=\(media.lastPathComponent)")
                exit(1)
            }
            let elapsed = CFAbsoluteTimeGetCurrent() - started
            print(String(format: "YOUTUBE AUDIO DOWNLOAD PASSED videoID=%@ bytes=%lld duration=%.1fs tracks=%d elapsed=%.2fs format=M4A disposable=true",
                         videoID, bytes, length.seconds, audioTracks.count, elapsed))
            exit(0)
        } catch {
            print("YOUTUBE AUDIO DOWNLOAD FAILED videoID=\(videoID) reason=\(error.localizedDescription)")
            exit(1)
        }
    }
    RunLoop.main.run()
}

// Exercise the real AVPlayer source-handoff lifecycle using two disposable WAVs
// and synthetic transcripts with a regional RSS ad. No actual user data/media.
if let i = arguments.firstIndex(of: "--contextual-source-handoff-test") {
    guard i + 2 < arguments.count else {
        print("CONTEXTUAL SOURCE HANDOFF FAILED: expected <RSS WAV> <YouTube WAV>")
        exit(2)
    }
    let original = arguments[i + 1], matched = arguments[i + 2]
    Task { @MainActor in
        let status = await SourceHandoffRegression.run(oldFile: original, youtubeFile: matched)
        exit(status)
    }
    RunLoop.main.run()
}

if let i = arguments.firstIndex(of: "--real-recognition-handoff-test") {
    guard i + 2 < arguments.count else {
        print("REAL RECOGNITION HANDOFF FAILED: expected <local audio> <isolated transcript library>")
        exit(2)
    }
    let sourceFile = arguments[i + 1], fixtureFile = arguments[i + 2]
    Task { @MainActor in
        let result = await SourceHandoffRegression.runRecognitionHandoff(
            localAudio: sourceFile, transcriptFixture: fixtureFile)
        exit(result)
    }
    RunLoop.main.run()
}

// Validate the bounded, temporary source-speech window with Apple's real
// recognizer. This explicit test uses a local fixture and NEVER the user's
// Library.json or media output folders.
if let i = arguments.firstIndex(of: "--source-context-speech-test") {
    guard i + 2 < arguments.count, let time = Double(arguments[i + 2]) else {
        print("SOURCE CONTEXT SPEECH FAILED: expected <local audio> <source second>")
        exit(2)
    }
    let path = arguments[i + 1]
    let input = URL(string: path).flatMap { url in
        ["http", "https"].contains(url.scheme?.lowercased() ?? "") ? url : nil
    } ?? URL(fileURLWithPath: path)
    Task { @MainActor in
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(
            "podcraft-context-asr-test-\(UUID().uuidString)", isDirectory: true)
        let prefsName = "org.podcraft.context-asr.\(UUID().uuidString)"
        guard let prefs = UserDefaults(suiteName: prefsName) else { exit(2) }
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let library = Library(screenshot: false,
                              isolatedStorageURL: temp.appendingPathComponent("Library.json"),
                              isolatedPreferences: prefs)
        let processor = Processor(library: library, mediaDirectory: temp.appendingPathComponent("Media"))
        do {
            let lines = try await processor.transcribeSourceContext(
                from: input, near: time, language: "en-US")
            if let diagnosticOutput = ProcessInfo.processInfo.environment["PODCRAFT_CONTEXT_ASR_OUTPUT"],
               !diagnosticOutput.isEmpty {
                try? JSONEncoder().encode(lines).write(
                    to: URL(fileURLWithPath: diagnosticOutput), options: .atomic)
            }
            let plausible = lines.count >= 3 &&
                (lines.first?.start ?? -.infinity) >= max(0, time - 31) &&
                (lines.last?.end ?? .infinity) <= time + 78
            print("SOURCE CONTEXT SPEECH \(plausible ? "PASSED" : "FAILED") words=\(lines.count) first=\(lines.first?.start ?? -1) last=\(lines.last?.end ?? -1) readonly=true isolated=true")
            processor.shutdown()
            prefs.removePersistentDomain(forName: prefsName)
            try? FileManager.default.removeItem(at: temp)
            exit(plausible ? 0 : 4)
        } catch {
            print("SOURCE CONTEXT SPEECH FAILED: \(error.localizedDescription)")
            processor.shutdown()
            prefs.removePersistentDomain(forName: prefsName)
            try? FileManager.default.removeItem(at: temp)
            exit(3)
        }
    }
    RunLoop.main.run()
}

// Native Player regression: start a verified *cached YouTube AUDIO* recording,
// explicitly request its video, and adopt the live HTTPS video stream at the
// same source passage. Never download MP4 or touch the user's real Library.
// Usage: --youtube-stream-handoff-test <isolated Broski Library.json> <local M4A>
if let i = arguments.firstIndex(of: "--youtube-stream-handoff-test") {
    guard i + 2 < arguments.count else {
        print("YOUTUBE STREAM HANDOFF FAILED: expected <fixture Library.json> <cached M4A>")
        exit(2)
    }
    let fixtureURL = URL(fileURLWithPath: arguments[i + 1]).standardizedFileURL
    let audioURL = URL(fileURLWithPath: arguments[i + 2]).standardizedFileURL
    Task { @MainActor in
        do {
            let original = try Data(contentsOf: fixtureURL)
            let fixture = try JSONDecoder().decode(LibraryFile.self, from: original)
            guard FileManager.default.isReadableFile(atPath: audioURL.path),
                  let e = fixture.episodes.first(where: {
                      $0.youtubeID != nil && $0.youtubeMediaID == $0.youtubeID && !$0.transcript.isEmpty
                  }), let videoID = e.youtubeID,
                  let show = fixture.shows.first(where: { $0.id == e.showID }),
                  let channel = show.youtubeChannelURL else {
                print("YOUTUBE STREAM HANDOFF FAILED: no cached verified YouTube audio/transcript fixture")
                exit(2)
            }
            let lib = Library(screenshot: true)
            lib.settings.transcribe = false
            lib.settings.generateChapters = false
            lib.settings.removeSponsors = false
            lib.settings.useSponsorBlock = false
            lib.settings.aiProvider = .off
            lib.shows = [show]
            var source = e
            source.stage = .ready
            source.played = false
            source.position = 180
            source.localFile = audioURL.path
            source.originalLocalFile = audioURL.path
            source.isVideo = false
            source.youtubeMediaID = videoID
            source.youtubeMatchState = .matched
            source.youtubeMatchChannelURL = channel
            lib.episodes = [source]
            let player = Player(library: lib, suppressUserSessionWrites: true)
            player.testMute = true
            player.playYouTubeVideo(source.id)
            let initialWasAudio = player.videoPlayer == nil && player.isPlaying
            let until = Date().addingTimeInterval(50)
            while player.videoPlayer == nil && Date() < until {
                try await Task.sleep(for: .milliseconds(250))
            }
            guard let vp = player.videoPlayer, player.isPlaying,
                  let item = vp.currentItem, initialWasAudio else {
                player.shutdown()
                print("YOUTUBE STREAM HANDOFF FAILED: verified stream never replaced audible source")
                exit(3)
            }
            let readyUntil = Date().addingTimeInterval(20)
            while item.status != .readyToPlay && Date() < readyUntil {
                if item.status == .failed { break }
                try await Task.sleep(for: .milliseconds(200))
            }
            let originalTime = vp.currentTime().seconds
            try await Task.sleep(for: .seconds(2))
            let advanced = vp.currentTime().seconds - originalTime
            let unchanged = try Data(contentsOf: fixtureURL) == original
            let good = item.status == .readyToPlay && originalTime > 165 &&
                advanced > 0.3 && unchanged && player.videoPlayer === player.avPlayerForRoutes
            player.shutdown()
            print(String(format:
                "YOUTUBE STREAM HANDOFF %@ video=%@ source=verified-audio->HTTPS-stream sourceTime=%.1fs advance=%.2fs fullVideoDownload=false isolated=%@",
                good ? "PASSED" : "FAILED", videoID, originalTime, advanced,
                unchanged ? "true" : "false"))
            exit(good ? 0 : 4)
        } catch {
            print("YOUTUBE STREAM HANDOFF FAILED: \(error.localizedDescription)")
            exit(1)
        }
    }
    RunLoop.main.run()
}

// Streaming smoke test against a real, verified official YouTube upload.
// No PodCraft Library or media folder is opened, and no video is downloaded.
// Usage: PodCraft --youtube-video-stream-test <video ID> <official channel ID>
if let i = arguments.firstIndex(of: "--youtube-video-stream-test") {
    guard i + 2 < arguments.count else {
        print("YOUTUBE VIDEO STREAM FAILED: expected <video ID> <official channel ID>")
        exit(2)
    }
    let videoID = arguments[i + 1], channelID = arguments[i + 2]
    Task { @MainActor in
        do {
            print("YOUTUBE VIDEO STREAM CHECK resolving verified URL (no download)")
            fflush(stdout)
            let started = Date()
            let stream = try await YouTubeSource.playableStream(videoID: videoID,
                                                                channelID: channelID)
            let resolvedSeconds = Date().timeIntervalSince(started)
            print(String(format: "YOUTUBE VIDEO STREAM CHECK resolved in %.2fs; preparing native AVPlayer", resolvedSeconds))
            fflush(stdout)
            let av = AVPlayer(url: stream.url)
            av.isMuted = true
            av.volume = 0
            let timeout = Date().addingTimeInterval(28)
            while av.currentItem?.status != .readyToPlay && Date() < timeout {
                if av.currentItem?.status == .failed { break }
                try await Task.sleep(for: .milliseconds(200))
            }
            guard av.currentItem?.status == .readyToPlay else {
                throw av.currentItem?.error ?? NSError(domain: "PodCraftStream", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "AVPlayer could not prepare direct media stream"])
            }
            print("YOUTUBE VIDEO STREAM CHECK native player ready; testing clock advancement")
            fflush(stdout)
            av.play()
            let startTime = av.currentTime().seconds
            try await Task.sleep(for: .seconds(3))
            let advanced = av.currentTime().seconds - startTime
            av.pause()
            guard advanced > 0.25, stream.duration > 60,
                  stream.url.scheme == "https" else {
                print("YOUTUBE VIDEO STREAM FAILED: ready but playback did not advance")
                exit(3)
            }
            print(String(format:
                "YOUTUBE VIDEO STREAM PASSED verified=%@ channel=%@ duration=%.1f chapters=%d resolved=%.2fs advance=%.2fs fullDownload=false isolated=true",
                videoID, channelID, stream.duration, stream.chapters.count,
                resolvedSeconds, advanced))
            exit(0)
        } catch {
            print("YOUTUBE VIDEO STREAM FAILED: \(error.localizedDescription)")
            exit(1)
        }
    }
    RunLoop.main.run()
}

// Opt-in local video playback regression: `PodCraft --video-playback-test <local MP4>`.
// The screenshot-only Library is intentionally empty and nonpersistent. Never attach
// the real user's Library, mutate the video, or start the download/processing pipeline.
if let i = arguments.firstIndex(of: "--video-playback-test") {
    guard i + 1 < arguments.count else {
        print("VIDEO PLAYBACK FAILED: expected --video-playback-test <local MP4>")
        exit(2)
    }
    let source = URL(fileURLWithPath: arguments[i + 1]).standardizedFileURL
    MainActor.assumeIsolated {
        let lib = Library(screenshot: true)
        lib.downloadsPaused = true
        lib.settings.transcribe = false
        lib.settings.generateChapters = false
        lib.settings.aiProvider = .off
        let player = Player(library: lib)
        player.testMute = true
        Task { @MainActor in
            do {
                guard source.pathExtension.lowercased() == "mp4",
                      FileManager.default.isReadableFile(atPath: source.path) else {
                    throw NSError(domain: "PodCraftVideoTest", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "The MP4 must be an existing local readable file"])
                }
                let asset = AVURLAsset(url: source)
                async let audioTracks = asset.loadTracks(withMediaType: .audio)
                async let videoTracks = asset.loadTracks(withMediaType: .video)
                async let assetPlayable = asset.load(.isPlayable)
                async let assetDuration = asset.load(.duration)
                let (audio, video, playable, duration) = try await (audioTracks, videoTracks, assetPlayable, assetDuration)
                guard !audio.isEmpty, !video.isEmpty, playable,
                      duration.seconds.isFinite, duration.seconds > 0 else {
                    throw NSError(domain: "PodCraftVideoTest", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: "The MP4 must contain playable audio and video tracks"])
                }
                let show = Show(title: "YouTube Video Smoke", author: "PodCraft Test", hue: 0.55)
                var episode = Episode(showID: show.id, title: "Local MP4 Playback Test",
                                      published: Date(), addedAt: Date(), duration: duration.seconds)
                episode.isVideo = true
                episode.localFile = source.path
                episode.originalLocalFile = source.path
                episode.stage = .ready
                lib.shows = [show]
                lib.episodes = [episode]
                player.play(episode.id)
                guard player.episodeID == episode.id, let videoPlayer = player.videoPlayer,
                      let item = videoPlayer.currentItem,
                      (item.asset as? AVURLAsset)?.url.standardizedFileURL == source,
                      try await item.asset.load(.isPlayable) else {
                    throw NSError(domain: "PodCraftVideoTest", code: 3,
                                  userInfo: [NSLocalizedDescriptionKey: "Player.play did not attach a playable video AVPlayerItem"])
                }
                // AVPlayerItem status resolves asynchronously. Await the media backend without
                // equating a successfully constructed AVPlayer with actual playability.
                var status = player.videoPlayer?.currentItem?.status ?? .unknown
                for _ in 0..<24 where status == .unknown {
                    try await Task.sleep(for: .milliseconds(125))
                    status = player.videoPlayer?.currentItem?.status ?? .unknown
                }
                guard status == .readyToPlay else {
                    throw NSError(domain: "PodCraftVideoTest", code: 4,
                                  userInfo: [NSLocalizedDescriptionKey: "AVPlayerItem did not reach readyToPlay (status=\(status.rawValue))"])
                }
                print(String(format: "VIDEO PLAYBACK PASSED source=%@ duration=%.2fs audioTracks=%d videoTracks=%d videoPlayer=true readyToPlay=true persistentLibrary=false",
                             source.lastPathComponent, duration.seconds, audio.count, video.count))
                player.shutdown()
                exit(0)
            } catch {
                print("VIDEO PLAYBACK FAILED: \(error.localizedDescription)")
                player.shutdown()
                exit(1)
            }
        }
    }
    RunLoop.main.run()
}

// AVPlayer completion regression on a three-episode chain. The test uses an
// in-memory, nonpersistent library and checks both automatic queue transitions.
if let i = arguments.firstIndex(of: "--queue-completion-test"), i + 3 < arguments.count {
    let firstURL = URL(fileURLWithPath: arguments[i + 1])
    let nextURL = URL(fileURLWithPath: arguments[i + 2])
    let lastURL = URL(fileURLWithPath: arguments[i + 3])
    let tailCut = arguments.contains("--tail-cut")
    MainActor.assumeIsolated {
        let lib = Library(screenshot: true)
        let player = Player(library: lib)
        player.testMute = true
        Task { @MainActor in
            do {
                let firstLength = try await AVURLAsset(url: firstURL).load(.duration).seconds
                let secondLength = try await AVURLAsset(url: nextURL).load(.duration).seconds
                let thirdLength = try await AVURLAsset(url: lastURL).load(.duration).seconds
                guard firstLength > 0.2, secondLength > 0.2, thirdLength > 0.2 else { throw NSError(domain: "QueueTest", code: 1) }
                let show = Show(title: "Completion Queue Test", author: "PodCraft", hue: 0.4)
                lib.shows = [show]
                var first = Episode(showID: show.id, title: "First Queued Test", published: Date(), addedAt: Date(), duration: firstLength)
                var second = Episode(showID: show.id, title: "Second Queued Test", published: Date(), addedAt: Date(), duration: secondLength)
                var third = Episode(showID: show.id, title: "Third Queued Test", published: Date(), addedAt: Date(), duration: thirdLength)
                first.localFile = firstURL.path; first.originalLocalFile = firstURL.path; first.stage = .ready
                if tailCut {
                    first.cuts = [CutSegment(start: firstLength * 0.65, end: firstLength,
                                             category: "sponsor", source: "Manual")]
                }
                second.localFile = nextURL.path; second.originalLocalFile = nextURL.path; second.stage = .ready
                third.localFile = lastURL.path; third.originalLocalFile = lastURL.path; third.stage = .ready
                lib.episodes = [first, second, third]
                player.queue = [second.id, third.id]
                player.play(first.id)
                var sawSecond = false
                var reachedThird = false
                for _ in 0..<120 {
                    if lib.episode(first.id)?.played == true && player.episodeID == second.id { sawSecond = true }
                    if lib.episode(first.id)?.played == true && lib.episode(second.id)?.played == true && player.episodeID == third.id {
                        reachedThird = true
                        break
                    }
                    try await Task.sleep(for: .milliseconds(100))
                }
                let nextPlaying = player.isPlaying
                let queueConsumed = player.queue.isEmpty
                let finishCount = lib.metrics.episodesFinished
                let firstPosition = lib.episode(first.id)?.position ?? -1
                let secondPosition = lib.episode(second.id)?.position ?? -1
                player.shutdown()
                let expectedFirst = first.playbackDuration
                guard sawSecond && reachedThird && nextPlaying && queueConsumed && finishCount == 2 &&
                      abs(firstPosition - expectedFirst) < 0.15 && abs(secondPosition - secondLength) < 0.15 else {
                    print("QUEUE COMPLETION FAILED firstPlayed=\(lib.episode(first.id)?.played == true) secondPlayed=\(lib.episode(second.id)?.played == true) reachedSecond=\(sawSecond) reachedThird=\(reachedThird) playing=\(nextPlaying) remainingQueue=\(player.queue.count) finishes=\(finishCount) positions=\(firstPosition),\(secondPosition)")
                    exit(1)
                }
                print("QUEUE COMPLETION PASSED firstPlayed=true secondPlayed=true thirdStarted=true queueConsumed=true tailCut=\(tailCut) finishedCount=2 persistedLibrary=false")
                exit(0)
            } catch {
                print("QUEUE COMPLETION FAILED error=\(error.localizedDescription)")
                player.shutdown()
                exit(1)
            }
        }
    }
    RunLoop.main.run()
}

if let i = arguments.firstIndex(of: "--process-test"), i + 1 < arguments.count {
    let url = URL(fileURLWithPath: arguments[i + 1])
    Task {
        do {
            let d = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
            // PODCRAFT_LANG picks the transcript language for the check (as an episode's or show's language would).
            let lines = try await AIService.transcribe(file: url, duration: d,
                                                       language: ProcessInfo.processInfo.environment["PODCRAFT_LANG"]) { _ in }
            print("TRANSCRIPT \(lines.count) lines")
            for l in lines { print(String(format: "%6.1f  ", l.start) + l.text) }
            let found = try await AIService.chapters(lines: lines, duration: d, provider: .onDevice, model: "", findSponsors: true)
            for c in found.chapters { print("CHAPTER \(Fmt.clock(c.start)) \(c.title)") }
            for s in found.sponsors { print("SPONSOR \(Fmt.clock(s.start))-\(Fmt.clock(s.end))") }
            if !found.sponsors.isEmpty {
                let timeline = SponsorTimeline(sourceDuration: d, cuts: found.sponsors)
                print(String(format: "SKIP ONLY %.1f s original -> %.1f s visible (source unchanged)",
                             d, timeline.duration))
            }
            exit(0)
        } catch { print("FAILED: \(error.localizedDescription)"); exit(1) }
    }
    RunLoop.main.run()
}

// Developer check: `PodCraft --chapter-filter-test <audio file>` validates the
// source-preserving filter: one invisible timeline span, original timestamps and bytes intact.
if let i = arguments.firstIndex(of: "--chapter-filter-test"), i + 1 < arguments.count {
    let source = URL(fileURLWithPath: arguments[i + 1])
    MainActor.assumeIsolated {
        let lib = Library(screenshot: true)
        lib.downloadsPaused = true
        lib.settings.removeSponsors = false
        lib.settings.useSponsorBlock = false
        lib.settings.transcribe = false
        lib.settings.generateChapters = false
        lib.settings.aiProvider = .off
        let processor = Processor(library: lib)
        lib.processor = processor
        Task { @MainActor in
            do {
                let duration = try await AVURLAsset(url: source).load(.duration).seconds
                guard duration.isFinite, duration >= 6 else {
                    throw NSError(domain: "PodCraftTest", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "Test audio must be at least 6 seconds long"])
                }
                let show = Show(title: "Filter Test", author: "PodCraft", hue: 0.6,
                                excludedChapterTerms: "sponsor")
                lib.shows = [show]
                let oneThird = duration / 3
                var episode = Episode(showID: show.id, title: "Filter Test", published: Date(),
                                      addedAt: Date(), duration: duration)
                episode.localFile = source.path
                episode.stage = .queued
                episode.chapters = [Chapter(start: 0, title: "Intro"),
                                    Chapter(start: oneThird, title: "Sponsor break"),
                                    Chapter(start: oneThird * 2, title: "Main story")]
                episode.transcript = [TranscriptLine(start: 1, end: oneThird - 1, text: "intro"),
                                      TranscriptLine(start: oneThird + 1, end: oneThird * 2 - 1, text: "advert"),
                                      TranscriptLine(start: oneThird * 2 + 1, end: duration - 1, text: "story")]
                lib.episodes = [episode]
                let originalBytes = try Data(contentsOf: source)

                await processor.processImmediately(episode.id)
                guard let result = lib.episode(episode.id), result.stage == .ready,
                      !result.cutApplied, result.localFile == source.path,
                      result.chapters.count == 3, result.transcript.count == 3,
                      abs(result.duration - duration) < 0.2,
                      abs(result.playbackDuration - oneThird * 2) < 0.2,
                      result.playbackChapters.map(\.title) == ["Intro", "Main story"],
                      result.playbackTranscript.map(\.text) == ["intro", "story"],
                      abs((result.playbackChapters.last?.start ?? -1) - oneThird) < 0.1,
                      try Data(contentsOf: source) == originalBytes else {
                    throw NSError(domain: "PodCraftTest", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: "Chapter filter output did not match expectations"])
                }
                print(String(format: "CHAPTER FILTER PASS original=%.2f s visible=%.2f s skipped=%.2f s unchanged=true",
                             result.duration, result.playbackDuration, result.adSecondsRemoved))
                exit(0)
            } catch {
                print("CHAPTER FILTER FAILED: \(error.localizedDescription)")
                exit(1)
            }
        }
    }
    RunLoop.main.run()
}

// Developer check: `PodCraft --library-test <feed file or link>` adds the show to an empty, unsaved library,
// prints what is listed and what gets downloaded, lets the newest one process, then exits.
if let i = arguments.firstIndex(of: "--library-test"), i + 1 < arguments.count {
    let arg = arguments[i + 1]
    let url = arg.hasPrefix("http") ? URL(string: arg)! : URL(fileURLWithPath: arg)
    MainActor.assumeIsolated {
        let lib = Library(screenshot: true)
        let processor = Processor(library: lib)
        lib.processor = processor
        Task { @MainActor in
            do {
                let parsed = try await FeedFetcher.fetch(url)
                let show = Show(title: parsed.title, author: parsed.author, feedURL: url.absoluteString,
                                hue: 0.6, keepAvailable: lib.settings.defaultAvailable)
                let id = lib.addShow(show, items: parsed.items)
                print("SHOW \(parsed.title) keepAvailable=\(lib.show(id)!.keepAvailable) feed=\(lib.show(id)!.feedID == nil ? "none" : "set")")
                if let terms = ProcessInfo.processInfo.environment["PODCRAFT_SKIP_TERMS"], var s = lib.show(id) {
                    s.excludedTitleTerms = terms
                    s.title = "Edited Title"
                    lib.updateShow(s)
                    print("EDITED title=\(lib.show(id)!.title) skip=\(terms)")
                }
                for e in lib.episodes(inShow: id) {
                    print("  \(e.title): \(e.stage.rawValue) skipped=\(lib.isSkipped(e)) art=\(e.artworkURL ?? "-")")
                }
                for _ in 0..<120 {
                    try await Task.sleep(for: .seconds(1))
                    if !lib.episodes.contains(where: { $0.stage.isWorking }) { break }
                }
                print("AFTER PROCESSING")
                for e in lib.episodes(inShow: id) {
                    print("  \(e.title): \(e.stage.rawValue) chapters=\(e.chapters.count) cut=\(Int(e.adSecondsRemoved))s \(e.note ?? "")")
                    for c in e.chapters { print("    CHAPTER \(Fmt.clock(c.start)) \(c.title)") }
                }
                lib.setKeepAvailable(2, forShow: id)
                print("KEEP 2 -> " + lib.episodes(inShow: id).map { $0.stage.rawValue }.joined(separator: ","))
                exit(0)
            } catch { print("FAILED \(error.localizedDescription)"); exit(1) }
        }
    }
    RunLoop.main.run()
}

// Developer check: `PodCraft --language-test <Library.json>` prints, read-only, the language each show's episodes
// would be transcribed in and whether an existing transcript looks like the wrong language.
if let i = arguments.firstIndex(of: "--language-test"), i + 1 < arguments.count {
    let url = URL(fileURLWithPath: arguments[i + 1])
    MainActor.assumeIsolated {
        let lib = Library(screenshot: true)
        guard let file = try? JSONDecoder().decode(LibraryFile.self, from: Data(contentsOf: url)) else { print("NO LIBRARY"); exit(1) }
        lib.shows = file.shows; lib.episodes = file.episodes
        for s in lib.shows {
            let eps = lib.episodes(inShow: s.id)
            let withTranscript = eps.filter { !$0.transcript.isEmpty }
            let wrong = withTranscript.filter { lib.transcriptLooksWrongLanguage($0) }.count
            print("SHOW \(s.title) tag=\(s.language ?? "-") expected=\(eps.first.flatMap { lib.expectedLanguage(for: $0) } ?? "-") transcripts=\(withTranscript.count) wrongLanguage=\(wrong)")
        }
        exit(0)
    }
}

// Developer check: `PodCraft --show-details-test <Library.json>` loads the show-page details (directory match,
// ratings & reviews, hosts & guests, information) for shows in a library file, read-only, and prints them.
if let i = arguments.firstIndex(of: "--show-details-test"), i + 1 < arguments.count {
    let url = URL(fileURLWithPath: arguments[i + 1])
    Task { @MainActor in
        guard let file = try? JSONDecoder().decode(LibraryFile.self, from: Data(contentsOf: url)) else { print("NO LIBRARY"); exit(1) }
        for show in file.shows.filter({ $0.feedURL != nil }).prefix(3) {
            await ShowInfoStore.shared.load(show, force: true)
            let info = ShowInfoStore.shared.info(for: show)
            print("SHOW \(show.title) appleID=\(info?.appleID.map(String.init) ?? "none") genres=\(info?.genres ?? []) episodes=\(info?.episodeCount ?? -1)")
            print("  rating=\(info?.averageRating.map { String(format: "%.1f", $0) } ?? "-") reviews=\(info?.reviews.count ?? 0) people=\(info?.people.prefix(5).map { "\($0.name) (\($0.role))" } ?? [])")
            print("  language=\(info?.language ?? "-") website=\(info?.website ?? "-")")
        }
        exit(0)
    }
    RunLoop.main.run()
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate(screenshotPath: screenshotPath) }
app.delegate = delegate
app.setActivationPolicy(screenshotPath == nil ? .regular : .accessory)
app.run()
