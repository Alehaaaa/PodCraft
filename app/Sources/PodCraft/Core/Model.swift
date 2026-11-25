import Foundation
import SwiftUI
import AVFoundation
import NaturalLanguage

// MARK: - Modes and navigation

enum AppMode: String, Codable, CaseIterable, Identifiable {
    case manage, listen
    var id: String { rawValue }
    var title: String { self == .manage ? "Manage" : "Listen" }
    var symbol: String { self == .manage ? "slider.horizontal.3" : "headphones" }
}

enum SidebarItem: Hashable {
    case show(UUID)
    case feed(UUID)
    case downloads
    case settings
}

enum ListenItem: Hashable {
    case home
    case search
    case new
    case recentlyUpdated
    case shows
    case channels
    case saved
    case downloaded
    case latest
    case show(UUID)
    case feed(UUID)
}

// MARK: - Rules (see MECHANICS.md)

/// How long a feed keeps its downloads. Mirrors the three choices of the original's
/// "Keep episodes by" setting (EpisodeEditorView, function 0x1002571f8).
enum KeepRule: Codable, Hashable {
    case forever
    case days(Int)
    case newest(Int)

    var kind: Int {
        switch self { case .forever: 0; case .days: 1; case .newest: 2 }
    }

    func describe() -> String {
        switch self {
        case .forever: "Kept until you remove them manually."
        case .days(let d): "Removed from this Mac \(d) days after they were added."
        case .newest(let n): "Removed from this Mac once the feed keeps \(n) newer episodes."
        }
    }
}

enum Stage: String, Codable, CaseIterable {
    /// In the show's listing but not on this Mac (can be streamed or downloaded).
    case listed
    case queued, downloading, cuttingSponsors, transcribing, chaptering, cutting, ready, failed

    var label: String {
        switch self {
        case .listed: "Not downloaded"
        case .queued: "Queued episode processing."
        case .downloading: "Downloading"
        case .cuttingSponsors: "Checking SponsorBlock segments"
        case .transcribing: "Transcribing"
        case .chaptering: "Generating chapters and finding sponsors"
        case .cutting: "Cutting sponsor segments"
        case .ready: "On this Mac"
        case .failed: "Failed"
        }
    }
    var symbol: String {
        switch self {
        case .listed: "icloud.and.arrow.down"
        case .queued: "clock"
        case .downloading: "arrow.down.circle"
        case .cuttingSponsors: "shield.lefthalf.filled"
        case .transcribing: "text.bubble"
        case .chaptering: "sparkles"
        case .cutting: "scissors"
        case .ready: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }
    /// Being downloaded or processed right now (or waiting for it).
    var isWorking: Bool { ![.listed, .ready, .failed].contains(self) }
}

// MARK: - Data

struct Chapter: Codable, Identifiable, Hashable {
    var id = UUID()
    var start: Double
    var title: String
}

struct TranscriptLine: Codable, Hashable, Sendable {
    var start: Double
    var end: Double
    var text: String
}

    /// An interval in ORIGINAL media time. The recording is not modified; playback skips it.
struct CutSegment: Codable, Hashable, Identifiable {
    var id = UUID()
    var start: Double
    var end: Double
    var category: String
    var source: String
    var length: Double { max(0, end - start) }
}

/// Persistent result from checking this exact RSS episode against an official
/// YouTube channel. Only a verified exact negative is `.notFound`; network
/// failures and missing yt-dlp must remain `.untried` and retryable.
enum YouTubeEpisodeMatchState: String, Codable, Hashable {
    case untried, matched, notFound
}

struct Episode: Codable, Identifiable, Hashable {
    var id = UUID()
    var showID: UUID
    var title: String
    var summary: String = ""
    var published: Date
    var addedAt: Date
    var duration: Double
    var position: Double = 0
    var played: Bool = false
    /// Most recent time playback was started or resumed. Drives Recently Played ordering.
    var lastPlayedAt: Date? = nil
    var chapters: [Chapter] = []
    var audioURL: String? = nil
    var guid: String? = nil
    var keepForever: Bool = false
    var stage: Stage = .listed
    var progress: Double = 0
    var adSecondsRemoved: Double = 0
    var isVideo: Bool = false
    var link: String? = nil
    var youtubeID: String? = nil
    /// Reopens must not search a confirmed no-match episode again on playback.
    /// This is a metadata lookup state, not an indication of the media source.
    var youtubeMatchState: YouTubeEpisodeMatchState = .untried
    /// Prevents a negative decision from one official channel being applied to
    /// a newly selected channel. A verified positive has its own youtubeID.
    var youtubeMatchChannelURL: String? = nil
    /// Only populated when the CURRENT local recording is the matched YouTube upload.
    /// SponsorBlock timestamps must not be applied to a separate, ad-inserted RSS recording.
    var youtubeMediaID: String? = nil
    var localFile: String? = nil
    /// Original media retained for non-destructive sponsor editing (also used to recover legacy exports).
    var originalLocalFile: String? = nil
    /// Preserve an earlier RSS download when replacing the playback source with YouTube.
    var rssBackupLocalFile: String? = nil
    var transcript: [TranscriptLine] = []
    var cuts: [CutSegment] = []
    var cutApplied: Bool = false
    var note: String? = nil
    var artworkURL: String? = nil
    /// Identifies the transcript/settings combination used for the current generated chapters.
    var analysisFingerprint: String? = nil
    /// Downloaded because it was among the show's newest; removed again when it falls out of that window.
    var autoDownloaded: Bool = false
    /// The episode's own language tag from its feed, if any ("es-ES").
    var language: String? = nil
    /// The language its transcript was made in (so a wrong-language transcript can be spotted and redone).
    var transcriptLanguage: String? = nil

    /// The unmodified recording, including advertising, for waveform editing and transcription.
    var sourceURL: URL? {
        if let originalLocalFile, FileManager.default.fileExists(atPath: originalLocalFile) {
            return URL(fileURLWithPath: originalLocalFile)
        }
        if let localFile, FileManager.default.fileExists(atPath: localFile) {
            return URL(fileURLWithPath: localFile)
        }
        return audioURL.flatMap(URL.init(string:))
    }

    /// Playback uses the same immutable recording; sponsor skips are handled by Player.
    var playableURL: URL? {
        sourceURL
    }
    var isSample: Bool { audioURL == nil && localFile == nil }
    var isDownloaded: Bool { stage == .ready && localFile != nil }
    /// Can be played: on this Mac, or streamed from its link.
    // Processing does not make a stream unplayable. Keep playback available while the
    // same episode downloads, transcribes, or gains chapters in the background.
    var canPlay: Bool { playableURL != nil }

    var playbackTimeline: SponsorTimeline {
        SponsorTimeline(sourceDuration: duration,
                        cuts: cutApplied && originalLocalFile == nil ? [] : cuts)
    }
    var playbackDuration: Double { playbackTimeline.duration }
    /// Playback-only presentation. Stored chapters/transcript stay in ORIGINAL source time.
    var playbackChapters: [Chapter] {
        let timeline = playbackTimeline
        var result: [Chapter] = []
        for var chapter in chapters.sorted(by: { $0.start < $1.start }) {
            let title = chapter.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if title == "ad" || title == "ads" || title == "sponsor" ||
                title.hasPrefix("sponsor:") || title.hasPrefix("advertisement") ||
                timeline.containsSource(chapter.start) { continue }
            chapter.start = timeline.visibleTime(forSource: chapter.start)
            if let previous = result.last, abs(previous.start - chapter.start) < 0.01 { continue }
            result.append(chapter)
        }
        return result
    }
    var playbackTranscript: [TranscriptLine] {
        let timeline = playbackTimeline
        return transcript.compactMap { line in
            guard timeline.visibleSourceRange(line.start, line.end) else { return nil }
            // A sentence straddling an excluded interval cannot be faithfully
            // cropped by trimming its timestamps: its text could still quote the
            // hidden advert. Keep the full sentence only in the source editor.
            guard !timeline.skipped.contains(where: {
                line.start < $0.upperBound && line.end > $0.lowerBound
            }) else { return nil }
            return TranscriptLine(start: timeline.visibleTime(forSource: line.start),
                                  end: timeline.visibleTime(forSource: line.end), text: line.text)
        }
    }

    var remaining: Double { max(0, playbackDuration - position) }
    var started: Bool { position > 1 && !played }
}

struct Show: Codable, Identifiable, Hashable {
    var id = UUID()
    /// The feed this show is grouped into, if any. A show doesn't need a feed.
    var feedID: UUID? = nil
    var title: String
    var author: String
    var feedURL: String? = nil
    /// Optional official video channel; never infer identity from an unrelated search result.
    var youtubeChannelURL: String? = nil
    /// Revision 1 records that legacy negatives from the 100-video channel
    /// listing were reconsidered against the larger official archive.
    var youtubeCatalogRevision = 0
    /// Persist the last successful bulk scan to avoid reindexing thousands of
    /// uploads every time the app starts. New RSS entries bypass this cooldown.
    var youtubeCatalogScannedAt: Date? = nil
    var youtubeCatalogScannedEpisodeCount = 0
    var youtubeCatalogScannedChannelURL: String? = nil
    /// Default to the smaller audio-only YouTube source; opt in for full H.264/AAC video.
    var youtubePlaybackVideo = false
    var artworkURL: String? = nil
    var hue: Double
    var isFiles: Bool = false
    var summary: String = ""
    /// How many of the newest episodes are kept on this Mac at a time.
    var keepAvailable: Int = Mechanics.defaultAvailablePerShow
    // Customisation kept from the original's subscription settings (fields read at 0x10010c45c):
    /// Your own cover picture (hasCustomArtwork), stored in the Artwork folder.
    var customArtwork: String? = nil
    /// A coloured frame around the cover (artworkBorderColorHex / artworkBorderWidth).
    var showsBorder: Bool = false
    var borderHue: Double = 0.6
    var borderWidth: Double = 6
    /// Episodes whose titles contain any of these words are skipped (excludedEpisodeTitleTerms).
    var excludedTitleTerms: String = ""
    /// Chapters whose titles contain any of these words are cut out (excludedChapterTitleTerms).
    var excludedChapterTerms: String = ""
    /// The show's language from its feed ("es-ES"); transcripts start in this language.
    var language: String? = nil

    static func terms(_ raw: String) -> [String] {
        raw.split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
    }
    func skips(_ e: Episode) -> Bool {
        let t = e.title.lowercased()
        return Show.terms(excludedTitleTerms).contains { t.contains($0) }
    }
    func cutsChapter(_ title: String) -> Bool {
        let t = title.lowercased()
        return Show.terms(excludedChapterTerms).contains { t.contains($0) }
    }
}

struct Feed: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var author: String
    var summary: String
    var hue: Double
    var showsBorder: Bool = true
    var borderHue: Double = 0.6
    var borderWidth: Double = 6
    var keepRule: KeepRule? = nil   // nil = use the app setting
    var localOnly: Bool = false
    var token: String = String(UUID().uuidString.prefix(8)).lowercased()

    var privateLink: String { "http://localhost:8743/feeds/\(token).xml" }
}

