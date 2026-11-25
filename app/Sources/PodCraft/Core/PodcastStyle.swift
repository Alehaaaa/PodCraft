import SwiftUI
import AVKit
import CoreImage

// Layout modelled on the macOS Podcasts app (the person's reference picture): a floating player bar,
// show pages with a large header, and episode rows with a play/progress pill and a cover on the right.

// MARK: - Short dates ("Today", "2d ago", "Nov 11")

extension Fmt {
    static let monthDay: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f
    }()

    static func short(_ d: Date) -> String {
        let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: d),
                                                   to: Calendar.current.startOfDay(for: Date())).day ?? 0
        if days <= 0 { return "Today" }
        if days < 7 { return "\(days)d ago" }
        return monthDay.string(from: d)
    }

    /// Chapter titles in title case: "the day before the awards" → "The Day Before the Awards".
    /// Words that already carry capitals inside (AI, iPhone, McDonald's) are kept as written; short joining
    /// words stay lower case unless they open the title or follow a colon.
    static func titleCase(_ text: String) -> String {
        let minor: Set<String> = ["a", "an", "the", "and", "but", "or", "nor", "for", "so", "yet", "of", "in", "on",
                                  "at", "to", "by", "up", "as", "via", "vs", "vs.", "with", "from", "into", "per", "off", "over"]
        let words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        var out: [String] = []
        var startOfPhrase = true
        for (i, w) in words.enumerated() {
            let letters = w.filter(\.isLetter)
            let hasInnerCaps = letters.dropFirst().contains(where: \.isUppercase)
            let core = w.lowercased().trimmingCharacters(in: .punctuationCharacters)
            var word: String
            if hasInnerCaps || letters.isEmpty {
                word = w
            } else if !startOfPhrase && i != words.count - 1 && minor.contains(core) {
                word = w.lowercased()
            } else {
                // Capitalise each hyphen-joined part at its first letter, after any opening quote or bracket.
                word = w.split(separator: "-", omittingEmptySubsequences: false).map { part -> String in
                    var s = String(part)
                    if let idx = s.firstIndex(where: \.isLetter), !s[s.index(after: idx)...].contains(where: \.isUppercase) {
                        s.replaceSubrange(idx...idx, with: String(s[idx]).uppercased())
                    }
                    return s
                }.joined(separator: "-")
            }
            out.append(word)
            startOfPhrase = w.hasSuffix(":") || w.hasSuffix("—") || w.hasSuffix("–")
        }
        return out.joined(separator: " ")
    }

    static func compact(_ s: Double) -> String {
        let m = Int((max(0, s) / 60).rounded())
        if m >= 60 { return m % 60 == 0 ? "\(m / 60)h" : "\(m / 60)h \(m % 60)m" }
        return "\(max(m, 1))m"
    }
}

// MARK: - Play pill

/// "▶ 1h 9m" before listening; a small progress bar and the time left once started; pause while playing.
struct EpisodePill: View {
    @Environment(Player.self) private var player
    let episode: Episode
    var prominent = false

    var body: some View {
        let current = player.episodeID == episode.id
        let playing = current && player.isPlaying
        let pos = current ? player.position : episode.position
        let total = current && player.duration > 0 ? player.duration : episode.playbackDuration
        let started = pos > 1 && !episode.played
        let waitingForYouTube = player.preparingYouTubeEpisodeID == episode.id
        Button {
            if playing { player.togglePlay() } else { player.play(episode.id) }
        } label: {
            HStack(spacing: 8) {
                if waitingForYouTube && !playing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: playing ? "pause.fill" : (episode.played ? "checkmark.circle.fill" : (started ? "waveform" : "play.fill")))
                        .font(.system(size: prominent ? 15 : 12, weight: .bold))
                        .contentTransition(.symbolEffect(.replace))
                }
                if !waitingForYouTube && (started || playing) {
                    // Teal progress on a darker track: on the large light button a white bar blended in.
                    ZStack(alignment: .leading) {
                        Capsule().fill(prominent ? Color.black.opacity(0.22) : Color.podTeal.opacity(0.28))
                        Capsule().fill(Color.podTeal).frame(width: (prominent ? 90 : 46) * min(1, pos / max(total, 1)))
                    }
                    .frame(width: prominent ? 90 : 46, height: prominent ? 6 : 4)
                }
                Text(waitingForYouTube ?
                     (player.youtubePreparationStatus ?? (player.preparingYouTubeVideo ? "Preparing YouTube video" : "Preparing YouTube audio")) :
                     (episode.played && !playing ? "Played" : (started ? Fmt.compact((total - pos) / player.rate) : Fmt.compact(total))))
                    .font(prominent ? .title3.weight(.semibold) : .callout.weight(.semibold))
                    .monospacedDigit()
            }
            .padding(.horizontal, prominent ? 28 : 14)
            .padding(.vertical, prominent ? 12 : 7)
            .foregroundStyle(prominent ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor)) : AnyShapeStyle(Color.podTeal))
            .background(prominent ? AnyShapeStyle(Color.primary) : AnyShapeStyle(Color.podTeal.opacity(0.14)), in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!episode.canPlay)
        .help(waitingForYouTube ? "Playback continues while PodCraft aligns the same spoken passage" :
              (playing ? "Pause" : (episode.played ? "Played · Play Again" : "Play")))
    }
}

