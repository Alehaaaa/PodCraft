import SwiftUI

// MARK: - Listen mode: no editing, just your shows and the player

/// Shared only by New's sidebar row and detail column, so selecting New again returns from
/// a discovery preview without forcing a fake sidebar selection change.
@MainActor
@Observable
final class DiscoveryRoute {
    static let shared = DiscoveryRoute()
    var preview: FeedFetcher.SearchResult?
}

/// Listen mode's sidebar: Listen Now, feeds and shows (a native source list).
struct ListenSidebar: View {
    @Environment(Library.self) private var library

    var body: some View {
        @Bindable var lib = library
        List(selection: $lib.listenSelection) {
            Label("Search", systemImage: "magnifyingglass").tag(ListenItem.search)
            Label("Home", systemImage: "house").tag(ListenItem.home)
            Label("New", systemImage: "square.grid.2x2")
                .tag(ListenItem.new)
                .simultaneousGesture(TapGesture().onEnded { DiscoveryRoute.shared.preview = nil })
            Section("Library") {
                Label("Recently Updated", systemImage: "checkmark.circle").tag(ListenItem.recentlyUpdated)
                Label("Shows", systemImage: "rectangle.stack").tag(ListenItem.shows)
                Label("Channels", systemImage: "slider.horizontal.3").tag(ListenItem.channels)
                Label("Saved", systemImage: "bookmark").tag(ListenItem.saved)
                Label("Downloaded", systemImage: "arrow.down.circle").tag(ListenItem.downloaded)
                Label("Latest Episodes", systemImage: "clock").tag(ListenItem.latest)
            }
            if !library.feeds.isEmpty {
                Section("Channels") {
                    ForEach(library.feeds) { f in
                        Label {
                            Text(f.title)
                        } icon: {
                            ArtworkView(title: f.title, hue: f.hue, size: 18, symbol: "dot.radiowaves.left.and.right")
                        }
                        .tag(ListenItem.feed(f.id))
                    }
                }
            }
            Section("Shows") {
                ForEach(library.sortedShows.filter { !library.listenable(library.episodes(inShow: $0.id)).isEmpty }) { s in
                    Label {
                        Text(s.title).lineLimit(1)
                    } icon: {
                        ShowArtwork(showID: s.id, size: 18)
                    }
                    .tag(ListenItem.show(s.id))
                }
            }
        }
        .listStyle(.sidebar)
    }
}

/// Listen mode's main area with search and the large player.
struct ListenDetail: View {
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    private var discoveryRoute: DiscoveryRoute { DiscoveryRoute.shared }
    /// The title bar's search field (a native toolbar item the window owns) writes here.
    private var search: String { library.listenSearch }

    var body: some View {
        Group {
            if let person = library.personEpisodes {
                PersonEpisodesPage(name: person)
            } else if !search.isEmpty {
                SearchResults(query: search)
            } else {
                switch library.listenSelection {
                case .search?:
                    if search.isEmpty {
                        ContentUnavailableView("Search Podcasts", systemImage: "magnifyingglass",
                                               description: Text("Use the search field above to find episodes and shows."))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else { SearchResults(query: search) }
                case .new?:
                    if let show = discoveryRoute.preview {
                        DiscoveryShowPreview(show: show)
                    } else {
                        NewDiscoveryPage { show in discoveryRoute.preview = show }
                    }
                case .recentlyUpdated?: RecentlyUpdatedShowsPage()
                case .shows?: ShowsLibraryPage()
                case .channels?: ChannelsLibraryPage()
                case .saved?: EpisodeCollectionPage(title: "Saved", episodes: library.listenable(library.episodes.filter(\.keepForever)))
                case .downloaded?: EpisodeCollectionPage(title: "Downloaded", episodes: library.episodes.filter(\.isDownloaded))
                case .latest?: EpisodeCollectionPage(title: "Latest Episodes", episodes: library.listenable(library.episodes).sorted { $0.published > $1.published })
                case .show(let id)? where library.show(id) != nil: PodcastShowPage(showID: id)
                case .feed(let id)? where library.feed(id) != nil: FeedPage(feedID: id)
                default: ListenNow()
                }
            }
        }
        .onChange(of: library.pendingSearch, initial: true) { _, value in
            if let value { library.listenSearch = value; library.pendingSearch = nil }
        }
        .onChange(of: library.listenSelection) { _, selection in
            if selection != nil { library.leavePersonEpisodes() }
            // Split-view selection can briefly become nil while the detail/title bar redraws.
            // Only an actual destination selection should dismiss a discovery preview.
            if let selection, selection != .new { discoveryRoute.preview = nil }
        }
        .onChange(of: library.listenSearch) { _, query in
            if !query.isEmpty { discoveryRoute.preview = nil }
            if !query.isEmpty, library.personEpisodes != nil {
                library.leavePersonEpisodes()
                library.listenSelection = .search
            }
        }
        // Keep the selected discovery show across SwiftUI detail/toolbar reconstruction.
        // The explicit sidebar/search handlers and the native toolbar Back item own dismissal.
        .navigationTitle(activeTitle)
        .navigationSubtitle("")
    }

    private var activeTitle: String {
        // Native MainToolbar owns the inline title on person results and discovery previews.
        // Search, Home and New overview draw their own heading.
        if library.personEpisodes != nil { return "" }
        if !search.isEmpty { return "" }
        switch library.listenSelection {
        case .search?: return ""
        case .home?: return ""
        case .new?: return ""
        case .recentlyUpdated?: return "Recently Updated"
        case .shows?: return "Shows"
        case .channels?: return "Channels"
        case .saved?: return "Saved"
        case .downloaded?: return "Downloaded"
        case .latest?: return "Latest Episodes"
        case .show(let id)?: return library.show(id)?.title ?? "Show"
        case .feed(let id)?: return library.feed(id)?.title ?? "Channel"
        case nil: return ""
        }
    }
}

/// A person selected from a show's credits: a temporary result page with a way back to that show.
struct PersonEpisodesPage: View {
    @Environment(Library.self) private var library
    let name: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Episodes featuring \(name)")
                .font(.title2.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
            Divider()
            SearchResults(query: name)
        }
    }
}

