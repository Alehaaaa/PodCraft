import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings, in four short pages. The everyday choices are up front; ports, link addresses and uploads sit
/// under Advanced.
struct SettingsView: View {
    enum Page: String, CaseIterable, Identifiable {
        case general = "General", processing = "Processing", devices = "iPhone & Sync", sharing = "Podcast Feeds"
        var id: String { rawValue }
    }

    @Environment(Library.self) private var library
    @State private var page: Page = .general

    var body: some View {
        VStack(spacing: 0) {
            Picker("Settings", selection: $page) {
                ForEach(Page.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.top, 14)
            .padding(.bottom, 2)

            Form {
                switch page {
                case .general: GeneralSettings()
                case .processing: ProcessingSettings()
                case .devices:
                    SyncSettingsSection()
                    PhonePairingSection()
                case .sharing: FeedSharingSettings()
                }
            }
            .formStyle(.grouped)
        }
        .navigationTitle("Settings")
        .onChange(of: library.settings) { library.save() }
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    @State private var confirmReset = false

    var body: some View {
        @Bindable var lib = library
        Section("Playback") {
            LabeledContent("Default speed") {
                HStack {
                    Slider(value: Binding(get: { library.settings.defaultSpeed },
                                          set: { lib.settings.defaultSpeed = (($0 / 0.05).rounded() * 0.05); player.setRate(lib.settings.defaultSpeed) }),
                           in: Mechanics.minSpeed...Mechanics.maxSpeed)
                        .frame(maxWidth: 220)
                    Text(Fmt.speed(library.settings.defaultSpeed)).monospacedDigit().frame(width: 44, alignment: .trailing)
                }
            }
        }

        Section {
            Stepper("Download the newest \(library.settings.defaultAvailable) of each new show",
                    value: $lib.settings.defaultAvailable, in: 0...50)
            KeepRulePicker(rule: Binding(get: { library.settings.keepRule },
                                         set: { lib.settings.keepRule = $0; library.applyKeepRules() }))
        } header: {
            Text("Downloads")
        } footer: {
            Text("Every episode is listed; download any other by hand. Each show can change this on its own page.")
        }

        Section {
            HStack {
                Button("Back Up…") { backup() }
                Button("Restore…") { restore() }
                Divider().frame(height: 16)
                OPMLButtons()
            }
            Button("Delete Library Data and Media…", role: .destructive) { confirmReset = true }
        } header: {
            Text("Library")
        } footer: {
            Text("A backup holds your feeds, shows, settings, lifetime numbers and which episodes are downloaded.")
        }
        .confirmationDialog("Delete library data and media?", isPresented: $confirmReset) {
            Button("Delete and Start Over", role: .destructive) { player.stop(); library.resetLibrary() }
        } message: { Text("All shows, feeds and downloaded episodes are removed. Settings stay.") }

        Section("Lifetime") {
            LabeledContent("Listened", value: Fmt.hours(library.metrics.listenedSeconds))
            LabeledContent("Saved by listening faster", value: Fmt.hours(library.metrics.speedSavedSeconds))
            LabeledContent("Sponsor time removed", value: Fmt.hours(library.metrics.adSecondsRemoved))
            LabeledContent("Episodes finished", value: "\(library.metrics.episodesFinished)")
        }
    }

    private func backup() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "PodCraft Library.json"
        panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url {
            do { try library.exportBackup(to: url); library.flash("Library backed up") }
            catch { library.flash("Back up failed: \(error.localizedDescription)") }
        }
    }

    private func restore() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.message = "Choose a library backup to restore."
        if panel.runModal() == .OK, let url = panel.url {
            do { player.stop(); try library.restoreBackup(from: url); library.flash("Library restored") }
            catch { library.flash("Restore failed: \(error.localizedDescription)") }
        }
    }
}

// MARK: - Processing

private struct ProcessingSettings: View {
    @Environment(Library.self) private var library
    @State private var geminiKey = Keychain.read("gemini") ?? ""

