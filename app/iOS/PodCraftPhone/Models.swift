import Foundation

/// The library as PodCraft on the Mac serves it (GET /api/<code>/library.json).
struct RemoteLibrary: Codable, Hashable {
    var name: String
    var shows: [RemoteShow]
    /// Channels: feeds built on the Mac, each a group of shows (older Macs don't send them).
    var feeds: [RemoteFeed]?
}

struct RemoteFeed: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var author: String
    var summary: String
    var artwork: URL?
    var showIDs: [String]
}

struct RemoteShow: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var author: String
    var summary: String
    var artwork: URL?
    var episodes: [RemoteEpisode]
}

struct RemoteChapter: Codable, Hashable, Identifiable {
    var start: Double
    var title: String
    var id: Double { start }
}

struct RemoteEpisode: Codable, Identifiable, Hashable {
    var id: String
    var showID: String
    var title: String
    var summary: String
    var published: Date
    var duration: Double
    var position: Double
    var played: Bool
    var isVideo: Bool
    var media: URL
    var artwork: URL?
    var hasTranscript: Bool
    var chapters: [RemoteChapter]
    /// Downloaded and cleaned on the Mac (sponsors cut, chapters); otherwise it streams as the show published it.
    var onMac: Bool?

    var isOnMac: Bool { onMac ?? true }
}

struct TranscriptLine: Codable, Hashable, Identifiable {
    var start: Double
    var end: Double
    var text: String
    var id: Double { start }
}

/// One episode with its transcript (GET /api/<code>/episodes/<id>.json).
struct EpisodeDetail: Codable {
    var transcript: [TranscriptLine]
}

enum Fmt {
    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let s = Int(seconds.rounded(.down))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }

    static func remaining(_ seconds: Double) -> String {
        let minutes = Int((max(0, seconds) / 60).rounded(.up))
        if minutes >= 60 { return "\(minutes / 60) hr \(minutes % 60) min" }
        return "\(max(1, minutes)) min"
    }

    static let day: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        f.doesRelativeDateFormatting = true
        return f
    }()

    static func date(_ d: Date) -> String { day.string(from: d).uppercased() }

    /// Plain text from a show's HTML summary.
    static func plain(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
