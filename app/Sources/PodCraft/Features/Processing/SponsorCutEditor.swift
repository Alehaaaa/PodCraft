import AVKit
import SwiftUI

/// Precise, non-destructive editing of sponsor skip metadata. Times are ALWAYS measured
/// against the original source file; no audio/video export or modification occurs here.
struct SponsorCutEditor: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss

    let episodeID: UUID
    let sourceURL: URL?
    let fallbackDuration: Double
    @Binding var cuts: [CutSegment]

    @State private var waveform: SponsorWaveformData?
    @State private var waveformError: String?
    @State private var loadingWaveform = false
    @State private var selectedCutID: UUID?
    @State private var cursorTime = 0.0
    @State private var zoomExponent = 0.0
    @State private var scrollFraction = 0.0
    @State private var previewPlayer: AVPlayer?
    @State private var previewIsPlaying = false
    @State private var previewEndTime: Double?
    @State private var previewMonitor: Task<Void, Never>?
    @State private var audioMessage: String?
    @State private var showingVideoPreview = false
    @State private var transcriptFollowsCut = true
    @State private var transcriptFocusRequest = 0

    private let cutCategories = ["sponsor", "selfpromo", "interaction", "intro", "outro", "preview", "filler", "chapter filter", "other"]
    private let cutSources = ["Manual", "AI", "SponsorBlock", "Filter"]

    private var sourceDuration: Double {
        let longestCut = cuts.map(\.end).filter(\.isFinite).max() ?? 0
        return max(1, waveform?.duration ?? max(fallbackDuration, longestCut))
    }
    private var zoom: Double { pow(2, zoomExponent) }
    private var visibleLength: Double { sourceDuration / zoom }
    private var visibleStart: Double { scrollFraction * max(0, sourceDuration - visibleLength) }
    private var selectedIndex: Int? { cuts.firstIndex { $0.id == selectedCutID } }
    private var selectedCut: CutSegment? { selectedIndex.map { cuts[$0] } }
    /// The processor appends recognized lines to the observable episode. Keep this
    /// transcript live even if the parent metadata editor was opened before transcription.
    private var transcriptLines: [TranscriptLine] { library.episode(episodeID)?.transcript ?? [] }
    private var workingEpisode: Episode? {
        guard let episode = library.episode(episodeID), episode.stage.isWorking else { return nil }
        return episode
    }
    private var localOriginal: URL? {
        guard let sourceURL, sourceURL.isFileURL,
              FileManager.default.isReadableFile(atPath: sourceURL.path) else { return nil }
        // Older PodCraft versions generated a physical cut file. It is *not* a reliable
        // source timeline and must never masquerade as the original in this editor.
        guard !sourceURL.deletingPathExtension().lastPathComponent.hasSuffix("-cut") else { return nil }
        return sourceURL
    }
    private var originalIsVideo: Bool {
        guard let ext = localOriginal?.pathExtension.lowercased() else { return false }
        return ["mp4", "mov", "m4v"].contains(ext)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Sponsor Cuts").font(.title3.weight(.semibold))
                Spacer()
                Text("\(cuts.count) \(cuts.count == 1 ? "segment" : "segments")")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Text("Adjust cut edges on the original recording. The audio is never changed.")
                .font(.callout).foregroundStyle(.secondary)

            waveformSection

            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Cut").font(.headline)
                        Picker("Cut", selection: Binding(get: { selectedCutID }, set: { id in
                            selectedCutID = id
                            if id != nil { focusSelection() }
                        })) {
                            Text("Select").tag(Optional<UUID>.none)
                            ForEach(cuts.sorted(by: { $0.start < $1.start })) { cut in
                                Text("\(cut.category.capitalized) · \(preciseTime(cut.start))")
                                    .tag(Optional(cut.id))
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity)
                        Button { addCut() } label: { Image(systemName: "plus") }
                            .buttonStyle(.glass)
                            .help("Add a cut at the playhead")
                    }
                if let selectedIndex {
                    selectedCutDetails(cut: $cuts[selectedIndex])
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "waveform.path")
                            .font(.title2).foregroundStyle(.tertiary)
                        Text("Select a cut to edit its times")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                }
                .frame(width: 270, alignment: .topLeading)

                transcriptPanel
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity, alignment: .top)

            HStack(spacing: 12) {
                Text("Changes are saved with the episode metadata.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { stopPreview(); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
            }
        }
        .padding(20)
        .frame(width: 750, height: 560)
        .task(id: sourceURL?.path) { await loadOriginalWaveform() }
        .onDisappear { stopPreview() }
        .popover(isPresented: $showingVideoPreview, arrowEdge: .bottom) {
            if let previewPlayer {
                VideoPlayer(player: previewPlayer)
                    .frame(width: 440, height: 250)
                    .padding(8)
            }
        }
        .onChange(of: showingVideoPreview) { _, showing in
            if !showing { pausePreview() }
        }
        .onChange(of: cuts.map(\.id)) { _, ids in
            if let selectedCutID, !ids.contains(selectedCutID) { self.selectedCutID = ids.first }
        }
        .onAppear { if selectedCutID == nil { selectedCutID = cuts.first?.id } }
    }

    private var waveformSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "waveform")
                    .foregroundStyle(Color.podTeal)
                Text(localOriginal == nil ? "Original audio unavailable" : "Original audio")
                    .font(.callout)
                    .lineLimit(1)
                    .help(localOriginal?.path ?? "Numeric editing is available without an original local file")
                Spacer(minLength: 4)
                if loadingWaveform { ProgressView().controlSize(.small) }
                Text(preciseTime(sourceDuration))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            SponsorCutTimeline(cuts: $cuts, selection: $selectedCutID, playhead: $cursorTime,
                               samples: waveform?.levels ?? [], duration: sourceDuration,
                               visibleStart: visibleStart, visibleLength: visibleLength)
                .frame(height: 110)

            HStack {
                ForEach(0..<3, id: \.self) { tick in
                    Text(preciseTime(visibleStart + Double(tick) * visibleLength / 2))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    if tick != 2 { Spacer() }
                }
            }
            HStack(spacing: 10) {
                Button {
                    if previewIsPlaying { pausePreview() }
                    else { preview(at: cursorTime) }
                } label: {
                    Label(previewIsPlaying ? "Pause" : "Preview", systemImage: previewIsPlaying ? "pause.fill" : "play.fill")
                }
                .buttonStyle(.glass)
                .disabled(localOriginal == nil)
                .help("Listen to the original recording, including sponsor sections")
                Text(preciseTime(cursorTime))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                if let audioMessage {
                    Text(audioMessage).font(.caption).foregroundStyle(.orange).lineLimit(1)
                } else if let waveformError {
                    Text(waveformError).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button { changeZoom(by: -1) } label: { Image(systemName: "minus.magnifyingglass") }
                    .disabled(zoomExponent <= 0)
                    .help("Zoom out")
                Text(String(format: "%.0f×", zoom))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(minWidth: 25)
                Button { changeZoom(by: 1) } label: { Image(systemName: "plus.magnifyingglass") }
                    .disabled(zoomExponent >= 6)
                    .help("Zoom in on the selected cut")
            }
            .buttonStyle(.borderless)
            if zoomExponent > 0 {
                Slider(value: $scrollFraction, in: 0...1)
                    .controlSize(.mini)
                    .accessibilityLabel("Timeline position")
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 12))
    }

    private func selectedCutDetails(cut: Binding<CutSegment>) -> some View {
        let item = cut.wrappedValue
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Selected Cut").font(.headline)
                Spacer()
                Button(role: .destructive) { cuts.removeAll { $0.id == item.id } } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove this cut")
            }
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Start").font(.caption).foregroundStyle(.secondary)
                    TextField("Start", value: secondsBinding(cut, edge: .start),
                              format: .number.precision(.fractionLength(2)))
                        .textFieldStyle(.roundedBorder).monospacedDigit()
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text("End").font(.caption).foregroundStyle(.secondary)
                    TextField("End", value: secondsBinding(cut, edge: .end),
                              format: .number.precision(.fractionLength(2)))
                        .textFieldStyle(.roundedBorder).monospacedDigit()
                }
            }
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Category").font(.caption).foregroundStyle(.secondary)
                    Picker("Category", selection: fieldBinding(cut, \.category)) {
                        ForEach(options(item.category, standard: cutCategories), id: \.self) { choice in
                            Text(choice.capitalized).tag(choice)
                        }
                    }
                    .labelsHidden()
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Source").font(.caption).foregroundStyle(.secondary)
                    Picker("Source", selection: Binding(get: { cut.wrappedValue.source },
                                                        set: { cut.wrappedValue.source = $0 })) {
                        ForEach(options(item.source, standard: cutSources), id: \.self) { choice in
                            Text(choice).tag(choice)
                        }
                    }
                    .labelsHidden()
                }
            }
            Button {
                if previewIsPlaying { pausePreview() }
                else { preview(at: max(0, item.start - 2), until: min(sourceDuration, item.end + 2)) }
            } label: {
                Label(previewIsPlaying ? "Pause Preview" : "Preview Cut", systemImage: previewIsPlaying ? "pause.fill" : "play.fill")
            }
            .disabled(localOriginal == nil)
            .buttonStyle(.glass)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A compact, independently scrolling source-time transcript. Its header and
    /// processing bar remain pinned even while the reader scrolls through spoken words.
    private var transcriptPanel: some View {
        let lines = transcriptLines
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text("Transcript").font(.headline)
                Spacer(minLength: 3)
                if !transcriptFollowsCut && selectedCut != nil {
                    Button("To Cut") {
                        transcriptFollowsCut = true
                        transcriptFocusRequest &+= 1
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .help("Return to the transcript text inside the selected cut")
                }
                Text("\(lines.count) lines").font(.caption).foregroundStyle(.secondary)
            }
            if let workingEpisode {
                ProcessingStatus(episode: workingEpisode)
            }
            if lines.isEmpty {
                Text(workingEpisode?.stage == .transcribing
                     ? "Transcribing… Lines will appear here as they are recognized."
                     : "No transcript available yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                                let inside = selectedCut.map { line.start < $0.end && line.end > $0.start } ?? false
                                let audible = cursorTime >= line.start && cursorTime < line.end
                                Button {
                                    cursorTime = line.start
                                    centerTimeline(on: line.start)
                                    if localOriginal != nil { preview(at: line.start) }
                                } label: {
                                    HStack(alignment: .top, spacing: 8) {
                                        Text(Fmt.clock(line.start))
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                            .frame(width: 47, alignment: .leading)
                                        Text(line.text)
                                            .font(.callout)
                                            .foregroundStyle(inside ? Color.primary : Color.primary.opacity(0.84))
                                            .multilineTextAlignment(.leading)
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 5)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(inside ? Color.podTeal.opacity(0.14)
                                                : audible ? Color.primary.opacity(0.06) : Color.clear,
                                                in: RoundedRectangle(cornerRadius: 6))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help("Preview original audio from \(Fmt.clock(line.start))")
                                .id(index)
                            }
                        }
                        .padding(5)
                    }
                    .onScrollPhaseChange { _, phase in
                        if phase == .interacting { transcriptFollowsCut = false }
                    }
                    .task(id: selectedCutID) {
                        transcriptFollowsCut = true
                        await Task.yield()
                        if let index = transcriptLineIndex(for: selectedCut, in: lines) {
                            proxy.scrollTo(index, anchor: .center)
                        }
                    }
                    .onChange(of: lines.count) { _, _ in
                        if transcriptFollowsCut,
                           let index = transcriptLineIndex(for: selectedCut, in: lines) {
                            proxy.scrollTo(index, anchor: .center)
                        }
                    }
                    .onChange(of: transcriptFocusRequest) { _, _ in
                        if let index = transcriptLineIndex(for: selectedCut, in: lines) {
                            proxy.scrollTo(index, anchor: .center)
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.20), in: RoundedRectangle(cornerRadius: 12))
    }

    private func transcriptLineIndex(for cut: CutSegment?, in lines: [TranscriptLine]) -> Int? {
        guard let cut, !lines.isEmpty else { return nil }
        return lines.firstIndex(where: { $0.end > cut.start && $0.start < cut.end })
            ?? lines.lastIndex(where: { $0.start <= cut.start })
            ?? 0
    }

    private func centerTimeline(on position: Double) {
        guard zoomExponent > 0 else { return }
        let length = visibleLength
        let start = max(0, min(sourceDuration - length, position - length / 2))
        scrollFraction = sourceDuration > length ? start / (sourceDuration - length) : 0
    }

    private enum Edge { case start, end }

    private func secondsBinding(_ cut: Binding<CutSegment>, edge: Edge) -> Binding<Double> {
        Binding {
            edge == .start ? cut.wrappedValue.start : cut.wrappedValue.end
        } set: { amount in
            guard amount.isFinite else { return }
            var copy = cut.wrappedValue
            if edge == .start { copy.start = min(max(0, amount), copy.end - 0.1) }
            else { copy.end = max(copy.start + 0.1, min(sourceDuration, amount)) }
            copy.source = "Manual"
            cut.wrappedValue = copy
        }
    }

    private func fieldBinding(_ cut: Binding<CutSegment>, _ path: WritableKeyPath<CutSegment, String>) -> Binding<String> {
        Binding(get: { cut.wrappedValue[keyPath: path] }, set: { value in
            var copy = cut.wrappedValue
            copy[keyPath: path] = value
            if path == \.category { copy.source = "Manual" }
            cut.wrappedValue = copy
        })
    }

    private func options(_ current: String, standard: [String]) -> [String] {
        standard.contains(current) || current.isEmpty ? standard : [current] + standard
    }

    private func addCut() {
        let available = sourceDuration
        let length = min(30, max(0.1, available * 0.03))
        let start = min(max(0, cursorTime), max(0, available - length))
        let new = CutSegment(start: start, end: start + length, category: "sponsor", source: "Manual")
        cuts.append(new)
        selectedCutID = new.id
        focusSelection()
    }

    private func focusSelection() {
        guard let selectedIndex else { return }
        let cut = cuts[selectedIndex]
        let targetLength = max(12, cut.length * 4)
        zoomExponent = min(6, max(0, log2(sourceDuration / targetLength)))
        let window = sourceDuration / pow(2, zoomExponent)
        let desiredStart = max(0, min(sourceDuration - window, (cut.start + cut.end - window) / 2))
        scrollFraction = sourceDuration > window ? desiredStart / (sourceDuration - window) : 0
        cursorTime = cut.start
    }

    private func changeZoom(by steps: Double) {
        let anchor = selectedIndex.map { (cuts[$0].start + cuts[$0].end) / 2 } ?? cursorTime
        zoomExponent = min(6, max(0, zoomExponent + steps))
        let length = visibleLength
        let start = max(0, min(sourceDuration - length, anchor - length / 2))
        scrollFraction = sourceDuration > length ? start / (sourceDuration - length) : 0
    }

    private func loadOriginalWaveform() async {
        waveform = nil
        waveformError = nil
        guard let url = localOriginal else {
            waveformError = "Original local audio unavailable; numeric editing still works."
            return
        }
        loadingWaveform = true
        defer { loadingWaveform = false }
        let task = Task.detached(priority: .utility) {
            try await SponsorWaveformLoader.load(from: url)
        }
        do {
            let envelope = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            guard !Task.isCancelled else { task.cancel(); return }
            waveform = envelope
        } catch is CancellationError {
            task.cancel()
        } catch {
            guard !Task.isCancelled else { task.cancel(); return }
            waveformError = error.localizedDescription
        }
    }

    private func preview(at position: Double, until end: Double? = nil) {
        guard let url = localOriginal else {
            audioMessage = "Original source audio is unavailable."
            return
        }
        audioMessage = nil
        let audio: AVPlayer
        if let existing = previewPlayer { audio = existing }
        else {
            audio = AVPlayer(url: url)
            previewPlayer = audio
        }
        let start = min(max(0, position), sourceDuration)
        cursorTime = start
        previewEndTime = end
        // Keep the editor compact: video appears only when previewing a movie source.
        if originalIsVideo { showingVideoPreview = true }
        audio.pause()
        audio.seek(to: CMTime(seconds: start, preferredTimescale: 600),
                   toleranceBefore: .zero, toleranceAfter: .zero) { completed in
            Task { @MainActor in
                guard completed, previewPlayer === audio else { return }
                audio.play()
                previewIsPlaying = true
            }
        }
        previewMonitor?.cancel()
        previewMonitor = Task { @MainActor in
            while !Task.isCancelled {
                let now = audio.currentTime().seconds
                if now.isFinite && now >= 0 {
                    cursorTime = min(sourceDuration, now)
                    if let previewEndTime, now >= previewEndTime { pausePreview(); return }
                    if now >= sourceDuration - 0.05 { pausePreview(); return }
                }
                try? await Task.sleep(for: .milliseconds(120))
            }
        }
    }

    private func pausePreview() {
        previewPlayer?.pause()
        previewIsPlaying = false
        previewEndTime = nil
        previewMonitor?.cancel()
        previewMonitor = nil
    }

    private func stopPreview() {
        pausePreview()
        previewPlayer?.replaceCurrentItem(with: nil)
        previewPlayer = nil
    }

    private func preciseTime(_ time: Double) -> String {
        let safe = max(0, time.isFinite ? time : 0)
        let whole = Int(safe)
        let fraction = Int((safe - Double(whole)) * 100)
        return String(format: "%02d:%02d:%02d.%02d", whole / 3600, (whole / 60) % 60, whole % 60, fraction)
    }
}

