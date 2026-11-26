import SwiftUI

extension Color {
    /// PodCraft's teal, from the logo (the same as the Mac app).
    static let podTeal = Color(red: 0, green: 169 / 255, blue: 157 / 255)
}

@main
struct PodCraftPhoneApp: App {
    @UIApplicationDelegateAdaptor(PodCraftAppDelegate.self) private var appDelegate
    @State private var store: Store
    @State private var player: AudioPlayer
    @State private var updater = Updater()
    @State private var router = Router()

    init() {
        let s = Store()
        _store = State(initialValue: s)
        _player = State(initialValue: AudioPlayer(store: s))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(player)
                .environment(updater)
                .environment(Downloads.shared)
                .environment(router)
                .tint(.podTeal)
                // The QR code in PodCraft's Settings on the Mac opens podcraft://connect?…
                .onOpenURL { store.open($0) }
        }
    }
}

/// Which tab is open and what each tab has pushed, so the player and long-press menus can open a show.
@MainActor
@Observable
final class Router {
    /// PODCRAFT_TAB=browse opens on that tab (for screenshots).
    var tab = ProcessInfo.processInfo.environment["PODCRAFT_TAB"] ?? "home"
    var home = NavigationPath()
    var browse = NavigationPath()
    var search = NavigationPath()
    /// The show last opened this way, so tapping it again doesn't stack a second copy.
    @ObservationIgnored private var lastOpened: (tab: String, show: String, depth: Int)?

    /// Shows a show's page on the tab that's open (closing the player first).
    func open(_ show: RemoteShow, player: AudioPlayer) {
        player.showNowPlaying = false
        if let last = lastOpened, last.tab == tab, last.show == show.id, last.depth == depth { return }
        switch tab {
        case "browse": browse.append(show)
        case "search": search.append(show)
        default: tab = "home"; home.append(show)
        }
        lastOpened = (tab, show.id, depth)
    }

    private var depth: Int {
        switch tab {
        case "browse": browse.count
        case "search": search.count
        default: home.count
        }
    }
}

struct RootView: View {
    @Environment(Store.self) private var store
    @Environment(AudioPlayer.self) private var player
    @Environment(Updater.self) private var updater
    @Environment(Router.self) private var router
    @Environment(\.scenePhase) private var phase

    var body: some View {
        @Bindable var p = player
        @Bindable var r = router
        Group {
            if store.isReady {
                TabView(selection: $r.tab) {
                    Tab("Home", systemImage: "house", value: "home") { HomeView() }
                    Tab("Browse", systemImage: "square.grid.2x2", value: "browse") { BrowseView() }
                    Tab(value: "search", role: .search) { SearchView() }
                }
                .tabViewBottomAccessory { MiniPlayer() }
                .sheet(isPresented: $p.showNowPlaying) { NowPlayingView() }
            } else {
                WelcomeView()
            }
        }
        .onChange(of: phase) { _, now in
            if now == .active {
                Task {
                    await store.refresh()
                    Downloads.shared.cleanUp(store: store, playing: player.episode?.id)
                    await updater.checkAutomatically(server: store.isStandalone ? "" : store.server)
                }
            }
        }
        // PODCRAFT_PLAY=1 starts the newest episode and opens the player (for screenshots).
        .task {
            guard ProcessInfo.processInfo.environment["PODCRAFT_PLAY"] == "1" else { return }
            for _ in 0..<40 where store.latest.isEmpty { try? await Task.sleep(for: .milliseconds(250)) }
            if let e = store.latest.first { player.play(e); player.showNowPlaying = true }
        }
    }
}

// MARK: - Home

struct HomeView: View {
    @Environment(Store.self) private var store
    @Environment(Router.self) private var router

