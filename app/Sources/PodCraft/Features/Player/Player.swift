import Foundation
import AVFoundation
import SwiftUI

/// The shared player used by both modes. Downloaded episodes play from this Mac; listed ones stream
/// from their link. Video episodes also show their picture.
@MainActor
@Observable
final class Player {
    var episodeID: UUID?
    var isPlaying = false
    var position: Double = 0
    var duration: Double = 0
    var rate: Double = 1.0
    var showSpeedPanel = false
    var showChapters = false
    var cinemaMode = false
    /// Shared reading position for the transcript sidebar across Cinema and the regular player.
    /// An explicit user scroll pauses automatic following until the user resumes it.
    var transcriptScrollEpisodeID: UUID?
    var transcriptScrollAnchor: String?
    var transcriptFollowsPlayback = true
    var scrubPreviewChapterTitle: String? = nil
    var showsRemainingTime = true
    /// The playing video, when the episode has one (shown above the player).
    var videoPlayer: AVPlayer?
    var showVideo = true
    var videoFullscreenRequest = 0
    /// Explicit playback can wait for a verified YouTube recording rather than
    /// silently starting the differently timed RSS edition. The download stays
    /// asynchronous; the player starts as soon as the media file is committed,
    /// without waiting for transcription or sponsor analysis.
    var preparingYouTubeEpisodeID: UUID?
    var preparingYouTubeVideo = false
    var youtubePreparationProgress: Double = 0
    var youtubePreparationStatus: String?
    @ObservationIgnored private var pendingPreferredYouTube: (id: UUID, video: Bool)?
    /// Keep source-timed RSS words while Processor publishes new YouTube media
    /// and captions. Old words are never attached to the new recording clock.
    @ObservationIgnored private var outgoingSourceTranscript: [TranscriptLine] = []
    @ObservationIgnored private var outgoingVisibleTranscript: [TranscriptLine] = []
    @ObservationIgnored private var outgoingVisibleChapters: [Chapter] = []
    @ObservationIgnored private var outgoingMediaID: String?
    @ObservationIgnored private var lastTranscriptAlignmentAttempt = Date.distantPast
    @ObservationIgnored private var sourceHandoffAttempts: Set<String> = []
    @ObservationIgnored private var sourceContextTask: Task<Void, Never>?
    @ObservationIgnored private var sourceContextGeneration = UUID()
    /// A verified, expiring Googlevideo URL is a playback resource, never a
    /// downloaded file or a persisted Episode.sourceURL. Its captions, chapters
    /// and SponsorBlock cuts belong only to the YouTube source clock.
    private struct YouTubeStream {
        var episodeID: UUID
        var videoID: String
        var url: URL
        var duration: Double
        var transcript: [TranscriptLine]
        var chapters: [Chapter]
        var cuts: [CutSegment]
        var resolvedAt: Date
    }
    @ObservationIgnored private var preparedYouTubeStream: YouTubeStream?
    @ObservationIgnored private var activeYouTubeStream: YouTubeStream?
    @ObservationIgnored private var streamTranscript: [TranscriptLine] = []
    @ObservationIgnored private var streamChapters: [Chapter] = []
    @ObservationIgnored private var streamTask: Task<Void, Never>?
    @ObservationIgnored private var streamChapterTask: Task<Void, Never>?
    @ObservationIgnored private var streamGeneration = UUID()
    /// The queue panel (Up Next) is open. It shares the side column with the chapters & transcript panel.
    var showQueue = false
    /// Episodes to play next, in order (kept between launches).
    var queue: [UUID] = (UserDefaults.standard.stringArray(forKey: "upNextQueue") ?? []).compactMap(UUID.init(uuidString:)) {
        didSet {
            // Test fixtures must never overwrite the user's real playback queue,
            // even when their audio output is intentionally audible.
            if !suppressUserSessionWrites && !testMute {
                UserDefaults.standard.set(queue.map(\.uuidString), forKey: "upNextQueue")
            }
        }
    }
    /// Queue entries leave `queue` as soon as they start. Keep the actual playback trail
    /// separately so Previous can return to a consumed item, and Next can retrace it.
    @ObservationIgnored private var playbackBackStack: [UUID] = []
    @ObservationIgnored private var playbackForwardStack: [UUID] = []

    func previousQueuedEpisode() {
        while let previous = playbackBackStack.popLast() {
            guard previous != episodeID, library?.episode(previous)?.canPlay == true else { continue }
            if let current = episodeID { playbackForwardStack.append(current) }
            if playbackForwardStack.count > 100 { playbackForwardStack.removeFirst(playbackForwardStack.count - 100) }
            load(previous, autoplay: true, recordHistory: false)
            return
        }
        library?.flash("There is no previous episode.")
    }

    func nextQueuedEpisode() {
        // Retrace a previous skip first, even if those entries have already been dequeued.
        while let next = playbackForwardStack.popLast() {
            guard next != episodeID, library?.episode(next)?.canPlay == true else { continue }
            if let current = episodeID { playbackBackStack.append(current) }
            if playbackBackStack.count > 100 { playbackBackStack.removeFirst(playbackBackStack.count - 100) }
            load(next, autoplay: true, recordHistory: false)
            return
        }
        if let next = upNext.first { play(next.id) }
        else { library?.flash("There is no next queued episode.") }
    }

    func toggleTranscriptPanel() {
        showQueue = false
        showChapters.toggle()
    }

    func toggleQueuePanel() {
        showChapters = false
        showQueue.toggle()
    }

    func playNext(_ id: UUID) {
        queue.removeAll { $0 == id }
        queue.insert(id, at: 0)
        library?.flash("Playing next")
    }

    func addToQueue(_ id: UUID) {
        guard !queue.contains(id) else { return }
        queue.append(id)
        library?.flash("Added to queue")
    }

    func removeFromQueue(_ id: UUID) { queue.removeAll { $0 == id } }

    /// Queued episodes that can still be played (not the one playing now).
    var upNext: [Episode] {
        queue.compactMap { library?.episode($0) }.filter { $0.canPlay && $0.id != episodeID }
    }

    /// Half-listened episodes not already queued or playing.
    var continuePlaying: [Episode] {
        let queued = Set(queue)
        return (library?.continueListening ?? []).filter { $0.id != episodeID && !queued.contains($0.id) }
    }

    /// Sleep timer: seconds left (nil = off); `sleepAtEnd` pauses when the episode ends.
    var sleepRemaining: Double? = nil
    var sleepAtEnd = false
    var volume: Double = 1.0 {
        didSet {
            if volume > 0 { lastAudibleVolume = volume }
            avPlayer?.volume = testMute ? 0 : Float(volume)
        }
    }
    @ObservationIgnored private var lastAudibleVolume: Double = 1.0
    func toggleMute() { volume = volume > 0 ? 0 : lastAudibleVolume }
    /// Screenshot and test runs play silently, whatever the volume says.
    @ObservationIgnored var testMute = false
    /// Isolated fixtures may play audible media without changing real UserDefaults.
    /// Keep testMute as a legacy safeguard for existing silent screenshot tests.
    @ObservationIgnored var suppressUserSessionWrites = false
    var avPlayerForRoutes: AVPlayer? { avPlayer }

