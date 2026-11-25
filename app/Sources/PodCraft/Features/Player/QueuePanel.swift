import SwiftUI

/// Up Next: the episodes you queued (drag to reorder) and the ones you're partway through.
/// Shown in the side column, and beside the cinema player.
struct QueuePanel: View {
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    var onCinema = false

    var body: some View {
        let queued = player.upNext
        let resume = player.continuePlaying
        Group {
            if queued.isEmpty && resume.isEmpty {
                ContentUnavailableView("Nothing Queued", systemImage: "list.bullet",
                                       description: Text("Use “Play Next” or “Add to Queue” on any episode."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    if !queued.isEmpty {
                        Section {
                            ForEach(queued) { e in
                                row(e, queued: true)
                            }
                            .onMove { from, to in
                                var ids = queued.map(\.id)
                                ids.move(fromOffsets: from, toOffset: to)
                                let rest = player.queue.filter { !ids.contains($0) }
                                player.queue = ids + rest
                            }
                        } header: {
                            header("Up Next")
                        }
                    }
                    if !resume.isEmpty {
                        Section {
                            ForEach(resume.prefix(20)) { e in row(e, queued: false) }
                        } header: {
                            header("Continue Playing")
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }

    func header(_ title: String) -> some View {
        Text(title).font(.title3.bold()).foregroundStyle(.primary).padding(.top, 8).padding(.bottom, 4)
    }

    func row(_ e: Episode, queued: Bool) -> some View {
        let left = max(0, e.playbackDuration - e.position)
        return HStack(spacing: 12) {
            EpisodeArtwork(episode: e, size: 46)
            VStack(alignment: .leading, spacing: 3) {
                Text(e.title).font(.callout.weight(.semibold)).lineLimit(2)
                Text("\(Fmt.dateFormatter.string(from: e.published)) · \(e.position > 1 ? "\(Fmt.compact(left)) left" : Fmt.compact(e.playbackDuration))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            if queued {
                Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary).help("Drag to reorder")
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { player.play(e.id) }
        .contextMenu {
            Button("Play") { player.play(e.id) }
            if queued {
                Button("Play Next") { player.playNext(e.id) }
                Button("Remove from Queue") { player.removeFromQueue(e.id) }
            } else {
                Button("Add to Queue") { player.addToQueue(e.id) }
            }
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }
}
