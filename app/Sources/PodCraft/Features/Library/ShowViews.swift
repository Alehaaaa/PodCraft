import SwiftUI

/// Manage mode page for one show: every episode the show lists, which ones are on this Mac,
/// and how many of the newest to keep available.
struct ShowManager: View {
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    let showID: UUID
    @State private var filter = 0
    @State private var refreshing = false
    @State private var confirmRemove = false
    @State private var episodeToDelete: UUID? = nil
    @State private var editing = false

    var body: some View {
        if let s = library.show(showID) {
            let everything = library.episodes(inShow: showID)
            let all = everything.filter { !s.skips($0) }
            let skipped = everything.count - all.count
            let list: [Episode] = switch filter {
            case 1: all.filter { $0.stage != .listed }
            case 2: all.filter { $0.stage == .listed }
            default: all
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header(s, total: all.count)
                    if !s.isFiles { availabilityCard(s) }
                    GroupBox {
                        VStack(spacing: 0) {
                            HStack {
                                Picker("Show", selection: $filter) {
                                    Text("All \(all.count)").tag(0)
                                    Text("On this Mac \(all.filter { $0.stage != .listed }.count)").tag(1)
                                    Text("Not downloaded \(all.filter { $0.stage == .listed }.count)").tag(2)
                                }
                                .pickerStyle(.segmented)
                                .labelsHidden()
                                .fixedSize()
                                Spacer()
                            }
                            .padding(.bottom, 6)
                            if skipped > 0 {
                                Label("\(skipped) episodes skipped by this show’s title filter", systemImage: "line.3.horizontal.decrease.circle")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.bottom, 6)
                            }
                            if list.isEmpty {
                                Text(all.isEmpty ? "This show lists no episodes yet." : "Nothing here.")
                                    .foregroundStyle(.secondary).frame(maxWidth: .infinity).padding()
                            }
                            PagedManageEpisodeList(episodes: list, onDelete: { episodeToDelete = $0 })
                        }
                        .padding(6)
                    } label: {
                        Label("Episodes", systemImage: "list.bullet")
                    }
                }
                .padding(24)
                .frame(maxWidth: 980, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle(s.title)
            .navigationSubtitle("\(all.count) episodes · \(library.downloadedCount(showID)) on this Mac")
            .sheet(isPresented: $editing) { ShowEditor(original: s) }
            .confirmationDialog("Remove \(s.title) from your library?", isPresented: $confirmRemove) {
                Button("Remove Show", role: .destructive) {
                    if let p = player.episode, p.showID == showID { player.stop() }
                    library.removeShow(showID)
                }
            } message: { Text("Its downloaded episodes are deleted from this Mac.") }
            .confirmationDialog("Delete this episode?", isPresented: Binding(get: { episodeToDelete != nil }, set: { if !$0 { episodeToDelete = nil } })) {
                Button("Delete Episode", role: .destructive) {
                    if let id = episodeToDelete { if player.episodeID == id { player.stop() }; library.deleteEpisode(id) }
                }
            }
        }
    }

    func header(_ s: Show, total: Int) -> some View {
        HStack(alignment: .top, spacing: 20) {
            ShowArtwork(showID: s.id, size: 132)
                .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
            VStack(alignment: .leading, spacing: 6) {
                Text(s.title).font(.system(size: 26, weight: .bold)).lineLimit(2)
                Text(s.author).foregroundStyle(.secondary)
                if !s.summary.isEmpty {
                    Text(s.summary).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                }
                if let link = s.feedURL {
                    Text(link).font(.caption.monospaced()).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)
                }
                HStack(spacing: 8) {
                    Button { editing = true } label: { Label("Edit Show…", systemImage: "pencil") }
                    ShowLinkRow(show: s)
                    Picker("Feed", selection: Binding(get: { s.feedID }, set: { library.setFeed($0, forShow: s.id) })) {
                        Text("Not in a feed").tag(UUID?.none)
                        ForEach(library.feeds) { f in Text(f.title).tag(Optional(f.id)) }
                    }
                    .fixedSize()
                    .help("Group this show into one of your feeds")
                }
                .buttonStyle(.glass)
                .padding(.top, 4)
                if !s.isFiles, s.feedURL != nil {
                    videoSourceCard(s)
                        .padding(.top, 7)
                }
                Label("Updates checked automatically every \(Int(Mechanics.checkIntervalMinutes)) minutes",
                      systemImage: "clock.arrow.circlepath")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Menu {
                Button("Edit Show…") { editing = true }
                if !s.isFiles, s.feedURL != nil {
                    Button("Find YouTube Matches Again") { library.refreshYouTubeMatches(forShow: s.id) }
                }
                Divider()
                Button("Remove from Library…", role: .destructive) { confirmRemove = true }
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.button).buttonStyle(.glass).fixedSize()
        }
    }