enum AIProvider: String, Codable, CaseIterable, Identifiable {
    case onDevice, gemini, off
    var id: String { rawValue }
    var title: String {
        switch self {
        case .onDevice: "Apple Intelligence (on this Mac)"
        case .gemini: "Gemini (your API key)"
        case .off: "Off"
        }
    }
}

/// The visible episode subset on an individual podcast show page.
enum EpisodeFilter: String, CaseIterable, Identifiable {
    case all = "All", unplayed = "Unplayed", downloaded = "Downloaded"
    var id: String { rawValue }
}

/// Observable result of checking a podcast against its official YouTube channel.
/// A verified episode ID is only metadata until Processor downloads that recording.
enum YouTubeMatchStatus: Equatable {
    case idle
    case checking
    case verified
    case noMatch
    case error(String)

    var label: String {
        switch self {
        case .idle: "Not checked"
        case .checking: "Checking official YouTube archive…"
        case .verified: "Official YouTube matches verified"
        case .noMatch: "No official YouTube matches confirmed yet"
        case .error(let message): message
        }
    }

    var isChecking: Bool { if case .checking = self { true } else { false } }
    var errorMessage: String? { if case .error(let message) = self { message } else { nil } }
}

struct YouTubeCatalogProgress: Equatable {
    var checked: Int
    var total: Int
}

struct AppSettings: Codable, Hashable {
    // autoDeletePolicy defaults to its first case; the picker lists "Delete after a set time" first (inferred).
    var keepRule: KeepRule = .days(Mechanics.defaultKeepDays)
    var removeSponsors = true
    var generateChapters = true
    var transcribe = true
    var localOnlyByDefault = false
    var defaultSpeed: Double = 1.0
    var useSponsorBlock = true
    var sponsorCategories: [String] = SponsorBlock.defaultCategories
    var aiProvider: AIProvider = .onDevice
    var geminiModel: String = Mechanics.defaultGeminiModel
    var hostingEnabled = true
    var hostPort: Int = Mechanics.defaultHostPort
    var uploadURL: String = ""
    /// How many of the newest episodes a newly added show keeps on this Mac.
    var defaultAvailable: Int = Mechanics.defaultAvailablePerShow
    /// Which address feed links use: this Mac's local network name, or its Tailscale address (reachable from
    /// your other devices anywhere, over your tailnet).
    var linkAddress: LinkAddress = .automatic
    /// The private code the PodCraft iPhone app uses to read this library (shown as a QR code in Settings).
    var phoneCode: String = AppSettings.newPhoneCode()

    static func newPhoneCode() -> String {
        let letters = Array("abcdefghjkmnpqrstuvwxyz23456789")
        return String((0..<20).map { _ in letters.randomElement()! })
    }
}

enum LinkAddress: String, Codable, CaseIterable, Identifiable, Hashable {
    /// Tailscale when it's connected on this Mac, otherwise the local network.
    case automatic, localNetwork, tailscale
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .localNetwork: "Local Network"
        case .tailscale: "Tailscale"
        }
    }
}

struct Metrics: Codable, Hashable {
    var listenedSeconds: Double = 0
    var speedSavedSeconds: Double = 0
    var episodesFinished: Int = 0
    var adSecondsRemoved: Double = 0
    var episodesProcessed: Int = 0
}

struct LibraryFile: Codable {
    var feeds: [Feed] = []
    var shows: [Show] = []
    var episodes: [Episode] = []
    var settings = AppSettings()
    var metrics = Metrics()
}

// MARK: - Forgiving decoding: fields added in later versions fall back to their defaults

extension KeyedDecodingContainer {
    func v<T: Decodable>(_ key: Key, _ fallback: @autoclosure () -> T) -> T {
        ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback()
    }
}

extension Episode {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(showID: try c.decode(UUID.self, forKey: .showID), title: c.v(.title, ""),
                  published: c.v(.published, Date()), addedAt: c.v(.addedAt, Date()), duration: c.v(.duration, 0))
        id = c.v(.id, id); summary = c.v(.summary, ""); position = c.v(.position, 0); played = c.v(.played, false)
        lastPlayedAt = c.v(.lastPlayedAt, nil)
        chapters = c.v(.chapters, []); audioURL = c.v(.audioURL, nil); guid = c.v(.guid, nil)
        keepForever = c.v(.keepForever, false); stage = c.v(.stage, .listed); progress = c.v(.progress, 0)
        adSecondsRemoved = c.v(.adSecondsRemoved, 0); isVideo = c.v(.isVideo, false); link = c.v(.link, nil)
        youtubeID = c.v(.youtubeID, nil); youtubeMediaID = c.v(.youtubeMediaID, nil)
        youtubeMatchState = c.v(.youtubeMatchState, youtubeID == nil ? .untried : .matched)
        youtubeMatchChannelURL = c.v(.youtubeMatchChannelURL, nil)
        localFile = c.v(.localFile, nil); rssBackupLocalFile = c.v(.rssBackupLocalFile, nil)
        originalLocalFile = c.v(.originalLocalFile, nil); transcript = c.v(.transcript, [])
        cuts = c.v(.cuts, []); cutApplied = c.v(.cutApplied, false); note = c.v(.note, nil)
        artworkURL = c.v(.artworkURL, nil); autoDownloaded = c.v(.autoDownloaded, false)
        analysisFingerprint = c.v(.analysisFingerprint, nil)
        language = c.v(.language, nil); transcriptLanguage = c.v(.transcriptLanguage, nil)
    }
}

extension Show {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(title: c.v(.title, ""), author: c.v(.author, ""), hue: c.v(.hue, 0.6))
        id = c.v(.id, id); feedID = c.v(.feedID, nil); feedURL = c.v(.feedURL, nil)
        youtubeChannelURL = c.v(.youtubeChannelURL, nil)
        youtubeCatalogRevision = c.v(.youtubeCatalogRevision, 0)
        youtubeCatalogScannedAt = c.v(.youtubeCatalogScannedAt, nil)
        youtubeCatalogScannedEpisodeCount = c.v(.youtubeCatalogScannedEpisodeCount, 0)
        youtubeCatalogScannedChannelURL = c.v(.youtubeCatalogScannedChannelURL, nil)
        youtubePlaybackVideo = c.v(.youtubePlaybackVideo, false)
        artworkURL = c.v(.artworkURL, nil)
        isFiles = c.v(.isFiles, false); summary = c.v(.summary, "")
        keepAvailable = c.v(.keepAvailable, Mechanics.defaultAvailablePerShow)
        customArtwork = c.v(.customArtwork, nil); showsBorder = c.v(.showsBorder, false)
        borderHue = c.v(.borderHue, 0.6); borderWidth = c.v(.borderWidth, 6)
        excludedTitleTerms = c.v(.excludedTitleTerms, ""); excludedChapterTerms = c.v(.excludedChapterTerms, "")
        language = c.v(.language, nil)
    }
}

extension Feed {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(title: c.v(.title, "Feed"), author: c.v(.author, ""), summary: c.v(.summary, ""), hue: c.v(.hue, 0.6))
        id = c.v(.id, id); showsBorder = c.v(.showsBorder, true); borderHue = c.v(.borderHue, 0.6)
        borderWidth = c.v(.borderWidth, 6); keepRule = c.v(.keepRule, nil); localOnly = c.v(.localOnly, false)
        token = c.v(.token, token)
    }
}

extension AppSettings {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        keepRule = c.v(.keepRule, keepRule); removeSponsors = c.v(.removeSponsors, true)
        generateChapters = c.v(.generateChapters, true); transcribe = c.v(.transcribe, true)
        localOnlyByDefault = c.v(.localOnlyByDefault, false); defaultSpeed = c.v(.defaultSpeed, 1.0)
        useSponsorBlock = c.v(.useSponsorBlock, true); sponsorCategories = c.v(.sponsorCategories, SponsorBlock.defaultCategories)
        aiProvider = c.v(.aiProvider, .onDevice); geminiModel = c.v(.geminiModel, Mechanics.defaultGeminiModel)
        hostingEnabled = c.v(.hostingEnabled, true); hostPort = c.v(.hostPort, Mechanics.defaultHostPort)
        uploadURL = c.v(.uploadURL, ""); defaultAvailable = c.v(.defaultAvailable, Mechanics.defaultAvailablePerShow)
        linkAddress = c.v(.linkAddress, .automatic)
        phoneCode = c.v(.phoneCode, AppSettings.newPhoneCode())
    }
}

extension Metrics {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(listenedSeconds: c.v(.listenedSeconds, 0), speedSavedSeconds: c.v(.speedSavedSeconds, 0),
                  episodesFinished: c.v(.episodesFinished, 0), adSecondsRemoved: c.v(.adSecondsRemoved, 0),
                  episodesProcessed: c.v(.episodesProcessed, 0))
    }
}

extension LibraryFile {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(feeds: c.v(.feeds, []), shows: c.v(.shows, []), episodes: c.v(.episodes, []),
                  settings: c.v(.settings, AppSettings()), metrics: c.v(.metrics, Metrics()))
    }
}

// MARK: - Library store

@Observable
final class Library {
    var feeds: [Feed] = []
    var shows: [Show] = []
    var episodes: [Episode] = []
    var settings = AppSettings()
    var metrics = Metrics()
    /// Observable, per-show presentation state. Kept separate from Library.json so
    /// changing a picker never rewrites episodes, transcripts or download metadata.
    var episodeFiltersByShow: [UUID: EpisodeFilter] = [:]
    /// Transient UI state. The verified channel and each confirmed `youtubeID`
    /// are persisted on Show/Episode, never in this dictionary.
    var youtubeMatchStatusesByShow: [UUID: YouTubeMatchStatus] = [:]
    /// Live archive progress, updated without reserializing the whole library.
    var youtubeCatalogProgressByShow: [UUID: YouTubeCatalogProgress] = [:]

    // Window state
    var mode: AppMode = .manage
    var manageSelection: SidebarItem? = nil
    var listenSelection: ListenItem? = .home
    var showAddShow = false
    var addShowTargetFeed: UUID? = nil
    var editingEpisode: UUID? = nil
    var downloadsPaused = false
    var toast: String? = nil
    /// Bumped whenever a piece of artwork finishes downloading, so pictures redraw.
    var artworkVersion = 0
    var checking = false

