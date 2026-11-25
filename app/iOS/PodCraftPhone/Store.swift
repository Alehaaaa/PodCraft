import Foundation
import Observation

/// PodCraft on the phone works two ways:
/// - Companion: the library PodCraft on the Mac serves (cleaned episodes, chapters, transcripts). The last library
///   is kept on the phone so the shows are there at once, and listening positions are sent back to the Mac.
/// - Standalone: shows this phone follows itself, read straight from their feeds, with no Mac at all.
/// Either way, Sync (a sync code) keeps subscriptions, progress and settings in step across devices.
@MainActor
@Observable
final class Store {
    enum Mode: String { case companion, standalone }

    private(set) var mode: Mode?
    private(set) var server: String
    private(set) var code: String
    private(set) var macName: String
    private(set) var library: RemoteLibrary?
    private(set) var loading = false
    private(set) var message: String?
    /// Positions saved on the phone, by episode id, and when each last changed (for Sync).
    private(set) var positions: [String: Double]
    private(set) var played: Set<String>
    @ObservationIgnored private var progressStamps: [String: Double]
    /// Shows followed in standalone mode (removed ones are kept a while as tombstones for Sync).
    private(set) var subscriptions: [Subscription]
    /// Transcripts, chapters and sponsor spans from the Mac (through Sync) for episodes streamed from their feed.
    private(set) var extras: [String: SyncExtras] = [:]
    /// Skip the sponsor reads the Mac found, in episodes streamed from their feed.
    var skipSponsors: Bool { didSet { defaults.set(skipSponsors, forKey: "skipSponsors") } }
    /// Playback speed, shared with other devices through Sync.
    private(set) var rate: Float
    @ObservationIgnored private var rateUpdatedAt: Date

    let sync: CloudSync

    private let defaults = UserDefaults.standard
    private static let supportDir: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    private let companionCacheURL = Store.supportDir.appendingPathComponent("Library.json")
    private let standaloneCacheURL = Store.supportDir.appendingPathComponent("Standalone.json")
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 15
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    init() {
        sync = CloudSync()
        server = defaults.string(forKey: "server") ?? ""
        code = defaults.string(forKey: "code") ?? ""
        macName = defaults.string(forKey: "macName") ?? "Mac"
        positions = (defaults.dictionary(forKey: "positions") as? [String: Double]) ?? [:]
        played = Set(defaults.stringArray(forKey: "played") ?? [])
        progressStamps = (defaults.dictionary(forKey: "progressStamps") as? [String: Double]) ?? [:]
        subscriptions = defaults.data(forKey: "subscriptions").flatMap { try? Self.decoder.decode([Subscription].self, from: $0) } ?? []
        rate = defaults.object(forKey: "rate") as? Float ?? 1
        skipSponsors = defaults.object(forKey: "skipSponsors") as? Bool ?? true
        rateUpdatedAt = defaults.object(forKey: "rateUpdatedAt") as? Date ?? .distantPast
        if let m = defaults.string(forKey: "mode").flatMap(Mode.init(rawValue:)) {
            mode = m
        } else if !server.isEmpty && !code.isEmpty {
            mode = .companion   // phones set up before standalone mode existed
        }
        loadCache()
        sync.store = self
        // Screenshots and checks: PODCRAFT_SERVER / PODCRAFT_CODE connect without scanning.
        let env = ProcessInfo.processInfo.environment
        if let s = env["PODCRAFT_SERVER"], let c = env["PODCRAFT_CODE"] { connect(server: s, code: c, name: env["PODCRAFT_MAC"]) }
    }

    /// Connected to a Mac (companion mode).
    var isConnected: Bool { !server.isEmpty && !code.isEmpty }
    var isStandalone: Bool { mode == .standalone }
    /// Set up either way, so the library shows instead of the welcome screen.
    var isReady: Bool { mode == .standalone || (mode == .companion && isConnected) }
    /// Where the library comes from, for messages.
    var sourceName: String { isStandalone ? "PodCraft" : macName }

    private func setMode(_ m: Mode?) {
        mode = m
        if let m { defaults.set(m.rawValue, forKey: "mode") } else { defaults.removeObject(forKey: "mode") }
        message = nil
        loadCache()
    }

    private func loadCache() {
        let url = isStandalone ? standaloneCacheURL : companionCacheURL
        library = (try? Data(contentsOf: url)).flatMap { try? Self.decoder.decode(RemoteLibrary.self, from: $0) }
    }

    private func saveCache(_ lib: RemoteLibrary) {
        try? Self.encoder.encode(lib).write(to: isStandalone ? standaloneCacheURL : companionCacheURL, options: .atomic)
    }

    // MARK: Opening links

