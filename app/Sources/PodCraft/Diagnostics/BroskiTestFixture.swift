import Foundation
import AppKit
import AVFoundation

/// Opt-in, real-network integration fixture for The Broski Report. Unlike the
/// normal PodCraft app, every Library save and downloaded media file is rooted
/// in the project's .build/BroskiTest folder. Nothing here is used by a normal
/// launch. It deliberately exercises FeedFetcher, Library, YouTubeSource,
/// Processor and Player instead of fabricating an episode or thumbnail.
@MainActor
final class BroskiTestFixture {
    static let current: BroskiTestFixture? = CommandLine.arguments.contains("--broski-test-show")
        ? BroskiTestFixture() : nil

    private static let rss = URL(string: "https://audioboom.com/channels/5103827.rss")!
    private static let officialChannelID = "UCdEwstTO8WsTHCyzrCSfXCQ"
    private static let expectedVideoID = "BaliszUp8hg"

    let root: URL
    let storage: URL
    let media: URL
    let preferences: UserDefaults
    let metadataOnly = CommandLine.arguments.contains("--broski-test-metadata-only")
    let transcribe = CommandLine.arguments.contains("--broski-test-transcribe")

    private init() {
        // #filePath points at the source directory even when the built app is
        // launched from Finder or an unrelated working directory.
        let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        if CommandLine.arguments.contains("--broski-test-disposable") {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "podcraft-broski-qa-\(UUID().uuidString)", isDirectory: true)
        } else {
            root = sourceRoot.appendingPathComponent(".build/BroskiTest", isDirectory: true)
        }
        storage = root.appendingPathComponent("Library.json")
        media = root.appendingPathComponent("Media", isDirectory: true)
        preferences = UserDefaults(suiteName: "com.podcraft.qa.broski-test")!
        do {
            try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        } catch {
            fatalError("Could not create isolated Broski media directory: \(error)")
        }
        precondition(storage.standardizedFileURL != Library.storeURL.standardizedFileURL)
        precondition(!media.path.hasPrefix(Library.supportFolder.path))
    }

    func configure(_ library: Library) {
        library.downloadsPaused = true // only the selected #143 is processed by this harness
        library.settings.defaultAvailable = 0
        library.settings.transcribe = false
        library.settings.generateChapters = false // preserve native YouTube chapters
        library.settings.removeSponsors = false
        library.settings.useSponsorBlock = false
        library.settings.aiProvider = .off
        library.settings.hostingEnabled = false
        library.save()
    }

    private func note(_ message: String) {
        print("BROSKI TEST \(message)")
        fflush(stdout)
    }

    private func fail(_ reason: String, screenshot: Bool) {
        note("FAILED \(reason)")
        if screenshot { exit(1) }
    }

    /// Called after the actual RootView / NSWindow have been installed. No fake
    /// rows: the visible show, thumbnails and player are the same native views
    /// used in an ordinary library. Screenshot capture waits for verification.
    func populate(library: Library, processor: Processor, player: Player,
                  screenshotPath: String?, capture: @escaping @MainActor () -> Void) async {
        let shouldExit = screenshotPath != nil
        note("START root=\(root.path) library=\(storage.path) media=\(media.path) persistentProduction=false")
        do {
            let showID: UUID
            if let existing = library.shows.first(where: { $0.feedURL == Self.rss.absoluteString }) {
                showID = existing.id
                note("REUSED saved isolated show=\(existing.title) episodes=\(library.episodes(inShow: showID).count)")
            } else {
                let feed = try await FeedFetcher.fetch(Self.rss)
                var latest = Array(feed.items.sorted { $0.published > $1.published }.prefix(8))
                guard let episode143 = feed.items.first(where: { $0.title.hasPrefix("143:") }) else {
                    throw TestError.missing("The real RSS feed no longer provides episode 143")
                }
                if !latest.contains(where: { $0.title == episode143.title }) { latest.append(episode143) }
                var show = Show(title: feed.title, author: feed.author,
                                feedURL: Self.rss.absoluteString, artworkURL: feed.artwork,
                                hue: 0.57, summary: feed.summary, keepAvailable: 0)
                show.language = feed.language
                showID = library.addShow(show, items: latest)
                note("ADDED via Library.addShow RSS=\(Self.rss.absoluteString) realEpisodes=\(latest.count) title=\(feed.title)")
            }
            guard let episodeID = library.episodes(inShow: showID)
                .first(where: { $0.title.hasPrefix("143:") })?.id else {
                throw TestError.missing("Episode 143 not found in the isolated test library")
            }
            library.setMode(.listen)
            library.listenSelection = .show(showID)
            library.ensureYouTubeArtwork(forShow: showID)
            library.ensureYouTubeArtwork(forEpisode: episodeID)

            // Discovery is asynchronous and can include two yt-dlp network
            // subprocesses. Poll observed production metadata; do not freeze
            // the SwiftUI main thread or replace it with a hardcoded video ID.
            var artwork: String?
            for second in 0..<180 {
                try Task.checkCancellation()
                if let show = library.show(showID),
                   let channel = show.youtubeChannelURL,
                   channel.contains(Self.officialChannelID),
                   let episode = library.episode(episodeID),
                   episode.youtubeID == Self.expectedVideoID,
                   let remote = episode.artworkURL,
                   remote.contains("/vi/\(Self.expectedVideoID)/") ||
                   remote.contains("/vi_webp/\(Self.expectedVideoID)/"),
                   ArtworkStore.cachedFile(for: remote) != nil {
                    artwork = remote
                    note("ARTWORK PASSED officialChannel=\(Self.officialChannelID) episode=\(episode.title) verifiedVideo=\(episode.youtubeID ?? "-") url=\(remote) cached=true seconds=\(second)")
                    break
                }
                if second > 0 && second.isMultiple(of: 20) {
                    note("ARTWORK WAIT seconds=\(second) channel=\(library.show(showID)?.youtubeChannelURL ?? "discovering") episodeVideo=\(library.episode(episodeID)?.youtubeID ?? "pending")")
                }
                try await Task.sleep(for: .seconds(1))
            }
            guard artwork != nil else {
                throw TestError.missing("Timed out before verified official YouTube artwork for #143")
            }
            guard let show = library.show(showID), let channel = show.youtubeChannelURL,
                  let rssEpisode = library.episode(episodeID),
                  let verified = try await YouTubeSource.match(episode: rssEpisode, channelURL: channel),
                  verified.id == Self.expectedVideoID,
                  verified.channelID == Self.officialChannelID,
                  verified.thumbnailURL == artwork,
                  verified.chapters.count == 11 else {
                throw TestError.missing("A live, exact channel+episode+thumbnail verification failed")
            }
            note("FETCHER PASSED channel=\(verified.channelID) video=\(verified.id) rssDuration=\(Int(rssEpisode.duration))s youtubeDuration=\(Int(verified.duration))s")
            note("CHAPTERS VERIFIED source=YouTube count=\(verified.chapters.count) first=\(verified.chapters.first?.title ?? "none") timestamps=original")

            if metadataOnly {
                note("METADATA ONLY no media download, native episode list + verified thumbnails visible")
            } else {
                let savedTranscript = rssEpisode.transcript
                let savedCuts = rssEpisode.cuts
                if await hasVerifiedReadyMedia(episode: rssEpisode, verified: verified) {
                    // Reopening the UI must NOT force an audio→video source swap:
                    // Processor intentionally clears source-aligned transcript,
                    // chapters and cuts whenever the recording changes.
                    note("MEDIA CACHE REUSED verifiedVideo=\(verified.id) audio=M4A video=MP4 chapters=\(rssEpisode.chapters.count) transcriptLines=\(savedTranscript.count) cuts=\(savedCuts.count) sourceUnchanged=true")
                } else {
                    // A previously analysed episode may not be reprocessed just
                    // because an auxiliary cache was deleted. Preserve the only
                    // existing transcript/cuts rather than silently erasing them.
                    guard savedTranscript.isEmpty && savedCuts.isEmpty else {
                        throw TestError.missing("Verified cached media incomplete; refusing destructive source replacement of existing transcript/cuts")
                    }
                    // Fresh or incomplete unanalysed fixtures still exercise the
                    // actual production audio and video downloader/Processor.
                    try await mediaPass(episodeID: episodeID, showID: showID, video: false,
                                        library: library, processor: processor, player: player,
                                        verified: verified)
                    try await mediaPass(episodeID: episodeID, showID: showID, video: true,
                                        library: library, processor: processor, player: player,
                                        verified: verified)
                }
                player.load(episodeID, autoplay: false)
                let item = player.videoPlayer?.currentItem
                for _ in 0..<32 where item?.status == .unknown {
                    try await Task.sleep(for: .milliseconds(125))
                }
                guard let item, item.status == .readyToPlay,
                      item.asset is AVURLAsset, player.episodeID == episodeID else {
                    throw TestError.missing("Native Player did not reach video readyToPlay")
                }
                guard player.chapters.count == 11,
                      verified.chapters.count > 1,
                      abs(verified.chapters[1].start - 163) < 1 else {
                    throw TestError.missing("Player's chapter presentation is not the 11 verified YouTube chapters")
                }
                player.seek(to: verified.chapters[1].start)
                var actualSeek = player.videoPlayer?.currentTime().seconds ?? 0
                for _ in 0..<30 where !actualSeek.isFinite || abs(actualSeek - 163) > 2 {
                    try await Task.sleep(for: .milliseconds(125))
                    actualSeek = player.videoPlayer?.currentTime().seconds ?? 0
                }
                guard actualSeek.isFinite && abs(actualSeek - 163) <= 2 else {
                    throw TestError.missing("Native video seek did not reach the 163s YouTube chapter")
                }
                player.togglePlay()
                try await Task.sleep(for: .milliseconds(1300))
                let advancedTo = player.videoPlayer?.currentTime().seconds ?? 0
                if player.isPlaying { player.togglePlay() }
                guard advancedTo.isFinite && advancedTo >= actualSeek + 0.15 else {
                    throw TestError.missing("Native video AVPlayer did not advance during playback")
                }
                player.showQueue = false
                player.showChapters = true
                note(String(format: "PLAYER PASSED nativeVideo=true readyToPlay=true chapters=%d seek=%.1fs playbackAdvanced=%.1fs showChapters=true audioSource=verifiedYouTube",
                            player.chapters.count, actualSeek, advancedTo - actualSeek))

                if transcribe, let existing = library.episode(episodeID), !existing.transcript.isEmpty {
                    note("ASR REUSED existing transcriptLines=\(existing.transcript.count) language=\(existing.transcriptLanguage ?? "unknown") source=YouTube-video captionsFetched=false")
                } else if transcribe {
                    note("ASR START file=YouTube-MP4 engine=Apple-SpeechAnalyzer captionsFetched=false (native YouTube captions are not part of this production pipeline)")
                    library.settings.transcribe = true
                    library.settings.aiProvider = .onDevice
                    if let index = library.episodeIndex(episodeID) {
                        library.episodes[index].stage = .queued
                        library.save()
                    }
                    await processor.processImmediately(episodeID)
                    guard let result = library.episode(episodeID), !result.transcript.isEmpty else {
                        throw TestError.missing("On-device ASR generated no transcript; \(library.episode(episodeID)?.note ?? "unknown")")
                    }
                    note("ASR PASSED source=YouTube-video transcriptLines=\(result.transcript.count) language=\(result.transcriptLanguage ?? "unknown") nativeChaptersPreserved=\(result.chapters.count == verified.chapters.count)")
                } else {
                    note("ASR NOT RUN existingTranscriptLines=\(library.episode(episodeID)?.transcript.count ?? 0); opt in with --broski-test-transcribe if missing (on-device ASR, not fetched captions)")
                }
                if !savedTranscript.isEmpty || !savedCuts.isEmpty {
                    guard let after = library.episode(episodeID),
                          after.transcript == savedTranscript, after.cuts == savedCuts else {
                        throw TestError.missing("Reopening changed the existing source-aligned transcript or cuts")
                    }
                    note("ANALYSIS PRESERVED transcriptLines=\(after.transcript.count) cuts=\(after.cuts.count) byteForByteMetadata=true")
                }
            }
            library.setMode(.listen)
            library.listenSelection = .show(showID)
            library.save() // isolated .build/BroskiTest/Library.json only
            note("PASSED nativeUI=true show=\(show.title) episodes=\(library.episodes(inShow: showID).count) storage=isolated media=isolated screenshot=\(screenshotPath ?? "interactive")")
            if shouldExit {
                try await Task.sleep(for: .seconds(2))
                capture()
            }
        } catch {
            fail(error.localizedDescription, screenshot: shouldExit)
        }
    }

    /// Read-only cache acceptance: require the exact current verified YouTube
    /// MP4, both deterministic cached files, native chapters, and playable A/V.
    /// Do not change a recording's source while previously generated analysis
    /// is attached to that recording's timeline.
    private func hasVerifiedReadyMedia(episode: Episode, verified: YouTubeSource.Video) async -> Bool {
        let stem = "\(episode.id.uuidString)-youtube-\(verified.id)"
        let m4a = media.appendingPathComponent("\(stem).m4a")
        let mp4 = media.appendingPathComponent("\(stem).mp4")
        guard episode.stage == .ready, episode.isVideo,
              episode.youtubeMediaID == verified.id,
              episode.youtubeID == verified.id,
              episode.localFile == mp4.path,
              episode.originalLocalFile == mp4.path,
              episode.chapters.count == verified.chapters.count,
              zip(episode.chapters, verified.chapters).allSatisfy({ pair in
                  abs(pair.0.start - pair.1.start) < 0.1 && pair.0.title == pair.1.title
              }) else { return false }
        for (url, expectsVideo) in [(m4a, false), (mp4, true)] {
            guard let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value,
                  bytes > 10_000 else { return false }
            let asset = AVURLAsset(url: url)
            do {
                async let length = asset.load(.duration)
                async let playable = asset.load(.isPlayable)
                async let audio = asset.loadTracks(withMediaType: .audio)
                async let picture = asset.loadTracks(withMediaType: .video)
                let (duration, isPlayable, audioTracks, videoTracks) = try await (length, playable, audio, picture)
                guard isPlayable, duration.seconds.isFinite,
                      abs(duration.seconds - verified.duration) < 3,
                      !audioTracks.isEmpty,
                      (expectsVideo ? !videoTracks.isEmpty : videoTracks.isEmpty) else { return false }
            } catch { return false }
        }
        return true
    }

    private func mediaPass(episodeID: UUID, showID: UUID, video: Bool,
                           library: Library, processor: Processor, player: Player,
                           verified: YouTubeSource.Video) async throws {
        guard var show = library.show(showID) else { throw TestError.missing("Missing show") }
        show.youtubePlaybackVideo = video
        library.updateShow(show)
        guard let index = library.episodeIndex(episodeID) else { throw TestError.missing("Missing episode") }
        library.episodes[index].played = false
        library.episodes[index].stage = .queued
        library.episodes[index].note = nil
        library.save()
        let begun = Date()
        await processor.processImmediately(episodeID)
        guard let updated = library.episode(episodeID), updated.stage == .ready,
              updated.youtubeMediaID == verified.id,
              updated.isVideo == video,
              let file = updated.localFile,
              file.hasPrefix(media.path + "/"),
              file.contains("-youtube-\(verified.id)."),
              file.hasSuffix(video ? ".mp4" : ".m4a") else {
            throw TestError.missing("Production \(video ? "video" : "audio") did not select verified YouTube file (stage=\(library.episode(episodeID)?.stage.rawValue ?? "missing") note=\(library.episode(episodeID)?.note ?? "none"))")
        }
        let asset = AVURLAsset(url: URL(fileURLWithPath: file))
        async let duration = asset.load(.duration)
        async let playable = asset.load(.isPlayable)
        async let audioTracks = asset.loadTracks(withMediaType: .audio)
        async let videoTracks = asset.loadTracks(withMediaType: .video)
        let (length, isPlayable, audio, picture) = try await (duration, playable, audioTracks, videoTracks)
        let bytes = (try FileManager.default.attributesOfItem(atPath: file)[.size] as? NSNumber)?.int64Value ?? 0
        guard isPlayable, length.seconds.isFinite, length.seconds > 60,
              bytes > 10000, !audio.isEmpty, (video ? !picture.isEmpty : picture.isEmpty),
              updated.chapters.count == verified.chapters.count else {
            throw TestError.missing("AVFoundation \(video ? "video" : "audio") or native chapter integrity failed")
        }
        note(String(format: "%@ PASSED source=YouTube id=%@ bytes=%lld duration=%.1fs tracksAudio=%d tracksVideo=%d nativeChapters=%d elapsed=%.1fs isolated=true",
                    video ? "VIDEO" : "AUDIO", verified.id, bytes, length.seconds, audio.count,
                    picture.count, updated.chapters.count, Date().timeIntervalSince(begun)))
    }

    private enum TestError: LocalizedError {
        case missing(String)
        var errorDescription: String? {
            if case .missing(let message) = self { return message }
            return nil
        }
    }
}
