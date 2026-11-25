import AppKit
import AVKit
import SwiftUI

/// Scrubber with chapter marks, like the original's PlayerStripScrubber.
struct Scrubber: View {
    @Environment(Player.self) private var player
    var height: CGFloat = 6
    var cinemaStyle = false
    @State private var dragValue: Double? = nil
    @State private var hovering = false
    @State private var snappedChapterID: UUID?
    @State private var haptickedChapterIDs: Set<UUID> = []
    @State private var dragEpisodeID: UUID?

    /// The snap radius is expressed in screen points, not seconds. A fixed time tolerance
    /// would feel far too wide on a short clip and almost impossible on a long episode.
    private func snapRadius(for width: CGFloat) -> CGFloat {
        min(cinemaStyle ? 16 : 12, max(8, width * 0.025))
    }

    private func chapterNear(_ x: CGFloat, width: CGFloat, duration: Double) -> Chapter? {
        guard width > 1, duration > 0, duration.isFinite else { return nil }
        let radius = snapRadius(for: width)
        return player.chapters
            .filter { $0.start.isFinite && $0.start > 0 && $0.start < duration }
            .min(by: { abs(CGFloat($0.start / duration) * width - x) < abs(CGFloat($1.start / duration) * width - x) })
            .flatMap { abs(CGFloat($0.start / duration) * width - x) <= radius ? $0 : nil }
    }

    private func scrubTime(at location: CGFloat, width: CGFloat, duration: Double, marker: Chapter?) -> Double {
        guard width > 1, duration.isFinite, duration > 0 else { return 0 }
        let x = min(width, max(0, location))
        guard let marker else { return Double(x / width) * duration }
        let chapterX = CGFloat(marker.start / duration) * width
        let proximity = max(0, 1 - abs(chapterX - x) / snapRadius(for: width))
        // Light, continuous pull near a marker; the exact snap is committed on mouse release.
        let drawnX = x + (chapterX - x) * proximity * proximity
        return Double(drawnX / width) * duration
    }

    private func updateDrag(_ value: DragGesture.Value, width: CGFloat, duration: Double) {
        guard width > 1, let episodeID = player.episodeID else { return }
        if dragEpisodeID == nil {
            dragEpisodeID = episodeID
            haptickedChapterIDs.removeAll()
        }
        guard dragEpisodeID == episodeID else { return }
        let x = min(width, max(0, value.location.x))
        let chapter = chapterNear(x, width: width, duration: duration)
        dragValue = scrubTime(at: x, width: width, duration: duration, marker: chapter)
        snappedChapterID = chapter?.id
        player.scrubPreviewChapterTitle = chapter?.title

        // A click is also a zero-distance DragGesture; never haptic for it. Track IDs for
        // the whole gesture so hovering back and forth over one marker cannot spam taps.
        let moved = hypot(value.translation.width, value.translation.height) > 3
        if moved, let id = chapter?.id, haptickedChapterIDs.insert(id).inserted {
            // The default performer safely does nothing on Macs without haptic hardware.
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }

    private func finishDrag(_ value: DragGesture.Value, width: CGFloat, duration: Double) {
        defer { clearDrag() }
        guard width > 1, player.episodeID != nil, dragEpisodeID == player.episodeID else { return }
        let x = min(width, max(0, value.location.x))
        let chapter = chapterNear(x, width: width, duration: duration)
        // Release directly on the marker, regardless of the eased visual pull while dragging.
        player.seek(to: chapter?.start ?? Double(x / width) * duration)
    }

    private func clearDrag() {
        dragValue = nil
        snappedChapterID = nil
        dragEpisodeID = nil
        haptickedChapterIDs.removeAll()
        player.scrubPreviewChapterTitle = nil
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let d = max(player.duration, 1)
            let shown = dragValue ?? player.position
            let frac = min(1, max(0, shown / d))
            let expanded = cinemaStyle && (hovering || dragValue != nil)
            let trackHeight = expanded ? 9.0 : height
            let markerHeight = expanded ? 18.0 : height
            let markerWidth = expanded ? 3.0 : 2.0
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.12))
                Capsule().fill(Color.podTeal)
                    .frame(width: max(trackHeight, w * frac))
                ForEach(player.chapters.filter { $0.start.isFinite && $0.start > 0 && $0.start < d }) { c in
                    let snapped = dragValue != nil && snappedChapterID == c.id
                    Rectangle()
                        .fill(snapped ? Color.podTeal : Color.primary.opacity(0.72))
                        .frame(width: snapped ? markerWidth + 2 : markerWidth,
                               height: snapped ? markerHeight + 5 : markerHeight)
                        .shadow(color: Color.podTeal.opacity(snapped ? 0.6 : 0), radius: snapped ? 5 : 0)
                        .offset(x: w * c.start / d - (snapped ? markerWidth + 2 : markerWidth) / 2)
                }
                Circle()
                    .fill(snappedChapterID == nil ? Color.white : Color.podTeal)
                    .shadow(color: snappedChapterID == nil ? .black.opacity(0.25) : Color.podTeal.opacity(0.6),
                            radius: snappedChapterID == nil ? 2 : 5, y: 1)
                    .frame(width: hovering || dragValue != nil ? trackHeight * 2.4 : 0,
                           height: hovering || dragValue != nil ? trackHeight * 2.4 : 0)
                    .offset(x: w * frac - trackHeight * 1.2)
            }
            .frame(height: trackHeight)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { updateDrag($0, width: w, duration: d) }
                .onEnded { finishDrag($0, width: w, duration: d) })
            .animation(.smooth(duration: 0.2), value: hovering)
            .animation(.easeOut(duration: 0.12), value: snappedChapterID)
        }
        .frame(height: cinemaStyle ? 28 : height * 3)
        .disabled(player.episodeID == nil)
        .accessibilityLabel("Playback position")
        .onChange(of: player.episodeID) { _, _ in
            if dragEpisodeID != nil { clearDrag() }
        }
        .onDisappear {
            if dragEpisodeID != nil { clearDrag() }
        }
    }
}