    @ObservationIgnored var persist = true
    /// An explicit storage root and defaults domain let persistence regressions
    /// exercise the actual read/write/relaunch path without ever opening the
    /// user's Library.json or modifying their application preferences.
    @ObservationIgnored private var storageURL: URL = Library.storeURL
    @ObservationIgnored private var preferences: UserDefaults = .standard
    private static let episodeFiltersPreferenceKey = "episodeFiltersByShow"
    @ObservationIgnored var onEpisodeReady: ((UUID) -> Void)?
    /// Media and transcript are source-consistent and can be adopted by the
    /// current player even while optional chapter analysis continues.
    @ObservationIgnored var onEpisodePlaybackPrepared: ((UUID) -> Void)?
    @ObservationIgnored var processor: Processor?
    @ObservationIgnored var server: FeedServer?
    // YouTube artwork is metadata, not a media source. Keep discovery and image
    // lookups detached from the playback and download lifecycles, coalesced by
    // show/episode so rapid navigation never spawns duplicate yt-dlp processes.
    @ObservationIgnored private var youtubeArtworkShowTasks: [UUID: Task<Void, Never>] = [:]
    /// Each channel index job awaits the previous one to bound yt-dlp traffic.
    @ObservationIgnored private var youtubeCatalogTaskTail: Task<Void, Never>?
    @ObservationIgnored private var youtubeCatalogStartupTask: Task<Void, Never>?
    @ObservationIgnored private var youtubeCatalogStartupGeneration: UUID?
    @ObservationIgnored private var youtubeCatalogLastScanByShow: [UUID: (date: Date, count: Int)] = [:]
    @ObservationIgnored private var youtubeArtworkShowGenerations: [UUID: UUID] = [:]
    @ObservationIgnored private var youtubeArtworkEpisodeTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var youtubeArtworkEpisodeGenerations: [UUID: UUID] = [:]
    /// Stable across a completed task; changed on force-retry or channel edit.
    @ObservationIgnored private var youtubeArtworkEpochByShow: [UUID: UUID] = [:]
    /// Tokens allow an explicit refresh to supersede a cancelled task whose
    /// previous network request has not yet unwound.
    @ObservationIgnored private var youtubeArtworkInProgress: [UUID: UUID] = [:]
    @ObservationIgnored private var youtubeArtworkRetryAfter: [UUID: Date] = [:]
    @ObservationIgnored private var youtubeShowRetryAfter: [UUID: Date] = [:]
    var hostingStatus = "Stopped"

