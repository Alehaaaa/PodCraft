import SwiftUI
import UniformTypeIdentifiers

// MARK: - Manage mode: everything you can change

/// Manage mode's sidebar: shows, feeds, downloads and settings (a native source list).
struct ManageSidebar: View {
    @Environment(Library.self) private var library

    var body: some View {
        @Bindable var lib = library
            List(selection: $lib.manageSelection) {
                Section("Shows") {
                    if library.shows.isEmpty {
                        Text("No shows yet").foregroundStyle(.secondary)
                    }
                    ForEach(library.sortedShows) { s in
                        HStack(spacing: 10) {
                            ShowArtwork(showID: s.id, size: 26)
                            Text(s.title).lineLimit(1)
                            Spacer()
                            let busy = library.episodes.contains { $0.showID == s.id && $0.stage.isWorking }
                            if busy {
                                ProgressView().controlSize(.mini)
                            } else {
                                Text("\(library.downloadedCount(s.id))")
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    .help("Episodes on this Mac")
                            }
                        }
                        .tag(SidebarItem.show(s.id))
                        .contextMenu {
                            Button("Copy PodCraft Feed Link") {
                                copy(library.server?.showURL(s) ?? "http://localhost:\(library.settings.hostPort)/shows/\(s.id.uuidString.lowercased()).xml")
                            }
                            if let url = library.server?.subscribeURL(app: "apple", show: s) {
                                Button("Open in Apple Podcasts") { NSWorkspace.shared.open(url) }
                                    .disabled(!library.settings.hostingEnabled)
                            }
                            Divider()
                            if s.feedURL != nil {
                                Button("Check for New Episodes") { Task { @MainActor in await library.refreshShow(s.id) } }
                            }
                            Menu("Add to Feed") {
                                Button("None") { library.setFeed(nil, forShow: s.id) }
                                ForEach(library.feeds) { f in Button(f.title) { library.setFeed(f.id, forShow: s.id) } }
                            }
                            Divider()
                            Button("Remove from Library", role: .destructive) { library.removeShow(s.id) }
                        }
                    }
                }
                Section("Feeds") {
                    ForEach(library.feeds) { f in
                        HStack(spacing: 10) {
                            ArtworkView(title: f.title, hue: f.hue, size: 26,
                                        borderHue: f.showsBorder ? f.borderHue : nil, borderWidth: f.showsBorder ? f.borderWidth : 0,
                                        symbol: "dot.radiowaves.left.and.right")
                            Text(f.title).lineLimit(1)
                            Spacer()
                            Text("\(library.shows(in: f.id).count)")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                .help("Shows in this feed")
                        }
                        .tag(SidebarItem.feed(f.id))
                        .contextMenu {
                            Button("Copy Podcast Feed Link") { copy(library.server?.feedURL(f) ?? f.privateLink) }
                            if let url = library.server?.subscribeURL(app: "apple", feed: f) {
                                Button("Open in Apple Podcasts") { NSWorkspace.shared.open(url) }
                                    .disabled(!library.settings.hostingEnabled)
                            }
                            Divider()
                            Button("Remove All Downloads") { library.removeAllDownloads(inFeed: f.id) }
                            Divider()
                            Button("Delete Feed", role: .destructive) { library.deleteFeed(f.id) }
                        }
                    }
                }
                Section("Library") {
                    HStack {
                        Label("Downloads", systemImage: "arrow.down.circle")
                        Spacer()
                        if !library.inProgress.isEmpty {
                            Text("\(library.inProgress.count)").font(.caption.monospacedDigit())
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(.tint.opacity(0.2), in: .capsule)
                        }
                    }
                    .tag(SidebarItem.downloads)
                    Label("Settings", systemImage: "gearshape").tag(SidebarItem.settings)
                }
            }
            .listStyle(.sidebar)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                HStack(spacing: 14) {
                    Button {
                        library.addShowTargetFeed = nil
                        library.showAddShow = true
                    } label: { Label("Add Show", systemImage: "plus") }
                    Button {
                        library.addFeed()
                    } label: { Label("New Feed", systemImage: "rectangle.stack.badge.plus") }
                    Spacer()
                }
                .buttonStyle(.borderless)
                .labelStyle(.titleAndIcon)
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        library.flash("Podcast feed link copied")
    }
}

/// Manage mode's main area: the selected show, feed, downloads or settings, with the player below.
struct ManageDetail: View {
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player

