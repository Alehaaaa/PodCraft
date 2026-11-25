import Foundation
import AVFoundation
import MediaPlayer

/// Opt-in native diagnostic, run with PODCRAFT_PLAYBACK_STRESS=<local audio file>.
/// Uses the real AVPlayer and remote metadata service, without touching saved user data.
@MainActor
enum PlaybackStress {
    static func run(player: Player, library: Library, file: String) async {
        guard FileManager.default.fileExists(atPath: file), !library.persist else {
            print("PLAYBACK STRESS FAILED: requires a screenshot/test library and a local audio file")
            fflush(stdout)
            exit(3)
        }
        library.settings.transcribe = false
        library.settings.generateChapters = false
        if ProcessInfo.processInfo.environment["PODCRAFT_TEST_SERVER"] == "1" {
            // Production PodCraft may already serve its feeds on 8743. A screenshot
            // diagnostic must never contact or disturb that user's running server.
            library.settings.hostPort = 30000 + Int(ProcessInfo.processInfo.processIdentifier % 20000)
            library.server?.start()
            try? await Task.sleep(for: .milliseconds(200))
        }
        let show = Show(title: "Player Lifecycle Test", author: "PodCraft QA", hue: 0.4)
        library.shows.append(show)
        let url = URL(fileURLWithPath: file)
        let assetDuration = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 30
        let length = assetDuration.isFinite && assetDuration > 5 ? assetDuration : 30
        let items: [Episode] = (0..<3).map { index in
            var episode = Episode(showID: show.id, title: "Episode \(index)",
                                  published: Date(), addedAt: Date(), duration: length,
                                  audioURL: url.absoluteString, stage: .ready)
            episode.localFile = file
            episode.chapters = [Chapter(start: 0, title: "Start"), Chapter(start: 10, title: "Next")]
            return episode
        }
        library.episodes.append(contentsOf: items)

        let started = CFAbsoluteTimeGetCurrent()
        player.play(items[0].id)
        let staleItem = player.avPlayerForRoutes?.currentItem
        for index in 0..<60 {
            player.play(items[index % items.count].id)
            player.seek(to: Double((index * 3) % 20))
            if index.isMultiple(of: 3) { player.togglePlay(); player.togglePlay() }
        }
        player.play(items[1].id)
        player.seek(to: 12)
        if let staleItem {
            NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: staleItem)
        }
        try? await Task.sleep(for: .milliseconds(500))
        let staleIgnored = player.episodeID == items[1].id && !library.episode(items[1].id)!.played
        let positionPreserved = abs(player.position - 12) < 2.5
        let nowPlaying = MPNowPlayingInfoCenter.default().nowPlayingInfo
        let mediaValid = (nowPlaying?[MPMediaItemPropertyTitle] as? String) == items[1].title

        // Transcription can finish while an RSS stream is playing, and a newly
        // matched YouTube recording can have a different duration and URL.
        // Never restart the actual AVPlayer at zero or attach different-source
        // chapters to its old clock. Exercise this with an isolated copied WAV.
        let replacement = FileManager.default.temporaryDirectory.appendingPathComponent(
            "podcraft-source-switch-\(UUID().uuidString).wav")
        let sourcePrepared = (try? FileManager.default.copyItem(at: url, to: replacement)) != nil
        let previousAVPlayer = player.avPlayerForRoutes
        if sourcePrepared, let index = library.episodeIndex(items[1].id) {
            library.episodes[index].localFile = replacement.path
            library.episodes[index].originalLocalFile = replacement.path
            library.episodes[index].youtubeMediaID = "TESTSOURCE1"
            library.episodes[index].duration = length + 120
            library.episodes[index].chapters = [Chapter(start: 0, title: "Different-source chapter")]
            library.episodes[index].stage = .ready
        }
        try? await Task.sleep(for: .milliseconds(1_100))
        let sourceStable = sourcePrepared && previousAVPlayer === player.avPlayerForRoutes
            && player.episodeID == items[1].id && player.isPlaying
            && player.position > 9 && player.position < 20
            && !player.chapters.contains(where: { $0.title == "Different-source chapter" })
        let currentItem = player.avPlayerForRoutes?.currentItem
        if let currentItem {
            NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: currentItem)
            try? await Task.sleep(for: .milliseconds(150))
            NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: currentItem)
        }
        try? await Task.sleep(for: .milliseconds(150))
        let endedOnce = library.metrics.episodesFinished == 1 && !player.isPlaying
        player.togglePlay()
        try? await Task.sleep(for: .milliseconds(175))
        let replayed = player.isPlaying && player.episodeID == items[1].id
            && player.position < 3 && library.metrics.episodesFinished == 1
        let serverValid = ProcessInfo.processInfo.environment["PODCRAFT_TEST_SERVER"] == "1"
            ? await checkFeedServer(episode: items[1], file: file, port: library.settings.hostPort)
            : true
        player.stop()
        try? FileManager.default.removeItem(at: replacement)
        let cleared = player.episodeID == nil
            && MPNowPlayingInfoCenter.default().nowPlayingInfo == nil
        let elapsed = CFAbsoluteTimeGetCurrent() - started
        let passed = staleIgnored && positionPreserved && sourceStable && replayed
            && mediaValid && endedOnce && cleared && serverValid
        print(String(format: "PLAYBACK STRESS %@ switches=60 elapsed=%.2fs stale=%@ seek=%@ sourceStable=%@ replay=%@ nowPlaying=%@ end=%@ cleanup=%@ server=%@",
                     passed ? "PASSED" : "FAILED", elapsed,
                     String(staleIgnored), String(positionPreserved), String(sourceStable),
                     String(replayed), String(mediaValid), String(endedOnce), String(cleared), String(serverValid)))
        fflush(stdout)
        exit(passed ? 0 : 4)
    }

    private static func checkFeedServer(episode: Episode, file: String, port: Int) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/media/\(episode.id.uuidString.lowercased()).wav"),
              let original = try? Data(contentsOf: URL(fileURLWithPath: file)) else { return false }
        do {
            func fetch(_ method: String, range: String? = nil) async throws -> (Data, HTTPURLResponse) {
                var request = URLRequest(url: url)
                request.httpMethod = method
                request.timeoutInterval = 5
                if let range { request.setValue(range, forHTTPHeaderField: "Range") }
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                return (data, http)
            }
            let (whole, fullResponse) = try await fetch("GET")
            let (part, partialResponse) = try await fetch("GET", range: "bytes=5-14")
            let (invalid, invalidResponse) = try await fetch("GET", range: "bytes=999999999-9999999999")
            let (head, headResponse) = try await fetch("HEAD")
            let passed = fullResponse.statusCode == 200 && whole == original
                && partialResponse.statusCode == 206 && part == original.subdata(in: 5..<15)
                && invalidResponse.statusCode == 416 && invalid.isEmpty
                && headResponse.statusCode == 200 && head.isEmpty
            print("FEED HTTP \(passed ? "PASSED" : "FAILED") bytes=\(whole.count) partial=\(part.count) status=\(fullResponse.statusCode)/\(partialResponse.statusCode)/\(invalidResponse.statusCode)/\(headResponse.statusCode)")
            fflush(stdout)
            return passed
        } catch {
            print("FEED HTTP FAILED: \(error.localizedDescription)")
            fflush(stdout)
            return false
        }
    }
}