struct NewDiscoveryPage: View {
    @Environment(Library.self) private var library
    let onOpenShow: (FeedFetcher.SearchResult) -> Void
    private var store: DiscoveryStore { DiscoveryStore.shared }
    private var shows: [FeedFetcher.SearchResult] { store.shows }
    private var loading: Bool { store.loading }
    private var message: String? { store.message }

    var body: some View {
        GeometryReader { available in
            ScrollView {
                VStack(alignment: .leading, spacing: 34) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("New").font(.system(size: 38, weight: .bold))
                        Spacer()
                        if loading && !shows.isEmpty { ProgressView().controlSize(.small) }
                        NewCountryPicker()
                    }
                    if loading && shows.isEmpty {
                        ProgressView("Finding new shows…")
                            .frame(maxWidth: .infinity, minHeight: max(240, available.size.height - 210))
                    } else if shows.isEmpty {
                        ContentUnavailableView("Discovery Isn’t Available", systemImage: "sparkles",
                                               description: Text(message ?? "Check your connection and try again."))
                            // Keep the New header at the top while centering its empty content beneath it.
                            .frame(maxWidth: .infinity, minHeight: max(240, available.size.height - 210))
                    } else {
                        discoverySection("Featured") {
                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(spacing: 20) {
                                    ForEach(Array(shows.prefix(4).enumerated()), id: \.element.id) { index, show in
                                        DiscoveryHero(show: show, label: index == 0 ? "NEW & NOTEWORTHY" : "FEATURED", onOpen: onOpenShow)
                                    }
                                }
                            }
                        }
                        discoverySection("Trending Shows") {
                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(alignment: .top, spacing: 18) {
                                    ForEach(Array(shows.prefix(12).enumerated()), id: \.element.id) { index, show in
                                        DiscoveryShowTile(show: show, rank: index + 1, onOpen: onOpenShow)
                                    }
                                }
                            }
                        }
                        discoverySection("Recommended for You") {
                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(alignment: .top, spacing: 18) {
                                    ForEach(recommendations) { show in DiscoveryShowTile(show: show, onOpen: onOpenShow) }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 32).padding(.top, 8).padding(.bottom, 120)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task {
            await store.load()
            await store.refineCountryFromLocation()
        }
    }

    var recommendations: [FeedFetcher.SearchResult] {
        var words = Set<String>()
        for show in library.shows {
            for word in tokens(show.title + " " + show.author) where word.count > 3 { words.insert(word) }
        }
        let remaining = Array(shows.dropFirst(4))
        let ranked = remaining.sorted { a, b in
            score(a, words: words) > score(b, words: words)
        }
        return Array(ranked.prefix(12))
    }

    func score(_ show: FeedFetcher.SearchResult, words: Set<String>) -> Int {
        Set(tokens(show.title + " " + show.author)).intersection(words).count
    }

    func tokens(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    func discoverySection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 7) {
                Text(title).font(.title2.bold())
                Image(systemName: "chevron.right").font(.title3.weight(.semibold)).foregroundStyle(.secondary)
            }
            content()
        }
    }

}