    private static var applicationSupportRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    /// Move data written under the pre-rename product folder before any service
    /// asks for Library.json, Media, or Artwork. The legacy name is assembled so
    /// the retired branding is not retained as a live application identifier.
    static let supportFolder: URL = {
        let root = applicationSupportRoot
        let destination = root.appendingPathComponent("PodCraft", isDirectory: true)
        let legacy = root.appendingPathComponent(["Pod", "nest"].joined(), isDirectory: true)
        let fm = FileManager.default
        if fm.fileExists(atPath: legacy.path) && !fm.fileExists(atPath: destination.path) {
            do { try fm.moveItem(at: legacy, to: destination) }
            catch { NSLog("PodCraft: could not migrate application data: \(error)") }
        }
        try? fm.createDirectory(at: destination, withIntermediateDirectories: true)
        return destination
    }()
    static var storeURL: URL { supportFolder.appendingPathComponent("Library.json") }
    static var mediaFolder: URL {
        let url = supportFolder.appendingPathComponent("Media", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// `screenshot` opens an empty library and never saves.
    init(screenshot: Bool, isolatedStorageURL: URL? = nil, isolatedPreferences: UserDefaults? = nil) {
        storageURL = isolatedStorageURL ?? Self.storeURL
        preferences = isolatedPreferences ?? .standard
        persist = !screenshot
        if !screenshot, FileManager.default.fileExists(atPath: storageURL.path) {
            if let data = try? Data(contentsOf: storageURL),
               let file = try? JSONDecoder().decode(LibraryFile.self, from: data) {
                feeds = file.feeds; shows = file.shows; episodes = file.episodes
                settings = file.settings; metrics = file.metrics
                remapLegacyStoragePaths()
                // Cancel legacy automatic jobs queued for episodes already marked
                // Played before the processor starts. Never touch downloaded files.
                for i in episodes.indices where episodes[i].played && episodes[i].autoDownloaded &&
                    episodes[i].stage == .queued && episodes[i].localFile == nil {
                    episodes[i].stage = .listed
                    episodes[i].progress = 0
                    episodes[i].note = nil
                    episodes[i].autoDownloaded = false
                }
                // Preserve the exact serialized library before any one-time title or
                // transcript repair can save changes. In particular, older versions
                // stored physically shortened *-cut media with shifted timestamps.
                // Their original metadata must remain available for recovery.
                if episodes.contains(where: { $0.cutApplied && ($0.localFile?.contains("-cut.") == true) }) {
                    let backup = storageURL.deletingLastPathComponent().appendingPathComponent("Library-before-lossless-sponsors.json")
                    if !FileManager.default.fileExists(atPath: backup.path) {
                        do { try FileManager.default.copyItem(at: storageURL, to: backup) }
                        catch { NSLog("PodCraft: cannot create pre-migration backup: \(error)") }
                    }
                }
                removePlaceholders()
                capitalizeChapterTitlesOnce()
                repairSerializedChapterTitlesOnce()
                removeStoredAdChaptersOnce()
                splitLongTranscriptLinesOnce()
                restoreOriginalMediaFromLegacyCuts()
            } else {
                // Keep an unreadable library file aside instead of overwriting it.
                let aside = storageURL.deletingLastPathComponent().appendingPathComponent("Library-unreadable-\(Int(Date().timeIntervalSince1970)).json")
                try? FileManager.default.copyItem(at: storageURL, to: aside)
            }
        }
        if let raw = preferences.string(forKey: "mode"), let m = AppMode(rawValue: raw), !screenshot {
            mode = m
        }
        if !screenshot, let stored = preferences.dictionary(forKey: Self.episodeFiltersPreferenceKey) as? [String: String] {
            for (key, value) in stored {
                guard let showID = UUID(uuidString: key), let filter = EpisodeFilter(rawValue: value),
                      filter != .all else { continue }
                episodeFiltersByShow[showID] = filter
            }
        }
        manageSelection = shows.first.map { .show($0.id) } ?? feeds.first.map { .feed($0.id) }
    }

    /// Serialized media paths were absolute in older libraries. Point them at
    /// the migrated PodCraft directory without touching unrelated user files.
    private func remapLegacyStoragePaths() {
        let oldComponent = "/Application Support/" + ["Pod", "nest"].joined() + "/"
        let newComponent = "/Application Support/PodCraft/"
        func migrated(_ path: String?) -> String? {
            path?.replacingOccurrences(of: oldComponent, with: newComponent)
        }
        for index in episodes.indices {
            episodes[index].localFile = migrated(episodes[index].localFile)
            episodes[index].originalLocalFile = migrated(episodes[index].originalLocalFile)
            episodes[index].rssBackupLocalFile = migrated(episodes[index].rssBackupLocalFile)
        }
        for index in shows.indices { shows[index].customArtwork = migrated(shows[index].customArtwork) }
    }

    /// Older on-device models sometimes saved their C|line|... response syntax as a
    /// displayed chapter title. Repair only those stored strings; never rename a hand-edited
    /// title or re-run transcription to correct a formatting error.
    private func repairSerializedChapterTitlesOnce() {
        let key = "chapterResponseArtifactsFixed2"
        guard !preferences.bool(forKey: key) else { return }
        var changed = false
        for i in episodes.indices {
            for j in episodes[i].chapters.indices {
                let raw = episodes[i].chapters[j].title
                let clean = AIService.sanitizeChapterTitle(raw)
                if !clean.isEmpty && clean != raw {
                    episodes[i].chapters[j].title = AIService.formattedChapterTitle(clean)
                    changed = true
                }
            }
        }
        preferences.set(true, forKey: key)
        if changed { save() }
    }

    /// Older releases exported a separate *-cut.m4a and changed transcript/chapter times
    /// to that shortened file. Recover only when the genuine original is still on disk.
    /// Back up the old Library.json BEFORE clearing timestamps that cannot be reconciled
    /// without the historical cut boundaries, then queue a clean source-time transcription.
    private func restoreOriginalMediaFromLegacyCuts() {
        let originalExtensions = ["mp3", "m4a", "mp4", "wav", "aac", "ogg", "flac"]
        var restores: [(Int, String)] = []
        for i in episodes.indices where episodes[i].cutApplied {
            guard let file = episodes[i].localFile,
                  let cutSuffix = file.range(of: "-cut.", options: .backwards) else { continue }
            let base = String(file[..<cutSuffix.lowerBound])
            if let original = originalExtensions.map({ base + "." + $0 })
                .first(where: { FileManager.default.fileExists(atPath: $0) }) {
                restores.append((i, original))
            }
        }
        guard !restores.isEmpty else { return }
        let backup = storageURL.deletingLastPathComponent().appendingPathComponent("Library-before-lossless-sponsors.json")
        if !FileManager.default.fileExists(atPath: backup.path) {
            // If a backup cannot be made, never discard the previous transcript or metadata.
            guard (try? FileManager.default.copyItem(at: storageURL, to: backup)) != nil else { return }
        }
        for (i, original) in restores {
            episodes[i].localFile = original
            episodes[i].originalLocalFile = original
            episodes[i].duration += episodes[i].adSecondsRemoved
            episodes[i].position = 0
            episodes[i].cutApplied = false
            episodes[i].adSecondsRemoved = 0
            episodes[i].analysisFingerprint = nil
            episodes[i].transcript = []
            episodes[i].chapters = []
            episodes[i].stage = .queued
            episodes[i].note = "Original audio restored. Regenerating source-time transcript and sponsor cuts…"
        }
        save()
    }

    /// Transcripts made before lines were split into sentences can hold several sentences per line (fast speech).
    /// Re-split those once, sharing each old line's time by text length; nothing is transcribed again.
    private func splitLongTranscriptLinesOnce() {
        // v2: group into short paragraphs (split at pauses, not at every full stop), for every saved transcript.
        let key = "transcriptParagraphs2"
        guard !preferences.bool(forKey: key) else { return }
        for i in episodes.indices where !episodes[i].transcript.isEmpty {
            episodes[i].transcript = AIService.sentences(episodes[i].transcript)
        }
        preferences.set(true, forKey: key)
        save()
    }

    /// Episodes processed before chapters were remade from the ad-free transcript can still list "Ad" chapters
    /// for audio that's already gone; drop those once.
    private func removeStoredAdChaptersOnce() {
        let key = "storedAdChaptersRemoved1"
        guard !preferences.bool(forKey: key) else { return }
        for i in episodes.indices where episodes[i].cutApplied && !episodes[i].chapters.isEmpty {
            episodes[i].chapters = AIService.withoutAdChapters(episodes[i].chapters)
        }
        preferences.set(true, forKey: key)
        save()
    }

    /// Chapters made before titles were capitalised get title case once (later hand edits are left alone).
    private func capitalizeChapterTitlesOnce() {
        let key = "chapterTitlesCapitalized1"
        guard !preferences.bool(forKey: key) else { return }
        for i in episodes.indices {
            for k in episodes[i].chapters.indices {
                episodes[i].chapters[k].title = Fmt.titleCase(episodes[i].chapters[k].title)
            }
        }
        preferences.set(true, forKey: key)
        save()
    }

    /// Earlier versions started with invented sample feeds, shows and episodes: drop them.
    private func removePlaceholders() {
        let sampleTokens: Set<String> = ["m0rn1ng", "w33kend", "k1tchen"]
        let before = shows.count + feeds.count
        shows.removeAll { $0.feedURL == nil && !$0.isFiles }
        let showIDs = Set(shows.map(\.id))
        episodes.removeAll { !showIDs.contains($0.showID) || $0.isSample }
        feeds.removeAll { sampleTokens.contains($0.token) }
        let feedIDs = Set(feeds.map(\.id))
        for i in shows.indices where shows[i].feedID.map({ !feedIDs.contains($0) }) ?? false { shows[i].feedID = nil }
        if before != shows.count + feeds.count {
            metrics = Metrics()
            save()
        }
    }

    // MARK: Show page filters

    func episodeFilter(forShow showID: UUID) -> EpisodeFilter {
        episodeFiltersByShow[showID] ?? .all
    }

    func setEpisodeFilter(_ filter: EpisodeFilter, forShow showID: UUID) {
        guard show(showID) != nil, episodeFilter(forShow: showID) != filter else { return }
        if filter == .all { episodeFiltersByShow.removeValue(forKey: showID) }
        else { episodeFiltersByShow[showID] = filter }
        // In-memory screenshot libraries never write to the real defaults domain.
        // Broski fixtures supply their own UserDefaults via isolatedPreferences.
        if persist {
            let stored = Dictionary(uniqueKeysWithValues: episodeFiltersByShow.map {
                ($0.key.uuidString, $0.value.rawValue)
            })
            preferences.set(stored, forKey: Self.episodeFiltersPreferenceKey)
        }
    }

    // MARK: Mode

    func setMode(_ m: AppMode) {
        // No animation: animating this swap briefly keeps both modes' columns and title-bar items on screen at
        // once, which can make AppKit's layout loop and stop the app.
        if m != .listen { leavePersonEpisodes(restoreSelection: true) }
        mode = m
        if persist { preferences.set(m.rawValue, forKey: "mode") }
    }

    func toggleMode() { setMode(mode == .manage ? .listen : .manage) }

    /// A search the Listen page should run.
    var pendingSearch: String? = nil
    /// What's typed in the title bar's search field (Listen mode). The window's toolbar owns the field.
    var listenSearch = ""
    /// Temporary destination opened from a show's Hosts & Guests section.
    var personEpisodes: String? = nil
    private var personReturnSelection: ListenItem? = nil
    private var personReturnMode: AppMode? = nil

    func searchForPerson(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let originMode = mode
        setMode(.listen)
        personReturnMode = originMode
        personReturnSelection = listenSelection ?? .home
        listenSelection = nil // No sidebar row selected; clicking any row opens that destination.
        pendingSearch = nil
        listenSearch = ""
        personEpisodes = name
    }

    func leavePersonEpisodes(restoreSelection: Bool = false) {
        guard personEpisodes != nil else { return }
        let previous = personReturnSelection
        personEpisodes = nil
        personReturnSelection = nil
        personReturnMode = nil
        if restoreSelection { listenSelection = previous ?? .home }
    }

    func goBackFromPersonEpisodes() {
        let previousMode = personReturnMode
        leavePersonEpisodes(restoreSelection: true)
        if let previousMode { setMode(previousMode) }
    }

    /// Processing progress for one episode.
    func updateProgress(_ id: UUID, _ value: Double) {
        guard let i = episodeIndex(id), value.isFinite else { return }
        let next = min(1, max(0, value))
        let previous = episodes[i].progress
        // Progress is presentation state, not audio position. Updating the observable
        // episode on every sub-percent callback needlessly re-lays out the inspector
        // and player while downloads/transcription are active. Whole-percent updates
        // preserve visible fidelity and the exact zero/completion transitions.
        guard Int(previous * 100) != Int(next * 100) || next == 0 || next == 1 else { return }
        episodes[i].progress = next
    }

    // MARK: Lookups

    func feed(_ id: UUID?) -> Feed? { id.flatMap { id in feeds.first { $0.id == id } } }
    func show(_ id: UUID) -> Show? { shows.first { $0.id == id } }
    func episode(_ id: UUID) -> Episode? { episodes.first { $0.id == id } }
    func feedIndex(_ id: UUID) -> Int? { feeds.firstIndex { $0.id == id } }
    func showIndex(_ id: UUID) -> Int? { shows.firstIndex { $0.id == id } }
    func episodeIndex(_ id: UUID) -> Int? { episodes.firstIndex { $0.id == id } }

    func shows(in feedID: UUID) -> [Show] { shows.filter { $0.feedID == feedID } }

    var sortedShows: [Show] { shows.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending } }

    func episodes(inShow id: UUID) -> [Episode] {
        episodes.filter { $0.showID == id }.sorted { $0.published > $1.published }
    }

    func episodes(inFeed id: UUID) -> [Episode] {
        let ids = Set(shows(in: id).map(\.id))
        return episodes.filter { ids.contains($0.showID) }.sorted { $0.published > $1.published }
    }

    /// Episodes on this Mac, ready to play.
    func playable(_ list: [Episode]) -> [Episode] { list.filter { $0.stage == .ready } }
    /// Everything that can be played, downloaded or streamed.
    func listenable(_ list: [Episode]) -> [Episode] { list.filter { $0.canPlay && !isSkipped($0) } }

    /// Skipped by the show's title filter.
    func isSkipped(_ e: Episode) -> Bool { show(e.showID)?.skips(e) ?? false }

    func downloadedCount(_ showID: UUID) -> Int { episodes.filter { $0.showID == showID && $0.isDownloaded }.count }

    var continueListening: [Episode] {
        episodes.filter { $0.started && $0.canPlay }.sorted { $0.addedAt > $1.addedAt }
    }

    /// The newest unplayed episode of each show first, then the rest by date.
    var latest: [Episode] {
        episodes.filter { !$0.played && $0.canPlay }.sorted { a, b in
            if a.isDownloaded != b.isDownloaded { return a.isDownloaded }
            return a.published > b.published
        }
    }

    var inProgress: [Episode] {
        episodes.filter { $0.stage.isWorking }.sorted { $0.addedAt < $1.addedAt }
    }

    func effectiveRule(for feedID: UUID) -> KeepRule {
        feed(feedID)?.keepRule ?? settings.keepRule
    }

    // MARK: Shows

    /// Adds a show on its own (optionally into a feed): every episode is listed, only the newest
    /// `keepAvailable` are downloaded.
    @MainActor
    @discardableResult
    func addShow(_ show: Show, items: [FeedFetcher.Item]) -> UUID {
        var s = show
        if s.keepAvailable < 0 { s.keepAvailable = settings.defaultAvailable }
        shows.append(s)
        let now = Date()
        episodes.append(contentsOf: items.map { item in
            var e = item.episode(showID: s.id)
            e.addedAt = now
            e.stage = .listed
            return e
        })
        refreshAvailability(s.id)
        fetchArtwork(for: s.id)
        manageSelection = .show(s.id)
        flash("Added \(s.title)")
        save()
        ensureYouTubeArtwork(forShow: s.id)
        return s.id
    }

    func removeShow(_ id: UUID) {
        youtubeArtworkShowTasks.removeValue(forKey: id)?.cancel()
        youtubeArtworkShowGenerations.removeValue(forKey: id)
        youtubeArtworkEpochByShow.removeValue(forKey: id)
        youtubeMatchStatusesByShow.removeValue(forKey: id)
        youtubeCatalogProgressByShow.removeValue(forKey: id)
        youtubeCatalogLastScanByShow.removeValue(forKey: id)
        for e in episodes where e.showID == id {
            youtubeArtworkEpisodeTasks.removeValue(forKey: e.id)?.cancel()
            youtubeArtworkEpisodeGenerations.removeValue(forKey: e.id)
            youtubeArtworkInProgress.removeValue(forKey: e.id)
            youtubeArtworkRetryAfter.removeValue(forKey: e.id)
        }
        youtubeShowRetryAfter.removeValue(forKey: id)
        for e in episodes where e.showID == id {
            MainActor.assumeIsolated { processor?.cancel(e.id) }
            Self.deleteMedia(for: e.id)
        }
        episodes.removeAll { $0.showID == id }
        shows.removeAll { $0.id == id }
        if manageSelection == .show(id) { manageSelection = shows.first.map { .show($0.id) } }
        if listenSelection == .show(id) { listenSelection = .home }
        save()
    }

    func setFeed(_ feedID: UUID?, forShow showID: UUID) {
        guard let i = showIndex(showID) else { return }
        shows[i].feedID = feedID
        save()
    }

    /// Save edits from the show editor and apply them (filters, availability, artwork).
    func updateShow(_ edited: Show) {
        guard let i = showIndex(edited.id) else { return }
        let previous = shows[i]
        shows[i] = edited
        if previous.youtubeChannelURL != edited.youtubeChannelURL {
            shows[i].youtubeCatalogRevision = 0
            shows[i].youtubeCatalogScannedAt = nil
            shows[i].youtubeCatalogScannedEpisodeCount = 0
            shows[i].youtubeCatalogScannedChannelURL = nil
            // A previously verified thumbnail belongs to a specific
            // official channel. On a channel change, remove only this
            // metadata, never a physically downloaded source recording.
            // The episode then safely shows its normal show artwork until
            // the replacement channel independently verifies a match.
            for j in episodes.indices where episodes[j].showID == edited.id {
                episodes[j].youtubeMatchState = .untried
                episodes[j].youtubeMatchChannelURL = nil
                if artworkAlreadyVerified(for: episodes[j]) {
                    episodes[j].artworkURL = nil
                    if episodes[j].youtubeMediaID == nil { episodes[j].youtubeID = nil }
                }
            }
            // Only downloaded episodes need a source replacement. Never relabel their
            // old transcript/cut times as if those belonged to the YouTube recording.
            for j in episodes.indices where episodes[j].showID == edited.id &&
                episodes[j].localFile != nil && !episodes[j].played && !episodes[j].stage.isWorking {
                episodes[j].stage = .queued
                episodes[j].note = "Checking preferred playback source…"
            }
        }
        for e in episodes where e.showID == edited.id && edited.skips(e) && e.autoDownloaded && e.stage != .listed && !e.started {
            removeDownload(e.id, save: false)
        }
        refreshAvailability(edited.id)
        artworkVersion += 1
        let srv = server
        Task { @MainActor in srv?.invalidateArtwork() }
        save()
        if previous.youtubeChannelURL != edited.youtubeChannelURL {
            youtubeArtworkShowTasks.removeValue(forKey: edited.id)?.cancel()
            youtubeArtworkShowGenerations.removeValue(forKey: edited.id)
            youtubeArtworkEpochByShow[edited.id] = UUID()
            youtubeMatchStatusesByShow[edited.id] = .idle
            youtubeCatalogProgressByShow.removeValue(forKey: edited.id)
            youtubeCatalogLastScanByShow.removeValue(forKey: edited.id)
            for episode in episodes where episode.showID == edited.id {
                youtubeArtworkEpisodeTasks.removeValue(forKey: episode.id)?.cancel()
                youtubeArtworkEpisodeGenerations.removeValue(forKey: episode.id)
                youtubeArtworkInProgress.removeValue(forKey: episode.id)
                youtubeArtworkRetryAfter.removeValue(forKey: episode.id)
            }
            youtubeShowRetryAfter.removeValue(forKey: edited.id)
        }
        Task { @MainActor [weak self] in self?.ensureYouTubeArtwork(forShow: edited.id) }
    }

    func setKeepAvailable(_ n: Int, forShow showID: UUID) {
        guard let i = showIndex(showID) else { return }
        shows[i].keepAvailable = max(0, n)
        refreshAvailability(showID)
        save()
    }

    /// Keep the newest N episodes of a show on this Mac. Played episodes still
    /// occupy their place in the newest-N window, but never trigger an automatic
    /// download. Do not backfill older episodes merely because newer ones were played.
    /// Manual downloads remain available for played episodes.
    func refreshAvailability(_ showID: UUID) {
        guard let s = show(showID), !s.isFiles else { return }
        // Index once and sort the indices: the old implementation scanned all
        // episodes to resolve each UUID separately (quadratic on large RSS feeds).
        let ordered = episodes.indices.filter { episodes[$0].showID == showID && !s.skips(episodes[$0]) }
            .sorted { episodes[$0].published > episodes[$1].published }
        for (rank, k) in ordered.enumerated() {
            guard episodes[k].audioURL != nil else { continue }
            if rank < s.keepAvailable {
                if episodes[k].played {
                    // A finished episode must not consume a new automatic
                    // transfer, even if a feed refresh started it moments ago.
                    // Cancel only jobs without committed media; never erase a
                    // previously downloaded or manually requested recording.
                    if episodes[k].autoDownloaded && episodes[k].stage.isWorking &&
                        episodes[k].localFile == nil {
                        let id = episodes[k].id
                        MainActor.assumeIsolated { processor?.cancel(id) }
                        episodes[k].stage = .listed
                        episodes[k].progress = 0
                        episodes[k].note = nil
                        episodes[k].autoDownloaded = false
                    }
                } else if episodes[k].stage == .listed {
                    episodes[k].stage = .queued
                    episodes[k].progress = 0
                    episodes[k].autoDownloaded = true
                }
            } else if episodes[k].autoDownloaded && !episodes[k].keepForever && !episodes[k].started
                        && (episodes[k].stage == .ready || episodes[k].stage == .queued || episodes[k].stage == .failed) {
                removeDownload(episodes[k].id, save: false)
            }
        }
    }

    // MARK: Episodes

    /// Download one episode by hand (kept until you remove it).
    func download(_ id: UUID) {
        guard let i = episodeIndex(id), episodes[i].stage == .listed || episodes[i].stage == .failed else { return }
        episodes[i].stage = .queued
        episodes[i].progress = 0
        episodes[i].autoDownloaded = false
        episodes[i].note = nil
        save()
        Task { @MainActor [weak self] in self?.ensureYouTubeArtwork(forEpisode: id) }
    }

    /// Playback can opportunistically fill in transcript/chapters. The processor owns the
    /// one-at-a-time task queue, so repeated play clicks cannot create competing analysis jobs.
    // MARK: Transcript language

    /// The language a passage of text is written in, when the recogniser is confident ("es", "en").
    static func detectLanguage(_ text: String) -> String? {
        let r = NLLanguageRecognizer()
        r.processString(text)
        guard let (lang, p) = r.languageHypotheses(withMaximum: 1).first, p >= 0.6 else { return nil }
        return lang.rawValue
    }

    static func baseLanguage(_ code: String) -> String {
        String(code.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "")
    }

    /// The language an episode should be transcribed in: its own tag, its show's tag, or detected from
    /// its title and description. Nil means "use this Mac's language".
    func expectedLanguage(for e: Episode) -> String? {
        if let l = e.language, !l.isEmpty { return l }
        let s = show(e.showID)
        if let l = s?.language, !l.isEmpty { return l }
        return Self.detectLanguage([e.title, e.summary, s?.title ?? "", s?.summary ?? ""].joined(separator: ". "))
    }

    /// A transcript made before languages were chosen per episode was always made in this Mac's language. If the
    /// episode is in another language (Spanish speech written as phonetic English), it needs redoing. (Reading the
    /// old words to guess their language isn't reliable: garbled phonetic text can look like either language.)
    func transcriptLooksWrongLanguage(_ e: Episode) -> Bool {
        guard !e.transcript.isEmpty, let want = expectedLanguage(for: e) else { return false }
        let madeIn = e.transcriptLanguage ?? Locale.current.identifier
        return Self.baseLanguage(madeIn) != Self.baseLanguage(want)
    }

    func analyzeIfNeededForPlayback(_ id: UUID) {
        guard let i = episodeIndex(id), !episodes[i].stage.isWorking else { return }
        if episodes[i].localFile != nil, transcriptLooksWrongLanguage(episodes[i]) {
            // Redo it in the right language; chapters come from the new transcript.
            let name = expectedLanguage(for: episodes[i]).flatMap { Locale.current.localizedString(forLanguageCode: $0) } ?? "its language"
            reanalyze(id, retranscribe: true)
            if let k = episodeIndex(id) { episodes[k].note = "Transcribing again in \(name)…" }
            save()
            return
        }
        let needsTranscript = settings.transcribe && episodes[i].transcript.isEmpty
        let needsChapters = settings.generateChapters && settings.aiProvider != .off && episodes[i].chapters.isEmpty
        guard needsTranscript || needsChapters else { return }
        episodes[i].stage = .queued
        episodes[i].progress = 0
        episodes[i].note = "Preparing transcript and chapters in the background…"
        save()
    }

    /// Explicitly queue a fresh analysis pass. Retranscription discards the old words;
    /// chapter-only regeneration reuses them and is consequently much faster.
    func reanalyze(_ id: UUID, retranscribe: Bool) {
        guard let i = episodeIndex(id), episodes[i].localFile != nil, !episodes[i].stage.isWorking else { return }
        if retranscribe { episodes[i].transcript = [] }
        episodes[i].chapters = []
        episodes[i].analysisFingerprint = nil
        episodes[i].cuts.removeAll { $0.source == "AI" }
        episodes[i].stage = .queued
        episodes[i].progress = 0
        episodes[i].note = retranscribe ? "Queued for fresh transcription…" : "Queued for fresh chapter analysis…"
        save()
    }

    /// Remove the downloaded copy; the episode stays listed and can be downloaded again.
    func removeDownload(_ id: UUID, save shouldSave: Bool = true) {
        guard let i = episodeIndex(id) else { return }
        guard episodes[i].audioURL != nil, !(show(episodes[i].showID)?.isFiles ?? false) else { return }   // your own files stay
        // Invalidate an in-flight parallel transfer *before* removing the file
        // and moving the episode back to Listed. A late URLSession/yt-dlp
        // completion must never resurrect a user-cancelled download.
        MainActor.assumeIsolated { processor?.cancel(id) }
        Self.deleteMedia(for: id)
        if episodes[i].cutApplied { episodes[i].chapters = []; episodes[i].transcript = [] }
        episodes[i].localFile = nil
        episodes[i].originalLocalFile = nil
        episodes[i].rssBackupLocalFile = nil
        episodes[i].youtubeMediaID = nil
        episodes[i].isVideo = episodes[i].audioURL.map {
            ["mp4", "m4v", "mov", "webm"].contains(URL(string: $0)?.pathExtension.lowercased() ?? "")
        } ?? false
        episodes[i].stage = .listed
        episodes[i].progress = 0
        episodes[i].note = nil
        episodes[i].cuts = []
        episodes[i].cutApplied = false
        episodes[i].adSecondsRemoved = 0
        episodes[i].autoDownloaded = false
        if shouldSave { save() }
    }

    func deleteEpisode(_ id: UUID) {
        MainActor.assumeIsolated { processor?.cancel(id) }
        youtubeArtworkEpisodeTasks.removeValue(forKey: id)?.cancel()
        youtubeArtworkEpisodeGenerations.removeValue(forKey: id)
        youtubeArtworkInProgress.removeValue(forKey: id)
        youtubeArtworkRetryAfter.removeValue(forKey: id)
        Self.deleteMedia(for: id)
        episodes.removeAll { $0.id == id }
        save()
    }

    static func deleteMedia(for id: UUID) {
        let folder = mediaFolder
        let prefix = id.uuidString
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    func setPlayed(_ id: UUID, _ played: Bool) {
        guard let i = episodeIndex(id) else { return }
        episodes[i].played = played
        episodes[i].position = played ? episodes[i].playbackDuration : 0
        refreshAvailability(episodes[i].showID)
        save()
    }

    // MARK: Feeds

    @discardableResult
    func addFeed(title: String = "New Feed") -> UUID {
        let f = Feed(title: title, author: "You", summary: "Group the shows and files you want to follow into one feed.",
                     hue: Double.random(in: 0...1), borderHue: Double.random(in: 0...1),
                     localOnly: settings.localOnlyByDefault)
        feeds.append(f)
        manageSelection = .feed(f.id)
        save()
        return f.id
    }

    /// Deletes the feed only; its shows stay in your library.
    func deleteFeed(_ id: UUID) {
        for i in shows.indices where shows[i].feedID == id { shows[i].feedID = nil }
        feeds.removeAll { $0.id == id }
        manageSelection = shows.first.map { .show($0.id) } ?? feeds.first.map { .feed($0.id) }
        save()
    }

    func removeAllDownloads(inFeed id: UUID) {
        for e in episodes(inFeed: id) where e.isDownloaded { removeDownload(e.id, save: false) }
        save()
    }

    // MARK: Checking for new episodes

    @MainActor
    func checkForNewEpisodes(notify: Bool = true) {
        guard !checking else { return }
        let linked = shows.filter { !$0.isFiles && $0.feedURL != nil }
        guard !linked.isEmpty else { if notify { flash("Add a show to check for new episodes.") }; return }
        checking = true
        Task { @MainActor in
            // Feed requests are independent. Fetch a small batch concurrently, then
            // merge results on the main actor so a single slow host cannot stall all shows.
            let targets = linked.compactMap { show -> (UUID, URL)? in
                guard let raw = show.feedURL, let url = URL(string: raw) else { return nil }
                return (show.id, url)
            }
            var fetched: [(UUID, FeedFetcher.Parsed)] = []
            await withTaskGroup(of: (UUID, FeedFetcher.Parsed?).self) { group in
                var iterator = targets.makeIterator()
                for _ in 0..<min(4, targets.count) {
                    if let target = iterator.next() {
                        group.addTask { (target.0, try? await FeedFetcher.fetch(target.1)) }
                    }
                }
                while let result = await group.next() {
                    if let parsed = result.1 { fetched.append((result.0, parsed)) }
                    if let target = iterator.next() {
                        group.addTask { (target.0, try? await FeedFetcher.fetch(target.1)) }
                    }
                }
            }
            var added = 0
            for (id, parsed) in fetched { added += self.mergeFeed(parsed, into: id, saveAfter: false) }
            if !fetched.isEmpty { self.applyKeepRules(); self.save() }
            self.checking = false
            if notify || added > 0 { self.flash(added == 0 ? "No new episodes." : "\(added) new episodes.") }
        }
    }

    /// Queue downloaded episodes that do not yet have chapters. The processor creates a transcript
    /// first when needed, then derives topic chapters from it with the selected AI provider.
    @MainActor
    func generateMissingChapters() {
        var queued = 0
        for i in episodes.indices where episodes[i].isDownloaded && episodes[i].chapters.isEmpty {
            episodes[i].stage = .queued
            episodes[i].progress = 0
            episodes[i].note = nil
            queued += 1
        }
        if queued > 0 {
            save()
            flash("Generating chapters for \(queued) downloaded \(queued == 1 ? "episode" : "episodes")")
        }
    }

    /// Re-read one show's feed: new episodes are listed and the newest are downloaded.
    @MainActor
    @discardableResult
    func refreshShow(_ id: UUID) async -> Int {
        guard let show = show(id), let link = show.feedURL, let url = URL(string: link),
              let parsed = try? await FeedFetcher.fetch(url) else { return 0 }
        return mergeFeed(parsed, into: id, saveAfter: true)
    }

    /// One merge path for manual refresh and the batched background refresh.
    @MainActor
    private func mergeFeed(_ parsed: FeedFetcher.Parsed, into id: UUID, saveAfter: Bool) -> Int {
        guard show(id) != nil else { return 0 }
        var known = Set(episodes.filter { $0.showID == id }
            .map { $0.guid ?? $0.audioURL ?? $0.title })
        let now = Date()
        var added = 0
        for item in parsed.items {
            // A feed can repeat a GUID within one response. Update the set as items
            // are appended so repeated entries do not create duplicate episodes.
            guard known.insert(item.guid ?? item.audioURL ?? item.title).inserted else { continue }
            var e = item.episode(showID: id)
            e.addedAt = now
            e.stage = .listed
            episodes.append(e)
            added += 1
        }
        if let i = showIndex(id) {
            if shows[i].artworkURL == nil { shows[i].artworkURL = parsed.artwork }
            if shows[i].summary.isEmpty { shows[i].summary = parsed.summary }
            if let l = parsed.language, !l.isEmpty { shows[i].language = l }
        }
        refreshAvailability(id)
        if saveAfter { applyKeepRules() }
        fetchArtwork(for: id)
        if saveAfter { save() }
        ensureYouTubeArtwork(forShow: id)
        return added
    }

    @MainActor
    func importFiles(_ urls: [URL]) {
        var filesShow = shows.first { $0.isFiles }
        if filesShow == nil {
            let s = Show(title: "My Files", author: "You", hue: 0.6, isFiles: true, keepAvailable: 0)
            shows.append(s)
            filesShow = s
        }
        guard let target = filesShow else { return }
        for url in urls {
            let ext = url.pathExtension.lowercased()
            let e = Episode(showID: target.id, title: url.deletingPathExtension().lastPathComponent,
                            summary: "Imported from \(url.lastPathComponent)", published: Date(), addedAt: Date(),
                            duration: 0, audioURL: url.absoluteString, guid: url.absoluteString,
                            stage: .queued, isVideo: Mechanics.videoExtensions.contains(ext))
            let id = e.id
            episodes.append(e)
            Task { @MainActor in
                let asset = AVURLAsset(url: url)
                if let d = try? await asset.load(.duration), let i = self.episodeIndex(id) {
                    self.episodes[i].duration = max(1, d.seconds.isFinite ? d.seconds : 0)
                    self.save()
                }
            }
        }
        manageSelection = .show(target.id)
        flash("Import was handed to the processing queue.")
        save()
    }

    // MARK: Feed keep rules (remove old downloads; episodes stay listed)

    func applyKeepRules() {
        let now = Date()
        for feed in feeds {
            let downloaded = episodes(inFeed: feed.id).filter { $0.isDownloaded && !$0.keepForever && !$0.started }
            switch effectiveRule(for: feed.id) {
            case .forever: break
            case .days(let d):
                for e in downloaded where now.timeIntervalSince(e.addedAt) > Double(d) * 86_400 { removeDownload(e.id, save: false) }
            case .newest(let n):
                for e in downloaded.dropFirst(n) { removeDownload(e.id, save: false) }
            }
        }
    }

    // MARK: Artwork

    /// Human-readable status for ShowViews and ShowEditor. The richer enum
    /// remains observable as youtubeMatchStatusesByShow.
    @MainActor
    func youtubeMatchStatus(forShow showID: UUID) -> String {
        let progress = youtubeCatalogProgressByShow[showID]
        let total = progress?.total ?? episodes.filter {
            $0.showID == showID && $0.audioURL != nil
        }.count
        switch youtubeMatchState(forShow: showID) {
        case .verified:
            return "Official YouTube catalog checked • \(matchedVideoCount(forShow: showID)) of \(total) episodes matched"
        case .idle:
            return show(showID)?.youtubeChannelURL == nil
                ? "Not checked — find the official YouTube channel"
                : "Official channel linked — archive not checked"
        case .checking:
            if let progress {
                return "Checking official YouTube archive • \(progress.checked) / \(progress.total) episodes"
            }
            return "Finding official YouTube channel…"
        case .noMatch:
            return show(showID)?.youtubeChannelURL == nil
                ? "No official YouTube channel confirmed — Find Again to retry"
                : "No archive matches confirmed among \(total) episodes — Find Again to retry"
        case .error(let reason): return reason
        }
    }

    @MainActor
    func youtubeMatchState(forShow showID: UUID) -> YouTubeMatchStatus {
        guard let current = show(showID) else { return .error("Show no longer exists") }
        guard !current.isFiles, current.feedURL != nil else {
            return .error("YouTube matching requires a podcast RSS feed")
        }
        guard YouTubeSource.available else {
            return .error("yt-dlp is unavailable. Install yt-dlp or use PodCraft with bundled YouTube tools.")
        }
        if let state = youtubeMatchStatusesByShow[showID] {
            // A successful lazy match can arrive after a bulk scan that
            // found none; do not display a stale negative.
            if case .noMatch = state, matchedVideoCount(forShow: showID) > 0 { return .verified }
            return state
        }
        if matchedVideoCount(forShow: showID) > 0 { return .verified }
        if current.youtubeCatalogRevision >= 1,
           current.youtubeCatalogScannedAt != nil,
           current.youtubeCatalogScannedChannelURL == current.youtubeChannelURL,
           current.youtubeCatalogScannedEpisodeCount ==
                episodes.filter({ $0.showID == showID && $0.audioURL != nil }).count {
            return .noMatch
        }
        return .idle
    }

    @MainActor
    func matchedVideoCount(forShow showID: UUID) -> Int {
        guard let channel = show(showID)?.youtubeChannelURL, !channel.isEmpty else { return 0 }
        return episodes.reduce(into: 0) { result, e in
            if e.showID == showID, e.youtubeMatchState == .matched,
               let videoID = e.youtubeID,
               e.youtubeMatchChannelURL == channel ||
               (e.youtubeMatchChannelURL == nil &&
                (artworkAlreadyVerified(for: e) || e.youtubeMediaID == videoID)) {
                result += 1
            }
        }
    }

    @MainActor
    func currentYouTubeChannel(forShow showID: UUID) -> String? {
        show(showID)?.youtubeChannelURL
    }

    /// Explicit Find Again bypasses automatic 10/30-minute cooldowns and
    /// forces a fresh full-catalog scan. No media or ASR data is modified.
    @MainActor
    func refreshYouTubeMatches(forShow showID: UUID) {
        scheduleYouTubeArtwork(forShow: showID, force: true)
    }

    @MainActor
    private func catalogEpisodes(forShow showID: UUID) -> [Episode] {
        episodes.filter { $0.showID == showID && $0.audioURL != nil }
            .sorted { $0.published > $1.published }
    }

    /// Called by the app at launch. Existing shows are indexed one at a time,
    /// without blocking the UI or repeating searches for every RSS episode.
    @MainActor
    func startCatalogMatchingForSavedShows() {
        guard persist, youtubeCatalogStartupTask == nil else { return }
        let ids = shows.filter { !$0.isFiles && $0.feedURL != nil }.map(\.id)
        guard !ids.isEmpty else { return }
        let generation = UUID()
        youtubeCatalogStartupGeneration = generation
        youtubeCatalogStartupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.youtubeCatalogStartupGeneration == generation {
                    self.youtubeCatalogStartupTask = nil
                    self.youtubeCatalogStartupGeneration = nil
                }
            }
            for id in ids {
                guard !Task.isCancelled else { return }
                self.ensureYouTubeArtwork(forShow: id)
                if let task = self.youtubeArtworkShowTasks[id] { await task.value }
            }
        }
    }

