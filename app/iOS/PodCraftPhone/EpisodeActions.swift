import SwiftUI
import UIKit

// MARK: - Swipes

extension View {
    /// Swipe right to add the episode to Up Next (or take it off), left to mark it played or unplayed.
    func episodeSwipes(_ episode: RemoteEpisode) -> some View { modifier(EpisodeSwipe(episode: episode)) }
}

/// Full swipes like Mail: past the threshold the action is armed (with a tap of haptics) and runs on release.
/// The rows live in scroll views rather than Lists, so this is a pan that only starts on a mostly sideways drag
/// and leaves vertical scrolling alone.
struct EpisodeSwipe: ViewModifier {
    @Environment(Store.self) private var store
    let episode: RemoteEpisode
    @State private var offset: CGFloat = 0
    @State private var armed = false
    private let threshold: CGFloat = 80

    func body(content: Content) -> some View {
        let queued = store.isQueued(episode)
        let played = store.isPlayed(episode)
        content
            .offset(x: offset)
            .background {
                HStack(spacing: 0) {
                    if offset > 0 {
                        strip(icon: queued ? "text.badge.minus" : "text.badge.plus",
                              title: queued ? "Remove" : "Up Next",
                              color: queued ? .orange : .podTeal, leading: true)
                            .frame(width: offset)
                        Spacer(minLength: 0)
                    } else if offset < 0 {
                        Spacer(minLength: 0)
                        strip(icon: played ? "circle" : "checkmark.circle",
                              title: played ? "Unplayed" : "Played",
                              color: .indigo, leading: false)
                            .frame(width: -offset)
                    }
                }
            }
            .gesture(HorizontalPan(onChange: changed, onEnd: ended))
            .sensoryFeedback(.impact(weight: .medium), trigger: armed) { _, now in now }
            .accessibilityAction(named: queued ? "Remove from Up Next" : "Add to Up Next") { toggleQueue() }
            .accessibilityAction(named: played ? "Mark as Unplayed" : "Mark as Played") { store.setPlayed(episode, !played) }
    }

    private func strip(icon: String, title: String, color: Color, leading: Bool) -> some View {
        ZStack(alignment: leading ? .leading : .trailing) {
            color.opacity(armed ? 1 : 0.75)
            VStack(spacing: 4) {
                Image(systemName: icon).font(.title3.weight(.semibold))
                    .scaleEffect(armed ? 1.15 : 1)
                Text(title).font(.caption2.weight(.semibold))
            }
            .foregroundStyle(.white)
            .frame(width: threshold)
            .opacity(abs(offset) > 28 ? 1 : 0)
        }
        .clipped()
        .animation(.snappy(duration: 0.18), value: armed)
    }

    private func changed(_ x: CGFloat) {
        // Past the threshold the row follows the finger more slowly.
        let limit = threshold * 1.4
        offset = abs(x) <= limit ? x : (x > 0 ? 1 : -1) * (limit + (abs(x) - limit) * 0.3)
        let now = abs(offset) >= threshold
        if now != armed { armed = now }
    }

    private func ended(cancelled: Bool) {
        if armed && !cancelled {
            if offset > 0 { toggleQueue() } else { store.setPlayed(episode, !store.isPlayed(episode)) }
        }
        armed = false
        withAnimation(.spring(duration: 0.3, bounce: 0.15)) { offset = 0 }
    }

    private func toggleQueue() {
        if store.isQueued(episode) { store.dequeue(episode.id) } else { store.enqueue(episode) }
    }
}

/// A pan that begins only when the finger moves mostly sideways, so vertical scrolling keeps working.
struct HorizontalPan: UIGestureRecognizerRepresentable {
    var onChange: (CGFloat) -> Void
    var onEnd: (_ cancelled: Bool) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        return pan
    }

    func handleUIGestureRecognizerAction(_ pan: UIPanGestureRecognizer, context: Context) {
        switch pan.state {
        case .began, .changed: onChange(pan.translation(in: pan.view).x)
        case .ended: onEnd(false)
        case .cancelled, .failed: onEnd(true)
        default: break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
            guard let pan = gesture as? UIPanGestureRecognizer else { return true }
            let v = pan.velocity(in: pan.view)
            return abs(v.x) > abs(v.y) * 1.5
        }
    }
}

// MARK: - Long-press menus

/// What a long press on an episode offers, wherever it's shown: play, Up Next, played, share.
struct EpisodeMenu: View {
    let episode: RemoteEpisode
    let store: Store
    let player: AudioPlayer

    var body: some View {
        let isCurrent = player.episode?.id == episode.id
        Section {
            if isCurrent && player.isPlaying {
                Button("Pause", systemImage: "pause") { player.pause() }
            } else {
                Button("Play", systemImage: "play") { player.play(episode) }
            }
            Button("Open Player", systemImage: "rectangle.portrait.and.arrow.forward") {
                player.play(episode); player.showNowPlaying = true
            }
        }
        if !isCurrent {
            Section {
                Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") { store.playNext(episode) }
                if store.isQueued(episode) {
                    Button("Remove from Up Next", systemImage: "text.badge.minus") { store.dequeue(episode.id) }
                } else {
                    Button("Add to Up Next", systemImage: "text.badge.plus") { store.enqueue(episode) }
                }
            }
        }
        Section {
            if store.isPlayed(episode) {
                Button("Mark as Unplayed", systemImage: "circle") { store.setPlayed(episode, false) }
            } else {
                Button("Mark as Played", systemImage: "checkmark.circle") { store.setPlayed(episode, true) }
            }
            DownloadMenuItems(episode: episode)
            ShareLink(item: episode.media, subject: Text(episode.title)) {
                Label("Share Episode", systemImage: "square.and.arrow.up")
            }
        }
    }
}

/// A long press on a show: play its latest episode, queue it, or unfollow.
struct ShowMenu: View {
    let show: RemoteShow
    let store: Store
    let player: AudioPlayer

    var body: some View {
        if let latest = show.episodes.first {
            Section {
                Button("Play Latest Episode", systemImage: "play") { player.play(latest); player.showNowPlaying = true }
                if player.episode?.id != latest.id {
                    if store.isQueued(latest) {
                        Button("Remove Latest from Up Next", systemImage: "text.badge.minus") { store.dequeue(latest.id) }
                    } else {
                        Button("Add Latest to Up Next", systemImage: "text.badge.plus") { store.enqueue(latest) }
                    }
                }
            }
        }
        if store.isStandalone && store.isSubscribed(showID: show.id) {
            Section {
                Button("Unfollow", systemImage: "minus.circle", role: .destructive) { store.unsubscribe(showID: show.id) }
            }
        }
    }
}