    func setSleep(minutes: Int?) {
        sleepAtEnd = false
        sleepRemaining = minutes.map { Double($0 * 60) }
    }

    func sleepAtEndOfEpisode() {
        sleepRemaining = nil
        sleepAtEnd = true
    }

    @ObservationIgnored private weak var library: Library?
    @ObservationIgnored private var avPlayer: AVPlayer?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastTick = Date()
    @ObservationIgnored private var saveCounter = 0
    @ObservationIgnored private var systemMedia: SystemMedia?
    /// Incremented on every replacement; callbacks from old AVPlayerItems must never modify
    /// the newly selected episode, even when the old stream completes after a fast switch.
    @ObservationIgnored private var playbackGeneration: UInt64 = 0
    /// One completion per playback run, even when AVPlayer posts duplicate end events.
    /// Reset when an item is replaced or a completed episode is explicitly replayed.
    @ObservationIgnored private var completedPlaybackGeneration: UInt64?
    @ObservationIgnored private var seekGeneration: UInt64 = 0
    @ObservationIgnored private var initialSeekPending = false
    @ObservationIgnored private var seekInFlight = false
    @ObservationIgnored private var deferredPositionSave: Task<Void, Never>?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var failureObserver: NSObjectProtocol?
    @ObservationIgnored private var itemStatusObservation: NSKeyValueObservation?
    @ObservationIgnored private var cutBoundaryObserver: Any?
    @ObservationIgnored private var skipTimeline = SponsorTimeline(sourceDuration: 0, cuts: [])
    @ObservationIgnored private var observedCutMetadata: [CutSegment] = []
    @ObservationIgnored private var loadedMediaURL: URL?
    /// Source identity captured when AVPlayer was created. Processing may replace
    /// Episode's file with a different YouTube edition while this item still plays.
    @ObservationIgnored private var loadedYouTubeMediaID: String?
    /// Coalesce artwork lookups requested during rapid episode switching. The library
    /// owns the actual background matching and its retry policy.
    @ObservationIgnored private var pendingYouTubeArtwork: Set<UUID> = []

    init(library: Library, suppressUserSessionWrites: Bool = false) {
        self.library = library
        self.suppressUserSessionWrites = suppressUserSessionWrites
        self.rate = library.settings.defaultSpeed
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        systemMedia = SystemMedia(player: self)
        if let path = ProcessInfo.processInfo.environment["PODCRAFT_PLAYBACK_STRESS"] {
            Task { @MainActor [weak self, weak library] in
                try? await Task.sleep(for: .milliseconds(200))
                guard let self, let library else { return }
                await PlaybackStress.run(player: self, library: library, file: path)
            }
        }
    }

    isolated deinit {
        timer?.invalidate()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
    }

    var episode: Episode? { episodeID.flatMap { library?.episode($0) } }
    var showForNowPlaying: Show? { episode.flatMap { library?.show($0.showID) } }
    /// Effective playback times; original chapters remain unmodified in Episode metadata.
    var chapters: [Chapter] {
        if let stream = activeYouTubeStream {
            if !streamChapters.isEmpty { return streamChapters }
            // A previously processed audio representation of this exact upload
            // shares the stream clock. Keep its generated chapters when YouTube
            // metadata itself has no native chapter list.
            if let episode, episode.youtubeMediaID == stream.videoID {
                return episode.playbackChapters
            }
            return []
        }
        guard let episode else { return [] }
        if !metadataMatchesLoadedRecording(episode) {
            return pendingPreferredYouTube?.id == episodeID ? outgoingVisibleChapters : []
        }
        return episode.playbackChapters
    }

    /// The local editor works in the immutable source recording's coordinates.
    var sourceDuration: Double { skipTimeline.sourceDuration }
    var sourcePosition: Double {
        if let time = avPlayer?.currentTime().seconds, time.isFinite, !seekInFlight { return time }
        return skipTimeline.sourceTime(forVisible: position)
    }
    var visibleTranscript: [TranscriptLine] {
        if activeYouTubeStream != nil { return streamTranscript }
        guard let episode else { return [] }
        if !metadataMatchesLoadedRecording(episode) {
            return pendingPreferredYouTube?.id == episodeID ? outgoingVisibleTranscript : []
        }
        return episode.playbackTranscript
    }

    /// RSS audio becoming a local download is the same edition when its source
    /// identity and clock agree. A newly matched YouTube edition has its own clock.
    private func metadataMatchesLoadedRecording(_ episode: Episode) -> Bool {
        if activeYouTubeStream != nil { return false }
        guard let loadedMediaURL else { return true }
        guard loadedYouTubeMediaID == episode.youtubeMediaID else { return false }
        if episode.playableURL == loadedMediaURL { return true }
        if let actual = avPlayer?.currentItem?.duration.seconds,
           actual.isFinite, actual > 0, episode.duration.isFinite, episode.duration > 0 {
            return abs(actual - episode.duration) <= max(2, actual * 0.002)
        }
        return true
    }

    func visibleTime(forSource time: Double) -> Double { skipTimeline.visibleTime(forSource: time) }
    func sourceTime(forVisible time: Double) -> Double { skipTimeline.sourceTime(forVisible: time) }
    func seekSourceTime(_ time: Double) { seek(to: skipTimeline.visibleTime(forSource: time)) }

    /// Synchronize a newly saved editor draft while playback continues. Existing source
    /// positions are retained; only their visible coordinates and boundary observers change.
    func refreshSkipMetadata() {
        guard let episode else { return }
        // A downloaded copy of the same RSS edition may publish fresh chapters and
        // cuts without disturbing playback. Never apply an alternate edition's cuts.
        guard metadataMatchesLoadedRecording(episode) else { return }
        let source = sourcePosition
        let cuts = episode.cutApplied && episode.originalLocalFile == nil ? [] : episode.cuts
        let itemDuration = avPlayer?.currentItem?.duration.seconds
        let sourceDuration: Double
        if let itemDuration, itemDuration.isFinite, itemDuration > 0 {
            sourceDuration = itemDuration
        } else {
            sourceDuration = episode.duration
        }
        guard observedCutMetadata != cuts || abs(skipTimeline.sourceDuration - sourceDuration) > 0.1 else { return }
        observedCutMetadata = cuts
        skipTimeline = SponsorTimeline(sourceDuration: sourceDuration, cuts: cuts)
        duration = skipTimeline.duration
        position = skipTimeline.visibleTime(forSource: source)
        installCutBoundaryObserver()
        skipExcludedAudioIfNeeded()
        systemMedia?.publish()
    }

    private func installCutBoundaryObserver() {
        if let cutBoundaryObserver, let avPlayer { avPlayer.removeTimeObserver(cutBoundaryObserver) }
        cutBoundaryObserver = nil
        guard let avPlayer, !skipTimeline.skipped.isEmpty else { return }
        let markers = skipTimeline.skipped.map { range in
            NSValue(time: CMTime(seconds: range.lowerBound, preferredTimescale: 600))
        }
        let generation = playbackGeneration
        cutBoundaryObserver = avPlayer.addBoundaryTimeObserver(forTimes: markers, queue: .main) { [weak self] in
            // Already delivered on the main queue: skip immediately instead of
            // scheduling another task that could let ad audio play briefly.
            MainActor.assumeIsolated {
                guard let self, self.playbackGeneration == generation else { return }
                self.skipExcludedAudioIfNeeded(atBoundary: true)
            }
        }
    }

