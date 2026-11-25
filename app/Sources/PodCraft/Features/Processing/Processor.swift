import Foundation
import AVFoundation

/// Legacy media helper; only audio extraction for speech recognition is still required.
enum AudioCutter {
    /// Merge overlapping cuts and clamp them to the episode.
    static func merged(_ cuts: [CutSegment], duration: Double) -> [ClosedRange<Double>] {
        let ranges = cuts.compactMap { cut -> ClosedRange<Double>? in
            guard cut.start.isFinite, cut.end.isFinite, cut.end > cut.start else { return nil }
            let lower = max(0, cut.start)
            let upper = min(duration.isFinite && duration > 0 ? duration : cut.end, cut.end)
            guard upper > lower else { return nil }
            return lower...upper
        }.sorted { $0.lowerBound < $1.lowerBound }
        var out: [ClosedRange<Double>] = []
        for r in ranges {
            if let last = out.last, r.lowerBound <= last.upperBound + 0.5 {
                out[out.count - 1] = last.lowerBound...max(last.upperBound, r.upperBound)
            } else { out.append(r) }
        }
        return out
    }

    /// The sound of a video, written as .m4a so it can be transcribed.
    static func extractAudio(from source: URL, to dest: URL) async throws {
        try? FileManager.default.removeItem(at: dest)
        guard let export = AVAssetExportSession(asset: AVURLAsset(url: source), presetName: AVAssetExportPresetAppleM4A) else {
            throw NSError(domain: "PodCraft", code: 3, userInfo: [NSLocalizedDescriptionKey: "Audio export unavailable"])
        }
        try await export.export(to: dest, as: .m4a)
    }

}

/// Allows concurrent episode downloads, then serializes the more expensive
/// SponsorBlock, transcription and AI stages to avoid competing for CPU/ML resources.
/// Sample episodes (no audio) move through a simulated version in Library.processTick.
@MainActor
final class Processor {
    private weak var library: Library?
    private static let maximumConcurrentDownloads = 3
    private static let maximumProcessingBacklog = 6
    private var timer: Timer?
    private var activeTasks: [UUID: Task<Void, Never>] = [:]
    private var immediateJobs: Set<UUID> = []
    /// Explicit Play / video-icon requests are transient and per episode.
    /// A later click can replace a waiting format, but cannot start a second
    /// simultaneous transfer for the same episode.
    private var requestedMediaFormats: [UUID: Bool] = [:]
    private var runningMediaFormats: [UUID: Bool] = [:]
    /// A downloading job frees this slot as soon as its source media is committed,
    /// even if it is waiting for a different episode's transcription to finish.
    private var downloadingJobs: Set<UUID> = []
    private let processingGate = SerialProcessingGate()
    private var shuttingDown = false
    private var checkedSourceUpgradeShows: Set<UUID> = []
    private static let sourceUpgradeNote = "Checking preferred YouTube recording…"
    private static let unmatchedSourceNote = "No confirmed YouTube recording; using the RSS source."

    static var mediaFolder: URL { Library.mediaFolder }
    private let mediaDirectory: URL

