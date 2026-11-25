import SwiftUI

/// "Add a show: search or paste a link". The show is added on its own; putting it into a feed is optional.
struct AddShowSheet: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [FeedFetcher.SearchResult] = []
    @State private var busy = false
    @State private var message: String? = nil
    @State private var targetFeed: UUID? = nil
    @State private var keepAvailable = Mechanics.defaultAvailablePerShow
    @State private var youtubeChannelText = ""

    /// Accept the same strictly validated channel forms as the playback source.
    /// This is a format check, not a claim that the channel belongs to the show.
    private var youtubeChannelInput: String {
        youtubeChannelText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var invalidYouTubeChannel: Bool {
        !youtubeChannelInput.isEmpty && YouTubeSource.channelURL(from: youtubeChannelInput) == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add a Show").font(.title2.bold())
            Text("Search by name, or paste any podcast feed link.").foregroundStyle(.secondary)
            HStack {
                TextField("A show name or a feed link", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(go)
                Button(FeedFetcher.looksLikeLink(query) ? "Add" : "Search", action: go)
                    .buttonStyle(.glassProminent)
                    .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || busy)
            }
            VStack(alignment: .leading, spacing: 4) {
                TextField("Official YouTube channel (optional)", text: $youtubeChannelText,
                          prompt: Text("https://www.youtube.com/@Channel"))
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.URL)
                if invalidYouTubeChannel {
                    Label("Use an HTTPS YouTube channel link (youtube.com/@handle or youtube.com/channel/UC…). Not a video or playlist.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                } else {
                    Text("Leave blank to automatically look for the official channel after adding the show. The podcast feed remains available if no match is verified.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 16) {
                Stepper("Keep the newest \(keepAvailable) on this Mac", value: $keepAvailable, in: 0...50)
                    .fixedSize()
                Spacer()
                Picker("Feed", selection: $targetFeed) {
                    Text("Not in a feed").tag(UUID?.none)
                    ForEach(library.feeds) { f in Text(f.title).tag(Optional(f.id)) }
                }
                .fixedSize()
            }
            Text("Every episode is listed; only the newest \(keepAvailable == 1 ? "one is" : "\(keepAvailable) are") downloaded. Download any other by hand later.")
                .font(.caption).foregroundStyle(.secondary)
            if busy { ProgressView().frame(maxWidth: .infinity) }
            if let message { Text(message).foregroundStyle(.secondary).font(.callout) }
            List(results) { r in
                HStack {
                    RemoteCover(url: r.artwork, title: r.title, size: 40)
                    VStack(alignment: .leading) {
                        Text(r.title).fontWeight(.medium)
                        Text(r.author).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if library.shows.contains(where: { $0.feedURL == r.feedURL }) {
                        Text("Added").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Button("Add") { add(link: r.feedURL, artwork: r.artwork) }.disabled(busy)
                    }
                }
            }
            .frame(minHeight: 200)
            HStack {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(22)
        .frame(width: 600, height: 610)
        .onAppear {
            targetFeed = library.addShowTargetFeed
            keepAvailable = library.settings.defaultAvailable
        }
    }

    func go() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        if FeedFetcher.looksLikeLink(q) { add(link: q, artwork: nil); return }
        busy = true; message = nil
        Task { @MainActor in
            do {
                results = try await FeedFetcher.search(q)
                message = results.isEmpty ? "No shows match “\(q)”. If the show isn’t in the directory, paste its feed link instead." : nil
            } catch {
                message = "Search isn’t reachable right now. Check your connection, or paste a feed link."
            }
            busy = false
        }
    }

    func add(link: String, artwork: String?) {
        guard !invalidYouTubeChannel else {
            message = "Enter a valid HTTPS YouTube channel URL, not a video or playlist, or leave the optional field empty for automatic discovery."
            return
        }
        // Capture once so a slow feed fetch cannot save a URL typed later.
        let channelURL = youtubeChannelInput.isEmpty ? nil : YouTubeSource.channelURL(from: youtubeChannelInput)?.absoluteString
        guard let url = URL(string: link) else { message = "That link doesn’t look right."; return }
        if library.shows.contains(where: { $0.feedURL == link }) { message = "That show is already in your library."; return }
        busy = true; message = nil
        Task { @MainActor in
            do {
                let parsed = try await FeedFetcher.fetch(url)
                var show = Show(feedID: targetFeed, title: parsed.title,
                                author: parsed.author.isEmpty ? "Unknown" : parsed.author,
                                feedURL: link, artworkURL: parsed.artwork ?? artwork, hue: Double.random(in: 0...1),
                                summary: parsed.summary, keepAvailable: keepAvailable)
                show.language = parsed.language
                show.youtubeChannelURL = channelURL
                library.addShow(show, items: parsed.items)
                library.setMode(.manage)
                busy = false
                dismiss()
            } catch {
                busy = false
                message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

/// A search result's cover, loaded from the web.
struct RemoteCover: View {
    var url: String?
    var title: String
    var size: CGFloat

    var body: some View {
        AsyncImage(url: url.flatMap(URL.init(string:))) { phase in
            if let img = phase.image {
                img.resizable().scaledToFill()
            } else {
                ArtworkView(title: title, hue: 0.6, size: size)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.2, style: .continuous))
    }
}
