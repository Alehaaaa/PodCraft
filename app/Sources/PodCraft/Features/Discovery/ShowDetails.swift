import Foundation
import SwiftUI

// Show details under the episode list (as in the Podcasts app): ratings & reviews, hosts and guests,
// and information. Gathered from the show's own feed (podcast:person, itunes tags) and Apple's public
// podcast directory. Shows added from a plain feed link are matched to their directory entry by feed address,
// or by title and author. Results are kept on disk so the page opens instantly next time.

struct ShowPerson: Codable, Hashable, Identifiable {
    var id: String { name.lowercased() + "|" + role.lowercased() }
    var name: String
    var role: String
    var image: String?
    var link: String?
    var appearances: Int = 1
}

struct ShowReview: Codable, Hashable, Identifiable {
    var id: String
    var author: String
    var title: String
    var body: String
    var rating: Int
    var date: Date?
}

struct ShowInfo: Codable {
    var appleID: Int?
    var appleURL: String?
    var genres: [String] = []
    var episodeCount: Int?
    var updated: Date?
    var explicit: Bool?
    var country: String?
    // Added when country was sourced from the feed's creator-location metadata.
    // Older caches have no version and may contain Apple's storefront country.
    var countryMetadataVersion: Int?
    var language: String?
    var website: String?
    var copyright: String?
    var owner: String?
    var people: [ShowPerson] = []
    var reviews: [ShowReview] = []
    var fetched = Date()

    var averageRating: Double? {
        guard !reviews.isEmpty else { return nil }
        return Double(reviews.map(\.rating).reduce(0, +)) / Double(reviews.count)
    }
}

@MainActor
@Observable
final class ShowInfoStore {
    static let shared = ShowInfoStore()
    var infos: [UUID: ShowInfo] = [:]
    var loading: Set<UUID> = []