    var body: some View {
        @Bindable var lib = library
        Section {
            Toggle("Cut out sponsors", isOn: $lib.settings.removeSponsors)
            Toggle("Make transcripts", isOn: $lib.settings.transcribe)
            Toggle("Make chapters", isOn: Binding(
                get: { library.settings.generateChapters },
                set: { enabled in
                    lib.settings.generateChapters = enabled
                    library.save()
                    if enabled { library.generateMissingChapters() }
                }))
        } header: {
            Text("Downloaded Episodes")
        } footer: {
            Text("Transcripts are made on this Mac with Apple’s speech recognition. An AI reads them to split chapters and find sponsor reads.")
        }

        Section("AI") {
            Picker("Use", selection: $lib.settings.aiProvider) {
                ForEach(AIProvider.allCases) { Text($0.title).tag($0) }
            }
            switch library.settings.aiProvider {
            case .onDevice:
                LabeledContent("Apple Intelligence", value: Snapshot.active ? "Ready on this Mac" : AIService.onDeviceStatus)
            case .gemini:
                SecureField("Gemini API key", text: $geminiKey)
                    .onChange(of: geminiKey) { Keychain.save(geminiKey, for: "gemini") }
                TextField("Model", text: $lib.settings.geminiModel)
                Link("Get a key from Google AI Studio", destination: URL(string: "https://aistudio.google.com/apikey")!)
                    .font(.caption)
            case .off:
                Text("Episodes keep the chapters their show publishes.").font(.caption).foregroundStyle(.secondary)
            }
        }

        Section {
            Toggle("Use SponsorBlock for YouTube episodes", isOn: $lib.settings.useSponsorBlock)
            DisclosureGroup("Segments to cut") {
                ForEach(SponsorBlock.allCategories, id: \.id) { cat in
                    Toggle(cat.title, isOn: Binding(
                        get: { library.settings.sponsorCategories.contains(cat.id) },
                        set: { on in
                            if on { lib.settings.sponsorCategories.append(cat.id) }
                            else { lib.settings.sponsorCategories.removeAll { $0 == cat.id } }
                        }))
                }
            }
            .disabled(!library.settings.useSponsorBlock)
        } header: {
            Text("SponsorBlock")
        } footer: {
            Text("Community-marked segments from sponsor.ajay.app, cut along with what the AI finds.")
        }
    }
}

// MARK: - Sync

/// Settings → iPhone & Sync: the same free, encrypted sync the iPhone app has.
struct SyncSettingsSection: View {
    @State private var joinCode = ""
    @State private var confirmLeave = false
    @State private var badCode = false

    var body: some View {
        @Bindable var sync = MacSync.shared
        Section {
            if sync.isOn {
                HStack(alignment: .center, spacing: 18) {
                    if let link = sync.joinLink, let qr = PhoneAPI.qrImage(link) {
                        Image(nsImage: qr).interpolation(.none).resizable()
                            .frame(width: 110, height: 110).padding(6)
                            .background(.white, in: RoundedRectangle(cornerRadius: 10))
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text(sync.displayCode).font(.title3.monospaced().weight(.semibold)).textSelection(.enabled)
                        Text("Scan with an iPhone’s camera, or enter the code in PodCraft → Settings → Sync on your other devices.")
                            .font(.callout).foregroundStyle(.secondary)
                        HStack {
                            Button("Copy Code") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(sync.displayCode, forType: .string)
                            }
                            Button(sync.syncing ? "Syncing…" : "Sync Now") { Task { await sync.syncNow() } }
                                .disabled(sync.syncing)
                        }
                        .controlSize(.small)
                    }
                }
                .padding(.vertical, 4)

                ForEach(sync.peers) { peer in
                    HStack {
                        Image(systemName: peer.platform == "mac" ? "laptopcomputer" : "iphone")
                            .foregroundStyle(Color.podTeal).frame(width: 22)
                        Text(peer.name + (peer.isThisDevice ? " (this Mac)" : ""))
                        Spacer()
                        Text(peer.savedAt, format: .relative(presentation: .named)).foregroundStyle(.secondary)
                        if !peer.isThisDevice {
                            Button { Task { await sync.remove(peer) } } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless).help("Remove this device")
                        }
                    }
                }

                Toggle("Add shows followed on other devices", isOn: $sync.addNewShows)
                TextField("This Mac’s name", text: $sync.deviceName)
                Button("Stop Syncing This Mac", role: .destructive) { confirmLeave = true }
            } else {
                HStack {
                    Button("Start Syncing") { sync.start() }.buttonStyle(.borderedProminent)
                    Text("or").foregroundStyle(.secondary)
                    TextField("Enter a sync code", text: $joinCode).frame(maxWidth: 220)
                    Button("Join") { badCode = !sync.join(joinCode) }.disabled(joinCode.isEmpty)
                }
            }
        } header: {
            Text("Sync")
        } footer: {
            if let error = sync.error {
                Text(error).foregroundStyle(.orange)
            } else if sync.isOn {
                Text((sync.lastSynced.map { "Last synced \($0.formatted(.relative(presentation: .named))). " } ?? "")
                     + "Shows you follow, where you are in each episode and your speed stay the same on every device — at home or away, no Tailscale needed. Shows unfollowed elsewhere stay on this Mac.")
            } else {
                Text("Keeps the shows you follow, where you are in every episode and your speed the same on this Mac and your iPhones — anywhere, no Tailscale needed. Free, no account, end-to-end encrypted.")
            }
        }
        .confirmationDialog("Stop syncing this Mac?", isPresented: $confirmLeave) {
            Button("Stop Syncing", role: .destructive) { Task { await sync.leave() } }
        } message: { Text("Your library stays as it is. Your other devices keep syncing.") }
        .alert("That isn’t a sync code", isPresented: $badCode) { Button("OK", role: .cancel) {} } message: {
            Text("Sync codes are 16 letters and numbers, like ABCD-EFGH-JKLM-NPQR.")
        }
    }
}

