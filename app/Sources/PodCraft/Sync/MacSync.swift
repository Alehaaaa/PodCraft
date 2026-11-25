import AppKit
import Foundation
import Observation

/// The Mac side of PodCraft Sync (format and merging in SyncCore.swift, shared with the iPhone app).
///
/// The Mac takes part like any other device: it publishes the shows it follows, where you are in every episode and
/// your default speed, and takes in what your other devices did. Positions go over the wire in the ORIGINAL
/// recording's time (what a phone streaming the feed plays), so they're converted through each episode's sponsor
/// cuts. Episodes playing from a YouTube upload are left out, since their timing differs from the feed's audio.
/// Shows unfollowed on another device stay on this Mac (with their downloads); new ones are added here.
@MainActor
@Observable
final class MacSync {
    static let shared = MacSync()

    struct Peer: Identifiable, Hashable {
        var id: String
        var name: String
        var platform: String
        var mode: String
        var savedAt: Date
        var isThisDevice: Bool
    }

    private(set) var code: String?
    private(set) var peers: [Peer] = []
    private(set) var syncing = false
    private(set) var lastSynced: Date?
    private(set) var error: String?

    var addNewShows: Bool { didSet { defaults.set(addNewShows, forKey: Key.addShows) } }
    var deviceName: String { didSet { defaults.set(deviceName, forKey: Key.name) } }
    let deviceID: String

    @ObservationIgnored private weak var library: Library?
    /// The episode in the player, which Sync never moves under the listener.
    @ObservationIgnored var nowPlaying: () -> UUID? = { nil }
    @ObservationIgnored private var state: SyncState
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 20
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    private enum Key {
        static let id = "sync.deviceID", code = "sync.code", name = "sync.deviceName"
        static let addShows = "sync.addShows", state = "sync.state", last = "sync.last"
    }

    /// What this Mac remembers between syncs: when each thing it published last changed.
    private struct SyncState: Codable {
        struct Stamp: Codable { var fingerprint: String; var at: Date }
        var subscriptions: [String: Subscription] = [:]
        var progress: [String: Stamp] = [:]
        var rate: Stamp?
    }

    private init() {
        if let id = defaults.string(forKey: Key.id) { deviceID = id } else {
            deviceID = UUID().uuidString
            defaults.set(deviceID, forKey: Key.id)
        }
        code = defaults.string(forKey: Key.code)
        addNewShows = defaults.object(forKey: Key.addShows) as? Bool ?? true
        deviceName = defaults.string(forKey: Key.name) ?? (Host.current().localizedName ?? "Mac")
        lastSynced = defaults.object(forKey: Key.last) as? Date
        state = defaults.data(forKey: Key.state).flatMap { try? SyncBox.decoder.decode(SyncState.self, from: $0) } ?? SyncState()
    }

    var isOn: Bool { code != nil }
    var displayCode: String { code.map(SyncBox.display) ?? "" }
    var joinLink: String? { code.map { "podcraft://sync?code=\($0)" } }