    private var folder: URL {
        let url = Library.supportFolder.appendingPathComponent("ShowDetails", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private static let freshFor: TimeInterval = 24 * 3600
    private static let countryMetadataVersion = 1

    private static func safeInfo(_ cached: ShowInfo) -> ShowInfo {
        var info = cached
        if info.countryMetadataVersion != countryMetadataVersion { info.country = nil }
        return info
    }

    func info(for show: Show) -> ShowInfo? {
        if let i = infos[show.id] { return Self.safeInfo(i) }
        let file = folder.appendingPathComponent("\(show.id.uuidString).json")
        if let data = try? Data(contentsOf: file), let i = try? JSONDecoder().decode(ShowInfo.self, from: data) {
            infos[show.id] = i
            return Self.safeInfo(i)
        }
        return nil
    }

    func load(_ show: Show, force: Bool = false) async {
        if loading.contains(show.id) { return }
        if !force, let i = info(for: show), i.countryMetadataVersion == Self.countryMetadataVersion,
           Date().timeIntervalSince(i.fetched) < Self.freshFor { return }
        loading.insert(show.id)
        defer { loading.remove(show.id) }
        var info = ShowInfo()
        info.countryMetadataVersion = Self.countryMetadataVersion
        // 1. The show's own feed: people, language, website, copyright, owner, categories.
        if let link = show.feedURL, let url = URL(string: link),
           let (data, _) = try? await FeedFetcher.quick.data(from: url) {
            let parsed = FeedDetailsParser(data: data).parse()
            info.people = parsed.people
            info.language = parsed.language
            info.country = parsed.country
            info.website = parsed.website
            info.copyright = parsed.copyright
            info.owner = parsed.owner
            info.genres = parsed.categories
            info.explicit = parsed.explicit
            info.episodeCount = parsed.items
        }
        // Without podcast:person tags, the feed's author names are the hosts.
        // Several names are usually the hosts; a single one is often the studio, so it's shown as the creator.
        if info.people.isEmpty {
            let names = Self.splitNames(show.author)
            info.people = names.map { ShowPerson(name: $0, role: names.count > 1 ? "Host" : "Creator") }
        }
        // 2. Apple's directory entry (matched by feed address, then title and author).
        let storefront = LocationCountry.shared.current
        if let match = await Self.directoryMatch(for: show, country: storefront) {
            info.appleID = match.id
            info.appleURL = match.url
            if !match.genres.isEmpty { info.genres = match.genres.filter { $0 != "Podcasts" } }
            info.episodeCount = match.count ?? info.episodeCount
            info.updated = match.released
            if info.explicit == nil { info.explicit = match.explicit }
            // 3. Ratings & reviews from the directory.
            info.reviews = await Self.reviews(appleID: match.id, country: storefront)
        }
        info.fetched = Date()
        infos[show.id] = info
        if let data = try? JSONEncoder().encode(info) {
            try? data.write(to: folder.appendingPathComponent("\(show.id.uuidString).json"), options: .atomic)
        }
    }

    static func splitNames(_ text: String) -> [String] {
        text.replacingOccurrences(of: " and ", with: ",").replacingOccurrences(of: "&", with: ",")
            .replacingOccurrences(of: " y ", with: ",")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.count < 60 }
    }

    struct DirectoryMatch { var id: Int; var url: String?; var genres: [String]; var count: Int?; var released: Date?; var explicit: Bool? }

    static func normalize(_ link: String) -> String {
        var s = link.lowercased()
        for p in ["https://", "http://", "feed://", "www."] { if s.hasPrefix(p) { s.removeFirst(p.count) } }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// A title reduced to its words: lower case, no "[Premium]"/"(Ad-free)" tags, no punctuation.
    static func cleanTitle(_ t: String) -> String {
        t.lowercased()
            .replacingOccurrences(of: #"\[[^\]]*\]|\([^)]*\)"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"[^\p{L}\p{N} ]"#, with: " ", options: .regularExpression)
            .split(separator: " ").joined(separator: " ")
    }

    static func directoryMatch(for show: Show, country: String) async -> DirectoryMatch? {
        let title = cleanTitle(show.title)
        guard !title.isEmpty else { return nil }
        var comps = URLComponents(string: "https://itunes.apple.com/search")!
        comps.queryItems = [.init(name: "media", value: "podcast"), .init(name: "entity", value: "podcast"),
                            .init(name: "limit", value: "25"), .init(name: "term", value: title),
                            .init(name: "country", value: country)]
        guard let (data, _) = try? await FeedFetcher.quick.data(from: comps.url!),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = root["results"] as? [[String: Any]] else { return nil }
        let feed = show.feedURL.map(normalize)
        let authors = Set(splitNames(show.author).map { $0.lowercased() })
        func artistOverlaps(_ r: [String: Any]) -> Bool {
            guard let artist = (r["artistName"] as? String)?.lowercased(), !authors.isEmpty else { return true }
            return authors.contains { artist.contains($0) || $0.contains(artist) }
        }
        let byFeed = results.first { r in feed != nil && (r["feedUrl"] as? String).map(normalize) == feed }
        // A private or premium copy of a public show: same title once tags and punctuation are gone.
        let byName = results.first { r in (r["collectionName"] as? String).map(cleanTitle) == title && artistOverlaps(r) }
        let byPrefix = results.first { r in
            guard let n = (r["collectionName"] as? String).map(cleanTitle), !n.isEmpty else { return false }
            return (n.hasPrefix(title) || title.hasPrefix(n)) && artistOverlaps(r)
        }
        guard let r = byFeed ?? byName ?? byPrefix, let id = r["collectionId"] as? Int else { return nil }
        let iso = ISO8601DateFormatter()
        return DirectoryMatch(id: id, url: r["collectionViewUrl"] as? String,
                              genres: r["genres"] as? [String] ?? [],
                              count: r["trackCount"] as? Int,
                              released: (r["releaseDate"] as? String).flatMap { iso.date(from: $0) },
                              explicit: (r["collectionExplicitness"] as? String).map { $0 == "explicit" })
    }

    static func reviews(appleID: Int, country: String) async -> [ShowReview] {
        guard let url = URL(string: "https://itunes.apple.com/\(country)/rss/customerreviews/page=1/id=\(appleID)/sortby=mostrecent/json"),
              let (data, _) = try? await FeedFetcher.quick.data(from: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let feed = root["feed"] as? [String: Any] else { return [] }
        let entries: [[String: Any]] = (feed["entry"] as? [[String: Any]]) ?? ((feed["entry"] as? [String: Any]).map { [$0] } ?? [])
        func label(_ v: Any?) -> String? { (v as? [String: Any])?["label"] as? String }
        let iso = ISO8601DateFormatter()
        return entries.compactMap { e in
            guard let ratingText = label(e["im:rating"]), let rating = Int(ratingText) else { return nil }
            let author = label((e["author"] as? [String: Any])?["name"]) ?? "Listener"
            return ShowReview(id: label(e["id"]) ?? UUID().uuidString, author: author,
                              title: label(e["title"]) ?? "", body: label(e["content"]) ?? "",
                              rating: rating, date: label(e["updated"]).flatMap { iso.date(from: $0) })
        }
    }
}

/// Reads the channel-level details and the podcast:person tags (hosts on the channel; guests counted per episode).
private final class FeedDetailsParser: NSObject, XMLParserDelegate {
    struct Result {
        var people: [ShowPerson] = []
        var language: String?
        var country: String?
        var website: String?
        var copyright: String?
        var owner: String?
        var categories: [String] = []
        var explicit: Bool?
        var items = 0
    }
    private let parser: XMLParser
    private var result = Result()
    private var text = ""
    private var inItem = false
    private var inOwner = false
    private var personAttrs: [String: String] = [:]
    private var people: [String: ShowPerson] = [:]

    init(data: Data) {
        parser = XMLParser(data: data)
        super.init()
        parser.delegate = self
    }

    func parse() -> Result {
        parser.parse()
        result.people = people.values.sorted {
            let rank: (ShowPerson) -> Int = { $0.role.lowercased() == "host" ? 0 : 1 }
            return rank($0) != rank($1) ? rank($0) < rank($1) : $0.appearances > $1.appearances
        }
        return result
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        text = ""
        switch name {
        case "item": inItem = true; result.items += 1
        case "itunes:owner": inOwner = true
        case "itunes:category": if let c = attributes["text"], !result.categories.contains(c) { result.categories.append(c) }
        case "podcast:location":
            // Channel-level creator location is explicitly where the podcast is produced.
            // A subject location or an episode location must not be used as the show's origin.
            if !inItem, attributes["rel"]?.lowercased() == "creator",
               let code = attributes["country"]?.uppercased(),
               Locale.Region.isoRegions.contains(Locale.Region(code)) {
                result.country = code
            }
        case "podcast:person": personAttrs = attributes
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "item": inItem = false
        case "itunes:owner": inOwner = false
        case "itunes:name": if inOwner, result.owner == nil, !t.isEmpty { result.owner = t }
        case "language": if !inItem, result.language == nil, !t.isEmpty { result.language = t }
        case "link": if !inItem, result.website == nil, t.hasPrefix("http") { result.website = t }
        case "copyright": if !inItem, !t.isEmpty { result.copyright = t }
        case "itunes:explicit": if !inItem { result.explicit = ["yes", "true", "explicit"].contains(t.lowercased()) }
        case "podcast:person":
            guard !t.isEmpty else { break }
            let role = (personAttrs["role"] ?? (inItem ? "guest" : "host")).capitalized
            let key = t.lowercased() + "|" + role.lowercased()
            if var p = people[key] { p.appearances += 1; people[key] = p }
            else { people[key] = ShowPerson(name: t, role: role, image: personAttrs["img"], link: personAttrs["href"]) }
        default: break
        }
        text = ""
    }
}

// MARK: - Views

/// Everything under the episode list on a show page.
struct ShowDetailsSection: View {
    @Environment(Library.self) private var library
    let show: Show
    private var store: ShowInfoStore { ShowInfoStore.shared }

    var body: some View {
        let info = store.info(for: show)
        VStack(alignment: .leading, spacing: 34) {
            if let info {
                if !info.reviews.isEmpty { ratings(info) }
                if !info.people.isEmpty { people(info.people) }
                information(info)
            } else if store.loading.contains(show.id) {
                ProgressView("Loading show details…").frame(maxWidth: .infinity).padding(.vertical, 20)
            }
        }
        .task(id: show.id) {
            // Start official-channel discovery/episode artwork in its own
            // bounded library job. Directory ratings and show details still
            // load independently, without waiting for YouTube verification.
            library.ensureYouTubeArtwork(forShow: show.id)
            await store.load(show)
        }
    }

    func heading(_ t: String) -> some View {
        HStack(spacing: 6) {
            Text(t).font(.title2.bold())
            Image(systemName: "chevron.right").font(.title3.weight(.semibold)).foregroundStyle(.secondary)
        }
    }

    func stars(_ value: Double, size: CGFloat) -> some View {
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { i in
                Image(systemName: Double(i) + 0.75 <= value ? "star.fill" : (Double(i) + 0.25 <= value ? "star.leadinghalf.filled" : "star"))
                    .font(.system(size: size))
            }
        }
        .foregroundStyle(Color.podTeal)
    }

    func ratings(_ info: ShowInfo) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            heading("Ratings & Reviews")
            HStack(alignment: .center, spacing: 24) {
                VStack(spacing: 2) {
                    Text(String(format: "%.1f", info.averageRating ?? 0)).font(.system(size: 52, weight: .bold)).monospacedDigit()
                    Text("out of 5").font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 6) {
                    stars(info.averageRating ?? 0, size: 16)
                    Text("From \(info.reviews.count) recent review\(info.reviews.count == 1 ? "" : "s") on Apple Podcasts")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(info.reviews.prefix(12)) { r in reviewCard(r) }
                }
                .padding(.vertical, 2)
            }
        }
    }

    func reviewCard(_ r: ShowReview) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(r.title).font(.headline).lineLimit(1)
            HStack {
                stars(Double(r.rating), size: 11)
                Spacer()
                if let d = r.date { Text(Fmt.short(d)).font(.caption).foregroundStyle(.secondary) }
            }
            Text(r.body).font(.callout).foregroundStyle(.secondary).lineLimit(5)
            Spacer(minLength: 0)
            Text(r.author).font(.caption.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(14)
        .frame(width: 300, height: 170, alignment: .topLeading)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    func people(_ list: [ShowPerson]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            heading("Hosts & Guests")
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 20) {
                    ForEach(list.prefix(24)) { p in
                        Button {
                            library.searchForPerson(p.name)
                        } label: {
                            VStack(spacing: 8) {
                                PersonAvatar(person: p, size: 84)
                                Text(p.name).font(.callout.weight(.semibold)).lineLimit(2).multilineTextAlignment(.center)
                                Text(p.appearances > 1 && p.role.lowercased() != "host" ? "\(p.role) · \(p.appearances) episodes" : p.role)
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .frame(width: 110)
                        }
                        .buttonStyle(.plain)
                        .help("Search for episodes with \(p.name)")
                    }
                }
            }
        }
    }

