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

/// Settings sections for the AI, SponsorBlock and hosting.
struct AISettingsSection: View {
    @Environment(Library.self) private var library
    @State private var geminiKey = Keychain.read("gemini") ?? ""

    var body: some View {
        @Bindable var lib = library
        Section("Processing") {
            Toggle("Remove sponsor chapters", isOn: $lib.settings.removeSponsors)
            Toggle("Transcribe episodes", isOn: $lib.settings.transcribe)
            Toggle("Generate chapters from transcripts automatically", isOn: Binding(
                get: { library.settings.generateChapters },
                set: { enabled in
                    lib.settings.generateChapters = enabled
                    library.save()
                    if enabled { library.generateMissingChapters() }
                }))
        }
        Section {
            Picker("Chapters and sponsor finding", selection: $lib.settings.aiProvider) {
                ForEach(AIProvider.allCases) { Text($0.title).tag($0) }
            }
            switch library.settings.aiProvider {
            case .onDevice:
                LabeledContent("Apple Intelligence", value: Snapshot.active ? "Ready on this Mac" : AIService.onDeviceStatus)
            case .gemini:
                SecureField("Gemini API key", text: $geminiKey)
                    .onSubmit { Keychain.save(geminiKey, for: "gemini") }
                    .onChange(of: geminiKey) { Keychain.save(geminiKey, for: "gemini") }
                TextField("Model", text: $lib.settings.geminiModel)
                Link("Get a key from Google AI Studio", destination: URL(string: "https://aistudio.google.com/apikey")!)
                    .font(.caption)
            case .off:
                Text("Episodes keep the chapters their show publishes.").font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Transcript & AI Chapters")
        } footer: {
            Text("Transcripts are made on this Mac with Apple’s speech recognition. The AI reads them to split chapters and mark ads, which are then cut out.")
        }
        Section {
            Toggle("Use SponsorBlock segments for YouTube episodes", isOn: $lib.settings.useSponsorBlock)
            ForEach(SponsorBlock.allCategories, id: \.id) { cat in
                Toggle(cat.title, isOn: Binding(
                    get: { library.settings.sponsorCategories.contains(cat.id) },
                    set: { on in
                        if on { lib.settings.sponsorCategories.append(cat.id) }
                        else { lib.settings.sponsorCategories.removeAll { $0 == cat.id } }
                    }))
                .disabled(!library.settings.useSponsorBlock)
                .padding(.leading, 16)
            }
        } header: {
            Text("SponsorBlock")
        } footer: {
            Text("Community-marked segments from sponsor.ajay.app, cut along with what the AI finds.")
        }
    }
}

struct HostingSettingsSection: View {
    @Environment(Library.self) private var library
    @State private var uploadToken = Keychain.read("upload") ?? ""
    @State private var publishing = false

    var body: some View {
        @Bindable var lib = library
        Section {
            Toggle("Host feeds from this Mac", isOn: $lib.settings.hostingEnabled)
            Picker("Feed links use", selection: $lib.settings.linkAddress) {
                ForEach(LinkAddress.allCases) { Text($0.title).tag($0) }
            }
            LabeledContent("Local network") {
                Text(library.server?.localNetworkURL(port: library.settings.hostPort) ?? "").textSelection(.enabled)
            }
            LabeledContent("Tailscale") {
                if let url = library.server?.tailscaleURL(port: library.settings.hostPort) {
                    Text(url).textSelection(.enabled)
                } else {
                    Text("Not connected on this Mac").foregroundStyle(.secondary)
                }
            }
            HStack {
                Text("Port")
                TextField("Port", value: $lib.settings.hostPort, format: .number.grouping(.never))
                    .frame(width: 80)
                Spacer()
                Text(library.hostingStatus).font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Keep new feeds local only by default", isOn: $lib.settings.localOnlyByDefault)
        } header: {
            Text("Hosting")
        } footer: {
            Text("Apple Podcasts reads feeds from this Mac directly. With Tailscale on this Mac and your iPhone or other devices, feed links use your tailnet address, so they work away from home too. Apps that fetch feeds from their own servers (Overcast, Pocket Casts) can’t reach a tailnet, so they need the online listing below. Audio streams from this Mac, which has to be awake.")
        }
        Section {
            TextField("Upload address (for example https://example.com/feeds/)", text: $lib.settings.uploadURL)
            SecureField("Upload token (optional)", text: $uploadToken)
                .onChange(of: uploadToken) { Keychain.save(uploadToken, for: "upload") }
            HStack {
                Button(publishing ? "Uploading…" : "Upload Listings Now") {
                    publishing = true
                    Task { @MainActor in
                        let msg = await library.server?.publishAll() ?? ""
                        library.flash(msg)
                        publishing = false
                    }
                }
                .disabled(publishing || library.settings.uploadURL.isEmpty)
            }
        } header: {
            Text("Online Listing")
        } footer: {
            Text("Optional. Only the episode listing goes online (sent with an HTTP PUT to your own server); feeds marked local only are skipped.")
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