    private func skipExcludedAudioIfNeeded(atBoundary: Bool = false) {
        guard let avPlayer, !seekInFlight else { return }
        let raw = avPlayer.currentTime().seconds
        guard raw.isFinite else { return }
        let end = skipTimeline.endOfSkippedRange(atSource: raw) ?? (atBoundary
            ? skipTimeline.skipped.first(where: { abs(raw - $0.lowerBound) < 0.12 })?.upperBound : nil)
        guard let end else { return }
        position = skipTimeline.visibleTime(forSource: end)
        // The last seconds of many RSS podcasts are inserted commercials. If the
        // excluded range reaches the file's end, the *visible* episode has ended
        // now. Complete it directly: seeking AVPlayer to the physical EOF does not
        // reliably emit AVPlayerItemDidPlayToEndTime on all media formats.
        if isPlaying && end >= skipTimeline.sourceDuration - 0.015 {
            completeEpisode()
            return
        }
        seekPlayer(avPlayer, to: end, generation: playbackGeneration)
    }

    var currentChapterIndex: Int? {
        let list = chapters
        guard !list.isEmpty else { return nil }
        return list.lastIndex { $0.start <= position + 0.01 } ?? 0
    }

    var currentChapter: Chapter? { currentChapterIndex.map { chapters[$0] } }
    var hasNextChapter: Bool { currentChapterIndex.map { $0 + 1 < chapters.count } ?? false }
    var hasPreviousChapter: Bool { !chapters.isEmpty }

    // MARK: Loading

    /// Play immediately using the recording already available (often RSS).
    /// An exact official YouTube match is acquired in parallel and only adopted
    /// after the transcripts prove which spoken passage is under the playhead.
    func play(_ id: UUID) { playPreferredSource(id, requestedVideo: nil) }

    /// The episode's YouTube icon explicitly requests video even if the show's
    /// default is audio-only. This is a user-driven change of recording/source.
    func playYouTubeVideo(_ id: UUID) { playPreferredSource(id, requestedVideo: true) }

    /// Keep the current audio clock playing while hiding/cancelling only the
    /// visual video request. Chapters and captions remain attached to playback.
    func showAudioOnly() {
        if pendingPreferredYouTube?.video == true { cancelPendingPreferredPlayback() }
        showVideo = false
    }

    private func playPreferredSource(_ id: UUID, requestedVideo: Bool?) {
        guard let lib = library, let e = lib.episode(id) else { return }
        let video = requestedVideo ?? lib.show(e.showID)?.youtubePlaybackVideo ?? false
        if let pending = pendingPreferredYouTube, pending.id == id {
            if pending.video != video {
                // Switching from the audio button to the video icon updates the
                // requested representation without interrupting current speech.
                cancelPendingPreferredPlayback()
                beginPreferredHandoff(id, video: video, in: lib)
            }
            if !isPlaying { togglePlay() }
            return
        }
        if episodeID != id { cancelPendingPreferredPlayback() }
        // The existing AVPlayer must remain audible while the media and speech
        // context are prepared. Do not reset its source time to zero.
        if episodeID != id || avPlayer == nil { load(id, autoplay: true) }
        else if !isPlaying { togglePlay() }
        guard let show = lib.show(e.showID), !show.isFiles,
              show.youtubeChannelURL != nil, e.youtubeMatchState == .matched,
              e.youtubeID != nil else { return }
        let key = "\(id.uuidString):\(e.youtubeID!):\(video)"
        sourceHandoffAttempts.remove(key) // explicit Play is a deliberate retry
        if loadedYouTubeMediaID == e.youtubeID && (!video || videoPlayer != nil) {
            return
        }
        beginPreferredHandoff(id, video: video, in: lib)
    }

    private func beginPreferredHandoff(_ id: UUID, video: Bool, in lib: Library) {
        guard episodeID == id, let e = lib.episode(id), e.youtubeMatchState == .matched,
              let videoID = e.youtubeID else { return }
        if video {
            beginStreamingVideo(id, videoID: videoID, in: lib)
            return
        }
        // If the new representation is already downloaded, use it as a target
        // for contextual alignment without triggering a redundant network job.
        let targetReady = e.youtubeMediaID == videoID && e.localFile != nil &&
                          (!video || e.isVideo)
        guard targetReady || lib.processor?.preparePreferredYouTubePlayback(id, video: video) == true else { return }
        pendingPreferredYouTube = (id, video)
        preparingYouTubeEpisodeID = id
        preparingYouTubeVideo = video
        youtubePreparationProgress = 0.05
        youtubePreparationStatus = "Connecting video…"
        sourceHandoffAttempts.insert("\(id.uuidString):\(videoID):\(video)")
        lastTranscriptAlignmentAttempt = .distantPast
        rememberSpokenSourceContext()
        requestMissingSourceSpeechContext()
        lib.flash(video ? "Playing current audio · aligning YouTube video…" :
                          "Playing current audio · aligning YouTube audio…")
    }

