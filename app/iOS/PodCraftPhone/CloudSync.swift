import CryptoKit
import Foundation
import Observation
import UIKit

// PodCraft Sync: keeps subscriptions, listening progress and settings in step between any number of devices,
// in companion or standalone mode, without Tailscale, an account or a server of our own. Devices that share a
// sync code share one document in a free public text store over HTTPS (textdb.dev); each device keeps its own
// entry there, and for every subscription and episode the newest change wins. The code picks the document and
// is the encryption key, so the store only ever sees ciphertext.

// MARK: - Wire format

struct SyncProgress: Codable, Equatable {
    var id: String
    var position: Double
    var played: Bool
    var updatedAt: Date
}

struct SyncSettings: Codable, Equatable {
    var rate: Double
    var updatedAt: Date
}

struct SyncDeviceDoc: Codable, Equatable {
    var name: String
    var platform: String
    var mode: String
    var version: String
    var savedAt: Date
    var subscriptions: [Subscription]
    var progress: [SyncProgress]
    var settings: SyncSettings?
}

struct SyncChannel: Codable {
    var devices: [String: SyncDeviceDoc] = [:]
}

enum SyncBox {
    static let prefix = "podcraft1:"
    static let store = URL(string: "https://textdb.dev/api/data/")!

    static func slot(for code: String) -> String {
        let digest = SHA256.hash(data: Data("podcraft-sync-slot|\(code)".utf8))
        return "podcraft-" + digest.map { String(format: "%02x", $0) }.joined()
    }

    static func url(for code: String) -> URL { store.appendingPathComponent(slot(for: code)) }

    static func key(for code: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(code.utf8)),
                               salt: Data("podcraft-sync".utf8),
                               info: Data("podcraft-sync-key-v1".utf8),
                               outputByteCount: 32)
    }

    static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .millisecondsSince1970
        e.outputFormatting = [.sortedKeys]
        return e
    }

    static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .millisecondsSince1970
        return d
    }

    static func seal(_ channel: SyncChannel, code: String) throws -> String {
        let json = try encoder.encode(channel)
        let packed = try (json as NSData).compressed(using: .zlib) as Data
        guard let box = try AES.GCM.seal(packed, using: key(for: code)).combined else { throw CocoaError(.coderInvalidValue) }
        return prefix + box.base64EncodedString()
    }

    /// An empty slot is an empty channel.
    static func open(_ text: String, code: String) throws -> SyncChannel {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return SyncChannel() }
        guard text.hasPrefix(prefix), let raw = Data(base64Encoded: String(text.dropFirst(prefix.count))) else {
            throw CocoaError(.coderReadCorrupt)
        }
        let packed = try AES.GCM.open(AES.GCM.SealedBox(combined: raw), using: key(for: code))
        let json = try (packed as NSData).decompressed(using: .zlib) as Data
        return try decoder.decode(SyncChannel.self, from: json)
    }

    /// Sync codes: 16 letters and digits, shown in groups of four.
    static let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")

    static func newCode() -> String {
        var g = SystemRandomNumberGenerator()
        return String((0..<16).map { _ in alphabet.randomElement(using: &g)! })
    }

    /// Accepts a typed or pasted code in any case, with or without dashes and spaces.
    static func normalized(_ raw: String) -> String? {
        let code = String(raw.uppercased().filter { $0.isLetter || $0.isNumber })
        guard (12...64).contains(code.count), code.allSatisfy(\.isASCII) else { return nil }
        return code
    }

    static func display(_ code: String) -> String {
        stride(from: 0, to: code.count, by: 4).map { i in
            let start = code.index(code.startIndex, offsetBy: i)
            let end = code.index(start, offsetBy: 4, limitedBy: code.endIndex) ?? code.endIndex
            return String(code[start..<end])
        }.joined(separator: "-")
    }
}

// MARK: - Merging (pure)

enum SyncMerge {
    /// Newest change wins for each subscription, removals included.
    static func subscriptions(local: [Subscription], incoming: [Subscription]) -> [Subscription] {
        var byID = Dictionary(local.map { ($0.id, $0) }, uniquingKeysWith: { $0.updatedAt >= $1.updatedAt ? $0 : $1 })
        for s in incoming where s.updatedAt > (byID[s.id]?.updatedAt ?? .distantPast) { byID[s.id] = s }
        // Tombstones are kept for 90 days, long enough for every device to hear about the removal.
        let cutoff = Date().addingTimeInterval(-90 * 86400)
        return byID.values.filter { !$0.removed || $0.updatedAt > cutoff }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// The newest record for each episode among the peers.
    static func newest(_ records: [SyncProgress]) -> [String: SyncProgress] {
        var out: [String: SyncProgress] = [:]
        for r in records where r.updatedAt > (out[r.id]?.updatedAt ?? .distantPast) { out[r.id] = r }
        return out
    }
}

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