    var body: some View {
            Group {
                switch library.manageSelection {
                case .show(let id)? where library.show(id) != nil:
                    ShowManager(showID: id).id(id)
                case .feed(let id)? where library.feed(id) != nil:
                    FeedEditor(feedID: id).id(id)
                case .downloads?:
                    DownloadsView()
                case .settings?:
                    SettingsView()
                default:
                    WelcomeView()
                }
            }
        // Add Show, Import and Pause Downloads are native items in the window's toolbar (MainToolbar).
        .sheet(isPresented: Binding(get: { library.editingEpisode != nil }, set: { if !$0 { library.editingEpisode = nil } })) {
            if let id = library.editingEpisode { EpisodeEditor(episodeID: id) }
        }
    }

    static func importFiles(into library: Library) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.audio, .movie, .mpeg4Audio, .mp3]
        panel.message = "Add your own audio and video files"
        if panel.runModal() == .OK { library.importFiles(panel.urls) }
    }

    func importFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.audio, .movie, .mpeg4Audio, .mp3]
        panel.message = "Add your own audio and video files"
        if panel.runModal() == .OK { library.importFiles(panel.urls) }
    }
}

// MARK: Feed editor

struct FeedEditor: View {
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    let feedID: UUID
    @State private var confirmDelete = false
    @State private var episodeToDelete: UUID? = nil
    @State private var selectedEpisodes = Set<UUID>()

    var body: some View {
        if let index = library.feedIndex(feedID) {
            @Bindable var lib = library
            let feed = library.feeds[index]
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header(feed, index: index)
                    settingsCard(index: index)
                    showsCard(feed)
                    episodesCard(feed)
                }
                .padding(24)
                .frame(maxWidth: 980, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle(feed.title)
            .navigationSubtitle("\(library.shows(in: feedID).count) shows · \(library.playable(library.episodes(inFeed: feedID)).count) episodes on this Mac")
            .confirmationDialog("Delete this episode?", isPresented: Binding(get: { episodeToDelete != nil }, set: { if !$0 { episodeToDelete = nil } })) {
                Button("Delete Episode", role: .destructive) {
                    if let id = episodeToDelete {
                        if player.episodeID == id { player.stop() }
                        library.deleteEpisode(id)
                    }
                }
            }
            .confirmationDialog("Delete this feed?", isPresented: $confirmDelete) {
                Button("Delete \(feed.title)", role: .destructive) { library.deleteFeed(feedID) }
            } message: {
                Text("Only the feed is deleted. Its shows and their episodes stay in your library.")
            }
        }
    }

    func header(_ feed: Feed, index: Int) -> some View {
        @Bindable var lib = library
        return HStack(alignment: .top, spacing: 20) {
            ArtworkView(title: feed.title, hue: feed.hue, size: 132,
                        borderHue: feed.showsBorder ? feed.borderHue : nil,
                        borderWidth: feed.showsBorder ? feed.borderWidth : 0, symbol: "dot.radiowaves.left.and.right")
                .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
            VStack(alignment: .leading, spacing: 8) {
                TextField("Feed title", text: $lib.feeds[index].title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 26, weight: .bold))
                TextField("Author", text: $lib.feeds[index].author)
                    .textFieldStyle(.plain)
                    .foregroundStyle(.secondary)
                TextField("Description", text: $lib.feeds[index].summary, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(2...4)
                FeedLinkRow(feed: feed).padding(.top, 4)
            }
            Spacer(minLength: 0)
            Menu {
                Button("Remove All Downloads") { library.removeAllDownloads(inFeed: feedID) }
                Button("Delete Feed…", role: .destructive) { confirmDelete = true }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.button)
            .buttonStyle(.glass)
            .fixedSize()
        }
        .onChange(of: feed) { library.save() }
    }