    var body: some View {
        @Bindable var r = router
        NavigationStack(path: $r.home) {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if let message = store.message { StatusBanner(text: message) }
                    UpdateBanner()
                    if store.shows.isEmpty {
                        if store.loading { ProgressView().frame(maxWidth: .infinity, minHeight: 240) }
                        else {
                            if store.isStandalone { FollowPrompt() } else {
                                ContentUnavailableView("No Episodes Yet", systemImage: "headphones",
                                                       description: Text("Episodes appear here once \(store.macName) has downloaded and cleaned them."))
                            }
                        }
                    } else {
                        let queued = store.queuedEpisodes
                        if !queued.isEmpty {
                            SectionTitle("Up Next")
                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(spacing: 14) {
                                    ForEach(queued.prefix(20)) { ContinueCard(episode: $0, inQueue: true) }
                                }
                                .padding(.horizontal)
                            }
                            .scrollClipDisabled()
                        }
                        if !store.continueListening.isEmpty {
                            SectionTitle("Continue Listening")
                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(spacing: 14) {
                                    ForEach(store.continueListening.prefix(10)) { ContinueCard(episode: $0) }
                                }
                                .padding(.horizontal)
                            }
                            .scrollClipDisabled()
                        }
                        HStack(alignment: .firstTextBaseline) {
                            SectionTitle("Latest Episodes")
                            Spacer()
                            EpisodeFilterMenu(key: "latest").padding(.trailing)
                        }
                        let latest = store.apply("latest", to: store.latest)
                        if latest.isEmpty {
                            FilteredEmpty(key: "latest")
                        } else {
                            LazyVStack(spacing: 0) {
                                ForEach(latest.prefix(40)) { e in
                                    EpisodeRow(episode: e, showsShow: true)
                                    Divider().padding(.leading)
                                }
                            }
                        }
                    }
                }
                .padding(.vertical)
            }
            .navigationTitle("Home")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { ConnectionMenu() }
            }
            .refreshable { await store.refresh() }
            .navigationDestination(for: RemoteShow.self) { ShowView(showID: $0.id) }
        }
    }
}

struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.title2.bold()).padding(.horizontal)
    }
}

struct StatusBanner: View {
    let text: String
    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal)
    }
}

/// The toolbar button: Settings (library, Mac, Sync, updates), and Add a Show when listening on this iPhone.
struct ConnectionMenu: View {
    @Environment(Store.self) private var store
    @Environment(Updater.self) private var updater
    @State private var settings = false
    @State private var adding = false

    var body: some View {
        HStack(spacing: 4) {
            if store.isStandalone {
                Button("Add a Show", systemImage: "plus") { adding = true }
            }
            Button {
                settings = true
            } label: {
                Image(systemName: store.message != nil || store.sync.error != nil ? "exclamationmark.icloud"
                                  : updater.available != nil ? "arrow.down.app.fill"
                                  : store.sync.syncing ? "arrow.triangle.2.circlepath.icloud" : "gearshape")
            }
            .accessibilityLabel("Settings")
        }
        .sheet(isPresented: $settings) { SettingsView() }
        .sheet(isPresented: $adding) { AddShowView() }
    }
}

/// Standalone with nothing followed yet.
struct FollowPrompt: View {
    @State private var adding = false
    var body: some View {
        ContentUnavailableView {
            Label("Follow Some Shows", systemImage: "plus.circle")
        } description: {
            Text("Search any podcast or paste its feed address. Shows you follow on your other devices appear here once Sync is on.")
        } actions: {
            Button("Add a Show") { adding = true }.buttonStyle(.glassProminent)
        }
        .sheet(isPresented: $adding) { AddShowView() }
    }
}

/// Shown on Home when the Mac hosts a newer build of this app.
struct UpdateBanner: View {
    @Environment(Store.self) private var store
    @Environment(Updater.self) private var updater

    var body: some View {
        if let release = updater.available {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.app.fill").font(.title2).foregroundStyle(Color.podTeal)
                VStack(alignment: .leading, spacing: 2) {
                    Text("PodCraft \(release.version) is available").font(.subheadline.weight(.semibold))
                    Text("Build \(release.build), from \(store.isStandalone || !store.isConnected ? "GitHub" : store.macName)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Install") { updater.install(release, server: store.isStandalone ? "" : store.server) }
                    .buttonStyle(.glassProminent)
            }
            .padding(12)
            .background(Color.podTeal.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal)
        }
    }
}