struct DiscoveryHero: View {
    let show: FeedFetcher.SearchResult
    let label: String
    let onOpen: (FeedFetcher.SearchResult) -> Void
    @State private var hovering = false

    var body: some View {
        Button { onOpen(show) } label: {
            ZStack(alignment: .bottomLeading) {
                RemoteCover(url: show.artwork, title: show.title, size: 390)
                    .frame(width: 390, height: 268)
                    .clipped()

                LinearGradient(stops: [
                    .init(color: .black.opacity(0.18), location: 0),
                    .init(color: .black.opacity(0.06), location: 0.30),
                    .init(color: .black.opacity(0.58), location: 0.60),
                    .init(color: .black.opacity(0.90), location: 1)
                ], startPoint: .top, endPoint: .bottom)

                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text(label)
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .tracking(1.1)
                            .foregroundStyle(.white.opacity(0.94))
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(.white.opacity(0.17), in: Circle())
                    }
                    Spacer(minLength: 12)
                    Text(show.title)
                        .font(.system(size: 25, weight: .bold))
                        .tracking(-0.45)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if !show.author.isEmpty {
                        Text(show.author)
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.8))
                            .lineLimit(1)
                            .padding(.top, 6)
                    }
                }
                .padding(21)
            }
            .frame(width: 390, height: 268)
            .clipShape(RoundedRectangle(cornerRadius: 19, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 19, style: .continuous)
                    .strokeBorder(.white.opacity(hovering ? 0.32 : 0.13), lineWidth: 1)
            }
            .contentShape(Rectangle())
            .scaleEffect(hovering ? 1.012 : 1)
            .shadow(color: .black.opacity(hovering ? 0.17 : 0.09), radius: hovering ? 18 : 9, y: 5)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.17), value: hovering)
        .help("Browse \(show.title)")
        .contextMenu { DiscoveryActions(show: show) }
    }
}

struct DiscoveryShowTile: View {
    let show: FeedFetcher.SearchResult
    var rank: Int? = nil
    let onOpen: (FeedFetcher.SearchResult) -> Void

