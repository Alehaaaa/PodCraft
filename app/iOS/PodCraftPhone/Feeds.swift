import Foundation

// MARK: - Reading feeds

enum FeedError: LocalizedError {
    case notAFeed, http(Int)
    var errorDescription: String? {
        switch self {
        case .notAFeed: "That address isn’t a podcast feed."
        case .http(let code): "The feed answered with an error (\(code))."
        }
    }
}

enum FeedReader {
    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 20
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    /// Accepts "example.com/feed", "feed://…", "podcast://…" and plain https addresses.
    static func normalize(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        for scheme in ["feed://", "podcast://", "pcast://", "itpc://"] where s.lowercased().hasPrefix(scheme) {
            s = "https://" + s.dropFirst(scheme.count)
        }
        if !s.contains("://") { s = "https://" + s }
        guard let url = URL(string: s), url.host != nil else { return nil }
        return url
    }

    static func fetch(_ url: URL, id: String) async throws -> RemoteShow {
        var request = URLRequest(url: url)
        request.setValue("PodCraft/1.0 (iPhone)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        if let code = (response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(code) { throw FeedError.http(code) }
        return try await Task.detached(priority: .utility) { try FeedReader.parse(data, id: id) }.value
    }

    static func parse(_ data: Data, id: String) throws -> RemoteShow {
        let parser = RSSParser()
        let xml = XMLParser(data: data)
        xml.shouldProcessNamespaces = false
        xml.delegate = parser
        xml.parse()
        guard parser.sawChannel else { throw FeedError.notAFeed }
        let showArt = parser.channel.image.flatMap(URL.init(string:))
        let episodes: [RemoteEpisode] = parser.items.compactMap { item in
            let raw = item.enclosure?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let media = raw.flatMap(URL.init(string:)),
                  let episodeID = SyncIDs.episode(showID: id, guid: item.guid, media: raw) else { return nil }
            return RemoteEpisode(
                id: episodeID,
                showID: id,
                title: item.title.trimmingCharacters(in: .whitespacesAndNewlines),
                summary: item.summary,
                published: RSSDate.parse(item.pubDate) ?? .distantPast,
                duration: RSSDate.duration(item.duration),
                position: 0,
                played: false,
                isVideo: item.type.hasPrefix("video"),
                media: media,
                artwork: item.image.flatMap(URL.init(string:)),
                hasTranscript: false,
                chapters: [],
                onMac: false
            )
        }
        .sorted { $0.published > $1.published }
        return RemoteShow(id: id,
                          title: parser.channel.title.trimmingCharacters(in: .whitespacesAndNewlines),
                          author: parser.channel.author.trimmingCharacters(in: .whitespacesAndNewlines),
                          summary: parser.channel.summary,
                          artwork: showArt,
                          episodes: episodes)
    }
}

private final class RSSParser: NSObject, XMLParserDelegate {
    struct Channel { var title = "", author = "", summary = "", image: String? }
    struct Item {
        var title = "", guid = "", summary = "", pubDate = "", duration = "", type = ""
        var enclosure: String?
        var image: String?
    }

    var channel = Channel()
    var items: [Item] = []
    var sawChannel = false
    private var current: Item?
    private var text = ""
    private var inImage = false

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        text = ""
        switch name {
        case "channel", "feed": sawChannel = true
        case "item", "entry": current = Item()
        case "image": inImage = current == nil
        case "enclosure":
            if current?.enclosure == nil, let url = attributes["url"] {
                current?.enclosure = url
                current?.type = attributes["type"] ?? ""
            }
        case "media:content":
            if current?.enclosure == nil, let url = attributes["url"],
               (attributes["type"] ?? attributes["medium"] ?? "").hasPrefix("audio") || (attributes["type"] ?? attributes["medium"] ?? "").hasPrefix("video") {
                current?.enclosure = url
                current?.type = attributes["type"] ?? attributes["medium"] ?? ""
            }
        case "itunes:image":
            if let href = attributes["href"] {
                if current != nil { current?.image = href } else if channel.image == nil || !inImage { channel.image = href }
            }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        text += String(decoding: CDATABlock, as: UTF8.self)
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if current != nil {
            switch name {
            case "title": current?.title = value
            case "guid", "id": current?.guid = value
            case "pubDate", "published", "dc:date": if current?.pubDate.isEmpty == true { current?.pubDate = value }
            case "itunes:duration": current?.duration = value
            case "description", "itunes:summary", "content:encoded", "summary":
                if (current?.summary.count ?? 0) < value.count { current?.summary = value }
            case "item", "entry":
                if let item = current { items.append(item) }
                current = nil
            default: break
            }
        } else {
            switch name {
            case "title": if !inImage, channel.title.isEmpty { channel.title = value }
            case "itunes:author", "author": if channel.author.isEmpty { channel.author = value }
            case "description", "itunes:summary", "subtitle":
                if channel.summary.count < value.count { channel.summary = value }
            case "url": if inImage, channel.image == nil, !value.isEmpty { channel.image = value }
            case "image": inImage = false
            default: break
            }
        }
        text = ""
    }
}

enum RSSDate {
    private static let formatters: [DateFormatter] = [
        "EEE, dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm:ss zzz", "EEE, d MMM yyyy HH:mm:ss Z",
        "EEE, dd MMM yyyy HH:mm Z", "dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy", "yyyy-MM-dd'T'HH:mm:ssZ",
    ].map {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = $0
        return f
    }

    static func parse(_ raw: String) -> Date? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        for f in formatters { if let d = f.date(from: s) { return d } }
        let iso = ISO8601DateFormatter()
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return iso.date(from: s)
    }

    /// "1:02:03", "62:03" or "3723".
    static func duration(_ raw: String) -> Double {
        let parts = raw.split(separator: ":").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        return parts.reduce(0) { $0 * 60 + $1 }
    }
}

// MARK: - Finding shows

/// Apple's public podcast directory (free, no key).
struct DirectoryResult: Decodable, Identifiable, Hashable {
    var collectionId: Int
    var collectionName: String
    var artistName: String?
    var feedUrl: String?
    var artworkUrl600: String?
    var id: Int { collectionId }
}

enum Directory {
    static func search(_ term: String) async -> [DirectoryResult] {
        var c = URLComponents(string: "https://itunes.apple.com/search")!
        c.queryItems = [.init(name: "media", value: "podcast"), .init(name: "entity", value: "podcast"),
                        .init(name: "limit", value: "30"), .init(name: "term", value: term)]
        guard let url = c.url, let (data, _) = try? await URLSession.shared.data(from: url) else { return [] }
        struct Page: Decodable { var results: [DirectoryResult] }
        return ((try? JSONDecoder().decode(Page.self, from: data))?.results ?? []).filter { $0.feedUrl != nil }
    }

    static func top() async -> [DirectoryResult] {
        let region = Locale.current.region?.identifier.lowercased() ?? "us"
        guard let url = URL(string: "https://itunes.apple.com/\(region)/rss/toppodcasts/limit=25/json"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = (json["feed"] as? [String: Any])?["entry"] as? [[String: Any]] else { return [] }
        let ids = entries.compactMap { (($0["id"] as? [String: Any])?["attributes"] as? [String: Any])?["im:id"] as? String }
        guard !ids.isEmpty, let lookup = URL(string: "https://itunes.apple.com/lookup?id=" + ids.joined(separator: ",")),
              let (more, _) = try? await URLSession.shared.data(from: lookup) else { return [] }
        struct Page: Decodable { var results: [DirectoryResult] }
        return ((try? JSONDecoder().decode(Page.self, from: more))?.results ?? []).filter { $0.feedUrl != nil }
    }
}
