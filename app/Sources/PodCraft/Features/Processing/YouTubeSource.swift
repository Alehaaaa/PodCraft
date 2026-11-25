import Foundation
import Darwin

/// Optional verified source for a show's official YouTube uploads.
/// No search-result substitution: both a channel match and a unique title/duration
/// match are required before downloading media in place of an RSS recording.
enum YouTubeSource {
    /// YouTube's own chapter boundaries, in the exact downloaded video's source time.
    /// They must not be applied to the differently timed RSS audio.
    struct VideoChapter: Sendable, Hashable {
        let start: Double
        let end: Double
        let title: String
    }

    struct Video: Sendable, Identifiable {
        let id: String
        let title: String
        let duration: Double
        let channelID: String
        let uploadDate: Date?
        var chapters: [VideoChapter] = []
        /// Artwork returned by the video's own verified watch-page metadata.
        /// Never populated from an unverified YouTube search hit.
        var thumbnailURL: String? = nil
        var url: URL { URL(string: "https://www.youtube.com/watch?v=\(id)")! }
    }

    struct Index: Sendable {
        let channelID: String
        let channelTitle: String
        let channelURL: URL
        let videos: [Video]
    }

    enum Failure: LocalizedError {
        case unavailable
        case invalidChannel
        case invalidVideo
        case invalidDirectory
        case invalidResponse
        case downloadFailed(String)
        case cancelled
        case verificationFailed
        case catalogIncomplete
        case streamUnavailable
        case unsafeStreamURL

        var errorDescription: String? {
            switch self {
            case .unavailable: "yt-dlp is not installed. Install it to use YouTube as a source."
            case .invalidChannel: "Enter a YouTube channel URL (youtube.com/@handle or youtube.com/channel/UC…)."
            case .invalidVideo: "The YouTube video ID was invalid."
            case .invalidDirectory: "The media destination is not a valid directory."
            case .invalidResponse: "YouTube did not return a usable channel or video listing."
            case .downloadFailed(let reason): "The YouTube download failed: \(reason)"
            case .cancelled: "The YouTube operation was cancelled."
            case .verificationFailed: "The video could not be verified as belonging to the selected channel."
            case .catalogIncomplete: "This episode predates the bounded YouTube channel listing, so no match could be confirmed safely. Try again after opening more of the archive."
            case .streamUnavailable: "YouTube has no directly streamable H.264/AAC MP4 for this upload, or its temporary playback link could not be resolved. Try the podcast audio or retry later."
            case .unsafeStreamURL: "YouTube returned an unsupported playback address. PodCraft did not open or download it. Try the podcast audio."
            }
        }
    }

    private static let cliLocations = [
        "/opt/homebrew/bin/yt-dlp",
        "/usr/local/bin/yt-dlp",
        "/usr/bin/yt-dlp"
    ]

    static var available: Bool { executable != nil }

    private static var executable: URL? {
        cliLocations.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
            .map { URL(fileURLWithPath: $0) }
    }

