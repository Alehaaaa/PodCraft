import AppKit
import SwiftUI

/// The window's title bar, as a native AppKit toolbar the window owns: sidebar button, the Manage / Listen
/// switch in the centre, Manage's Add Show / Import buttons and Listen's search field.
///
/// SwiftUI used to build this toolbar from the views (.toolbar / .searchable). When the window was resized,
/// SwiftUI moved those items around in the middle of AppKit laying out the window, and AppKit stopped the app
/// ("more Update Constraints in Window passes than there are views"). Here every item exists from the start and
/// is only shown or hidden, outside layout, so resizing and switching modes never rebuild the title bar.
@MainActor
final class MainToolbar: NSObject, NSToolbarDelegate, NSSearchFieldDelegate {
    let toolbar = NSToolbar(identifier: "PodCraftMainToolbar")
    private let library: Library
    private weak var splitView: NSSplitView?
    private weak var window: NSWindow?

    private let modeID = NSToolbarItem.Identifier("mode")
    private let separatorID = NSToolbarItem.Identifier("sidebarSeparator")
    private let backID = NSToolbarItem.Identifier("navigationBack")
    private let backTitleID = NSToolbarItem.Identifier("navigationBackTitle")
    private let addShowID = NSToolbarItem.Identifier("addShow")
    private let importID = NSToolbarItem.Identifier("importFiles")
    private let searchID = NSToolbarItem.Identifier("search")

    private var modeControl: NSSegmentedControl?
    private var backItem: NSToolbarItem?
    private var backTitleItem: NSToolbarItem?
    private var backTitleLabel: NSTextField?
    private var searchItem: NSSearchToolbarItem?
    private var items: [NSToolbarItem.Identifier: NSToolbarItem] = [:]
    private var isActive = true
    private var titleVisibilityWatch: NSKeyValueObservation?