struct ContinueCard: View {
    @Environment(Store.self) private var store
    @Environment(AudioPlayer.self) private var player
    let episode: RemoteEpisode
    /// Shown in the Up Next shelf rather than Continue Listening.
    var inQueue = false

    var body: some View {
        Button { player.play(episode); player.showNowPlaying = true } label: {
            VStack(alignment: .leading, spacing: 8) {
                Artwork(url: episode.artwork ?? store.show(episode.showID)?.artwork, size: 150, radius: 14)
                Text(store.show(episode.showID)?.title.uppercased() ?? "")
                    .font(.caption2.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
                Text(episode.title).font(.subheadline.weight(.semibold)).lineLimit(2, reservesSpace: true)
                ProgressView(value: store.position(of: episode), total: max(episode.duration, 1))
                    .tint(.podTeal)
                Text("\(Fmt.remaining(store.remaining(episode))) left").font(.caption).foregroundStyle(.secondary)
            }
            .frame(width: 150)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            EpisodeMenu(episode: episode, store: store, player: player)
            if inQueue {
                Button("Move to Front", systemImage: "arrow.up.to.line") { store.playNext(episode) }
            } else if store.position(of: episode) > 0 && !store.isPlayed(episode) {
                Button("Remove from Continue Listening", systemImage: "xmark.circle") { store.clearProgress(episode) }
            }
        }
    }
}

// MARK: - Browse

/// Everything on the Mac: all shows, the channels (feeds) built there, what's cleaned and ready, and the latest.
enum BrowseList: Hashable {
    case allShows, allChannels, readyOnMac, latest, downloads
}

struct BrowseView: View {
    @Environment(Store.self) private var store
    @Environment(Downloads.self) private var downloads
    @Environment(Router.self) private var router

    var body: some View {
        @Bindable var r = router
        NavigationStack(path: $r.browse) {
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    if let message = store.message { StatusBanner(text: message) }
                    if store.shows.isEmpty {
                        if store.loading { ProgressView().frame(maxWidth: .infinity, minHeight: 240) }
                        else {
                            if store.isStandalone { FollowPrompt() } else {
                                ContentUnavailableView("No Shows Yet", systemImage: "square.grid.2x2",
                                                       description: Text("Add shows in PodCraft on \(store.macName) and they appear here."))
                            }
                        }
                    } else {
                        BrowseSection(title: "Shows", count: store.shows.count, destination: .allShows) {
                            ShelfRow { ForEach(store.shows) { ShowTile(show: $0, size: 140) } }
                        }
                        if !store.feeds.isEmpty {
                            BrowseSection(title: "Channels", count: store.feeds.count, destination: .allChannels) {
                                ShelfRow { ForEach(store.feeds) { FeedTile(feed: $0, size: 140) } }
                            }
                        }
                        let ready = store.readyOnMac
                        if !ready.isEmpty {
                            BrowseSection(title: "Ready on Your Mac", count: ready.count, destination: .readyOnMac,
                                          note: "Sponsors removed, with chapters.") {
                                EpisodeStack(episodes: Array(ready.prefix(5)))
                            }
                        }
                        let downloaded = downloads.episodes(in: store)
                        if !downloaded.isEmpty || !downloads.active.isEmpty {
                            BrowseSection(title: "Downloads", count: downloaded.count, destination: .downloads,
                                          note: downloads.active.isEmpty ? "On this iPhone, to play offline."
                                              : "\(downloads.active.count) downloading.") {
                                EpisodeStack(episodes: Array(downloaded.prefix(5)))
                            }
                        }
                        let latest = store.apply("latest", to: store.latest)
                        BrowseSection(title: "Latest Episodes", count: latest.count, destination: .latest,
                                      note: store.filter(for: "latest") == .all ? nil : store.filter(for: "latest").title + ".") {
                            EpisodeStack(episodes: Array(latest.prefix(5)))
                        }
                    }
                }
                .padding(.vertical)
            }
            .navigationTitle("Browse")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { ConnectionMenu() } }
            .refreshable { await store.refresh() }
            .navigationDestination(for: RemoteShow.self) { ShowView(showID: $0.id) }
            .navigationDestination(for: RemoteFeed.self) { FeedView(feedID: $0.id) }
            .navigationDestination(for: BrowseList.self) { BrowseListView(list: $0) }
        }
    }
}

