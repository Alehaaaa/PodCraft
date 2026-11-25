import SwiftUI

/// Placeholder cover art: a soft gradient with the show's initials, optionally framed
/// with the feed's colored border ("A colored frame around the artwork tells this feed apart").
struct ArtworkView: View {
    var title: String
    var hue: Double
    var size: CGFloat
    var borderHue: Double? = nil
    var borderWidth: Double = 0
    var symbol: String = "waveform"

    var initials: String {
        let words = title.split(separator: " ").filter { $0.first?.isLetter ?? false }
        return String(words.prefix(2).compactMap(\.first)).uppercased()
    }

    var body: some View {
        let radius = size * 0.2
        ZStack {
            LinearGradient(colors: [Color(hue: hue, saturation: 0.55, brightness: 0.95),
                                    Color(hue: (hue + 0.08).truncatingRemainder(dividingBy: 1), saturation: 0.75, brightness: 0.62)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: symbol)
                .font(.system(size: size * 0.5, weight: .bold))
                .foregroundStyle(.white.opacity(0.18))
                .offset(x: size * 0.18, y: size * 0.16)
            VStack(alignment: .leading) {
                Spacer(minLength: 0)
                Text(initials)
                    .font(.system(size: max(9, size * 0.26), weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .padding(size * 0.1)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay {
            if let b = borderHue, borderWidth > 0 {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color(hue: b, saturation: 0.8, brightness: 0.85),
                                  lineWidth: max(1.5, borderWidth * size / 160))
            } else {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(.black.opacity(0.08), lineWidth: 0.5)
            }
        }
    }
}

/// A downloaded cover picture with the same rounded shape and optional feed frame as the drawn placeholder.
struct CoverImage: View {
    var image: NSImage
    var size: CGFloat
    var borderHue: Double? = nil
    var borderWidth: Double = 0

    var body: some View {
        let radius = size * 0.2
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .scaledToFill()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                if let b = borderHue, borderWidth > 0 {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(Color(hue: b, saturation: 0.8, brightness: 0.85), lineWidth: max(1.5, borderWidth * size / 160))
                } else {
                    RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(.black.opacity(0.08), lineWidth: 0.5)
                }
            }
    }
}

struct ShowArtwork: View {
    @Environment(Library.self) private var library
    var showID: UUID
    var size: CGFloat
    var framed = false

    var body: some View {
        let _ = library.artworkVersion
        if let s = library.show(showID) {
            let f = library.feed(s.feedID)
            let borderHue = s.showsBorder ? s.borderHue : (framed && (f?.showsBorder ?? false) ? f?.borderHue : nil)
            let borderWidth = s.showsBorder ? s.borderWidth : (framed ? (f?.borderWidth ?? 0) : 0)
            // Small sizes use a ready-to-draw copy so rows don't flash while a big picture is decoded.
            if let thumb = ArtworkStore.thumbnail(remote: s.artworkURL, localPath: s.customArtwork, points: size) {
                CoverImage(image: thumb, size: size, borderHue: borderHue, borderWidth: borderWidth)
            } else if let path = s.customArtwork, let img = ArtworkStore.localImage(path) {
                CoverImage(image: img, size: size, borderHue: borderHue, borderWidth: borderWidth)
            } else if let img = ArtworkStore.image(for: s.artworkURL) {
                CoverImage(image: img, size: size, borderHue: borderHue, borderWidth: borderWidth)
            } else {
                ArtworkView(title: s.title, hue: s.hue, size: size, borderHue: borderHue, borderWidth: borderWidth,
                            symbol: s.isFiles ? "folder.fill" : "waveform")
            }
        } else {
            ArtworkView(title: "?", hue: 0.6, size: size)
        }
    }
}

/// An episode's own cover when it has one, otherwise its show's.
struct EpisodeArtwork: View {
    @Environment(Library.self) private var library
    var episode: Episode
    var size: CGFloat

    var body: some View {
        let _ = library.artworkVersion
        if let thumb = ArtworkStore.thumbnail(remote: episode.artworkURL, points: size) {
            CoverImage(image: thumb, size: size)
        } else if let img = ArtworkStore.image(for: episode.artworkURL) {
            CoverImage(image: img, size: size)
        } else {
            ShowArtwork(showID: episode.showID, size: size)
        }
    }
}

/// Small helper for empty states.
struct EmptyHint: View {
    var symbol: String
    var title: String
    var message: String
    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(message)
        }
    }
}

struct Toast: View {
    var text: String
    var body: some View {
        Text(text)
            .font(.callout.weight(.medium))
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .podGlass(in: Capsule())
            .transition(.move(edge: .top).combined(with: .opacity))
    }
}

/// Manage / Listen switch shown in the window toolbar.
struct ModePicker: View {
    @Environment(Library.self) private var library
    var body: some View {
        if Snapshot.active { SnapshotModeSwitch() } else { picker }
    }