    /// Only accepted YouTube channel URLs are passed to the external CLI. Reject playlists,
    /// arbitrary hosts, query strings and encoded paths rather than trying to reinterpret them.
    static func canonicalChannelURL(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed), components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(),
              ["youtube.com", "www.youtube.com", "m.youtube.com"].contains(host),
              components.port == nil, components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              !components.percentEncodedPath.contains("%") else { return nil }
        let parts = components.path.split(separator: "/").map(String.init)
        guard parts.count == 2 || parts.count == 3,
              parts.count == 2 || parts[2] == "videos" else { return nil }
        let namespace = parts[0], value = parts[1]
        let legal: Bool
        if namespace == "channel" {
            legal = value.range(of: #"^UC[A-Za-z0-9_-]{22}$"#, options: .regularExpression) != nil
        } else if namespace.hasPrefix("@") && parts.count == 2 {
            legal = false
        } else if namespace == "user" || namespace == "c" {
            legal = value.range(of: #"^[A-Za-z0-9._-]{3,60}$"#, options: .regularExpression) != nil
        } else {
            legal = false
        }
        // @handles are one path component, optionally followed by /videos.
        if parts[0].hasPrefix("@"), ["", "videos"].contains(parts[1]) {
            let handle = parts[0]
            guard handle.range(of: #"^@[A-Za-z0-9._-]{3,60}$"#, options: .regularExpression) != nil else {
                return nil
            }
            return URL(string: "https://www.youtube.com/\(handle)/videos")
        }
        guard legal else { return nil }
        return URL(string: "https://www.youtube.com/\(namespace)/\(value)/videos")
    }

    /// A browser's normal @handle URL has only one component; accept that too.
    static func channelURL(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let c = URLComponents(string: trimmed), c.scheme?.lowercased() == "https",
              let host = c.host?.lowercased(), ["youtube.com", "www.youtube.com", "m.youtube.com"].contains(host),
              c.port == nil, c.user == nil, c.password == nil, c.query == nil, c.fragment == nil,
              !c.percentEncodedPath.contains("%") else { return nil }
        let parts = c.path.split(separator: "/").map(String.init)
        if let handle = parts.first, handle.hasPrefix("@"),
           (parts.count == 1 || (parts.count == 2 && parts[1] == "videos")),
           handle.range(of: #"^@[A-Za-z0-9._-]{3,60}$"#, options: .regularExpression) != nil {
            return URL(string: "https://www.youtube.com/\(handle)/videos")
        }
        return canonicalChannelURL(from: trimmed)
    }

    static func channelIndex(from channelURL: String) async throws -> Index {
        try await channelIndex(from: channelURL, limit: maximumIndexedUploads)
    }

    /// Larger indexed window for bulk library matching and older on-demand
    /// episodes. Limits are internal and bounded, never caller-supplied URLs.
    private static func channelIndex(from channelURL: String, limit: Int) async throws -> Index {
        guard let canonical = YouTubeSource.channelURL(from: channelURL) else { throw Failure.invalidChannel }
        let bounded = max(1, min(2_000, limit))
        return try await channelCache.resolve(canonical, limit: bounded) {
            let data = try await invoke([
                "--flat-playlist", "--playlist-end", String(bounded),
                "--dump-single-json", canonical.absoluteString
            ], timeout: bounded > maximumIndexedUploads ? 300 : 210)
            return try decodeIndex(from: data, channelURL: canonical)
        }
    }

    /// Pure channel listing decoder, also used by offline matching regression tests.
    static func decodeIndex(from data: Data, channelURL: URL) throws -> Index {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let channelID = (object["channel_id"] ?? object["id"]) as? String,
              channelID.range(of: #"^UC[A-Za-z0-9_-]{22}$"#, options: .regularExpression) != nil,
              let entries = object["entries"] as? [Any] else { throw Failure.invalidResponse }
        let requestedPath = channelURL.path.split(separator: "/")
        if requestedPath.count >= 2, requestedPath[0] == "channel",
           String(requestedPath[1]) != channelID {
            // Do not silently adopt a redirected/unrelated channel.
            throw Failure.verificationFailed
        }
        // yt-dlp occasionally leaves null placeholders for unavailable/deleted
        // uploads; skip them without discarding the entire valid channel index.
        let videos = entries.compactMap { row -> Video? in
            guard let entry = row as? [String: Any] else { return nil }
            guard let id = entry["id"] as? String, validVideoID(id),
                  let title = entry["title"] as? String, !title.isEmpty,
                  let duration = (entry["duration"] as? NSNumber)?.doubleValue, duration > 0 else { return nil }
            let uploadDate = parseDate(entry["upload_date"] as? String) ??
                (entry["timestamp"] as? NSNumber).flatMap { value -> Date? in
                    let seconds = value.doubleValue
                    guard seconds.isFinite, seconds > 946_684_800 else { return nil }
                    return Date(timeIntervalSince1970: seconds)
                }
            return Video(id: id, title: title, duration: duration, channelID: channelID,
                         uploadDate: uploadDate)
        }
        guard !videos.isEmpty else { throw Failure.invalidResponse }
        let rawTitle = object["channel"] as? String
            ?? object["uploader"] as? String
            ?? object["title"] as? String
            ?? "YouTube"
        return Index(channelID: channelID, channelTitle: rawTitle, channelURL: channelURL,
                     videos: videos)
    }

    private static let channelCache = ChannelIndexCache()
    private static let discoveryCache = ChannelDiscoveryCache()
    private static let verifiedVideoCache = VerifiedVideoCache()
    private static let captionCache = VerifiedCaptionCache()
    /// A channel's first 100 uploads may span only a few months. Read a bounded
    /// catalog so old public RSS episodes have a chance to match without
    /// searching arbitrary uploads or crawling an unlimited channel history.
    private static let maximumIndexedUploads = 500
    private static let maximumArchiveUploads = 2_000

    /// Automatically find an official YouTube channel for an RSS podcast without requiring
    /// a pasted URL. A channel is accepted only when several *different* recent episodes
    /// match its uploads by title and duration AND its name matches the show's identity.
    /// A missing/ambiguous result is nil: never substitute a fan/reupload channel.
    static func discoverChannel(show: Show) async throws -> Index? {
        if let manual = show.youtubeChannelURL, !manual.isEmpty {
            return try await channelIndex(from: manual)
        }
        guard available else { throw Failure.unavailable }
        let key = "\(show.id.uuidString):\(show.title):\(show.feedURL ?? "")"
        if let remembered = await discoveryCache.lookup(key) { return remembered }
        guard let rss = show.feedURL, let rssURL = URL(string: rss),
              ["http", "https"].contains(rssURL.scheme?.lowercased() ?? "") else { return nil }
        let feed = try await FeedFetcher.fetch(rssURL)
        let episodes = feed.items
            .filter {
                $0.duration > 90 &&
                !$0.title.trimmingCharacters(in: .whitespaces).isEmpty &&
                // Private extras can occupy half the newest RSS entries.
                // Discovery needs multiple independent public episodes.
                !likelyExclusiveBonus(title: $0.title)
            }
            .sorted { $0.published > $1.published }
            .prefix(36).map { $0.episode(showID: show.id) }
        guard episodes.count >= 2 else { return nil }

        // "ytsearch" is a fixed yt-dlp extractor prefix, not a shell or arbitrary URL.
        // Search only a bounded, single-line show name. Video results supply real
        // channel_id values which are then verified against each channel's own /videos.
        let term = show.title.replacingOccurrences(of: #"[\r\n\t]+"#, with: " ",
                                                    options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return nil }
        let search = "ytsearch15:\(String(term.prefix(110)))"
        let data = try await invoke(["--flat-playlist", "--playlist-end", "15",
                                     "--dump-single-json", search], timeout: 90)
        guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = response["entries"] as? [Any] else {
            throw Failure.invalidResponse
        }
        var counts: [String: Int] = [:]
        var labels: [String: String] = [:]
        for row in results {
            guard let result = row as? [String: Any] else { continue }
            guard let id = result["channel_id"] as? String,
                  id.range(of: #"^UC[A-Za-z0-9_-]{22}$"#, options: .regularExpression) != nil,
                  let title = (result["channel"] ?? result["uploader"]) as? String,
                  strongChannelIdentity(show: show, name: title) else { continue }
            counts[id, default: 0] += 1
            labels[id] = title
        }
        // A short general-title search can overwhelmingly return a publisher's
        // clips channel and omit its separate official RSS-focused channel.
        // When only one plausible channel appears, one bounded "podcast" search
        // adds candidates; it never authorizes a match by search ranking alone.
        if counts.count < 2 {
            let podcastSearch = "ytsearch10:\(String(term.prefix(100))) podcast"
            if let extraData = try? await invoke([
                "--flat-playlist", "--playlist-end", "10", "--dump-single-json",
                podcastSearch
            ], timeout: 60),
               let response = try? JSONSerialization.jsonObject(with: extraData) as? [String: Any],
               let extras = response["entries"] as? [Any] {
                for row in extras {
                    guard let entry = row as? [String: Any],
                          let id = entry["channel_id"] as? String,
                          id.range(of: #"^UC[A-Za-z0-9_-]{22}$"#, options: .regularExpression) != nil,
                          let title = (entry["channel"] ?? entry["uploader"]) as? String,
                          strongChannelIdentity(show: show, name: title) else { continue }
                    counts[id, default: 0] += 1
                    labels[id] = title
                }
            }
        }
        // Search ranking is NOT proof of an official podcast channel. The
        // publisher's RSS-matching channel may occur only once in ytsearch15
        // while a same-name clips/video channel dominates the results. Keep
        // up to four brand-compatible candidates even with one search hit;
        // bestChannel still demands >=2 DIFFERENT high-confidence RSS/video
        // matches from each candidate's own verified UC channel listing.
        let candidates = counts.sorted {
                $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
            }
            .prefix(4)
        let diagnostic = ProcessInfo.processInfo.environment["PODCRAFT_YOUTUBE_DISCOVERY_DIAG"] == "1"
        if diagnostic {
            print("YOUTUBE DISCOVERY QUERY rss=\(episodes.count) candidates=\(candidates.map { "\($0.key):\($0.value)" }.joined(separator: ","))")
            fflush(stdout)
        }
        var indexes: [Index] = []
        for candidate in candidates {
            try Task.checkCancellation()
            let url = "https://www.youtube.com/channel/\(candidate.key)/videos"
            do {
                let index = try await channelIndex(from: url)
                let valid = strongChannelIdentity(show: show, name: index.channelTitle)
                if diagnostic {
                    let matched = Set(episodes.compactMap { bestMatch(episode: $0, in: index)?.id })
                    print("YOUTUBE DISCOVERY INDEX id=\(index.channelID) title=\(index.channelTitle) uploads=\(index.videos.count) identity=\(valid) matched=\(matched.count)")
                    fflush(stdout)
                }
                if valid { indexes.append(index) }
            } catch {
                if diagnostic {
                    print("YOUTUBE DISCOVERY INDEX ERROR id=\(candidate.key) \(error.localizedDescription)")
                    fflush(stdout)
                }
            }
        }
        let result = bestChannel(show: show, episodes: episodes, candidates: indexes)
        if diagnostic {
            print("YOUTUBE DISCOVERY CHOSEN id=\(result?.channelID ?? "none")")
            fflush(stdout)
        }
        await discoveryCache.store(key, index: result)
        return result
    }

    /// Pure conservative channel selector for offline matching tests.
    static func bestChannel(show: Show, episodes: [Episode], candidates: [Index]) -> Index? {
        guard episodes.count >= 2 else { return nil }
        let matches = candidates.compactMap { index -> (Index, Int)? in
            guard strongChannelIdentity(show: show, name: index.channelTitle) else { return nil }
            let uniqueMatches = Set(episodes.compactMap { bestMatch(episode: $0, in: index)?.id })
            return uniqueMatches.count >= 2 ? (index, uniqueMatches.count) : nil
        }.sorted { $0.1 > $1.1 }
        guard let winner = matches.first else { return nil }
        if matches.count == 1 { return winner.0 }
        // A publisher may operate separate official audio-podcast and video
        // channels with nearly identical names. An arbitrary second channel
        // with only a few matching uploads should not permanently block a
        // much more complete, independently matching podcast catalog. Accept
        // one *clearly dominant* source only: >=12 separate public RSS titles,
        // at least twice the runner-up's confirmations and eight more distinct
        // matches. This handles a publisher's exact podcast feed mirrored on a
        // second, translated video channel (36 vs 18 real public titles).
        // Otherwise the channels remain ambiguous and need manual selection.
        guard winner.1 >= 12, winner.1 >= 2 * matches[1].1,
              winner.1 - matches[1].1 >= 8 else { return nil }
        return winner.0
    }

    private static func strongChannelIdentity(show: Show, name: String) -> Bool {
        let source = collapsedName(show.title)
        let channel = collapsedName(name)
        guard source.count >= 6, channel.count >= 6 else { return false }
        if source.contains(channel) || channel.contains(source) { return true }
        let sourceTokens = Set(normalizedTitle(show.title).split(separator: " ").filter { $0.count >= 4 })
        let channelTokens = Set(normalizedTitle(name).split(separator: " ").filter { $0.count >= 4 })
        guard !channelTokens.isEmpty else { return false }
        return Double(sourceTokens.intersection(channelTokens).count) / Double(channelTokens.count) >= 0.7
    }

    private static func collapsedName(_ text: String) -> String {
        normalizedTitle(text).replacingOccurrences(of: " ", with: "")
    }

    /// A *single*, high-confidence recording match, confirmed against the video's own
    /// metadata and uploader. RSS recordings may contain inserted ads, so their durations
    /// may be several minutes longer than the official upload.
    static func match(episode: Episode, channelURL: String) async throws -> Video? {
        let index = try await channelIndex(from: channelURL)
        if let match = try await match(episode: episode, in: index) { return match }
        // An exact negative from the first 500 uploads is meaningless for
        // older public RSS entries. Expand once on demand, without treating
        // bonus/private RSS entries as proof of public YouTube uploads.
        guard index.videos.count >= maximumIndexedUploads,
              !likelyExclusiveBonus(title: episode.title) else { return nil }
        let archive = try await channelIndex(from: channelURL, limit: maximumArchiveUploads)
        if let match = try await match(episode: episode, in: archive) { return match }
        if archive.videos.count >= maximumArchiveUploads {
            // The archive is still truncated. Verify its real oldest public
            // upload date before deciding whether this RSS episode was covered.
            guard let oldest = archive.videos.last else { throw Failure.catalogIncomplete }
            let verified = try await verifiedVideoCache.resolve(
                id: oldest.id, channelID: archive.channelID
            ) {
                try await verifyVideo(id: oldest.id, channelID: archive.channelID)
            }
            guard let oldestDate = verified.uploadDate,
                  episode.published >= oldestDate.addingTimeInterval(-21 * 86_400) else {
                throw Failure.catalogIncomplete
            }
        }
        return nil
    }

    private static func match(episode: Episode, in index: Index) async throws -> Video? {
        guard let best = bestMatch(episode: episode, in: index) else {
            return try await renamedRecordingMatch(episode: episode, in: index)
        }
        let verified = try await verifiedVideoCache.resolve(id: best.id, channelID: index.channelID) {
            try await verifyVideo(id: best.id, channelID: index.channelID)
        }
        try Task.checkCancellation()
        // YouTube's flat channel listing can localize/translate or shorten titles while
        // the individual watch-page metadata returns the original wording. The upload ID
        // and official channel ID are verified above; compare the *authoritative* video
        // title against the RSS episode, rather than requiring the two YouTube APIs to
        // use identical display strings. This still rejects unrelated videos.
        guard (titleSimilarity(normalizedTitle(episode.title), normalizedTitle(verified.title)) >= 0.92 ||
               matchingSerialAndSubject(episode.title, verified.title)),
              abs(verified.duration - episode.duration) <= allowedDurationDifference(episode.duration)
        else { return nil }
        if let upload = verified.uploadDate {
            guard abs(upload.timeIntervalSince(episode.published)) <= 21 * 86400 else { return nil }
        }
        return verified
    }

    /// Sometimes the RSS and YouTube use completely different headlines for
    /// the SAME public recording. The Wine About It audit includes one with
    /// "The Peter Pan Girl" in RSS and "Calling Out Fear&" on YouTube, both
    /// exactly 4290 seconds and published the same day. Relaxing the global
    /// title threshold would invite false positives. Instead this fallback
    /// requires FOUR independent facts: a unique near-exact duration, the
    /// official uploader's actual watch page, a corroborating upload date,
    /// and no other eligible upload in that same date/duration window.
    ///
    /// Generic bonus/premium/private RSS entries never qualify for this
    /// fallback. They can match only by the regular explicit title rule when
    /// such a video really exists on the official channel.
    private static func renamedRecordingMatch(episode: Episode, in index: Index) async throws -> Video? {
        guard episode.duration.isFinite, episode.duration >= 300,
              !likelyExclusiveBonus(title: episode.title) else { return nil }
        let candidates = index.videos.filter {
            $0.channelID == index.channelID &&
            abs($0.duration - episode.duration) <= 1.5
        }
        // Too many duration collisions cannot be disambiguated safely or
        // checked with a bounded number of YouTube watch-page requests.
        guard !candidates.isEmpty, candidates.count <= 8 else { return nil }

        var unique: Video?
        for candidate in candidates {
            try Task.checkCancellation()
            let verified = try await verifiedVideoCache.resolve(
                id: candidate.id, channelID: index.channelID
            ) {
                try await verifyVideo(id: candidate.id, channelID: index.channelID)
            }
            try Task.checkCancellation()
            guard verified.id == candidate.id,
                  verified.channelID == index.channelID,
                  abs(verified.duration - episode.duration) <= 1.5,
                  let upload = verified.uploadDate,
                  abs(upload.timeIntervalSince(episode.published)) <= 2 * 86_400
            else { continue }
            if unique != nil { return nil }
            unique = verified
        }
        return unique
    }

    private static func likelyExclusiveBonus(title: String) -> Bool {
        let words = Set(normalizedTitle(title).split(separator: " "))
        return words.contains("patreon") || words.contains("premium") ||
               words.contains("bonus") || words.contains("exclusive") ||
               words.contains("suscriptores") || words.contains("members")
    }

    /// Pure, deterministic matching for previews and regression tests; no network or CLI.
    static func bestMatch(episode: Episode, in index: Index) -> Video? {
        let requested = normalizedTitle(episode.title)
        guard !requested.isEmpty else { return nil }
        let threshold = allowedDurationDifference(episode.duration)
        let candidates = index.videos.compactMap { video -> (Video, Double)? in
            // Reject implausible clocks BEFORE expensive Unicode title
            // normalization and token scoring. A full 2000-video catalog
            // otherwise repeats that work hundreds of thousands of times.
            guard video.channelID == index.channelID,
                  abs(video.duration - episode.duration) <= threshold else { return nil }
            let title = normalizedTitle(video.title)
            guard !title.isEmpty else { return nil }
            let similarity = titleSimilarity(requested, title)
            let hasVerifiedSerial = matchingSerialAndSubject(episode.title, video.title)
            guard similarity >= 0.92 || hasVerifiedSerial else { return nil }
            return (video, hasVerifiedSerial ? max(similarity, 0.94) : similarity)
        }.sorted { $0.1 > $1.1 }
        guard candidates.count == 1 else { return nil }
        return candidates[0].0
    }

    /// Bulk *metadata* lookup for all RSS episodes on a show. A single bounded
    /// official-channel listing replaces hundreds of repeated channel reads.
    /// Returns only high-confidence metadata candidates unique both within
    /// the official channel and across the supplied RSS episodes. Renamed
    /// titles may additionally qualify from *two independent strict-match
    /// chronological anchors* plus an exact unique source-clock duration.
    /// The caller may display/persist candidate IDs but MUST use match()/
    /// verifyVideo before playing media, applying SponsorBlock or attaching
    /// YouTube captions; a metadata candidate is not playback verification.
    ///
    /// A missing entry is NOT a verified negative: the channel may have older
    /// uploads beyond maximumIndexedUploads, changed a title, or never
    /// published an RSS-only premium episode.
    static func catalogMatches(episodes: [Episode], channelURL: String) async throws -> [UUID: Video] {
        // Enough headroom for short clips, highlight uploads and feed gaps.
        // The cap is explicit; absent entries must never be marked "notFound".
        let limit = min(maximumArchiveUploads, max(maximumIndexedUploads, episodes.count * 3))
        let index = try await channelIndex(from: channelURL, limit: limit)
        try Task.checkCancellation()
        // Precompute expensive Unicode title normalization ONCE per video,
        // not hundreds of times per source show. Shortlist by duration first.
        let prepared = index.videos.map(PreparedCatalogVideo.init)
        var result: [UUID: Video] = [:]
        var claimedBy: [String: UUID] = [:]
        var duplicates: Set<String> = []
        for episode in episodes where episode.audioURL != nil {
            try Task.checkCancellation()
            guard let candidate = safeCatalogMatch(
                episode: episode, in: index, prepared: prepared) else { continue }
            guard !duplicates.contains(candidate.id) else { continue }
            if let older = claimedBy[candidate.id], older != episode.id {
                // Two RSS entries claim the same channel upload: do not map
                // one YouTube clock to either without more identifying facts.
                result.removeValue(forKey: older)
                claimedBy.removeValue(forKey: candidate.id)
                duplicates.insert(candidate.id)
            } else {
                claimedBy[candidate.id] = episode.id
                result[episode.id] = candidate
            }
        }
        // A channel's flat playlist usually supplies no upload dates. Learn
        // only tightly bracketed tentative IDs from the already strong title
        // anchors, never from duration or upload position alone. The final
        // per-episode match() checks real watch-page upload date and uploader.
        let groups = Set(episodes.map(\.showID))
        if groups.count == 1 {
            let proposals = bracketedCatalogCandidates(
                episodes: episodes, index: index, strictMatches: result)
            for (episodeID, video) in proposals {
                guard !duplicates.contains(video.id), claimedBy[video.id] == nil else { continue }
                claimedBy[video.id] = episodeID
                result[episodeID] = video
            }
        }
        return result
    }

    /// An upload renamed on YouTube may still be identified by two nearby
    /// exact title matches in the same channel's reverse-chronological
    /// sequence. Require a short bracket, a single unused upload with almost
    /// exactly the same clock, and a unique claimant on the RSS side. Never
    /// permit this fallback to propagate: only ORIGINAL strict anchors count.
    private static func bracketedCatalogCandidates(
        episodes: [Episode], index: Index, strictMatches: [UUID: Video]
    ) -> [UUID: Video] {
        let ordered = episodes.filter { $0.audioURL != nil }
            .sorted { $0.published > $1.published }
        let positionByVideo = Dictionary(uniqueKeysWithValues:
            index.videos.enumerated().map { ($0.element.id, $0.offset) })
        let anchors: [(rss: Int, video: Int)] = ordered.enumerated().compactMap { offset, episode in
            guard let video = strictMatches[episode.id],
                  let position = positionByVideo[video.id] else { return nil }
            return (offset, position)
        }
        guard anchors.count >= 2 else { return [:] }
        let alreadyUsed = Set(strictMatches.values.map(\.id))
        var proposed: [UUID: Video] = [:]
        var videoClaimCounts: [String: Int] = [:]
        for pair in zip(anchors, anchors.dropFirst()) {
            let newer = pair.0, older = pair.1
            guard older.rss > newer.rss + 1,
                  older.rss - newer.rss <= 20,
                  older.video > newer.video + 1,
                  older.video - newer.video <= 12 else { continue }
            let candidateWindow = index.videos[(newer.video + 1)..<older.video]
            for i in (newer.rss + 1)..<older.rss {
                let episode = ordered[i]
                guard episode.duration.isFinite, episode.duration >= 300,
                      !likelyExclusiveBonus(title: episode.title) else { continue }
                let candidates = candidateWindow.filter { video in
                    guard video.channelID == index.channelID,
                          !alreadyUsed.contains(video.id),
                          abs(video.duration - episode.duration) <= 1.5 else { return false }
                    if let date = video.uploadDate {
                        return abs(date.timeIntervalSince(episode.published)) <= 2 * 86_400
                    }
                    return true
                }
                guard candidates.count == 1 else { continue }
                let video = candidates[0]
                proposed[episode.id] = video
                videoClaimCounts[video.id, default: 0] += 1
            }
        }
        return proposed.filter { videoClaimCounts[$0.value.id] == 1 }
    }

    private struct PreparedCatalogVideo {
        let video: Video
        let normalized: String
        let words: Set<Substring>
        let normalizedSerial: String?
        let rawSerial: String?

        init(_ video: Video) {
            self.video = video
            normalized = YouTubeSource.normalizedTitle(video.title)
            words = Set(normalized.split(separator: " "))
            normalizedSerial = YouTubeSource.episodeSerial(normalized)
            rawSerial = YouTubeSource.episodeSerial(video.title)
        }
    }

    /// Same scoring and exactly-one-candidate rule as bestMatch, but reuse
    /// prepared titles and token sets across a whole show. Never make a
    /// candidate by chronology, position or a duration match on its own.
    private static func bestCatalogMatch(episode: Episode, in index: Index,
                                         prepared: [PreparedCatalogVideo]) -> Video? {
        let requested = normalizedTitle(episode.title)
        guard !requested.isEmpty else { return nil }
        let requestedWords = Set(requested.split(separator: " "))
        let normalizedSerial = episodeSerial(requested)
        let rawSerial = episodeSerial(episode.title)
        let threshold = allowedDurationDifference(episode.duration)
        var best: Video?
        for item in prepared {
            let video = item.video
            guard video.channelID == index.channelID,
                  abs(video.duration - episode.duration) <= threshold,
                  !item.normalized.isEmpty else { continue }
            let overlap = requestedWords.intersection(item.words).count
            let score: Double
            if requested == item.normalized {
                score = 1
            } else if min(requestedWords.count, item.words.count) >= 4 &&
                        overlap == min(requestedWords.count, item.words.count) {
                score = 0.97
            } else if let normalizedSerial, normalizedSerial == item.normalizedSerial &&
                        overlap >= 3 {
                score = 0.96
            } else {
                score = Double(overlap) / Double(requestedWords.union(item.words).count)
            }
            let sameSerial = rawSerial != nil && rawSerial == item.rawSerial
            guard score >= 0.92 ||
                  (sameSerial && matchingSerialAndSubject(episode.title, video.title))
            else { continue }
            // The original bestMatch returns nil when two candidate uploads
            // qualify, not merely the highest score.
            if best != nil { return nil }
            best = video
        }
        return best
    }

    /// Title-independent catalog matching is permitted ONLY when the flat
    /// listing actually provides an upload date. Some YouTube extractors omit
    /// it entirely; in that case a renamed episode stays unconfirmed until
    /// match() reads the authoritative watch-page date. Never invent dates
    /// from playlist position or match a private/bonus entry by duration.
    private static func safeCatalogMatch(episode: Episode, in index: Index,
                                         prepared: [PreparedCatalogVideo]) -> Video? {
        if let strict = bestCatalogMatch(episode: episode, in: index, prepared: prepared) {
            return strict
        }
        guard episode.duration.isFinite, episode.duration >= 300,
              !likelyExclusiveBonus(title: episode.title) else { return nil }
        let eligible = index.videos.filter { video in
            guard let date = video.uploadDate else { return false }
            return video.channelID == index.channelID &&
                abs(video.duration - episode.duration) <= 1.5 &&
                abs(date.timeIntervalSince(episode.published)) <= 2 * 86_400
        }
        guard eligible.count == 1 else { return nil }
        return eligible[0]
    }

    private static func allowedDurationDifference(_ duration: Double) -> Double {
        max(70, min(240, duration * 0.085))
    }

    /// Use a unique temporary directory, then an atomic move into a deterministic file.
    /// Never overwrite a previously downloaded episode or touch the original RSS media.
    static func download(videoID: String, video: Bool, destinationFolder: URL,
                         episodeID: UUID) async throws -> URL {
        guard validVideoID(videoID) else { throw Failure.invalidVideo }
        let fs = FileManager.default
        try fs.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
        var isDir: ObjCBool = false
        guard fs.fileExists(atPath: destinationFolder.path, isDirectory: &isDir), isDir.boolValue
        else { throw Failure.invalidDirectory }
        let ext = video ? "mp4" : "m4a"
        let final = destinationFolder.appendingPathComponent(
            "\(episodeID.uuidString)-youtube-\(videoID).\(ext)")
        if let attrs = try? fs.attributesOfItem(atPath: final.path),
           let bytes = attrs[.size] as? NSNumber, bytes.int64Value > 0 { return final }
        let stage = destinationFolder.appendingPathComponent(
            ".youtube-stage-\(episodeID.uuidString)-\(UUID().uuidString)", isDirectory: true)
        try fs.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? fs.removeItem(at: stage) }
        // Progressive MP4 carries H.264+AAC together; itag 18 on the verified Broski upload
        // downloads via yt-dlp's native HTTP transport. DASH A/V can fail external ffmpeg
        // range fetching with HTTP 403. Retain DASH only as a fallback when no progressive
        // H.264+AAC source exists. For audio, extract M4A from the verified progressive
        // MP4 first; current native audio DASH responses can fail with HTTP 403.
        let strategies: [[String]] = video
            ? [
                ["-f", "b[ext=mp4][vcodec^=avc1][acodec^=mp4a]"],
                ["-f", "bv[vcodec^=avc1]+ba[ext=m4a]",
                 "--merge-output-format", "mp4"]
            ] : [
                ["-f", "b[ext=mp4][vcodec^=avc1][acodec^=mp4a]",
                 "--extract-audio", "--audio-format", "m4a"],
                // Current YouTube audio-only DASH variants may advertise a
                // playable URL but return HTTP 403 on the full transfer.
                // Prefer the proven progressive H.264/AAC source first.
                ["-f", "ba[ext=m4a]/ba[acodec^=mp4a]"]
            ]
        var errors: [String] = []
        for (index, format) in strategies.enumerated() {
            try Task.checkCancellation()
            let attempt = stage.appendingPathComponent("attempt-\(index)", isDirectory: true)
            try fs.createDirectory(at: attempt, withIntermediateDirectories: false)
            let output = attempt.appendingPathComponent("source.%(ext)s").path
            do {
                _ = try await invoke([
                    "--no-playlist", "--no-progress", "--restrict-filenames",
                    "--no-mtime", "--socket-timeout", "25", "-o", output
                ] + format + ["https://www.youtube.com/watch?v=\(videoID)"], timeout: video ? 1800 : 900)
                let files = try fs.contentsOfDirectory(at: attempt,
                                                       includingPropertiesForKeys: [.isRegularFileKey],
                                                       options: [.skipsHiddenFiles])
                    .filter { $0.pathExtension.lowercased() == ext }
                guard files.count == 1,
                      let attrs = try? fs.attributesOfItem(atPath: files[0].path),
                      let bytes = attrs[.size] as? NSNumber, bytes.int64Value > 0 else {
                    throw Failure.downloadFailed("The requested \(ext.uppercased()) file was not produced.")
                }
                // FileManager.moveItem refuses an existing destination: never overwrite.
                if fs.fileExists(atPath: final.path) { return final }
                try fs.moveItem(at: files[0], to: final)
                return final
            } catch {
                if Task.isCancelled { throw CancellationError() }
                errors.append(error.localizedDescription)
            }
        }
        throw Failure.downloadFailed(errors.joined(separator: " / "))
    }

    private static func verifyVideo(id: String, channelID: String) async throws -> Video {
        guard validVideoID(id) else { throw Failure.invalidVideo }
        let data = try await invoke([
            "--no-playlist", "--skip-download", "--dump-single-json",
            "https://www.youtube.com/watch?v=\(id)"
        ], timeout: 90)
        guard let item = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let realID = item["id"] as? String, realID == id,
              let actualChannelID = item["channel_id"] as? String,
              actualChannelID == channelID, let title = item["title"] as? String,
              let duration = (item["duration"] as? NSNumber)?.doubleValue, duration > 0
        else { throw Failure.verificationFailed }
        return Video(id: id, title: title, duration: duration,
                     channelID: actualChannelID, uploadDate: parseDate(item["upload_date"] as? String),
                     chapters: decodeChapters(from: item, duration: duration),
                     thumbnailURL: verifiedThumbnailURL(from: item, videoID: id))
    }

    /// Resolve a fresh, direct AVPlayer-compatible *progressive* H.264/AAC MP4
    /// stream. No media download, playlist merge, file staging, URL cache, or
    /// reused signed CDN link is involved. Call it on every playback attempt.
    ///
    /// channelID must be the ID of the show's already verified official
    /// channel; the watch page is verified again before resolving the stream.
    /// An arbitrary 11-character ID cannot bypass the uploader check.
    ///
    /// The returned Googlevideo URL is a short-lived bearer credential: keep
    /// it only in AVPlayer memory, do not persist it or include it in logs.
    static func playableStream(videoID: String, channelID: String) async throws
        -> (url: URL, duration: Double, chapters: [VideoChapter]) {
        guard available else { throw Failure.unavailable }
        guard validVideoID(videoID),
              channelID.range(of: #"^UC[A-Za-z0-9_-]{22}$"#, options: .regularExpression) != nil
        else { throw Failure.verificationFailed }
        try Task.checkCancellation()

        // Do not use a cached/index-only match: verify the exact real watch
        // page's ID and channel before releasing a playable signed URL.
        let verified: Video
        do {
            verified = try await verifyVideo(id: videoID, channelID: channelID)
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as Failure {
            switch failure {
            case .verificationFailed, .invalidVideo:
                throw failure
            default:
                // Existing yt-dlp errors may include ephemeral signed URLs.
                throw Failure.streamUnavailable
            }
        } catch {
            throw Failure.streamUnavailable
        }
        try Task.checkCancellation()
        guard verified.id == videoID, verified.channelID == channelID,
              verified.duration.isFinite, verified.duration > 0 else {
            throw Failure.verificationFailed
        }

        // One muxed progressive stream is essential. DASH's separate video
        // and audio URLs are not directly playable by one AVPlayer URL.
        // -g prints a signed CDN URL to the private stdout capture; it does
        // not download, merge or even create a media file.
        let stdout: Data
        do {
            stdout = try await invoke([
                "--no-playlist", "--skip-download", "-g",
                "-f", "b[ext=mp4][vcodec^=avc1][acodec^=mp4a]",
                verified.url.absoluteString
            ], timeout: 90)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // yt-dlp stderr may contain a signed CDN URL, so deliberately
            // avoid forwarding its raw localized description to the UI/logs.
            throw Failure.streamUnavailable
        }
        try Task.checkCancellation()
        guard !stdout.isEmpty else { throw Failure.streamUnavailable }
        guard stdout.count <= 16_384,
              let output = String(data: stdout, encoding: .utf8) else {
            throw Failure.unsafeStreamURL
        }
        let urls = output.split(whereSeparator: \.isNewline)
        guard urls.count == 1 else { throw Failure.streamUnavailable }
        guard let stream = validatedProgressiveStreamURL(String(urls[0])) else {
            throw Failure.unsafeStreamURL
        }
        return (stream, verified.duration, verified.chapters)
    }

    /// Pure URL gate used for every yt-dlp -g result. No guessed redirects,
    /// relative URLs, DASH/HLS manifests, non-Google hosts or stale signed
    /// links may be handed to AVPlayer.
    static func validatedProgressiveStreamURL(_ raw: String, now: Date = Date()) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count <= 16_384,
              let parts = URLComponents(string: trimmed),
              parts.scheme?.lowercased() == "https",
              let host = parts.host?.lowercased(),
              host == "googlevideo.com" || host.hasSuffix(".googlevideo.com"),
              parts.user == nil, parts.password == nil, parts.port == nil,
              parts.fragment == nil, parts.path == "/videoplayback",
              let expiryRaw = parts.queryItems?.first(where: { $0.name == "expire" })?.value,
              let expiry = TimeInterval(expiryRaw),
              expiry.isFinite, expiry > now.timeIntervalSince1970 + 90,
              let url = parts.url else { return nil }
        return url
    }

    /// Restrict thumbnail URLs to the exact verified video's image. yt-dlp's
    /// own `thumbnail` may vary by client, so fall back to YouTube's canonical
    /// hqdefault image for that same verified ID when its URL is absent/invalid.
    static func verifiedThumbnailURL(from metadata: [String: Any], videoID: String) -> String? {
        guard validVideoID(videoID) else { return nil }
        let direct = metadata["thumbnail"] as? String
        let listed = Array(((metadata["thumbnails"] as? [[String: Any]])?
            .compactMap { $0["url"] as? String } ?? []).reversed())
        for value in ([direct].compactMap { $0 } + listed) {
            guard value.utf8.count < 2048, let components = URLComponents(string: value),
                  components.scheme?.lowercased() == "https", components.user == nil,
                  components.password == nil, components.port == nil,
                  let host = components.host?.lowercased(),
                  host == "i.ytimg.com" || host == "img.youtube.com" ||
                  host.range(of: #"^i[0-9]\.ytimg\.com$"#, options: .regularExpression) != nil else { continue }
            let pieces = components.path.split(separator: "/")
            guard pieces.count == 3, ["vi", "vi_webp"].contains(String(pieces[0])),
                  pieces[1] == videoID,
                  ["jpg", "jpeg", "png", "webp"].contains((String(pieces[2]) as NSString).pathExtension.lowercased())
            else { continue }
            return value
        }
        return "https://i.ytimg.com/vi/\(videoID)/hqdefault.jpg"
    }

    /// Re-fetch chapters for an already downloaded or otherwise known YouTube recording.
    /// Channel identity is verified again, so metadata from an unrelated upload is rejected.
    static func chapters(videoID: String, channelID: String) async throws -> [VideoChapter] {
        try await verifiedVideoCache.resolve(id: videoID, channelID: channelID) {
            try await verifyVideo(id: videoID, channelID: channelID)
        }.chapters
    }

    /// Fetch genuine YouTube VTT for the *selected recording*, not the RSS file.
    /// `match` verifies the official uploader, unique title/duration and date
    /// again, so a stale youtubeID or unrelated 11-character ID cannot supply text.
    /// A missing, malformed or unavailable subtitle returns nil for local ASR.
    static func captions(episode: Episode, channelURL: String, videoID: String,
                         language: String?, duration: Double) async throws -> [TranscriptLine]? {
        guard validVideoID(videoID), duration.isFinite, duration > 0,
              let language = captionLanguage(language) else { return nil }
        try Task.checkCancellation()
        guard let verified = try await match(episode: episode, channelURL: channelURL),
              verified.id == videoID,
              abs(verified.duration - duration) <= max(3, min(20, duration * 0.01)) else { return nil }
        let key = "\(verified.channelID):\(videoID):\(language)"
        if let cached = await captionCache.lookup(key) { return cached.lines }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PodCraft-verified-captions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        // Prefer human-authored captions; use YouTube's original-language auto
        // track before a potentially machine-translated automatic track.
        let attempts: [(automatic: Bool, language: String)] = [
            (false, language), (true, "\(language)-orig"), (true, language)
        ]
        for (attempt, request) in attempts.enumerated() {
            try Task.checkCancellation()
            let stage = directory.appendingPathComponent("attempt-\(attempt)", isDirectory: true)
            try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
            do {
                let output = stage.appendingPathComponent("%(id)s.%(ext)s").path
                _ = try await invoke([
                    "--no-playlist", "--skip-download", "--no-progress", "--no-mtime",
                    "--socket-timeout", "15", "--write-info-json",
                    request.automatic ? "--write-auto-subs" : "--write-subs",
                    "--sub-langs", request.language, "--sub-format", "vtt",
                    "--output", output, "https://www.youtube.com/watch?v=\(videoID)"
                ], timeout: 65)
                try Task.checkCancellation()
                // An additional identity check on the metadata emitted by THIS
                // subtitle request prevents using an unrelated extractor result.
                let info = stage.appendingPathComponent("\(videoID).info.json")
                guard let data = try? Data(contentsOf: info), data.count < 8_000_000,
                      let metadata = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      metadata["id"] as? String == videoID,
                      metadata["channel_id"] as? String == verified.channelID else { continue }
                let file = stage.appendingPathComponent("\(videoID).\(request.language).vtt")
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
                      let bytes = attrs[.size] as? NSNumber, bytes.intValue > 0,
                      bytes.intValue <= 8_000_000,
                      let vtt = try? Data(contentsOf: file),
                      let parsed = parseVTT(vtt, duration: verified.duration), !parsed.isEmpty else { continue }
                await captionCache.store(key, lines: parsed, ttl: 6 * 3600)
                return parsed
            } catch is CancellationError { throw CancellationError() }
            catch {
                try Task.checkCancellation()
                // A 429 response means YouTube is rate-limiting subtitle
                // downloads. Do not retry other languages immediately.
                if error.localizedDescription.contains("429") { break }
            }
        }
        await captionCache.store(key, lines: nil, ttl: 15 * 60)
        return nil
    }

    /// Restrict yt-dlp subtitle selection to a single language from RSS/show
    /// metadata. Never request "all" or a wildcard translation catalog.
    private static func captionLanguage(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let base = raw.lowercased().split(separator: "-", maxSplits: 1).first.map(String.init) ?? ""
        return base.range(of: #"^[a-z]{2,3}$"#, options: .regularExpression) != nil ? base : nil
    }

    /// Decode source-time WebVTT cues. YouTube's automatic captions frequently
    /// repeat rolling windows; merge duplicate/prefix cues and remove repeated
    /// suffix/prefix words while preserving the original media clock.
    static func parseVTT(_ data: Data, duration: Double) -> [TranscriptLine]? {
        guard data.count <= 8_000_000, duration > 0, duration.isFinite,
              var raw = String(data: data, encoding: .utf8) else { return nil }
        raw = raw.replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        guard raw.hasPrefix("WEBVTT") else { return nil }
        var cues: [TranscriptLine] = []
        let blocks = raw.components(separatedBy: "\n\n")
        guard blocks.count <= 60_000 else { return nil }
        for block in blocks.dropFirst() {
            let rows = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let timeIndex = rows.firstIndex(where: { $0.contains("-->") }),
                  timeIndex + 1 < rows.count else { continue }
            let timing = rows[timeIndex].components(separatedBy: "-->")
            guard timing.count == 2,
                  let start = vttSeconds(timing[0]),
                  let end = vttSeconds(timing[1].split(separator: " ").first.map(String.init) ?? ""),
                  end > start, start < duration, end <= duration + 10 else { continue }
            let clean = rows[(timeIndex+1)...].joined(separator: " ")
                .replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"(?:^|\s)>>\s*"#, with: " ", options: .regularExpression)
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&#39;", with: "'")
                .replacingOccurrences(of: "&nbsp;", with: " ")
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, clean.count <= 1500 else { continue }
            cues.append(TranscriptLine(start: start, end: min(end, duration), text: clean))
        }
        cues.sort { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
        var result: [TranscriptLine] = []
        for cue in cues {
            guard let previous = result.last else { result.append(cue); continue }
            let sharedWindow = cue.start <= previous.end + 0.75
            if sharedWindow && (cue.text == previous.text || previous.text.contains(cue.text)) {
                result[result.count-1].end = max(previous.end, cue.end)
                continue
            }
            if sharedWindow && cue.text.hasPrefix(previous.text) {
                result[result.count-1].text = cue.text
                result[result.count-1].end = max(previous.end, cue.end)
                continue
            }
            var next = cue
            if sharedWindow {
                let a = previous.text.split(separator: " ")
                let b = cue.text.split(separator: " ")
                let maxWords = min(24, a.count, b.count)
                for count in stride(from: maxWords, through: 1, by: -1) {
                    if a.suffix(count).elementsEqual(b.prefix(count)) {
                        next.text = b.dropFirst(count).joined(separator: " ")
                        break
                    }
                }
                next.start = max(previous.end, next.start)
            }
            if !next.text.isEmpty && next.end > next.start { result.append(next) }
        }
        // Reject error pages, accidental partial captions and absurdly sparse
        // tracks rather than silently claiming a full recording was captioned.
        guard result.count >= 3, (result.last?.end ?? 0) >= min(duration * 0.15, 120) else { return nil }
        // Group rolling caption fragments into the same readable timed
        // paragraphs used for locally recognized speech.
        return AIService.sentences(result)
    }

    private static func vttSeconds(_ raw: String) -> Double? {
        let parts = raw.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard parts.count == 2 || parts.count == 3,
              let seconds = Double(parts.last ?? ""), seconds >= 0, seconds < 60,
              let minutes = Int(parts[parts.count-2]), minutes >= 0, minutes < 60 else { return nil }
        let hours = parts.count == 3 ? Int(parts[0]) : 0
        guard let hours, hours >= 0, hours < 100 else { return nil }
        return Double(hours * 3600 + minutes * 60) + seconds
    }

    /// Pure parser shared with verified video metadata and offline chapter regression tests.
    /// Ignores malformed/out-of-range timestamps; never invents chapter titles or durations.
    static func decodeChapters(from metadata: [String: Any], duration: Double) -> [VideoChapter] {
        guard duration.isFinite, duration > 0,
              let rows = metadata["chapters"] as? [[String: Any]], !rows.isEmpty else {
            return []
        }
        let raw = rows.compactMap { row -> (start: Double, end: Double?, title: String)? in
            guard let start = (row["start_time"] as? NSNumber)?.doubleValue,
                  start.isFinite, start >= 0, start < duration,
                  let label = row["title"] as? String else { return nil }
            let title = AIService.sanitizeChapterTitle(label)
            guard !title.isEmpty else { return nil }
            let end = (row["end_time"] as? NSNumber)?.doubleValue
            return (start, end?.isFinite == true ? end : nil, title)
        }.sorted { $0.start < $1.start }
        var result: [VideoChapter] = []
        for (index, current) in raw.enumerated() {
            // yt-dlp usually provides end_time; if it doesn't, the next start or the
            // recording duration is the only defensible upper bound.
            let next = index + 1 < raw.count ? raw[index + 1].start : duration
            let end = min(duration, next, current.end ?? next)
            guard end > current.start + 0.01 else { continue }
            if let prior = result.last, current.start < prior.end - 0.01 { continue }
            result.append(VideoChapter(start: current.start, end: end, title: current.title))
        }
        return result
    }

    static func decodeChapters(from data: Data) throws -> [VideoChapter] {
        guard let item = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let duration = (item["duration"] as? NSNumber)?.doubleValue else {
            throw Failure.invalidResponse
        }
        return decodeChapters(from: item, duration: duration)
    }

    private static func parseDate(_ raw: String?) -> Date? {
        guard let raw, raw.count == 8 else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyyMMdd"
        return f.date(from: raw)
    }

    static func normalizedTitle(_ raw: String) -> String {
        var s = raw.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
        // Common RSS show numbering: "[#203] Title | Show", "143: Title",
        // "T14x11 | Title" and "#393 - Guest". Keep internal serial tokens for
        // cross-language episode identification; remove only bare leading counters.
        s = s.replacingOccurrences(of: #"^\s*\[\s*#?\d{1,4}\s*\]\s*"#,
                                 with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"^(?:episode|ep|capitulo|capitulo nº|chapter)?\s*#?\s*\d{1,4}\s*[:.|\-–]\s*"#,
                                 with: "", options: .regularExpression)
        return s.replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: " ",
                                      options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func titleSimilarity(_ a: String, _ b: String) -> Double {
        if a == b { return 1 }
        let aa = Set(a.split(separator: " ")), bb = Set(b.split(separator: " "))
        guard !aa.isEmpty, !bb.isEmpty else { return 0 }
        let common = aa.intersection(bb).count
        // When YouTube appends "| Show Name" to a complete episode title, every
        // significant token of the shorter title still matches. Require at least
        // four tokens to avoid matching generic "Bonus"/"Patreon Bonus" episodes.
        if min(aa.count, bb.count) >= 4 && common == min(aa.count, bb.count) {
            return 0.97
        }
        // Podcast serial IDs are a language-neutral bridge when a platform has
        // translated the description (e.g. Spanish RSS vs English YouTube title).
        // Two other shared words and close duration remain mandatory.
        if let aNumber = episodeSerial(a), let bNumber = episodeSerial(b),
           aNumber == bNumber, common >= 3 { return 0.96 }
        return Double(common) / Double(aa.union(bb).count)
    }

    /// A few channels abbreviate the episode's description in their flat `/videos`
    /// listing (e.g. guest name only) while RSS has an extended subtitle. Matching
    /// a true *episode serial* plus TWO shared words after that serial, together
    /// with exact channel identity and duration validation, is safer than lowering
    /// the global similarity threshold. Ordinary dates or numbers without an
    /// explicit #episode or season×episode marker do not qualify.
    private static func matchingSerialAndSubject(_ rss: String, _ youtube: String) -> Bool {
        let pattern = #"(?i)(?:#\s*\d{2,4}\b|\bt?\d{1,2}x\d{1,2}\b)"#
        guard let a = rss.range(of: pattern, options: .regularExpression),
              let b = youtube.range(of: pattern, options: .regularExpression) else { return false }
        let serialA = rss[a].lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "t", with: "")
        let serialB = youtube[b].lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "t", with: "")
        guard serialA == serialB else { return false }
        let tailA = Set(normalizedTitle(String(rss[a.upperBound...])).split(separator: " ")
            .filter { $0.count >= 3 })
        let tailB = Set(normalizedTitle(String(youtube[b.upperBound...])).split(separator: " ")
            .filter { $0.count >= 3 })
        return tailA.intersection(tailB).count >= 2
    }

    private static func episodeSerial(_ title: String) -> String? {
        guard let range = title.range(of: #"(?i)(?:\bt?\d{1,2}x\d{1,2}\b|#\d{2,4}\b)"#,
                                      options: .regularExpression) else { return nil }
        return title[range].lowercased().replacingOccurrences(of: "t", with: "")
            .replacingOccurrences(of: "#", with: "")
    }

    private static func validVideoID(_ id: String) -> Bool {
        id.range(of: #"^[A-Za-z0-9_-]{11}$"#, options: .regularExpression) != nil
    }

    /// Collect CLI output into temporary files so large JSON responses never deadlock a pipe.
    /// Cancellation uses the child's PID, not captured non-Sendable Foundation objects.
    private static func invoke(_ arguments: [String], timeout: Double) async throws -> Data {
        guard let cli = executable else { throw Failure.unavailable }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PodCraft-yt-dlp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let out = directory.appendingPathComponent("stdout")
        let err = directory.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: out.path, contents: Data())
        FileManager.default.createFile(atPath: err.path, contents: Data())
        let outHandle = try FileHandle(forWritingTo: out)
        let errHandle = try FileHandle(forWritingTo: err)
        defer { try? outHandle.close(); try? errHandle.close() }
        let process = Process()
        process.executableURL = cli
        // Finder-launched macOS apps rarely inherit Homebrew's PATH. yt-dlp's
        // progressive MP4→M4A extraction needs *both* ffmpeg and ffprobe even
        // when its own executable was found via an absolute path.
        var environment = ProcessInfo.processInfo.environment
        // Release packaging ships a signed LGPL helper pair here. The CLI
        // debug build has no .app bundle and falls back to system/Homebrew.
        let bundledHelpers = Bundle.main.bundleURL.appendingPathComponent(
            "Contents/Helpers", isDirectory: true).path
        let toolPaths = [bundledHelpers, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        environment["PATH"] = (toolPaths + [(environment["PATH"] ?? "")]).joined(separator: ":")
        process.environment = environment
        let ffmpegPath = toolPaths.first(where: {
            FileManager.default.isExecutableFile(atPath: "\($0)/ffmpeg") &&
            FileManager.default.isExecutableFile(atPath: "\($0)/ffprobe")
        })
        let ffmpegOptions = ffmpegPath.map { ["--ffmpeg-location", $0] } ?? []
        process.arguments = ["--ignore-config", "--no-update", "--no-warnings"] +
            ffmpegOptions + arguments
        process.standardOutput = outHandle
        process.standardError = errHandle
        let termination = YouTubeTermination()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let timer = Task.detached {
                do { try await Task.sleep(for: .seconds(timeout)) }
                catch { return }  // cancelling a completed operation must not kill a reused PID
                await termination.stop()
            }
            defer { timer.cancel() }
            let status = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
                process.terminationHandler = { child in
                    continuation.resume(returning: child.terminationStatus)
                }
                do {
                    try process.run()
                    let pid = process.processIdentifier
                    Task { await termination.started(pid: pid) }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            await termination.finished()
            try Task.checkCancellation()
            if status != 0 {
                let reason = (try? String(contentsOf: err, encoding: .utf8)) ?? "yt-dlp exited \(status)"
                throw Failure.downloadFailed(String(reason.suffix(500)))
            }
            return try Data(contentsOf: out)
        } onCancel: {
            Task { await termination.stop() }
        }
    }
}

private actor YouTubeTermination {
    private var pid: pid_t?
    private var cancelled = false
    private var completed = false

    func started(pid: pid_t) {
        guard !completed else { return }
        self.pid = pid
        if cancelled { _ = Darwin.kill(pid, SIGTERM) }
    }

    func stop() {
        guard !completed else { return }
        cancelled = true
        if let pid { _ = Darwin.kill(pid, SIGTERM) }
    }

    func finished() {
        completed = true
        pid = nil
    }
}

/// Small in-memory cache; failed/429 caption downloads are remembered briefly
/// so playback and re-analysis do not create a subtitle request storm.
private actor VerifiedCaptionCache {
    struct Entry {
        let lines: [TranscriptLine]?
        let expires: Date
    }
    private var entries: [String: Entry] = [:]

    func lookup(_ key: String) -> Entry? {
        guard let value = entries[key], value.expires > Date() else {
            entries.removeValue(forKey: key)
            return nil
        }
        return value
    }

    func store(_ key: String, lines: [TranscriptLine]?, ttl: TimeInterval) {
        entries[key] = Entry(lines: lines, expires: Date().addingTimeInterval(ttl))
        if entries.count > 64 {
            entries = entries.filter { $0.value.expires > Date() }
            if entries.count > 64,
               let oldest = entries.min(by: { $0.value.expires < $1.value.expires })?.key {
                entries.removeValue(forKey: oldest)
            }
        }
    }
}

private actor ChannelIndexCache {
    private struct Key: Hashable {
        let url: URL
        let limit: Int
    }
    private struct Entry {
        var index: YouTubeSource.Index
        var expires: Date
    }
    private var entries: [Key: Entry] = [:]
    private var inFlight: [Key: Task<YouTubeSource.Index, Error>] = [:]

    func resolve(_ url: URL, limit: Int,
                 load: @escaping @Sendable () async throws -> YouTubeSource.Index) async throws -> YouTubeSource.Index {
        // A completed full-archive index safely satisfies a later request for
        // just the recent window. The reverse must not silently truncate.
        if let larger = entries
            .filter({ $0.key.url == url && $0.key.limit >= limit && $0.value.expires > Date() })
            .max(by: { $0.key.limit < $1.key.limit }) {
            return larger.value.index
        }
        let key = Key(url: url, limit: limit)
        let pending: Task<YouTubeSource.Index, Error>
        if let existing = inFlight[key] {
            pending = existing
        } else {
            pending = Task.detached(priority: .utility) { try await load() }
            inFlight[key] = pending
        }
        do {
            let decoded = try await pending.value
            entries[key] = Entry(index: decoded, expires: Date().addingTimeInterval(600))
            inFlight.removeValue(forKey: key)
            try Task.checkCancellation()
            return decoded
        } catch {
            inFlight.removeValue(forKey: key)
            throw error
        }
    }
}

private actor ChannelDiscoveryCache {
    private struct Entry {
        let index: YouTubeSource.Index?
        let expires: Date
    }
    private var entries: [String: Entry] = [:]

    /// Optional-optional distinguishes "not cached" from a cached safe no-match result.
    func lookup(_ key: String) -> YouTubeSource.Index?? {
        guard let entry = entries[key], entry.expires > Date() else {
            entries.removeValue(forKey: key)
            return nil
        }
        return .some(entry.index)
    }

    func store(_ key: String, index: YouTubeSource.Index?) {
        entries[key] = Entry(index: index, expires: Date().addingTimeInterval(600))
    }
}

/// A watch-page verification is expensive (a yt-dlp subprocess). Share the
/// result between artwork, playback and download requests for the same video.
/// The exact channel ID is part of the cache key and is rechecked in verifyVideo.
private actor VerifiedVideoCache {
    private struct Entry {
        let video: YouTubeSource.Video
        let expires: Date
    }
    private var stored: [String: Entry] = [:]
    private var inFlight: [String: Task<YouTubeSource.Video, Error>] = [:]

    func resolve(id: String, channelID: String,
                 verify: @escaping @Sendable () async throws -> YouTubeSource.Video) async throws -> YouTubeSource.Video {
        let key = "\(channelID):\(id)"
        if let cached = stored[key], cached.expires > Date() { return cached.video }
        let verification: Task<YouTubeSource.Video, Error>
        if let existing = inFlight[key] {
            verification = existing
        } else {
            verification = Task.detached(priority: .utility) { try await verify() }
            inFlight[key] = verification
        }
        do {
            let value = try await verification.value
            stored[key] = Entry(video: value, expires: Date().addingTimeInterval(3600))
            inFlight.removeValue(forKey: key)
            if stored.count > 128 {
                stored = stored.filter { $0.value.expires > Date() }
                if stored.count > 128, let oldest = stored.min(by: { $0.value.expires < $1.value.expires })?.key {
                    stored.removeValue(forKey: oldest)
                }
            }
            try Task.checkCancellation()
            return value
        } catch {
            // A consumer cancelling cannot cancel the shared detached task.
            // Once it has completed, release the entry so retries are possible.
            inFlight.removeValue(forKey: key)
            throw error
        }
    }
}