    /// Starts syncing in the background: every few minutes and whenever PodCraft comes to the front.
    func attach(_ library: Library) {
        self.library = library
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.syncNow()
                try? await Task.sleep(for: .seconds(180))
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncSoon(after: 1) }
        }
    }

    // MARK: Turning it on and off

    func start() { set(code: SyncBox.newCode()); syncSoon(after: 0) }

    @discardableResult
    func join(_ raw: String) -> Bool {
        guard let c = SyncBox.normalized(raw) else { return false }
        set(code: c)
        syncSoon(after: 0)
        return true
    }

    func leave() async {
        if let code { _ = try? await update(code) { $0.devices[self.deviceID] = nil } }
        set(code: nil)
        peers = []; lastSynced = nil; error = nil
        state = SyncState()
        saveState()
    }

    func remove(_ peer: Peer) async {
        guard let code else { return }
        do { show(try await update(code) { $0.devices[peer.id] = nil }) } catch { self.error = Self.describe(error) }
    }

    private func set(code new: String?) {
        code = new
        if let new { defaults.set(new, forKey: Key.code) } else { defaults.removeObject(forKey: Key.code) }
    }

    func syncSoon(after seconds: Double = 5) {
        guard isOn else { return }
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            await self?.syncNow()
        }
    }

    // MARK: Syncing

    func syncNow() async {
        guard let code, let library, !syncing else { return }
        syncing = true
        defer { syncing = false }
        do {
            var channel = try await read(code)
            let others = channel.devices.filter { $0.key != deviceID }.map(\.value)
            let now = Date()

            // Shows: what this Mac follows now, then what's new elsewhere.
            var subscriptions = localSubscriptions(library, now: now)
            let merged = SyncMerge.subscriptions(local: Array(subscriptions.values), incoming: others.flatMap(\.subscriptions))
            if addNewShows {
                for sub in merged where !sub.removed && subscriptions[sub.id]?.removed != false {
                    if await add(sub, to: library) { subscriptions[sub.id] = sub }
                }
            }
            state.subscriptions = subscriptions

            // Progress: newer positions from other devices, then this Mac's own.
            apply(SyncMerge.newest(others.flatMap(\.progress)), to: library)
            let progress = localProgress(library, now: now)

            // Default speed.
            let rateFP = String(format: "%.2f", library.settings.defaultSpeed)
            if state.rate?.fingerprint != rateFP { state.rate = .init(fingerprint: rateFP, at: state.rate == nil ? .distantPast : now) }
            if let s = others.compactMap(\.settings).max(by: { $0.updatedAt < $1.updatedAt }),
               s.updatedAt > (state.rate?.at ?? .distantPast), abs(s.rate - library.settings.defaultSpeed) > 0.001 {
                library.settings.defaultSpeed = s.rate
                state.rate = .init(fingerprint: String(format: "%.2f", s.rate), at: s.updatedAt)
                library.save()
            }

            channel.devices[deviceID] = SyncDeviceDoc(
                name: deviceName, platform: "mac", mode: "mac",
                version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
                savedAt: now,
                subscriptions: subscriptions.values.sorted { $0.title < $1.title },
                progress: progress,
                settings: SyncSettings(rate: library.settings.defaultSpeed, updatedAt: state.rate?.at ?? .distantPast))
            try await write(channel, code: code)
            saveState()
            show(channel)
            lastSynced = now
            defaults.set(now, forKey: Key.last)
            error = nil
        } catch {
            self.error = Self.describe(error)
        }
    }

    /// Shows with a feed, stamped with when they last changed. A show seen for the first time is as old as can
    /// be, so a removal made on another device before this Mac first synced still wins there.
    private func localSubscriptions(_ library: Library, now: Date) -> [String: Subscription] {
        var out: [String: Subscription] = [:]
        let firstSync = state.subscriptions.isEmpty
        for show in library.shows where !show.isFiles {
            guard let raw = show.feedURL, let url = URL(string: raw) else { continue }
            var sub = Subscription(url: url, title: show.title, author: show.author,
                                   artwork: show.artworkURL.flatMap(URL.init(string:)))
            if let known = state.subscriptions[sub.id], !known.removed {
                sub.updatedAt = known.updatedAt
            } else {
                sub.updatedAt = firstSync ? Date(timeIntervalSince1970: 0) : now
            }
            out[sub.id] = sub
        }
        // Shows removed on this Mac since the last sync.
        for (id, known) in state.subscriptions where out[id] == nil {
            var gone = known
            if !gone.removed { gone.removed = true; gone.updatedAt = now }
            if gone.updatedAt > now.addingTimeInterval(-90 * 86400) { out[id] = gone }
        }
        return out
    }

    private func add(_ sub: Subscription, to library: Library) async -> Bool {
        if library.shows.contains(where: { $0.feedURL.flatMap(URL.init(string:)).map(Subscription.id(for:)) == sub.id }) { return true }
        guard let parsed = try? await FeedFetcher.fetch(sub.url) else { return false }
        var show = Show(title: parsed.title, author: parsed.author, feedURL: sub.url.absoluteString,
                        artworkURL: parsed.artwork, hue: Double.random(in: 0...1), summary: parsed.summary,
                        keepAvailable: library.settings.defaultAvailable)
        show.language = parsed.language
        library.addShow(show, items: parsed.items)
        return true
    }

    /// The sync id of each episode that can be matched across devices.
    private func keyed(_ library: Library) -> [(index: Int, key: String)] {
        var showIDs: [UUID: String] = [:]
        for show in library.shows where !show.isFiles {
            if let raw = show.feedURL, let url = URL(string: raw) { showIDs[show.id] = Subscription.id(for: url) }
        }
        return library.episodes.indices.compactMap { i in
            let e = library.episodes[i]
            guard e.youtubeMediaID == nil, let showKey = showIDs[e.showID],
                  let key = SyncIDs.episode(showID: showKey, guid: e.guid, media: e.audioURL) else { return nil }
            return (i, key)
        }
    }

    private func apply(_ incoming: [String: SyncProgress], to library: Library) {
        guard !incoming.isEmpty else { return }
        let playing = nowPlaying()
        var changed = false
        for (i, key) in keyed(library) {
            guard let r = incoming[key], r.updatedAt > (state.progress[key]?.at ?? .distantPast) else { continue }
            let e = library.episodes[i]
            guard e.id != playing else { continue }
            let timeline = e.playbackTimeline
            let visible = r.played ? e.playbackDuration : min(timeline.visibleTime(forSource: r.position), e.playbackDuration)
            if abs(visible - e.position) >= 1 || e.played != r.played {
                library.episodes[i].position = visible
                library.episodes[i].played = r.played
                changed = true
            }
            state.progress[key] = .init(fingerprint: Self.fingerprint(position: r.position, played: r.played), at: r.updatedAt)
        }
        if changed { library.save() }
    }

    private func localProgress(_ library: Library, now: Date) -> [SyncProgress] {
        var out: [SyncProgress] = []
        for (i, key) in keyed(library) {
            let e = library.episodes[i]
            guard e.position > 1 || e.played else { continue }
            let source = e.played ? 0 : e.playbackTimeline.sourceTime(forVisible: e.position).rounded()
            let fp = Self.fingerprint(position: source, played: e.played)
            if state.progress[key]?.fingerprint != fp {
                // First sight: as old as the last time it was played, so a device that played it later wins.
                let at = state.progress[key] == nil ? (e.lastPlayedAt ?? Date(timeIntervalSince1970: 0)) : now
                state.progress[key] = .init(fingerprint: fp, at: at)
            }
            out.append(SyncProgress(id: key, position: source, played: e.played, updatedAt: state.progress[key]!.at))
        }
        return Array(out.sorted { $0.updatedAt > $1.updatedAt }.prefix(2000))
    }

    private static func fingerprint(position: Double, played: Bool) -> String {
        played ? "played" : String(Int((position / 5).rounded()) * 5)
    }

    private func saveState() {
        if let data = try? SyncBox.encoder.encode(state) { defaults.set(data, forKey: Key.state) }
    }

    private func show(_ channel: SyncChannel) {
        peers = channel.devices.map { id, doc in
            Peer(id: id, name: doc.name, platform: doc.platform, mode: doc.mode, savedAt: doc.savedAt, isThisDevice: id == deviceID)
        }
        .sorted { a, b in a.isThisDevice != b.isThisDevice ? a.isThisDevice : a.savedAt > b.savedAt }
    }

    // MARK: The store

    private func update(_ code: String, _ change: (inout SyncChannel) -> Void) async throws -> SyncChannel {
        var channel = try await read(code)
        change(&channel)
        try await write(channel, code: code)
        return channel
    }

    private func read(_ code: String) async throws -> SyncChannel {
        let (data, response) = try await session.data(for: URLRequest(url: SyncBox.url(for: code)))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return SyncChannel() }
        guard status == 200 else { throw SyncError.http(status) }
        do { return try SyncBox.open(String(decoding: data, as: UTF8.self), code: code) } catch { throw SyncError.unreadable }
    }

    private func write(_ channel: SyncChannel, code: String) async throws {
        var request = URLRequest(url: SyncBox.url(for: code))
        request.httpMethod = "POST"
        request.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(try SyncBox.seal(channel, code: code).utf8)
        let (_, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw SyncError.http(status) }
    }

    private enum SyncError: Error { case http(Int), unreadable }

    private static func describe(_ error: Error) -> String {
        switch error {
        case SyncError.http(let s): "The sync service answered with an error (\(s)). PodCraft tries again in a few minutes."
        case SyncError.unreadable: "This sync code’s data can’t be read. Check the code, or start a new sync group."
        default: "Can’t reach the sync service. PodCraft tries again when you’re online."
        }
    }
}