    /// Media can be several gigabytes; limit stalled requests without capping an
    /// otherwise progressing download to the short metadata/feed timeout.
    private static let mediaDownloadSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 20 * 60
        return URLSession(configuration: config)
    }()

    init(library: Library, mediaDirectory: URL? = nil) {
        self.library = library
        self.mediaDirectory = mediaDirectory ?? Library.mediaFolder
        try? FileManager.default.createDirectory(at: self.mediaDirectory, withIntermediateDirectories: true)
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.startNext() }
        }
    }

    isolated deinit { timer?.invalidate() }

    /// Closing the application must stop queued work and release timer/Task ownership.
    /// Already downloaded media remains in place and an interrupted episode can resume
    /// on the next launch through its persisted processing stage.
    func shutdown() {
        shuttingDown = true
        timer?.invalidate()
        timer = nil
        for task in activeTasks.values { task.cancel() }
        activeTasks.removeAll()
        downloadingJobs.removeAll()
        requestedMediaFormats.removeAll()
        runningMediaFormats.removeAll()
    }

    /// Called when a user removes an episode or its download. The networking
    /// tasks observe cancellation and must not restore a removed media file.
    func cancel(_ id: UUID) {
        requestedMediaFormats.removeValue(forKey: id)
        activeTasks[id]?.cancel()
    }

    /// Supply a short, ephemeral speech-context sample when the already playing
    /// RSS recording has no saved transcript. This does not rewrite the episode
    /// or store its words on the new YouTube edition. It participates in the
    /// same serial ML gate as full transcription. For a remote RSS asset,
    /// AVFoundation may fetch only the needed time range using HTTP byte ranges;
    /// never download a second *entire* episode just to infer an offset.
    /// Unsupported remote formats or range servers leave playback on RSS.
    func transcribeSourceContext(from url: URL, near second: Double,
                                 language: String?,
                                 currentSourceTime: (@MainActor () -> Double)? = nil) async throws -> [TranscriptLine] {
        let scheme = url.scheme?.lowercased()
        guard !shuttingDown, second.isFinite, second >= 0,
              (url.isFileURL && FileManager.default.isReadableFile(atPath: url.path)) ||
              ((scheme == "https" || scheme == "http") && url.host != nil) else { return [] }
        var source = url
        var temporaryDownload: URL?
        defer { if let temporaryDownload { try? FileManager.default.removeItem(at: temporaryDownload) } }
        if !url.isFileURL {
            // AVAssetExportSession cannot reliably export from every HTTP RSS
            // server. A bounded *temporary* download is the last resort; it
            // never becomes an episode download and cannot replace the source.
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 25
            config.timeoutIntervalForResource = 150
            let session = URLSession(configuration: config)
            defer { session.invalidateAndCancel() }
            var head = URLRequest(url: url)
            head.httpMethod = "HEAD"
            let (_, headResponse) = try await session.data(for: head)
            guard let headHTTP = headResponse as? HTTPURLResponse,
                  (200..<300).contains(headHTTP.statusCode),
                  headHTTP.expectedContentLength > 0,
                  headHTTP.expectedContentLength <= 128 * 1_024 * 1_024 else { return [] }
            try Task.checkCancellation()
            let (downloaded, response) = try await session.download(from: url)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let size = (try? FileManager.default.attributesOfItem(atPath: downloaded.path)[.size] as? NSNumber)?.int64Value,
                  size > 0, size <= 128 * 1_024 * 1_024 else {
                try? FileManager.default.removeItem(at: downloaded)
                return []
            }
            let ext = ["mp3", "mp4", "m4a", "aac", "wav", "caf"].contains(url.pathExtension.lowercased())
                ? url.pathExtension.lowercased() : "m4a"
            let staged = FileManager.default.temporaryDirectory.appendingPathComponent(
                "podcraft-rss-context-\(UUID().uuidString).\(ext)")
            do { try FileManager.default.moveItem(at: downloaded, to: staged) }
            catch { try? FileManager.default.removeItem(at: downloaded); throw error }
            temporaryDownload = staged
            source = staged
            try Task.checkCancellation()
        }
        let asset = AVURLAsset(url: source)
        let total = try await asset.load(.duration).seconds
        guard total.isFinite, total > 0 else { return [] }
        // After fetching a remote edition, locate the *current* playhead;
        // using the original request time would be stale after a slow network.
        let freshSecond = currentSourceTime?() ?? second
        let start = min(max(0, (freshSecond.isFinite ? freshSecond : second) - 30), max(0, total - 15))
        let length = min(105, total - start)
        guard length >= 12 else { return [] }
        try await processingGate.acquire()
        defer { Task { await processingGate.release() } }
        try Task.checkCancellation()
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "podcraft-context-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let export = AVAssetExportSession(asset: asset,
                                               presetName: AVAssetExportPresetAppleM4A) else { return [] }
        export.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                       duration: CMTime(seconds: length, preferredTimescale: 600))
        // A remote podcast server can stall on a range request. Bound the
        // optional handoff probe and cancel its AVFoundation export rather than
        // retaining background work or delaying actual playback indefinitely.
        let timeout = Task {
            try? await Task.sleep(for: .seconds(45))
            if !Task.isCancelled { export.cancelExport() }
        }
        defer { timeout.cancel() }
        try await withTaskCancellationHandler {
            try await export.export(to: temporary, as: .m4a)
        } onCancel: {
            export.cancelExport()
        }
        try Task.checkCancellation()
        let recognized = try await AIService.transcribe(file: temporary,
                                                         duration: length, language: language,
                                                         progress: { _ in })
        try Task.checkCancellation()
        return recognized.map { line in
            TranscriptLine(start: start + line.start,
                           end: start + line.end, text: line.text)
        }
    }

    /// Called before explicit Play or a video-icon action. This does NOT trust a
    /// pasted ID or channel on its own: the episode must already have a matched
    /// ID for the show's *current* official channel. The processing pipeline
    /// re-verifies that exact ID on the actual watch page before committing it.
    ///
    /// True: that media representation is queued or already transferring.
    /// False: no trusted match/processor, or the requested recording is ready.
    /// The old RSS/YouTube file remains playable while the new one is acquired.
    @MainActor
    @discardableResult
    func preparePreferredYouTubePlayback(_ id: UUID, video: Bool) -> Bool {
        // A video is streamed by Player from a verified short-lived URL. Never
        // queue a full MP4 download simply because the user clicked its icon.
        if video { return false }
        guard !shuttingDown, let lib = library, let index = lib.episodeIndex(id),
              YouTubeSource.available else { return false }
        let episode = lib.episodes[index]
        guard !episode.isSample, episode.youtubeMatchState == .matched,
              let matchedID = episode.youtubeID,
              let show = lib.show(episode.showID), !show.isFiles, show.feedURL != nil,
              let linked = show.youtubeChannelURL,
              let channel = YouTubeSource.channelURL(from: linked) else { return false }
        if let matchChannel = episode.youtubeMatchChannelURL,
           YouTubeSource.channelURL(from: matchChannel) != channel { return false }
        guard matchedID.range(of: #"^[A-Za-z0-9_-]{11}$"#, options: .regularExpression) != nil else {
            return false
        }
        // An existing processing task consumes its desired format at start.
        // If the click changes format mid-flight, defer a new pass; never
        // create a fourth download or race two writers to a media filename.
        if activeTasks[id] != nil || immediateJobs.contains(id) {
            if runningMediaFormats[id] == video {
                requestedMediaFormats.removeValue(forKey: id)
            } else {
                requestedMediaFormats[id] = video
                // A format switch is explicit user intent. Stop the obsolete
                // transfer instead of waiting behind a lengthy transcription;
                // its cancellation leaves the original playable file intact.
                activeTasks[id]?.cancel()
            }
            lib.episodes[index].autoDownloaded = false
            lib.save()
            return true
        }
        if isReadyVerifiedMedia(episode, id: matchedID, video: video) {
            requestedMediaFormats.removeValue(forKey: id)
            return false
        }
        requestedMediaFormats[id] = video
        if !episode.stage.isWorking {
            lib.episodes[index].stage = .queued
            lib.episodes[index].progress = 0
            lib.episodes[index].note = "Connecting video…"
        }
        lib.episodes[index].autoDownloaded = false
        lib.save()
        startNext() // Existing three-download cap and six-item backlog apply.
        return true
    }

    private func isUsableLocalMedia(_ url: URL) -> Bool {
        guard url.isFileURL,
              let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
        else { return false }
        return size > 0
    }

    private func verifiedMediaURL(for id: UUID, youtubeID: String, video: Bool) -> URL {
        mediaDirectory.appendingPathComponent(
            "\(id.uuidString)-youtube-\(youtubeID).\(video ? "mp4" : "m4a")")
    }

    private func isReadyVerifiedMedia(_ episode: Episode, id: String, video: Bool) -> Bool {
        guard episode.stage == .ready, episode.youtubeMediaID == id,
              episode.isVideo == video,
              let current = episode.originalLocalFile ?? episode.localFile else { return false }
        let url = URL(fileURLWithPath: current)
        return url == verifiedMediaURL(for: episode.id, youtubeID: id, video: video)
            && isUsableLocalMedia(url)
    }

    /// A second format request received during an in-flight transfer gets one
    /// follow-up queue entry, only after the first job has settled.
    private func scheduleDeferredMediaRequest(_ id: UUID) {
        guard !shuttingDown, let video = requestedMediaFormats[id],
              let lib = library, let i = lib.episodeIndex(id) else {
            requestedMediaFormats.removeValue(forKey: id)
            return
        }
        let episode = lib.episodes[i]
        guard let matchedID = episode.youtubeID, episode.youtubeMatchState == .matched,
              let show = lib.show(episode.showID), let channel = show.youtubeChannelURL,
              let canonical = YouTubeSource.channelURL(from: channel),
              episode.youtubeMatchChannelURL.map({
                  YouTubeSource.channelURL(from: $0) == canonical
              }) ?? true else {
            requestedMediaFormats.removeValue(forKey: id)
            return
        }
        if isReadyVerifiedMedia(episode, id: matchedID, video: video) {
            requestedMediaFormats.removeValue(forKey: id)
            return
        }
        guard !episode.stage.isWorking else { return }
        lib.episodes[i].stage = .queued
        lib.episodes[i].progress = 0
        lib.episodes[i].note = "Connecting video…"
        lib.episodes[i].autoDownloaded = false
        lib.save()
    }

    private func startNext() {
        guard !shuttingDown, let lib = library, !lib.downloadsPaused else { return }
        // A saved channel can predate the current source preference. Check only
        // the user's newest kept episodes once per app session, never the whole
        // historical RSS library or any already-played recording.
        for show in lib.shows where !show.isFiles && show.youtubeChannelURL != nil {
            guard checkedSourceUpgradeShows.insert(show.id).inserted else { continue }
            queueRecentSourceUpgrades(showID: show.id)
        }
        for episode in lib.episodes where !episode.isSample && episode.stage.isWorking {
            // A limited backlog prevents thousands of waiting tasks for large feeds.
            let processingBacklog = activeTasks.count + immediateJobs.count - downloadingJobs.count
            guard downloadingJobs.count < Self.maximumConcurrentDownloads,
                  processingBacklog < Self.maximumProcessingBacklog else { break }
            // Manual requests may download played episodes; automated rules may not.
            guard !(episode.played && episode.autoDownloaded && episode.localFile == nil) else { continue }
            if episode.played && episode.note == Self.sourceUpgradeNote {
                if let index = lib.episodeIndex(episode.id) {
                    lib.episodes[index].stage = .ready
                    lib.episodes[index].note = nil
                    lib.save()
                }
                continue
            }
            let id = episode.id
            guard activeTasks[id] == nil, !immediateJobs.contains(id) else { continue }
            downloadingJobs.insert(id)
            activeTasks[id] = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.process(id)
                self.downloadingJobs.remove(id)
                self.activeTasks.removeValue(forKey: id)
                self.startNext()
            }
        }
    }

    private func queueRecentSourceUpgrades(showID: UUID) {
        guard let lib = library, let show = lib.show(showID),
              show.youtubeChannelURL != nil, show.keepAvailable > 0 else { return }
        let recent = lib.episodes.indices.filter { lib.episodes[$0].showID == showID }
            .sorted { lib.episodes[$0].published > lib.episodes[$1].published }
            .prefix(min(3, show.keepAvailable))
        var changed = false
        for index in recent {
            let episode = lib.episodes[index]
            guard !episode.played, episode.stage == .ready, episode.localFile != nil,
                  episode.youtubeMediaID == nil,
                  !(episode.note?.contains(Self.unmatchedSourceNote) ?? false) else { continue }
            lib.episodes[index].stage = .queued
            lib.episodes[index].note = Self.sourceUpgradeNote
            changed = true
        }
        if changed { lib.save() }
    }

    /// "Process Again": run an episode through the pipeline once more.
    func reprocess(_ id: UUID) {
        guard let lib = library, let i = lib.episodeIndex(id) else { return }
        lib.episodes[i].stage = .queued
        lib.episodes[i].progress = 0
        lib.episodes[i].note = nil
    }

    /// Runs one queued episode immediately. This is used by the deterministic
    /// processing check so it exercises the same pipeline as the app.
    func processImmediately(_ id: UUID) async {
        guard !shuttingDown, activeTasks[id] == nil,
              downloadingJobs.count < Self.maximumConcurrentDownloads,
              immediateJobs.insert(id).inserted else { return }
        downloadingJobs.insert(id)
        defer { downloadingJobs.remove(id); immediateJobs.remove(id); startNext() }
        await process(id)
    }

    /// The language to transcribe in: the episode's tag, the show's tag (read from its feed once if it isn't
    /// known yet), or detected from the episode's text. Nil falls back to this Mac's language.
    private func transcriptLanguage(for id: UUID) async -> String? {
        guard let lib = library, let e = lib.episode(id) else { return nil }
        if let l = e.language, !l.isEmpty { return l }
        if let s = lib.show(e.showID), (s.language ?? "").isEmpty, let link = s.feedURL, let url = URL(string: link),
           let parsed = try? await FeedFetcher.fetch(url), let l = parsed.language, !l.isEmpty,
           let i = lib.showIndex(s.id) {
            lib.shows[i].language = l
            lib.save()
        }
        return lib.expectedLanguage(for: e)
    }

    private func update(_ id: UUID, _ change: (inout Episode) -> Void) {
        guard let lib = library, let i = lib.episodeIndex(id) else { return }
        change(&lib.episodes[i])
    }

    /// An await may let the user remove/cancel the episode. Do not publish a
    /// late network result into a deleted or no-longer-queued library entry.
    private func ensureCurrent(_ id: UUID) throws {
        try Task.checkCancellation()
        guard let lib = library, let episode = lib.episode(id), episode.stage.isWorking else {
            throw CancellationError()
        }
    }

    private func process(_ id: UUID) async {
        guard let lib = library, let start = lib.episode(id) else { return }
        let settings = lib.settings
        let requestedVideo = requestedMediaFormats.removeValue(forKey: id)
        // The show-level Video preference now controls streaming at Play time,
        // not background storage. Offline processing acquires audio only.
        let targetVideo = false
        _ = requestedVideo
        runningMediaFormats[id] = targetVideo
        defer {
            runningMediaFormats.removeValue(forKey: id)
            scheduleDeferredMediaRequest(id)
        }
        do {
            try ensureCurrent(id)
            // 1. Prefer the verified upload from this show's linked YouTube channel.
            // Title-only matches from arbitrary YouTube search results are never trusted:
            // YouTubeSource checks channel identity, title, duration and publication.
            // Keep any prior RSS recording; on failure, fall back without applying the
            // YouTube video's SponsorBlock timestamps to the RSS audio.
            update(id) { $0.stage = .downloading; $0.progress = 0.05 }
            var selected: URL?
            var youtubeMediaID: String?
            var noVerifiedYouTubeMatch = false
            var selectedVideo = start.isVideo
            var rssBackup = start.rssBackupLocalFile
            var verifiedYouTubeDuration: Double?
            // Only chapters from a verified upload can describe the YouTube media clock.
            // A feed chapter list must never be carried over to a different recording.
            var verifiedYouTubeChapters: [Chapter] = []
            if let show = lib.show(start.showID), !show.isFiles, show.feedURL != nil,
               YouTubeSource.available {
                update(id) { $0.note = "Finding the official YouTube source…" }
                do {
                    let channel: String?
                    if let saved = show.youtubeChannelURL, !saved.isEmpty {
                        channel = saved
                    } else if let discovered = try await YouTubeSource.discoverChannel(show: show) {
                        try ensureCurrent(id)
                        channel = discovered.channelURL.absoluteString
                        // Discovery already requires a unique official-channel identity
                        // and at least two independent RSS↔upload matches. Retain that
                        // verified show association even when this particular RSS entry
                        // has no corresponding YouTube upload and must stay on the feed.
                        if let k = lib.showIndex(show.id), lib.shows[k].youtubeChannelURL == nil {
                            lib.shows[k].youtubeChannelURL = discovered.channelURL.absoluteString
                            queueRecentSourceUpgrades(showID: show.id)
                        }
                    } else {
                        channel = nil
                    }
                    if let channel,
                       let match = try await YouTubeSource.match(episode: start, channelURL: channel),
                       // Never substitute a different title match once this
                       // episode already has a channel-verified YouTube ID.
                       (start.youtubeMatchState != .matched || match.id == start.youtubeID),
                       (requestedVideo == nil ||
                        (start.youtubeMatchState == .matched &&
                         start.youtubeMatchChannelURL.map {
                             YouTubeSource.channelURL(from: $0) == YouTubeSource.channelURL(from: channel)
                         } ?? true)) {
                        try ensureCurrent(id)
                        guard lib.show(show.id)?.youtubeChannelURL == show.youtubeChannelURL else {
                            throw YouTubeSource.Failure.verificationFailed
                        }
                        let expectedFile = verifiedMediaURL(for: id, youtubeID: match.id, video: targetVideo)
                        if isUsableLocalMedia(expectedFile) {
                            // Reuse a previously verified audio/video representation
                            // without downloading the 50+ minute episode again.
                            selected = expectedFile
                        } else {
                            update(id) { $0.note = targetVideo ? "Downloading matched YouTube video…" : "Preparing matched YouTube audio…" }
                            let existedBefore = FileManager.default.fileExists(atPath: expectedFile.path)
                            do {
                                // Derive audio locally from an existing verified MP4
                                // before spending data on another full YouTube download.
                                let videoFile = verifiedMediaURL(for: id, youtubeID: match.id, video: true)
                                if !targetVideo && isUsableLocalMedia(videoFile) {
                                    let temporary = mediaDirectory.appendingPathComponent(
                                        ".\(id.uuidString)-youtube-\(match.id)-\(UUID().uuidString).m4a")
                                    defer { try? FileManager.default.removeItem(at: temporary) }
                                    do {
                                        try await AudioCutter.extractAudio(from: videoFile, to: temporary)
                                        try ensureCurrent(id)
                                        guard isUsableLocalMedia(temporary) else {
                                            throw YouTubeSource.Failure.downloadFailed("Local AAC extraction produced no audio.")
                                        }
                                        if !FileManager.default.fileExists(atPath: expectedFile.path) {
                                            try FileManager.default.moveItem(at: temporary, to: expectedFile)
                                        }
                                        guard isUsableLocalMedia(expectedFile) else {
                                            throw YouTubeSource.Failure.downloadFailed("Cached YouTube audio is empty.")
                                        }
                                        selected = expectedFile
                                    } catch is CancellationError { throw CancellationError() }
                                    catch {
                                        // AVFoundation export may be unavailable for
                                        // a particular MP4; yt-dlp remains the fallback.
                                        selected = try await YouTubeSource.download(
                                            videoID: match.id, video: false,
                                            destinationFolder: mediaDirectory, episodeID: id)
                                    }
                                } else {
                                    selected = try await YouTubeSource.download(
                                        videoID: match.id, video: targetVideo,
                                        destinationFolder: mediaDirectory, episodeID: id)
                                }
                                try ensureCurrent(id)
                            } catch {
                                // If the user removed an in-flight download before
                                // yt-dlp finished moving it, remove only this new file.
                                if !existedBefore && (Task.isCancelled || lib.episode(id)?.stage.isWorking != true) {
                                    try? FileManager.default.removeItem(at: expectedFile)
                                }
                                throw error
                            }
                        }
                        if start.youtubeMediaID == nil,
                           let old = start.originalLocalFile ?? start.localFile,
                           FileManager.default.isReadableFile(atPath: old) {
                            rssBackup = old
                        }
                        youtubeMediaID = match.id
                        selectedVideo = targetVideo
                        verifiedYouTubeDuration = match.duration
                        verifiedYouTubeChapters = match.chapters.map {
                            Chapter(start: $0.start, title: $0.title)
                        }
                    } else if channel != nil {
                        noVerifiedYouTubeMatch = true
                        update(id) { $0.note = Self.unmatchedSourceNote }
                    }
                } catch is CancellationError { throw CancellationError() }
                catch {
                    let detail = error.localizedDescription
                    let localToolFailure = detail.localizedCaseInsensitiveContains("ffmpeg") ||
                        detail.localizedCaseInsensitiveContains("ffprobe")
                    update(id) {
                        $0.note = (localToolFailure
                            ? "YouTube processing needs FFmpeg; using the podcast feed. "
                            : "Verified YouTube recording could not be downloaded; using the podcast feed. ") + detail
                    }
                }
            }
            if selected == nil {
                // A previously verified YouTube recording is still a valid, aligned
                // source during a temporary network/discovery outage. Do not replace
                // it with a differently timed RSS file merely because yt-dlp failed.
                if let recordedVideoID = start.youtubeMediaID,
                   let local = start.originalLocalFile ?? start.localFile,
                   URL(fileURLWithPath: local).deletingPathExtension().lastPathComponent
                       .hasSuffix("-youtube-\(recordedVideoID)"),
                   FileManager.default.isReadableFile(atPath: local) {
                    selected = URL(fileURLWithPath: local)
                    youtubeMediaID = recordedVideoID
                    selectedVideo = ["mp4", "m4v", "mov"].contains(selected?.pathExtension.lowercased() ?? "")
                } else if start.youtubeMediaID == nil,
                   let local = start.originalLocalFile ?? start.localFile,
                   FileManager.default.isReadableFile(atPath: local) {
                    selected = URL(fileURLWithPath: local)
                } else if let rssBackup, FileManager.default.isReadableFile(atPath: rssBackup) {
                    selected = URL(fileURLWithPath: rssBackup)
                } else if let s = start.audioURL, let url = URL(string: s) {
                    if url.isFileURL { selected = url } else {
                    let (tmp, response) = try await Self.mediaDownloadSession.download(from: url)
                    if let http = response as? HTTPURLResponse,
                       !(200..<300).contains(http.statusCode) {
                        throw NSError(domain: "PodCraft.HTTP", code: http.statusCode,
                                      userInfo: [NSLocalizedDescriptionKey: "Episode download failed (HTTP \(http.statusCode))."])
                    }
                    try ensureCurrent(id)
                    let ext = url.pathExtension.isEmpty ? "mp3" : url.pathExtension
                    let dest = mediaDirectory.appendingPathComponent("\(id.uuidString).\(ext)")
                    if !FileManager.default.fileExists(atPath: dest.path) {
                        try FileManager.default.moveItem(at: tmp, to: dest)
                    } else {
                        try? FileManager.default.removeItem(at: tmp)
                        let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? NSNumber)?.int64Value ?? 0
                        guard size > 0 else {
                            throw NSError(domain: "PodCraft.Source", code: 2,
                                          userInfo: [NSLocalizedDescriptionKey: "An existing episode download is empty; it was left unchanged."])
                        }
                    }
                    selected = dest
                    }
                }
                selectedVideo = start.youtubeMediaID == nil ? start.isVideo :
                    ["mp4", "m4v", "mov"].contains(selected?.pathExtension.lowercased() ?? "")
            }
            guard let file = selected else {
                throw NSError(domain: "PodCraft.Source", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "No playable recording found on YouTube or in the podcast feed."])
            }
            let measuredDuration = try? await AVURLAsset(url: file).load(.duration).seconds
            let duration = measuredDuration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
                ?? verifiedYouTubeDuration ?? start.duration
            try ensureCurrent(id)
            let previousFile = start.originalLocalFile ?? start.localFile
            // M4A and MP4 are representations of the SAME verified YouTube
            // recording and share source timestamps. Do not erase transcript,
            // virtual sponsor cuts, chapters or listening position when the
            // user switches between audio and video. RSS↔YouTube is different.
            let sameYouTubeRecording = youtubeMediaID != nil && youtubeMediaID == start.youtubeMediaID
            let sameYouTubeClock = sameYouTubeRecording &&
                (!duration.isFinite || !start.duration.isFinite ||
                 abs(duration - start.duration) <= 2.0)
            let sameRecordingNewRepresentation = sameYouTubeClock &&
                (selectedVideo != start.isVideo || (previousFile != nil && previousFile != file.path))
            let sourceClockChanged = youtubeMediaID != start.youtubeMediaID ||
                (!sameYouTubeClock && (selectedVideo != start.isVideo ||
                                       (previousFile != nil && previousFile != file.path)))
            let legacyPhysicalCut = start.cutApplied && start.originalLocalFile == nil &&
                youtubeMediaID == nil && file.deletingPathExtension().lastPathComponent.hasSuffix("-cut")
            update(id) {
                if sourceClockChanged {
                    // A podcast RSS file and a YouTube upload rarely have identical lengths.
                    // Their chapter/transcript/cut coordinates cannot be interchanged.
                    $0.transcript = []
                    $0.chapters = []
                    $0.cuts = []
                    $0.analysisFingerprint = nil
                    $0.transcriptLanguage = nil
                    $0.position = 0
                    $0.adSecondsRemoved = 0
                }
                if youtubeMediaID != nil && !verifiedYouTubeChapters.isEmpty {
                    // Native YouTube chapters were read from this exact, channel-verified
                    // recording. Keep their uncompressed source timestamps for cut editing.
                    $0.chapters = verifiedYouTubeChapters.filter {
                        $0.start >= 0 && $0.start < duration + 0.01
                    }
                }
                $0.localFile = file.path
                $0.originalLocalFile = legacyPhysicalCut ? nil : file.path
                $0.rssBackupLocalFile = rssBackup
                $0.youtubeMediaID = youtubeMediaID
                if let youtubeMediaID { $0.youtubeID = youtubeMediaID }
                $0.isVideo = selectedVideo
                $0.cutApplied = legacyPhysicalCut
                $0.duration = duration.isFinite && duration > 0 ? duration : $0.duration
                $0.progress = 1
            }
            // Downloaded files and verified source identity survive an interruption;
            // the queued heavy phase can safely resume after relaunch.
            lib.save()

            // Start another transfer immediately; this episode now occupies only
            // a bounded processing backlog slot, independent of the download cap.
            downloadingJobs.remove(id)
            startNext()

            // All downloading jobs can run together. Only one episode at a time
            // proceeds to SponsorBlock, local transcription and chapter analysis.
            try await processingGate.acquire()
            defer { Task { await processingGate.release() } }
            try ensureCurrent(id)

            // 2. SponsorBlock community segments (YouTube episodes).
            var cuts: [CutSegment] = sourceClockChanged ? [] :
                (sameRecordingNewRepresentation ? (lib.episode(id)?.cuts ?? []) :
                    (lib.episode(id)?.cuts ?? []).filter { $0.source == "Manual" })
            if !sameRecordingNewRepresentation, settings.removeSponsors && settings.useSponsorBlock,
               let yt = youtubeMediaID, yt == lib.episode(id)?.youtubeID {
                update(id) { $0.stage = .cuttingSponsors; $0.progress = 0.3 }
                if let segs = try? await SponsorBlock.segments(videoID: yt, categories: settings.sponsorCategories) {
                    try ensureCurrent(id)
                    cuts += segs
                }
            }

            // 3. Prefer YouTube's source-timed captions for the exact official
            // upload actually selected as media; unavailable/invalid captions
            // fall back to on-device ASR. Never align a YouTube transcript to
            // a separate RSS recording with possible regional ad inserts.
            var lines = lib.episode(id)?.transcript ?? []
            if settings.transcribe || settings.generateChapters, lines.isEmpty {
                update(id) { $0.stage = .transcribing; $0.progress = 0 }
                do {
                    let language = await transcriptLanguage(for: id)
                    try ensureCurrent(id)
                    var captions: [TranscriptLine]?
                    if let verifiedID = youtubeMediaID,
                       verifiedID == lib.episode(id)?.youtubeMediaID,
                       let linkedChannel = lib.show(start.showID)?.youtubeChannelURL,
                       !linkedChannel.isEmpty {
                        update(id) {
                            $0.progress = 0.08
                            $0.note = "Checking verified YouTube captions…"
                        }
                        do {
                            captions = try await YouTubeSource.captions(
                                episode: start, channelURL: linkedChannel, videoID: verifiedID,
                                language: language, duration: duration)
                        } catch is CancellationError { throw CancellationError() }
                        catch { /* Subtitle fetch is optional; the local ASR is authoritative fallback. */ }
                        try ensureCurrent(id)
                    }
                    if let captions, !captions.isEmpty {
                        lines = captions
                        update(id) { $0.progress = 1; $0.note = "Verified YouTube captions loaded" }
                    } else {
                        var audioFile = file
                        if lib.episode(id)?.isVideo ?? false {
                            audioFile = mediaDirectory.appendingPathComponent("\(id.uuidString)-sound.m4a")
                            try await AudioCutter.extractAudio(from: file, to: audioFile)
                        }
                        defer { if audioFile != file { try? FileManager.default.removeItem(at: audioFile) } }
                        if let language {
                            let name = Locale.current.localizedString(forLanguageCode: language) ?? language
                            update(id) { $0.note = "Transcribing in \(name) on this Mac…" }
                        }
                        lines = try await AIService.transcribe(file: audioFile, duration: duration,
                                                               language: language, partialTranscript: { partial in
                            Task { @MainActor in
                                guard let current = self.library?.episode(id),
                                      current.stage == .transcribing,
                                      current.originalLocalFile == file.path else { return }
                                // A delayed collector callback may arrive after a newer one.
                                // Never regress visible text or overwrite a finished transcript.
                                if (partial.last?.end ?? 0) + 0.01 < (current.transcript.last?.end ?? 0) { return }
                                self.update(id) { $0.transcript = partial }
                            }
                        }, progress: { p in
                            Task { @MainActor in
                                // Whole-percent steps only, so the window isn't redrawn for every recognised phrase.
                                guard let current = self.library?.episode(id), current.stage == .transcribing,
                                      Int(p * 100) != Int(current.progress * 100) else { return }
                                self.update(id) { $0.progress = p }
                            }
                        })
                    }
                    try ensureCurrent(id)
                    update(id) {
                        $0.transcript = lines
                        $0.transcriptLanguage = language ?? Locale.current.identifier
                        $0.note = nil
                    }
                    // Do not make the currently playing episode wait for the
                    // optional AI chapter pass. Its media and captions now use
                    // the same verified source clock and are ready for handoff.
                    lib.save()
                    lib.onEpisodePlaybackPrepared?(id)
                } catch is CancellationError { throw CancellationError() }
                catch {
                    update(id) { $0.note = "Transcript unavailable: \(error.localizedDescription)" }
                }
            }

            // 4. AI chapters and sponsor finding.
            // A verified YouTube upload already supplies source-timed chapters,
            // and SponsorBlock supplies its cuts. Running the full transcript AI
            // pass cannot improve those chapters and used to delay playback for minutes.
            let needsTranscriptAnalysis = verifiedYouTubeChapters.isEmpty ||
                (settings.removeSponsors && !settings.useSponsorBlock)
            if !sameRecordingNewRepresentation, needsTranscriptAnalysis, settings.generateChapters,
               settings.aiProvider != .off, !lines.isEmpty {
                // Only true legacy exports without an original recording cannot be mapped
                // to source timestamps. Migrated episodes use the recovered original file.
                let findSponsors = settings.removeSponsors && !legacyPhysicalCut
                let fingerprint = AIService.fingerprint(lines: lines, duration: duration, provider: settings.aiProvider,
                                                        findSponsors: findSponsors)
                if lib.episode(id)?.analysisFingerprint == fingerprint {
                    cuts += (lib.episode(id)?.cuts ?? []).filter { $0.source == "AI" || $0.source == "Transcript evidence" }
                } else {
                    update(id) { $0.stage = .chaptering; $0.progress = 0.02; $0.note = "Reading transcript…" }
                    do {
                        let found = try await AIService.chapters(lines: lines, duration: duration, provider: settings.aiProvider,
                                                                 model: settings.geminiModel, findSponsors: findSponsors) { p in
                            Task { @MainActor in
                                guard self.library?.episode(id)?.stage == .chaptering else { return }
                                self.update(id) {
                                    $0.progress = max(0.02, min(0.98, p))
                                    $0.note = "Analyzing transcript…"
                                }
                            }
                        }
                        try ensureCurrent(id)
                        update(id) {
                            // The model may still detect sponsors, but it must not replace
                            // source-native chapter boundaries from a verified YouTube video.
                            if verifiedYouTubeChapters.isEmpty && !found.chapters.isEmpty {
                                $0.chapters = found.chapters
                            }
                            $0.analysisFingerprint = fingerprint
                            $0.note = nil
                        }
                        cuts += found.sponsors
                    } catch is CancellationError { throw CancellationError() }
                    catch {
                        update(id) { $0.note = error.localizedDescription }
                    }
                }
            }

            // 4b. Chapters whose titles contain the show's "cut chapters" words are cut as well.
            if !sameRecordingNewRepresentation, let s = lib.show(start.showID),
               !Show.terms(s.excludedChapterTerms).isEmpty, let chs = lib.episode(id)?.chapters {
                let sorted = chs.sorted { $0.start < $1.start }
                for (k, c) in sorted.enumerated() where s.cutsChapter(c.title) {
                    let end = k + 1 < sorted.count ? sorted[k + 1].start : duration
                    if end > c.start { cuts.append(CutSegment(start: c.start, end: end, category: "chapter filter", source: "Filter")) }
                }
            }

            // 5. Never export, truncate or replace the recording. Chapters and transcript
            // retain their ORIGINAL timestamps for future precise sponsor-cut editing.
            // PlaybackTimeline removes these ranges from the *displayed* time axis and
            // AVPlayer seeks across them at their original boundaries.
            let timeline = SponsorTimeline(sourceDuration: duration, cuts: cuts)
            update(id) { e in
                e.cuts = cuts
                e.adSecondsRemoved = max(0, duration - timeline.duration)
                e.cutApplied = legacyPhysicalCut
                e.localFile = file.path
                e.originalLocalFile = legacyPhysicalCut ? nil : file.path
            }
            try ensureCurrent(id)
            update(id) {
                $0.stage = .ready
                $0.progress = 1
                if noVerifiedYouTubeMatch {
                    // Transcription and AI can clear or replace the progress
                    // note. Retain this provenance so relaunches do not queue
                    // the same unsupported YouTube replacement repeatedly.
                    if let existing = $0.note, !existing.isEmpty,
                       !existing.contains(Self.unmatchedSourceNote) {
                        $0.note = "\(existing) \(Self.unmatchedSourceNote)"
                    } else {
                        $0.note = Self.unmatchedSourceNote
                    }
                } else if youtubeMediaID != nil {
                    $0.note = nil
                }
            }
            lib.metrics.episodesProcessed += 1
            lib.save()
            lib.onEpisodeReady?(id)
        } catch is CancellationError {
            if let current = lib.episode(id), current.stage.isWorking {
                update(id) { $0.stage = .queued; $0.note = nil; $0.progress = 0 }
                lib.save()
            }
        } catch {
            if Task.isCancelled {
                if let current = lib.episode(id), current.stage.isWorking {
                    update(id) { $0.stage = .queued; $0.note = nil; $0.progress = 0 }
                    lib.save()
                }
                return
            }
            if let current = lib.episode(id), current.stage.isWorking {
                // An explicit source upgrade must never strand a playable RSS
                // or previously verified recording in Failed when analysis
                // errors after downloading or restoring its media.
                update(id) {
                    $0.stage = current.playableURL == nil ? .failed : .ready
                    $0.note = error.localizedDescription
                }
                lib.save()
            }
        }
    }
}

/// FIFO gate for the stages that use local speech recognition and AI. A cancelled
/// waiter still receives its turn and immediately exits at Task.checkCancellation,
/// releasing the gate for the following episode.
private actor SerialProcessingGate {
    private var occupied = false
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }
    private var waiting: [Waiter] = []

    func acquire() async throws {
        try Task.checkCancellation()
        if !occupied { occupied = true; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { waiting.append(Waiter(id: id, continuation: continuation)) }
            }
        } onCancel: {
            Task { await self.cancelWaiting(id) }
        }
    }

    private func cancelWaiting(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    func release() {
        if waiting.isEmpty {
            occupied = false
        } else {
            waiting.removeFirst().continuation.resume()
        }
    }
}
