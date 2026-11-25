import SwiftUI
import AVKit

/// The bar above the tabs: cover, title and play / skip, like the Podcasts app. Tap to open the player.
struct MiniPlayer: View {
    @Environment(Store.self) private var store
    @Environment(AudioPlayer.self) private var player

    var body: some View {
        HStack(spacing: 10) {
            if let e = player.episode {
                Artwork(url: e.artwork ?? store.show(e.showID)?.artwork, size: 36, radius: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(e.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(player.currentChapter?.title ?? store.show(e.showID)?.title ?? "")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Button { player.togglePlay() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title3)
                        .frame(width: 34, height: 34)
                }
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                Button { player.skip(30) } label: {
                    Image(systemName: "goforward.30").font(.title3).frame(width: 34, height: 34)
                }
                .accessibilityLabel("Forward 30 Seconds")
            } else {
                Image(systemName: "headphones").foregroundStyle(.secondary)
                Text("Nothing Playing").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .contentShape(Rectangle())
        .onTapGesture { if player.episode != nil { player.showNowPlaying = true } }
    }
}

struct NowPlayingView: View {
    @Environment(Store.self) private var store
    @Environment(AudioPlayer.self) private var player
    @Environment(\.dismiss) private var dismiss
    @State private var panel: Panel = .chapters
    @State private var transcript: [TranscriptLine]?
    @State private var scrubbing: Double?

    enum Panel: String, CaseIterable, Identifiable {
        case chapters = "Chapters", transcript = "Transcript"
        var id: String { rawValue }
    }

    var body: some View {
        if let e = player.episode {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 22) {
                        Capsule().fill(.secondary.opacity(0.5)).frame(width: 38, height: 5).padding(.top, 8)
                        picture(e)
                        titles(e)
                        scrubber
                        transport
                        extras
                        panels(e, proxy: proxy)
                    }
                    .padding(.horizontal, 22)
                    .padding(.bottom, 40)
                }
            }
            .background(backdrop(e))
            .task(id: e.id) {
                transcript = nil
                if e.hasTranscript { transcript = await store.detail(for: e)?.transcript }
            }
        }
    }

    // MARK: Parts

    @ViewBuilder
    private func picture(_ e: RemoteEpisode) -> some View {
        if e.isVideo, let p = player.player {
            VideoPlayer(player: p)
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        } else {
            Artwork(url: e.artwork ?? store.show(e.showID)?.artwork, size: nil, radius: 20)
                .frame(maxWidth: 320)
                .scaleEffect(player.isPlaying ? 1 : 0.88)
                .shadow(color: .black.opacity(0.3), radius: 24, y: 14)
                .animation(.spring(duration: 0.45, bounce: 0.3), value: player.isPlaying)
        }
    }

    private func titles(_ e: RemoteEpisode) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Fmt.date(e.published)).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(e.title).font(.title3.bold()).lineLimit(3)
            Text(player.currentChapter?.title ?? store.show(e.showID)?.title ?? "")
                .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var scrubber: some View {
        let shown = scrubbing ?? player.position
        return VStack(spacing: 4) {
            Slider(value: Binding(get: { shown }, set: { scrubbing = $0 }),
                   in: 0...max(player.duration, 1)) { editing in
                if !editing, let t = scrubbing { player.seek(to: t); scrubbing = nil }
            }
            HStack {
                Text(Fmt.clock(shown))
                Spacer()
                if player.isBuffering { ProgressView().controlSize(.mini) }
                Spacer()
                Text("−" + Fmt.clock(max(0, player.duration - shown) / Double(player.rate)))
            }
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    private var transport: some View {
        HStack {
            Button { player.skip(-15) } label: { Image(systemName: "gobackward.15").font(.system(size: 30)) }
                .accessibilityLabel("Back 15 Seconds")
            Spacer()
            Button { player.togglePlay() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 50))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 70, height: 70)
            }
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            Spacer()
            Button { player.skip(30) } label: { Image(systemName: "goforward.30").font(.system(size: 30)) }
                .accessibilityLabel("Forward 30 Seconds")
        }
        .foregroundStyle(.primary)
        .buttonStyle(.plain)
        .padding(.horizontal, 30)
    }

    private var extras: some View {
        HStack {
            Menu {
                ForEach([0.8, 1.0, 1.2, 1.5, 1.75, 2.0] as [Float], id: \.self) { r in
                    Button { player.setRate(r) } label: {
                        if abs(player.rate - r) < 0.01 { Label(speed(r), systemImage: "checkmark") } else { Text(speed(r)) }
                    }
                }
            } label: {
                Text(speed(player.rate)).font(.callout.weight(.semibold).monospacedDigit())
                    .frame(minWidth: 44, minHeight: 32)
            }
            Spacer()
            RoutePicker().frame(width: 32, height: 32)
            Spacer()
            Button { dismiss() } label: { Image(systemName: "chevron.down").font(.title3).frame(width: 44, height: 32) }
                .accessibilityLabel("Close Player")
        }
        .foregroundStyle(.secondary)
        .buttonStyle(.plain)
    }

    private func speed(_ r: Float) -> String {
        r == Float(Int(r)) ? "\(Int(r))×" : String(format: "%g×", r)
    }

    @ViewBuilder
    private func panels(_ e: RemoteEpisode, proxy: ScrollViewProxy) -> some View {
        if !e.chapters.isEmpty || e.hasTranscript {
            VStack(alignment: .leading, spacing: 12) {
                if !e.chapters.isEmpty && e.hasTranscript {
                    Picker("Show", selection: $panel) {
                        ForEach(Panel.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                if panel == .chapters && !e.chapters.isEmpty || !e.hasTranscript {
                    chapterList(e)
                } else {
                    transcriptList(proxy: proxy)
                }
            }
            .padding(.top, 8)
        }
    }

    private func chapterList(_ e: RemoteEpisode) -> some View {
        VStack(spacing: 0) {
            ForEach(e.chapters) { c in
                let current = player.currentChapter == c
                Button { player.seek(to: c.start) } label: {
                    HStack {
                        Text(c.title).font(current ? .body.weight(.semibold) : .body)
                            .foregroundStyle(current ? Color.podTeal : .primary)
                            .multilineTextAlignment(.leading)
                        Spacer()
                        Text(Fmt.clock(c.start)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 11)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider()
            }
        }
    }

    @ViewBuilder
    private func transcriptList(proxy: ScrollViewProxy) -> some View {
        if let lines = transcript {
            let active = lines.last { $0.start <= player.position + 0.2 }?.start
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(lines) { line in
                    Button { player.seek(to: line.start) } label: {
                        Text(line.text)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(line.start == active ? Color.primary : Color.secondary.opacity(0.7))
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .id(line.start)
                }
            }
            .onChange(of: active) { _, now in
                if let now { withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(now, anchor: .center) } }
            }
        } else {
            ProgressView("Loading Transcript…").frame(maxWidth: .infinity, minHeight: 120)
        }
    }

    private func backdrop(_ e: RemoteEpisode) -> some View {
        ZStack {
            Color(.systemBackground)
            Artwork(url: e.artwork ?? store.show(e.showID)?.artwork, size: nil, radius: 0)
                .scaleEffect(2.2)
                .blur(radius: 80)
                .opacity(0.45)
        }
        .ignoresSafeArea()
    }
}

/// AirPlay and Bluetooth output picker.
struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = .secondaryLabel
        v.activeTintColor = UIColor(Color.podTeal)
        v.prioritizesVideoDevices = false
        return v
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