/// Renders the full source envelope at any zoom level with unmodified cut metadata on top.
private struct SponsorCutTimeline: View {
    @Binding var cuts: [CutSegment]
    @Binding var selection: UUID?
    @Binding var playhead: Double
    let samples: [Double]
    let duration: Double
    let visibleStart: Double
    let visibleLength: Double

    var body: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width)
            let height = geometry.size.height
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(0.045))
                Canvas { context, canvasSize in
                    let bars = max(2, Int(canvasSize.width / 2.6))
                    let unit = canvasSize.width / CGFloat(bars)
                    var barsPath = Path()
                    for bar in 0..<bars {
                        let at = visibleStart + Double(bar) / Double(bars) * visibleLength
                        let to = visibleStart + Double(bar + 1) / Double(bars) * visibleLength
                        var amplitude = 0.06
                        if !samples.isEmpty {
                            let first = min(samples.count - 1, max(0, Int(at / duration * Double(samples.count - 1))))
                            let last = min(samples.count - 1, max(first, Int(to / duration * Double(samples.count - 1))))
                            let strideSize = max(1, (last - first + 1) / 16)
                            amplitude = max(0.035, samples[first])
                            for index in stride(from: first, through: last, by: strideSize) {
                                amplitude = max(amplitude, samples[index])
                            }
                        }
                        let half = canvasSize.height * 0.43 * amplitude
                        let x = CGFloat(bar) * unit + unit / 2
                        barsPath.move(to: CGPoint(x: x, y: canvasSize.height / 2 - half))
                        barsPath.addLine(to: CGPoint(x: x, y: canvasSize.height / 2 + half))
                    }
                    context.stroke(barsPath, with: .color(.primary.opacity(0.40)), lineWidth: 1.9)
                    var center = Path()
                    center.move(to: CGPoint(x: 0, y: canvasSize.height / 2))
                    center.addLine(to: CGPoint(x: canvasSize.width, y: canvasSize.height / 2))
                    context.stroke(center, with: .color(.primary.opacity(0.1)), lineWidth: 0.7)
                }
                .contentShape(Rectangle())
                .gesture(SpatialTapGesture().onEnded { tap in
                    playhead = max(0, min(duration, visibleStart + Double(tap.location.x / width) * visibleLength))
                })

                ForEach($cuts) { $cut in
                    SponsorCutRegion(cut: $cut, selected: $selection, duration: duration,
                                     visibleStart: visibleStart, visibleLength: visibleLength,
                                     width: width, height: height)
                }

                if playhead >= visibleStart && playhead <= visibleStart + visibleLength {
                    let x = CGFloat((playhead - visibleStart) / visibleLength) * width
                    Rectangle().fill(Color.white.opacity(0.9))
                        .frame(width: 1.5, height: height)
                        .shadow(color: .black.opacity(0.45), radius: 2)
                        .offset(x: x)
                        .allowsHitTesting(false)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

private struct SponsorCutRegion: View {
    @Binding var cut: CutSegment
    @Binding var selected: UUID?
    let duration: Double
    let visibleStart: Double
    let visibleLength: Double
    let width: CGFloat
    let height: CGFloat

    @State private var initial: CutSegment?
    private enum DragPart { case start, end, body }

    var body: some View {
        let originalLeft = CGFloat((cut.start - visibleStart) / visibleLength) * width
        let originalRight = CGFloat((cut.end - visibleStart) / visibleLength) * width
        let left = max(0, originalLeft)
        let right = min(width, originalRight)
        let chosen = selected == cut.id

        if right > left {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.podTeal.opacity(chosen ? 0.34 : 0.19))
                    .overlay {
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Color.podTeal.opacity(chosen ? 0.9 : 0.55), lineWidth: chosen ? 1.6 : 1)
                    }
                    .frame(width: max(2, right - left), height: height - 8)
                    .position(x: (left + right) / 2, y: height / 2)
                    .gesture(drag(.body))
                    .onTapGesture { selected = cut.id }

                if originalLeft >= 0 && originalLeft <= width {
                    handle(.start, at: originalLeft, selected: chosen)
                }
                if originalRight >= 0 && originalRight <= width {
                    handle(.end, at: originalRight, selected: chosen)
                }
            }
            .frame(width: width, height: height)
        }
    }

    private func handle(_ part: DragPart, at x: CGFloat, selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Color.podTeal.opacity(selected ? 1 : 0.85))
            .frame(width: 9, height: height - 12)
            .overlay(alignment: .center) {
                Capsule().fill(Color.white.opacity(0.65)).frame(width: 2, height: 18)
            }
            .frame(width: 18)
            .contentShape(Rectangle())
            .position(x: x, y: height / 2)
            .gesture(drag(part))
            .accessibilityLabel(part == .start ? "Move cut start" : "Move cut end")
    }

    private func drag(_ part: DragPart) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if initial == nil { initial = cut }
                guard let initial else { return }
                selected = initial.id
                let change = Double(value.translation.width / width) * visibleLength
                var adjusted = initial
                switch part {
                case .start:
                    adjusted.start = min(max(0, initial.start + change), initial.end - 0.1)
                case .end:
                    adjusted.end = max(initial.start + 0.1, min(duration, initial.end + change))
                case .body:
                    let length = initial.length
                    adjusted.start = min(max(0, initial.start + change), max(0, duration - length))
                    adjusted.end = adjusted.start + length
                }
                adjusted.source = "Manual"
                cut = adjusted
            }
            .onEnded { _ in initial = nil }
    }
}