    init(library: Library, splitView: NSSplitView?, window: NSWindow) {
        self.library = library
        self.splitView = splitView
        self.window = window
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.centeredItemIdentifiers = [modeID]
        watch()
        // SwiftUI title bridging may reset this property after a route update.
        // Observe it so native Back + title remains the single visible title on detail pages.
        titleVisibilityWatch = window.observe(\.titleVisibility, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.updateWindowTitleVisibility() }
        }
    }

    private var manageIDs: [NSToolbarItem.Identifier] { [addShowID, importID] }

    private enum BackPage {
        case person(String)
        case discovery(String)

        var title: String {
            switch self {
            case .person(let name), .discovery(let name): name
            }
        }

        var tooltip: String {
            switch self {
            case .person: "Back to previous page"
            case .discovery: "Back to New"
            }
        }
    }

    private var backPage: BackPage? {
        guard library.mode == .listen else { return nil }
        if let person = library.personEpisodes { return .person(person) }
        if library.listenSelection == .new, library.listenSearch.isEmpty,
           let preview = DiscoveryRoute.shared.preview { return .discovery(preview.title) }
        return nil
    }

    /// The normal NSWindow title is shown for pages without a native inline Back button.
    var hasInlineBackTitle: Bool { backPage != nil }

    private func updateWindowTitleVisibility() {
        guard isActive, let window, window.toolbar === toolbar else { return }
        let wanted: NSWindow.TitleVisibility = hasInlineBackTitle ? .hidden : .visible
        if window.titleVisibility != wanted { window.titleVisibility = wanted }
    }

    /// Shut down observation and AppKit callbacks before the owner/window is torn down.
    func stopObserving() {
        isActive = false
        titleVisibilityWatch?.invalidate()
        titleVisibilityWatch = nil
        toolbar.delegate = nil
        searchItem?.searchField.delegate = nil
        searchItem?.searchField.target = nil
        modeControl?.target = nil
        for item in items.values { item.target = nil }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        var ids: [NSToolbarItem.Identifier] = [.toggleSidebar]
        if splitView != nil { ids.append(separatorID) }
        return ids + [backID, backTitleID, .flexibleSpace, modeID, .flexibleSpace] + manageIDs + [searchID]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item: NSToolbarItem
        switch id {
        case separatorID:
            guard let split = splitView else { return nil }
            item = NSTrackingSeparatorToolbarItem(identifier: id, splitView: split, dividerIndex: 0)
        case backID:
            item = button(id, "Back", "chevron.left", "Return to the previous page", #selector(goBack))
            item.visibilityPriority = .high
            backItem = item
        case backTitleID:
            let label = NSTextField(labelWithString: "")
            label.font = .systemFont(ofSize: 14, weight: .semibold)
            label.textColor = .labelColor
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            // A fixed width prevents an episode/show title changing the toolbar's constraints.
            label.frame = NSRect(x: 0, y: 0, width: 230, height: 26)
            backTitleLabel = label
            item = NSToolbarItem(itemIdentifier: id)
            item.view = label
            item.label = "Page Title"
            item.visibilityPriority = .high
            backTitleItem = item
        case modeID:
            let control = NSSegmentedControl()
            control.segmentCount = AppMode.allCases.count
            control.trackingMode = .selectOne
            for (i, m) in AppMode.allCases.enumerated() {
                control.setLabel(m.title, forSegment: i)
                control.setImage(NSImage(systemSymbolName: m.symbol, accessibilityDescription: m.title), forSegment: i)
                control.setImageScaling(.scaleProportionallyDown, forSegment: i)
                control.setWidth(0, forSegment: i)
            }
            control.target = self
            control.action = #selector(modeChanged(_:))
            control.toolTip = "Manage your feeds, or just listen"
            control.sizeToFit()
            modeControl = control
            item = NSToolbarItem(itemIdentifier: id)
            item.view = control
            item.label = "Mode"
            item.visibilityPriority = .high
        case addShowID:
            item = button(id, "Add Show", "plus", "Add a show: search or paste a link", #selector(addShow))
        case importID:
            item = button(id, "Import Media Files…", "square.and.arrow.down", "Add your own audio and video files", #selector(importFiles))
        case searchID:
            let search = NSSearchToolbarItem(itemIdentifier: id)
            search.searchField.placeholderString = "Search All Episodes"
            search.searchField.delegate = self
            search.searchField.sendsSearchStringImmediately = true
            search.searchField.target = self
            search.searchField.action = #selector(searchChanged(_:))
            search.preferredWidthForSearchField = 220
            search.label = "Search"
            searchItem = search
            item = search
        default:
            return nil
        }
        items[id] = item
        refresh()
        return item
    }

    private func button(_ id: NSToolbarItem.Identifier, _ label: String, _ symbol: String, _ tip: String,
                        _ action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = label
        item.toolTip = tip
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.isBordered = true
        item.target = self
        item.action = action
        return item
    }

    // MARK: Actions

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        let modes = AppMode.allCases
        guard modes.indices.contains(sender.selectedSegment) else { return }
        library.setMode(modes[sender.selectedSegment])
    }

    @objc private func addShow() {
        library.addShowTargetFeed = nil
        library.showAddShow = true
    }

    @objc private func importFiles() { ManageDetail.importFiles(into: library) }

    @objc private func searchChanged(_ sender: NSSearchField) {
        if library.listenSearch != sender.stringValue { library.listenSearch = sender.stringValue }
    }

    @objc private func goBack() {
        switch backPage {
        case .person:
            library.goBackFromPersonEpisodes()
        case .discovery:
            DiscoveryRoute.shared.preview = nil
        case nil:
            break
        }
    }

    func controlTextDidChange(_ note: Notification) {
        if let field = note.object as? NSSearchField { searchChanged(field) }
    }

    // MARK: Keeping it current (show / hide only; never add or remove items)

    private func refresh() {
        guard isActive else { return }
        let manage = library.mode == .manage
        if let control = modeControl, let i = AppMode.allCases.firstIndex(of: library.mode), control.selectedSegment != i {
            control.selectedSegment = i
        }
        for id in manageIDs { items[id]?.isHidden = !manage }
        searchItem?.isHidden = manage
        let page = backPage
        let showBack = page != nil
        backItem?.isHidden = !showBack
        backTitleItem?.isHidden = !showBack
        backItem?.toolTip = page?.tooltip
        backTitleLabel?.stringValue = page?.title ?? ""
        updateWindowTitleVisibility()
        if let field = searchItem?.searchField, field.stringValue != library.listenSearch {
            field.stringValue = library.listenSearch
        }
    }

    private func watch() {
        guard isActive else { return }
        withObservationTracking {
            _ = library.mode
            _ = library.listenSearch
            _ = library.listenSelection
            _ = library.personEpisodes
            _ = DiscoveryRoute.shared.preview
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isActive else { return }
                self.refresh()
                self.watch()
            }
        }
    }
}