    func settingsCard(index: Int) -> some View {
        @Bindable var lib = library
        let rule = library.feeds[index].keepRule ?? library.settings.keepRule
        return GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Toggle("Colored frame on the artwork", isOn: $lib.feeds[index].showsBorder)
                    Spacer()
                    if library.feeds[index].showsBorder {
                        Slider(value: $lib.feeds[index].borderHue, in: 0...1) { Text("Color") }
                            .frame(width: 160)
                        Stepper("Width \(Int(library.feeds[index].borderWidth))", value: $lib.feeds[index].borderWidth, in: 2...16)
                            .fixedSize()
                    }
                }
                Text("A colored frame around the artwork tells this feed apart from the original show in your podcast app.")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                KeepRulePicker(rule: Binding(get: { rule }, set: { lib.feeds[index].keepRule = $0; library.applyKeepRules() }),
                               usesDefault: library.feeds[index].keepRule == nil,
                               resetToDefault: { lib.feeds[index].keepRule = nil })
                Divider()
                Toggle("Keep this feed local only", isOn: $lib.feeds[index].localOnly)
            }
            .padding(6)
        } label: {
            Label("Feed Settings", systemImage: "slider.horizontal.3")
        }
    }

    func showsCard(_ feed: Feed) -> some View {
        GroupBox {
            VStack(spacing: 0) {
                let list = library.shows(in: feedID)
                if list.isEmpty {
                    Text("Group the shows and files you want to follow into one feed.")
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity).padding()
                }
                ForEach(list) { s in
                    HStack(spacing: 12) {
                        ShowArtwork(showID: s.id, size: 36)
                        VStack(alignment: .leading) {
                            Text(s.title).fontWeight(.medium)
                            Text(s.feedURL ?? (s.isFiles ? "Your own audio and video files" : s.author))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Text("\(library.downloadedCount(s.id)) on this Mac").font(.caption).foregroundStyle(.secondary)
                        Button("Remove from Feed") { library.setFeed(nil, forShow: s.id) }
                            .controlSize(.small)
                    }
                    .padding(.vertical, 6)
                    if s.id != list.last?.id { Divider() }
                }
                HStack {
                    let others = library.sortedShows.filter { $0.feedID != feedID }
                    Menu {
                        ForEach(others) { s in Button(s.title) { library.setFeed(feedID, forShow: s.id) } }
                        if !others.isEmpty { Divider() }
                        Button("Add a New Show…") { library.addShowTargetFeed = feedID; library.showAddShow = true }
                    } label: { Label("Add a Show to This Feed", systemImage: "plus") }
                        .fixedSize()
                    Spacer()
                }
                .padding(.top, 8)
            }
            .padding(6)
        } label: {
            Label("Shows in This Feed", systemImage: "square.stack")
        }
    }

    func episodesCard(_ feed: Feed) -> some View {
        GroupBox {
            let list = library.episodes(inFeed: feedID).filter { $0.stage != .listed }
            VStack(spacing: 0) {
                if list.isEmpty {
                    Text("Downloaded episodes of this feed’s shows appear here and in the feed.")
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity).padding()
                }
                ForEach(list) { e in
                    ManageEpisodeRow(episode: e, onDelete: { episodeToDelete = e.id })
                    if e.id != list.last?.id { Divider() }
                }
            }
            .padding(6)
        } label: {
            Label("Episodes in the Feed", systemImage: "list.bullet")
        }
    }
}

struct ManageEpisodeRow: View {
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    let e: Episode
    var onDelete: () -> Void

    init(episode: Episode, onDelete: @escaping () -> Void) {
        self.e = episode
        self.onDelete = onDelete
    }