    /// Resolve only the short-lived signed playback URL. A YouTube VIDEO is
    /// streamed into AVPlayer; no MP4 is transferred to PodCraft's media folder.
    /// RSS remains audible while an accurate speech-context mapping is sought.
    private func beginStreamingVideo(_ id: UUID, videoID: String, in lib: Library) {
        guard let e = lib.episode(id), let show = lib.show(e.showID),
              let linked = show.youtubeChannelURL,
              let canonical = YouTubeSource.channelURL(from: linked),
              e.youtubeMatchChannelURL.map({ YouTubeSource.channelURL(from: $0) == canonical }) ?? true
        else { return }
        pendingPreferredYouTube = (id, true)
        preparingYouTubeEpisodeID = id
        preparingYouTubeVideo = true
        youtubePreparationProgress = 0.05
        youtubePreparationStatus = "Connecting video…"
        lastTranscriptAlignmentAttempt = .distantPast
        sourceHandoffAttempts.insert("\(id.uuidString):\(videoID):true")
        rememberSpokenSourceContext()
        requestMissingSourceSpeechContext()
        let generation = UUID()
        streamGeneration = generation
        streamTask?.cancel()
        preparedYouTubeStream = nil
        lib.flash("Playing current audio · connecting to YouTube stream…")
        streamTask = Task { @MainActor [weak self, weak lib] in
            guard let self, let lib else { return }
            defer { if self.streamGeneration == generation { self.streamTask = nil } }
            do {
                // Recheck actual official uploader and exact episode before resolving
                // the CDN URL; a cached video ID alone is not an authorization.
                guard let match = try await YouTubeSource.match(episode: e, channelURL: linked),
                      match.id == videoID else { throw YouTubeSource.Failure.verificationFailed }
                self.youtubePreparationProgress = 0.25
                self.youtubePreparationStatus = "Connecting video…"
                let result = try await YouTubeSource.playableStream(videoID: videoID,
                                                                   channelID: match.channelID)
                try Task.checkCancellation()
                guard self.streamGeneration == generation,
                      self.episodeID == id,
                      self.pendingPreferredYouTube?.id == id,
                      self.pendingPreferredYouTube?.video == true else { return }
                var prepared = YouTubeStream(episodeID: id, videoID: videoID,
                                             url: result.url, duration: result.duration,
                                             transcript: [], chapters: result.chapters.map {
                                                 Chapter(start: $0.start, title: $0.title)
                                             }, cuts: [], resolvedAt: Date())
                // An existing verified YouTube audio transcript has exactly this
                // video ID/clock; an RSS transcript emphatically does not.
                if e.youtubeMediaID == videoID { prepared.transcript = e.transcript }
                self.preparedYouTubeStream = prepared
                if prepared.transcript.isEmpty {
                    self.youtubePreparationProgress = 0.55
                    self.youtubePreparationStatus = "Connecting video…"
                    let language = e.language ?? show.language ?? lib.expectedLanguage(for: e)
                    if let captions = try? await YouTubeSource.captions(
                        episode: e, channelURL: linked, videoID: videoID,
                        language: language, duration: result.duration),
                       self.streamGeneration == generation,
                       self.episodeID == id {
                        self.preparedYouTubeStream?.transcript = captions
                    }
                }
                guard !Task.isCancelled, self.streamGeneration == generation,
                      self.episodeID == id else { return }
                self.youtubePreparationProgress = 0.8
                self.youtubePreparationStatus = "Connecting video…"
                if lib.settings.removeSponsors && lib.settings.useSponsorBlock,
                   let cuts = try? await SponsorBlock.segments(
                       videoID: videoID, categories: lib.settings.sponsorCategories),
                   self.streamGeneration == generation {
                    self.preparedYouTubeStream?.cuts = cuts
                }
                self.lastTranscriptAlignmentAttempt = .distantPast
                self.youtubePreparationProgress = 0.95
                self.youtubePreparationStatus = "Connecting video…"
            } catch is CancellationError { return }
            catch {
                guard self.streamGeneration == generation else { return }
                self.cancelPendingPreferredPlayback()
                lib.flash("YouTube streaming unavailable; continuing the current recording. \(error.localizedDescription)")
            }
        }
    }

    /// Copy *old* source text while it still belongs to the loaded AVPlayer.
    /// The Processor later clears source-incompatible episode metadata; this
    /// copy is transient and never persisted onto the YouTube recording.
    private func rememberSpokenSourceContext() {
        guard let pendingPreferredYouTube, pendingPreferredYouTube.id == episodeID,
              let lib = library, let current = lib.episode(pendingPreferredYouTube.id),
              metadataMatchesLoadedRecording(current) else { return }
        if !current.transcript.isEmpty {
            outgoingSourceTranscript = current.transcript
            outgoingVisibleTranscript = current.playbackTranscript
        }
        outgoingVisibleChapters = current.playbackChapters
        outgoingMediaID = loadedYouTubeMediaID
    }

    private func requestMissingSourceSpeechContext() {
        guard sourceContextTask == nil, outgoingSourceTranscript.isEmpty,
              let pending = pendingPreferredYouTube,
              let lib = library, lib.settings.transcribe,
              let existing = loadedMediaURL,
              let processor = lib.processor, let episode = lib.episode(pending.id) else { return }
        let point = sourcePosition
        let language = episode.language ?? lib.show(episode.showID)?.language
        let generation = UUID()
        sourceContextGeneration = generation
        sourceContextTask = Task { @MainActor [weak self, weak processor] in
            defer {
                if self?.sourceContextGeneration == generation { self?.sourceContextTask = nil }
            }
            guard let processor else { return }
            do {
                let lines = try await processor.transcribeSourceContext(
                    from: existing, near: point, language: language,
                    currentSourceTime: { [weak self] in self?.sourcePosition ?? point })
                guard !Task.isCancelled, let self,
                      self.sourceContextGeneration == generation,
                      self.pendingPreferredYouTube?.id == pending.id,
                      self.loadedMediaURL == existing,
                      self.outgoingSourceTranscript.isEmpty else { return }
                self.outgoingSourceTranscript = lines
                self.outgoingVisibleTranscript = lines.compactMap { line in
                    guard self.skipTimeline.visibleSourceRange(line.start, line.end) else { return nil }
                    return TranscriptLine(start: self.skipTimeline.visibleTime(forSource: line.start),
                                          end: self.skipTimeline.visibleTime(forSource: line.end), text: line.text)
                }
                self.lastTranscriptAlignmentAttempt = .distantPast
            } catch is CancellationError { return }
            catch { /* No reliable local speech sample: retain the original recording. */ }
        }
    }

    /// Transcript context is compared with the new recording only while the
    /// current source is actively playing. The source clock is read afresh on
    /// each attempt, so a slow download cannot make us jump to a stale point.
    private func tryContextualYouTubeHandoff(_ target: Episode, requestedVideo: Bool, now: Date) -> Bool {
        guard isPlaying, let currentID = episodeID, target.id == currentID,
              let loadedMediaURL, target.youtubeMediaID == target.youtubeID,
              target.youtubeID != nil, let targetURL = target.playableURL,
              targetURL != loadedMediaURL, (!requestedVideo || target.isVideo),
              targetURL.isFileURL, FileManager.default.isReadableFile(atPath: targetURL.path),
              now.timeIntervalSince(lastTranscriptAlignmentAttempt) >= 1.5 else { return false }
        lastTranscriptAlignmentAttempt = now

        let sourceSecond = sourcePosition
        let mapped: Double
        if outgoingMediaID != nil, outgoingMediaID == target.youtubeMediaID,
           abs(skipTimeline.sourceDuration - target.duration) <= 2.0 {
            // M4A and MP4 representations of the same upload share a source
            // clock. No speech inference or time-offset guessing is needed.
            mapped = sourceSecond
        } else {
            guard !outgoingSourceTranscript.isEmpty, !target.transcript.isEmpty,
                  let alignment = TranscriptSourceAlignment.align(
                      from: outgoingSourceTranscript, to: target.transcript,
                      atSource: sourceSecond, targetDuration: target.duration) else { return false }
            mapped = alignment.targetTime
        }
        let destination = SponsorTimeline(sourceDuration: target.duration,
                                          cuts: target.cutApplied && target.originalLocalFile == nil ? [] : target.cuts)
        let visibleTarget = destination.visibleTime(forSource: mapped)
        let keepManualScroll = !transcriptFollowsPlayback
        cancelPendingPreferredPlayback()
        load(currentID, autoplay: true, at: visibleTarget, recordHistory: false)
        if keepManualScroll { transcriptFollowsPlayback = false }
        library?.flash("Aligned the spoken passage · now playing verified YouTube")
        return true
    }