/// "Playback Speed" panel: a slider from 0.5× to 3.0× between a tortoise and a hare.
struct SpeedPanel: View {
    @Environment(Player.self) private var player

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Playback Speed").font(.headline)
                Spacer()
                Text(Fmt.speed(player.rate)).font(.headline.monospacedDigit()).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Image(systemName: "tortoise.fill").foregroundStyle(.secondary)
                Slider(value: Binding(get: { player.rate }, set: { player.setRate($0) }),
                       in: Mechanics.minSpeed...Mechanics.maxSpeed)
                    .labelsHidden()
                Image(systemName: "hare.fill").foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                ForEach(Mechanics.speedPresets, id: \.self) { r in
                    Button(Fmt.speed(r)) { player.setRate(r) }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                        .tint(abs(player.rate - r) < 0.01 ? Color.podTeal : nil)
                }
            }
        }
        .padding(16)
        .frame(width: Mechanics.speedPanelWidth)
    }
}

struct SpeedButton: View {
    @Environment(Player.self) private var player
    var body: some View {
        @Bindable var p = player
        Button {
            player.showSpeedPanel.toggle()
        } label: {
            Text(Fmt.speed(player.rate))
                .font(.callout.weight(.semibold).monospacedDigit())
                .frame(minWidth: 40)
        }
        .buttonStyle(.glass)
        .help("Playback Speed")
        .popover(isPresented: $p.showSpeedPanel, arrowEdge: .top) { SpeedPanel() }
    }
}

struct TransportButtons: View {
    @Environment(Player.self) private var player
    var large: Bool

    var body: some View {
        let s: CGFloat = large ? 22 : 15
        HStack(spacing: large ? 14 : 6) {
            button("backward.end.fill", "Previous Chapter", size: s * 0.8, enabled: player.hasPreviousChapter) { player.previousChapter() }
            button("gobackward.15", "Back 15 Seconds", size: s) { player.skipBack() }
            Button {
                player.togglePlay()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: s * 1.25, weight: .semibold))
                    .frame(width: s * 2.1, height: s * 2.1)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .help(player.isPlaying ? "Pause" : "Play")
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            button("goforward.15", "Forward 15 Seconds", size: s) { player.skipForward() }
            button("forward.end.fill", "Next Chapter", size: s * 0.8, enabled: player.hasNextChapter) { player.nextChapter() }
        }
    }

    func button(_ symbol: String, _ label: String, size: CGFloat, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .frame(width: size * 1.7, height: size * 1.7)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.primary)
        .disabled(!enabled || player.episodeID == nil)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// The player strip shown at the bottom of both modes (compact in Manage, roomy in Listen).
struct PlayerStrip: View {
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    var large: Bool

