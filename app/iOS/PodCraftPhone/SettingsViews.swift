import CoreImage.CIFilterBuiltins
import SwiftUI

// MARK: - Welcome

/// First launch: use PodCraft on its own, connect it to PodCraft on a Mac, or join another device's sync.
struct WelcomeView: View {
    @Environment(Store.self) private var store
    @State private var joining = false
    @State private var syncCode = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 14) {
                        Image("Logo")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 96, height: 96)
                            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        Text("PodCraft").font(.largeTitle.bold())
                        Text("A free podcast player. Follow shows on this iPhone, or listen to the shows PodCraft on your Mac cleans of sponsors.")
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                }
                .listRowBackground(Color.clear)

                Section {
                    Button { store.startStandalone() } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Use on This iPhone").font(.headline)
                                Text("Search and follow any podcast. No Mac needed.").font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: { Image(systemName: "iphone") }
                    }
                    NavigationLink {
                        MacConnectForm()
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Connect to Your Mac").font(.headline)
                                Text("Cleaned episodes, chapters and transcripts from PodCraft on the Mac.").font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: { Image(systemName: "desktopcomputer") }
                    }
                } header: {
                    Text("How Do You Want to Listen?")
                }

                Section {
                    if joining {
                        TextField("Sync code, like ABCD-EFGH-JKLM-NPQR", text: $syncCode)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                        Button("Join") {
                            store.startStandalone()
                            store.sync.join(syncCode)
                        }
                        .disabled(SyncBox.normalized(syncCode) == nil)
                    } else {
                        Button("I Have a Sync Code", systemImage: "arrow.triangle.2.circlepath.icloud") { joining = true }
                    }
                } footer: {
                    Text("Sync brings your shows, progress and settings from your other devices. It’s free and needs no account.")
                }
            }
        }
    }
}

/// The address and code from PodCraft's Settings on the Mac, or scan its QR code with the Camera.
struct MacConnectForm: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var server = ""
    @State private var code = ""

    var body: some View {
        Form {
            Section {
                Label("On your Mac, open PodCraft → Settings → iPhone.", systemImage: "desktopcomputer")
                Label("Scan the code with the Camera app.", systemImage: "qrcode.viewfinder")
            } header: {
                Text("Connect to Your Mac")
            } footer: {
                Text("On the same network it just works. Away from home, use Tailscale on both — or use this iPhone on its own with Sync instead.")
            }

            Section("Or Enter It Here") {
                TextField("Address, like my-mac.local:8743", text: $server)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                TextField("Code", text: $code)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Connect") {
                    store.connect(server: server, code: code)
                    dismiss()
                }
                .disabled(server.isEmpty || code.isEmpty)
            }
        }
        .navigationTitle("Your Mac")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Adding shows