    /// Unlike a downloaded YouTube file, streaming has no persistent
    /// Episode.localFile. Align source-specific captions against the passage
    /// presently audible in RSS, then give AVPlayer the direct remote URL.
    private func tryContextualVideoStreamHandoff(now: Date) -> Bool {
        guard isPlaying, let pending = pendingPreferredYouTube, pending.video,
              pending.id == episodeID, let target = preparedYouTubeStream,
              target.episodeID == pending.id,
              target.url.scheme?.lowercased() == "https",
              let current = library?.episode(pending.id),
              current.youtubeMatchState == .matched,
              current.youtubeID == target.videoID,
              now.timeIntervalSince(lastTranscriptAlignmentAttempt) >= 1.5 else { return false }
        // CDN signatures are transient. Never open an old URL after a long
        // speech-alignment wait; the user can retry to resolve a fresh one.
        guard now.timeIntervalSince(target.resolvedAt) < 120 else {
            cancelPendingPreferredPlayback()
            library?.flash("YouTube stream link expired while aligning speech. Select video to retry.")
            return false
        }
        lastTranscriptAlignmentAttempt = now
        let sourceSecond = sourcePosition
        let mapped: Double
        if outgoingMediaID == target.videoID,
           abs(skipTimeline.sourceDuration - target.duration) <= 2 {
            // Already playing the exact YouTube upload as audio, just change
            // representation. Source timestamps remain interchangeable.
            mapped = sourceSecond
        } else {
            guard !outgoingSourceTranscript.isEmpty, !target.transcript.isEmpty,
                  let match = TranscriptSourceAlignment.align(
                    from: outgoingSourceTranscript, to: target.transcript,
                    atSource: sourceSecond, targetDuration: target.duration) else { return false }
            mapped = match.targetTime
        }
        let destination = SponsorTimeline(sourceDuration: target.duration, cuts: target.cuts)
        let targetPosition = destination.visibleTime(forSource: mapped)
        let keepManualScroll = !transcriptFollowsPlayback
        cancelPendingPreferredPlayback()
        activateYouTubeStream(target, at: targetPosition)
        if keepManualScroll { transcriptFollowsPlayback = false }
        library?.flash("Aligned the spoken passage · streaming verified YouTube video")
        return true
    }

    private func activateYouTubeStream(_ stream: YouTubeStream, at visiblePosition: Double) {
        guard episodeID == stream.episodeID else { return }
        // Preserve the currently visible chapter navigation until the verified
        // stream supplies native or caption-generated replacements.
        let handoffChapters = chapters
        deferredPositionSave?.cancel()
        deferredPositionSave = nil
        // Never persist stream timestamps into RSS Episode metadata.
        recordPosition()
        releaseCurrentItem()
        activeYouTubeStream = stream
        // Retire a legacy zero-progress preparation marker. The verified stream
        // is already active, so this state cannot describe current work.
        if let lib = library, let index = lib.episodeIndex(stream.episodeID),
           lib.episodes[index].stage == .queued, lib.episodes[index].progress == 0,
           lib.episodes[index].note?.contains("Preparing verified YouTube") == true {
            lib.episodes[index].stage = lib.episodes[index].localFile == nil ? .listed : .ready
            lib.episodes[index].note = nil
            lib.save()
        }
        let timeline = SponsorTimeline(sourceDuration: stream.duration, cuts: stream.cuts)
        observedCutMetadata = stream.cuts
        skipTimeline = timeline
        duration = timeline.duration
        position = min(max(0, visiblePosition), duration)
        streamChapters = stream.chapters.sorted { $0.start < $1.start }.compactMap { chapter in
            guard !timeline.containsSource(chapter.start) else { return nil }
            return Chapter(start: timeline.visibleTime(forSource: chapter.start), title: chapter.title)
        }
        if streamChapters.isEmpty { streamChapters = handoffChapters }
        streamTranscript = stream.transcript.compactMap { line in
            guard timeline.visibleSourceRange(line.start, line.end),
                  !timeline.skipped.contains(where: {
                      line.start < $0.upperBound && line.end > $0.lowerBound
                  }) else { return nil }
            return TranscriptLine(start: timeline.visibleTime(forSource: line.start),
                                  end: timeline.visibleTime(forSource: line.end), text: line.text)
        }
        generateMissingStreamChapters(stream)
        let p = AVPlayer(url: stream.url)
        p.volume = testMute ? 0 : Float(volume)
        p.isMuted = testMute
        avPlayer = p
        videoPlayer = p
        showVideo = true
        loadedMediaURL = stream.url
        loadedYouTubeMediaID = stream.videoID
        if let item = p.currentItem { observe(item, generation: playbackGeneration) }
        installCutBoundaryObserver()
        isPlaying = true
        lastTick = Date()
        let sourceStart = timeline.sourceTime(forVisible: position)
        if sourceStart > 0.01 {
            initialSeekPending = true
            seekPlayer(p, to: sourceStart, generation: playbackGeneration)
        } else {
            p.playImmediately(atRate: Float(rate))
        }
        saveSession()
        systemMedia?.publish()
    }

    private func cancelPendingPreferredPlayback() {
        sourceContextGeneration = UUID()
        sourceContextTask?.cancel()
        sourceContextTask = nil
        streamGeneration = UUID()
        streamTask?.cancel()
        streamTask = nil
        streamChapterTask?.cancel()
        streamChapterTask = nil
        preparedYouTubeStream = nil
        pendingPreferredYouTube = nil
        preparingYouTubeEpisodeID = nil
        preparingYouTubeVideo = false
        youtubePreparationProgress = 0
        youtubePreparationStatus = nil
        outgoingSourceTranscript = []
        outgoingVisibleTranscript = []
        outgoingVisibleChapters = []
        outgoingMediaID = nil
        lastTranscriptAlignmentAttempt = .distantPast
    }

    /// Native YouTube chapters win. If the verified stream has captions but no
    /// chapters, generate them independently after video activation so playback
    /// and captions never wait for the model.
    private func generateMissingStreamChapters(_ stream: YouTubeStream) {
        streamChapterTask?.cancel()
        streamChapterTask = nil
        guard stream.chapters.isEmpty, !stream.transcript.isEmpty,
              let lib = library, lib.settings.generateChapters,
              lib.settings.aiProvider != .off else { return }
        if let episode = lib.episode(stream.episodeID), episode.youtubeMediaID == stream.videoID,
           !episode.chapters.isEmpty { return }
        let generation = streamGeneration
        let provider = lib.settings.aiProvider
        let model = lib.settings.geminiModel
        streamChapterTask = Task { @MainActor [weak self, weak lib] in
            guard let self, let lib else { return }
            defer { if self.streamGeneration == generation { self.streamChapterTask = nil } }
            do {
                let found = try await AIService.chapters(
                    lines: stream.transcript, duration: stream.duration,
                    provider: provider, model: model, findSponsors: false)
                guard !Task.isCancelled, self.streamGeneration == generation,
                      self.activeYouTubeStream?.videoID == stream.videoID else { return }
                let source = found.chapters
                self.activeYouTubeStream?.chapters = source
                let timeline = SponsorTimeline(sourceDuration: stream.duration,
                                               cuts: self.activeYouTubeStream?.cuts ?? [])
                self.streamChapters = source.compactMap { chapter in
                    guard !timeline.containsSource(chapter.start) else { return nil }
                    return Chapter(start: timeline.visibleTime(forSource: chapter.start), title: chapter.title)
                }
                if let index = lib.episodeIndex(stream.episodeID),
                   lib.episodes[index].youtubeMediaID == stream.videoID,
                   lib.episodes[index].chapters.isEmpty {
                    lib.episodes[index].chapters = source
                    lib.save()
                }
            } catch is CancellationError {
                return
            } catch {
                // Captions and video remain usable when optional chapter generation fails.
            }
        }
    }