// MARK: - Episode row

struct PodcastEpisodeRow: View {
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    let episode: Episode
    var showShowName = false

    var body: some View {
        let e = episode
        HStack(alignment: .top, spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    if showShowName, let s = library.show(e.showID) { Text(s.title.uppercased()).lineLimit(1); Text("·") }
                    Text(Fmt.short(e.published))
                    if e.youtubeMatchState == .matched, e.youtubeID != nil {
                        Button { player.playYouTubeVideo(e.id) } label: {
                            Image(systemName: "play.rectangle.fill")
                        }
                        .buttonStyle(.plain)
                        .help("Verified YouTube video available · Play video")
                        .accessibilityLabel("Play verified YouTube video")
                    } else if e.isVideo { Image(systemName: "video.fill") }
                    if e.isDownloaded { Image(systemName: "arrow.down.circle.fill").help("On this Mac, sponsors removed") }
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                Text(e.title)
                    .font(.title3.weight(e.played ? .regular : .semibold))
                    .foregroundStyle(e.played ? .secondary : .primary)
                    .lineLimit(2)
                if !e.summary.isEmpty {
                    Text(e.summary).font(.body).foregroundStyle(.secondary).lineLimit(3)
                }
                HStack {
                    EpisodePill(episode: e)
                    Spacer()
                    moreMenu(e)
                }
                .padding(.top, 6)
            }
            EpisodeArtwork(episode: e, size: 112)
        }
        .padding(.vertical, 18)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { player.play(e.id) }
        .contextMenu { EpisodeContextActions(episode: e) }
    }

    func moreMenu(_ e: Episode) -> some View {
        Menu {
            if e.canPlay && player.episodeID != e.id {
                Button("Play Next") { player.playNext(e.id) }
                Button("Add to Queue") { player.addToQueue(e.id) }
                Divider()
            }
            if e.youtubeMatchState == .matched, e.youtubeID != nil {
                Button("Show Video") { player.playYouTubeVideo(e.id) }
            } else if e.youtubeMatchState == .notFound, library.show(e.showID)?.youtubeChannelURL != nil {
                Button("Find YouTube Match Again") { library.retryYouTubeMatch(forEpisode: e.id) }
            }
            Button(e.played ? "Mark as Unplayed" : "Mark as Played") { library.setPlayed(e.id, !e.played) }
            if e.stage == .listed {
                Button("Download") { library.download(e.id) }
            } else if e.isDownloaded {
                Button("Remove Download") { if player.episodeID == e.id { player.stop() }; library.removeDownload(e.id) }
            }
            if !e.transcript.isEmpty {
                Button("Show Transcript") { player.play(e.id); player.showChapters = true }
            }
            Divider()
            Button("Go to Show") { library.listenSelection = .show(e.showID) }
        } label: {
            Image(systemName: "ellipsis").foregroundStyle(.secondary).frame(width: 28, height: 20)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.borderless)
        .fixedSize()
    }
}

/// A list of rows with dividers, the way the Podcasts app lays them out.
struct EpisodeList: View {
    let episodes: [Episode]
    var showShowName = false
    private let pageSize = 30
    @State private var visibleCount = 30
    @State private var loadingMore = false

    var body: some View {
        let visible = Array(episodes.prefix(visibleCount))
        LazyVStack(spacing: 0) {
            ForEach(visible) { e in
                PodcastEpisodeRow(episode: e, showShowName: showShowName)
                Divider()
            }
            if visibleCount < episodes.count {
                ProgressView()
                    .controlSize(.small)
                    .padding(.vertical, 18)
                    .task(id: visibleCount) { await loadNextPage() }
            }
        }
        .onChange(of: episodes.map(\.id)) { _, _ in visibleCount = min(pageSize, episodes.count) }
    }

    /// Load one bounded page only after the scroll sentinel has remained visible briefly. This
    /// prevents fast trackpad scrolling from decoding artwork and constructing every row at once.
    @MainActor
    private func loadNextPage() async {
        guard !loadingMore, visibleCount < episodes.count else { return }
        loadingMore = true
        try? await Task.sleep(for: .milliseconds(220))
        guard !Task.isCancelled else { loadingMore = false; return }
        visibleCount = min(visibleCount + pageSize, episodes.count)
        loadingMore = false
    }
}

// MARK: - Show page

struct PodcastShowPage: View {
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    let showID: UUID
    @State private var oldestFirst = false
    @State private var showAll = false
    /// Episodes shown before "See All".
    private let firstPage = 10

    /// Read the selected show every time: a reused SwiftUI page must not carry
    /// another show's filter across navigation or reset a restored preference.
    private var filter: EpisodeFilter { library.episodeFilter(forShow: showID) }
    private var filterBinding: Binding<EpisodeFilter> {
        Binding(get: { library.episodeFilter(forShow: showID) },
                set: { library.setEpisodeFilter($0, forShow: showID) })
    }

