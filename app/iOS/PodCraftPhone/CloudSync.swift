import Foundation
import Observation
import UIKit

// The iPhone side of PodCraft Sync (the format and merging live in Sources/PodCraft/Sync/SyncCore.swift,
// shared with the Mac). Keeps subscriptions, progress and settings in step between any number of devices.

// MARK: - The service

@MainActor
@Observable
final class CloudSync {
    struct Peer: Identifiable, Hashable {
        var id: String
        var name: String
        var platform: String
        var mode: String
        var version: String
        var savedAt: Date
        var isThisDevice: Bool
    }

    private(set) var code: String?
    private(set) var peers: [Peer] = []
    private(set) var syncing = false
    private(set) var lastSynced: Date?
    private(set) var error: String?
    /// Episodes another device (the Mac) published extras for, and when.
    @ObservationIgnored private(set) var availableExtras: [String: Date] = [:]

    var syncSubscriptions: Bool { didSet { defaults.set(syncSubscriptions, forKey: "sync.subscriptions"); syncSoon() } }
    var syncProgress: Bool { didSet { defaults.set(syncProgress, forKey: "sync.progress"); syncSoon() } }
    var syncSettings: Bool { didSet { defaults.set(syncSettings, forKey: "sync.settings"); syncSoon() } }
    var deviceName: String { didSet { defaults.set(deviceName, forKey: "sync.deviceName"); syncSoon() } }

    let deviceID: String
    @ObservationIgnored weak var store: Store?
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 20
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    init() {
        if let id = defaults.string(forKey: "sync.deviceID") { deviceID = id } else {
            deviceID = UUID().uuidString
            defaults.set(deviceID, forKey: "sync.deviceID")
        }
        code = defaults.string(forKey: "sync.code")
        syncSubscriptions = defaults.object(forKey: "sync.subscriptions") as? Bool ?? true
        syncProgress = defaults.object(forKey: "sync.progress") as? Bool ?? true
        syncSettings = defaults.object(forKey: "sync.settings") as? Bool ?? true
        deviceName = defaults.string(forKey: "sync.deviceName") ?? UIDevice.current.name
        if let t = defaults.object(forKey: "sync.last") as? Date { lastSynced = t }
    }

    var isOn: Bool { code != nil }
    var displayCode: String { code.map(SyncBox.display) ?? "" }
    var joinLink: URL? { code.flatMap { URL(string: "podcraft://sync?code=\($0)") } }

    // MARK: Turning it on and off

    /// Starts a new sync group with this device in it.
    func start() {
        set(code: SyncBox.newCode())
        Task { await syncNow() }
    }

    /// Joins the group another device shows. Returns false for a code that can't be right.
    @discardableResult
    func join(_ raw: String) -> Bool {
        guard let c = SyncBox.normalized(raw) else { return false }
        set(code: c)
        Task { await syncNow() }
        return true
    }

    /// Takes this device out of the group (its entry is removed) and forgets the code.
    func leave() async {
        if let code { _ = try? await update(code) { $0.devices[self.deviceID] = nil } }
        set(code: nil)
        peers = []
        lastSynced = nil
        error = nil
    }

    /// Forgets another device; it adds itself back the next time it syncs, unless it has left too.
    func remove(_ peer: Peer) async {
        guard let code else { return }
        do {
            let channel = try await update(code) { $0.devices[peer.id] = nil }
            show(channel)
        } catch { self.error = Self.describe(error) }
    }

    private func set(code new: String?) {
        code = new
        if let new { defaults.set(new, forKey: "sync.code") } else { defaults.removeObject(forKey: "sync.code") }
    }

    // MARK: Syncing

    /// A sync a few seconds from now, so a run of changes goes out together.
    func syncSoon(after seconds: Double = 4) {
        guard isOn else { return }
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            await self?.syncNow()
        }
    }

    func syncNow() async {
        guard let code, let store, !syncing else { return }
        syncing = true
        defer { syncing = false }
        do {
            var channel = try await read(code)
            let others = channel.devices.filter { $0.key != deviceID }.map(\.value)
            availableExtras = others.reduce(into: [:]) { all, doc in
                for (id, at) in doc.extras ?? [:] where at > (all[id] ?? .distantPast) { all[id] = at }
            }
            var subscriptionsChanged = false
            if syncSubscriptions { subscriptionsChanged = store.merge(subscriptions: others.flatMap(\.subscriptions)) }
            if syncProgress { store.merge(progress: SyncMerge.newest(others.flatMap(\.progress))) }
            if syncSettings, let s = others.compactMap(\.settings).max(by: { $0.updatedAt < $1.updatedAt }) { store.merge(settings: s) }
            channel.devices[deviceID] = store.syncDocument(name: deviceName,
                                                           subscriptions: syncSubscriptions,
                                                           progress: syncProgress,
                                                           settings: syncSettings)
            try await write(channel, code: code)
            show(channel)
            lastSynced = Date()
            defaults.set(lastSynced, forKey: "sync.last")
            error = nil
            if subscriptionsChanged { await store.refreshIfStandalone() }
        } catch is CancellationError {
        } catch {
            self.error = Self.describe(error)
        }
    }

    /// The transcript, chapters and sponsor spans the Mac published for an episode, if any.
    func fetchExtras(_ episodeID: String) async -> SyncExtras? {
        guard let code, availableExtras[episodeID] != nil else { return nil }
        guard let (data, response) = try? await session.data(for: URLRequest(url: SyncBox.extrasURL(for: code, episode: episodeID))),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? SyncBox.open(SyncExtras.self, String(decoding: data, as: UTF8.self), code: code)
    }

    private func show(_ channel: SyncChannel) {
        peers = channel.devices.map { id, doc in
            Peer(id: id, name: doc.name, platform: doc.platform, mode: doc.mode, version: doc.version,
                 savedAt: doc.savedAt, isThisDevice: id == deviceID)
        }
        .sorted { a, b in a.isThisDevice != b.isThisDevice ? a.isThisDevice : a.savedAt > b.savedAt }
    }

    private func update(_ code: String, _ change: (inout SyncChannel) -> Void) async throws -> SyncChannel {
        var channel = try await read(code)
        change(&channel)
        try await write(channel, code: code)
        return channel
    }

    private func read(_ code: String) async throws -> SyncChannel {
        // No Accept header: textdb.dev answers 406 to "text/plain".
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

    enum SyncError: Error { case http(Int), unreadable }

    private static func describe(_ error: Error) -> String {
        switch error {
        case SyncError.http(let s): "The sync service answered with an error (\(s)). PodCraft tries again later."
        case SyncError.unreadable: "This sync code’s data can’t be read. Check the code, or start a new sync group."
        default: "Can’t reach the sync service. PodCraft tries again when you’re online."
        }
    }
}