    /// Show onboarding and refreshed feeds schedule the same full-channel
    /// metadata scan. Media/timestamps still need independent watch verification.
    @MainActor
    func ensureYouTubeArtwork(forShow showID: UUID) {
        scheduleYouTubeArtwork(forShow: showID, force: false)
    }

    @MainActor
    private func scheduleYouTubeArtwork(forShow showID: UUID, force: Bool) {
        guard persist, let current = show(showID), !current.isFiles, current.feedURL != nil else { return }
        if force {
            youtubeArtworkShowTasks.removeValue(forKey: showID)?.cancel()
            youtubeArtworkShowGenerations.removeValue(forKey: showID)
            youtubeShowRetryAfter.removeValue(forKey: showID)
            youtubeCatalogLastScanByShow.removeValue(forKey: showID)
        } else if youtubeArtworkShowTasks[showID] != nil ||
                    (youtubeShowRetryAfter[showID] ?? .distantPast) > Date() { return }
        let allEpisodes = catalogEpisodes(forShow: showID)
        if !force, let last = youtubeCatalogLastScanByShow[showID],
           Date().timeIntervalSince(last.date) < 24 * 60 * 60,
           last.count == allEpisodes.count { return }
        if !force, current.youtubeCatalogRevision >= 1,
           let last = current.youtubeCatalogScannedAt,
           Date().timeIntervalSince(last) < 24 * 60 * 60,
           current.youtubeCatalogScannedEpisodeCount == allEpisodes.count,
           current.youtubeCatalogScannedChannelURL == current.youtubeChannelURL { return }

        // Invalidate old per-episode requests before the archive job starts.
        // Their callbacks must never overwrite a newer catalog candidate.
        let epoch = UUID()
        youtubeArtworkEpochByShow[showID] = epoch
        for episode in allEpisodes {
            youtubeArtworkEpisodeTasks.removeValue(forKey: episode.id)?.cancel()
            youtubeArtworkEpisodeGenerations.removeValue(forKey: episode.id)
            youtubeArtworkInProgress.removeValue(forKey: episode.id)
            if force { youtubeArtworkRetryAfter.removeValue(forKey: episode.id) }
        }
        if force {
            var cleared = false
            if let index = showIndex(showID), shows[index].youtubeCatalogScannedAt != nil {
                shows[index].youtubeCatalogScannedAt = nil
                cleared = true
            }
            for i in episodes.indices where episodes[i].showID == showID &&
                episodes[i].youtubeMatchState == .notFound {
                episodes[i].youtubeMatchState = .untried
                episodes[i].youtubeMatchChannelURL = nil
                if episodes[i].youtubeMediaID == nil { episodes[i].youtubeID = nil }
                cleared = true
            }
            if cleared { save() }
        }
        guard YouTubeSource.available else {
            youtubeMatchStatusesByShow[showID] = .error(
                "yt-dlp is unavailable. Install yt-dlp or use PodCraft with bundled YouTube tools.")
            return
        }
        youtubeMatchStatusesByShow[showID] = .checking
        youtubeCatalogProgressByShow[showID] = .init(checked: 0, total: allEpisodes.count)
        let generation = UUID()
        youtubeArtworkShowGenerations[showID] = generation
        let previous = youtubeCatalogTaskTail
        let job = Task { @MainActor [weak self] in
            defer {
                // A channel edit can cancel this task and start a replacement
                // before the old task actually unwinds. The old completion
                // must never erase the newer task from the deduplication map.
                if self?.youtubeArtworkShowGenerations[showID] == generation {
                    self?.youtubeArtworkShowTasks.removeValue(forKey: showID)
                    self?.youtubeArtworkShowGenerations.removeValue(forKey: showID)
                }
            }
            // Only one yt-dlp official-channel listing runs at a time across
            // shows, including onboarding and manual Find Again requests.
            if let previous { await previous.value }
            guard let self, !Task.isCancelled, self.youtubeArtworkEpochByShow[showID] == epoch,
                  self.youtubeArtworkShowGenerations[showID] == generation,
                  let initial = self.show(showID) else { return }
            var channel = initial.youtubeChannelURL
            if channel == nil || channel?.isEmpty == true {
                do {
                    // The library's discovery cache uses Show.id in its key.
                    // A temporary identity makes an explicit retry independent
                    // of a previously cached safe no-match.
                    var probe = initial
                    if force { probe.id = UUID() }
                    let discovered = try await YouTubeSource.discoverChannel(show: probe)
                    guard !Task.isCancelled, self.youtubeArtworkEpochByShow[showID] == epoch,
                          self.youtubeArtworkShowGenerations[showID] == generation,
                          let stillHere = self.show(showID) else { return }
                    if let discovered {
                        channel = discovered.channelURL.absoluteString
                        // Do not override an explicit channel link edited while
                        // remote verification was in progress.
                        if stillHere.youtubeChannelURL == nil || stillHere.youtubeChannelURL?.isEmpty == true,
                           let i = self.showIndex(showID) {
                            self.shows[i].youtubeChannelURL = channel
                            self.save()
                        } else {
                            channel = stillHere.youtubeChannelURL
                        }
                    } else {
                        self.youtubeShowRetryAfter[showID] = Date().addingTimeInterval(30 * 60)
                        self.youtubeMatchStatusesByShow[showID] = self.matchedVideoCount(forShow: showID) > 0
                            ? .verified : .noMatch
                        return
                    }
                } catch is CancellationError { return }
                catch {
                    guard !Task.isCancelled, self.youtubeArtworkEpochByShow[showID] == epoch,
                          self.youtubeArtworkShowGenerations[showID] == generation else { return }
                    self.youtubeShowRetryAfter[showID] = Date().addingTimeInterval(10 * 60)
                    self.youtubeMatchStatusesByShow[showID] = .error(
                        "Official YouTube discovery failed: \(error.localizedDescription). Try Find Again.")
                    return
                }
            }
            guard !Task.isCancelled, self.youtubeArtworkEpochByShow[showID] == epoch,
                  self.youtubeArtworkShowGenerations[showID] == generation,
                  let channel, !channel.isEmpty,
                  self.show(showID)?.youtubeChannelURL == channel else { return }
            do {
                // catalogMatches reads the channel listing once and compares
                // every RSS title/duration against that same indexed snapshot.
                // Its missing IDs are UNCONFIRMED, never a verified negative.
                let candidates = try await YouTubeSource.catalogMatches(
                    episodes: allEpisodes, channelURL: channel)
                guard !Task.isCancelled, self.youtubeArtworkEpochByShow[showID] == epoch,
                      self.youtubeArtworkShowGenerations[showID] == generation,
                      self.show(showID)?.youtubeChannelURL == channel else { return }

                // Existing confirmed positives always win, including over a
                // conflicting provisional candidate for another RSS episode.
                var claimed: [String: UUID] = [:]
                for episode in self.catalogEpisodes(forShow: showID)
                    where episode.youtubeMatchState == .matched {
                    guard let videoID = episode.youtubeID,
                          episode.youtubeMatchChannelURL == channel ||
                          (episode.youtubeMatchChannelURL == nil &&
                           (self.artworkAlreadyVerified(for: episode) ||
                            episode.youtubeMediaID == videoID)) else { continue }
                    claimed[videoID] = episode.id
                }
                var accepted: [UUID: YouTubeSource.Video] = [:]
                for (offset, episode) in allEpisodes.enumerated() {
                    if let candidate = candidates[episode.id],
                       let existingClaim = claimed[candidate.id] {
                        if existingClaim == episode.id { accepted[episode.id] = candidate }
                    } else if let candidate = candidates[episode.id] {
                        accepted[episode.id] = candidate
                        claimed[candidate.id] = episode.id
                    }
                    if (offset + 1) % 100 == 0 || offset + 1 == allEpisodes.count {
                        self.youtubeCatalogProgressByShow[showID] = .init(
                            checked: offset + 1, total: allEpisodes.count)
                        await Task.yield()
                        guard !Task.isCancelled, self.youtubeArtworkEpochByShow[showID] == epoch,
                              self.youtubeArtworkShowGenerations[showID] == generation,
                              self.show(showID)?.youtubeChannelURL == channel else { return }
                    }
                }

                // One commit, one JSON serialization for the entire show.
                // Legacy .notFound values originated in a truncated archive;
                // release them for later verification if no positive is found.
                guard let showIndex = self.showIndex(showID) else { return }
                var changed = false
                for index in self.episodes.indices where self.episodes[index].showID == showID {
                    let entry = self.episodes[index]
                    if let video = accepted[entry.id] {
                        let confirmed = entry.youtubeMatchState == .matched &&
                            entry.youtubeID != nil &&
                            (entry.youtubeMatchChannelURL == channel ||
                             (entry.youtubeMatchChannelURL == nil &&
                              (self.artworkAlreadyVerified(for: entry) ||
                               entry.youtubeMediaID == entry.youtubeID)))
                        if !confirmed {
                            self.episodes[index].youtubeID = video.id
                            self.episodes[index].youtubeMatchState = .matched
                            self.episodes[index].youtubeMatchChannelURL = channel
                            changed = true
                        }
                        self.youtubeArtworkRetryAfter.removeValue(forKey: entry.id)
                    } else if entry.youtubeMatchState == .notFound &&
                              (force || self.shows[showIndex].youtubeCatalogRevision < 1) {
                        self.episodes[index].youtubeMatchState = .untried
                        self.episodes[index].youtubeMatchChannelURL = nil
                        if entry.youtubeMediaID == nil { self.episodes[index].youtubeID = nil }
                        self.youtubeArtworkRetryAfter.removeValue(forKey: entry.id)
                        changed = true
                    }
                }
                if self.shows[showIndex].youtubeCatalogRevision < 1 {
                    self.shows[showIndex].youtubeCatalogRevision = 1
                }
                self.shows[showIndex].youtubeCatalogScannedAt = Date()
                self.shows[showIndex].youtubeCatalogScannedEpisodeCount = allEpisodes.count
                self.shows[showIndex].youtubeCatalogScannedChannelURL = channel
                changed = true
                if changed { self.save() }
                self.youtubeCatalogLastScanByShow[showID] = (Date(), allEpisodes.count)
                self.youtubeMatchStatusesByShow[showID] =
                    self.matchedVideoCount(forShow: showID) > 0 ? .verified : .noMatch
            } catch is CancellationError { return }
            catch {
                guard !Task.isCancelled, self.youtubeArtworkEpochByShow[showID] == epoch,
                      self.youtubeArtworkShowGenerations[showID] == generation else { return }
                self.youtubeShowRetryAfter[showID] = Date().addingTimeInterval(10 * 60)
                self.youtubeMatchStatusesByShow[showID] = .error(
                    "YouTube archive lookup failed: \(error.localizedDescription). Try Find Again.")
            }
        }
        youtubeArtworkShowTasks[showID] = job
        youtubeCatalogTaskTail = job
    }