    var body: some View {
        if let s = library.show(showID) {
            let all = library.listenable(library.episodes(inShow: showID))
            let filtered = all.filter {
                switch filter {
                case .all: true
                case .unplayed: !$0.played
                case .downloaded: $0.isDownloaded
                }
            }
            let list = oldestFirst ? filtered.reversed() : filtered
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ShowHero(show: s, latest: all.first(where: { !$0.played }) ?? all.first,
                             filter: filterBinding, oldestFirst: $oldestFirst)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text("Episodes").font(.title2.bold())
                            Image(systemName: "chevron.right").font(.title3.weight(.semibold)).foregroundStyle(.secondary)
                        }
                        if filter != .all || oldestFirst {
                            Label("Filtered by: \(filter.rawValue)\(oldestFirst ? " · Oldest first" : "")",
                                  systemImage: "line.3.horizontal.decrease")
                                .foregroundStyle(.secondary)
                        }
                        if list.isEmpty {
                            Text("No episodes here.").foregroundStyle(.secondary).padding(.vertical, 30)
                        }
                        EpisodeList(episodes: Array(showAll ? Array(list) : Array(list.prefix(firstPage)))).padding(.top, 8)
                        if !showAll && list.count > firstPage {
                            Button { withAnimation(.smooth(duration: 0.25)) { showAll = true } } label: {
                                HStack(spacing: 6) {
                                    Text("See All \(list.count) Episodes")
                                    Image(systemName: "chevron.right").font(.caption.weight(.bold))
                                }
                                .font(.callout.weight(.semibold))
                                .padding(.horizontal, 16).padding(.vertical, 8)
                                .foregroundStyle(Color.podTeal)
                                .background(Color.podTeal.opacity(0.14), in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .padding(.top, 14)
                        }
                        ShowDetailsSection(show: s)
                            .padding(.top, 44)
                            .padding(.bottom, 120)
                    }
                    .padding(.horizontal, 40)
                    .padding(.top, 28)
                    .frame(maxWidth: 1100, alignment: .leading)
                }
            }
        }
    }
}

/// The big header: cover on the left; show, latest episode and a large play pill on the right,
/// over a background tinted from the cover. Filter, sort and more buttons in the corner.
struct ShowHero: View {
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    let show: Show
    let latest: Episode?
    @Binding var filter: EpisodeFilter
    @Binding var oldestFirst: Bool