    var body: some View {
        HStack(spacing: 12) {
            EpisodeArtwork(episode: e, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if player.episodeID == e.id {
                        Image(systemName: "speaker.wave.2.fill").foregroundStyle(.tint).font(.caption)
                    }
                    Text(e.title).fontWeight(e.played ? .regular : .medium)
                        .foregroundStyle(e.played ? .secondary : .primary).lineLimit(1)
                    if e.youtubeMatchState == .matched, e.youtubeID != nil {
                        Button { player.playYouTubeVideo(e.id) } label: { VideoSourceBadge(episode: e, compact: true) }
                            .buttonStyle(.borderless).font(.caption2)
                    } else if e.isVideo {
                        VideoSourceBadge(episode: e, compact: true).font(.caption2)
                    }
                    if e.keepForever {
                        Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.tint).help("Kept until you delete it manually")
                    }
                }
                HStack(spacing: 6) {
                    Text(library.show(e.showID)?.title ?? "")
                    Text("·")
                    Text(Fmt.date(e.published))
                    if e.duration > 0 { Text("·"); Text(Fmt.length(e.duration)) }
                    if e.chapters.count > 0 { Text("·"); Text("\(e.chapters.count) chapters") }
                    if e.adSecondsRemoved > 0 { Text("·"); Text("\(Int(e.adSecondsRemoved)) s of sponsors cut") }
                }
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            // Identical control order for listed, working, failed and ready episodes.
            // Status is always the first slot; no extra Retry/Cancel/Trash buttons
            // appear outside the shared More menu.
            downloadControl
                .frame(width: 180, alignment: .trailing)
            Button {
                if player.episodeID == e.id && player.isPlaying { player.togglePlay() }
                else { player.play(e.id) }
            } label: {
                Image(systemName: player.episodeID == e.id && player.isPlaying ? "pause.fill" :
                      (player.preparingYouTubeEpisodeID == e.id ? "hourglass" :
                       (e.played ? "checkmark.circle.fill" : "play.fill")))
                    .frame(width: 19, height: 19)
            }
            .buttonStyle(.borderless)
            .disabled(!e.canPlay)
            .help(player.preparingYouTubeEpisodeID == e.id ? "Connecting video" :
                  (!e.canPlay ? "Unavailable to play" :
                  (player.episodeID == e.id && player.isPlaying ? "Pause" :
                   (e.played ? "Played · Play Again" : "Play"))))

            Button { library.editingEpisode = e.id } label: {
                Image(systemName: "pencil").frame(width: 19, height: 19)
            }
            .buttonStyle(.borderless)
            .help("Edit Metadata…")

            Menu { episodeActions } label: {
                Image(systemName: "ellipsis.circle").frame(width: 19, height: 19)
            }
            .menuStyle(.button).buttonStyle(.borderless).fixedSize()
            .help("More episode actions")
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if e.canPlay { player.play(e.id) } }
        .contextMenu { episodeActions }
    }

    @ViewBuilder
    private var downloadControl: some View {
        if player.preparingYouTubeEpisodeID == e.id {
            HStack(spacing: 7) {
                Image(systemName: "play.rectangle.fill").foregroundStyle(Color.podTeal)
                Text(player.youtubePreparationStatus ?? "Preparing YouTube…")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text("\(Int((player.youtubePreparationProgress * 100).rounded()))%")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        } else { switch e.stage {
        case .listed:
            Button { library.download(e.id) } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }
            .controlSize(.small)
            .help("Download and process this episode (including if already played)")
        case .ready:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.tint)
                .help("Downloaded · On this Mac")
        case .failed:
            Button {
                if e.localFile != nil { library.processor?.reprocess(e.id) }
                else { library.download(e.id) }
            } label: { Label("Retry", systemImage: "arrow.clockwise") }
                .controlSize(.small)
                .help(e.note ?? "Retry download or processing")
        default:
            HStack(spacing: 7) {
                Image(systemName: e.stage.symbol).foregroundStyle(.secondary)
                Text(e.stage == .queued ? "Queued" :
                     (e.stage == .downloading ? "Downloading" : "Processing"))
                    .font(.caption).foregroundStyle(.secondary)
                ProgressView(value: min(1, max(0, e.progress)))
                    .frame(width: 46)
            }
            .help(e.note ?? e.stage.label)
        }
        }
    }

    @ViewBuilder
    private var episodeActions: some View {
        Button("Edit Metadata…") { library.editingEpisode = e.id }
        if e.youtubeMatchState == .matched, e.youtubeID != nil {
            Button("Show Video") { player.playYouTubeVideo(e.id) }
        } else if e.youtubeMatchState == .notFound,
                  library.show(e.showID)?.youtubeChannelURL != nil {
            Button("Find YouTube Match Again") { library.retryYouTubeMatch(forEpisode: e.id) }
        }
        if e.canPlay && player.episodeID != e.id {
            Button("Play Next") { player.playNext(e.id) }
            Button("Add to Queue") { player.addToQueue(e.id) }
        }
        Button(e.played ? "Mark as Unplayed" : "Mark as Played") {
            library.setPlayed(e.id, !e.played)
        }
        Button(e.keepForever ? "Allow Automatic Deletion" : "Keep Until I Delete It") {
            if let i = library.episodeIndex(e.id) {
                library.episodes[i].keepForever.toggle()
                library.save()
            }
        }
        Divider()
        if e.stage.isWorking && e.localFile == nil {
            Button("Cancel Download") { library.removeDownload(e.id) }
        } else if e.localFile != nil && !(e.audioURL?.hasPrefix("file:") ?? true) {
            Button("Remove Download") {
                if player.episodeID == e.id { player.stop() }
                library.removeDownload(e.id)
            }
        } else if e.stage == .listed || e.stage == .failed || e.localFile != nil {
            Button("Delete Episode…", role: .destructive, action: onDelete)
        }
    }
}