    /// Playback can still request a watch-page verification when the bulk
    /// metadata listing could not confirm an individual RSS episode.
    @MainActor
    func ensureYouTubeArtwork(forEpisode id: UUID) {
        guard persist, let episode = episode(id), episode.audioURL != nil,
              let show = show(episode.showID), !show.isFiles, show.feedURL != nil,
              !artworkAlreadyVerified(for: episode),
              youtubeArtworkEpisodeTasks[id] == nil,
              (youtubeArtworkRetryAfter[id] ?? .distantPast) <= Date() else { return }
        let showID = show.id
        if episode.youtubeMatchState == .matched, episode.youtubeID != nil,
           let channel = show.youtubeChannelURL,
           episode.youtubeMatchChannelURL == channel { return }
        if show.youtubeCatalogRevision >= 1,
           let channel = show.youtubeChannelURL, episode.youtubeMatchState == .notFound,
           episode.youtubeMatchChannelURL == channel { return }
        guard YouTubeSource.available else {
            youtubeMatchStatusesByShow[showID] = .error(
                "yt-dlp is unavailable. Install yt-dlp or use PodCraft with bundled YouTube tools.")
            return
        }
        let marker = UUID()
        youtubeArtworkEpisodeGenerations[id] = marker
        youtubeArtworkEpisodeTasks[id] = Task { @MainActor [weak self] in
            defer {
                if let self, self.youtubeArtworkEpisodeGenerations[id] == marker {
                    self.youtubeArtworkEpisodeTasks.removeValue(forKey: id)
                    self.youtubeArtworkEpisodeGenerations.removeValue(forKey: id)
                }
            }
            guard let self, !Task.isCancelled else { return }
            if self.show(showID)?.youtubeChannelURL == nil {
                self.ensureYouTubeArtwork(forShow: showID)
                if let discovery = self.youtubeArtworkShowTasks[showID] { await discovery.value }
            }
            guard !Task.isCancelled, let channel = self.show(showID)?.youtubeChannelURL,
                  !channel.isEmpty else { return }
            let epoch = self.youtubeArtworkEpochByShow[showID] ?? UUID()
            if self.youtubeArtworkEpochByShow[showID] == nil {
                self.youtubeArtworkEpochByShow[showID] = epoch
            }
            let outcome = await self.matchYouTubeArtwork(for: id, channel: channel,
                                                         epoch: epoch, force: false)
            if !Task.isCancelled, self.youtubeArtworkShowTasks[showID] == nil {
                self.publishYouTubeLookupOutcome(outcome, showID: showID)
            }
        }
    }