    var body: some View {
        Group {
            if let e = player.episode {
                content(e)
            } else {
                HStack(spacing: 12) {
                    Image(systemName: "headphones").font(.title2).foregroundStyle(.secondary)
                    Text("Playback and metadata appear here.").foregroundStyle(.secondary)
                    Spacer()
                    TransportButtons(large: false)
                }
            }
        }
        .padding(.horizontal, large ? 20 : 14)
        .padding(.vertical, large ? 16 : 10)
        .podGlass(in: RoundedRectangle(cornerRadius: large ? 26 : 20, style: .continuous))
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    func content(_ e: Episode) -> some View {
        let show = library.show(e.showID)
        if large {
            HStack(spacing: 18) {
                EpisodeArtwork(episode: e, size: 76)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.title).font(.headline).lineLimit(1).help(e.title)
                            Text([show?.title, player.scrubPreviewChapterTitle ?? player.currentChapter?.title].compactMap { $0 }.joined(separator: " · "))
                                .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if player.videoPlayer != nil && !player.showVideo {
                            Button { player.showVideo = true } label: { Label("Show Video", systemImage: "play.rectangle") }
                                .buttonStyle(.glass)
                        }
                        if !e.transcript.isEmpty {
                            Button { player.showChapters.toggle() } label: { Label("Transcript", systemImage: "text.bubble") }
                                .buttonStyle(.glass).help("Show the transcript")
                        }
                        chapterMenu
                        SpeedButton()
                    }
                    Scrubber(height: 6)
                    HStack {
                        Text(Fmt.clock(player.position)).monospacedDigit()
                        Spacer()
                        TransportButtons(large: true)
                        Spacer()
                        Text("-" + Fmt.clock(max(0, player.duration - player.position) / player.rate)).monospacedDigit()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        } else {
            HStack(spacing: 12) {
                EpisodeArtwork(episode: e, size: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text(e.title).font(.callout.weight(.semibold)).lineLimit(1).help(e.title)
                    Text(player.scrubPreviewChapterTitle ?? player.currentChapter?.title ?? show?.title ?? "")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(width: 210, alignment: .leading)
                TransportButtons(large: false)
                Text(Fmt.clock(player.position)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Scrubber(height: 4)
                Text("-" + Fmt.clock(max(0, player.duration - player.position))).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                SpeedButton()
            }
        }
    }

    var chapterMenu: some View {
        Menu {
            if player.chapters.isEmpty {
                Text("No chapters")
            }
            ForEach(Array(player.chapters.enumerated()), id: \.element.id) { i, c in
                Button {
                    player.seek(to: c.start)
                } label: {
                    if i == player.currentChapterIndex {
                        Label("\(Fmt.clock(c.start))  \(c.title)", systemImage: "speaker.wave.2.fill")
                    } else {
                        Text("\(Fmt.clock(c.start))  \(c.title)")
                    }
                }
            }
        } label: {
            Label("Chapters", systemImage: "list.bullet")
        }
        .menuStyle(.button)
        .buttonStyle(.glass)
        .fixedSize()
        .help("Chapters")
    }
}

/// What's happening to an episode right now (downloading, transcribing, chapters, cutting) with its progress.
/// Fixed height, so the panel's layout doesn't move as the numbers change.
struct ProcessingStatus: View {
    let episode: Episode

    /// Some processing callbacks include the same trailing percentage that the card
    /// already prints on the right. Strip only that suffix, leaving the status intact.
    private var statusText: String {
        guard let note = episode.note?.trimmingCharacters(in: .whitespacesAndNewlines),
              !note.isEmpty else { return episode.stage.label }
        let clean = note.replacingOccurrences(of: #"\s+\d+(?:[.,]\d+)?\s*%\s*$"#,
                                              with: "", options: .regularExpression)
        return clean.isEmpty ? episode.stage.label : clean
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: episode.stage.symbol).foregroundStyle(Color.podTeal)
                Text(statusText).lineLimit(1)
                Spacer(minLength: 4)
                if episode.stage != .queued {
                    Text("\(Int((episode.progress * 100).rounded()))%").monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .font(.callout.weight(.medium))
            ProgressView(value: episode.stage == .queued ? 0 : min(1, max(0, episode.progress)))
                .tint(Color.podTeal)
        }
        .padding(10)
        .frame(height: 58)
        .background(Color.podTeal.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct PlaybackPreparationStatus: View {
    @Environment(Player.self) private var player

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "play.rectangle.fill").foregroundStyle(Color.podTeal)
                Text(player.youtubePreparationStatus ?? "Connecting video…").lineLimit(1)
                Spacer(minLength: 4)
                Text("\(Int((player.youtubePreparationProgress * 100).rounded()))%")
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.callout.weight(.medium))
            ProgressView(value: min(1, max(0, player.youtubePreparationProgress))).tint(Color.podTeal)
        }
        .padding(10)
        .frame(height: 58)
        .background(Color.podTeal.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Chapters and transcript in one reading view: each chapter is a heading (pinned while you read it)
/// followed by the transcript lines spoken in it. Click a heading or a line to jump there.
struct PlaybackInfoSidebar: View {
    @Environment(Player.self) private var player
    let episode: Episode
    var showSearch = true
    /// Cinema uses the same layered tint as its full-screen background for an opaque pinned header.
    var cinemaTint: Color? = nil
    @State private var query = ""
    @State private var visibleAnchor: String?
    @State private var suppressScrollGestureUntil = Date.distantPast

    private var isCurrent: Bool { player.episodeID == episode.id }
    private var isVisibleMode: Bool { showSearch ? !player.cinemaMode : player.cinemaMode }
    private var playableChapters: [Chapter] { isCurrent ? player.chapters : episode.playbackChapters }
    private var playableLines: [TranscriptLine] { isCurrent ? player.visibleTranscript : episode.playbackTranscript }

    /// The currently spoken line, or the current chapter when there is no transcript yet.
    private var playbackAnchor: String? {
        guard isCurrent else { return nil }
        if let line = player.currentLineStart(in: playableLines) { return "line-\(line)" }
        if let chapter = playableChapters
            .last(where: { $0.start <= player.position + 0.01 }) ?? playableChapters.first {
            return "chapter-\(chapter.id.uuidString)"
        }
        return playableLines.first.map { "line-\($0.start)" }
    }

    private var storedAnchor: String? {
        if player.transcriptFollowsPlayback { return playbackAnchor }
        if player.transcriptScrollEpisodeID == episode.id { return player.transcriptScrollAnchor ?? playbackAnchor }
        return playbackAnchor
    }

    private func scrollToCurrent(_ proxy: ScrollViewProxy, animated: Bool) {
        guard isVisibleMode, let target = storedAnchor else { return }
        // Native scroll phase can briefly report interaction while an automatic scroll
        // settles or the inspector changes width during the Cinema transition.
        suppressScrollGestureUntil = Date().addingTimeInterval(animated ? 0.65 : 0.35)
        let jump = {
            proxy.scrollTo(target, anchor: .center)
        }
        if animated { withAnimation(.smooth(duration: 0.32), jump) }
        else { jump() }
        visibleAnchor = target
        if player.transcriptFollowsPlayback {
            player.transcriptScrollEpisodeID = episode.id
            player.transcriptScrollAnchor = target
        }
    }

    struct Part: Identifiable {
        let id: String
        let chapter: Chapter?
        let index: Int?
        let lines: [TranscriptLine]
    }

    /// Transcript lines grouped under the chapter they fall in.
    var parts: [Part] {
        let chapters = playableChapters
        let lines = playableLines
        guard !chapters.isEmpty else { return [Part(id: "all", chapter: nil, index: nil, lines: lines)] }
        var out: [Part] = []
        let lead = lines.filter { $0.start < chapters[0].start - 0.5 }
        if !lead.isEmpty { out.append(Part(id: "lead", chapter: nil, index: nil, lines: lead)) }
        for (i, c) in chapters.enumerated() {
            let end = i + 1 < chapters.count ? chapters[i + 1].start : .infinity
            let inside = lines.filter { $0.start >= c.start - 0.5 && $0.start < end - 0.5 }
            out.append(Part(id: c.id.uuidString, chapter: c, index: i, lines: inside))
        }
        return out
    }

    var body: some View {
        let q = query.trimmingCharacters(in: .whitespaces)
        let shown: [Part] = q.isEmpty ? parts : parts.compactMap { p in
            let titleHit = p.chapter.map { $0.title.localizedCaseInsensitiveContains(q) } ?? false
            let hits = p.lines.filter { $0.text.localizedCaseInsensitiveContains(q) }
            if titleHit { return p }
            return hits.isEmpty ? nil : Part(id: p.id, chapter: p.chapter, index: p.index, lines: hits)
        }
        VStack(spacing: 0) {
            if showSearch {
                TextField("Search transcript", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .padding(12)
            }
            if isCurrent && player.preparingYouTubeEpisodeID == episode.id {
                PlaybackPreparationStatus()
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            } else if episode.stage.isWorking {
                ProcessingStatus(episode: episode)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            }
            if playableChapters.isEmpty && playableLines.isEmpty {
                let preparing = isCurrent && player.preparingYouTubeEpisodeID == episode.id
                ContentUnavailableView(
                    preparing ? "Connecting video…" :
                        (episode.stage == .transcribing ? "Transcribing…" : "No Chapters or Transcript"),
                    systemImage: "text.bubble",
                    description: Text(preparing
                                      ? (player.youtubePreparationStatus ?? "Captions will appear as soon as the verified source is ready.")
                                      : episode.stage == .transcribing
                                      ? "Transcript lines will appear here as they are recognized."
                                      : "They appear once the episode has been downloaded and processed.")
                )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                            ForEach(shown) { part in
                                Section {
                                    ForEach(Array(part.lines.enumerated()), id: \.offset) { _, l in
                                        line(l, active: isCurrent && player.position >= l.start && player.position < l.end)
                                    }
                                    if part.lines.isEmpty && part.chapter != nil {
                                        Color.clear.frame(height: 4)
                                    }
                                } header: {
                                    if let c = part.chapter {
                                        heading(c, active: isCurrent && part.index == player.currentChapterIndex)
                                            .id("chapter-\(c.id.uuidString)")
                                    }
                                }
                            }
                            if playableLines.isEmpty {
                                Text("The transcript appears here once the episode has been processed.")
                                    .font(.caption).foregroundStyle(.secondary).padding(14)
                            }
                        }
                        .padding(.bottom, 20)
                        .scrollTargetLayout()
                    }
                    .scrollPosition(id: $visibleAnchor, anchor: .center)
                    .onScrollPhaseChange { _, phase in
                        if phase == .interacting, isCurrent, isVisibleMode,
                           Date() > suppressScrollGestureUntil {
                            player.transcriptFollowsPlayback = false
                            player.transcriptScrollEpisodeID = episode.id
                        }
                    }
                    .onChange(of: visibleAnchor) { _, anchor in
                        if !player.transcriptFollowsPlayback, isVisibleMode, let anchor {
                            player.transcriptScrollEpisodeID = episode.id
                            player.transcriptScrollAnchor = anchor
                        }
                    }
                    .onChange(of: playbackAnchor) { _, _ in
                        if isCurrent, player.transcriptFollowsPlayback, q.isEmpty {
                            scrollToCurrent(proxy, animated: true)
                        }
                    }
                    .onChange(of: episode.transcript.count) { _, _ in
                        // New transcription lines must not pull a reader away from a
                        // manually selected position.
                        if q.isEmpty, isCurrent, player.transcriptFollowsPlayback {
                            scrollToCurrent(proxy, animated: false)
                        }
                    }
                    .onChange(of: episode.chapters.count) { _, _ in
                        if q.isEmpty, isCurrent, player.transcriptFollowsPlayback {
                            scrollToCurrent(proxy, animated: false)
                        }
                    }
                    // Wait for the lazy stack's first layout before restoring the reading position.
                    .task(id: episode.id) {
                        await Task.yield()
                        if q.isEmpty { scrollToCurrent(proxy, animated: false) }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if isCurrent && !player.transcriptFollowsPlayback && q.isEmpty {
                            Button {
                                player.transcriptFollowsPlayback = true
                                scrollToCurrent(proxy, animated: true)
                            } label: {
                                Label("Follow Playback", systemImage: "waveform")
                                    .font(.caption.weight(.semibold))
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Color.podTeal)
                            .padding(12)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }
                    }
                }
            }
        }
    }

    func seek(_ t: Double) {
        if player.episodeID != episode.id { player.play(episode.id) }
        player.transcriptFollowsPlayback = true
        player.seek(to: t)
    }

    func heading(_ c: Chapter, active: Bool) -> some View {
        Button { seek(c.start) } label: {
            VStack(alignment: .leading, spacing: 3) {
                // Time above, title below: reads like a chapter heading, not a table row.
                HStack(spacing: 6) {
                    Text(Fmt.clock(c.start)).monospacedDigit()
                    if active {
                        Image(systemName: "speaker.wave.2.fill")
                        Text("Now Playing")
                    }
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(active ? Color.podTeal : .secondary)
                Text(c.title)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(active ? Color.podTeal : .primary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14)
            .padding(.top, 9)
            .padding(.bottom, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Jump to this chapter")
        .background {
            Color(nsColor: .windowBackgroundColor)
                .overlay {
                    if let cinemaTint {
                        ZStack {
                            cinemaTint
                            Color.black.opacity(0.22)
                        }
                    }
                }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(.primary.opacity(0.08)).frame(height: 1)
        }
    }

    func line(_ l: TranscriptLine, active: Bool) -> some View {
        Text(l.text)
            .font(.body)
            .fontWeight(active ? .semibold : .regular)
            .foregroundStyle(active ? Color.podTeal : Color.primary.opacity(0.85))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .background(active ? Color.podTeal.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .onTapGesture { seek(l.start) }
            .help(Fmt.clock(l.start))
            .id("line-\(l.start)")
    }
}

/// Transcript with search; clicking a line jumps there (PlaybackTranscriptView in the original).
struct TranscriptView: View {
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    let lines: [TranscriptLine]
    let episodeID: UUID
    @State private var query = ""
    @State private var followLatest = true

    var body: some View {
        // The editor's draft was captured when its sheet opened. Read the observable
        // episode to show partial transcript lines while the processor is still running.
        let liveEpisode = library.episode(episodeID)
        let currentLines = liveEpisode?.transcript ?? lines
        let isCurrent = player.episodeID == episodeID
        let shown = query.isEmpty ? currentLines : currentLines.filter { $0.text.localizedCaseInsensitiveContains(query) }
        VStack(spacing: 8) {
            TextField("Search transcript", text: $query).textFieldStyle(.roundedBorder)
            // Keep processing status fixed above the independently scrolling transcript.
            if isCurrent && player.preparingYouTubeEpisodeID == episodeID {
                PlaybackPreparationStatus()
            } else if let liveEpisode, liveEpisode.stage.isWorking {
                ProcessingStatus(episode: liveEpisode)
            }
            if currentLines.isEmpty {
                ContentUnavailableView(liveEpisode?.stage == .transcribing ? "Transcribing…" : "No Transcript",
                                       systemImage: "text.bubble",
                                       description: Text(liveEpisode?.stage == .transcribing
                                                         ? "Recognized lines will appear here as transcription progresses."
                                                         : "Transcripts appear once the episode has been processed."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    List(Array(shown.enumerated()), id: \.offset) { _, l in
                        let active = isCurrent && player.sourcePosition >= l.start && player.sourcePosition < l.end
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(Fmt.clock(l.start)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                            Text(l.text).fontWeight(active ? .semibold : .regular).foregroundStyle(active ? Color.podTeal : .primary)
                        }
                        .id(l.start)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if !isCurrent { player.play(episodeID) }
                            player.seekSourceTime(l.start)
                        }
                    }
                    .onScrollPhaseChange { _, phase in
                        if phase == .interacting { followLatest = false }
                    }
                    .onChange(of: currentLines.count) { _, newCount in
                        if newCount > 0, query.isEmpty, followLatest,
                           liveEpisode?.stage == .transcribing, let last = currentLines.last {
                            proxy.scrollTo(last.start, anchor: .bottom)
                        }
                    }
                    .onChange(of: currentLines.last(where: { $0.start <= player.sourcePosition })?.start) { _, t in
                        if let t, query.isEmpty, isCurrent, followLatest,
                           liveEpisode?.stage != .transcribing {
                            withAnimation { proxy.scrollTo(t, anchor: .center) }
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if !followLatest && query.isEmpty {
                            Button(liveEpisode?.stage == .transcribing ? "Latest" : "Follow Playback") {
                                followLatest = true
                                if let target = isCurrent && liveEpisode?.stage != .transcribing
                                    ? currentLines.last(where: { $0.start <= player.sourcePosition })
                                    : currentLines.last {
                                    proxy.scrollTo(target.start, anchor: .center)
                                }
                            }
                            .buttonStyle(.glass)
                            .controlSize(.small)
                            .padding(12)
                        }
                    }
                }
            }
        }
        .padding(12)
    }
}

extension Player {
    func currentLineStart(in lines: [TranscriptLine]) -> Double? {
        lines.last { $0.start <= position }?.start
    }
}


/// Floating in-page video. It remains inside the available detail area, can be
/// dragged like PiP, and resizes from its lower-right corner.

struct VideoPanel: View {
    @Environment(Player.self) private var player
    var height: CGFloat
    var availableSize: CGSize
    @State private var panelCenter: CGPoint?
    @State private var dragOrigin: CGPoint?
    @State private var customWidth: CGFloat?
    @State private var resizeOrigin: CGFloat?
    @State private var resizeCenterOrigin: CGPoint?
    @State private var hovering = false
    @State private var hoveringResizeCorner = false
    @State private var isFullscreen = false
    @State private var fullscreenWindow = VideoFullscreenWindow()

    private func presentFullscreen(_ videoPlayer: AVPlayer) {
        isFullscreen = true
        fullscreenWindow.present(player: videoPlayer, togglePlayback: { player.togglePlay() }) {
            isFullscreen = false
        }
    }

    var body: some View {
        if let vp = player.videoPlayer, player.showVideo {
                let maximumWidth = max(260, min(760, availableSize.width - 28))
                let width = min(maximumWidth, max(260, customWidth ?? height * 16 / 9))
                let videoHeight = width * 9 / 16
                let minX = width / 2 + 14
                let maxX = max(minX, availableSize.width - width / 2 - 14)
                let minY = videoHeight / 2 + 14
                let maxY = max(minY, availableSize.height - videoHeight / 2 - 14)
                let fallback = CGPoint(x: maxX, y: minY)
                let requestedCenter = panelCenter ?? fallback
                let center = CGPoint(
                    x: min(maxX, max(minX, requestedCenter.x)),
                    y: min(maxY, max(minY, requestedCenter.y))
                )
                let anchoredLeft = center.x <= availableSize.width / 2
                let anchoredTop = center.y <= availableSize.height / 2
                // Keep the snapped corner fixed and put the resize target on the
                // diagonally opposite, free corner (like a snapped utility window).
                let resizeLeft = !anchoredLeft
                let resizeTop = !anchoredTop
                let resizeAlignment: Alignment = switch (resizeLeft, resizeTop) {
                case (true, true): .topLeading
                case (false, true): .topTrailing
                case (true, false): .bottomLeading
                case (false, false): .bottomTrailing
                }
                let resizeCursorPosition: NSCursor.FrameResizePosition = switch (resizeLeft, resizeTop) {
                case (true, true): .topLeft
                case (false, true): .topRight
                case (true, false): .bottomLeft
                case (false, false): .bottomRight
                }
                let resizeDirection: CGFloat = resizeLeft ? -1 : 1
                let snapPoints = [
                    CGPoint(x: minX, y: minY), CGPoint(x: maxX, y: minY),
                    CGPoint(x: minX, y: maxY), CGPoint(x: maxX, y: maxY)
                ]

                ZStack(alignment: .topTrailing) {
                    Group {
                        if isFullscreen {
                            Color.black.overlay {
                                Label("Playing in Full Screen", systemImage: "arrow.up.left.and.arrow.down.right")
                                    .font(.caption).foregroundStyle(.white.opacity(0.7))
                            }
                        } else {
                            VideoSurface(player: vp)
                        }
                    }
                    .background(.black)
                    // AVPlayerView consumes native mouse events, so a native
                    // interaction surface owns movement for precisely this frame.
                    PiPDragSurface(
                        onHover: { hovering = $0 },
                        onDrag: { translation in
                            guard !hoveringResizeCorner else { return }
                            let origin = dragOrigin ?? center
                            if dragOrigin == nil { dragOrigin = origin }
                            panelCenter = CGPoint(
                                x: min(maxX, max(minX, origin.x + translation.width)),
                                y: min(maxY, max(minY, origin.y + translation.height))
                            )
                        },
                        onEnd: { translation in
                            guard !hoveringResizeCorner else { return }
                            let origin = dragOrigin ?? center
                            let released = CGPoint(x: origin.x + translation.width,
                                                   y: origin.y + translation.height)
                            let target = snapPoints.min {
                                hypot($0.x - released.x, $0.y - released.y)
                                    < hypot($1.x - released.x, $1.y - released.y)
                            } ?? fallback
                            dragOrigin = nil
                            withAnimation(.spring(duration: 0.34, bounce: 0.08)) {
                                panelCenter = target
                            }
                        }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if hovering {
                        HStack(spacing: 8) {
                            Button { presentFullscreen(vp) } label: {
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                            }
                            .help("Enter Full Screen").disabled(isFullscreen)
                            Button {
                                fullscreenWindow.close()
                                player.showVideo = false
                            } label: { Image(systemName: "xmark") }
                            .help("Hide Video")
                        }
                        .buttonStyle(.glass).buttonBorderShape(.circle).padding(10)
                        .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .topTrailing)))
                    }
                    // An AppKit-backed hit surface owns mouse events in the outer
                    // corner, so the surrounding SwiftUI move gesture cannot steal
                    // a resize drag.
                    PiPResizeHandle(
                        cursorPosition: resizeCursorPosition,
                        onHover: { hoveringResizeCorner = $0 },
                        onDrag: { translation in
                            let origin = resizeOrigin ?? width
                            let originCenter = resizeCenterOrigin ?? center
                            if resizeOrigin == nil {
                                resizeOrigin = origin
                                resizeCenterOrigin = originCenter
                            }
                            let resized = min(maximumWidth, max(260, origin + translation * resizeDirection))
                            let widthChange = resized - origin
                            customWidth = resized
                            panelCenter = CGPoint(
                                x: originCenter.x + widthChange / 2 * (resizeLeft ? -1 : 1),
                                y: originCenter.y + widthChange * 9 / 32 * (resizeTop ? -1 : 1)
                            )
                        },
                        onEnd: { translation in
                            let origin = resizeOrigin ?? width
                            let originCenter = resizeCenterOrigin ?? center
                            let resized = min(maximumWidth, max(260, origin + translation * resizeDirection))
                            let widthChange = resized - origin
                            customWidth = resized
                            panelCenter = CGPoint(
                                x: originCenter.x + widthChange / 2 * (resizeLeft ? -1 : 1),
                                y: originCenter.y + widthChange * 9 / 32 * (resizeTop ? -1 : 1)
                            )
                            resizeOrigin = nil
                            resizeCenterOrigin = nil
                        }
                    )
                    .frame(width: 36, height: 36)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: resizeAlignment)
                }
                .frame(width: width, height: videoHeight)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(hovering ? 0.22 : 0.08)))
                .shadow(color: .black.opacity(0.32), radius: 18, y: 8)
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .onHover { hovering = $0 }
                .animation(.smooth(duration: 0.18), value: hovering)
                // Placed with real layout (.position), not .offset: an offset only moves the drawing, and the
                // AppKit views that take clicks (video, move surface, resize corner) stayed at the original spot,
                // so nothing on the floating video could be clicked or dragged.
                .position(x: center.x, y: center.y)
                .frame(width: availableSize.width, height: availableSize.height, alignment: .topLeading)
            .onChange(of: ObjectIdentifier(vp)) { _, _ in
                if isFullscreen { fullscreenWindow.updatePlayer(vp) }
            }
            .onChange(of: player.videoFullscreenRequest) { _, _ in presentFullscreen(vp) }
            .onDisappear { fullscreenWindow.close() }
        }
    }
}

private struct PiPDragSurface: NSViewRepresentable {
    var onHover: (Bool) -> Void
    var onDrag: (CGSize) -> Void
    var onEnd: (CGSize) -> Void

    func makeNSView(context: Context) -> DragView {
        DragView(onHover: onHover, onDrag: onDrag, onEnd: onEnd)
    }

    func updateNSView(_ view: DragView, context: Context) {
        view.onHover = onHover
        view.onDrag = onDrag
        view.onEnd = onEnd
    }

    final class DragView: NSView {
        var onHover: (Bool) -> Void
        var onDrag: (CGSize) -> Void
        var onEnd: (CGSize) -> Void
        private var start: NSPoint?
        private var tracking: NSTrackingArea?

        init(onHover: @escaping (Bool) -> Void,
             onDrag: @escaping (CGSize) -> Void,
             onEnd: @escaping (CGSize) -> Void) {
            self.onHover = onHover
            self.onDrag = onDrag
            self.onEnd = onEnd
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func updateTrackingAreas() {
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: bounds,
                                      options: [.activeInKeyWindow, .mouseEnteredAndExited],
                                      owner: self)
            addTrackingArea(area)
            tracking = area
            super.updateTrackingAreas()
        }

        override func mouseEntered(with event: NSEvent) { onHover(true) }
        override func mouseExited(with event: NSEvent) { if start == nil { onHover(false) } }
        override func mouseDown(with event: NSEvent) {
            start = event.locationInWindow
            onHover(true)
        }
        override func mouseDragged(with event: NSEvent) {
            guard let start else { return }
            onDrag(CGSize(width: event.locationInWindow.x - start.x,
                          height: start.y - event.locationInWindow.y))
        }
        override func mouseUp(with event: NSEvent) {
            guard let start else { return }
            let translation = CGSize(width: event.locationInWindow.x - start.x,
                                     height: start.y - event.locationInWindow.y)
            self.start = nil
            onEnd(translation)
            onHover(bounds.contains(convert(event.locationInWindow, from: nil)))
        }
    }
}

/// A real AppKit mouse target for PiP resizing. SwiftUI gestures attached to a
/// parent view otherwise compete for the same drag and can turn a resize into a move.
private struct PiPResizeHandle: NSViewRepresentable {
    var cursorPosition: NSCursor.FrameResizePosition
    var onHover: (Bool) -> Void
    var onDrag: (CGFloat) -> Void
    var onEnd: (CGFloat) -> Void

    func makeNSView(context: Context) -> ResizeView {
        ResizeView(cursorPosition: cursorPosition, onHover: onHover, onDrag: onDrag, onEnd: onEnd)
    }

    func updateNSView(_ view: ResizeView, context: Context) {
        if view.cursorPosition != cursorPosition {
            view.cursorPosition = cursorPosition
            view.window?.invalidateCursorRects(for: view)
        }
        view.onHover = onHover
        view.onDrag = onDrag
        view.onEnd = onEnd
    }

    final class ResizeView: NSView {
        var cursorPosition: NSCursor.FrameResizePosition
        var onHover: (Bool) -> Void
        var onDrag: (CGFloat) -> Void
        var onEnd: (CGFloat) -> Void
        private var start: NSPoint?
        private var tracking: NSTrackingArea?

        init(cursorPosition: NSCursor.FrameResizePosition,
             onHover: @escaping (Bool) -> Void,
             onDrag: @escaping (CGFloat) -> Void,
             onEnd: @escaping (CGFloat) -> Void) {
            self.cursorPosition = cursorPosition
            self.onHover = onHover
            self.onDrag = onDrag
            self.onEnd = onEnd
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func updateTrackingAreas() {
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: bounds,
                                      options: [.activeInKeyWindow, .mouseEnteredAndExited, .cursorUpdate],
                                      owner: self)
            addTrackingArea(area)
            tracking = area
            super.updateTrackingAreas()
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .frameResize(position: cursorPosition, directions: .outward))
        }

        override func mouseEntered(with event: NSEvent) { onHover(true) }
        override func mouseExited(with event: NSEvent) { if start == nil { onHover(false) } }
        override func cursorUpdate(with event: NSEvent) {
            NSCursor.frameResize(position: cursorPosition, directions: .outward).set()
        }
        override func mouseDown(with event: NSEvent) {
            start = event.locationInWindow
            onHover(true)
        }
        override func mouseDragged(with event: NSEvent) {
            guard let start else { return }
            onDrag(event.locationInWindow.x - start.x)
        }
        override func mouseUp(with event: NSEvent) {
            guard let start else { return }
            let translation = event.locationInWindow.x - start.x
            self.start = nil
            onEnd(translation)
            onHover(bounds.contains(convert(event.locationInWindow, from: nil)))
        }
    }
}

/// AVKit's player view without its own controls (PodCraft's player bar drives it).
struct VideoSurface: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        // PodCraft's SystemMedia publishes the complete episode/show metadata.
        // AVPlayerView defaults this to true and otherwise publishes a second,
        // mostly empty Now Playing entry for the raw signed video stream.
        v.updatesNowPlayingInfoCenter = false
        v.controlsStyle = .none
        v.videoGravity = .resizeAspect
        v.player = player
        Self.hideCaptions(for: player)
        return v
    }
    func updateNSView(_ v: AVPlayerView, context: Context) {
        v.updatesNowPlayingInfoCenter = false
        if v.player !== player { v.player = player }
        Self.hideCaptions(for: player)
    }

