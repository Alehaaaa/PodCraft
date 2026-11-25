import Foundation
import Network
import SwiftUI
import AppKit
import SystemConfiguration
import UniformTypeIdentifiers

/// Owns one HTTP media response and its file descriptor. File I/O stays off the main actor;
/// the next chunk is read only after the previous one has been written to the socket.
private actor MediaFileStream {
    private let connection: SocketConnection
    private let url: URL
    private let range: String?
    private let head: Bool
    private var handle: FileHandle?
    private var remaining: Int64 = 0
    private var finished = false

    init(connection: SocketConnection, path: String, range: String?, head: Bool) {
        self.connection = connection
        self.url = URL(fileURLWithPath: path)
        self.range = range
        self.head = head
    }

    private static func byteRange(_ header: String?, size: Int64) -> (start: Int64, end: Int64, partial: Bool)? {
        guard let header else { return (0, size - 1, false) }
        guard header.lowercased().hasPrefix("bytes="), !header.contains(","), size > 0 else { return nil }
        let parts = header.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        if parts[0].isEmpty {
            guard let suffix = Int64(parts[1]), suffix > 0 else { return nil }
            return (max(0, size - suffix), size - 1, true)
        }
        guard let start = Int64(parts[0]), start >= 0, start < size else { return nil }
        let end = parts[1].isEmpty ? size - 1 : (Int64(parts[1]) ?? -1)
        guard end >= start else { return nil }
        return (start, min(end, size - 1), true)
    }

    func start() {
        guard !finished else { return }
        do {
            let file = try FileHandle(forReadingFrom: url)
            handle = file
            let byteSize = try file.seekToEnd()
            guard byteSize <= UInt64(Int64.max) else {
                respondError("500 Internal Server Error"); return
            }
            let size = Int64(byteSize)
            guard let selection = Self.byteRange(range, size: size) else {
                respondError("416 Range Not Satisfiable", extra: "Content-Range: bytes */\(size)\r\n")
                return
            }
            remaining = selection.end - selection.start + 1
            if remaining > 0 { try file.seek(toOffset: UInt64(selection.start)) }
            let type = url.pathExtension.lowercased() == "ipa" ? "application/octet-stream"
                : (UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "audio/mpeg")
            var header = "HTTP/1.1 \(selection.partial ? "206 Partial Content" : "200 OK")\r\n"
            header += "Content-Type: \(type)\r\nContent-Length: \(remaining)\r\nAccept-Ranges: bytes\r\nConnection: close\r\n"
            if selection.partial { header += "Content-Range: bytes \(selection.start)-\(selection.end)/\(size)\r\n" }
            header += "\r\n"
            connection.send(Data(header.utf8)) { [self] ok in
                Task { await didSend(ok: ok) }
            }
        } catch {
            respondError("404 Not Found")
        }
    }

    private func respondError(_ status: String, extra: String = "") {
        guard !finished else { return }
        finished = true
        closeFile()
        let header = "HTTP/1.1 \(status)\r\nContent-Length: 0\r\nAccept-Ranges: bytes\r\n\(extra)Connection: close\r\n\r\n"
        connection.send(Data(header.utf8)) { [connection] _ in connection.cancel() }
    }

    private func didSend(ok: Bool) {
        guard !finished else { return }
        if !ok { abort(); return }
        if head || remaining == 0 {
            finished = true
            closeFile()
            connection.cancel()
            return
        }
        guard let handle else { abort(); return }
        do {
            guard let chunk = try handle.read(upToCount: Int(min(remaining, 256 * 1024))), !chunk.isEmpty else {
                // File truncated during streaming: a shorter-than-advertised body must fail closed.
                abort(); return
            }
            remaining -= Int64(chunk.count)
            connection.send(chunk) { [self] ok in
                Task { await didSend(ok: ok) }
            }
        } catch {
            abort()
        }
    }

    func abort() {
        guard !finished else { return }
        finished = true
        closeFile()
        connection.cancel()
    }

    private func closeFile() {
        try? handle?.close()
        handle = nil
    }
}