    func information(_ info: ShowInfo) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            heading("Information")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), alignment: .topLeading)], alignment: .leading, spacing: 18) {
                infoItem("Creator", show.author.isEmpty ? (info.owner ?? "—") : show.author)
                if !info.genres.isEmpty { infoItem("Genre", info.genres.prefix(3).joined(separator: ", ")) }
                if let n = info.episodeCount { infoItem("Episodes", "\(n)") }
                if let d = info.updated { infoItem("Updated", Fmt.dateFormatter.string(from: d)) }
                if let e = info.explicit { infoItem("Rating", e ? "Explicit" : "Clean") }
                if let l = info.language { infoItem("Language", Locale.current.localizedString(forIdentifier: l) ?? l) }
                if let c = info.country { infoItem("Country", Locale.current.localizedString(forRegionCode: c) ?? c) }
                if let c = info.copyright { infoItem("Copyright", c) }
                if let w = info.website, let url = URL(string: w) { linkItem("Website", url, label: url.host() ?? w) }
                if let a = info.appleURL, let url = URL(string: a) { linkItem("Apple Podcasts", url, label: "Show on Apple Podcasts") }
                if let f = show.feedURL, let url = URL(string: f) { linkItem("Feed", url, label: url.host() ?? f) }
            }
        }
    }

    func infoItem(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).font(.callout).lineLimit(3).textSelection(.enabled)
        }
    }

    func linkItem(_ title: String, _ url: URL, label: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Link(label, destination: url).font(.callout).lineLimit(1)
        }
    }
}

struct PersonAvatar: View {
    let person: ShowPerson
    let size: CGFloat
    var body: some View {
        let initials = String(person.name.split(separator: " ").prefix(2).compactMap(\.first)).uppercased()
        AsyncImage(url: person.image.flatMap(URL.init(string:))) { phase in
            if let img = phase.image {
                img.resizable().scaledToFill()
            } else {
                ZStack {
                    LinearGradient(colors: [Color.podTeal.opacity(0.8), Color.podTeal.opacity(0.45)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Text(initials).font(.system(size: size * 0.34, weight: .bold, design: .rounded)).foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}