    var body: some View {
        let _ = library.artworkVersion
        let tint = CoverColor.average(for: show) ?? Color.podTeal.opacity(0.35)
        ZStack(alignment: .topTrailing) {
            LinearGradient(colors: [tint, tint.opacity(0.55)], startPoint: .top, endPoint: .bottom)
            HStack(alignment: .center, spacing: 44) {
                ShowArtwork(showID: show.id, size: 240)
                    .shadow(color: .black.opacity(0.3), radius: 18, y: 8)
                VStack(alignment: .leading, spacing: 8) {
                    Text(show.title).font(.system(size: 30, weight: .bold)).lineLimit(2)
                    if let latest {
                        Text(latest.title).font(.title3.weight(.semibold)).lineLimit(2)
                    }
                    Text(show.author).foregroundStyle(.secondary).lineLimit(1)
                    if show.feedURL != nil {
                        Label(library.youtubeMatchStatus(forShow: show.id), systemImage: "play.rectangle.on.rectangle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    if let latest {
                        HStack(spacing: 12) {
                            EpisodePill(episode: latest, prominent: true)
                            if latest.youtubeMatchState == .matched, latest.youtubeID != nil {
                                Button { player.playYouTubeVideo(latest.id) } label: {
                                    Image(systemName: "play.rectangle.fill")
                                        .font(.title3.weight(.semibold))
                                        .frame(width: 44, height: 44)
                                }
                                .buttonStyle(.plain)
                                .background(.regularMaterial, in: Circle())
                                .help("Verified YouTube video found · Play video")
                            }
                            Button { library.setPlayed(latest.id, !latest.played) } label: {
                                Image(systemName: "checkmark").font(.title3.weight(.semibold)).frame(width: 44, height: 44)
                            }
                            .buttonStyle(.plain)
                            .background(.regularMaterial, in: Circle())
                            .help(latest.played ? "Mark as Unplayed" : "Mark as Played")
                        }
                        .padding(.top, 10)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 48)
            .padding(.vertical, 40)
            HStack(spacing: 10) {
                Menu {
                    Picker("Show", selection: $filter) {
                        ForEach(EpisodeFilter.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: { Image(systemName: "line.3.horizontal.decrease") }
                    .help("Filter Episodes")
                Button { oldestFirst.toggle() } label: { Image(systemName: "arrow.up.arrow.down") }
                    .help(oldestFirst ? "Newest First" : "Oldest First")
                Menu {
                    Button("Edit Show in Manage Mode") {
                        library.setMode(.manage)
                        library.manageSelection = .show(show.id)
                    }
                    if show.feedURL != nil {
                        Button("Check for New Episodes") { Task { @MainActor in await library.refreshShow(show.id) } }
                        Button("Find YouTube Matches Again") { library.refreshYouTubeMatches(forShow: show.id) }
                    }
                } label: { Image(systemName: "ellipsis") }
                    .help("More")
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .padding(18)
        }
        .frame(minHeight: 330)
    }
}

/// The average colour of a cover, softened, for the show header background (cached per picture).
enum CoverColor {
    nonisolated(unsafe) private static var cache: [String: Color] = [:]

    static func average(for show: Show) -> Color? {
        let key = show.customArtwork ?? show.artworkURL ?? ""
        guard !key.isEmpty else { return nil }
        if let c = cache[key] { return c }
        let img = show.customArtwork.flatMap(ArtworkStore.localImage) ?? ArtworkStore.image(for: show.artworkURL)
        guard let img, let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let input = CIImage(cgImage: cg)
        guard let filter = CIFilter(name: "CIAreaAverage",
                                    parameters: [kCIInputImageKey: input, kCIInputExtentKey: CIVector(cgRect: input.extent)]),
              let out = filter.outputImage else { return nil }
        var px = [UInt8](repeating: 0, count: 4)
        CIContext(options: [.workingColorSpace: NSNull()]).render(out, toBitmap: &px, rowBytes: 4,
                                                                  bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                                                                  format: .RGBA8, colorSpace: nil)
        let c = Color(red: Double(px[0]) / 255, green: Double(px[1]) / 255, blue: Double(px[2]) / 255).opacity(0.55)
        cache[key] = c
        return c
    }
}

// MARK: - Floating player bar

struct PlayerBar: View {
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    @State private var showVolume = false
    @State private var artworkHover = false
    // PODCRAFT_EXPANDED (developer picture check only) starts with the progress bar open.
    @State private var progressHover = ProcessInfo.processInfo.environment["PODCRAFT_EXPANDED"] != nil
    @State private var progressHoverToken = UUID()
    @State private var speedHover = false
    @State private var sleepHover = false
    @State private var transcriptHover = false
    @State private var queueHover = false
    @Namespace private var playerGlass

    /// Transcript and queue buttons: faded while their panel is closed (like speed and sleep), full when open
    /// or under the pointer.
    func panelToggle(_ symbol: String, _ label: String, on: Bool, hover: Binding<Bool>, enabled: Bool,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 16, weight: .medium)).frame(width: 26, height: 26)
        }
        .buttonStyle(.borderless)
        .disabled(!enabled)
        .opacity(on || hover.wrappedValue ? 1 : 0.55)
        .onHover { hover.wrappedValue = $0 }
        .animation(.easeOut(duration: 0.14), value: on)
        .animation(.easeOut(duration: 0.14), value: hover.wrappedValue)
        .help(label)
        .accessibilityLabel(label)
    }

    var body: some View {
        @Bindable var p = player
        GlassEffectContainer(spacing: 24) {
            if player.episode != nil {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 9) {
                        speedMenu
                        iconButton("gobackward.15", "Back 15 Seconds", size: 17) { player.skipBack() }
                        Button { player.togglePlay() } label: {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 24, weight: .semibold))
                                .frame(width: 32, height: 32)
                                .contentTransition(.symbolEffect(.replace))
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.primary)
                        .help(player.isPlaying ? "Pause" : "Play")
                        iconButton("goforward.15", "Forward 15 Seconds", size: 17) { player.skipForward() }
                        sleepMenu
                        nowPlayingRegion
                        // Outside the title area, so it's centred in the bar like the buttons beside it.
                        moreMenu
                        panelToggle("quote.bubble", "Chapters & Transcript", on: player.showChapters, hover: $transcriptHover,
                                    enabled: player.episode != nil) { player.toggleTranscriptPanel() }
                        panelToggle("list.bullet", "Queue", on: player.showQueue, hover: $queueHover,
                                    enabled: true) { player.toggleQueuePanel() }
                        RoutePicker().frame(width: 26, height: 22).help("AirPlay")
                        Button { showVolume.toggle() } label: {
                            Image(systemName: player.volume == 0 ? "speaker.slash.fill" : "speaker.wave.3.fill")
                                .font(.system(size: 17, weight: .medium)).frame(width: 26, height: 26)
                        }
                        .buttonStyle(.borderless)
                        .help("Volume")
                        .popover(isPresented: $showVolume, arrowEdge: .top) {
                            HStack {
                                Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                                Slider(value: $p.volume, in: 0...1).frame(width: 160)
                                Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                            }
                            .padding(14)
                        }
                    }
                    // Keep the complete transport and progress scrubber visible at narrower widths.
                    // The compact layout is only needed once these controls genuinely stop fitting.
                    .frame(minWidth: 610)
                    compactBar
                }
                .foregroundStyle(.primary)
                .tint(.primary)
                .padding(.horizontal, 20)
                .padding(.vertical, 9)
                .podGlass(in: Capsule())
                .glassEffectID("persistent-player", in: playerGlass)
                .glassEffectTransition(.matchedGeometry)
                .frame(maxWidth: 1180)
                .padding(.horizontal, 28)
                .padding(.bottom, 14)
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
            } else {
                emptyBar
                    .padding(.horizontal, 14)
                    .padding(.vertical, 5)
                    .podGlass(in: Capsule())
                    .glassEffectID("persistent-player", in: playerGlass)
                    .glassEffectTransition(.matchedGeometry)
                    .frame(maxWidth: 250)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 14)
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
            }
        }
        .animation(.spring(duration: 0.55, bounce: 0.34), value: player.episodeID)
    }

    /// Cover, title and the more menu, with the thin progress line along the bottom. Hovering the line
    /// expands it in place, inside the same bar (as the Podcasts app does): what's behind blurs and fades,
    /// and a full-width scrubber with elapsed and remaining time sits on top until the pointer leaves.
    private var nowPlayingRegion: some View {
        VStack(spacing: 1) {
            nowPlaying.frame(maxWidth: .infinity)
            // The scrubber is a second row below the metadata. Compensate for
            // its height so the artwork/title block—not the combined two-row
            // stack—shares the transport controls' horizontal centerline.
            .padding(.top, 9)
            .blur(radius: progressHover ? 7 : 0)
            .opacity(progressHover ? 0.28 : 1)
            .allowsHitTesting(!progressHover)
            .overlay(alignment: .bottom) {
                // Keep the chapter legible during a scrub: the regular title behind this overlay
                // is deliberately blurred when the timeline expands on hover.
                if progressHover {
                    let chapterTitle = player.scrubPreviewChapterTitle ?? player.currentChapter?.title
                    VStack(alignment: .leading, spacing: 2) {
                        Text(chapterTitle ?? " ")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(player.scrubPreviewChapterTitle == nil ? Color.secondary : Color.podTeal)
                            .lineLimit(1)
                            .frame(height: 15, alignment: .leading)
                            .opacity(chapterTitle == nil ? 0 : 1)
                            .help(chapterTitle ?? "")
                        HStack {
                            Text(Fmt.clock(player.position))
                            Spacer()
                            Text("−" + Fmt.clock(max(0, player.duration - player.position) / player.rate))
                        }
                        .font(.title3.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.primary)
                    }
                    .padding(.bottom, 6)
                    .transition(.opacity.combined(with: .offset(y: 4)))
                }
            }
            // The progress lane: the thin line under the cover and title, from the cover's left edge.
            // Only this lane opens the scrubber. The lane keeps the thin line's height; the thicker bar keeps
            // the same bottom edge and grows upward from it (offset by the extra thickness).
            Scrubber(height: progressHover ? 6 : 3)
                .offset(y: progressHover ? 3 : 0)
                .frame(height: 9, alignment: .bottom)
                .contentShape(Rectangle().inset(by: -4))
                .onHover { inside in if inside { setProgressHover(true, delay: 80) } }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onHover { inside in if !inside { setProgressHover(false, delay: 160) } }
        .contextMenu { playingMenuItems }
        .animation(.spring(duration: 0.3, bounce: 0.15), value: progressHover)
    }

    private func setProgressHover(_ value: Bool, delay: Int) {
        let token = UUID()
        progressHoverToken = token
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(delay))
            guard progressHoverToken == token else { return }
            progressHover = value
        }
    }

    private var emptyBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "headphones")
                .font(.system(size: 14, weight: .medium))
            Text("Nothing Playing")
                .font(.caption.weight(.medium))
        }
        .foregroundStyle(.secondary)
        .frame(height: 28)
        .accessibilityElement(children: .combine)
    }

    private var compactBar: some View {
        HStack(spacing: 8) {
            iconButton("gobackward.15", "Back 15 Seconds", size: 16) { player.skipBack() }
            Button { player.togglePlay() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 21, weight: .semibold)).frame(width: 30, height: 30)
            }.buttonStyle(.borderless)
            iconButton("goforward.15", "Forward 15 Seconds", size: 16) { player.skipForward() }
            nowPlaying.frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .contextMenu { playingMenuItems }
            Menu {
                playingMenuItems
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 17, weight: .semibold)).frame(width: 28, height: 28)
            }
            .menuStyle(.button).menuIndicator(.hidden).buttonStyle(.borderless)
        }
        .frame(minWidth: 0)
    }

    // The middle: cover, title and date, with a thin progress line you can drag.
    var nowPlaying: some View {
        Group {
            if let e = player.episode {
                HStack(spacing: 12) {
                    Button { withAnimation(.smooth(duration: 0.25)) { player.cinemaMode = true } } label: {
                        ZStack {
                            EpisodeArtwork(episode: e, size: 48)
                            if artworkHover {
                                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.black.opacity(0.38))
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                                    .font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                            }
                        }
                        .frame(width: 48, height: 48)
                    }
                    .buttonStyle(.plain)
                    .onHover { artworkHover = $0 }
                    .help("Open Cinema Player")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(e.title).font(.callout.weight(.semibold)).lineLimit(1).help(e.title)
                        HStack(spacing: 5) {
                            Text(player.scrubPreviewChapterTitle ?? player.currentChapter?.title ?? Fmt.dateFormatter.string(from: e.published))
                                .lineLimit(1)
                            if canToggleVideo {
                                Text("·")
                                if player.showVideo || player.preparingYouTubeEpisodeID == e.id {
                                    Button { player.showAudioOnly() } label: {
                                        Label("Play audio", systemImage: "mic.fill")
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.secondary)
                                } else {
                                    Button {
                                        if player.videoPlayer != nil { player.showVideo = true }
                                        else { player.playYouTubeVideo(e.id) }
                                    } label: {
                                        Label("Play video", systemImage: "play.rectangle.fill")
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button { player.showsRemainingTime.toggle() } label: {
                        Text(player.showsRemainingTime
                             ? "−" + Fmt.clock(max(0, player.duration - player.position) / player.rate)
                             : Fmt.clock(player.position))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(player.showsRemainingTime ? "Show elapsed time" : "Show remaining time")
                }
            } else {
                Text("Playback and metadata appear here.").font(.callout).foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 190)
    }

    var speedMenu: some View {
        Menu {
            ForEach([0.5, 0.75, 0.8, 1.0, 1.2, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0], id: \.self) { r in
                Button { player.setRate(r) } label: {
                    if abs(player.rate - r) < 0.01 { Label(Fmt.speed(r), systemImage: "checkmark") } else { Text(Fmt.speed(r)) }
                }
            }
            Divider()
            Button("Custom Speed…") { player.showSpeedPanel = true }
        } label: {
            Text(Fmt.speed(player.rate).replacingOccurrences(of: ".0×", with: "×"))
                .font(.callout.weight(.semibold).monospacedDigit())
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.borderless)
        .fixedSize()
        .opacity(abs(player.rate - 1) < 0.01 && !speedHover ? 0.55 : 1)
        .onHover { speedHover = $0 }
        .animation(.easeOut(duration: 0.14), value: speedHover)
        .animation(.easeOut(duration: 0.14), value: player.rate)
        .help("Playback Speed")
        .popover(isPresented: Binding(get: { player.showSpeedPanel }, set: { player.showSpeedPanel = $0 }), arrowEdge: .top) { SpeedPanel() }
    }

    var sleepMenu: some View {
        Menu {
            Button("Off") { player.setSleep(minutes: nil) }
            ForEach([5, 10, 15, 30, 45, 60], id: \.self) { m in Button("\(m) Minutes") { player.setSleep(minutes: m) } }
            Button("End of Episode") { player.sleepAtEndOfEpisode() }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "moon.zzz.fill")
                if let left = player.sleepRemaining {
                    Text(Fmt.clock(left)).font(.caption2.monospacedDigit())
                }
            }
            .font(.system(size: 16))
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.borderless)
        .fixedSize()
        .opacity(player.sleepRemaining == nil && !player.sleepAtEnd && !sleepHover ? 0.55 : 1)
        .onHover { sleepHover = $0 }
        .animation(.easeOut(duration: 0.14), value: sleepHover)
        .animation(.easeOut(duration: 0.14), value: player.sleepRemaining)
        .animation(.easeOut(duration: 0.14), value: player.sleepAtEnd)
        .help("Sleep Timer")
    }

    /// The playing episode's menu: the "…" button and a right-click on the now-playing area show the same items.
    var playingMenuItems: some View { PlayingEpisodeMenuItems() }

    private var canToggleVideo: Bool {
        guard let episode = player.episode else { return false }
        if player.videoPlayer != nil { return true }
        return episode.youtubeID != nil && library.show(episode.showID)?.youtubeChannelURL != nil
    }

    var moreMenu: some View {
        Menu {
            playingMenuItems
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 17, weight: .semibold)).frame(width: 26, height: 26)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.borderless)
        .fixedSize()
        .help("More")
    }

    var chaptersMenu: some View {
        Menu {
            if player.chapters.isEmpty { Text("No chapters") }
            ForEach(Array(player.chapters.enumerated()), id: \.element.id) { i, c in
                Button { player.seek(to: c.start) } label: {
                    if i == player.currentChapterIndex {
                        Label("\(Fmt.clock(c.start))  \(c.title)", systemImage: "speaker.wave.2.fill")
                    } else {
                        Text("\(Fmt.clock(c.start))  \(c.title)")
                    }
                }
            }
        } label: {
            Image(systemName: "list.bullet").font(.system(size: 16, weight: .medium)).frame(width: 26, height: 26)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.borderless)
        .fixedSize()
        .help("Chapters")
    }

    func iconButton(_ symbol: String, _ label: String, size: CGFloat, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size, weight: .medium)).frame(width: 26, height: 26)
        }
        .buttonStyle(.borderless)
        .disabled(!enabled || player.episodeID == nil)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// The regular player and Cinema use one menu, with context-appropriate navigation.