    /// Adopt source-consistent media/captions as soon as they are ready; chapter
    /// analysis may continue in the background and will update the same episode.
    func episodePlaybackPrepared(_ id: UUID) {
        guard episodeID == id, let pending = pendingPreferredYouTube,
              pending.id == id, let updated = library?.episode(id) else { return }
        youtubePreparationProgress = 0.95
        youtubePreparationStatus = "Connecting video…"
        rememberSpokenSourceContext()
        if pending.video {
            _ = tryContextualVideoStreamHandoff(now: Date())
        } else if tryContextualYouTubeHandoff(updated, requestedVideo: false, now: Date()) {
            return
        } else if updated.youtubeMediaID == updated.youtubeID, updated.localFile != nil {
            // If the RSS edition has no transcript to align, do not leave an
            // explicit Play request spinning forever. Preserve approximate
            // listening position by mapping the fraction of the old recording.
            let fraction = duration > 0 ? min(1, max(0, position / duration)) : 0
            let approximate = fraction * updated.playbackDuration
            cancelPendingPreferredPlayback()
            load(id, autoplay: true, at: approximate, recordHistory: false)
            library?.flash("Now playing verified YouTube audio · position matched approximately")
        }
    }

    private func ensureYouTubeArtworkLater(_ id: UUID, in library: Library) {
        guard pendingYouTubeArtwork.insert(id).inserted else { return }
        Task { @MainActor [weak self, weak library] in
            self?.pendingYouTubeArtwork.remove(id)
            library?.ensureYouTubeArtwork(forEpisode: id)
        }
    }

    /// Load an episode into the player; `autoplay: false` leaves it paused (used to restore the last session).
    func load(_ id: UUID, autoplay: Bool, at start: Double? = nil, recordHistory: Bool = true) {
        scrubPreviewChapterTitle = nil
        guard let lib = library, let e = lib.episode(id), e.canPlay else { return }
        if let pending = pendingPreferredYouTube, pending.id != id { cancelPendingPreferredPlayback() }
        // Playback and explicit selection can lazily verify an episode's YouTube cover.
        // An internal reload after a media-source change must not initiate another lookup.
        if recordHistory || episodeID != id { ensureYouTubeArtworkLater(id, in: lib) }
        if queue.contains(id) { queue.removeAll { $0 == id } }
        if autoplay { markRecentlyPlayed(id, in: lib) }
        let sameEpisode = episodeID == id
        if sameEpisode && (activeYouTubeStream != nil || loadedMediaURL == e.playableURL) {
            if autoplay && !isPlaying { togglePlay() }
            return
        }
        if !sameEpisode {
            // Keep only the selected recording's source context; a long queue
            // session must not retain every prior episode's transcript.
            sourceHandoffAttempts.removeAll()
            outgoingSourceTranscript = e.transcript
            outgoingVisibleTranscript = e.playbackTranscript
            outgoingVisibleChapters = e.playbackChapters
            outgoingMediaID = e.youtubeMediaID
        }
        if recordHistory, let old = episodeID, old != id {
            playbackBackStack.append(old)
            if playbackBackStack.count > 100 { playbackBackStack.removeFirst(playbackBackStack.count - 100) }
            playbackForwardStack.removeAll()
        }
        // Switching episodes commits both the previous position and the new selection
        // with one library write. Repeatedly serializing the complete transcript library
        // for each step of a quick queue switch causes avoidable main-thread stalls.
        deferredPositionSave?.cancel()
        deferredPositionSave = nil
        // When the same episode changes from RSS audio to a matched YouTube source,
        // its old clock does not describe the new recording: don't overwrite the
        // newly selected source's duration/position with stale player state.
        if !sameEpisode { recordPosition() }
        releaseCurrentItem()
        episodeID = id
        transcriptScrollEpisodeID = id
        transcriptScrollAnchor = nil
        transcriptFollowsPlayback = true
        let cuts = e.cutApplied && e.originalLocalFile == nil ? [] : e.cuts
        observedCutMetadata = cuts
        skipTimeline = SponsorTimeline(sourceDuration: e.duration, cuts: cuts)
        duration = skipTimeline.duration
        let requested = start ?? (e.played ? 0 : e.position)
        position = requested.isFinite ? min(max(0, requested), duration > 0 ? duration : .greatestFiniteMagnitude) : 0
        if let url = e.playableURL {
            let p = AVPlayer(url: url)
            loadedMediaURL = url
            loadedYouTubeMediaID = e.youtubeMediaID
            p.volume = testMute ? 0 : Float(volume)
            p.isMuted = testMute
            avPlayer = p
            if e.isVideo { videoPlayer = p; showVideo = true }
            if let item = p.currentItem { observe(item, generation: playbackGeneration) }
            installCutBoundaryObserver()
            let rawStart = skipTimeline.sourceTime(forVisible: position)
            if rawStart > 0.01 {
                initialSeekPending = true
                seekPlayer(p, to: rawStart, generation: playbackGeneration)
            }
        }
        isPlaying = false
        saveSession()
        lib.save()
        systemMedia?.publish()
        guard autoplay else { return }
        togglePlay()
        // Keep this AVPlayer and its stream alive. The queued processor updates the shared
        // Episode in place, so transcript and chapter UI appear as soon as analysis completes.
        lib.analyzeIfNeededForPlayback(id)
    }

    /// End notifications and KVO tokens belong to exactly one AVPlayerItem. Invalidate
    /// them *before* releasing the player so in-flight events cannot finish a new episode.
    private func releaseCurrentItem() {
        streamChapterTask?.cancel()
        streamChapterTask = nil
        playbackGeneration &+= 1
        completedPlaybackGeneration = nil
        seekGeneration &+= 1
        initialSeekPending = false
        seekInFlight = false
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        endObserver = nil
        failureObserver = nil
        itemStatusObservation = nil
        if let cutBoundaryObserver, let avPlayer { avPlayer.removeTimeObserver(cutBoundaryObserver) }
        cutBoundaryObserver = nil
        avPlayer?.pause()
        avPlayer?.currentItem?.cancelPendingSeeks()
        avPlayer?.replaceCurrentItem(with: nil)
        avPlayer = nil
        videoPlayer = nil
        loadedMediaURL = nil
        loadedYouTubeMediaID = nil
        activeYouTubeStream = nil
        streamTranscript = []
        streamChapters = []
    }