/// A section heading with a "See All" link, then its content.
struct BrowseSection<Content: View>: View {
    let title: String
    let count: Int
    let destination: BrowseList
    var note: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            NavigationLink(value: destination) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(title).font(.title2.bold()).foregroundStyle(.primary).lineLimit(1)
                    Image(systemName: "chevron.right").font(.headline.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(count)").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal)
            .accessibilityHint("See all")
            if let note { Text(note).font(.subheadline).foregroundStyle(.secondary).padding(.horizontal).padding(.top, -8) }
            content()
        }
    }
}

struct ShelfRow<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 14) { content() }.padding(.horizontal)
        }
        .scrollClipDisabled()
    }
}

struct EpisodeStack: View {
    let episodes: [RemoteEpisode]
    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(episodes) { e in
                EpisodeRow(episode: e, showsShow: true)
                Divider().padding(.leading)
            }
        }
    }
}

struct ShowTile: View {
    @Environment(Store.self) private var store
    @Environment(AudioPlayer.self) private var player
    let show: RemoteShow
    var size: CGFloat?

    var body: some View {
        NavigationLink(value: show) {
            VStack(alignment: .leading, spacing: 6) {
                Artwork(url: show.artwork, size: size, radius: 14)
                Text(show.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(show.episodes.isEmpty ? show.author
                     : "\(show.episodes.count) episode\(show.episodes.count == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(width: size)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { ShowMenu(show: show, store: store, player: player) }
    }
}

struct FeedTile: View {
    @Environment(Store.self) private var store
    let feed: RemoteFeed
    var size: CGFloat?

    var body: some View {
        NavigationLink(value: feed) {
            VStack(alignment: .leading, spacing: 6) {
                Artwork(url: feed.artwork, size: size, radius: 14)
                Text(feed.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text("\(feed.showIDs.count) show\(feed.showIDs.count == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(width: size)
        }
        .buttonStyle(.plain)
    }
}

/// "See All" pages.
struct BrowseListView: View {
    @Environment(Store.self) private var store
    let list: BrowseList
    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 16)]

    var body: some View {
        ScrollView {
            switch list {
            case .allShows:
                LazyVGrid(columns: columns, spacing: 22) { ForEach(store.shows) { ShowTile(show: $0) } }.padding()
            case .allChannels:
                LazyVGrid(columns: columns, spacing: 22) { ForEach(store.feeds) { FeedTile(feed: $0) } }.padding()
            case .readyOnMac:
                EpisodeStack(episodes: store.readyOnMac)
            case .latest:
                let latest = store.apply("latest", to: store.latest)
                if latest.isEmpty { FilteredEmpty(key: "latest") }
                else { EpisodeStack(episodes: Array(latest.prefix(200))) }
            case .downloads:
                DownloadsList()
            }
        }
        .navigationTitle(title)
        .toolbar {
            if list == .latest { ToolbarItem(placement: .topBarTrailing) { EpisodeFilterMenu(key: "latest") } }
        }
    }

    private var title: String {
        switch list {
        case .allShows: "Shows"
        case .allChannels: "Channels"
        case .readyOnMac: "Ready on Your Mac"
        case .latest: "Latest Episodes"
        case .downloads: "Downloads"
        }
    }
}

/// A channel: its shows, then all their episodes.
struct FeedView: View {
    @Environment(Store.self) private var store
    let feedID: String

    var body: some View {
        if let feed = store.feed(feedID) {
            ScrollView {
                VStack(spacing: 10) {
                    Artwork(url: feed.artwork, size: 200, radius: 18)
                        .shadow(color: .black.opacity(0.25), radius: 18, y: 10)
                    Text(feed.title).font(.title2.bold()).multilineTextAlignment(.center)
                    if !feed.author.isEmpty { Text(feed.author).font(.subheadline).foregroundStyle(.secondary) }
                    let summary = Fmt.plain(feed.summary)
                    if !summary.isEmpty {
                        Text(summary).font(.callout).foregroundStyle(.secondary).lineLimit(3).padding(.horizontal)
                    }
                }
                .padding(.top)
                let shows = store.shows(in: feed)
                if !shows.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Shows").font(.title2.bold()).padding(.horizontal)
                        ShelfRow { ForEach(shows) { ShowTile(show: $0, size: 120) } }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 18)
                }
                let all = store.episodes(in: feed)
                let episodes = store.apply("feed:\(feed.id)", to: all)
                if !all.isEmpty {
                    Text("Episodes").font(.title2.bold()).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal).padding(.top, 18)
                    if episodes.isEmpty { FilteredEmpty(key: "feed:\(feed.id)") }
                    else { EpisodeStack(episodes: Array(episodes.prefix(200))) }
                }
            }
            .navigationTitle(feed.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { EpisodeFilterMenu(key: "feed:\(feed.id)") } }
        } else {
            ContentUnavailableView("Channel Not Found", systemImage: "dot.radiowaves.left.and.right")
        }
    }
}

struct ShowView: View {
    @Environment(Store.self) private var store
    @Environment(AudioPlayer.self) private var player
    let showID: String
    @State private var expanded = false

    var body: some View {
        if let show = store.show(showID) {
            let key = "show:\(show.id)"
            let episodes = store.apply(key, to: show.episodes)
            ScrollView {
                VStack(spacing: 14) {
                    Artwork(url: show.artwork, size: 220, radius: 18)
                        .shadow(color: .black.opacity(0.25), radius: 18, y: 10)
                    Text(show.title).font(.title2.bold()).multilineTextAlignment(.center)
                    Text(show.author).font(.subheadline).foregroundStyle(.secondary)
                    // Like the Mac: the newest episode not played yet, or the newest when all are.
                    if let first = show.episodes.first(where: { !store.isPlayed($0) }) ?? show.episodes.first {
                        Button { player.play(first); player.showNowPlaying = true } label: {
                            Label(store.position(of: first) > 15 && !store.isPlayed(first) ? "Resume"
                                  : first.id == show.episodes.first?.id ? "Latest Episode" : "Next Unplayed",
                                  systemImage: "play.fill")
                                .font(.headline)
                                .padding(.horizontal, 26).padding(.vertical, 6)
                        }
                        .buttonStyle(.glassProminent)
                    }
                    let summary = Fmt.plain(show.summary)
                    if !summary.isEmpty {
                        Text(summary)
                            .font(.callout).foregroundStyle(.secondary)
                            .lineLimit(expanded ? nil : 3)
                            .onTapGesture { withAnimation { expanded.toggle() } }
                            .padding(.horizontal)
                    }
                }
                .padding(.top)
                if show.episodes.isEmpty {
                    ContentUnavailableView("No Episodes Listed", systemImage: "headphones",
                                           description: Text(store.isStandalone ? "This show’s feed has no episodes." : "PodCraft on \(store.macName) hasn’t listed this show’s episodes yet."))
                } else {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Episodes").font(.title2.bold())
                        Spacer()
                        Text(countLabel(shown: episodes.count, all: show.episodes.count))
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal).padding(.top, 18)
                    if episodes.isEmpty {
                        FilteredEmpty(key: key)
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(episodes) { e in
                                Divider().padding(.leading)
                                EpisodeRow(episode: e, showsShow: false)
                            }
                        }
                        .padding(.top, 4)
                    }
                }
            }
            .navigationTitle(show.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { EpisodeFilterMenu(key: key) }
                if store.isStandalone {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button("Unfollow", systemImage: "minus.circle", role: .destructive) { store.unsubscribe(showID: show.id) }
                        } label: { Image(systemName: "ellipsis") }
                    }
                }
            }
        } else {
            ContentUnavailableView("Show Not Found", systemImage: "square.stack")
        }
    }

    private func countLabel(shown: Int, all: Int) -> String {
        shown == all ? "\(all) episode\(all == 1 ? "" : "s")" : "\(shown) of \(all)"
    }
}