struct PlayingEpisodeMenuItems: View {
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player

    @ViewBuilder var body: some View {
        if let episode = player.episode {
            if player.videoPlayer != nil {
                Button(player.showVideo ? "Hide Video" : "Show Video") { player.showVideo.toggle() }
            } else if episode.youtubeID != nil,
                      library.show(episode.showID)?.youtubeChannelURL != nil {
                Button("Show Video") { player.playYouTubeVideo(episode.id) }
            }
            Button("Go to Show") {
                player.cinemaMode = false
                if library.mode == .listen { library.listenSelection = .show(episode.showID) }
                else { library.manageSelection = .show(episode.showID) }
            }
            Button(episode.played ? "Mark as Unplayed" : "Mark as Played") {
                library.setPlayed(episode.id, !episode.played)
            }
            Button(player.cinemaMode ? "Close Cinema Player" : "Open Cinema Player") {
                withAnimation(.smooth(duration: 0.25)) { player.cinemaMode.toggle() }
            }
            Divider()
            Button("Previous Chapter") { player.previousChapter() }.disabled(!player.hasPreviousChapter)
            Button("Next Chapter") { player.nextChapter() }.disabled(!player.hasNextChapter)
            if episode.localFile != nil {
                Divider()
                Menu("Analyze Again") {
                    Button("Regenerate Chapters") { library.reanalyze(episode.id, retranscribe: false) }
                        .disabled(episode.transcript.isEmpty)
                    Button("Retranscribe & Analyze") { library.reanalyze(episode.id, retranscribe: true) }
                }
                .disabled(episode.stage.isWorking)
            } else if episode.stage == .listed {
                Divider()
                Button("Download & Analyze") { library.download(episode.id) }
            }
        } else {
            Text("Nothing playing")
        }
    }
}