    private func observe(_ item: AVPlayerItem, generation: UInt64) {
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.playbackGeneration == generation else { return }
                self.completeEpisode()
            }
        }
        failureObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
        ) { [weak self] notification in
            let description = (notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?
                .localizedDescription ?? "The episode could not finish playing."
            Task { @MainActor [weak self] in
                guard let self, self.playbackGeneration == generation else { return }
                self.failPlayback(description)
            }
        }
        itemStatusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            let description = item.error?.localizedDescription ?? "The audio stream could not be opened."
            Task { @MainActor [weak self] in
                guard let self, self.playbackGeneration == generation else { return }
                self.failPlayback(description)
            }
        }
    }

    private func failPlayback(_ description: String) {
        guard isPlaying else { return }
        isPlaying = false
        avPlayer?.pause()
        persistPosition()
        systemMedia?.publish()
        library?.flash(description)
    }

    /// A completed seek may arrive after a second seek or a replacement episode. Only
    /// the newest request can start playback; the initial resume starts at the requested time.
    private func seekPlayer(_ p: AVPlayer, to time: Double, generation: UInt64) {
        seekGeneration &+= 1
        seekInFlight = true
        let request = seekGeneration
        p.seek(to: CMTime(seconds: time, preferredTimescale: 600),
               toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.playbackGeneration == generation,
                      self.seekGeneration == request, self.avPlayer === p else { return }
                self.seekInFlight = false
                if self.initialSeekPending {
                    self.initialSeekPending = false
                    if self.isPlaying { p.playImmediately(atRate: Float(self.rate)) }
                }
            }
        }
    }

    private func markRecentlyPlayed(_ id: UUID, in library: Library) {
        guard let index = library.episodeIndex(id) else { return }
        library.episodes[index].lastPlayedAt = Date()
    }

    func togglePlay() {
        // Pausing the audible RSS recording must not cancel source matching.
        // A pending handoff adopts the target only if playback is still active.
        guard episodeID != nil else {
            if let first = library?.continueListening.first ?? library?.latest.first { play(first.id) }
            return
        }
        if !isPlaying, duration > 0, position >= duration - 0.25 {
            // Restarting a completed item must finish its zero seek before resuming,
            // or AVPlayer can briefly reach the previous end and advance the queue.
            completedPlaybackGeneration = nil
            initialSeekPending = true
            seek(to: 0)
        }
        isPlaying.toggle()
        lastTick = Date()
        if let p = avPlayer {
            if isPlaying && !initialSeekPending { p.playImmediately(atRate: Float(rate)) }
            else if !isPlaying { p.pause() }
        }
        if !isPlaying { persistPosition() }
        systemMedia?.publish()
    }

    func stop() {
        cancelPendingPreferredPlayback()
        scrubPreviewChapterTitle = nil
        playbackBackStack.removeAll()
        playbackForwardStack.removeAll()
        persistPosition()
        releaseCurrentItem()
        isPlaying = false
        episodeID = nil
        cinemaMode = false
        sleepRemaining = nil
        sleepAtEnd = false
        saveSession()
        systemMedia?.clear()
    }

    /// App shutdown preserves the selected episode for next launch, but releases all
    /// external playback resources and the macOS media-session ownership immediately.
    func shutdown() {
        cancelPendingPreferredPlayback()
        scrubPreviewChapterTitle = nil
        persistPosition()
        releaseCurrentItem()
        timer?.invalidate()
        timer = nil
        isPlaying = false
        systemMedia?.clear()
    }

    // MARK: Last session (restored paused on the next launch, even after a crash)

    private static let sessionKey = "lastPlaybackSession"

    /// Written whenever the position is saved (every few seconds while playing, on pause, seek and quit).
    func saveSession() {
        guard !suppressUserSessionWrites, !testMute else { return }
        if let id = episodeID {
            UserDefaults.standard.set(["episode": id.uuidString, "position": position, "rate": rate,
                                       "cinema": cinemaMode,
                                       "video": showVideo && (videoPlayer != nil ||
                                                               activeYouTubeStream != nil ||
                                                               pendingPreferredYouTube?.video == true),
                                       // Do not write expiring signed CDN URLs to user defaults.
                                       "mediaURL": activeYouTubeStream == nil
                                           ? (loadedMediaURL?.absoluteString ?? "")
                                           : "youtube-stream:\(activeYouTubeStream!.videoID)"], forKey: Self.sessionKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.sessionKey)
        }
    }

    /// Puts the last episode back in the player bar, paused at its last position.
    func restoreLastSession() {
        guard let saved = UserDefaults.standard.dictionary(forKey: Self.sessionKey),
              let idText = saved["episode"] as? String, let id = UUID(uuidString: idText),
              library?.episode(id)?.canPlay == true else { return }
        if let r = saved["rate"] as? Double { setRate(r) }
        // A saved RSS timestamp must not become a YouTube timestamp after background
        // processing changed the file while the app was closed.
        let savedURL = saved["mediaURL"] as? String
        let restoreVideo = (saved["video"] as? Bool) == true ||
                           savedURL?.hasPrefix("youtube-stream:") == true
        let sameRecording = savedURL == nil || savedURL == library?.episode(id)?.playableURL?.absoluteString
        load(id, autoplay: false, at: sameRecording ? saved["position"] as? Double : nil)
        if restoreVideo {
            // Signed stream URLs expire and are intentionally never persisted.
            // Re-resolve the verified stream instead of restoring an audio-only
            // player behind a UI that still says Video.
            playYouTubeVideo(id)
        }
    }

    // MARK: Transport (PlayerTransport: prev chapter, back 15, play/pause, forward 15, next chapter)

    func skip(by seconds: Double) { seek(to: position + seconds) }
    func skipBack() { skip(by: -Mechanics.skipBackSeconds) }
    func skipForward() { skip(by: Mechanics.skipForwardSeconds) }

    func seek(to t: Double) {
        guard episodeID != nil, t.isFinite else { return }
        position = min(max(0, t), duration > 0 ? duration : .greatestFiniteMagnitude)
        if let p = avPlayer {
            p.currentItem?.cancelPendingSeeks()
            seekPlayer(p, to: skipTimeline.sourceTime(forVisible: position), generation: playbackGeneration)
        }
        persistPositionSoon()
        systemMedia?.publish()
    }

    func nextChapter() {
        guard let i = currentChapterIndex, i + 1 < chapters.count else { library?.flash("There is no next chapter."); return }
        seek(to: chapters[i + 1].start)
    }

    func previousChapter() {
        guard let i = currentChapterIndex else { library?.flash("There is no previous chapter."); return }
        let c = chapters[i]
        if position - c.start > Mechanics.previousChapterGrace || i == 0 {
            seek(to: c.start)
        } else {
            seek(to: chapters[i - 1].start)
        }
    }

    func setRate(_ r: Double) {
        let clamped = min(Mechanics.maxSpeed, max(Mechanics.minSpeed, (r / Mechanics.speedStep).rounded() * Mechanics.speedStep))
        rate = clamped
        if isPlaying { avPlayer?.rate = Float(clamped) }
        saveSession()
        systemMedia?.publish()
    }

    func faster() { setRate(rate + 0.1) }
    func slower() { setRate(rate - 0.1) }

    // MARK: Clock

    private func tick() {
        let now = Date()
        let dt = now.timeIntervalSince(lastTick)
        lastTick = now
        if let currentID = episodeID, let lib = library, let current = lib.episode(currentID),
           metadataMatchesLoadedRecording(current) {
            // Capture each new partial ASR result before a background source
            // upgrade invalidates the old episode's clock and clears its text.
            if !current.transcript.isEmpty,
               (outgoingSourceTranscript.count != current.transcript.count ||
                outgoingSourceTranscript.last != current.transcript.last) {
                outgoingSourceTranscript = current.transcript
                outgoingVisibleTranscript = current.playbackTranscript
                outgoingVisibleChapters = current.playbackChapters
                outgoingMediaID = loadedYouTubeMediaID
            }
        }
        // A refresh or an already queued automatic download may also publish
        // a verified YouTube file without an explicit source-switch button.
        // Capture was done while the RSS clock still matched above. Now align
        // that live passage before adopting the background replacement.
        // A live verified stream intentionally has a short-lived signed URL that
        // differs from Episode.playableURL. Do not mistake that difference for a
        // newly published replacement and start a second, impossible handoff.
        if activeYouTubeStream == nil,
           pendingPreferredYouTube == nil, isPlaying, let id = episodeID,
           let e = library?.episode(id), e.youtubeMatchState == .matched,
           e.youtubeMediaID == e.youtubeID, e.youtubeID != nil,
           e.playableURL != loadedMediaURL, e.localFile != nil,
           loadedMediaURL != nil {
            pendingPreferredYouTube = (id, e.isVideo)
            preparingYouTubeEpisodeID = id
            preparingYouTubeVideo = e.isVideo
            lastTranscriptAlignmentAttempt = .distantPast
            requestMissingSourceSpeechContext()
        }
        if let pending = pendingPreferredYouTube, let lib = library {
            if let updated = lib.episode(pending.id), episodeID == pending.id {
                rememberSpokenSourceContext()
                requestMissingSourceSpeechContext()
                if pending.video {
                    if tryContextualVideoStreamHandoff(now: now) { return }
                } else if updated.youtubeMediaID == updated.youtubeID, updated.youtubeID != nil,
                   (!pending.video || updated.isVideo), updated.localFile != nil {
                    if tryContextualYouTubeHandoff(updated, requestedVideo: pending.video, now: now) { return }
                    // An untranscribed RSS source or a section absent on
                    // YouTube cannot be aligned safely. Continue playback and
                    // retry as ASR/captions or the current spoken context change.
                } else if updated.stage == .ready || updated.stage == .failed || updated.stage == .listed {
                    cancelPendingPreferredPlayback()
                    lib.flash("Verified YouTube source unavailable; continuing the current recording.")
                }
            } else {
                cancelPendingPreferredPlayback()
            }
        }
        if pendingPreferredYouTube == nil, isPlaying, let id = episodeID,
           let lib = library, let e = lib.episode(id),
           let show = lib.show(e.showID), let matchedID = e.youtubeID,
           e.youtubeMatchState == .matched, show.youtubeChannelURL != nil,
           (loadedYouTubeMediaID != matchedID || (show.youtubePlaybackVideo && videoPlayer == nil)),
           let loadedMediaURL, e.playableURL == loadedMediaURL {
            let video = show.youtubePlaybackVideo
            let key = "\(id.uuidString):\(matchedID):\(video)"
            if !sourceHandoffAttempts.contains(key) {
                beginPreferredHandoff(id, video: video, in: lib)
            }
        }
        // Processing may publish a different file while this recording is playing.
        // Keep the current AVPlayer and clock until the user explicitly selects it
        // again or starts a new session. This also preserves an in-progress RSS stream.
        refreshSkipMetadata()
        guard isPlaying, let lib = library, episodeID != nil else { return }
        if let p = avPlayer {
            if !seekInFlight {
                let t = p.currentTime().seconds
                if t.isFinite { position = skipTimeline.visibleTime(forSource: t) }
                if let d = p.currentItem?.duration.seconds, d.isFinite, d > 0,
                   abs(skipTimeline.sourceDuration - d) > 1 {
                    skipTimeline = SponsorTimeline(sourceDuration: d, cuts: observedCutMetadata)
                    duration = skipTimeline.duration
                    if let i = lib.episodeIndex(episodeID!), lib.episodes[i].playableURL == loadedMediaURL {
                        lib.episodes[i].duration = d
                    }
                    installCutBoundaryObserver()
                    systemMedia?.publish()
                }
                skipExcludedAudioIfNeeded()
            }
        } else {
            position += dt * rate
        }
        // Lifetime metrics: time listened, and time saved by playing faster than 1×.
        lib.metrics.listenedSeconds += dt
        lib.metrics.speedSavedSeconds += max(0, dt * rate - dt)
        if let left = sleepRemaining {
            if left - dt <= 0 { sleepRemaining = nil; togglePlay(); return }
            sleepRemaining = left - dt
        }
        // AVPlayerItemDidPlayToEndTime is authoritative for real audio/video.
        // Duration-based completion is retained only for synthetic/test playback.
        if avPlayer == nil, duration > 0, position >= duration - 0.25 {
            completeEpisode()
            return
        }
        saveCounter += 1
        if saveCounter % 20 == 0 { persistPosition() }
    }

    private func finish() {
        guard isPlaying, let lib = library, let id = episodeID, let i = lib.episodeIndex(id) else { return }
        isPlaying = false
        avPlayer?.pause()
        lib.episodes[i].played = true
        lib.episodes[i].position = metadataMatchesLoadedRecording(lib.episodes[i])
            ? duration : lib.episodes[i].playbackDuration
        lib.metrics.episodesFinished += 1
        saveSession()
        lib.save()
        systemMedia?.publish()
    }

    private func completeEpisode() {
        guard isPlaying, !seekInFlight, !initialSeekPending,
              completedPlaybackGeneration != playbackGeneration else { return }
        completedPlaybackGeneration = playbackGeneration
        if duration > 0 { position = duration }
        finish()
        if sleepAtEnd { sleepAtEnd = false }
        else if let next = upNext.first {
            removeFromQueue(next.id)
            play(next.id)
        }
    }

    func persistPosition() {
        deferredPositionSave?.cancel()
        deferredPositionSave = nil
        recordPosition()
        library?.save()
    }

    /// Dragging the scrubber or clicking multiple chapters should not serialize a multi-MB
    /// transcript library on every seek. The in-memory position updates immediately; a
    /// scheduled disk save is flushed synchronously on pause, switch and termination.
    private func persistPositionSoon() {
        recordPosition()
        deferredPositionSave?.cancel()
        deferredPositionSave = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(650))
            guard !Task.isCancelled, let self else { return }
            self.deferredPositionSave = nil
            self.library?.save()
        }
    }

    private func recordPosition() {
        saveSession()
        guard let lib = library, let id = episodeID, let i = lib.episodeIndex(id) else { return }
        guard metadataMatchesLoadedRecording(lib.episodes[i]) else { return }
        lib.episodes[i].position = position
        if lib.episodes[i].playableURL == loadedMediaURL, skipTimeline.sourceDuration > 0 {
            lib.episodes[i].duration = skipTimeline.sourceDuration
        }
    }
}