struct KeepRulePicker: View {
    @Binding var rule: KeepRule
    var usesDefault: Bool? = nil
    var resetToDefault: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Keep episodes by", selection: Binding(get: { rule.kind }, set: { k in
                    switch k {
                    case 0: rule = .forever
                    case 1: rule = .days(Mechanics.defaultKeepDays)
                    default: rule = .newest(Mechanics.defaultKeepNewest)
                    }
                })) {
                    Text("Keep every episode").tag(0)
                    Text("Delete after a set time").tag(1)
                    Text("Keep a set number per feed").tag(2)
                }
                .fixedSize()
                switch rule {
                case .days(let d):
                    Stepper("\(d) days", value: Binding(get: { d }, set: { rule = .days($0) }), in: 1...365).fixedSize()
                case .newest(let n):
                    Stepper("Keep newest \(n)", value: Binding(get: { n }, set: { rule = .newest($0) }), in: 1...200).fixedSize()
                case .forever:
                    EmptyView()
                }
                Spacer()
                if let usesDefault, let resetToDefault {
                    if usesDefault {
                        Text("Using the app setting").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Button("Use App Setting", action: resetToDefault).controlSize(.small)
                    }
                }
            }
            Text("Episodes are \(rule.describe().prefix(1).lowercased())\(rule.describe().dropFirst())")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: Episode metadata and chapter editor

