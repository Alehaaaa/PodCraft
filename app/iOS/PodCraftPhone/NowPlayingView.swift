import SwiftUI
import AVKit

/// The bar above the tabs: cover, title and play / skip, like the Podcasts app. Tap to open the player.
struct MiniPlayer: View {
    @Environment(Store.self) private var store
    @Environment(AudioPlayer.self) private var player

    var body: some View {
        HStack(spacing: 10) {
            if let e = player.episode {
                Artwork(url: e.artwork ?? store.show(e.showID)?.artwork, size: 36, radius: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(e.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(player.currentChapter?.title ?? store.show(e.showID)?.title ?? "")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Button { player.togglePlay() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title3)
                        .frame(width: 34, height: 34)
                }
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                Button { player.skip(30) } label: {
                    Image(systemName: "goforward.30").font(.title3).frame(width: 34, height: 34)
                }
                .accessibilityLabel("Forward 30 Seconds")
            } else if let next = store.queuedEpisodes.first {
                // Nothing playing yet, but Up Next has something lined up.
                Artwork(url: next.artwork ?? store.show(next.showID)?.artwork, size: 36, radius: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(next.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text("Up Next").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Button { player.play(next) } label: {
                    Image(systemName: "play.fill").font(.title3).frame(width: 34, height: 34)
                }
                .accessibilityLabel("Play Up Next")
            } else {
                Image(systemName: "headphones").foregroundStyle(.secondary)
                Text("Nothing Playing").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .contentShape(Rectangle())
        .onTapGesture { if player.episode != nil { player.showNowPlaying = true } }
    }
}

struct NowPlayingView: View {
    @Environment(Store.self) private var store
    @Environment(AudioPlayer.self) private var player
    @Environment(\.dismiss) private var dismiss
    @State private var panel: Panel?
    @State private var transcript: [TranscriptLine]?
    /// The episode whose transcript finished loading (nil while it loads).
    @State private var transcriptLoaded: String?
    @State private var transcriptExpanded = false
    @State private var scrubbing: Double?
    /// The episode's YouTube upload, while it plays in place of the audio.
    @State private var video: YouTubeVideo?
    /// Whether the video was playing as the app started to leave the screen (iOS may pause it before it's gone).
    @State private var videoWasPlaying = false
    /// The video handed over to the audio when the app went to the background, to bring back on return.
    @State private var videoInBackground: String?
    @Environment(\.scenePhase) private var scenePhase
    /// The last video time copied to the audio player, to tell it from a seek made elsewhere (chapters, transcript).
    @State private var mirrored: Double?
    @Environment(\.openURL) private var openURL
    @Environment(Router.self) private var router

    enum Panel: String, CaseIterable, Identifiable {
        case chapters = "Chapters", transcript = "Transcript", notes = "Notes", upNext = "Up Next"
        var id: String { rawValue }
    }

    var body: some View {
        if let e = player.episode {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 20) {
                        Capsule().fill(.secondary.opacity(0.5)).frame(width: 38, height: 5).padding(.top, 8)
                        picture(e)
                        sourceSwitch(e)
                        titles(e)
                        chapterBar
                        scrubber
                        transport
                        controls(e)
                        panels(e, proxy: proxy)
                    }
                    .padding(.horizontal, 22)
                    .padding(.bottom, 40)
                }
                .scrollIndicators(.hidden)
            }
            .background(backdrop(e))
            .overlay(alignment: .top) { sponsorNotice }
            .onChange(of: e.id) { closeVideo() }
            .onChange(of: player.isPlaying) { _, playing in if playing && video != nil { listen(resume: false) } }
            .onChange(of: video?.time) { _, t in mirror(t) }
            .onChange(of: player.position) { _, t in followSeek(t) }
            .onDisappear { listen(resume: true) }
            .onChange(of: scenePhase) { _, phase in sceneChanged(phase, e) }
            .task(id: "youtube|\(e.id)") {
                // Give the Mac's answer (through Sync) a moment to arrive; otherwise look on YouTube from the phone.
                try? await Task.sleep(for: .seconds(2))
                if !Task.isCancelled, store.youtubeID(for: e) == nil {
                    await YouTubeFinder.shared.lookUp(e, show: store.show(e.showID))
                }
            }
            .task(id: "\(e.id)|\(store.hasTranscript(e))") {
                transcript = nil
                transcriptLoaded = nil
                transcript = await store.transcript(for: e)
                transcriptLoaded = e.id
            }
        }
    }

    // MARK: Top

    @ViewBuilder
    private func picture(_ e: RemoteEpisode) -> some View {
        if let video {
            ZStack {
                Color.black
                YouTubeVideoView(video: video)
                if video.failed {
                    VStack(spacing: 10) {
                        Text("YouTube doesn’t allow this video to play inside PodCraft.")
                            .font(.subheadline.weight(.semibold)).multilineTextAlignment(.center)
                        Button("Open in YouTube", systemImage: "arrow.up.forward.app") { openInYouTube(video.videoID) }
                            .buttonStyle(.borderedProminent).tint(Color.podTeal)
                    }
                    .foregroundStyle(.white)
                    .padding(20)
                } else if !video.hasStarted || video.ended {
                    // Covers YouTube's own start and end screens.
                    Artwork(url: e.artwork ?? store.show(e.showID)?.artwork, size: nil, radius: 0)
                        .overlay(Color.black.opacity(0.35))
                    if !video.ended { ProgressView().tint(.white) }
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        } else if e.isVideo, let p = player.player {
            VideoPlayer(player: p)
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        } else {
            Artwork(url: e.artwork ?? store.show(e.showID)?.artwork, size: nil, radius: 22)
                .frame(maxWidth: 340)
                .scaleEffect(player.isPlaying ? 1 : 0.9)
                .shadow(color: .black.opacity(0.35), radius: 28, y: 16)
                .animation(.spring(duration: 0.45, bounce: 0.3), value: player.isPlaying)
                .padding(.top, 6)
                .onTapGesture { openShow(e) }
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Go to \(store.show(e.showID)?.title ?? "Show")")
        }
    }

    private func titles(_ e: RemoteEpisode) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(Fmt.date(e.published))
                    if e.isOnMac || !store.skips(for: e).isEmpty {
                        Label("Sponsors cut", systemImage: "scissors").labelStyle(.titleAndIcon)
                            .foregroundStyle(Color.podTeal)
                    }
                }
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(e.title).font(.title3.bold()).lineLimit(3)
                if let show = store.show(e.showID) {
                    Button { openShow(e) } label: {
                        HStack(spacing: 4) {
                            Text(show.title).lineLimit(1)
                            Image(systemName: "chevron.right").font(.caption.weight(.bold))
                        }
                        .font(.subheadline).foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Go to \(show.title)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            moreMenu(e)
        }
    }

    private func moreMenu(_ e: RemoteEpisode) -> some View {
        Menu {
            if store.isPlayed(e) {
                Button("Mark as Unplayed", systemImage: "circle") { store.setPlayed(e, false) }
            } else {
                Button("Mark as Played", systemImage: "checkmark.circle") { store.setPlayed(e, true); player.pause() }
            }
            ShareLink(item: e.media, subject: Text(e.title)) { Label("Share Episode", systemImage: "square.and.arrow.up") }
            if store.show(e.showID) != nil {
                Button("Go to Show", systemImage: "square.stack") { openShow(e) }
            }
            if let id = store.youtubeID(for: e) {
                Button("Open in YouTube", systemImage: "arrow.up.forward.app") { openInYouTube(id) }
            }
            if TranscriptService.canTranscribe, !store.transcripts.isRunning(e.id), transcript == nil || store.transcripts.hasOnDevice(e.id) {
                Button(store.transcripts.hasOnDevice(e.id) ? "Transcribe Again on iPhone" : "Transcribe on iPhone",
                       systemImage: "waveform.badge.magnifyingglass") {
                    store.transcripts.forgetOnDevice(e.id)
                    transcript = nil
                    store.transcribe(e)
                    panel = .transcript
                }
            }
            if store.isStandalone || !store.skips(for: e).isEmpty {
                Toggle(isOn: Binding(get: { store.skipSponsors }, set: { store.skipSponsors = $0 })) {
                    Label("Skip Sponsors", systemImage: "scissors")
                }
            }
            Divider()
            Button("Close Player", systemImage: "chevron.down") { dismiss() }
        } label: {
            Image(systemName: "ellipsis").font(.title3.weight(.semibold))
                .frame(width: 36, height: 36)
                .background(.ultraThinMaterial, in: Circle())
        }
        .foregroundStyle(.primary)
        .accessibilityLabel("More")
    }

    /// The current chapter, with buttons to the one before and after.
    @ViewBuilder
    private var chapterBar: some View {
        let chapters = player.chapters
        if let current = player.currentChapter, let index = chapters.firstIndex(of: current) {
            HStack(spacing: 10) {
                Button { player.previousChapter() } label: { Image(systemName: "backward.end.fill") }
                    .accessibilityLabel("Previous Chapter")
                VStack(spacing: 1) {
                    Text("CHAPTER \(index + 1) OF \(chapters.count)").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    Text(current.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                Button { player.nextChapter() } label: { Image(systemName: "forward.end.fill") }
                    .disabled(index == chapters.count - 1)
                    .accessibilityLabel("Next Chapter")
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(.ultraThinMaterial, in: Capsule())
        }
    }

    private var scrubber: some View {
        let shown = min(scrubbing ?? video?.time ?? player.position, max(player.duration, 1))
        return VStack(spacing: 4) {
            Slider(value: Binding(get: { shown }, set: { scrubbing = $0 }),
                   in: 0...max(player.duration, 1)) { editing in
                if !editing, let t = scrubbing { seek(to: t); scrubbing = nil }
            }
            HStack {
                Text(Fmt.clock(shown))
                Spacer()
                if video == nil && player.isBuffering { ProgressView().controlSize(.mini) }
                Spacer()
                Text("−" + Fmt.clock(max(0, player.duration - shown) / Double(player.rate)))
            }
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    private var transport: some View {
        HStack {
            Button { skip(-15) } label: { Image(systemName: "gobackward.15").font(.system(size: 32)) }
                .accessibilityLabel("Back 15 Seconds")
            Spacer()
            Button { if let video { video.togglePlay() } else { player.togglePlay() } } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 40))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 84, height: 84)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel(isPlaying ? "Pause" : "Play")
            Spacer()
            Button { skip(30) } label: { Image(systemName: "goforward.30").font(.system(size: 32)) }
                .accessibilityLabel("Forward 30 Seconds")
        }
        .foregroundStyle(.primary)
        .buttonStyle(.plain)
        .padding(.horizontal, 26)
    }

    /// Speed, sleep timer and output.
    private func controls(_ e: RemoteEpisode) -> some View {
        HStack(spacing: 10) {
            Menu {
                ForEach([0.8, 1.0, 1.1, 1.2, 1.3, 1.5, 1.75, 2.0] as [Float], id: \.self) { r in
                    Button { player.setRate(r); video?.setRate(r) } label: {
                        if abs(player.rate - r) < 0.01 { Label(speed(r), systemImage: "checkmark") } else { Text(speed(r)) }
                    }
                }
            } label: {
                pill(icon: "gauge.with.needle", text: speed(player.rate))
            }
            .accessibilityLabel("Playback Speed")

            Menu {
                if player.sleepAt != nil || player.sleepAtChapterEnd || player.sleepAtEpisodeEnd {
                    Button("Turn Off Timer", systemImage: "moon.zzz") { player.setSleepTimer(minutes: nil) }
                    Divider()
                }
                ForEach([5, 15, 30, 45, 60], id: \.self) { m in
                    Button("\(m) Minutes") { player.setSleepTimer(minutes: m) }
                }
                if !player.chapters.isEmpty {
                    Button("End of Chapter") { player.sleepAtEndOfChapter() }
                }
                Button("End of Episode") { player.sleepAtEndOfEpisode() }
            } label: {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    let on = player.sleepAt != nil || player.sleepAtChapterEnd || player.sleepAtEpisodeEnd
                    pill(icon: on ? "moon.fill" : "moon",
                         text: player.sleepRemaining.map { Fmt.clock($0) }
                            ?? (player.sleepAtChapterEnd ? "Chapter" : player.sleepAtEpisodeEnd ? "Episode" : "Sleep"),
                         active: on)
                }
            }
            .accessibilityLabel("Sleep Timer")

            Spacer()
            RoutePicker()
                .frame(width: 40, height: 40)
                .background(.ultraThinMaterial, in: Circle())
        }
        .foregroundStyle(.primary)
    }

    private func pill(icon: String, text: String, active: Bool = false) -> some View {
        Label(text, systemImage: icon)
            .font(.subheadline.weight(.semibold).monospacedDigit())
            .foregroundStyle(active ? Color.podTeal : .primary)
            .padding(.horizontal, 14).frame(height: 40)
            .background(.ultraThinMaterial, in: Capsule())
    }

    private func speed(_ r: Float) -> String {
        r == Float(Int(r)) ? "\(Int(r))×" : String(format: "%g×", r)
    }

    // MARK: Audio or YouTube video

    private var isPlaying: Bool { video?.isPlaying ?? player.isPlaying }

    /// One tap between the podcast audio and the same episode on the show's YouTube channel, at the same moment.
    @ViewBuilder
    private func sourceSwitch(_ e: RemoteEpisode) -> some View {
        if let id = store.youtubeID(for: e) {
            HStack(spacing: 0) {
                sourceButton("Audio", icon: "waveform", selected: video == nil) { listen(resume: true) }
                sourceButton("YouTube", icon: "play.rectangle.fill", selected: video != nil) { watch(id) }
            }
            .padding(3)
            .background(.ultraThinMaterial, in: Capsule())
        }
    }

    private func sourceButton(_ title: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(selected ? Color.white : .primary)
                .padding(.horizontal, 16).frame(height: 34)
                .background(selected ? Color.podTeal : .clear, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func watch(_ id: String) {
        guard video == nil else { return }
        player.pause()
        mirrored = player.position
        withAnimation(.spring(duration: 0.35)) {
            video = YouTubeVideo(videoID: id, start: player.position, rate: player.rate)
        }
    }

    /// Back to the audio where the video got to, playing if the video was.
    private func listen(resume: Bool) {
        guard let v = video else { return }
        let t = v.time, wasPlaying = v.isPlaying
        v.stop()
        withAnimation(.spring(duration: 0.35)) { video = nil }
        mirrored = nil
        player.seek(to: t)
        if resume && wasPlaying { player.resume() }
    }

    /// A web video can't play in the background, so the episode carries on as audio from the same moment (with the
    /// Lock Screen controls), and the video comes back when the app does, if the audio is still playing.
    private func sceneChanged(_ phase: ScenePhase, _ e: RemoteEpisode) {
        switch phase {
        case .inactive:
            if let video { videoWasPlaying = video.isPlaying }
        case .background:
            guard let v = video else { return }
            let playing = videoWasPlaying || v.isPlaying
            listen(resume: false)
            if playing {
                player.resume()
                videoInBackground = v.videoID
            }
        case .active:
            guard let id = videoInBackground else { return }
            videoInBackground = nil
            if video == nil, player.isPlaying, store.youtubeID(for: e) == id { watch(id) }
        @unknown default: break
        }
    }

    /// Another episode started: the video belonged to the one before.
    private func closeVideo() {
        video?.stop()
        video = nil
        mirrored = nil
    }

    private func seek(to t: Double) {
        if let video { video.seek(to: t) } else { player.seek(to: t) }
    }

    private func skip(_ delta: Double) {
        if let video { video.skip(delta) } else { player.skip(delta) }
    }

    /// Keeps the paused audio where the video is, so chapters, the transcript and saved progress follow along.
    private func mirror(_ t: Double?) {
        guard let t, video != nil, abs(t - player.position) >= 1 else { return }
        player.seek(to: t)
        mirrored = player.position
    }

    /// A chapter or transcript line tapped while the video plays moves the video.
    private func followSeek(_ t: Double) {
        guard let video, let mirrored, abs(t - mirrored) > 1.5 else { return }
        self.mirrored = t
        video.seek(to: t)
    }

    /// Closes the player and opens the show's page on the tab that's open.
    private func openShow(_ e: RemoteEpisode) {
        guard let show = store.show(e.showID) else { return }
        router.open(show, player: player)
    }

    private func openInYouTube(_ id: String) {
        guard let url = YouTubeVideo.link(videoID: id, at: video?.time ?? player.position) else { return }
        if video != nil { listen(resume: false) }
        player.pause()
        openURL(url)
    }

    // MARK: Panels

    private func available(_ e: RemoteEpisode) -> [Panel] {
        var list: [Panel] = []
        if !player.chapters.isEmpty { list.append(.chapters) }
        // A transcript that's there comes before the notes; the offer to make one comes after them.
        let hasTranscript = transcript != nil || store.hasAnyTranscript(e) || store.transcripts.isRunning(e.id)
        if hasTranscript { list.append(.transcript) }
        if !Fmt.plain(e.summary).isEmpty { list.append(.notes) }
        if !hasTranscript && TranscriptService.canTranscribe { list.append(.transcript) }
        if !store.queuedEpisodes.isEmpty || !store.upNext(after: e).isEmpty { list.append(.upNext) }
        return list
    }

    @ViewBuilder
    private func panels(_ e: RemoteEpisode, proxy: ScrollViewProxy) -> some View {
        let list = available(e)
        if let first = list.first {
            let shown = panel.flatMap { list.contains($0) ? $0 : nil } ?? first
            VStack(alignment: .leading, spacing: 14) {
                if list.count > 1 {
                    Picker("Show", selection: Binding(get: { shown }, set: { panel = $0 })) {
                        ForEach(list) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                switch shown {
                case .chapters: chapterList
                case .transcript: transcriptPanel(e, proxy: proxy)
                case .notes: notes(e)
                case .upNext: upNext(e)
                }
            }
            .padding(16)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .padding(.top, 4)
        }
    }

    private var chapterList: some View {
        VStack(spacing: 0) {
            ForEach(Array(player.chapters.enumerated()), id: \.element.id) { i, c in
                let current = player.currentChapter == c
                Button { player.seek(to: c.start) } label: {
                    HStack(spacing: 12) {
                        Text("\(i + 1)").font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(current ? Color.podTeal : .secondary).frame(width: 22)
                        Text(c.title).font(current ? .body.weight(.semibold) : .body)
                            .foregroundStyle(current ? Color.podTeal : .primary)
                            .multilineTextAlignment(.leading)
                        Spacer()
                        Text(Fmt.clock(c.start)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 11)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if i < player.chapters.count - 1 { Divider() }
            }
        }
    }

    @ViewBuilder
    private func transcriptPanel(_ e: RemoteEpisode, proxy: ScrollViewProxy) -> some View {
        let service = store.transcripts
        let phase = service.phases[e.id]
        let lines = transcript ?? service.lines[e.id] ?? []
        VStack(alignment: .leading, spacing: 14) {
            if service.isRunning(e.id), let phase { transcribingStatus(e, phase: phase) }
            if !lines.isEmpty {
                HStack {
                    Text("Tap a line to jump there").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    // Find a passage: the full transcript opens with its search field.
                    Button { transcriptExpanded = true } label: {
                        Image(systemName: "magnifyingglass").font(.subheadline.weight(.semibold))
                            .frame(width: 32, height: 32)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Search Transcript")
                    Button { transcriptExpanded = true } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right").font(.subheadline.weight(.semibold))
                            .frame(width: 32, height: 32)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Expand Transcript")
                }
                TranscriptLinesView(lines: lines)
                    .frame(height: 340)
                    .sheet(isPresented: $transcriptExpanded) {
                        TranscriptSheet(title: e.title, lines: transcript ?? store.transcripts.lines[e.id] ?? [])
                            .environment(player)
                    }
            } else if transcriptLoaded != e.id {
                ProgressView("Loading Transcript…").frame(maxWidth: .infinity, minHeight: 120)
            } else if !service.isRunning(e.id) {
                transcribeOffer(e, failure: { if case .failed(let why) = phase { return why } else { return nil } }())
            }
        }
    }

    /// Progress while this iPhone makes a transcript.
    private func transcribingStatus(_ e: RemoteEpisode, phase: TranscriptService.Phase) -> some View {
        let (label, fraction): (String, Double?) = switch phase {
        case .preparing: ("Getting Ready…", nil)
        case .downloadingModel: ("Downloading the Speech Model…", nil)
        case .downloadingAudio(let f): ("Downloading the Episode…", f)
        case .transcribing(let f): ("Transcribing on iPhone…", f)
        case .failed: ("", nil)
        }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(label, systemImage: "waveform").font(.subheadline.weight(.semibold))
                Spacer()
                if let fraction { Text("\(Int(fraction * 100))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                Button("Stop") { store.transcripts.cancel(e.id) }.font(.subheadline.weight(.semibold))
            }
            if let fraction { ProgressView(value: fraction).tint(Color.podTeal) } else { ProgressView().frame(maxWidth: .infinity) }
        }
    }

    /// No transcript yet: offer to make one on this iPhone.
    private func transcribeOffer(_ e: RemoteEpisode, failure: String?) -> some View {
        VStack(spacing: 10) {
            Image(systemName: failure == nil ? "waveform.badge.magnifyingglass" : "exclamationmark.triangle")
                .font(.title).foregroundStyle(failure == nil ? Color.podTeal : .orange)
            Text(failure == nil ? "No Transcript" : "Couldn’t Transcribe").font(.headline)
            Text(failure ?? "This show doesn’t publish one. PodCraft can transcribe the episode on this iPhone with Apple’s on-device speech model. The audio never leaves your iPhone.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if TranscriptService.canTranscribe {
                Button { store.transcribe(e) } label: {
                    Label(failure == nil ? "Transcribe on iPhone" : "Try Again", systemImage: "waveform")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderedProminent).tint(Color.podTeal)
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private func notes(_ e: RemoteEpisode) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(Fmt.date(e.published))
                Text("·")
                Text(Fmt.remaining(e.duration))
            }
            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(Fmt.plain(e.summary)).font(.callout).textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The listener's queue first (hold and drag to reorder, swipe to play next or remove), then more from the same show.
    private func upNext(_ e: RemoteEpisode) -> some View {
        QueueList(current: e)
    }

    // MARK: Around

    @ViewBuilder
    private var sponsorNotice: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if let at = player.skippedSponsorAt, context.date.timeIntervalSince(at) < 3 {
                Label("Skipped a sponsor read", systemImage: "scissors")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 24)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.35), value: player.skippedSponsorAt)
    }

    private func backdrop(_ e: RemoteEpisode) -> some View {
        ZStack {
            Color(.systemBackground)
            Artwork(url: e.artwork ?? store.show(e.showID)?.artwork, size: nil, radius: 0)
                .scaleEffect(2.4)
                .blur(radius: 70)
                .opacity(0.55)
            LinearGradient(colors: [.clear, Color(.systemBackground).opacity(0.35)], startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
    }
}

/// AirPlay and Bluetooth output picker.
struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = .secondaryLabel
        v.activeTintColor = UIColor(Color.podTeal)
        v.prioritizesVideoDevices = false
        return v
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
