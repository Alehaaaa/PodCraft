import Foundation

/// Reads a podcast RSS feed and searches the public podcast directory,
/// like the original's "Add a show: search or paste a link".
enum FeedFetcher {
    struct Item: Sendable {
        var title: String
        var summary: String
        var published: Date
        var duration: Double
        var audioURL: String?
        var guid: String?
        var isVideo: Bool
        var link: String? = nil
        var artwork: String? = nil
        /// The episode's own language tag (dc:language / language), when the feed gives one.
        var language: String? = nil

        func episode(showID: UUID) -> Episode {
            var e = Episode(showID: showID, title: title, summary: summary, published: published, addedAt: Date(),
                            duration: duration, audioURL: audioURL, guid: guid ?? audioURL ?? title, isVideo: isVideo)
            e.link = link
            e.artworkURL = artwork
            e.language = language
            e.youtubeID = [link, guid, audioURL].compactMap { $0 }.lazy.compactMap { SponsorBlock.videoID(from: $0) }.first
            return e
        }
    }

    struct Parsed: Sendable {
        var title = ""
        var author = ""
        var summary = ""
        var artwork: String?
        /// The show's language from the channel's <language> tag ("es-ES").
        var language: String?
        var items: [Item] = []
    }

    struct SearchResult: Identifiable, Hashable, Codable, Sendable {
        var id: String { feedURL }
        var title: String
        var author: String
        var feedURL: String
        var artwork: String?
        var storeURL: String? = nil
    }

    enum FetchError: LocalizedError {
        case noFeed
        case badResponse(Int)
        var errorDescription: String? {
            switch self {
            case .noFeed:
                "No podcast feed found at this link. Type the show’s name instead, or paste its RSS link."
            case .badResponse(let status):
                "The podcast server returned HTTP \(status). Try again later."
            }
        }
    }

    private static func checkedData(from url: URL, session: URLSession) async throws -> Data {
        guard url.scheme == "http" || url.scheme == "https" else { throw URLError(.unsupportedURL) }
        do {
            return try await NetworkClient.data(from: url, session: session, limit: 25 * 1_048_576).0
        } catch NetworkClient.Failure.http(let status) {
            throw FetchError.badResponse(status)
        }
    }

    static func looksLikeLink(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        return t.hasPrefix("http://") || t.hasPrefix("https://") || t.hasPrefix("feed:") || t.contains(".xml") || t.contains("/rss")
    }

    static func fetch(_ url: URL) async throws -> Parsed {
        var u = url
        if u.scheme == "feed", let fixed = URL(string: url.absoluteString.replacingOccurrences(of: "feed:", with: "https:")) { u = fixed }
        let data = try await checkedData(from: u, session: feedSession)
        try Task.checkCancellation()
        // Feed XML can contain hundreds of episodes; parse it away from the SwiftUI/main actor.
        let parsed = await Task.detached(priority: .userInitiated) {
            RSSParser(data: data).parse()
        }.value
        try Task.checkCancellation()
        guard let parsed, !parsed.title.isEmpty else { throw FetchError.noFeed }
        return parsed
    }

    static func search(_ term: String) async throws -> [SearchResult] {
        var comps = URLComponents(string: "https://itunes.apple.com/search")!
        comps.queryItems = [.init(name: "media", value: "podcast"), .init(name: "entity", value: "podcast"),
                            .init(name: "limit", value: "20"), .init(name: "term", value: term)]
        let data = try await checkedData(from: comps.url!, session: quick)
        try Task.checkCancellation()
        struct Resp: Decodable { var results: [R] }
        struct R: Decodable { var collectionName: String?; var artistName: String?; var feedUrl: String?; var artworkUrl600: String? }
        let resp = try JSONDecoder().decode(Resp.self, from: data)
        let results: [SearchResult] = resp.results.compactMap { r -> SearchResult? in
            guard let f = r.feedUrl else { return nil }
            return SearchResult(title: r.collectionName ?? "Untitled", author: r.artistName ?? "", feedURL: f, artwork: r.artworkUrl600)
        }
        return deduplicated(results)
    }

    /// Apple's storefront podcast chart, resolved through the public lookup API
    /// so every discovery tile still has a real RSS URL that PodCraft can add.
    /// A session that gives up quickly, so the New page never hangs on a slow chart server.
    static let quick = NetworkClient.metadata

    /// RSS feeds may be much larger than directory responses; give them a separate time budget.
    static let feedSession = NetworkClient.feeds