struct EpisodeEditor: View {
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    @Environment(\.dismiss) private var dismiss
    let episodeID: UUID
    @State private var draft: Episode? = nil
    @State private var originalDraft: Episode? = nil
    @State private var error: String? = nil
    @State private var youtubeText = ""
    @State private var fetching = false
    @State private var showTranscript = false
    @State private var showCutEditor = false
    @State private var generating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if draft != nil {
                let binding = Binding(get: { draft! }, set: { draft = $0 })
                Text("Edit Metadata").font(.title2.bold())
                Form {
                    TextField("Title", text: binding.title)
                    TextField("Description", text: binding.summary, axis: .vertical).lineLimit(3...6)
                    DatePicker("Published", selection: binding.published, displayedComponents: .date)
                    Toggle("Keep until I delete it manually", isOn: binding.keepForever)
                    LabeledContent("Length", value: Fmt.clock(draft!.duration))
                    if let note = draft!.note { Text(note).font(.caption).foregroundStyle(.orange) }
                }
                .formStyle(.grouped)
                .frame(maxHeight: 250)
                Form {
                    HStack {
                        TextField("YouTube link for SponsorBlock", text: $youtubeText)
                        Button(fetching ? "Fetching…" : "Fetch Segments") { fetchSegments() }
                            .disabled(fetching || youtubeText.isEmpty)
                            .help("SponsorBlock timestamps only match the exact YouTube recording being played. RSS regional ad insertion can shift the timeline.")
                    }
                    HStack {
                        Label("Sponsor Cuts", systemImage: "scissors")
                        Spacer()
                        Text("\(draft!.cuts.count) \(draft!.cuts.count == 1 ? "cut" : "cuts")")
                            .font(.caption).foregroundStyle(.secondary)
                        Button { showCutEditor = true } label: {
                            Text("Edit…")
                        }
                        .disabled(fetching)
                        .help("Adjust sponsor skips on the original waveform")
                    }
                    let cuts = draft!.cuts
                    if !cuts.isEmpty {
                        Text("\(Int(cuts.reduce(0) { $0 + $1.length })) seconds marked to skip")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("Process Again") {
                            if var d = draft { d.youtubeID = SponsorBlock.videoID(from: youtubeText); draft = d }
                            if commit() {
                                library.processor?.reprocess(episodeID)
                                dismiss()
                            }
                        }
                        .disabled(draft!.stage == .listed || draft!.isSample)
                        .help(draft!.stage == .listed ? "Download the episode first" : "Download, transcribe, find sponsors and cut again")
                        Spacer()
                        let live = library.episode(episodeID)
                        let transcriptCount = live?.transcript.count ?? draft!.transcript.count
                        Button("Transcript (\(transcriptCount) lines)") { showTranscript = true }
                            .disabled(transcriptCount == 0 && live?.stage != .transcribing)
                    }
                }
                .formStyle(.grouped)
                HStack {
                    Text("Chapters").font(.headline)
                    Spacer()
                    Button {
                        // Chapters are persisted in ORIGINAL source seconds, not the skip-compressed timeline.
                        let t = player.episodeID == episodeID ? player.sourcePosition : 0
                        draft!.chapters.append(Chapter(start: t.rounded(), title: "New Chapter"))
                    } label: { Label("Add Chapter at Playhead", systemImage: "plus") }
                    Button(generating ? "Generating…" : "Generate Chapters") { generateChapters() }
                        .disabled(generating || draft!.transcript.isEmpty || library.settings.aiProvider == .off)
                        .help(draft!.transcript.isEmpty ? "Chapters are generated from the transcript, made when the episode is downloaded" : "Ask the AI for chapters")
                }
                List {
                    ForEach(binding.chapters) { $c in
                        HStack {
                            TextField("Start", value: $c.start, format: .number)
                                .frame(width: 70)
                                .help("Start time in seconds")
                            Text(Fmt.clock(c.start)).monospacedDigit().foregroundStyle(.secondary).frame(width: 60)
                            TextField("Chapter title", text: $c.title)
                            Button(role: .destructive) {
                                draft!.chapters.removeAll { $0.id == c.id }
                            } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                        }
                    }
                }
                .frame(minHeight: 160)
                if let error { Text(error).foregroundStyle(.red).font(.callout) }
                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Save") { save() }.keyboardShortcut(.defaultAction).buttonStyle(.glassProminent)
                }
            }
        }
        .padding(22)
        .frame(width: 620, height: 780)
        .onAppear {
            draft = library.episode(episodeID)
            originalDraft = draft
            youtubeText = draft?.youtubeID.map { "https://www.youtube.com/watch?v=\($0)" } ?? ""
        }
        .sheet(isPresented: $showTranscript) {
            TranscriptView(lines: draft?.transcript ?? [], episodeID: episodeID).frame(width: 560, height: 520)
        }
        .sheet(isPresented: $showCutEditor) {
            if let episode = draft {
                SponsorCutEditor(episodeID: episodeID,
                                 sourceURL: episode.sourceURL,
                                 fallbackDuration: max(episode.duration,
                                                       episode.cuts.map(\.end).max() ?? 0),
                                 cuts: Binding(get: { draft?.cuts ?? [] },
                                               set: { draft?.cuts = $0 }))
            }
        }
    }

    func fetchSegments() {
        guard !showCutEditor else { return }
        guard let id = SponsorBlock.videoID(from: youtubeText) else { error = SponsorBlock.Failure.badID.errorDescription; return }
        guard draft?.youtubeMediaID == id else {
            error = "This episode is not using that YouTube recording. Link its show to the official channel and process with YouTube first; RSS regional ads have different timestamps."
            return
        }
        fetching = true; error = nil
        Task { @MainActor in
            do {
                let segs = try await SponsorBlock.segments(videoID: id, categories: library.settings.sponsorCategories)
                draft?.youtubeID = id
                draft?.cuts.removeAll { $0.source == "SponsorBlock" }
                draft?.cuts += segs
                if segs.isEmpty { error = "SponsorBlock has no segments for this video yet." }
            } catch { self.error = error.localizedDescription }
            fetching = false
        }
    }

    func generateChapters() {
        guard let d = draft else { return }
        generating = true; error = nil
        Task { @MainActor in
            do {
                let found = try await AIService.chapters(lines: d.transcript, duration: d.duration, provider: library.settings.aiProvider,
                                                         model: library.settings.geminiModel, findSponsors: false)
                if !found.chapters.isEmpty { draft?.chapters = found.chapters } else { error = "The AI found no chapters." }
            } catch { self.error = error.localizedDescription }
            generating = false
        }
    }

    @discardableResult
    func commit() -> Bool {
        guard let d = draft, let i = library.episodeIndex(episodeID) else { return false }
        return writeEditedFields(d, at: i)
    }

    func save() {
        guard var d = draft, let i = library.episodeIndex(episodeID) else { dismiss(); return }
        if let activeID = library.episodes[i].youtubeMediaID ?? d.youtubeMediaID {
            if let enteredID = SponsorBlock.videoID(from: youtubeText), enteredID != activeID {
                error = "The video link must match the recording used by this episode (\(activeID))."
                return
            }
            d.youtubeID = activeID
        } else {
            d.youtubeID = SponsorBlock.videoID(from: youtubeText) ?? (youtubeText.isEmpty ? nil : d.youtubeID)
        }
        let starts = d.chapters.map { $0.start }
        if Set(starts).count != starts.count { error = "Chapter start times must be unique."; return }
        if d.chapters.contains(where: { $0.start < 0 || ($0.start > d.duration && d.duration > 0) }) {
            error = "Chapter start times must be inside the episode."; return
        }
        if d.cuts.contains(where: { !$0.start.isFinite || !$0.end.isFinite || $0.start < 0 || $0.end <= $0.start }) {
            error = "Sponsor cuts need a valid start and an end after the start in source seconds."; return
        }
        if Set(d.cuts.map(\.id)).count != d.cuts.count {
            error = "Cut ranges must have unique identifiers."; return
        }
        guard writeEditedFields(d, at: i) else { return }
        dismiss()
    }

    /// The processor may update transcription, playback source, stage and progress while
    /// this draft sheet is open. Apply only editable fields instead of replacing the
    /// entire live Episode with a stale copy and losing recognized transcript lines.
    @discardableResult
    private func writeEditedFields(_ draft: Episode, at index: Int) -> Bool {
        var live = library.episodes[index]
        if draft.cuts != originalDraft?.cuts,
           originalDraft?.sourceURL != live.sourceURL {
            error = "The recording changed while this editor was open. Reopen it to edit cuts in the current source timeline."
            return false
        }
        live.title = draft.title
        live.summary = draft.summary
        live.published = draft.published
        live.keepForever = draft.keepForever
        if draft.youtubeID != originalDraft?.youtubeID { live.youtubeID = draft.youtubeID }
        if draft.chapters != originalDraft?.chapters {
            live.chapters = draft.chapters.sorted { $0.start < $1.start }
        }
        if draft.cuts != originalDraft?.cuts {
            live.cuts = draft.cuts.sorted { $0.start < $1.start }
        }
        let timeline = SponsorTimeline(sourceDuration: live.duration, cuts: live.cuts)
        live.adSecondsRemoved = max(0, live.duration - timeline.duration)
        library.episodes[index] = live
        library.save()
        if player.episodeID == episodeID { player.refreshSkipMetadata() }
        return true
    }
}