// MARK: - Podcast feeds

/// Settings → Podcast Feeds: this Mac serves cleaned episodes as podcast feeds any app can subscribe to.
private struct FeedSharingSettings: View {
    @Environment(Library.self) private var library
    @State private var uploadToken = Keychain.read("upload") ?? ""
    @State private var publishing = false

    var body: some View {
        @Bindable var lib = library
        let address = library.server?.baseURL(port: library.settings.hostPort) ?? ""
        Section {
            Toggle("Serve feeds from this Mac", isOn: $lib.settings.hostingEnabled)
            LabeledContent("Address") {
                HStack {
                    Text(address).textSelection(.enabled).foregroundStyle(.secondary)
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(address, forType: .string)
                    }
                    .controlSize(.small)
                }
            }
            .disabled(!library.settings.hostingEnabled)
            LabeledContent("Status", value: library.hostingStatus)
        } header: {
            Text("Podcast Feeds")
        } footer: {
            Text("Each feed and show has a link to subscribe in Apple Podcasts and other apps. The Mac has to be awake, since the audio streams from it. The iPhone app uses this too.")
        }

        Section {
            DisclosureGroup("Advanced") {
                Picker("Links use", selection: $lib.settings.linkAddress) {
                    ForEach(LinkAddress.allCases) { Text($0.title).tag($0) }
                }
                LabeledContent("Local network", value: library.server?.localNetworkURL(port: library.settings.hostPort) ?? "")
                LabeledContent("Tailscale", value: library.server?.tailscaleURL(port: library.settings.hostPort) ?? "Not connected")
                TextField("Port", value: $lib.settings.hostPort, format: .number.grouping(.never))
                Toggle("New feeds stay local only", isOn: $lib.settings.localOnlyByDefault)
                Text("With Tailscale on this Mac and your other devices, links work away from home. Apps that fetch feeds from their own servers (Overcast, Pocket Casts) can’t reach your network; give them an online listing below.")
                    .font(.caption).foregroundStyle(.secondary)

                TextField("Online listing address", text: $lib.settings.uploadURL, prompt: Text("https://example.com/feeds/"))
                SecureField("Upload token (optional)", text: $uploadToken)
                    .onChange(of: uploadToken) { Keychain.save(uploadToken, for: "upload") }
                Button(publishing ? "Uploading…" : "Upload Listings Now") {
                    publishing = true
                    Task { @MainActor in
                        library.flash(await library.server?.publishAll() ?? "")
                        publishing = false
                    }
                }
                .disabled(publishing || library.settings.uploadURL.isEmpty)
                Text("Only the episode listings go online, sent with an HTTP PUT to your own server. Feeds marked local only are skipped.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