/// Hosts each feed from this Mac, like the original: the episode listing (RSS), the audio (with byte ranges so
/// players can seek), artwork, chapters and transcripts. Apple Podcasts on this Mac reads it directly; other
/// apps need the listing at a web address, which the optional upload provides.
@MainActor
final class FeedServer {
    private weak var library: Library?
    private var listener: SocketListener?
    private var connections: [ObjectIdentifier: SocketConnection] = [:]
    private(set) var port: Int = Mechanics.defaultHostPort
    /// The episode the Mac is playing right now, so a phone's progress never overrides it.
    var macPlayingEpisode: (() -> UUID?)?
    private let artworkCache: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        cache.totalCostLimit = 64 * 1_048_576
        return cache
    }()
    var status: String = "Stopped"

    init(library: Library) { self.library = library }

    // MARK: Addresses

    static var localHostName: String {
        if Snapshot.active { return "this-mac.local" }
        if let name = SCDynamicStoreCopyLocalHostName(nil) as String? { return "\(name).local" }
        return ProcessInfo.processInfo.hostName
    }

    /// The host feed links use: the Tailscale name or address when chosen (or, on Automatic, when Tailscale is
    /// connected), so other devices on your tailnet reach this Mac from anywhere; otherwise the local network name.
    var linkHost: String {
        if Snapshot.active { return Self.localHostName }
        let tailscale = TailscaleInfo.shared.host
        switch library?.settings.linkAddress ?? .automatic {
        case .localNetwork: return Self.localHostName
        case .tailscale, .automatic: return tailscale ?? Self.localHostName
        }
    }

    func baseURL(port p: Int? = nil) -> String { "http://\(linkHost):\(p ?? port)" }
    func localNetworkURL(port p: Int? = nil) -> String { "http://\(Self.localHostName):\(p ?? port)" }
    func tailscaleURL(port p: Int? = nil) -> String? { TailscaleInfo.shared.host.map { "http://\($0):\(p ?? port)" } }
    func feedURL(_ feed: Feed) -> String { "\(baseURL())/feeds/\(feed.token).xml" }
    func showURL(_ show: Show) -> String { "\(baseURL())/shows/\(show.id.uuidString.lowercased()).xml" }

    func onlineURL(_ feed: Feed) -> String? {
        guard let lib = library, !feed.localOnly else { return nil }
        let base = lib.settings.uploadURL.trimmingCharacters(in: .whitespaces)
        guard !base.isEmpty else { return nil }
        return (base.hasSuffix("/") ? base : base + "/") + "\(feed.token).xml"
    }

    /// Subscribe links for podcast apps. Apple Podcasts reads from this Mac; the others fetch through their
    /// own servers, so they get the online address when there is one.
    func subscribeURL(app: String, feed: Feed) -> URL? {
        let local = feedURL(feed)
        let shared = onlineURL(feed) ?? local
        let noScheme = shared.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
        switch app {
        case "apple": return URL(string: local.replacingOccurrences(of: "http://", with: "podcast://"))
        case "overcast": return URL(string: "overcast://x-callback-url/add?url=" + (shared.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? shared))
        case "pocketcasts": return URL(string: "pktc://subscribe/" + noScheme)
        case "castro": return URL(string: "castro://subscribe/" + noScheme)
        default: return URL(string: shared)
        }
    }

    func subscribeURL(app: String, show: Show) -> URL? {
        let local = showURL(show)
        let encoded = local.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? local
        let noScheme = local.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
        switch app {
        case "apple": return URL(string: local.replacingOccurrences(of: "http://", with: "podcast://"))
        case "overcast": return URL(string: "overcast://x-callback-url/add?url=" + encoded)
        case "pocketcasts": return URL(string: "pktc://subscribe/" + noScheme)
        case "castro": return URL(string: "castro://subscribe/" + noScheme)
        default: return URL(string: local)
        }
    }

    // MARK: Start / stop

    func start() {
        guard let lib = library, lib.settings.hostingEnabled else { stop(); return }
        if listener != nil && port == lib.settings.hostPort { return }
        stop()
        port = lib.settings.hostPort
        guard let endpointPort = UInt16(exactly: port), port > 0 else {
            status = "Couldn’t start: invalid port \(port)"
            lib.hostingStatus = status
            return
        }
        do {
            // Every interface: the local network, this Mac itself, and Tailscale's tunnel.
            listener = try SocketListener(port: endpointPort) { [weak self] conn in
                Task { @MainActor in self?.accept(conn) }
            }
            status = "Serving on port \(port)"
            lib.hostingStatus = status
        } catch {
            status = "Couldn’t start: \(error.localizedDescription)"
            lib.hostingStatus = status
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        status = "Stopped"
        library?.hostingStatus = status
    }

    // MARK: HTTP

    private struct Request { var method: String; var path: String; var host: String?; var range: String?; var forwardedProto: String? }
    private static let headerTerminator = Data("\r\n\r\n".utf8)
    private static let maxHeaderBytes = 16 * 1024

    private func accept(_ conn: SocketConnection) {
        let id = ObjectIdentifier(conn)
        connections[id] = conn
        conn.onClose { [weak self] in
            Task { @MainActor in self?.connections.removeValue(forKey: id) }
        }
        receiveHeaders(on: conn, buffer: Data())
    }

    /// TCP can split even a tiny HTTP request across packets. Read until CRLFCRLF with a strict bound.
    private func receiveHeaders(on conn: SocketConnection, buffer: Data) {
        conn.receive(maximumLength: 64 * 1024) { [weak self] data in
            Task { @MainActor in
                guard let self else { conn.cancel(); return }
                var bytes = buffer
                if let data { bytes.append(data) }
                guard bytes.count <= Self.maxHeaderBytes else {
                    self.send(conn, status: "431 Request Header Fields Too Large", type: "text/plain", body: Data(), head: true)
                    return
                }
                if let end = bytes.range(of: Self.headerTerminator) {
                    guard let text = String(data: bytes[..<end.upperBound], encoding: .utf8) else {
                        self.send(conn, status: "400 Bad Request", type: "text/plain", body: Data(), head: true)
                        return
                    }
                    self.respond(to: self.parse(text), on: conn)
                } else if data?.isEmpty == false {
                    self.receiveHeaders(on: conn, buffer: bytes)
                } else {
                    conn.cancel()
                }
            }
        }
    }

    private func parse(_ text: String) -> Request {
        let lines = text.components(separatedBy: "\r\n")
        let first = lines.first?.split(separator: " ") ?? []
        var req = Request(method: first.first.map(String.init) ?? "GET",
                          path: first.count > 1 ? String(first[1]) : "/", host: nil, range: nil, forwardedProto: nil)
        for l in lines.dropFirst() {
            let parts = l.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            switch parts[0].lowercased() {
            case "host": req.host = parts[1]
            case "range": req.range = parts[1]
            case "x-forwarded-proto": req.forwardedProto = parts[1].lowercased()
            default: break
            }
        }
        return req
    }

    private func respond(to req: Request, on conn: SocketConnection) {
        guard let lib = library else { conn.cancel(); return }
        guard req.method == "GET" || req.method == "HEAD" else {
            send(conn, status: "405 Method Not Allowed", type: "text/plain", body: Data(), extra: ["Allow": "GET, HEAD"], head: true)
            return
        }
        let safeHost = req.host.flatMap { host -> String? in
            guard host.utf8.count <= 255, !host.isEmpty,
                  host.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.:-[]").contains($0) })
            else { return nil }
            return host
        }
        // Behind Tailscale Serve the request arrives as https://<name>.ts.net (no port): links keep that scheme.
        let https = req.forwardedProto == "https" || (safeHost.map { $0.hasSuffix(".ts.net") && !$0.contains(":") } ?? false)
        let base = safeHost.map { "\(https ? "https" : "http")://\($0)" } ?? baseURL()
        let path = req.path.components(separatedBy: "?").first ?? req.path
        let parts = path.split(separator: "/").map(String.init)
        let head = req.method == "HEAD"

        // The iPhone app as an AltStore / LiveContainer source (AltStoreSource.swift).
        if parts.first == "altstore" {
            if parts.count == 1 {
                send(conn, status: "200 OK", type: "text/html; charset=utf-8", body: IPhoneRelease.page(base: base), head: head)
            } else if parts.count == 2, parts[1] == "source.json" {
                send(conn, status: "200 OK", type: "application/json", body: IPhoneRelease.source(base: base), head: head)
            } else if parts.count == 2, parts[1] == "PodCraft.ipa", let ipa = IPhoneRelease.ipa {
                sendFile(conn, path: ipa.path, range: req.range, head: head)
            } else if parts.count == 2, parts[1] == "icon.png", let icon = IPhoneRelease.icon,
                      let data = try? Data(contentsOf: icon) {
                send(conn, status: "200 OK", type: "image/png", body: data, head: head)
            } else {
                send(conn, status: "404 Not Found", type: "text/plain", body: Data("Not found".utf8), head: head)
            }
            return
        }
        // The iPhone app's private API (PhoneAPI), behind the pairing code.
        if parts.count >= 3, parts[0] == "api" {
            guard parts[1] == lib.settings.phoneCode else {
                send(conn, status: "403 Forbidden", type: "text/plain", body: Data("Scan the new code in PodCraft’s Settings.".utf8), head: head)
                return
            }
            let query = req.path.components(separatedBy: "?").dropFirst().joined(separator: "?")
            if parts.count == 3, parts[2] == "library.json" {
                send(conn, status: "200 OK", type: "application/json", body: PhoneAPI.library(lib, base: base), head: head)
            } else if parts.count == 4, parts[2] == "episodes", let e = episode(parts[3], lib) {
                send(conn, status: "200 OK", type: "application/json", body: PhoneAPI.episode(e, base: base), head: head)
            } else if parts.count == 4, parts[2] == "progress", let e = episode(parts[3], lib) {
                let saved = PhoneAPI.progress(e.id, query: query, lib: lib, macIsPlaying: macPlayingEpisode?())
                send(conn, status: "200 OK", type: "application/json", body: Data("{\"saved\":\(saved)}".utf8), head: head)
            } else {
                send(conn, status: "404 Not Found", type: "text/plain", body: Data(), head: head)
            }
            return
        }
        if parts.count == 2, parts[0] == "feeds", parts[1].hasSuffix(".xml"),
           let feed = lib.feeds.first(where: { "\($0.token).xml" == parts[1] }) {
            send(conn, status: "200 OK", type: "application/rss+xml; charset=utf-8",
                 body: Data(RSSGenerator.xml(feed: feed, library: lib, base: base).utf8), head: head)
        } else if parts.count == 2, parts[0] == "shows", parts[1].hasSuffix(".xml"),
                  let id = UUID(uuidString: String(parts[1].dropLast(4))), let show = lib.show(id) {
            send(conn, status: "200 OK", type: "application/rss+xml; charset=utf-8",
                 body: Data(RSSGenerator.xml(show: show, library: lib, base: base).utf8), head: head)
        } else if parts.count == 2, parts[0] == "artwork", let data = artwork(named: parts[1], library: lib) {
            let type = data.starts(with: [0xFF, 0xD8]) ? "image/jpeg" : "image/png"
            send(conn, status: "200 OK", type: type, body: data, head: head)
        } else if parts.count == 2, parts[0] == "chapters", let e = episode(parts[1], lib) {
            let json: [String: Any] = ["version": "1.2.0", "chapters": e.chapters.sorted { $0.start < $1.start }
                .map { ["startTime": $0.start, "title": $0.title] }]
            send(conn, status: "200 OK", type: "application/json+chapters",
                 body: (try? JSONSerialization.data(withJSONObject: json)) ?? Data(), head: head)
        } else if parts.count == 2, parts[0] == "transcripts", let e = episode(parts[1], lib) {
            send(conn, status: "200 OK", type: "text/vtt; charset=utf-8", body: Data(RSSGenerator.vtt(e).utf8), head: head)
        } else if parts.count == 2, parts[0] == "media", let e = episode(parts[1], lib) {
            if let f = e.localFile, FileManager.default.fileExists(atPath: f) {
                sendFile(conn, path: f, range: req.range, head: head)
            } else if let remote = e.audioURL {
                send(conn, status: "302 Found", type: "text/plain", body: Data(), extra: ["Location": remote], head: head)
            } else {
                send(conn, status: "404 Not Found", type: "text/plain", body: Data("Not found".utf8), head: head)
            }
        } else {
            send(conn, status: "404 Not Found", type: "text/plain", body: Data("Not found".utf8), head: head)
        }
    }

    private func episode(_ name: String, _ lib: Library) -> Episode? {
        let idText = name.components(separatedBy: ".").first ?? name
        guard let id = UUID(uuidString: idText) else { return nil }
        return lib.episode(id)
    }

    private func send(_ conn: SocketConnection, status: String, type: String, body: Data, extra: [String: String] = [:], head: Bool) {
        var header = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\nAccess-Control-Allow-Origin: *\r\n"
        // Never allow upstream metadata (notably enclosure redirect URLs) to
        // inject a second HTTP header into our local server response.
        for (k, v) in extra where !k.contains("\r") && !k.contains("\n") && !v.contains("\r") && !v.contains("\n") {
            header += "\(k): \(v)\r\n"
        }
        header += "\r\n"
        var out = Data(header.utf8)
        if !head { out.append(body) }
        conn.send(out) { _ in conn.cancel() }
    }

    /// The stream actor owns the descriptor and sequences every network send before reading more.
    private func sendFile(_ conn: SocketConnection, path: String, range: String?, head: Bool) {
        let stream = MediaFileStream(connection: conn, path: path, range: range, head: head)
        conn.onClose { [weak stream] in Task { await stream?.abort() } }
        Task { await stream.start() }
    }

    // MARK: Artwork (rendered from the same placeholder art the app shows, 1400 px as podcast apps expect)

    private func artwork(named file: String, library lib: Library) -> Data? {
        if let cached = artworkCache.object(forKey: file as NSString) { return cached as Data }
        let key = file.replacingOccurrences(of: ".png", with: "")
        var view: ArtworkView?
        if let f = lib.feeds.first(where: { $0.token == key }) {
            view = ArtworkView(title: f.title, hue: f.hue, size: 1400, borderHue: f.showsBorder ? f.borderHue : nil,
                               borderWidth: f.showsBorder ? f.borderWidth : 0, symbol: "dot.radiowaves.left.and.right")
        } else if let id = UUID(uuidString: key), let s = lib.show(id),
                  let real = s.customArtwork.flatMap({ try? Data(contentsOf: URL(fileURLWithPath: $0)) }) ?? ArtworkStore.data(for: s.artworkURL) {
            artworkCache.setObject(real as NSData, forKey: file as NSString, cost: real.count)
            return real
        } else if key.hasPrefix("ep-"), let id = UUID(uuidString: String(key.dropFirst(3))), let e = lib.episode(id),
                  let real = ArtworkStore.data(for: e.artworkURL) ?? ArtworkStore.data(for: lib.show(e.showID)?.artworkURL) {
            artworkCache.setObject(real as NSData, forKey: file as NSString, cost: real.count)
            return real
        } else if let id = UUID(uuidString: key), let s = lib.show(id) {
            let f = lib.feed(s.feedID)
            view = ArtworkView(title: s.title, hue: s.hue, size: 1400, borderHue: (f?.showsBorder ?? false) ? f?.borderHue : nil,
                               borderWidth: (f?.showsBorder ?? false) ? (f?.borderWidth ?? 0) : 0)
        }
        guard let v = view else { return nil }
        let renderer = ImageRenderer(content: v)
        renderer.scale = 1
        guard let cg = renderer.cgImage else { return nil }
        let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
        if let data { artworkCache.setObject(data as NSData, forKey: file as NSString, cost: data.count) }
        return data
    }

    func invalidateArtwork() { artworkCache.removeAllObjects() }

    // MARK: Optional upload of the listing to your own web address (HTTP PUT)

    func publishAll() async -> String {
        guard let lib = library else { return "" }
        let base = lib.settings.uploadURL.trimmingCharacters(in: .whitespaces)
        guard !base.isEmpty else { return "No upload address set." }
        var done = 0, failed = 0
        for feed in lib.feeds where !feed.localOnly {
            guard let target = onlineURL(feed), let url = URL(string: target) else { continue }
            var req = URLRequest(url: url)
            req.httpMethod = "PUT"
            req.setValue("application/rss+xml", forHTTPHeaderField: "Content-Type")
            if let token = Keychain.read("upload"), !token.isEmpty { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            req.httpBody = Data(RSSGenerator.xml(feed: feed, library: lib, base: baseURL()).utf8)
            if let (_, resp) = try? await URLSession.shared.data(for: req), let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                done += 1
            } else { failed += 1 }
        }
        return failed == 0 ? "Uploaded \(done) feed listings." : "Uploaded \(done), \(failed) failed. Links point at this Mac until an upload works again."
    }
}

