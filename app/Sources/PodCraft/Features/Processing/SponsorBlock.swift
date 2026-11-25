import Foundation

/// SponsorBlock community segments for YouTube videos (sponsor.ajay.app/api/skipSegments),
/// asked for the same nine categories and two action types as the original (function 0x10041ef84).
enum SponsorBlock {
    static let allCategories: [(id: String, title: String)] = [
        ("sponsor", "Sponsor"), ("selfpromo", "Self-promotion"), ("interaction", "Like and subscribe reminders"),
        ("intro", "Intro"), ("outro", "Outro / end cards"), ("preview", "Previews and recaps"),
        ("music_offtopic", "Off-topic music"), ("filler", "Filler and tangents"), ("hook", "Hooks and teasers"),
    ]
    /// Estimated: which categories are cut by default (the original asks for all nine and lets you choose).
    static let defaultCategories = ["sponsor", "selfpromo", "interaction"]

    enum Failure: LocalizedError {
        case badID
        var errorDescription: String? { "Enter a valid YouTube URL or 11-character video ID." }
    }

    /// Accepts a YouTube link (watch, youtu.be, shorts, embed) or a bare 11-character ID.
    static func videoID(from text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let idPattern = "^[A-Za-z0-9_-]{11}$"
        if t.range(of: idPattern, options: .regularExpression) != nil { return t }
        guard let comps = URLComponents(string: t), let host = comps.host?.lowercased() else { return nil }
        if host.contains("youtu.be") {
            let id = comps.path.split(separator: "/").first.map(String.init) ?? ""
            return id.range(of: idPattern, options: .regularExpression) != nil ? id : nil
        }
        if host.contains("youtube") {
            if let v = comps.queryItems?.first(where: { $0.name == "v" })?.value,
               v.range(of: idPattern, options: .regularExpression) != nil { return v }
            let parts = comps.path.split(separator: "/").map(String.init)
            if parts.count >= 2, ["shorts", "embed", "live", "v"].contains(parts[0]),
               parts[1].range(of: idPattern, options: .regularExpression) != nil { return parts[1] }
        }
        return nil
    }

    static func segments(videoID: String, categories: [String]) async throws -> [CutSegment] {
        var comps = URLComponents(string: "https://sponsor.ajay.app/api/skipSegments")!
        let cats = "[" + categories.map { "\"\($0)\"" }.joined(separator: ",") + "]"
        comps.queryItems = [.init(name: "videoID", value: videoID), .init(name: "categories", value: cats),
                            .init(name: "actionTypes", value: "[\"skip\",\"mute\"]")]
        var request = URLRequest(url: comps.url!)
        request.timeoutInterval = 15
        let data: Data
        do {
            data = try await NetworkClient.data(for: request, limit: 2 * 1_048_576).0
        } catch NetworkClient.Failure.http(404) {
            return [] // No segments submitted yet.
        }
        struct Seg: Decodable { var segment: [Double]; var category: String }
        let segs = try JSONDecoder().decode([Seg].self, from: data)
        return segs.compactMap { s in
            guard s.segment.count == 2, s.segment[1] > s.segment[0] else { return nil }
            return CutSegment(start: s.segment[0], end: s.segment[1], category: s.category, source: "SponsorBlock")
        }
    }
}