struct EpisodeRow: View {
    @Environment(Store.self) private var store
    @Environment(AudioPlayer.self) private var player
    let episode: RemoteEpisode
    var showsShow: Bool

    var body: some View {
        let isCurrent = player.episode?.id == episode.id
        // Played episodes are greyed out (unless playing), so what's left to hear stands out.
        let dimmed = store.isPlayed(episode) && !isCurrent
        HStack(alignment: .top, spacing: 12) {
            if showsShow {
                Artwork(url: episode.artwork ?? store.show(episode.showID)?.artwork, size: 64, radius: 10)
                    .opacity(dimmed ? 0.45 : 1)
                    .saturation(dimmed ? 0.3 : 1)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(Fmt.date(episode.published))
                    if episode.isVideo { Image(systemName: "video.fill") }
                    if episode.isOnMac {
                        Image(systemName: "scissors").foregroundStyle(Color.podTeal)
                            .accessibilityLabel("Sponsors removed on your Mac")
                    }
                    if store.isQueued(episode) {
                        Image(systemName: "text.badge.plus").foregroundStyle(Color.podTeal)
                            .accessibilityLabel("In Up Next")
                    }
                }
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Text(episode.title).font(dimmed ? .headline.weight(.regular) : .headline)
                    .foregroundStyle(dimmed ? .secondary : .primary).lineLimit(2)
                let summary = Fmt.plain(episode.summary)
                if !summary.isEmpty {
                    Text(summary).font(.subheadline).foregroundStyle(dimmed ? .tertiary : .secondary).lineLimit(2)
                }
                HStack(spacing: 8) {
                    Button {
                        if isCurrent { player.togglePlay() } else { player.play(episode) }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: isCurrent && player.isPlaying ? "pause.fill" : dimmed ? "checkmark" : "play.fill")
                            if store.isPlayed(episode) { Text("Played") }
                            else if store.position(of: episode) > 15 {
                                ProgressView(value: store.position(of: episode), total: max(episode.duration, 1))
                                    .frame(width: 34).tint(.podTeal)
                                Text("\(Fmt.remaining(store.remaining(episode))) left")
                            } else { Text(Fmt.remaining(episode.duration)) }
                        }
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                    }
                    .buttonStyle(.glass)
                    .foregroundStyle(dimmed ? Color.secondary : Color.primary)
                    .accessibilityLabel(dimmed ? "Played, Play Again" : isCurrent && player.isPlaying ? "Pause" : "Play")
                    DownloadButton(episode: episode)
                }
                .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .contextMenu { EpisodeMenu(episode: episode, store: store, player: player, goToShow: showsShow) }
        .episodeSwipes(episode)
    }
}

