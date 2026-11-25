import Foundation
import AVFoundation

/// Isolated production-Player test. The WAV data is disposable; transcript
/// content simulates the same speech with a regional RSS advertisement inserted
/// before the YouTube edition. No real library, account defaults or media is used.
enum SourceHandoffRegression {
    /// Full integration: an initially untranscribed RSS file keeps playing,
    /// a short Apple SpeechAnalyzer sample is generated through Processor's
    /// serial ML gate, and Player context-aligns it against an independently
    /// saved transcript for the exact verified upload. Both URLs are local;
    /// the YouTube copy is only a symlink, not a rewritten original recording.
    @MainActor
    static func runRecognitionHandoff(localAudio: String, transcriptFixture: String) async -> Int32 {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "podcraft-recognition-handoff-\(UUID().uuidString)", isDirectory: true)
        let suiteName = "org.podcraft.recognition-handoff.\(UUID().uuidString)"
        guard let prefs = UserDefaults(suiteName: suiteName) else { return 2 }
        defer {
            prefs.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: folder)
        }
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        catch { return 2 }
        let source = URL(fileURLWithPath: localAudio)
        let linked = folder.appendingPathComponent("verified-youtube-BaliszUp8hg.m4a")
        guard FileManager.default.isReadableFile(atPath: source.path) else { return 2 }
        do { try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: source) }
        catch { print("RECOGNITION HANDOFF FAILED: temporary symlink: \(error)"); return 2 }
        let fixture: LibraryFile
        do { fixture = try JSONDecoder().decode(LibraryFile.self,
                                                from: Data(contentsOf: URL(fileURLWithPath: transcriptFixture))) }
        catch { print("RECOGNITION HANDOFF FAILED: transcript fixture: \(error)"); return 2 }
        guard let transcript = fixture.episodes.first(where: {
            $0.youtubeMediaID == "BaliszUp8hg" && $0.transcript.count >= 100
        })?.transcript else { return 2 }
        let library = Library(screenshot: false,
                              isolatedStorageURL: folder.appendingPathComponent("Library.json"),
                              isolatedPreferences: prefs)
        library.settings.transcribe = true
        library.settings.generateChapters = false
        library.settings.removeSponsors = false
        var show = Show(title: "Context Speech Handoff", author: "PodCraft QA", hue: 0.6)
        show.feedURL = "https://example.invalid/source-context.xml"
        show.youtubeChannelURL = "https://www.youtube.com/channel/UCdEwstTO8WsTHCyzrCSfXCQ/videos"
        show.keepAvailable = 0 // Never begin an external network download in this fixture.
        library.shows = [show]
        var episode = Episode(showID: show.id, title: "Podcast regional recording",
                              published: Date(), addedAt: Date(), duration: 3367.17,
                              audioURL: source.absoluteString, stage: .ready)
        episode.localFile = source.path
        episode.originalLocalFile = source.path
        episode.language = "en-US"
        library.episodes = [episode]
        library.save()
        let processor = Processor(library: library,
                                  mediaDirectory: folder.appendingPathComponent("Media"))
        library.processor = processor
        let player = Player(library: library, suppressUserSessionWrites: true)
        player.testMute = true
        player.play(episode.id)
        player.seek(to: 180)
        try? await Task.sleep(for: .milliseconds(650))
        let previousItem = player.avPlayerForRoutes
        let before = player.sourcePosition
        guard before > 175 && before < 185, let index = library.episodeIndex(episode.id) else {
            player.shutdown(); processor.shutdown()
            return 3
        }
        library.episodes[index].localFile = linked.path
        library.episodes[index].originalLocalFile = linked.path
        library.episodes[index].youtubeID = "BaliszUp8hg"
        library.episodes[index].youtubeMediaID = "BaliszUp8hg"
        library.episodes[index].youtubeMatchState = .matched
        library.episodes[index].youtubeMatchChannelURL = show.youtubeChannelURL
        library.episodes[index].transcript = transcript
        library.episodes[index].stage = .ready
        library.save()
        var swapped = false
        for _ in 0..<200 { // 50 s max; Apple SpeechAnalyzer may need its first model warmup.
            if player.avPlayerForRoutes !== previousItem {
                swapped = true
                break
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        try? await Task.sleep(for: .milliseconds(500))
        let clock = player.sourcePosition
        let passed = swapped && player.episodeID == episode.id && player.isPlaying &&
            clock > 164 && clock < 240 && previousItem !== player.avPlayerForRoutes
        player.shutdown()
        processor.shutdown()
        print(String(format: "REAL RECOGNITION CONTEXT HANDOFF %@ old=%.1fs youtube=%.1fs switched=%@ transcriptSource=Apple-ASR isolated=true",
                     passed ? "PASSED" : "FAILED", before, clock, String(swapped)))
        fflush(stdout)
        return passed ? 0 : 4
    }

    @MainActor
    static func run(oldFile: String, youtubeFile: String) async -> Int32 {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "podcraft-source-handoff-\(UUID().uuidString)", isDirectory: true)
        let suiteName = "org.podcraft.source-handoff.\(UUID().uuidString)"
        guard let prefs = UserDefaults(suiteName: suiteName) else { return 2 }
        defer {
            prefs.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: folder)
        }
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        catch { print("SOURCE HANDOFF FAILED: isolated folder: \(error)"); return 2 }
        let library = Library(screenshot: false,
                              isolatedStorageURL: folder.appendingPathComponent("Library.json"),
                              isolatedPreferences: prefs)
        library.settings.transcribe = false
        library.settings.generateChapters = false
        library.settings.removeSponsors = false
        var show = Show(title: "Source Context Regression", author: "PodCraft QA", hue: 0.5)
        show.feedURL = "https://example.invalid/qa.xml"
        show.youtubeChannelURL = "https://www.youtube.com/channel/UCdEwstTO8WsTHCyzrCSfXCQ/videos"
        library.shows = [show]
        let phrase = [
            "Today we are planning an autumn journey through the mountains",
            "We bought train tickets and enjoyed the peaceful countryside",
            "Our friends asked about the small villages near the river",
            "The hotel staff explained the museum and the old cathedral",
            "Later we tasted fresh bread and celebrated our family reunion",
            "The market opened early with flowers fruit and local musicians",
            "We followed the walking route toward the beautiful seaside garden",
            "Everyone remembered the unusual story about the ancient lighthouse",
            "During lunch we spoke about books cinema and the summer weather",
            "The festival director welcomed visitors to the renovated theater",
            "After dinner we discussed tomorrow's excursion around the island",
            "The captain described waves dolphins and the changing ocean currents",
            "We reached the historic station before the midnight departure",
            "Several photographers captured the colorful lights above the harbor",
            "This weekend our neighbors will organize another memorable celebration"
        ]
        let youtubeTranscript = phrase.enumerated().map { i, p in
            TranscriptLine(start: Double(i * 4), end: Double(i * 4 + 4), text: p)
        }
        var rssTranscript = youtubeTranscript.map { line in
            TranscriptLine(start: line.start < 12 ? line.start : line.start + 10,
                           end: line.end <= 12 ? line.end : line.end + 10, text: line.text)
        }
        rssTranscript.append(TranscriptLine(start: 12, end: 22,
                                           text: "Regional advertisement and special discounts for local shopping and home services"))
        rssTranscript.sort { $0.start < $1.start }

        let oldURL = URL(fileURLWithPath: oldFile)
        let youtubeURL = URL(fileURLWithPath: youtubeFile)
        guard FileManager.default.isReadableFile(atPath: oldURL.path),
              FileManager.default.isReadableFile(atPath: youtubeURL.path) else { return 2 }
        func episode(_ title: String) -> Episode {
            var e = Episode(showID: show.id, title: title, published: Date(), addedAt: Date(),
                            duration: 70, audioURL: oldURL.absoluteString, stage: .ready)
            e.originalLocalFile = oldURL.path
            e.localFile = oldURL.path
            e.transcript = rssTranscript
            return e
        }
        let first = episode("Aligned RSS to YouTube")
        let second = episode("Unmatched context must stay RSS")
        let third = episode("Paused playback must wait to align")
        library.episodes = [first, second, third]
        library.save()

        let player = Player(library: library, suppressUserSessionWrites: true)
        player.testMute = true
        player.play(first.id)
        player.seek(to: 40)
        try? await Task.sleep(for: .milliseconds(700))
        let firstItem = player.avPlayerForRoutes
        let oldClock = player.sourcePosition
        guard oldClock > 36, oldClock < 45, let firstIndex = library.episodeIndex(first.id) else {
            print("SOURCE HANDOFF FAILED: source playback did not seek to 40s")
            player.shutdown()
            return 3
        }
        library.episodes[firstIndex].localFile = youtubeURL.path
        library.episodes[firstIndex].originalLocalFile = youtubeURL.path
        library.episodes[firstIndex].youtubeID = "BaliszUp8hg"
        library.episodes[firstIndex].youtubeMediaID = "BaliszUp8hg"
        library.episodes[firstIndex].youtubeMatchState = .matched
        library.episodes[firstIndex].youtubeMatchChannelURL = show.youtubeChannelURL
        library.episodes[firstIndex].transcript = youtubeTranscript
        library.episodes[firstIndex].chapters = [Chapter(start: 0, title: "Official intro"),
                                                 Chapter(start: 24, title: "Official middle")]
        library.episodes[firstIndex].duration = 60
        library.save()
        for _ in 0..<36 {
            if player.avPlayerForRoutes !== firstItem { break }
            try? await Task.sleep(for: .milliseconds(125))
        }
        try? await Task.sleep(for: .milliseconds(500))
        let aligned = player.avPlayerForRoutes !== firstItem && player.episodeID == first.id &&
            player.isPlaying && player.sourcePosition > 28 && player.sourcePosition < 37 &&
            player.chapters.contains(where: { $0.title == "Official middle" })
        let mapped = player.sourcePosition

        // The second episode switches metadata to a different YouTube recording
        // but does NOT contain matching speech. Its old AVPlayer must survive.
        player.play(second.id)
        player.seek(to: 40)
        try? await Task.sleep(for: .milliseconds(700))
        let untouchedItem = player.avPlayerForRoutes
        if let index = library.episodeIndex(second.id) {
            library.episodes[index].localFile = youtubeURL.path
            library.episodes[index].originalLocalFile = youtubeURL.path
            library.episodes[index].youtubeID = "BaliszUp8hg"
            library.episodes[index].youtubeMediaID = "BaliszUp8hg"
            library.episodes[index].youtubeMatchState = .matched
            library.episodes[index].youtubeMatchChannelURL = show.youtubeChannelURL
            library.episodes[index].duration = 60
            library.episodes[index].transcript = [
                TranscriptLine(start: 0, end: 12, text: "Physics mathematics astronomy and laboratory experiments"),
                TranscriptLine(start: 12, end: 24, text: "Quantum particles orbital mechanics and chemical synthesis")
            ]
        }
        try? await Task.sleep(for: .seconds(2.2))
        let refused = player.avPlayerForRoutes === untouchedItem && player.isPlaying &&
            player.episodeID == second.id && player.sourcePosition > 40 && player.sourcePosition < 49

        player.play(third.id)
        player.seek(to: 40)
        try? await Task.sleep(for: .milliseconds(450))
        player.togglePlay() // User pauses RSS before the background media arrives.
        let pausedItem = player.avPlayerForRoutes
        if let index = library.episodeIndex(third.id) {
            library.episodes[index].localFile = youtubeURL.path
            library.episodes[index].originalLocalFile = youtubeURL.path
            library.episodes[index].youtubeID = "BaliszUp8hg"
            library.episodes[index].youtubeMediaID = "BaliszUp8hg"
            library.episodes[index].youtubeMatchState = .matched
            library.episodes[index].youtubeMatchChannelURL = show.youtubeChannelURL
            library.episodes[index].duration = 60
            library.episodes[index].transcript = youtubeTranscript
        }
        try? await Task.sleep(for: .milliseconds(700))
        let heldWhilePaused = player.avPlayerForRoutes === pausedItem && !player.isPlaying
        player.togglePlay()
        for _ in 0..<28 {
            if player.avPlayerForRoutes !== pausedItem { break }
            try? await Task.sleep(for: .milliseconds(125))
        }
        try? await Task.sleep(for: .milliseconds(200))
        let resumedAndAligned = heldWhilePaused && player.isPlaying &&
            player.avPlayerForRoutes !== pausedItem && player.sourcePosition > 28 && player.sourcePosition < 37
        let preserved = (library.episode(first.id)?.youtubeMediaID == "BaliszUp8hg") &&
            !library.episodes.contains(where: { $0.id == first.id && $0.cuts.contains(where: { $0.source == "RSS" }) })
        player.shutdown()
        print(String(format: "CONTEXTUAL SOURCE HANDOFF %@ rssSeconds=%.2f mappedYouTubeSeconds=%.2f aligned=%@ unmatchedStaysRSS=%@ pausedThenAligned=%@ isolated=true",
                     aligned && refused && preserved && resumedAndAligned ? "PASSED" : "FAILED", oldClock, mapped,
                     String(aligned), String(refused), String(resumedAndAligned)))
        fflush(stdout)
        return aligned && refused && preserved && resumedAndAligned ? 0 : 4
    }
}