    /// Force a new individual match beyond the most recent five episodes.
    /// This is separate from automatic playback, which never repeats a known
    /// negative result for the same official channel.
    @MainActor
    func retryYouTubeMatch(forEpisode id: UUID) {
        guard persist, let e = episode(id), e.audioURL != nil,
              let s = show(e.showID), !s.isFiles, s.feedURL != nil else { return }
        guard YouTubeSource.available else {
            youtubeMatchStatusesByShow[s.id] = .error(
                "yt-dlp is unavailable. Install yt-dlp or use PodCraft with bundled YouTube tools.")
            return
        }
        youtubeArtworkEpisodeTasks.removeValue(forKey: id)?.cancel()
        youtubeArtworkEpisodeGenerations.removeValue(forKey: id)
        youtubeArtworkInProgress.removeValue(forKey: id)
        youtubeArtworkRetryAfter.removeValue(forKey: id)
        if let i = episodeIndex(id), episodes[i].youtubeMatchState == .notFound {
            episodes[i].youtubeMatchState = .untried
            episodes[i].youtubeMatchChannelURL = nil
            save()
        }
        // Schedule discovery BEFORE installing the episode retry task:
        // forcing discovery cancels earlier episode jobs on this show.
        if s.youtubeChannelURL == nil {
            refreshYouTubeMatches(forShow: s.id)
        }
        let marker = UUID()
        youtubeArtworkEpisodeGenerations[id] = marker
        youtubeArtworkEpisodeTasks[id] = Task { @MainActor [weak self] in
            defer {
                if let self, self.youtubeArtworkEpisodeGenerations[id] == marker {
                    self.youtubeArtworkEpisodeTasks.removeValue(forKey: id)
                    self.youtubeArtworkEpisodeGenerations.removeValue(forKey: id)
                }
            }
            guard let self, !Task.isCancelled else { return }
            if self.show(s.id)?.youtubeChannelURL == nil {
                if let job = self.youtubeArtworkShowTasks[s.id] { await job.value }
            }
            guard !Task.isCancelled, let channel = self.show(s.id)?.youtubeChannelURL,
                  !channel.isEmpty else { return }
            let epoch = self.youtubeArtworkEpochByShow[s.id] ?? UUID()
            if self.youtubeArtworkEpochByShow[s.id] == nil {
                self.youtubeArtworkEpochByShow[s.id] = epoch
            }
            let outcome = await self.matchYouTubeArtwork(for: id, channel: channel,
                                                         epoch: epoch, force: true)
            if !Task.isCancelled, self.youtubeArtworkShowTasks[s.id] == nil {
                self.publishYouTubeLookupOutcome(outcome, showID: s.id)
            }
        }
    }