// MARK: - Search

struct SearchView: View {
    @Environment(Store.self) private var store
    @Environment(Router.self) private var router
    @State private var query = ""
    @State private var findQuery: String?

    var body: some View {
        @Bindable var r = router
        NavigationStack(path: $r.search) {
            List {
                let q = query.trimmingCharacters(in: .whitespaces)
                if q.isEmpty {
                    ContentUnavailableView("Search Your Library", systemImage: "magnifyingglass",
                                           description: Text(store.isStandalone ? "Find shows and episodes you follow." : "Find shows and episodes from \(store.macName)."))
                        .listRowBackground(Color.clear)
                } else {
                    let shows = store.shows.filter { $0.title.localizedCaseInsensitiveContains(q) || $0.author.localizedCaseInsensitiveContains(q) }
                    // Like the Mac, an episode matches by its show's name too.
                    let matchingShows = Set(shows.map(\.id))
                    let episodes = store.latest.filter {
                        $0.title.localizedCaseInsensitiveContains(q) || $0.summary.localizedCaseInsensitiveContains(q)
                            || matchingShows.contains($0.showID)
                    }
                    if !shows.isEmpty {
                        Section("Shows") {
                            ForEach(shows) { show in
                                NavigationLink(value: show) {
                                    HStack(spacing: 12) {
                                        Artwork(url: show.artwork, size: 48, radius: 8)
                                        VStack(alignment: .leading) {
                                            Text(show.title).font(.headline)
                                            Text(show.author).font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    if !episodes.isEmpty {
                        Section("Episodes") {
                            ForEach(episodes.prefix(50)) { e in
                                EpisodeRow(episode: e, showsShow: true)
                                    .listRowInsets(EdgeInsets())
                            }
                        }
                    }
                    if store.isStandalone {
                        Section {
                            Button("Find “\(q)” in All Podcasts", systemImage: "plus.magnifyingglass") { findQuery = q }
                        }
                    }
                    if shows.isEmpty && episodes.isEmpty && !store.isStandalone {
                        ContentUnavailableView.search(text: q).listRowBackground(Color.clear)
                    }
                }
            }
            .navigationTitle("Search")
            .searchable(text: $query, prompt: "Shows and Episodes")
            .sheet(item: Binding(get: { findQuery.map { FindQuery(text: $0) } }, set: { findQuery = $0?.text })) { AddShowView(query: $0.text) }
            .navigationDestination(for: RemoteShow.self) { ShowView(showID: $0.id) }
        }
    }
}

struct FindQuery: Identifiable { var text: String; var id: String { text } }

// MARK: - Filters

/// The filter button on episode lists: all episodes, hide played, or downloaded only, and the sort order.
struct EpisodeFilterMenu: View {
    @Environment(Store.self) private var store
    let key: String

    var body: some View {
        let current = store.filter(for: key)
        let oldest = store.isOldestFirst(key)
        Menu {
            Picker("Show", selection: Binding(get: { store.filter(for: key) },
                                              set: { f in withAnimation { store.setFilter(f, for: key) } })) {
                ForEach(EpisodeFilter.allCases) { Label($0.title, systemImage: $0.icon).tag($0) }
            }
            .pickerStyle(.inline)
            Picker("Order", selection: Binding(get: { store.isOldestFirst(key) },
                                               set: { o in withAnimation { store.setOldestFirst(o, for: key) } })) {
                Label("Newest First", systemImage: "arrow.down").tag(false)
                Label("Oldest First", systemImage: "arrow.up").tag(true)
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: current == .all && !oldest ? "line.3.horizontal.decrease.circle"
                  : "line.3.horizontal.decrease.circle.fill")
                .font(.title3)
                .foregroundStyle(current == .all && !oldest ? Color.primary : Color.podTeal)
        }
        .accessibilityLabel("Filter Episodes")
        .accessibilityValue(current == .all ? "All Episodes" : current.title)
    }
}

/// A list whose filter leaves nothing to show.
struct FilteredEmpty: View {
    @Environment(Store.self) private var store
    let key: String

    var body: some View {
        let f = store.filter(for: key)
        ContentUnavailableView {
            Label(f == .downloaded ? "No Downloads Here" : "All Played", systemImage: f == .downloaded ? "arrow.down.circle" : "checkmark.circle")
        } description: {
            Text(f == .downloaded ? "None of these episodes are on this iPhone." : "Every episode here has been played.")
        } actions: {
            Button("Show All Episodes") { withAnimation { store.setFilter(.all, for: key) } }
        }
        .padding(.vertical, 20)
    }
}