    /// Do not display selectable subtitle/closed-caption tracks over the picture.
    /// The separate PodCraft transcript remains available in the player sidebar.
    static func hideCaptions(for player: AVPlayer) {
        player.appliesMediaSelectionCriteriaAutomatically = false
        guard let item = player.currentItem else { return }
        Task { @MainActor in
            guard let legible = try? await item.asset.loadMediaSelectionGroup(for: .legible),
                  player.currentItem === item else { return }
            item.select(nil, in: legible)
        }
    }
}

/// A native macOS full-screen video window that shares the current AVPlayer.
/// Closing it returns the picture to its original inline position.
@MainActor
final class VideoFullscreenWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private weak var videoView: AVPlayerView?
    private var keyMonitor: Any?
    private var togglePlayback: (() -> Void)?
    private var onClose: (() -> Void)?
    private var isClosing = false

    func present(player: AVPlayer, togglePlayback: @escaping () -> Void, onClose: @escaping () -> Void) {
        if window != nil {
            updatePlayer(player)
            return
        }
        self.togglePlayback = togglePlayback
        self.onClose = onClose
        isClosing = false

        let video = AVPlayerView()
        video.updatesNowPlayingInfoCenter = false
        video.controlsStyle = .floating
        video.videoGravity = .resizeAspect
        video.player = player
        VideoSurface.hideCaptions(for: player)
        videoView = video

        let fullScreenWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 640),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        fullScreenWindow.title = "PodCraft Video"
        fullScreenWindow.contentView = video
        fullScreenWindow.backgroundColor = .black
        fullScreenWindow.collectionBehavior.insert(.fullScreenPrimary)
        fullScreenWindow.delegate = self
        fullScreenWindow.center()
        window = fullScreenWindow

        // Native AVPlayerView can consume Space itself; intercept it only while this
        // window is key so it drives PodCraft's own skip-aware playback controls.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.window?.isKeyWindow == true, event.keyCode == 49,
                  !(self.window?.firstResponder is NSTextView),
                  event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return event }
            if !event.isARepeat { self.togglePlayback?() }
            return nil
        }
        fullScreenWindow.makeKeyAndOrderFront(nil)
        fullScreenWindow.toggleFullScreen(nil)
    }

    func updatePlayer(_ player: AVPlayer) {
        if videoView?.player !== player { videoView?.player = player }
        VideoSurface.hideCaptions(for: player)
    }

    func close() {
        guard !isClosing, let window else { return }
        isClosing = true
        window.close()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        guard !isClosing, let exited = notification.object as? NSWindow,
              exited === window else { return }
        isClosing = true
        // Never call NSWindow.close() from the fullscreen transition callback.
        // AppKit is still unwinding its private fullscreen window hierarchy here.
        DispatchQueue.main.async { [weak self, weak exited] in
            guard let self, let exited, self.window === exited else { return }
            self.retire(exited)
        }
    }

    private func retire(_ retiredWindow: NSWindow) {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        // Detach AVPlayerView before removing the auxiliary window. Ordering it
        // out avoids re-entering AppKit's close machinery after fullscreen exit.
        videoView?.player = nil
        retiredWindow.orderOut(nil)
        retiredWindow.delegate = nil
        videoView = nil
        if window === retiredWindow { window = nil }
        isClosing = false
        togglePlayback = nil
        let completion = onClose
        onClose = nil
        completion?()
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === window else { return }
        retire(closing)
    }
}