    var body: some View {
        Button { onOpen(show) } label: {
            VStack(alignment: .leading, spacing: 6) {
                RemoteCover(url: show.artwork, title: show.title, size: 185)
                if let rank { Text("\(rank)").font(.headline) }
                Text(show.title).font(.headline).lineLimit(2)
                Text(show.author).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(width: 185, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Browse \(show.title)")
        .contextMenu { DiscoveryActions(show: show) }
    }
}

/// A discovery result can be explored before subscribing. Keeping it under New means the
/// sidebar still highlights New, and choosing another sidebar destination dismisses the preview.
struct DiscoveryShowPreview: View {
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    let show: FeedFetcher.SearchResult

    @State private var feed: FeedFetcher.Parsed?
    @State private var loading = false
    @State private var error: String?
    @State private var expandedEpisode: Int?

    private var addedShow: Show? {
        library.shows.first { $0.feedURL == show.feedURL }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                previewHero
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text("Episodes").font(.title2.bold())
                        Image(systemName: "chevron.right")
                            .font(.title3.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    previewEpisodes
                        .padding(.top, 8)
                }
                .padding(.horizontal, 40)
                .padding(.top, 28)
                .padding(.bottom, 120)
                .frame(maxWidth: 1100, alignment: .leading)
            }
        }
        .task(id: show.feedURL) { await loadFeed() }
    }

    private var previewTint: Color {
        if let sample = ArtworkStore.cardColor(remote: feed?.artwork ?? show.artwork, localPath: nil) {
            return Color(nsColor: sample)
        }
        return Color.podTeal.opacity(0.35)
    }

    private var previewHero: some View {
        HStack(alignment: .center, spacing: 44) {
            RemoteCover(url: feed?.artwork ?? show.artwork, title: show.title, size: 240)
                .frame(width: 240, height: 240)
                .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
            VStack(alignment: .leading, spacing: 10) {
                Text(feed?.title ?? show.title)
                    .font(.system(size: 30, weight: .bold))
                    .lineLimit(2)
                Text(feed?.author.isEmpty == false ? (feed?.author ?? show.author) : show.author)
                    .foregroundStyle(.secondary).lineLimit(2)
                if let description = feed?.summary, !description.isEmpty {
                    Text(description).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                }
                HStack(spacing: 12) {
                    if let addedShow {
                        Button { library.listenSelection = .show(addedShow.id) } label: {
                            Label("View in Library", systemImage: "rectangle.stack")
                        }
                        .buttonStyle(.glassProminent)
                    } else {
                        Button { addShow() } label: { Label("Add Show", systemImage: "plus") }
                            .buttonStyle(.glassProminent)
                            .tint(.podTeal)
                            .foregroundStyle(.white)
                            .disabled(feed == nil)
                    }
                    if let link = show.storeURL, let url = URL(string: link) {
                        Link(destination: url) { Label("Apple Podcasts", systemImage: "arrow.up.right.square") }
                            .buttonStyle(.glass)
                            .foregroundStyle(.primary)
                    }
                }
                .padding(.top, 10)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 48)
        .padding(.vertical, 40)
        .frame(minHeight: 330)
        .background {
            LinearGradient(colors: [previewTint, previewTint.opacity(0.55)],
                           startPoint: .top, endPoint: .bottom)
        }
    }

    @ViewBuilder
    private var previewEpisodes: some View {
        if loading {
            ProgressView("Loading episodes…")
                .frame(maxWidth: .infinity, minHeight: 160)
        } else if let error {
            ContentUnavailableView {
                Label("Episodes Unavailable", systemImage: "wifi.exclamationmark")
            } description: {
                Text(error)
            } actions: {
                Button("Try Again") { Task { await loadFeed() } }.buttonStyle(.glass)
            }
            .frame(maxWidth: .infinity, minHeight: 220)
        } else if let feed, !feed.items.isEmpty {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(feed.items.sorted(by: { $0.published > $1.published }).enumerated()), id: \.offset) { index, item in
                    Button {
                        withAnimation(.smooth(duration: 0.2)) {
                            expandedEpisode = expandedEpisode == index ? nil : index
                        }
                    } label: {
                        HStack(alignment: .top, spacing: 14) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(item.title).font(.headline)
                                Text("\(Fmt.date(item.published)) · \(Fmt.length(item.duration))")
                                    .font(.caption).foregroundStyle(.secondary)
                                if expandedEpisode != index {
                                    Text(item.summary).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                            Spacer(minLength: 0)
                            Image(systemName: expandedEpisode == index ? "chevron.up" : "chevron.down")
                                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 14)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if expandedEpisode == index {
                        VStack(alignment: .leading, spacing: 12) {
                            if !item.summary.isEmpty {
                                Text(item.summary).font(.callout).foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                            Button { addShow(andPlay: item) } label: {
                                Label(addedShow == nil ? "Add & Play" : "Play Episode", systemImage: "play.fill")
                            }
                            .buttonStyle(.glass)
                            .disabled(item.audioURL == nil)
                        }
                        .padding(.bottom, 16)
                    }
                    Divider()
                }
            }
        } else {
            ContentUnavailableView("No Episodes Found", systemImage: "waveform")
                .frame(maxWidth: .infinity, minHeight: 220)
        }
    }

    private func loadFeed() async {
        feed = nil
        error = nil
        expandedEpisode = nil
        guard let url = URL(string: show.feedURL) else {
            error = "The show's feed address is invalid."
            return
        }
        loading = true
        defer { if !Task.isCancelled { loading = false } }
        do {
            let loaded = try await FeedFetcher.fetch(url)
            guard !Task.isCancelled else { return }
            feed = loaded
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }

    private func addShow(andPlay item: FeedFetcher.Item? = nil) {
        let id: UUID
        if let addedShow {
            id = addedShow.id
        } else {
            guard let feed else { return }
            let newShow = Show(title: feed.title, author: feed.author.isEmpty ? show.author : feed.author,
                               feedURL: show.feedURL, artworkURL: feed.artwork ?? show.artwork,
                               hue: Double.random(in: 0...1), summary: feed.summary,
                               keepAvailable: library.settings.defaultAvailable)
            id = library.addShow(newShow, items: feed.items)
        }
        if let item {
            if let episode = matchingEpisode(item, in: id) {
                player.play(episode.id)
            } else {
                // A previously subscribed show can have new episodes in its live feed.
                // Refresh that show before trying to play the selected discovery episode.
                Task { @MainActor in
                    await library.refreshShow(id)
                    if let episode = matchingEpisode(item, in: id) {
                        player.play(episode.id)
                    } else {
                        library.flash("This episode is not available to play yet.")
                    }
                }
            }
        }
        library.listenSelection = .show(id)
    }

    private func matchingEpisode(_ item: FeedFetcher.Item, in showID: UUID) -> Episode? {
        let episodes = library.episodes(inShow: showID)
        let guid = item.guid ?? item.audioURL ?? item.title
        return episodes.first(where: { $0.guid == guid })
            ?? episodes.first(where: { item.audioURL != nil && $0.audioURL == item.audioURL })
            ?? episodes.first(where: {
                $0.title == item.title && abs($0.published.timeIntervalSince(item.published)) < 60
            })
    }
}

struct DiscoveryActions: View {
    @Environment(Library.self) private var library
    @Environment(\.openURL) private var openURL
    let show: FeedFetcher.SearchResult

    var body: some View {
        if library.shows.contains(where: { $0.feedURL == show.feedURL }) {
            Label("Already Added", systemImage: "checkmark")
        } else {
            Button { add() } label: { Label("Add Show", systemImage: "plus") }
        }
        if let link = show.storeURL, let url = URL(string: link) {
            Button { openURL(url) } label: { Label("Open in Apple Podcasts", systemImage: "arrow.up.right.square") }
        }
        Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(show.feedURL, forType: .string) } label: {
            Label("Copy Feed Link", systemImage: "doc.on.doc")
        }
    }

    func add() {
        guard !library.shows.contains(where: { $0.feedURL == show.feedURL }), let url = URL(string: show.feedURL) else { return }
        Task { @MainActor in
            guard let parsed = try? await FeedFetcher.fetch(url) else { return }
            let item = Show(title: parsed.title, author: parsed.author.isEmpty ? show.author : parsed.author,
                            feedURL: show.feedURL, artworkURL: parsed.artwork ?? show.artwork,
                            hue: Double.random(in: 0...1), summary: parsed.summary,
                            keepAvailable: library.settings.defaultAvailable)
            library.addShow(item, items: parsed.items)
        }
    }
}

struct EpisodeCollectionPage: View {
    let title: String
    let episodes: [Episode]

    var body: some View {
        Group {
            if episodes.isEmpty {
                ContentUnavailableView(emptyTitle, systemImage: emptySymbol,
                                       description: Text(emptyDescription))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    EpisodeList(episodes: episodes, showShowName: true)
                        .padding(28)
                        .frame(maxWidth: 1000, alignment: .leading)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private var emptyTitle: String {
        switch title {
        case "Saved": "No Saved Episodes"
        case "Downloaded": "No Downloaded Episodes"
        default: "Nothing Here Yet"
        }
    }

    private var emptySymbol: String {
        switch title {
        case "Saved": "bookmark"
        case "Downloaded": "arrow.down.circle"
        default: "waveform"
        }
    }

    private var emptyDescription: String {
        switch title {
        case "Saved": "Save episodes you want to listen to later, and they’ll show up here."
        case "Downloaded": "Episodes downloaded to this Mac will appear here."
        default: "Episodes appear here as your library updates."
        }
    }
}

struct ShowsLibraryPage: View {
    @Environment(Library.self) private var library
    var body: some View {
        Group {
            if library.sortedShows.isEmpty {
                EmptyHint(symbol: "rectangle.stack", title: "No Shows",
                          message: "Shows you add will appear here.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 180), spacing: 20)], alignment: .leading, spacing: 22) {
                    ForEach(library.sortedShows) { show in
                        Button { library.listenSelection = .show(show.id) } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                ShowArtwork(showID: show.id, size: 150)
                                Text(show.title).font(.headline).lineLimit(1)
                                Text(show.author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }.buttonStyle(.plain)
                    }
                }
                .padding(28).frame(maxWidth: 1100, alignment: .leading).frame(maxWidth: .infinity)
                }
            }
        }
    }
}

struct ChannelsLibraryPage: View {
    @Environment(Library.self) private var library
    var body: some View {
        Group {
            if library.feeds.isEmpty {
                EmptyHint(symbol: "slider.horizontal.3", title: "No Channels",
                          message: "Channels you create will appear here.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                ForEach(library.feeds) { feed in
                    Button { library.listenSelection = .feed(feed.id) } label: {
                        HStack(spacing: 14) {
                            ArtworkView(title: feed.title, hue: feed.hue, size: 58, symbol: "dot.radiowaves.left.and.right")
                            VStack(alignment: .leading) {
                                Text(feed.title).font(.headline)
                                Text("\(library.shows(in: feed.id).count) shows").foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.secondary)
                        }.padding(.vertical, 6)
                    }.buttonStyle(.plain)
                    Divider()
                }
                    }.padding(28).frame(maxWidth: 900, alignment: .leading).frame(maxWidth: .infinity)
                }
            }
        }
    }
}

/// One row per show, ordered by that show's newest episode. This is intentionally
/// different from Latest Episodes, which remains an episode-by-episode timeline.
struct RecentlyUpdatedShowsPage: View {
    @Environment(Library.self) private var library

    private var updated: [(show: Show, episode: Episode)] {
        library.shows.compactMap { show in
            library.listenable(library.episodes(inShow: show.id)).max(by: { $0.published < $1.published })
                .map { (show, $0) }
        }.sorted { $0.episode.published > $1.episode.published }
    }

    var body: some View {
        if updated.isEmpty {
            EmptyHint(symbol: "checkmark.circle", title: "No Recently Updated Shows",
                      message: "Shows will appear here when new episodes arrive.")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(updated, id: \.show.id) { item in
                        Button { library.listenSelection = .show(item.show.id) } label: {
                            HStack(spacing: 14) {
                                ShowArtwork(showID: item.show.id, size: 64)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.show.title).font(.headline).lineLimit(1)
                                    Text(item.episode.title).foregroundStyle(.secondary).lineLimit(1)
                                    Text(item.episode.published, style: .relative)
                                        .font(.caption).foregroundStyle(.tertiary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle()).padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)
                        Divider()
                    }
                }
                .padding(28).frame(maxWidth: 900).frame(maxWidth: .infinity)
            }
        }
    }
}

