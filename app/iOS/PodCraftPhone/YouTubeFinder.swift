import Foundation
import Observation

/// Finds an episode's upload on the show's official YouTube channel from the phone itself, with no Mac: it asks
/// YouTube's search for the show and episode, then keeps only a result that matches all of
/// - the channel: named like the show (or the channel already confirmed for it),
/// - the title: the same episode title, or the same episode number and subject,
/// - the length: within a few minutes, since feeds can carry inserted ads.
/// When more than one result passes, nothing is chosen. The title and length rules mirror the Mac's YouTubeSource.
@MainActor
@Observable
final class YouTubeFinder {
    static let shared = YouTubeFinder()

    /// Video ids found on this phone, by episode id.
    private(set) var found: [String: String]
    /// Episodes being looked up now.
    private(set) var searching: Set<String> = []

    /// Episodes with no match, and when they were checked (tried again after a couple of days).
    @ObservationIgnored private var missed: [String: Date]
    /// The channel confirmed for each show, by show id.
    @ObservationIgnored private var channels: [String: String]
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 15
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    private enum Key {
        static let found = "youtube.found", missed = "youtube.missed", channels = "youtube.channels"
    }

    private init() {
        found = defaults.dictionary(forKey: Key.found) as? [String: String] ?? [:]
        missed = defaults.dictionary(forKey: Key.missed) as? [String: Date] ?? [:]
        channels = defaults.dictionary(forKey: Key.channels) as? [String: String] ?? [:]
    }

    /// Looks for the episode's YouTube upload once in a while; the result shows up in `found`.
    func lookUp(_ e: RemoteEpisode, show: RemoteShow?) async {
        guard let show, found[e.id] == nil, !searching.contains(e.id) else { return }
        if let at = missed[e.id], Date().timeIntervalSince(at) < 2 * 86_400 { return }
        searching.insert(e.id)
        defer { searching.remove(e.id) }
        // Without the show's name in the query, a common episode title finds other channels' videos.
        guard let results = await search("\(show.title) \(e.title)") else { return } // offline: try again later
        if let hit = Self.match(episode: e, show: show, confirmedChannel: channels[show.id], in: results) {
            found[e.id] = hit.id
            channels[show.id] = hit.channelID
            missed.removeValue(forKey: e.id)
        } else {
            missed[e.id] = Date()
        }
        save()
    }

    private func save() {
        // Keep the lists from growing without end.
        if found.count > 3000 { found = Dictionary(uniqueKeysWithValues: found.prefix(2000).map { ($0.key, $0.value) }) }
        let cutoff = Date().addingTimeInterval(-30 * 86_400)
        missed = missed.filter { $0.value > cutoff }
        defaults.set(found, forKey: Key.found)
        defaults.set(missed, forKey: Key.missed)
        defaults.set(channels, forKey: Key.channels)
    }

    // MARK: Search

    struct Result: Equatable {
        var id: String
        var title: String
        var duration: Double
        var channel: String
        var channelID: String
    }

    /// YouTube's own search (the API its website uses), videos only. Nil when it can't be reached.
    private func search(_ query: String) async -> [Result]? {
        guard let url = URL(string: "https://www.youtube.com/youtubei/v1/search?prettyPrint=false") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "context": ["client": ["clientName": "WEB", "clientVersion": "2.20251120.01.00", "hl": "en", "gl": "US"]],
            "query": query,
            "params": "EgIQAQ==", // type: video
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return Self.results(in: json)
    }

    /// Every video in a search response, wherever it sits in the page layout.
    nonisolated static func results(in json: Any) -> [Result] {
        var out: [Result] = []
        func walk(_ node: Any) {
            if let dict = node as? [String: Any] {
                if let v = dict["videoRenderer"] as? [String: Any], let r = result(v) { out.append(r) }
                for value in dict.values { walk(value) }
            } else if let list = node as? [Any] {
                for value in list { walk(value) }
            }
        }
        walk(json)
        var seen = Set<String>()
        return out.filter { seen.insert($0.id).inserted }
    }