struct AddShowView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var query = ""
    @State private var results: [DirectoryResult] = []
    @State private var top: [DirectoryResult] = []
    @State private var searching = false
    @State private var adding: Set<String> = []
    @State private var failure: String?

    private var pastedURL: URL? {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.contains("."), !q.contains(" ") else { return nil }
        return FeedReader.normalize(q)
    }

    var body: some View {
        NavigationStack {
            List {
                if let url = pastedURL {
                    Section("Feed Address") {
                        addRow(title: url.host ?? url.absoluteString, subtitle: url.absoluteString, artwork: nil, feed: url)
                    }
                }
                let list = query.trimmingCharacters(in: .whitespaces).isEmpty ? top : results
                if !list.isEmpty {
                    Section(query.isEmpty ? "Top Shows" : "Shows") {
                        ForEach(list) { r in
                            if let feed = r.feedUrl.flatMap(URL.init(string:)) {
                                addRow(title: r.collectionName, subtitle: r.artistName ?? "",
                                       artwork: r.artworkUrl600.flatMap(URL.init(string:)), feed: feed)
                            }
                        }
                    }
                } else if searching {
                    ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear)
                } else if !query.isEmpty && pastedURL == nil {
                    ContentUnavailableView.search(text: query).listRowBackground(Color.clear)
                }
            }
            .navigationTitle("Add a Show")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search, or paste a feed address")
            .task(id: query) {
                let q = query.trimmingCharacters(in: .whitespaces)
                guard !q.isEmpty, pastedURL == nil else { results = []; return }
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                searching = true
                results = await Directory.search(q)
                searching = false
            }
            .task { if top.isEmpty { top = await Directory.top() } }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .alert("Can’t Add This Show", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(failure ?? "") }
        }
    }

    private func addRow(title: String, subtitle: String, artwork: URL?, feed: URL) -> some View {
        let id = Subscription.id(for: feed)
        let followed = store.isSubscribed(feed)
        return HStack(spacing: 12) {
            Artwork(url: artwork, size: 52, radius: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline).lineLimit(2)
                if !subtitle.isEmpty { Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer()
            if adding.contains(id) {
                ProgressView()
            } else if followed {
                Button { store.unsubscribe(showID: id) } label: { Image(systemName: "checkmark.circle.fill").font(.title2) }
                    .buttonStyle(.plain).foregroundStyle(Color.podTeal)
                    .accessibilityLabel("Following. Tap to unfollow.")
            } else {
                Button {
                    adding.insert(id)
                    Task {
                        do { try await store.subscribe(to: feed) } catch { failure = error.localizedDescription }
                        adding.remove(id)
                    }
                } label: { Image(systemName: "plus.circle").font(.title2) }
                    .buttonStyle(.plain).foregroundStyle(Color.podTeal)
                    .accessibilityLabel("Follow")
            }
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @Environment(Store.self) private var store
    @Environment(Updater.self) private var updater
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDisconnect = false
    @State private var result: Updater.Result?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Library", selection: Binding(
                        get: { store.isStandalone ? Store.Mode.standalone : Store.Mode.companion },
                        set: { $0 == .standalone ? store.startStandalone() : store.switchToCompanion() })) {
                        Text("This iPhone").tag(Store.Mode.standalone)
                        Text("My Mac").tag(Store.Mode.companion)
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Listen From")
                } footer: {
                    Text(store.isStandalone
                         ? "Shows you follow here, read straight from their feeds."
                         : "The library PodCraft serves from \(store.macName), cleaned of sponsors.")
                }

                if store.isStandalone {
                    Section("Shows You Follow") {
                        NavigationLink { FollowingView() } label: {
                            LabeledContent("Following", value: "\(store.activeSubscriptions.count)")
                        }
                    }
                }

                Section {
                    if store.isConnected {
                        LabeledContent(store.macName, value: store.server)
                        Button("Disconnect", role: .destructive) { confirmDisconnect = true }
                    } else {
                        NavigationLink("Connect to Your Mac") { MacConnectForm() }
                    }
                } header: { Text("Mac") }

                Section {
                    NavigationLink { SyncView() } label: {
                        LabeledContent("Sync", value: store.sync.isOn ? "\(store.sync.peers.count) device\(store.sync.peers.count == 1 ? "" : "s")" : "Off")
                    }
                } footer: {
                    if let error = store.sync.error { Text(error).foregroundStyle(.orange) }
                }

                Section {
                    Picker("Speed", selection: Binding(get: { store.rate }, set: { store.setRate($0) })) {
                        ForEach([0.8, 1.0, 1.1, 1.2, 1.3, 1.5, 1.75, 2.0] as [Float], id: \.self) { r in
                            Text(r == 1 ? "1×" : String(format: "%g×", r)).tag(r)
                        }
                    }
                    Toggle("Skip Sponsors", isOn: Binding(get: { store.skipSponsors }, set: { store.skipSponsors = $0 }))
                } header: {
                    Text("Playback")
                } footer: {
                    Text("With Sync on, episodes PodCraft on your Mac has processed come with their transcript and chapters, and their sponsor reads are skipped — even when this iPhone streams them straight from the show.")
                }

                Section {
                    Button("Check for Updates") { Task { result = await updater.check(server: updateServer) } }
                } header: {
                    Text("PodCraft \(Updater.currentVersion) (\(Updater.currentBuild))")
                } footer: {
                    Text("PodCraft is free. Updates come from \(store.isStandalone || !store.isConnected ? "GitHub" : store.macName).")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Disconnect from \(store.macName)?", isPresented: $confirmDisconnect) {
                Button("Disconnect", role: .destructive) { store.disconnect() }
            }
            .alert(alertTitle, isPresented: Binding(get: { result != nil }, set: { if !$0 { result = nil } })) {
                if case .available(let release)? = result {
                    Button("Install with LiveContainer") { updater.install(release, server: updateServer) }
                    Button("Later", role: .cancel) {}
                } else {
                    Button("OK", role: .cancel) {}
                }
            } message: { Text(alertMessage) }
        }
    }

    private var updateServer: String { store.isStandalone ? "" : store.server }

    private var alertTitle: String {
        switch result {
        case .available(let r)?: "PodCraft \(r.version) Is Available"
        case .upToDate?: "PodCraft Is Up to Date"
        case .noRelease?: "No Updates Hosted"
        default: "Can’t Check for Updates"
        }
    }

    private var alertMessage: String {
        switch result {
        case .available(let r)?: "Build \(r.build) is ready. LiveContainer installs it over this one; your shows and progress stay."
        case .upToDate?: "You have the newest build (\(Updater.currentBuild))."
        case .noRelease?: "No iPhone build is published yet."
        default: "The update source didn’t answer. Try again when you’re online."
        }
    }
}

struct FollowingView: View {
    @Environment(Store.self) private var store
    @State private var adding = false

