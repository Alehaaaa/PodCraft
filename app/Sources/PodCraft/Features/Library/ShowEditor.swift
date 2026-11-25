import SwiftUI
import UniformTypeIdentifiers

/// "Edit Show…": the show's details and the original's customisation
/// (your own cover, a coloured frame, title and chapter filters, how many to keep downloaded).
struct ShowEditor: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let original: Show
    @State private var draft: Show
    @State private var youtubeChannelText: String
    @State private var checkingYouTube = false
    @State private var youtubeStatus: String?
    @State private var youtubeError: String?
    /// Preserve a successful Find/Verify status when the Find action fills the
    /// text field; any subsequent manual edit invalidates that result.
    @State private var youtubeStatusChannelText: String?
    @State private var youtubeCheckTask: Task<Void, Never>?

    init(original: Show) {
        self.original = original
        _draft = State(initialValue: original)
        _youtubeChannelText = State(initialValue: original.youtubeChannelURL ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit Show").font(.title2.bold())
            Form {
                Section("Details") {
                    TextField("Title", text: $draft.title)
                    TextField("Author", text: $draft.author)
                    TextField("Description", text: $draft.summary, axis: .vertical).lineLimit(3...6)
                    if let link = draft.feedURL {
                        LabeledContent("Feed link") {
                            Text(link).font(.caption.monospaced()).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
                Section {
                    Text("Leave the channel link blank for automatic discovery. Find Official Channel Automatically compares recent RSS episode titles and durations; Verify Channel checks that a pasted channel URL resolves to uploads. Changes apply only when you click Save.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if YouTubeSource.available {
                        Label("YouTube channel lookup is available.", systemImage: "checkmark.circle")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Label("YouTube lookup unavailable: install yt-dlp (for example, brew install yt-dlp) to find and verify channels. You can still save a channel URL for later.",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Button {
                        youtubeCheckTask?.cancel()
                        youtubeCheckTask = Task { await findYouTubeChannel() }
                    } label: {
                        Label("Find Official Channel Automatically", systemImage: "sparkle.magnifyingglass")
                    }
                    .disabled(checkingYouTube || !YouTubeSource.available || draft.feedURL == nil)
                    TextField("Official YouTube channel URL", text: $youtubeChannelText,
                              prompt: Text("https://www.youtube.com/@Channel"))
                        .textContentType(.URL)
                        .disabled(checkingYouTube)
                        .onChange(of: youtubeChannelText) { _, updated in
                            if updated != youtubeStatusChannelText {
                                youtubeStatus = nil
                                youtubeError = nil
                                youtubeStatusChannelText = nil
                            }
                        }
                    if !youtubeChannelText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                        YouTubeSource.channelURL(from: youtubeChannelText) == nil {
                        Label("Use an HTTPS YouTube channel URL (youtube.com/@handle or youtube.com/channel/UC…). Video and playlist links are not accepted.",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    HStack(spacing: 12) {
                        Button {
                            youtubeCheckTask?.cancel()
                            youtubeCheckTask = Task { await validateYouTubeChannel() }
                        } label: {
                            if checkingYouTube {
                                Label("Checking Channel…", systemImage: "ellipsis")
                            } else {
                                Label("Verify Channel", systemImage: "checkmark.shield")
                            }
                        }
                        .disabled(checkingYouTube || !YouTubeSource.available
                                  || YouTubeSource.channelURL(from: youtubeChannelText) == nil)
                        if checkingYouTube { ProgressView().controlSize(.small) }
                        if let url = YouTubeSource.channelURL(from: youtubeChannelText) {
                            Link("Open Channel", destination: url)
                                .font(.callout)
                        }
                    }
                    if let status = youtubeStatus {
                        Label(status, systemImage: "checkmark.circle.fill")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let error = youtubeError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Toggle("Download YouTube video (MP4) when available", isOn: $draft.youtubePlaybackVideo)
                    Text("Turn off for audio-only M4A. PodCraft uses YouTube media only after an episode matches the verified channel; otherwise it keeps the RSS source.")
                        .font(.caption).foregroundStyle(.secondary)
                } header: {
                    Text("YouTube (optional)")
                } footer: {
                    Text("A valid URL format alone does not prove that a channel is official. Find compares RSS episodes; Verify confirms the channel is reachable. Save to use the chosen link. If no safe episode match is found, the original RSS audio is used.")
                }
                Section("Artwork") {
                    HStack(alignment: .top, spacing: 16) {
                        preview
                        VStack(alignment: .leading, spacing: 8) {
                            Button("Choose Artwork…") { chooseArtwork() }
                            if draft.customArtwork != nil {
                                Button("Use the Show’s Own Artwork") { draft.customArtwork = nil }
                            }
                            Toggle("Coloured frame", isOn: $draft.showsBorder)
                            if draft.showsBorder {
                                HStack {
                                    Text("Colour")
                                    Slider(value: $draft.borderHue, in: 0...1)
                                    Circle().fill(Color(hue: draft.borderHue, saturation: 0.8, brightness: 0.85))
                                        .frame(width: 16, height: 16)
                                }
                                Stepper("Width \(Int(draft.borderWidth))", value: $draft.borderWidth, in: 2...16)
                            }
                            Text("A coloured frame tells your cleaned-up copy apart from the original show in your podcast app.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    TextField("Skip episodes whose titles contain", text: $draft.excludedTitleTerms,
                              prompt: Text("for example: trailer, rerun, bonus"))
                    TextField("Cut chapters whose titles contain", text: $draft.excludedChapterTerms,
                              prompt: Text("for example: ad break, promo, housekeeping"))
                } header: {
                    Text("Filters")
                } footer: {
                    Text("Separate words with commas. Skipped episodes are hidden and never downloaded; matching chapters are cut out of episodes when they’re processed.")
                }
                if !draft.isFiles {
                    Section("Downloads") {
                        Stepper(draft.keepAvailable == 0 ? "Don’t download new episodes automatically"
                                : "Keep the newest \(draft.keepAvailable) on this Mac",
                                value: $draft.keepAvailable, in: 0...50)
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    if draft.title.trimmingCharacters(in: .whitespaces).isEmpty { draft.title = original.title }
                    let requested = youtubeChannelText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !requested.isEmpty {
                        guard let channel = YouTubeSource.channelURL(from: requested) else {
                            youtubeError = "Enter a valid HTTPS YouTube channel URL, not a video or playlist, or clear it to use automatic discovery."
                            return
                        }
                        draft.youtubeChannelURL = channel.absoluteString
                    } else {
                        draft.youtubeChannelURL = nil
                    }
                    library.updateShow(draft)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
                .disabled(checkingYouTube)
            }
        }
        .padding(22)
        .frame(width: 600, height: 700)
        .onDisappear { youtubeCheckTask?.cancel() }
    }

    var preview: some View {
        let size: CGFloat = 120
        let hue: Double? = draft.showsBorder ? draft.borderHue : nil
        return Group {
            if let p = draft.customArtwork, let img = ArtworkStore.localImage(p) {
                CoverImage(image: img, size: size, borderHue: hue, borderWidth: draft.borderWidth)
            } else if let img = ArtworkStore.image(for: draft.artworkURL) {
                CoverImage(image: img, size: size, borderHue: hue, borderWidth: draft.borderWidth)
            } else {
                ArtworkView(title: draft.title, hue: draft.hue, size: size, borderHue: hue, borderWidth: draft.borderWidth)
            }
        }
    }

    func chooseArtwork() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = "Choose artwork for \(draft.title)"
        if panel.runModal() == .OK, let url = panel.url, let path = ArtworkStore.importCustom(from: url, showID: draft.id) {
            draft.customArtwork = path
        }
    }

    @MainActor
    private func validateYouTubeChannel() async {
        let requested = youtubeChannelText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let canonical = YouTubeSource.channelURL(from: requested) else {
            youtubeError = "Enter an HTTPS YouTube channel URL (youtube.com/@handle or youtube.com/channel/UC…)."
            return
        }
        checkingYouTube = true
        youtubeError = nil
        youtubeStatus = nil
        defer { checkingYouTube = false }
        do {
            let index = try await YouTubeSource.channelIndex(from: canonical.absoluteString)
            guard !Task.isCancelled, requested == youtubeChannelText.trimmingCharacters(in: .whitespacesAndNewlines)
            else { return }
            youtubeStatusChannelText = youtubeChannelText
            youtubeStatus = "Channel reachable: \(index.channelTitle) (\(index.videos.count) uploads). Episode identity is checked before YouTube playback. Click Save to use this URL."
        } catch {
            guard !Task.isCancelled else { return }
            youtubeError = error.localizedDescription
        }
    }

    @MainActor
    private func findYouTubeChannel() async {
        var target = draft
        // Find, don't simply validate a preexisting manual link.
        target.youtubeChannelURL = nil
        let initialText = youtubeChannelText
        checkingYouTube = true
        youtubeError = nil
        youtubeStatus = nil
        defer { checkingYouTube = false }
        do {
            let result = try await YouTubeSource.discoverChannel(show: target)
            guard !Task.isCancelled else { return }
            if let result {
                // Keep the discovered result in the editable text field only.
                // `draft.youtubeChannelURL` and Library are unchanged until Save.
                guard youtubeChannelText == initialText else { return }
                youtubeStatusChannelText = result.channelURL.absoluteString
                youtubeChannelText = result.channelURL.absoluteString
                youtubeStatus = "Found \(result.channelTitle), matched against recent RSS episodes. Click Save to use this channel."
            } else {
                youtubeError = "No unique official channel could be verified against recent RSS episodes. You can paste a channel URL and Verify Channel, or leave this blank to keep RSS audio."
            }
        } catch {
            guard !Task.isCancelled else { return }
            youtubeError = error.localizedDescription
        }
    }
}
