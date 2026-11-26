import Foundation
import SwiftUI
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// What the PodCraft iPhone app reads from this Mac, behind the private pairing code:
///
///   GET /api/<code>/library.json          shows and their ready (sponsor-cleaned) episodes
///   GET /api/<code>/episodes/<id>.json    one episode with its chapters and transcript
///   GET /api/<code>/progress/<id>?t=…&played=0|1   where the phone got to, so the Mac carries on from there
///
/// Media, artwork, chapters and transcripts are the same addresses the podcast feeds use.
@MainActor
enum PhoneAPI {
    static let iso: ISO8601DateFormatter = ISO8601DateFormatter()

    /// The link the iPhone opens (scanned as a QR code): podcraft://connect?server=…&code=…
    static func connectURL(server: String, code: String) -> String {
        var c = URLComponents()
        c.scheme = "podcraft"
        c.host = "connect"
        c.queryItems = [URLQueryItem(name: "server", value: server), URLQueryItem(name: "code", value: code),
                        URLQueryItem(name: "name", value: Host.current().localizedName ?? "Mac")]
        return c.string ?? ""
    }

    static func servedEpisodes(_ show: Show, _ lib: Library) -> [Episode] {
        lib.episodes(inShow: show.id)
            .filter { $0.stage == .ready && !$0.isSample && !show.skips($0) }
            .sorted { $0.published > $1.published }
    }

    /// Every listed episode the phone can play: cleaned ones from this Mac, the rest streamed from the show
    /// (the media address forwards to the original). Newest first, at most 300 per show.
    static func listedEpisodes(_ show: Show, _ lib: Library) -> [Episode] {
        Array(lib.listenable(lib.episodes(inShow: show.id)).filter { !$0.isSample }.prefix(300))
    }

    static func mediaExtension(_ e: Episode) -> String {
        let ext = e.localFile.map { ($0 as NSString).pathExtension } ?? (URL(string: e.audioURL ?? "")?.pathExtension ?? "mp3")
        return ext.isEmpty ? "mp3" : ext
    }

    static func episodeSummary(_ e: Episode, base: String) -> [String: Any] {
        var row: [String: Any] = [
            "id": e.id.uuidString,
            "showID": e.showID.uuidString,
            "title": e.title,
            "summary": e.summary,
            "published": iso.string(from: e.published),
            "duration": e.duration,
            "position": e.position,
            "played": e.played,
            "isVideo": e.isVideo,
            "media": "\(base)/media/\(e.id.uuidString).\(mediaExtension(e))",
            "artwork": "\(base)/artwork/\(e.artworkURL != nil ? "ep-\(e.id.uuidString)" : e.showID.uuidString).png",
            "hasTranscript": !e.transcript.isEmpty,
            // Downloaded and cleaned on the Mac (sponsors removed, chapters); otherwise streamed as published.
            "onMac": e.stage == .ready,
        ]
        // The verified upload on the show's official YouTube channel, so the phone can switch to the video.
        if let youtube = MacSync.verifiedYouTubeID(e) { row["youtube"] = youtube }
        row["chapters"] = e.chapters.sorted { $0.start < $1.start }.map { ["start": $0.start, "title": $0.title] }
        return row
    }

