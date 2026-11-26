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
    @Environment(Router.self) private var router
    let episode: RemoteEpisode
    let store: Store
    let player: AudioPlayer
    /// Offer Go to Show (not on the show's own page).
    var goToShow = true

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
        if goToShow, let show = store.show(episode.showID) {
            Section {
                Button("Go to Show", systemImage: "square.stack") { router.open(show, player: player) }
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

// MARK: - Up Next queue

struct UpNextRoute: Hashable {}

/// Up Next on its own page (from Home): the whole queue, to reorder and edit.
struct UpNextView: View {
    @Environment(Store.self) private var store

    var body: some View {
        Group {
            if store.queuedEpisodes.isEmpty {
                ContentUnavailableView("Nothing Up Next", systemImage: "text.badge.plus",
                                       description: Text("Swipe right on an episode to add it here."))
            } else {
                QueueList(current: nil, fitsContent: false)
            }
        }
        .navigationTitle("Up Next")
        .toolbar {
            if !store.queuedEpisodes.isEmpty {
                Button("Clear") { withAnimation { store.clearQueue() } }
            }
        }
    }
}

/// The queue like a music app's: hold a row and drag to reorder, swipe right to play it next,
/// swipe left to take it off. Below it, more from the current show, which swipe onto the queue.
/// With `fitsContent` the list is as tall as its rows and doesn't scroll, for the player's panel.
struct QueueList: View {
    @Environment(Store.self) private var store
    @Environment(AudioPlayer.self) private var player
    let current: RemoteEpisode?
    var fitsContent = true

    private static let rowHeight: CGFloat = 72
    private static let headerHeight: CGFloat = 40

    var body: some View {
        let queued = store.queuedEpisodes
        let more = current.map { e in store.upNext(after: e).filter { !store.isQueued($0) } } ?? []
        let headers = (fitsContent && !queued.isEmpty ? 1 : 0) + (more.isEmpty ? 0 : 1)
        List {
            if !queued.isEmpty {
                if fitsContent {
                    header("Up Next") {
                        Button("Clear") { withAnimation { store.clearQueue() } }
                            .font(.subheadline.weight(.semibold)).buttonStyle(.borderless)
                    }
                }
                ForEach(queued) { e in
                    row(e, queued: true)
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            Button { withAnimation { store.playNext(e) } } label: {
                                Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                            }
                            .tint(.podTeal)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) { withAnimation { store.dequeue(e.id) } } label: {
                                Label("Remove", systemImage: "text.badge.minus")
                            }
                        }
                }
                .onMove { store.moveQueue(from: $0, to: $1) }
            }
            if !more.isEmpty {
                header("From This Show") { EmptyView() }
                ForEach(more) { e in
                    row(e, queued: false)
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            Button { withAnimation { store.enqueue(e) } } label: {
                                Label("Up Next", systemImage: "text.badge.plus")
                            }
                            .tint(.podTeal)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button { withAnimation { store.playNext(e) } } label: {
                                Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                            }
                            .tint(.indigo)
                        }
                }
            }
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 0)
        .scrollContentBackground(fitsContent ? .hidden : .automatic)
        .scrollDisabled(fitsContent)
        .frame(height: fitsContent
               ? CGFloat(queued.count + more.count) * Self.rowHeight + CGFloat(headers) * Self.headerHeight
               : nil)
        .animation(.default, value: store.queue)
    }

    private func header<Trailing: View>(_ title: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack {
            Text(title).font(.headline)
            Spacer()
            trailing()
        }
        .frame(height: Self.headerHeight, alignment: .bottom)
        .listRowInsets(EdgeInsets(top: 0, leading: fitsContent ? 0 : 16, bottom: 4, trailing: fitsContent ? 0 : 16))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .moveDisabled(true)
    }

    private func row(_ e: RemoteEpisode, queued: Bool) -> some View {
        HStack(spacing: 12) {
            Artwork(url: e.artwork ?? store.show(e.showID)?.artwork, size: 48, radius: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(store.show(e.showID)?.title.uppercased() ?? Fmt.date(e.published))
                    .font(.caption2.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
                Text(e.title).font(.subheadline.weight(.semibold)).lineLimit(2)
            }
            Spacer(minLength: 4)
            Text(Fmt.remaining(store.remaining(e))).font(.caption).foregroundStyle(.secondary)
            if queued {
                Image(systemName: "line.3.horizontal").font(.body.weight(.semibold)).foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .frame(height: Self.rowHeight - 12)
        .contentShape(Rectangle())
        .onTapGesture { player.play(e) }
        .listRowInsets(EdgeInsets(top: 6, leading: fitsContent ? 0 : 16, bottom: 6, trailing: fitsContent ? 0 : 16))
        .listRowBackground(Color.clear)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Play Next") { store.playNext(e) }
        .accessibilityAction(named: queued ? "Remove from Up Next" : "Add to Up Next") {
            queued ? store.dequeue(e.id) : store.enqueue(e)
        }
    }
}