// MARK: Downloads

struct DownloadsView: View {
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    @State private var downloadToRemove: UUID?

    private var downloadedEpisodes: [Episode] {
        library.episodes
            .filter { episode in
                [episode.localFile, episode.originalLocalFile]
                    .compactMap { $0 }
                    .contains { FileManager.default.fileExists(atPath: $0) }
            }
            .sorted { $0.published > $1.published }
    }

    private func canRemoveDownload(_ episode: Episode) -> Bool {
        episode.audioURL != nil && !(library.show(episode.showID)?.isFiles ?? false)
    }

    var body: some View {
        let active = library.inProgress
        let downloaded = downloadedEpisodes
        List {
            Section {
                if active.isEmpty {
                    ContentUnavailableView("No active processes", systemImage: "checkmark.circle",
                                           description: Text("Downloads and processing tasks will appear here when they start."))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                } else {
                    ForEach(active) { episode in
                        activeRow(episode)
                    }
                }
            } header: {
                Label("Active Processes (\(active.count))", systemImage: "arrow.triangle.2.circlepath")
            }
            Section {
                if downloaded.isEmpty {
                    ContentUnavailableView("No downloaded episodes", systemImage: "arrow.down.circle",
                                           description: Text("Download a show episode to manage its local copy here."))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                } else {
                    ForEach(downloaded) { episode in
                        downloadedRow(episode)
                    }
                }
            } header: {
                Label("Downloaded (\(downloaded.count))", systemImage: "checkmark.circle")
            }
        }
        .listStyle(.inset)
        .navigationTitle("Downloads")
        .navigationSubtitle("\(downloaded.count) on this Mac · \(active.count) active\(library.downloadsPaused ? " (paused)" : "")")
        .confirmationDialog("Remove downloaded copy?", isPresented: Binding(
            get: { downloadToRemove != nil }, set: { if !$0 { downloadToRemove = nil } })) {
            Button("Remove Download", role: .destructive) {
                if let id = downloadToRemove {
                    if player.episodeID == id { player.stop() }
                    library.removeDownload(id)
                }
            }
        } message: {
            Text("The downloaded media will be removed from this Mac. The episode stays in your library and can be downloaded again.")
        }
    }