    static func library(_ lib: Library, base: String) -> Data {
        // Every show in the library, including ones with nothing downloaded yet.
        let shows: [[String: Any]] = lib.sortedShows.map { show in
            let eps = listedEpisodes(show, lib)
            return [
                "id": show.id.uuidString,
                "title": show.title,
                "author": show.author,
                "summary": show.summary,
                "artwork": "\(base)/artwork/\(show.id.uuidString).png",
                "feed": "\(base)/shows/\(show.id.uuidString.lowercased()).xml",
                "episodes": eps.map { episodeSummary($0, base: base) },
            ]
        }
        // Channels: the feeds built on the Mac, each a group of shows.
        let feeds: [[String: Any]] = lib.feeds.map { feed in
            [
                "id": feed.id.uuidString,
                "title": feed.title,
                "author": feed.author,
                "summary": feed.summary,
                "artwork": "\(base)/artwork/\(feed.token).png",
                "showIDs": lib.shows(in: feed.id).map { $0.id.uuidString },
            ]
        }
        let body: [String: Any] = ["server": "PodCraft", "version": 2,
                                   "name": Host.current().localizedName ?? "Mac", "shows": shows, "feeds": feeds]
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)
    }

    static func episode(_ e: Episode, base: String) -> Data {
        var row = episodeSummary(e, base: base)
        row["transcript"] = e.transcript.map { ["start": $0.start, "end": $0.end, "text": $0.text] }
        return (try? JSONSerialization.data(withJSONObject: row)) ?? Data("{}".utf8)
    }

    /// Records the phone's position (unless the Mac is playing that episode right now).
    static func progress(_ id: UUID, query: String, lib: Library, macIsPlaying: UUID?) -> Bool {
        guard let i = lib.episodeIndex(id), macIsPlaying != id else { return false }
        let items = URLComponents(string: "x:?" + query)?.queryItems ?? []
        if let t = items.first(where: { $0.name == "t" })?.value.flatMap(Double.init), t.isFinite, t >= 0 {
            lib.episodes[i].position = min(t, max(lib.episodes[i].duration, t))
        }
        if let played = items.first(where: { $0.name == "played" })?.value {
            lib.episodes[i].played = played == "1"
        }
        lib.save()
        return true
    }

    static func qrImage(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

/// Settings → iPhone: scan the code with the iPhone's camera to open PodCraft there, connected to this Mac.
struct PhonePairingSection: View {
    @Environment(Library.self) private var library
    @State private var confirmReset = false

    @State private var serveBusy = false

    var body: some View {
        // Prefer https://<name>.ts.net when Tailscale Serve is on (a real certificate on your tailnet).
        let server = TailscaleInfo.shared.httpsBase ?? library.server?.baseURL(port: library.settings.hostPort) ?? ""
        let link = PhoneAPI.connectURL(server: server, code: library.settings.phoneCode)
        let installPage = IPhoneRelease.pageURL(base: server)
        let release = IPhoneRelease.info
        Section {
            HStack(alignment: .center, spacing: 18) {
                qrCard(installPage, caption: "1. Install")
                qrCard(link, caption: "2. Connect")
                VStack(alignment: .leading, spacing: 8) {
                    Text("Scan **Install** with the iPhone’s camera, then **Connect** to open PodCraft with this Mac’s library — cleaned episodes, chapters and transcripts.")
                        .font(.callout)
                    Text(release.map { "iPhone app \($0.version) (\($0.build))" } ?? "No iPhone build in this copy of PodCraft.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
            DisclosureGroup("More") {
                HStack {
                    Button("Copy Install Link") { copy(IPhoneRelease.sourceURL(base: server), "AltStore source link copied") }
                    Button("Copy Connect Link") { copy(link, "iPhone link copied") }
                    Button("New Connect Code…") { confirmReset = true }
                }
                .controlSize(.small)
                Text(TailscaleInfo.shared.isConnected
                     ? "Links use your Tailscale address, so the iPhone can reach this Mac away from home with Tailscale on."
                     : "Links use your local network. With Tailscale on this Mac and the iPhone, it works away from home too.")
                    .font(.caption).foregroundStyle(.secondary)
                if TailscaleInfo.shared.isConnected { serveRow }
            }
        } header: {
            Text("iPhone App with This Mac")
        } footer: {
            Text("Without the Mac nearby, the iPhone app can follow shows on its own; Sync keeps both in step.")
        }
        .task { TailscaleInfo.shared.refreshServe(port: library.settings.hostPort) }
        .confirmationDialog("Make a new code?", isPresented: $confirmReset) {
            Button("New Code", role: .destructive) {
                library.settings.phoneCode = AppSettings.newPhoneCode()
                library.save()
            }
        } message: {
            Text("Phones connected with the current code will need to scan the new one.")
        }
        .disabled(!library.settings.hostingEnabled)
    }

    private func qrCard(_ text: String, caption: String) -> some View {
        VStack(spacing: 6) {
            if let qr = PhoneAPI.qrImage(text) {
                Image(nsImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 100, height: 100)
                    .padding(7)
                    .background(.white, in: RoundedRectangle(cornerRadius: 10))
            }
            Text(caption).font(.caption.weight(.semibold))
        }
    }

    /// Tailscale Serve: HTTPS on your tailnet with a real certificate.
    @ViewBuilder
    private var serveRow: some View {
        let status = TailscaleInfo.shared.serve
        LabeledContent("HTTPS with Tailscale") {
            if let status, status.serving, let host = status.httpsHost {
                HStack {
                    Text("https://\(host)").textSelection(.enabled).foregroundStyle(.secondary)
                    Button("Turn Off") { toggleServe(false) }.disabled(serveBusy)
                }
            } else if let status, !status.certificatesOn {
                VStack(alignment: .trailing, spacing: 4) {
                    Text("Turn on HTTPS Certificates in Tailscale’s admin console (DNS page) first.")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                    Link("Open Tailscale DNS Settings", destination: URL(string: "https://login.tailscale.com/admin/dns")!)
                        .font(.caption)
                }
            } else if status != nil {
                Button(serveBusy ? "Turning On…" : "Serve over HTTPS") { toggleServe(true) }.disabled(serveBusy)
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }

    private func toggleServe(_ on: Bool) {
        serveBusy = true
        Task { @MainActor in
            if let error = await TailscaleInfo.shared.setServe(on, port: library.settings.hostPort) {
                library.flash(error)
            }
            serveBusy = false
        }
    }

    private func copy(_ value: String, _ message: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        library.flash(message)
    }
}