/// Writes the RSS listing for one feed (same channel layout as the original's RSSGenerator, 0x10005a158:
/// itunes, content, atom and podcast namespaces, a podcast:guid, and itunes:block so directories skip it).
enum RSSGenerator {
    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static let rfc822: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return f
    }()

    @MainActor
    static func xml(feed: Feed, library lib: Library, base: String) -> String {
        let eps = lib.episodes(inFeed: feed.id).filter { $0.stage == .ready && !$0.isSample }
        return xml(title: feed.title, author: feed.author, summary: feed.summary,
                   guid: feed.id, path: "feeds/\(feed.token).xml", artwork: feed.token,
                   episodes: eps, library: lib, base: base)
    }

    @MainActor
    static func xml(show: Show, library lib: Library, base: String) -> String {
        let eps = lib.episodes(inShow: show.id).filter { $0.stage == .ready && !$0.isSample && !show.skips($0) }
        return xml(title: show.title, author: show.author, summary: show.summary,
                   guid: show.id, path: "shows/\(show.id.uuidString.lowercased()).xml",
                   artwork: show.id.uuidString, episodes: eps, library: lib, base: base)
    }

    @MainActor
    private static func xml(title: String, author: String, summary: String, guid: UUID, path: String,
                            artwork: String, episodes eps: [Episode], library lib: Library, base: String) -> String {
        var x = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd" xmlns:content="http://purl.org/rss/1.0/modules/content/" xmlns:atom="http://www.w3.org/2005/Atom" xmlns:podcast="https://podcastindex.org/namespace/1.0">
        <channel>
         <title>\(esc(title))</title>
         <description>\(esc(summary))</description>
         <itunes:subtitle>\(esc(summary))</itunes:subtitle>
         <link>\(base)/\(path)</link>
         <atom:link href="\(base)/\(path)" rel="self" type="application/rss+xml" />
         <podcast:guid>\(guid.uuidString.lowercased())</podcast:guid>
         <generator>PodCraft</generator>
         <lastBuildDate>\(rfc822.string(from: Date()))</lastBuildDate>
         <itunes:author>\(esc(author))</itunes:author>
         <itunes:type>episodic</itunes:type>
         <itunes:explicit>false</itunes:explicit>
         <itunes:block>yes</itunes:block>
         <itunes:image href="\(base)/artwork/\(artwork).png" />
         <image><url>\(base)/artwork/\(artwork).png</url><title>\(esc(title))</title><link>\(base)</link></image>

        """
        for e in eps {
            let show = lib.show(e.showID)
            let ext = e.localFile.map { ($0 as NSString).pathExtension } ?? (URL(string: e.audioURL ?? "")?.pathExtension ?? "mp3")
            let type = UTType(filenameExtension: ext.isEmpty ? "mp3" : ext)?.preferredMIMEType ?? "audio/mpeg"
            let size = e.localFile.flatMap { (try? FileManager.default.attributesOfItem(atPath: $0)[.size] as? NSNumber)?.intValue } ?? 0
            x += """
             <item>
              <title>\(esc(e.title))</title>
              <guid isPermaLink="false">\(e.id.uuidString.lowercased())</guid>
              <pubDate>\(rfc822.string(from: e.published))</pubDate>
              <description>\(esc(e.summary))</description>
              <itunes:author>\(esc(show?.author ?? author))</itunes:author>
              <itunes:duration>\(Int(e.duration))</itunes:duration>
              <itunes:image href="\(base)/artwork/\(e.artworkURL != nil ? "ep-\(e.id.uuidString)" : e.showID.uuidString).png" />
              <enclosure url="\(base)/media/\(e.id.uuidString).\(ext.isEmpty ? "mp3" : ext)" length="\(size)" type="\(type)" />

            """
            if !e.chapters.isEmpty {
                x += "  <podcast:chapters url=\"\(base)/chapters/\(e.id.uuidString).json\" type=\"application/json+chapters\" />\n"
            }
            if !e.transcript.isEmpty {
                x += "  <podcast:transcript url=\"\(base)/transcripts/\(e.id.uuidString).vtt\" type=\"text/vtt\" />\n"
            }
            x += " </item>\n"
        }
        x += "</channel>\n</rss>\n"
        return x
    }

    static func vtt(_ e: Episode) -> String {
        func ts(_ t: Double) -> String {
            let ms = Int((t * 1000).rounded())
            return String(format: "%02d:%02d:%02d.%03d", ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60, ms % 1000)
        }
        return "WEBVTT\n\n" + e.transcript.map { "\(ts($0.start)) --> \(ts(max($0.end, $0.start + 0.5)))\n\($0.text)\n" }.joined(separator: "\n")
    }
}

/// OPML import and export of the shows that come from a feed link (the original offers both).
enum OPML {
    @MainActor
    static func export(_ lib: Library) -> String {
        var x = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<opml version=\"2.0\">\n<head><title>PodCraft subscriptions</title></head>\n<body>\n"
        for s in lib.shows where s.feedURL != nil {
            x += "  <outline type=\"rss\" text=\"\(RSSGenerator.esc(s.title))\" title=\"\(RSSGenerator.esc(s.title))\" xmlUrl=\"\(RSSGenerator.esc(s.feedURL!))\" />\n"
        }
        return x + "</body>\n</opml>\n"
    }

    static func feedLinks(in data: Data) -> [String] {
        let text = String(data: data, encoding: .utf8) ?? ""
        let pattern = "xmlUrl=\"([^\"]+)\""
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        return re.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]).replacingOccurrences(of: "&amp;", with: "&") }
        }
    }
}