    static func topPodcasts(country: String = (Locale.current.region?.identifier ?? "US").lowercased(),
                            limit: Int = 25) async throws -> [SearchResult] {
        let chartURL = URL(string: "https://rss.marketingtools.apple.com/api/v2/\(country)/podcasts/top/\(limit)/podcasts.json")!
        let chartData = try await checkedData(from: chartURL, session: quick)
        try Task.checkCancellation()
        struct Chart: Decodable { var feed: ChartFeed }
        struct ChartFeed: Decodable { var results: [ChartItem] }
        struct ChartItem: Decodable { var id: String; var name: String; var artistName: String; var artworkUrl100: String; var url: String }
        let chart = try JSONDecoder().decode(Chart.self, from: chartData)
        guard !chart.feed.results.isEmpty else { return [] }

        var lookup = URLComponents(string: "https://itunes.apple.com/lookup")!
        lookup.queryItems = [.init(name: "id", value: chart.feed.results.map(\.id).joined(separator: ",")),
                             .init(name: "entity", value: "podcast")]
        lookup.queryItems?.append(.init(name: "country", value: country))
        let lookupData = try await checkedData(from: lookup.url!, session: quick)
        try Task.checkCancellation()
        struct Lookup: Decodable { var results: [LookupItem] }
        struct LookupItem: Decodable { var collectionId: Int?; var feedUrl: String?; var artworkUrl600: String?; var collectionViewUrl: String? }
        let resolved = try JSONDecoder().decode(Lookup.self, from: lookupData)
        let records = resolved.results.compactMap { item -> (String, LookupItem)? in
            guard let id = item.collectionId else { return nil }
            return (String(id), item)
        }
        // Directory lookups can include duplicate IDs; prefer the entry with an RSS URL.
        var byID: [String: LookupItem] = [:]
        for (id, item) in records where byID[id]?.feedUrl == nil { byID[id] = item }
        return chart.feed.results.compactMap { item in
            guard let found = byID[item.id], let feed = found.feedUrl else { return nil }
            return SearchResult(title: item.name, author: item.artistName, feedURL: feed,
                                artwork: found.artworkUrl600 ?? item.artworkUrl100,
                                storeURL: found.collectionViewUrl ?? item.url)
        }
    }

    static func parseDuration(_ s: String) -> Double {
        let pieces = s.split(separator: ":")
        guard (1...3).contains(pieces.count) else { return 0 }
        let parts = pieces.compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == pieces.count, parts.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return 0 }
        let duration = parts.reduce(0) { $0 * 60 + $1 }
        return duration.isFinite ? duration : 0
    }

    /// Directory APIs occasionally return the same feed more than once with
    /// cosmetic URL differences. Keep ordering while presenting one add target.
    static func deduplicated(_ results: [SearchResult]) -> [SearchResult] {
        var seen = Set<String>()
        return results.filter { result in
            let key = result.feedURL.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased().replacingOccurrences(of: "http://", with: "https://")
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return !key.isEmpty && seen.insert(key).inserted
        }
    }

    static let rfc822: [DateFormatter] = ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm:ss Z",
                                          "EEE, dd MMM yyyy HH:mm:ss zzz", "dd MMM yyyy HH:mm:ss Z"].map {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = $0
        return f
    }

    static func parseDate(_ s: String) -> Date {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        for f in rfc822 { if let d = f.date(from: t) { return d } }
        return Date()
    }
}

private final class RSSParser: NSObject, XMLParserDelegate {
    let parser: XMLParser
    var result = FeedFetcher.Parsed()
    var current: FeedFetcher.Item?
    var text = ""
    var inItem = false

    init(data: Data) {
        parser = XMLParser(data: data)
        super.init()
        parser.delegate = self
    }

    func parse() -> FeedFetcher.Parsed? { parser.parse() ? result : nil }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        text = ""
        switch name {
        case "item", "entry":
            inItem = true
            current = .init(title: "", summary: "", published: Date(), duration: 0, audioURL: nil, guid: nil, isVideo: false)
        case "enclosure":
            if inItem {
                selectMedia(attributes["url"], type: attributes["type"])
            }
        case "link":
            if inItem {
                let rel = attributes["rel"]?.lowercased()
                if rel == "enclosure" { selectMedia(attributes["href"], type: attributes["type"]) }
                else if (rel == nil || rel == "alternate"), current?.link == nil {
                    current?.link = attributes["href"]
                }
            }
        case "itunes:image":
            if inItem { current?.artwork = attributes["href"] }
            else if result.artwork == nil { result.artwork = attributes["href"] }
        default: break
        }
    }

    /// Keep the first valid media enclosure. Some feeds include an image or a
    /// second enclosure after the playable audio, which must not replace it.
    private func selectMedia(_ raw: String?, type: String?) {
        guard current?.audioURL == nil, let raw, let url = URL(string: raw),
              ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return }
        let mime = (type ?? "").lowercased()
        guard mime.isEmpty || mime.hasPrefix("audio/") || mime.hasPrefix("video/") ||
              mime == "application/octet-stream" else { return }
        current?.audioURL = raw
        current?.isVideo = mime.hasPrefix("video/") ||
            Mechanics.videoExtensions.contains(url.pathExtension.lowercased())
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        text += String(data: CDATABlock, encoding: .utf8) ?? ""
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if inItem {
            switch name {
            case "title": current?.title = t
            case "description", "itunes:summary", "summary", "content":
                if current?.summary.isEmpty ?? false { current?.summary = Self.strip(t) }
            case "pubDate", "published": current?.published = FeedFetcher.parseDate(t)
            case "itunes:duration": current?.duration = FeedFetcher.parseDuration(t)
            case "guid", "id": current?.guid = t
            case "link": if !t.isEmpty { current?.link = t }
            case "language", "dc:language": if !t.isEmpty { current?.language = t }
            case "item", "entry":
                if let c = current, c.audioURL != nil { result.items.append(c) }
                current = nil
                inItem = false
            default: break
            }
        } else {
            switch name {
            case "title": if result.title.isEmpty { result.title = t }
            case "itunes:author": if result.author.isEmpty { result.author = t }
            case "description": if result.summary.isEmpty { result.summary = Self.strip(t) }
            case "language", "dc:language": if result.language == nil, !t.isEmpty { result.language = t }
            default: break
            }
        }
        text = ""
    }

    static func strip(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }
}