    private enum YouTubeLookupOutcome {
        case matched, noMatch, failed(String), skipped
    }

    @MainActor
    private func publishYouTubeLookupOutcome(_ outcome: YouTubeLookupOutcome, showID: UUID) {
        switch outcome {
        case .matched: youtubeMatchStatusesByShow[showID] = .verified
        case .noMatch:
            youtubeMatchStatusesByShow[showID] = matchedVideoCount(forShow: showID) > 0
                ? .verified : .noMatch
        case .failed(let reason):
            youtubeMatchStatusesByShow[showID] = .error(
                "YouTube verification failed: \(reason). Try Find Again.")
        case .skipped: break
        }
    }

    /// Verified episode thumbnails are persisted with the exact matching video
    /// ID. RSS/YouTube regional editions can use distinct audio clocks: do not
    /// populate youtubeMediaID here, which would misapply SponsorBlock cuts.
    @MainActor
    private func matchYouTubeArtwork(for id: UUID, channel: String,
                                     epoch: UUID, force: Bool) async -> YouTubeLookupOutcome {
        if youtubeArtworkInProgress[id] != nil && !force { return .skipped }
        let token = UUID()
        youtubeArtworkInProgress[id] = token
        defer {
            if youtubeArtworkInProgress[id] == token {
                youtubeArtworkInProgress.removeValue(forKey: id)
            }
        }
        guard let existing = episode(id), let currentShow = show(existing.showID),
              currentShow.youtubeChannelURL == channel,
              youtubeArtworkEpochByShow[existing.showID] == epoch,
              !Task.isCancelled else { return .skipped }
        if !force {
            if existing.youtubeMatchState == .notFound,
               existing.youtubeMatchChannelURL == channel,
               currentShow.youtubeCatalogRevision >= 1 { return .noMatch }
            if existing.youtubeMatchState == .matched, existing.youtubeID != nil,
               existing.youtubeMatchChannelURL == channel { return .matched }
            if artworkAlreadyVerified(for: existing) { return .matched }
            if (youtubeArtworkRetryAfter[id] ?? .distantPast) > Date() { return .skipped }
        }
        do {
            let match = try await YouTubeSource.match(episode: existing, channelURL: channel)
            guard !Task.isCancelled, youtubeArtworkEpochByShow[existing.showID] == epoch,
                  youtubeArtworkInProgress[id] == token,
                  show(existing.showID)?.youtubeChannelURL == channel,
                  let i = episodeIndex(id) else { return .skipped }
            guard let match else {
                // A verified absence is persisted per channel; later playback
                // won't hit YouTube again until explicitly retried.
                episodes[i].youtubeMatchState = .notFound
                episodes[i].youtubeMatchChannelURL = channel
                // Do NOT relabel or delete any existing downloaded recording.
                if episodes[i].youtubeMediaID == nil { episodes[i].youtubeID = nil }
                youtubeArtworkRetryAfter[id] = Date().addingTimeInterval(30 * 60)
                save()
                return .noMatch
            }
            // Persist the exact verified video even when its thumbnail is
            // missing or temporarily unreachable. No media source is changed.
            episodes[i].youtubeID = match.id
            episodes[i].youtubeMatchState = .matched
            episodes[i].youtubeMatchChannelURL = channel
            youtubeArtworkRetryAfter.removeValue(forKey: id)
            save()
            if let artwork = match.thumbnailURL {
                let cached = ArtworkStore.cachedFile(for: artwork) != nil
                let downloaded = cached ? true : await ArtworkStore.download(artwork)
                guard !Task.isCancelled, youtubeArtworkEpochByShow[existing.showID] == epoch,
                      youtubeArtworkInProgress[id] == token,
                      let refreshed = episodeIndex(id), episodes[refreshed].youtubeID == match.id,
                      show(existing.showID)?.youtubeChannelURL == channel else { return .matched }
                if downloaded {
                    episodes[refreshed].artworkURL = artwork
                    artworkVersion &+= 1
                    save()
                }
            }
            return .matched
        } catch is CancellationError { return .skipped }
        catch {
            guard !Task.isCancelled, youtubeArtworkEpochByShow[existing.showID] == epoch,
                  youtubeArtworkInProgress[id] == token else { return .skipped }
            youtubeArtworkRetryAfter[id] = Date().addingTimeInterval(10 * 60)
            // HTTP 429/transient failures are NOT confirmed negatives.
            return .failed(error.localizedDescription)
        }
    }

    private func artworkAlreadyVerified(for episode: Episode) -> Bool {
        guard let id = episode.youtubeID, let art = episode.artworkURL else { return false }
        return art.contains("/vi/\(id)/") || art.contains("/vi_webp/\(id)/")
    }

    /// Download a show's cover and its episodes' own covers (each picture once).
    @MainActor
    func fetchArtwork(for showID: UUID) {
        guard let s = show(showID) else { return }
        var urls: [String] = []
        if let a = s.artworkURL { urls.append(a) }
        urls += episodes(inShow: showID).compactMap(\.artworkURL)
        let unique = Array(NSOrderedSet(array: urls)) as? [String] ?? urls
        guard !unique.isEmpty else { return }
        Task { @MainActor in
            await withTaskGroup(of: Bool.self) { group in
                var iterator = unique.filter { ArtworkStore.cachedFile(for: $0) == nil }.makeIterator()
                for _ in 0..<min(4, unique.count) {
                    if let url = iterator.next() { group.addTask { await ArtworkStore.download(url) } }
                }
                while let saved = await group.next() {
                    if saved { self.artworkVersion += 1 }
                    if let url = iterator.next() { group.addTask { await ArtworkStore.download(url) } }
                }
            }
        }
    }

    // MARK: Messages / persistence

    @MainActor
    func flash(_ text: String) {
        withAnimation { toast = text }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(2500))
            guard !Task.isCancelled else { return }
            withAnimation { if self?.toast == text { self?.toast = nil } }
        }
    }

    func save() {
        guard persist else { return }
        let file = LibraryFile(feeds: feeds, shows: shows, episodes: episodes, settings: settings, metrics: metrics)
        do {
            try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(file)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            NSLog("PodCraft: could not save library: \(error)")
        }
    }

    func exportBackup(to url: URL) throws {
        let file = LibraryFile(feeds: feeds, shows: shows, episodes: episodes, settings: settings, metrics: metrics)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(file).write(to: url, options: .atomic)
    }

    func restoreBackup(from url: URL) throws {
        let file = try JSONDecoder().decode(LibraryFile.self, from: Data(contentsOf: url))
        invalidateYouTubeCatalogJobs()
        feeds = file.feeds; shows = file.shows; episodes = file.episodes
        settings = file.settings; metrics = file.metrics
        manageSelection = shows.first.map { .show($0.id) }
        save()
    }

    /// "Delete library data and media": start over with an empty library.
    func resetLibrary() {
        invalidateYouTubeCatalogJobs()
        for e in episodes {
            MainActor.assumeIsolated { processor?.cancel(e.id) }
            Self.deleteMedia(for: e.id)
        }
        feeds = []; shows = []; episodes = []; metrics = Metrics()
        manageSelection = nil
        listenSelection = .home
        save()
    }

    /// Late network callbacks may outlive a backup restore or library reset.
    /// Invalidate every epoch before the new library takes ownership of IDs.
    private func invalidateYouTubeCatalogJobs() {
        youtubeCatalogStartupTask?.cancel()
        youtubeCatalogStartupTask = nil
        youtubeCatalogStartupGeneration = nil
        for job in youtubeArtworkShowTasks.values { job.cancel() }
        for job in youtubeArtworkEpisodeTasks.values { job.cancel() }
        youtubeArtworkShowTasks.removeAll()
        youtubeArtworkShowGenerations.removeAll()
        youtubeArtworkEpisodeTasks.removeAll()
        youtubeArtworkEpisodeGenerations.removeAll()
        youtubeArtworkInProgress.removeAll()
        youtubeArtworkEpochByShow.removeAll()
        youtubeArtworkRetryAfter.removeAll()
        youtubeShowRetryAfter.removeAll()
        youtubeCatalogTaskTail = nil
        youtubeCatalogLastScanByShow.removeAll()
        youtubeMatchStatusesByShow.removeAll()
        youtubeCatalogProgressByShow.removeAll()
    }
}

// MARK: - Formatting helpers

enum Fmt {
    static func clock(_ s: Double) -> String {
        let t = Int(max(0, s.isFinite ? s : 0).rounded(.down))
        let h = t / 3600, m = (t % 3600) / 60, sec = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    static func length(_ s: Double) -> String {
        guard s > 0 else { return "—" }
        let m = Int((s / 60).rounded())
        if m >= 60 { return "\(m / 60) h \(m % 60) min" }
        return "\(max(m, 1)) min"
    }

    static func hours(_ s: Double) -> String {
        let h = s / 3600
        return h >= 1 ? String(format: "%.1f h", h) : "\(Int(s / 60)) min"
    }

    static func speed(_ r: Double) -> String {
        let rounded = (r * 100).rounded() / 100
        if rounded == rounded.rounded() { return String(format: "%.1f×", rounded) }
        return String(format: rounded * 10 == (rounded * 10).rounded() ? "%.1f×" : "%.2f×", rounded)
    }

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    static func date(_ d: Date) -> String {
        let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: d),
                                                   to: Calendar.current.startOfDay(for: Date())).day ?? 0
        if days == 0 { return "Today" }
        if days == 1 { return "Yesterday" }
        if days < 7 { return "\(days) days ago" }
        return dateFormatter.string(from: d)
    }
}
