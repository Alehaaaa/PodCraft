import SwiftUI
import UniformTypeIdentifiers

/// The feed's links and "Subscribe in…" buttons for podcast apps.
struct FeedLinkRow: View {
    @Environment(Library.self) private var library
    let feed: Feed

    var body: some View {
        let server = library.server
        let local = server?.feedURL(feed) ?? feed.privateLink
        let online = server?.onlineURL(feed)
        VStack(alignment: .leading, spacing: 6) {
            Text("Podcast Feed Link").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Image(systemName: library.settings.hostingEnabled ? "dot.radiowaves.left.and.right" : "pause.circle")
                    .foregroundStyle(library.settings.hostingEnabled ? Color.green : Color.secondary)
                Text(local)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Copy Link") { copy(online ?? local) }
                    .buttonStyle(.glass).controlSize(.small)
                Menu {
                    Button("Apple Podcasts") { open("apple") }
                    Divider()
                    Button("Overcast") { open("overcast") }
                    Button("Pocket Casts") { open("pocketcasts") }
                    Button("Castro") { open("castro") }
                } label: {
                    Label("Subscribe in…", systemImage: "plus.app")
                }
                .menuStyle(.button).buttonStyle(.glass).controlSize(.small).fixedSize()
            }
            if let online {
                HStack(spacing: 8) {
                    Image(systemName: "globe").foregroundStyle(.secondary)
                    Text(online).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(1)
                }
            } else if feed.localOnly {
                Label("Local only: the listing stays on this Mac.", systemImage: "lock.fill")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        library.flash("Feed link copied")
    }

    func open(_ app: String) {
        guard library.settings.hostingEnabled else { library.flash("Turn on hosting in Settings first."); return }
        if let url = library.server?.subscribeURL(app: app, feed: feed) {
            if !NSWorkspace.shared.open(url) { library.flash("That app isn’t installed on this Mac.") }
        }
    }
}

/// A per-show RSS link containing PodCraft's downloaded, sponsor-cleaned episodes.
struct ShowLinkRow: View {
    @Environment(Library.self) private var library
    let show: Show

    var body: some View {
        let link = library.server?.showURL(show) ?? "http://localhost:\(library.settings.hostPort)/shows/\(show.id.uuidString.lowercased()).xml"
        Menu {
            Button("Copy Local Feed Link") { copy(link) }
            Button("Open in Apple Podcasts") { open("apple") }
            Divider()
            Button("Open in Overcast") { open("overcast") }
            Button("Open in Pocket Casts") { open("pocketcasts") }
            Button("Open in Castro") { open("castro") }
            Divider()
            Text(link)
        } label: {
            Label("Podcast Link", systemImage: library.settings.hostingEnabled ? "dot.radiowaves.left.and.right" : "pause.circle")
        }
        .menuStyle(.button).buttonStyle(.glass).controlSize(.small).fixedSize()
        .help("Copy this show's local PodCraft RSS link or open it in a podcast app")
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        library.flash("Show feed link copied")
    }

    private func open(_ app: String) {
        guard library.settings.hostingEnabled else { library.flash("Turn on hosting in Settings first."); return }
        if let url = library.server?.subscribeURL(app: app, show: show), !NSWorkspace.shared.open(url) {
            library.flash("That app isn’t installed on this Mac.")
        }
    }
}

/// OPML import / export buttons.
struct OPMLButtons: View {
    @Environment(Library.self) private var library

    var body: some View {
        Button("Import OPML…") { importOPML() }
        Button("Export OPML…") { exportOPML() }
    }

    func exportOPML() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "PodCraft Subscriptions.opml"
        panel.message = "Export your podcast subscriptions as an OPML file."
        if panel.runModal() == .OK, let url = panel.url {
            try? OPML.export(library).write(to: url, atomically: true, encoding: .utf8)
            library.flash("Subscriptions exported")
        }
    }

    func importOPML() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "opml") ?? .xml, .xml]
        panel.message = "Choose an OPML file to import your podcast subscriptions."
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        let links = OPML.feedLinks(in: data)
        let known = Set(library.shows.compactMap(\.feedURL))
        library.flash("Importing \(links.count) shows…")
        Task { @MainActor in
            for link in links where !known.contains(link) {
                guard let u = URL(string: link), let parsed = try? await FeedFetcher.fetch(u) else { continue }
                var show = Show(title: parsed.title, author: parsed.author, feedURL: link,
                                artworkURL: parsed.artwork, hue: Double.random(in: 0...1), summary: parsed.summary,
                                keepAvailable: library.settings.defaultAvailable)
                show.language = parsed.language
                library.addShow(show, items: parsed.items)
            }
        }
    }
}