    /// podcraft://connect?server=…&code=…&name=…  (the QR code on the Mac)
    /// podcraft://sync?code=…                      (another device's sync code)
    /// podcraft://subscribe?url=…                  (a feed to follow)
    @discardableResult
    func open(_ url: URL) -> Bool {
        guard url.scheme == "podcraft" else { return false }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first(where: { $0.name == name })?.value }
        switch url.host {
        case "connect":
            guard let s = value("server"), let c = value("code") else { return false }
            connect(server: s, code: c, name: value("name"))
            return true
        case "sync":
            guard let c = value("code") else { return false }
            if mode == nil { startStandalone() }
            return sync.join(c)
        case "subscribe":
            guard let raw = value("url"), let feed = FeedReader.normalize(raw) else { return false }
            if mode == nil { startStandalone() }
            Task { try? await subscribe(to: feed) }
            return true
        default:
            return false
        }
    }

    // MARK: Companion

    func connect(server s: String, code c: String, name: String? = nil) {
        var address = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if !address.isEmpty, !address.contains("://") { address = "http://" + address }
        while address.hasSuffix("/") { address.removeLast() }
        server = address
        code = c.trimmingCharacters(in: .whitespacesAndNewlines)
        if let name, !name.isEmpty { macName = name }
        defaults.set(server, forKey: "server")
        defaults.set(code, forKey: "code")
        defaults.set(macName, forKey: "macName")
        setMode(.companion)
        Task { await refresh() }
    }

    /// Forgets the Mac. Sync, subscriptions and progress stay.
    func disconnect() {
        server = ""; code = ""; message = nil
        defaults.removeObject(forKey: "server")
        defaults.removeObject(forKey: "code")
        try? FileManager.default.removeItem(at: companionCacheURL)
        if mode == .companion { setMode(nil) }
    }

    private func api(_ path: String) -> URL? { URL(string: "\(server)/api/\(code)/\(path)") }

    // MARK: Standalone

    func startStandalone() {
        setMode(.standalone)
        Task { await refresh() }
    }

    /// Back to the Mac's library (when one is connected) or to the welcome screen.
    func switchToCompanion() {
        setMode(isConnected ? .companion : nil)
        if isConnected { Task { await refresh() } }
    }

    var activeSubscriptions: [Subscription] { subscriptions.filter { !$0.removed } }

    func isSubscribed(_ url: URL) -> Bool { activeSubscriptions.contains { $0.id == Subscription.id(for: url) } }
    func isSubscribed(showID: String) -> Bool { activeSubscriptions.contains { $0.id == showID } }

    /// Reads the feed first, so only real podcasts are added, then adds it to the library at once.
    func subscribe(to url: URL) async throws {
        let id = Subscription.id(for: url)
        let show = try await FeedReader.fetch(url, id: id)
        let sub = Subscription(url: url, title: show.title, author: show.author, artwork: show.artwork)
        subscriptions.removeAll { $0.id == id }
        subscriptions.append(sub)
        saveSubscriptions()
        if isStandalone {
            var lib = library ?? RemoteLibrary(name: "PodCraft", shows: [], feeds: nil)
            lib.shows.removeAll { $0.id == id }
            lib.shows.append(show)
            lib.shows = Self.ordered(lib.shows)
            library = lib
            saveCache(lib)
        }
        sync.syncSoon(after: 1)
    }

    func unsubscribe(showID: String) {
        guard let i = subscriptions.firstIndex(where: { $0.id == showID }) else { return }
        subscriptions[i].removed = true
        subscriptions[i].updatedAt = Date()
        saveSubscriptions()
        if isStandalone, var lib = library {
            lib.shows.removeAll { $0.id == showID }
            library = lib
            saveCache(lib)
        }
        sync.syncSoon(after: 1)
    }

    private func saveSubscriptions() {
        if let data = try? Self.encoder.encode(subscriptions) { defaults.set(data, forKey: "subscriptions") }
    }

    private static func ordered(_ shows: [RemoteShow]) -> [RemoteShow] {
        shows.sorted { ($0.episodes.first?.published ?? .distantPast) > ($1.episodes.first?.published ?? .distantPast) }
    }

    private func refreshFeeds() async {
        let subs = activeSubscriptions
        let previous = Dictionary((library?.shows ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var failures = 0
        var shows: [RemoteShow] = []
        await withTaskGroup(of: (Subscription, RemoteShow?).self) { group in
            for sub in subs {
                group.addTask { (sub, try? await FeedReader.fetch(sub.url, id: sub.id)) }
            }
            for await (sub, show) in group {
                if let show { shows.append(show) }
                else {
                    failures += 1
                    if let old = previous[sub.id] { shows.append(old) }
                }
            }
        }
        // A show unfollowed while the feeds were loading stays gone.
        let live = Set(activeSubscriptions.map(\.id))
        let lib = RemoteLibrary(name: "PodCraft", shows: Self.ordered(shows.filter { live.contains($0.id) }), feeds: nil)
        library = lib
        saveCache(lib)
        message = failures == 0 ? nil
            : failures == subs.count ? "Can’t reach your shows’ feeds. Check your connection."
            : "\(failures) show\(failures == 1 ? "" : "s") couldn’t be updated."
    }

    func refreshIfStandalone() async {
        if isStandalone { await refresh() }
    }

    // MARK: Library

    func refresh() async {
        guard !loading else { return }
        if isStandalone {
            loading = true
            defer { loading = false }
            await refreshFeeds()
            await sync.syncNow()
            return
        }
        guard isConnected, let url = api("library.json") else { return }
        loading = true
        defer { loading = false }
        do {
            let (data, response) = try await session.data(from: url)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 403 { message = "This code is no longer valid. Scan the new one in PodCraft’s Settings on your Mac."; return }
            guard status == 200 else { message = "\(macName) answered with an error (\(status))."; return }
            let lib = try Self.decoder.decode(RemoteLibrary.self, from: data)
            library = lib
            macName = lib.name
            defaults.set(macName, forKey: "macName")
            message = nil
            saveCache(lib)
        } catch is DecodingError {
            message = "PodCraft on \(macName) sent something this app doesn’t understand. Update both apps."
        } catch {
            message = "Can’t reach \(macName). Make sure it’s awake with PodCraft open, and on the same network or Tailscale."
        }
        await sync.syncNow()
    }

    // MARK: Extras (captions, chapters, sponsor spans)

    private static let extrasDir: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Extras")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Loads an episode's extras: from memory, from the cache on the phone, or from Sync when the Mac has newer.
    func loadExtras(for e: RemoteEpisode) async {
        guard !e.isOnMac else { return }
        let published = sync.availableExtras[e.id]
        if let have = extras[e.id], published == nil || have.updatedAt >= published! { return }
        let file = Self.extrasDir.appendingPathComponent(Hash.short(e.id, length: 32) + ".json")
        if let data = try? Data(contentsOf: file), let cached = try? SyncBox.decoder.decode(SyncExtras.self, from: data),
           published == nil || cached.updatedAt >= published! {
            extras[e.id] = cached
            return
        }
        guard let fresh = await sync.fetchExtras(e.id) else { return }
        extras[e.id] = fresh
        try? SyncBox.encoder.encode(fresh).write(to: file, options: .atomic)
    }

    func chapters(for e: RemoteEpisode) -> [RemoteChapter] {
        if !e.chapters.isEmpty { return e.chapters }
        return extras[e.id]?.chapters.map { RemoteChapter(start: $0.start, title: $0.title) } ?? []
    }

    func hasTranscript(_ e: RemoteEpisode) -> Bool { e.hasTranscript || !(extras[e.id]?.transcript.isEmpty ?? true) }

    /// Sponsor spans to skip while playing, when that's on.
    func skips(for e: RemoteEpisode) -> [SyncExtras.Span] {
        skipSponsors ? (extras[e.id]?.skips ?? []) : []
    }

    func transcript(for e: RemoteEpisode) async -> [TranscriptLine]? {
        if let lines = extras[e.id]?.transcript, !lines.isEmpty {
            return lines.map { TranscriptLine(start: $0.start, end: $0.end, text: $0.text) }
        }
        return e.hasTranscript ? await detail(for: e)?.transcript : nil
    }

    /// More episodes of the same show after this one: newer first if any are unplayed, then older.
    func upNext(after e: RemoteEpisode, limit: Int = 5) -> [RemoteEpisode] {
        guard let episodes = show(e.showID)?.episodes, let i = episodes.firstIndex(where: { $0.id == e.id }) else { return [] }
        let newer = episodes[..<i].reversed().filter { !isPlayed($0) }
        let older = episodes[(i + 1)...].filter { !isPlayed($0) }
        return Array((newer + older).prefix(limit))
    }

    func detail(for episode: RemoteEpisode) async -> EpisodeDetail? {
        guard !isStandalone, let url = api("episodes/\(episode.id).json"),
              let (data, _) = try? await session.data(from: url) else { return nil }
        return try? Self.decoder.decode(EpisodeDetail.self, from: data)
    }

    // MARK: Lists

    var shows: [RemoteShow] { library?.shows ?? [] }

    func show(_ id: String) -> RemoteShow? { shows.first { $0.id == id } }

    var feeds: [RemoteFeed] { library?.feeds ?? [] }

    func feed(_ id: String) -> RemoteFeed? { feeds.first { $0.id == id } }

    func shows(in feed: RemoteFeed) -> [RemoteShow] { feed.showIDs.compactMap { show($0) } }

    func episodes(in feed: RemoteFeed) -> [RemoteEpisode] {
        shows(in: feed).flatMap(\.episodes).sorted { $0.published > $1.published }
    }

    /// Cleaned on the Mac: sponsors removed, with chapters.
    var readyOnMac: [RemoteEpisode] { isStandalone ? [] : latest.filter(\.isOnMac) }

    var allEpisodes: [RemoteEpisode] { shows.flatMap(\.episodes) }

    var latest: [RemoteEpisode] { allEpisodes.sorted { $0.published > $1.published } }

    /// Started and not finished, most recently listened to first.
    var continueListening: [RemoteEpisode] {
        latest.filter { position(of: $0) > 15 && !isPlayed($0) }
            .sorted { (progressStamps[$0.id] ?? 0) > (progressStamps[$1.id] ?? 0) }
    }

    // MARK: Progress

    func position(of e: RemoteEpisode) -> Double { positions[e.id] ?? e.position }
    func isPlayed(_ e: RemoteEpisode) -> Bool { played.contains(e.id) || (e.played && positions[e.id] == nil) }

    func remaining(_ e: RemoteEpisode) -> Double { max(0, e.duration - position(of: e)) }

    func save(position: Double, for e: RemoteEpisode, played isDone: Bool = false) {
        let changed = abs((positions[e.id] ?? -1) - position) >= 1 || played.contains(e.id) != isDone
        positions[e.id] = position
        if isDone { played.insert(e.id) } else { played.remove(e.id) }
        if changed { progressStamps[e.id] = Date().timeIntervalSince1970 }
        persistProgress()
    }

    func setPlayed(_ e: RemoteEpisode, _ done: Bool) {
        save(position: done ? 0 : position(of: e), for: e, played: done)
        report(e)
    }

    private func persistProgress() {
        defaults.set(positions, forKey: "positions")
        defaults.set(Array(played), forKey: "played")
        defaults.set(progressStamps, forKey: "progressStamps")
    }

    /// Tells the Mac where the phone got to (best effort; the phone keeps its own copy), and other devices through Sync.
    func report(_ e: RemoteEpisode) {
        sync.syncSoon()
        guard !isStandalone, isConnected,
              let url = api("progress/\(e.id)?t=\(String(format: "%.1f", position(of: e)))&played=\(isPlayed(e) ? 1 : 0)") else { return }
        Task { _ = try? await session.data(from: url) }
    }

    // MARK: Settings

    func setRate(_ r: Float) {
        rate = r
        rateUpdatedAt = Date()
        defaults.set(r, forKey: "rate")
        defaults.set(rateUpdatedAt, forKey: "rateUpdatedAt")
        sync.syncSoon()
    }

    // MARK: Sync

    func syncDocument(name: String, subscriptions includeSubs: Bool, progress includeProgress: Bool,
                      settings includeSettings: Bool) -> SyncDeviceDoc {
        // The 2,000 most recently changed episodes are plenty and keep the document small.
        let progress: [SyncProgress] = includeProgress
            ? positions.keys.map { id in
                SyncProgress(id: id, position: (positions[id] ?? 0).rounded(),
                             played: played.contains(id),
                             updatedAt: Date(timeIntervalSince1970: ((progressStamps[id] ?? 0) * 1000).rounded() / 1000))
            }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(2000).map { $0 }
            : []
        return SyncDeviceDoc(name: name, platform: "iphone", mode: mode?.rawValue ?? "none",
                             version: "\(Updater.currentVersion) (\(Updater.currentBuild))",
                             savedAt: Date(),
                             subscriptions: includeSubs ? subscriptions : [],
                             progress: progress,
                             settings: includeSettings ? SyncSettings(rate: Double(rate), updatedAt: rateUpdatedAt) : nil)
    }

    /// Returns true when the shows followed changed.
    func merge(subscriptions incoming: [Subscription]) -> Bool {
        let merged = SyncMerge.subscriptions(local: subscriptions, incoming: incoming)
        let before = Set(activeSubscriptions.map(\.id))
        subscriptions = merged
        saveSubscriptions()
        return Set(activeSubscriptions.map(\.id)) != before
    }

    func merge(progress incoming: [String: SyncProgress]) {
        var changed = false
        for (id, r) in incoming where r.updatedAt.timeIntervalSince1970 > (progressStamps[id] ?? 0) + 0.001 {
            positions[id] = r.position
            if r.played { played.insert(id) } else { played.remove(id) }
            progressStamps[id] = r.updatedAt.timeIntervalSince1970
            changed = true
        }
        if changed { persistProgress() }
    }

    func merge(settings s: SyncSettings) {
        guard s.updatedAt > rateUpdatedAt else { return }
        rate = Float(s.rate)
        rateUpdatedAt = s.updatedAt
        defaults.set(rate, forKey: "rate")
        defaults.set(rateUpdatedAt, forKey: "rateUpdatedAt")
    }
}