    var picker: some View {
        Picker("Mode", selection: Binding(get: { library.mode }, set: { library.setMode($0) })) {
            ForEach(AppMode.allCases) { m in
                Label(m.title, systemImage: m.symbol).tag(m)
            }
        }
        .pickerStyle(.segmented)
        .labelStyle(.titleAndIcon)
        .fixedSize()
        .help("Manage your feeds, or just listen")
    }
}

// MARK: - Screenshot fallbacks
//
// The --screenshot picture is drawn with AppKit's cacheDisplay, which can't draw macOS 27 glass or the
// floating sidebar. In that mode only, glass surfaces get a solid fill and the sidebar sits in a plain
// column so the saved picture shows the real layout. The running app always uses real glass.

@MainActor
enum Snapshot {
    static var active = false
}

extension View {
    @ViewBuilder
    func podGlass<S: Shape>(in shape: S) -> some View {
        if Snapshot.active {
            self.background(Color(nsColor: .controlBackgroundColor), in: shape)
                .overlay(shape.stroke(Color.primary.opacity(0.1), lineWidth: 1))
                .shadow(color: .black.opacity(0.2), radius: 10, y: 3)
        } else {
            self.glassEffect(.regular.interactive(), in: shape)
        }
    }
}

/// NavigationSplitView in the app; a plain sidebar column in screenshot mode.
struct SplitShell<Sidebar: View, Detail: View>: View {
    var sidebarWidth: CGFloat = 240
    @ViewBuilder var sidebar: () -> Sidebar
    @ViewBuilder var detail: () -> Detail

    var body: some View {
        if Snapshot.active {
            HStack(spacing: 0) {
                sidebar()
                    .frame(width: sidebarWidth)
                    .background(Color(nsColor: .underPageBackgroundColor))
                Divider()
                detail().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            // Each column gets a fixed minimum size. Without it the columns report a new minimum whenever
            // their contents change (moving progress, a mode switch), and AppKit can end up re-laying out the
            // window in a loop until it gives up and stops the app.
            NavigationSplitView {
                sidebar()
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                    .navigationSplitViewColumnWidth(min: sidebarWidth - 30, ideal: sidebarWidth, max: sidebarWidth + 80)
            } detail: {
                detail()
                    // The same fixed minimum as RootView's main content. Requiring 500 points
                    // here made the sidebar's maximum width (330) plus the 220-point inspector
                    // exceed the window's 980-point minimum, producing competing size requests
                    // while AppKit resized the NavigationSplitView and its native inspector.
                    .frame(minWidth: 340, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            }
        }
    }
}

/// Manage / Listen switch drawn by hand for the screenshot (the native one is glass).
struct SnapshotModeSwitch: View {
    @Environment(Library.self) private var library
    var body: some View {
        HStack(spacing: 2) {
            ForEach(AppMode.allCases) { m in
                HStack(spacing: 5) { Image(systemName: m.symbol); Text(m.title) }
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(library.mode == m ? Color.podTeal : .clear, in: .capsule)
                    .foregroundStyle(library.mode == m ? Color.white : Color.primary)
            }
        }
        .padding(3)
        .background(Color.primary.opacity(0.08), in: .capsule)
    }
}

extension Color {
    /// The app's colour: teal, the background colour of the logo (#00A99D).
    static let podTeal = Color(red: 0x00 / 255, green: 0xA9 / 255, blue: 0x9D / 255)
}

/// A consistent explanation of which recording an episode can use. The old UI
/// exposed this as an unlabeled rectangle icon, which made discovery and playback
/// look like the same operation.
struct VideoSourceBadge: View {
    let episode: Episode
    var compact = false

    var body: some View {
        if episode.youtubeMatchState == .matched, episode.youtubeID != nil {
            Label(compact ? "Video" : "Verified video available", systemImage: "play.rectangle.fill")
                .foregroundStyle(.tint)
                .help("This RSS episode was matched to the official YouTube upload. Choose it to prepare and play video.")
        } else if episode.isVideo {
            Label(compact ? "Video" : "Video from RSS", systemImage: "video.fill")
                .foregroundStyle(.secondary)
        }
    }
}