/// AirPlay picker for the playing episode.
// MARK: - Cinema player

struct CinemaPlayerView: View {
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player

    var body: some View {
        @Bindable var p = player
        GeometryReader { geo in
            if let episode = player.episode {
                let show = library.show(episode.showID)
                let tint = show.flatMap(CoverColor.average) ?? Color.podTeal.opacity(0.35)
                ZStack {
                    // Solid base: the cinema is laid over the library, which must not show through.
                    Rectangle().fill(Color(nsColor: .windowBackgroundColor)).ignoresSafeArea()
                    Rectangle().fill(tint).ignoresSafeArea()
                    Rectangle().fill(.black.opacity(0.22)).ignoresSafeArea()

                    let panelOpen = player.showQueue || player.showChapters
                    // The queue/transcript takes one third of the Cinema width, including
                    // its trailing 24-point inset; the player keeps the other two thirds.
                    let panelWidth = geo.size.width / 3.0
                    HStack(spacing: 0) {
                        // The player; it moves left when the queue or transcript is open beside it.
                        VStack(spacing: 0) {
                            Spacer(minLength: 38)
                            if let video = player.videoPlayer, player.showVideo {
                                let presentation = video.currentItem?.presentationSize ?? .zero
                                let aspectRatio = presentation.width > 0 && presentation.height > 0
                                    ? presentation.width / presentation.height
                                    : 16 / 9
                                VideoSurface(player: video)
                                    .frame(maxWidth: min(geo.size.width * (panelOpen ? 0.4 : 0.58), 760),
                                           maxHeight: min(geo.size.height * 0.48, 520))
                                    .aspectRatio(aspectRatio, contentMode: .fit)
                                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                                    .shadow(color: .black.opacity(0.3), radius: 24, y: 10)
                            } else {
                                EpisodeArtwork(episode: episode, size: min(440, geo.size.height * 0.48))
                                    .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
                            }
                            Spacer(minLength: 22)
                            cinemaControls(episode, show: show)
                                .frame(maxWidth: 640)
                                .padding(.horizontal, 30)
                            Spacer(minLength: 30)
                        }
                        .frame(maxWidth: .infinity)
                        if panelOpen {
                            Group {
                                if player.showQueue { QueuePanel(onCinema: true) }
                                else { PlaybackInfoSidebar(episode: episode, showSearch: false, cinemaTint: tint) }
                            }
                            .frame(width: max(0, panelWidth - 24))
                            .frame(maxHeight: .infinity)
                            .padding(.top, 56)
                            .padding(.bottom, 90)
                            .padding(.trailing, 24)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                    }
                    .animation(.smooth(duration: 0.3), value: panelOpen)

                    // Bottom right: transcript and queue, the one that's open drawn filled.
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            HStack(spacing: 6) {
                                panelButton("quote.bubble", "Transcript", on: player.showChapters,
                                            enabled: true) { player.toggleTranscriptPanel() }
                                panelButton("list.bullet", "Queue", on: player.showQueue, enabled: true) { player.toggleQueuePanel() }
                            }
                            .padding(6)
                            .podGlass(in: Capsule())
                        }
                    }
                    .padding(18)

                    // Close and AirPlay + volume live in the window's title bar itself (title-bar accessories added
                    // by AppDelegate.watchCinema), so they're on the window buttons' line and always clickable.
                }
                .foregroundStyle(.primary).tint(.primary)
            }
        }
        .navigationTitle("")
    }

    private func panelButton(_ symbol: String, _ label: String, on: Bool, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 40, height: 40)
                .foregroundStyle(on ? Color.black : Color.primary)
                .background(on ? Color.white.opacity(0.92) : .clear, in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(label)
    }

    private func cinemaControls(_ episode: Episode, show: Show?) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 14) {
                EpisodeArtwork(episode: episode, size: 60)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(Fmt.dateFormatter.string(from: episode.published))
                        if canToggleVideo(episode) {
                            Text("·")
                            if player.showVideo || player.preparingYouTubeEpisodeID == episode.id {
                                Button { player.showAudioOnly() } label: {
                                    Label("Play audio", systemImage: "mic.fill")
                                }
                                .buttonStyle(.plain)
                            } else {
                                Button {
                                    if player.videoPlayer != nil { player.showVideo = true }
                                    else { player.playYouTubeVideo(episode.id) }
                                } label: {
                                    Label("Play video", systemImage: "play.rectangle.fill")
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Text(episode.title).font(.title3.bold()).lineLimit(2).help(episode.title)
                    Text(show?.title ?? "").font(.body).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Menu {
                    PlayingEpisodeMenuItems()
                } label: { Image(systemName: "ellipsis").font(.title3.bold()).frame(width: 38, height: 38) }
                    .menuStyle(.button).menuIndicator(.hidden).buttonStyle(.glass).buttonBorderShape(.circle)
            }
            if let chapterTitle = player.scrubPreviewChapterTitle ?? player.currentChapter?.title {
                HStack(spacing: 7) {
                    Image(systemName: "bookmark.fill")
                        .font(.caption)
                    Text(chapterTitle)
                        .lineLimit(1)
                        .help(chapterTitle)
                    Spacer(minLength: 0)
                }
                .font(.callout.weight(.medium))
                .foregroundStyle(player.scrubPreviewChapterTitle == nil ? Color.secondary : Color.podTeal)
            }
            Scrubber(height: 5, cinemaStyle: true)
            HStack {
                Text(Fmt.clock(player.position))
                Spacer()
                Text("−" + Fmt.clock(max(0, player.duration - player.position) / player.rate))
            }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            HStack {
                Button(Fmt.speed(player.rate)) { player.showSpeedPanel = true }
                    .font(.system(size: 19, weight: .semibold).monospacedDigit())
                    .frame(minWidth: 64, alignment: .leading)
                    .buttonStyle(.borderless)
                    .popover(isPresented: Binding(get: { player.showSpeedPanel }, set: { player.showSpeedPanel = $0 })) { SpeedPanel() }
                Spacer()
                Button { player.skipBack() } label: { Image(systemName: "gobackward.15") }
                Spacer()
                Button { player.togglePlay() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 40, weight: .semibold))
                        .frame(width: 60, height: 60)
                        .contentTransition(.symbolEffect(.replace))
                }
                .help(player.isPlaying ? "Pause" : "Play")
                Spacer()
                Button { player.skipForward() } label: { Image(systemName: "goforward.15") }
                Spacer()
                Menu {
                    Button("Off") { player.setSleep(minutes: nil) }
                    ForEach([5, 10, 15, 30, 45, 60], id: \.self) { m in
                        Button("\(m) Minutes") { player.setSleep(minutes: m) }
                    }
                    Button("End of Episode") { player.sleepAtEndOfEpisode() }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "moon.zzz.fill")
                            .font(.system(size: 25, weight: .medium))
                        if let remaining = player.sleepRemaining {
                            Text(Fmt.clock(remaining)).font(.caption2.monospacedDigit())
                        }
                    }
                    .frame(minWidth: 64, alignment: .trailing)
                }
                .menuStyle(.button).menuIndicator(.hidden)
                .help("Sleep Timer")
            }
            .font(.system(size: 25, weight: .medium)).buttonStyle(.borderless)
        }
    }

    private func canToggleVideo(_ episode: Episode) -> Bool {
        if player.videoPlayer != nil { return true }
        return episode.youtubeID != nil && library.show(episode.showID)?.youtubeChannelURL != nil
    }
}