    nonisolated private static func result(_ v: [String: Any]) -> Result? {
        func text(_ any: Any?) -> String? {
            guard let d = any as? [String: Any] else { return nil }
            if let s = d["simpleText"] as? String { return s }
            return (d["runs"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined()
        }
        guard let id = v["videoId"] as? String, YouTubeVideo.isValid(id),
              let title = text(v["title"]),
              let owner = (v["ownerText"] as? [String: Any])?["runs"] as? [[String: Any]], let first = owner.first,
              let channel = first["text"] as? String,
              let channelID = ((first["navigationEndpoint"] as? [String: Any])?["browseEndpoint"] as? [String: Any])?["browseId"] as? String,
              let length = text(v["lengthText"]).flatMap(clock) else { return nil }
        return Result(id: id, title: title, duration: length, channel: channel, channelID: channelID)
    }

    /// "1:02:03" → 3723.
    nonisolated static func clock(_ s: String) -> Double? {
        let parts = s.split(separator: ":").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard !parts.isEmpty, parts.count <= 3, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.reduce(0) { $0 * 60 + $1! }
    }

    // MARK: Matching (as on the Mac)

    nonisolated static func match(episode e: RemoteEpisode, show: RemoteShow, confirmedChannel: String?,
                                  in results: [Result]) -> Result? {
        let requested = normalizedTitle(e.title)
        guard !requested.isEmpty else { return nil }
        let threshold = allowedDurationDifference(e.duration)
        let candidates = results.filter { r in
            let channelOK = r.channelID == confirmedChannel ||
                (confirmedChannel == nil && (strongChannelIdentity(show.title, r.channel) ||
                                             strongChannelIdentity(show.author, r.channel)))
            guard channelOK else { return false }
            // An unknown feed length (0) can't rule a video out, but then the title alone must be exact.
            let lengthOK = e.duration > 0 ? abs(r.duration - e.duration) <= threshold : false
            let title = normalizedTitle(r.title)
            let similar = titleSimilarity(requested, title) >= 0.92 || matchingSerialAndSubject(e.title, r.title)
            return similar && (lengthOK || (e.duration <= 0 && title == requested))
        }
        return candidates.count == 1 ? candidates[0] : nil
    }

    nonisolated static func allowedDurationDifference(_ duration: Double) -> Double {
        max(70, min(240, duration * 0.085))
    }

    nonisolated static func strongChannelIdentity(_ showName: String, _ channelName: String) -> Bool {
        let source = normalizedTitle(showName).replacingOccurrences(of: " ", with: "")
        let channel = normalizedTitle(channelName).replacingOccurrences(of: " ", with: "")
        guard source.count >= 6, channel.count >= 6 else { return false }
        if source.contains(channel) || channel.contains(source) { return true }
        let sourceTokens = Set(normalizedTitle(showName).split(separator: " ").filter { $0.count >= 4 })
        let channelTokens = Set(normalizedTitle(channelName).split(separator: " ").filter { $0.count >= 4 })
        guard !channelTokens.isEmpty else { return false }
        return Double(sourceTokens.intersection(channelTokens).count) / Double(channelTokens.count) >= 0.7
    }

    nonisolated static func normalizedTitle(_ raw: String) -> String {
        var s = raw.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current).lowercased()
        s = s.replacingOccurrences(of: #"^\s*\[\s*#?\d{1,4}\s*\]\s*"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"^(?:episode|ep|capitulo|capitulo nº|chapter)?\s*#?\s*\d{1,4}\s*[:.|\-–]\s*"#,
                                   with: "", options: .regularExpression)
        return s.replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func titleSimilarity(_ a: String, _ b: String) -> Double {
        if a == b { return 1 }
        let aa = Set(a.split(separator: " ")), bb = Set(b.split(separator: " "))
        guard !aa.isEmpty, !bb.isEmpty else { return 0 }
        let common = aa.intersection(bb).count
        // YouTube often appends "| Show Name" to the full episode title.
        if min(aa.count, bb.count) >= 4 && common == min(aa.count, bb.count) { return 0.97 }
        if let x = episodeSerial(a), let y = episodeSerial(b), x == y, common >= 3 { return 0.96 }
        return Double(common) / Double(aa.union(bb).count)
    }

    /// The same "#123" or "2x05" episode number, and two more words after it in common.
    nonisolated static func matchingSerialAndSubject(_ rss: String, _ youtube: String) -> Bool {
        let pattern = #"(?i)(?:#\s*\d{2,4}\b|\bt?\d{1,2}x\d{1,2}\b)"#
        guard let a = rss.range(of: pattern, options: .regularExpression),
              let b = youtube.range(of: pattern, options: .regularExpression) else { return false }
        func serial(_ s: Substring) -> String {
            s.lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "t", with: "")
        }
        guard serial(rss[a]) == serial(youtube[b]) else { return false }
        let tailA = Set(normalizedTitle(String(rss[a.upperBound...])).split(separator: " ").filter { $0.count >= 3 })
        let tailB = Set(normalizedTitle(String(youtube[b.upperBound...])).split(separator: " ").filter { $0.count >= 3 })
        return tailA.intersection(tailB).count >= 2
    }

    nonisolated private static func episodeSerial(_ title: String) -> String? {
        guard let range = title.range(of: #"(?i)(?:\bt?\d{1,2}x\d{1,2}\b|#\d{2,4}\b)"#, options: .regularExpression) else { return nil }
        return title[range].lowercased().replacingOccurrences(of: "t", with: "").replacingOccurrences(of: "#", with: "")
    }
}