    func videoSourceCard(_ show: Show) -> some View {
        let matched = library.matchedVideoCount(forShow: show.id)
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: "play.rectangle.on.rectangle")
                    .foregroundStyle(matched > 0 ? Color.podTeal : .secondary)
                Text("Video source").font(.callout.weight(.semibold))
                if matched > 0 {
                    Text("\(matched) matched").font(.caption.weight(.medium))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Color.podTeal.opacity(0.14), in: .capsule)
                }
                Spacer()
                if let channelURL = show.youtubeChannelURL.flatMap(YouTubeSource.channelURL(from:)) {
                    Link("Open channel", destination: channelURL).font(.caption)
                }
                Button(show.youtubeChannelURL == nil ? "Find channel" : "Scan again") {
                    library.refreshYouTubeMatches(forShow: show.id)
                }
                .controlSize(.small)
            }
            Text(library.youtubeMatchStatus(forShow: show.id))
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            Text("Normal Play uses the RSS recording. Episodes labeled “Verified video available” can instead prepare and play the official YouTube video.")
                .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 11).padding(.vertical, 9)
        .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    func availabilityCard(_ s: Show) -> some View {
        HStack(spacing: 12) {
            Label("Automatic downloads", systemImage: "arrow.down.circle")
                .font(.callout.weight(.medium))
            Spacer()
            Picker("Automatic downloads", selection: Binding(get: { s.keepAvailable }, set: { library.setKeepAvailable($0, forShow: s.id) })) {
                Text("Off").tag(0)
                Text("Newest episode").tag(1)
                ForEach([2, 3, 5, 10, 20, 50], id: \.self) { Text("Newest \($0) episodes").tag($0) }
            }
            .labelsHidden().fixedSize()
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .help("New episodes are checked every 30 minutes. PodCraft keeps this many processed episodes on the Mac.")
    }
}

private struct PagedManageEpisodeList: View {
    let episodes: [Episode]
    let onDelete: (UUID) -> Void
    @State private var visibleCount = 40
    @State private var loading = false

    var body: some View {
        let visible = Array(episodes.prefix(visibleCount))
        LazyVStack(spacing: 0) {
            ForEach(visible) { episode in
                ManageEpisodeRow(episode: episode, onDelete: { onDelete(episode.id) })
                if episode.id != visible.last?.id { Divider() }
            }
            if visibleCount < episodes.count {
                ProgressView().controlSize(.small).padding(16)
                    .task(id: visibleCount) { await loadMore() }
            }
        }
        .onChange(of: episodes.map(\.id)) { _, _ in visibleCount = min(40, episodes.count) }
    }

    @MainActor
    private func loadMore() async {
        guard !loading, visibleCount < episodes.count else { return }
        loading = true
        try? await Task.sleep(for: .milliseconds(220))
        if !Task.isCancelled { visibleCount = min(visibleCount + 40, episodes.count) }
        loading = false
    }
}

/// First screen with an empty library.
struct WelcomeView: View {
    @Environment(Library.self) private var library

    var body: some View {
        VStack(spacing: 18) {
            LogoView(size: 140)
            Text(library.shows.isEmpty ? "Add Your First Show" : "Pick a show or feed")
                .font(.system(size: 26, weight: .bold))
            Text("Search by name, or paste any podcast feed link. Every episode is listed; only the newest is downloaded, cleaned of sponsors and given chapters.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 460)
            HStack(spacing: 10) {
                Button {
                    library.addShowTargetFeed = nil
                    library.showAddShow = true
                } label: { Label("Add a Show", systemImage: "plus").padding(.horizontal, 6) }
                    .buttonStyle(.glassProminent)
                    .tint(.podTeal)
                    .foregroundStyle(.white)
                    .controlSize(.large)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