    private func activeRow(_ episode: Episode) -> some View {
        HStack(alignment: .center, spacing: 14) {
            EpisodeArtwork(episode: episode, size: 42)
            VStack(alignment: .leading, spacing: 4) {
                Text(episode.title).fontWeight(.medium).lineLimit(1)
                Text(library.show(episode.showID)?.title ?? "")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text(episode.stage.label)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            ProcessingStatus(episode: episode)
                .frame(minWidth: 200, idealWidth: 290, maxWidth: 360)
            if episode.localFile == nil, canRemoveDownload(episode) {
                Button("Cancel") { library.removeDownload(episode.id) }
                    .controlSize(.small)
                    .help("Cancel the download and keep the episode in your library")
            }
        }
        .padding(.vertical, 5)
    }

    private func downloadedRow(_ episode: Episode) -> some View {
        HStack(spacing: 12) {
            EpisodeArtwork(episode: episode, size: 42)
            VStack(alignment: .leading, spacing: 4) {
                Text(episode.title).fontWeight(.medium).lineLimit(1)
                HStack(spacing: 6) {
                    Text(library.show(episode.showID)?.title ?? "Imported file")
                    Text("·")
                    Text(Fmt.date(episode.published))
                    if episode.duration > 0 {
                        Text("·")
                        Text(Fmt.length(episode.duration))
                    }
                    if episode.stage.isWorking {
                        Text("·")
                        Text(episode.stage.label)
                    }
                }
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 12)
            Button {
                if player.episodeID == episode.id && player.isPlaying {
                    player.togglePlay()
                } else {
                    player.play(episode.id)
                }
            } label: {
                Label(player.episodeID == episode.id && player.isPlaying ? "Pause" : "Play",
                      systemImage: player.episodeID == episode.id && player.isPlaying ? "pause.fill" : "play.fill")
            }
            .disabled(!episode.canPlay)
            Button("Manage") { library.editingEpisode = episode.id }
            Button(role: .destructive) {
                downloadToRemove = episode.id
            } label: {
                Label("Remove Download", systemImage: "trash")
            }
            .disabled(!canRemoveDownload(episode))
            .help(canRemoveDownload(episode)
                  ? "Remove the media while keeping this episode in your library"
                  : "Imported files are kept in your library")
        }
        .controlSize(.small)
        .padding(.vertical, 5)
    }
}

// MARK: Settings

struct SettingsView: View {
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    @State private var confirmReset = false

    var body: some View {
        @Bindable var lib = library
        Form {
            Section {
                Stepper("New shows keep the newest \(library.settings.defaultAvailable) on this Mac",
                        value: $lib.settings.defaultAvailable, in: 0...50)
            } header: {
                Text("Shows")
            } footer: {
                Text("Every episode of a show is listed. Only the newest ones are downloaded and processed; download any other by hand. Each show can change this on its own page.")
            }
            Section("Feeds") {
                KeepRulePicker(rule: Binding(get: { library.settings.keepRule },
                                             set: { lib.settings.keepRule = $0; library.applyKeepRules() }))
            }
            AISettingsSection()
            HostingSettingsSection()
            PhonePairingSection()
            Section("Playback") {
                LabeledContent("Skip back / forward", value: "\(Int(Mechanics.skipBackSeconds)) s / \(Int(Mechanics.skipForwardSeconds)) s")
                HStack {
                    Text("Default speed")
                    Slider(value: Binding(get: { library.settings.defaultSpeed },
                                          set: { lib.settings.defaultSpeed = (($0 / 0.05).rounded() * 0.05); player.setRate(lib.settings.defaultSpeed) }),
                           in: Mechanics.minSpeed...Mechanics.maxSpeed)
                    Text(Fmt.speed(library.settings.defaultSpeed)).monospacedDigit().frame(width: 50)
                }
            }
            Section("Lifetime") {
                LabeledContent("Listened", value: Fmt.hours(library.metrics.listenedSeconds))
                LabeledContent("Saved by speed", value: Fmt.hours(library.metrics.speedSavedSeconds))
                LabeledContent("Sponsor time removed", value: Fmt.hours(library.metrics.adSecondsRemoved))
                LabeledContent("Episodes finished", value: "\(library.metrics.episodesFinished)")
                LabeledContent("Episodes processed", value: "\(library.metrics.episodesProcessed)")
            }
            Section("Library") {
                HStack {
                    Button("Back Up Library…") { backup() }
                    Button("Restore Library…") { restore() }
                    OPMLButtons()
                    Spacer()
                    Button("Delete library data and media", role: .destructive) { confirmReset = true }
                }
                Text("Back up your feeds, subscriptions, settings, lifetime metrics and the list of downloaded episodes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .onChange(of: library.settings) { library.save() }
        .confirmationDialog("Delete library data and media?", isPresented: $confirmReset) {
            Button("Delete and Start Over", role: .destructive) { player.stop(); library.resetLibrary() }
        } message: { Text("All shows, feeds and downloaded episodes are removed. Settings stay.") }
    }

    func backup() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "PodCraft Library.json"
        panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url {
            do { try library.exportBackup(to: url); library.flash("Library backed up") }
            catch { library.flash("Back up failed: \(error.localizedDescription)") }
        }
    }

    func restore() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.message = "Choose a library backup to restore."
        if panel.runModal() == .OK, let url = panel.url {
            do { player.stop(); try library.restoreBackup(from: url); library.flash("Library restored") }
            catch { library.flash("Restore failed: \(error.localizedDescription)") }
        }
    }
}
