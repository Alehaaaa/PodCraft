import CryptoKit
import Foundation

// PodCraft Sync, shared by the Mac and iPhone apps (the iPhone project compiles this same file).
// Devices that share a sync code share one document in a free public text store over HTTPS (textdb.dev); each
// device keeps its own entry there, and for every subscription and episode the newest change wins. The code
// picks the document and is the encryption key, so the store only ever sees ciphertext.

/// A show followed by its feed. Kept with the time it last changed (and a tombstone when removed) so Sync can
/// merge them between any number of devices.
struct Subscription: Codable, Hashable, Identifiable {
    var id: String
    var url: URL
    var title: String
    var author: String
    var artwork: URL?
    var updatedAt: Date
    var removed: Bool

    init(url: URL, title: String, author: String = "", artwork: URL? = nil, updatedAt: Date = Date(), removed: Bool = false) {
        self.id = Self.id(for: url)
        self.url = url
        self.title = title
        self.author = author
        self.artwork = artwork
        self.updatedAt = updatedAt
        self.removed = removed
    }

    /// The same feed gets the same id on every device: http/https, case and a trailing slash don't matter.
    static func id(for url: URL) -> String {
        var s = url.absoluteString.lowercased()
        for scheme in ["https://", "http://", "feed://"] where s.hasPrefix(scheme) { s.removeFirst(scheme.count) }
        while s.hasSuffix("/") { s.removeLast() }
        return "rss-" + Hash.short(s)
    }
}

enum Hash {
    static func short(_ text: String, length: Int = 16) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(length))
    }
}

/// Episode ids every device agrees on: the feed's id plus a hash of the episode's guid (or its media address).
enum SyncIDs {
    static func episode(showID: String, guid: String?, media: String?) -> String? {
        let g = guid?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let key = g.isEmpty ? (media?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") : g
        guard !key.isEmpty else { return nil }
        return showID + "-" + Hash.short(key)
    }
}

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