/// Where the window's red/yellow/green buttons are: their right edge and their vertical centre from the window
/// top. Measured from the real buttons so the cinema controls sit on the same line. Only reports real changes.
struct TitlebarMetrics: NSViewRepresentable {
    struct Values: Equatable { var leading: CGFloat = 78; var centerY: CGFloat = 26 }
    @Binding var metrics: Values

    func makeNSView(context: Context) -> Probe {
        let v = Probe()
        v.report = { new in if new != metrics { metrics = new } }
        return v
    }
    func updateNSView(_ v: Probe, context: Context) {}

    final class Probe: NSView {
        var report: ((Values) -> Void)?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); measureSoon() }
        override func layout() { super.layout(); measureSoon() }
        private func measureSoon() { DispatchQueue.main.async { [weak self] in self?.measure() } }
        private func measure() {
            guard let w = window, let zoom = w.standardWindowButton(.zoomButton), let sup = zoom.superview else { return }
            let f = sup.convert(zoom.frame, to: nil)            // window coordinates, origin at the bottom left
            let values = Values(leading: f.maxX.rounded(), centerY: (w.frame.height - f.midY).rounded())
            report?(values)
        }
    }
}

/// Cinema player: close, on the line of the window buttons, just right of them.
struct CinemaCloseButton: View {
    @Environment(Player.self) private var player
    var body: some View {
        HStack(spacing: 6) {
            Button { withAnimation(.smooth(duration: 0.25)) { player.cinemaMode = false } } label: {
                Image(systemName: "xmark").font(.system(size: 15, weight: .semibold)).frame(width: 34, height: 34)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain).podGlass(in: Circle()).help("Close Cinema Player")
            .keyboardShortcut(.cancelAction)
            if player.videoPlayer != nil {
                Button { player.videoFullscreenRequest += 1 } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 13, weight: .semibold)).frame(width: 34, height: 34)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain).podGlass(in: Circle()).help("Full Screen Video")
            }
        }
    }
}

/// Cinema player: AirPlay and volume, top right on the window buttons' line.
struct CinemaAudioControls: View {
    @Environment(Player.self) private var player
    var body: some View {
        @Bindable var p = player
        HStack(spacing: 12) {
            RoutePicker().frame(width: 26, height: 22).help("AirPlay")
            Divider().frame(height: 18)
            Slider(value: $p.volume, in: 0...1).frame(width: 130).controlSize(.small)
            Image(systemName: player.volume == 0 ? "speaker.slash.fill" : "speaker.wave.3.fill")
                .font(.system(size: 15, weight: .medium))
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .contentShape(Capsule())
        .podGlass(in: Capsule())
    }
}

struct RoutePicker: NSViewRepresentable {
    @Environment(Player.self) private var player
    func makeNSView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.isRoutePickerButtonBordered = false
        v.player = player.avPlayerForRoutes
        return v
    }
    func updateNSView(_ v: AVRoutePickerView, context: Context) {
        let _ = player.episodeID
        v.player = player.avPlayerForRoutes
    }
}