struct ListenNow: View {
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player

    var body: some View {
        if library.shows.isEmpty {
            VStack(spacing: 14) {
                LogoView(size: 120)
                Text("Nothing to listen to yet").font(.system(size: 24, weight: .bold))
                Text("Add shows in Manage mode; they show up here, ready to play.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button { library.setMode(.manage); library.showAddShow = true } label: {
                    Label("Add a Show", systemImage: "plus").padding(.horizontal, 6)
                }
                .buttonStyle(.glassProminent)
                .tint(.podTeal)
                .foregroundStyle(.white)
                .controlSize(.large)
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            content
        }
    }

    var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 34) {
                Text("Home").font(.system(size: 38, weight: .bold))

                let upNext = homeUpNext
                if !upNext.isEmpty {
                    homeSection("Up Next") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 18) {
                                ForEach(upNext) { HomeUpNextCard(episode: $0) }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                let recent = recentlyPlayed
                if !recent.isEmpty {
                    homeSection("Recently Played") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 42) {
                                ForEach(recent) { HomeRecentEpisode(episode: $0) }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                homeSection("Latest Episodes") {
                    VStack(spacing: 0) {
                        let list = Array(library.latest.prefix(10))
                        ForEach(list) { e in
                            PodcastEpisodeRow(episode: e, showShowName: true)
                                .contextMenu { EpisodeContextActions(episode: e) }
                            if e.id != list.last?.id { Divider() }
                        }
                    }
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 8)
            .padding(.bottom, 120)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    var homeUpNext: [Episode] {
        var seenShows = Set<UUID>()
        return (library.continueListening + library.latest)
            .filter { seenShows.insert($0.showID).inserted }
            .prefix(10).map { $0 }
    }

    var recentlyPlayed: [Episode] {
        library.listenable(library.episodes)
            .filter { $0.started || $0.played }
            .sorted { ($0.lastPlayedAt ?? $0.addedAt) > ($1.lastPlayedAt ?? $1.addedAt) }
            .prefix(10).map { $0 }
    }

    func homeSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Button { } label: {
                HStack(spacing: 7) {
                    Text(title).font(.title2.bold())
                    Image(systemName: "chevron.right").font(.title3.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            content()
        }
    }
}

struct HomeUpNextCard: View {
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    let episode: Episode

    var body: some View {
        let e = player.episodeID == episode.id ? (library.episode(episode.id) ?? episode) : episode
        let pos = player.episodeID == e.id ? player.position : e.position
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                EpisodeArtwork(episode: e, size: 250)
                    .frame(width: 250, height: 170)
                    .clipped()
                    .overlay {
                        LinearGradient(colors: [.clear, .black.opacity(0.52)], startPoint: .center, endPoint: .bottom)
                    }
                EpisodeArtwork(episode: e, size: 52)
                    .padding(16)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(e.position > 0 && !e.played ? "Resume · \(Fmt.short(e.published))" : "New · \(Fmt.short(e.published))")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(e.title).font(.title3.bold()).lineLimit(3)
                Text(e.summary).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 10)
                HStack {
                    Button { player.play(e.id) } label: {
                        HStack(spacing: 7) {
                            Image(systemName: player.episodeID == e.id && player.isPlaying ? "pause.fill" : "play.fill")
                            if pos > 0 && !e.played {
                                ProgressView(value: min(1, pos / max(e.playbackDuration, 1))).frame(width: 40)
                            }
                            Text(Fmt.length(max(0, (player.episodeID == e.id ? player.duration : e.playbackDuration) - pos))).fontWeight(.semibold)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(.primary.opacity(0.12), in: .capsule)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Menu { EpisodeContextActions(episode: e) } label: {
                        Image(systemName: "ellipsis").frame(width: 28, height: 28)
                    }
                    .menuStyle(.button).menuIndicator(.hidden).buttonStyle(.borderless)
                }
            }
            .padding(16)
            .frame(width: 250, height: 164, alignment: .topLeading)
        }
        .frame(width: 250)
        .background(cardColor, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(.white.opacity(0.08)))
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contextMenu { EpisodeContextActions(episode: e) }
        .onTapGesture(count: 2) { player.play(e.id) }
    }

    var cardColor: Color {
        let show = library.show(episode.showID)
        if let sampled = ArtworkStore.cardColor(remote: episode.artworkURL ?? show?.artworkURL,
                                                localPath: show?.customArtwork) {
            return Color(nsColor: sampled)
        }
        return Color(hue: show?.hue ?? 0.5, saturation: 0.32, brightness: 0.30)
    }
}

struct HomeRecentEpisode: View {
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    let episode: Episode

    var body: some View {
        HStack(spacing: 14) {
            EpisodeArtwork(episode: episode, size: 92)
            VStack(alignment: .leading, spacing: 5) {
                Text(episode.played ? "Played · \(Fmt.short(episode.published))" : Fmt.short(episode.published))
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(episode.title).font(.headline).lineLimit(2)
                Text(library.show(episode.showID)?.title ?? "").font(.callout).foregroundStyle(.secondary).lineLimit(1)
                EpisodePill(episode: episode)
            }
        }
        .frame(width: 390, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { player.play(episode.id) }
        .contextMenu { EpisodeContextActions(episode: episode) }
    }
}

struct EpisodeContextActions: View {
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    let episode: Episode

    var body: some View {
        Button { player.play(episode.id) } label: {
            Label(player.episodeID == episode.id && player.isPlaying ? "Pause" : "Play", systemImage: "play.fill")
        }
        if episode.youtubeMatchState == .matched, episode.youtubeID != nil {
            Button("Show Video") { player.playYouTubeVideo(episode.id) }
        } else if episode.youtubeMatchState == .notFound,
                  library.show(episode.showID)?.youtubeChannelURL != nil {
            Button("Find YouTube Match Again") { library.retryYouTubeMatch(forEpisode: episode.id) }
        }
        if episode.canPlay && player.episodeID != episode.id {
            Button { player.playNext(episode.id) } label: { Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") }
            Button { player.addToQueue(episode.id) } label: { Label("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward") }
        }
        if episode.stage == .listed || episode.stage == .failed {
            Button { library.download(episode.id) } label: { Label("Download", systemImage: "arrow.down.circle") }
        } else if episode.isDownloaded {
            Button { if player.episodeID == episode.id { player.stop() }; library.removeDownload(episode.id) } label: {
                Label("Remove Download", systemImage: "trash")
            }
        }
        Button {
            if let i = library.episodeIndex(episode.id) { library.episodes[i].keepForever.toggle(); library.save() }
        } label: {
            Label(episode.keepForever ? "Unsave" : "Save", systemImage: episode.keepForever ? "bookmark.slash" : "bookmark")
        }
        Divider()
        Button(episode.played ? "Mark as Unplayed" : "Mark as Played") { library.setPlayed(episode.id, !episode.played) }
        if episode.localFile != nil {
            Menu("Analyze Again") {
                Button("Regenerate Chapters") { library.reanalyze(episode.id, retranscribe: false) }
                    .disabled(episode.transcript.isEmpty)
                Button("Retranscribe & Analyze") { library.reanalyze(episode.id, retranscribe: true) }
            }
        }
        Divider()
        Button("Go to Show") { library.listenSelection = .show(episode.showID) }
    }
}

struct ListenEpisodeRow: View {
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    let episode: Episode
    var showArtwork = true

    var body: some View {
        let e = episode
        let current = player.episodeID == e.id
        let pos = current ? player.position : e.position
        HStack(spacing: 14) {
            if showArtwork { EpisodeArtwork(episode: e, size: 48) }
            VStack(alignment: .leading, spacing: 3) {
                Text(e.title).font(.body.weight(e.played ? .regular : .semibold))
                    .foregroundStyle(e.played ? .secondary : .primary).lineLimit(1)
                Text(e.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 6) {
                    if e.isDownloaded {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint).help("On this Mac, sponsors removed")
                    } else {
                        Image(systemName: "dot.radiowaves.up.forward").help("Streams from the show")
                    }
                    if e.youtubeMatchState == .matched, e.youtubeID != nil {
                        Button { player.playYouTubeVideo(e.id) } label: {
                            VideoSourceBadge(episode: e, compact: true)
                        }
                        .buttonStyle(.plain)
                    } else if e.isVideo { VideoSourceBadge(episode: e, compact: true) }
                    Text(library.show(e.showID)?.title ?? "")
                    Text("·"); Text(Fmt.date(e.published))
                    Text("·")
                    let length = current ? player.duration : e.playbackDuration
                    Text(e.played ? "Played" : (pos > 1 ? "\(Fmt.length(max(0, length - pos))) left" : Fmt.length(length)))
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                if current && player.isPlaying { player.togglePlay() } else { player.play(e.id) }
            } label: {
                Image(systemName: current && player.isPlaying ? "pause.fill" : (e.played ? "checkmark.circle.fill" : "play.fill"))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .help(current && player.isPlaying ? "Pause" : (e.played ? "Played · Play Again" : "Play"))
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { player.play(e.id) }
    }
}

struct ShowPage: View {
    @Environment(Library.self) private var library
    let showID: UUID

    var body: some View {
        let s = library.show(showID)!
        let list = library.listenable(library.episodes(inShow: showID))
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .bottom, spacing: 20) {
                    ShowArtwork(showID: showID, size: 150).shadow(color: .black.opacity(0.15), radius: 10, y: 5)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(s.title).font(.system(size: 28, weight: .bold))
                        Text(s.author).font(.title3).foregroundStyle(.secondary)
                        Text("\(list.count) episodes · \(library.downloadedCount(showID)) on this Mac")
                            .font(.callout).foregroundStyle(.secondary)
                        PlayLatestButton(episodes: list)
                    }
                }
                VStack(spacing: 0) {
                    ForEach(list) { e in
                        ListenEpisodeRow(episode: e, showArtwork: false)
                        if e.id != list.last?.id { Divider() }
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 1000, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
}

struct FeedPage: View {
    @Environment(Library.self) private var library
    let feedID: UUID

    var body: some View {
        let f = library.feed(feedID)!
        let list = library.listenable(library.episodes(inFeed: feedID))
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .bottom, spacing: 20) {
                    ArtworkView(title: f.title, hue: f.hue, size: 150, symbol: "dot.radiowaves.left.and.right")
                        .shadow(color: .black.opacity(0.15), radius: 10, y: 5)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(f.title).font(.system(size: 28, weight: .bold))
                        Text(f.summary).foregroundStyle(.secondary).lineLimit(2)
                        Text(library.shows(in: feedID).map(\.title).joined(separator: ", "))
                            .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                        PlayLatestButton(episodes: list)
                    }
                }
                VStack(spacing: 0) {
                    ForEach(list) { e in
                        PodcastEpisodeRow(episode: e, showShowName: true)
                        if e.id != list.last?.id { Divider() }
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 1000, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
}

struct PlayLatestButton: View {
    @Environment(Player.self) private var player
    let episodes: [Episode]
    var body: some View {
        if let next = episodes.first(where: { !$0.played }) ?? episodes.first {
            Button { player.play(next.id) } label: {
                Label(next.started ? "Resume" : "Play Latest", systemImage: "play.fill").padding(.horizontal, 6)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .padding(.top, 6)
        }
    }
}

struct SearchResults: View {
    @Environment(Library.self) private var library
    let query: String

    var body: some View {
        let q = query.lowercased()
        let hits = library.listenable(library.episodes).filter {
            $0.title.lowercased().contains(q) || $0.summary.lowercased().contains(q)
                || (library.show($0.showID)?.title.lowercased().contains(q) ?? false)
        }.sorted { $0.published > $1.published }
        if hits.isEmpty {
            ContentUnavailableView.search(text: query)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(hits) { e in ListenEpisodeRow(episode: e) }
        }
    }
}