    var body: some View {
        List {
            ForEach(store.activeSubscriptions) { sub in
                HStack(spacing: 12) {
                    Artwork(url: sub.artwork, size: 44, radius: 8)
                    VStack(alignment: .leading) {
                        Text(sub.title).font(.headline).lineLimit(1)
                        Text(sub.url.host ?? "").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .swipeActions { Button("Unfollow", role: .destructive) { store.unsubscribe(showID: sub.id) } }
            }
        }
        .overlay {
            if store.activeSubscriptions.isEmpty {
                ContentUnavailableView("Not Following Any Shows", systemImage: "plus.circle",
                                       description: Text("Shows you follow, here or on your other devices, appear here."))
            }
        }
        .navigationTitle("Following")
        .toolbar { Button("Add", systemImage: "plus") { adding = true } }
        .sheet(isPresented: $adding) { AddShowView() }
    }
}

// MARK: - Sync

struct SyncView: View {
    @Environment(Store.self) private var store
    @State private var joinCode = ""
    @State private var confirmLeave = false
    @State private var badCode = false

    var body: some View {
        @Bindable var sync = store.sync
        Form {
            if sync.isOn {
                Section {
                    VStack(spacing: 12) {
                        if let link = sync.joinLink, let qr = QRCode.image(for: link.absoluteString) {
                            Image(uiImage: qr).interpolation(.none).resizable().scaledToFit().frame(width: 180, height: 180)
                        }
                        Text(sync.displayCode).font(.title3.monospaced().weight(.semibold)).textSelection(.enabled)
                        if let link = sync.joinLink {
                            ShareLink(item: link, message: Text("Join my PodCraft sync: \(sync.displayCode)")) {
                                Label("Share Code", systemImage: "square.and.arrow.up")
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                } header: {
                    Text("Sync Code")
                } footer: {
                    Text("On another iPhone or iPad, scan this with the Camera or enter the code in PodCraft → Settings → Sync. Anyone with the code can see what you listen to, so share it only with your own devices.")
                }

                Section("Devices") {
                    ForEach(sync.peers) { peer in
                        HStack {
                            Image(systemName: peer.platform == "mac" ? "desktopcomputer" : "iphone")
                                .foregroundStyle(Color.podTeal).frame(width: 26)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(peer.name + (peer.isThisDevice ? " (This Device)" : "")).font(.headline)
                                Text("\(peer.platform == "mac" ? "Mac" : peer.mode == "companion" ? "With Mac" : "On its own") · \(peer.savedAt.formatted(.relative(presentation: .named)))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions {
                            if !peer.isThisDevice {
                                Button("Remove", role: .destructive) { Task { await sync.remove(peer) } }
                            }
                        }
                    }
                }

                Section {
                    TextField("This Device’s Name", text: $sync.deviceName)
                    Toggle("Shows You Follow", isOn: $sync.syncSubscriptions)
                    Toggle("Listening Progress", isOn: $sync.syncProgress)
                    Toggle("Playback Settings", isOn: $sync.syncSettings)
                } header: {
                    Text("What This Device Syncs")
                }

                Section {
                    Button {
                        Task { await sync.syncNow() }
                    } label: {
                        HStack {
                            Text("Sync Now")
                            Spacer()
                            if sync.syncing { ProgressView() }
                            else if let t = sync.lastSynced { Text(t.formatted(.relative(presentation: .named))).foregroundStyle(.secondary) }
                        }
                    }
                    .disabled(sync.syncing)
                    Button("Stop Syncing This Device", role: .destructive) { confirmLeave = true }
                } footer: {
                    if let error = sync.error { Text(error) }
                }
            } else {
                Section {
                    Button("Start Syncing", systemImage: "arrow.triangle.2.circlepath.icloud") { sync.start() }
                } footer: {
                    Text("Keeps the shows you follow, where you are in every episode and your playback settings the same on all your devices — at home or away, with or without your Mac. Free, no account, end-to-end encrypted.")
                }
                Section("Join Your Other Devices") {
                    TextField("Sync code", text: $joinCode)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    Button("Join") { badCode = !sync.join(joinCode) }
                        .disabled(joinCode.isEmpty)
                }
            }
        }
        .navigationTitle("Sync")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await sync.syncNow() }
        .confirmationDialog("Stop syncing this device?", isPresented: $confirmLeave) {
            Button("Stop Syncing", role: .destructive) { Task { await sync.leave() } }
        } message: {
            Text("Your shows and progress stay on this device. Your other devices keep syncing.")
        }
        .alert("That Isn’t a Sync Code", isPresented: $badCode) { Button("OK", role: .cancel) {} } message: {
            Text("Sync codes are 16 letters and numbers, like ABCD-EFGH-JKLM-NPQR.")
        }
    }
}

enum QRCode {
    static func image(for text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
