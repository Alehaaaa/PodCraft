import SwiftUI

/// One native split view for both modes: switching modes swaps what the sidebar and the main area
/// show, never the window structure itself (rebuilding it made the sidebar slide under the title bar).
struct RootView: View {
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player

    private var showsSidePanel: Bool {
        !player.cinemaMode && (player.showQueue || (player.showChapters && player.episode != nil))
    }

    /// Keep the detail mounted as the side panel opens, closes, or switches content.
    @ViewBuilder
    private var mainDetail: some View {
        GeometryReader { geometry in
            Group {
                switch library.mode {
                case .manage: ManageDetail()
                case .listen: ListenDetail()
                }
            }
            .overlay(alignment: .topLeading) {
                VideoPanel(height: library.mode == .listen ? 250 : 210,
                           availableSize: geometry.size)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                PlayerBar()
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .frame(minWidth: 340, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
    }

    @ViewBuilder
    private var sidePanel: some View {
        Group {
            if player.showQueue {
                QueuePanel()
            } else if let episode = player.episode {
                PlaybackInfoSidebar(episode: episode)
            }
        }
        .frame(minWidth: 220, idealWidth: 300, maxWidth: 420,
               minHeight: 0, maxHeight: .infinity)
    }

    var body: some View {
        @Bindable var lib = library
        // The library layout is always here. The cinema player is a separate layer the window lays over it
        // (AppDelegate.watchCinema), so opening or closing it never removes and re-adds this layout and its
        // title-bar items, which could stop the app while the window lays itself out.
        Group {
            SplitShell(sidebarWidth: 250) {
                Group {
                    switch library.mode {
                    case .manage: ManageSidebar()
                    case .listen: ListenSidebar()
                    }
                }
            } detail: {
                // Native adjustable side-by-side columns, without nesting SwiftUI's
                // inspector split controller inside NavigationSplitView. Even an empty
                // `.inspector` triggered recursive AppKit constraints under rapid resizing.
                HSplitView {
                    mainDetail
                    if showsSidePanel { sidePanel }
                }
                .frame(minWidth: 340, maxWidth: .infinity,
                       minHeight: 0, maxHeight: .infinity)
            }
        }
        .overlay(alignment: .top) {
            if let t = library.toast { Toast(text: t).padding(.top, 8) }
        }
        .frame(minWidth: 980, minHeight: 640)
        // The title bar is a native AppKit toolbar the window owns (MainToolbar): SwiftUI rebuilding its own
        // toolbar while the window resized is what stopped the app.
        .sheet(isPresented: $lib.showAddShow) { AddShowSheet() }
    }
}
