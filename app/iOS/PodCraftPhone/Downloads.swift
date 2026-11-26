import Foundation
import Observation
import SwiftUI
import UIKit

/// Episodes saved on the phone, to play with no connection.
/// Files download in a background URLSession, so they keep going when PodCraft is closed, and live in
/// Application Support/Downloads (not backed up, and not purged by iOS like Caches).
@MainActor
@Observable
final class Downloads {
    static let shared = Downloads()

    struct Record: Codable, Hashable {
        /// The episode as it was when downloaded, so the download still shows if the show drops it from its feed.
        var episode: RemoteEpisode
        var file: String
        var bytes: Int64
        var downloadedAt: Date
        /// Already played when downloaded: "Delete When Played" waits until it's unplayed and played again.
        var wasPlayed: Bool
    }

    struct Active: Hashable {
        var episode: RemoteEpisode
        var written: Int64 = 0
        var expected: Int64 = 0
        var error: String?

        var fraction: Double? { expected > 0 ? min(1, Double(written) / Double(expected)) : nil }
    }

    enum State: Equatable {
        case none
        case downloading(Double?)
        case failed(String)
        case downloaded
    }

    private(set) var records: [String: Record] = [:]
    private(set) var active: [String: Active] = [:]

    /// Removes a download once its episode is played.
    var deletePlayed: Bool { didSet { defaults.set(deletePlayed, forKey: "downloadsDeletePlayed") } }
    /// Downloads over cellular data too (otherwise they wait for Wi-Fi).
    var allowCellular: Bool { didSet { defaults.set(allowCellular, forKey: "downloadsAllowCellular") } }

    /// iOS hands this over when it wakes PodCraft for finished background downloads.
    @ObservationIgnored static var backgroundCompletion: (() -> Void)?

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var tasks: [String: URLSessionDownloadTask] = [:]
    @ObservationIgnored private let session: URLSession

    private init() {
        let c = URLSessionConfiguration.background(withIdentifier: "app.podcraft.ios.downloads")
        c.sessionSendsLaunchEvents = true
        c.isDiscretionary = false
        c.timeoutIntervalForRequest = 60
        session = URLSession(configuration: c, delegate: DownloadDelegate(), delegateQueue: nil)
        deletePlayed = defaults.object(forKey: "downloadsDeletePlayed") as? Bool ?? true
        allowCellular = defaults.object(forKey: "downloadsAllowCellular") as? Bool ?? true
        loadIndex()
        reattach()
    }

    // MARK: Reading

    func state(of e: RemoteEpisode) -> State {
        if records[e.id] != nil { return .downloaded }
        guard let a = active[e.id] else { return .none }
        if let error = a.error { return .failed(error) }
        return .downloading(a.fraction)
    }

    func isDownloaded(_ e: RemoteEpisode) -> Bool { records[e.id] != nil }

    /// The file to play instead of streaming, when the episode is downloaded.
    func localURL(for e: RemoteEpisode) -> URL? {
        guard let r = records[e.id] else { return nil }
        let url = DownloadFiles.directory.appendingPathComponent(r.file)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    var totalBytes: Int64 { records.values.reduce(0) { $0 + $1.bytes } }

    var summary: String {
        let n = records.count
        return "\(n) episode\(n == 1 ? "" : "s") · \(DownloadFiles.size(totalBytes))"
    }

    /// Downloaded episodes, newest download first, with the library's current details where it still lists them.
    func episodes(in store: Store) -> [RemoteEpisode] {
        let live = Dictionary(store.allEpisodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return records.values.sorted { $0.downloadedAt > $1.downloadedAt }.map { live[$0.episode.id] ?? $0.episode }
    }

    /// Downloading or failed, oldest first.
    var inProgress: [Active] { active.values.sorted { $0.episode.title < $1.episode.title } }

    // MARK: Changing

    func download(_ e: RemoteEpisode, played: Bool = false) {
        guard records[e.id] == nil else { return }
        tasks[e.id]?.cancel()
        var request = URLRequest(url: e.media)
        request.allowsCellularAccess = allowCellular
        let task = session.downloadTask(with: request)
        task.taskDescription = e.id
        tasks[e.id] = task
        active[e.id] = Active(episode: e)
        pendingPlayed[e.id] = played
        saveIndex()
        task.resume()
    }

    /// Stops a download, or clears a failed one.
    func cancel(_ e: RemoteEpisode) {
        tasks.removeValue(forKey: e.id)?.cancel()
        active[e.id] = nil
        pendingPlayed[e.id] = nil
        saveIndex()
    }

    func remove(_ e: RemoteEpisode) { remove(id: e.id) }

    func removeAll() {
        for id in Array(records.keys) { remove(id: id, save: false) }
        saveIndex()
    }

    private func remove(id: String, save: Bool = true) {
        guard let r = records.removeValue(forKey: id) else { return }
        try? FileManager.default.removeItem(at: DownloadFiles.directory.appendingPathComponent(r.file))
        if save { saveIndex() }
    }

    /// "Delete When Played": drops downloads played since they were saved (not the one playing now).
    func cleanUp(store: Store, playing: String?) {
        let live = Dictionary(store.allEpisodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var changed = false
        for (id, r) in records {
            let played = store.isPlayed(live[id] ?? r.episode)
            if !played, r.wasPlayed {
                records[id]?.wasPlayed = false
                changed = true
            } else if deletePlayed, played, !r.wasPlayed, id != playing {
                remove(id: id, save: false)
                changed = true
            }
        }
        if changed { saveIndex() }
    }

    // MARK: From the URL session

    fileprivate func progress(_ id: String, written: Int64, expected: Int64) {
        guard var a = active[id] else { return }
        a.written = written
        a.expected = expected
        a.error = nil
        active[id] = a
    }

    fileprivate func finished(_ id: String, file: String, bytes: Int64) {
        tasks[id] = nil
        guard let a = active.removeValue(forKey: id) else {
            // Cancelled meanwhile.
            try? FileManager.default.removeItem(at: DownloadFiles.directory.appendingPathComponent(file))
            return
        }
        records[id] = Record(episode: a.episode, file: file, bytes: bytes, downloadedAt: Date(),
                             wasPlayed: pendingPlayed.removeValue(forKey: id) ?? false)
        saveIndex()
    }

    fileprivate func failed(_ id: String, _ message: String) {
        tasks[id] = nil
        guard active[id] != nil else { return }
        active[id]?.error = message
        saveIndex()
    }

    // MARK: Keeping the list

    private struct Index: Codable {
        var records: [Record]
        var pending: [RemoteEpisode]
        var pendingPlayed: [String: Bool]?
    }

    @ObservationIgnored private var pendingPlayed: [String: Bool] = [:]

    private static let indexURL = DownloadFiles.directory.appendingPathComponent("Downloads.json")

    private func loadIndex() {
        guard let data = try? Data(contentsOf: Self.indexURL),
              let index = try? DownloadFiles.decoder.decode(Index.self, from: data) else { return }
        let fm = FileManager.default
        for r in index.records where fm.fileExists(atPath: DownloadFiles.directory.appendingPathComponent(r.file).path) {
            records[r.episode.id] = r
        }
        for e in index.pending where records[e.id] == nil { active[e.id] = Active(episode: e) }
        pendingPlayed = index.pendingPlayed ?? [:]
    }

    private func saveIndex() {
        // Failed downloads aren't kept across launches.
        let index = Index(records: Array(records.values),
                          pending: active.values.filter { $0.error == nil }.map(\.episode),
                          pendingPlayed: pendingPlayed)
        try? DownloadFiles.encoder.encode(index).write(to: Self.indexURL, options: .atomic)
    }

    /// Finds the downloads the background session kept going while PodCraft wasn't running.
    private func reattach() {
        session.getAllTasks { all in
            let running = all.compactMap { $0 as? URLSessionDownloadTask }
                .filter { $0.taskDescription != nil && $0.state != .completed }
            Task { @MainActor in
                let shared = Downloads.shared
                for task in running {
                    guard let id = task.taskDescription else { continue }
                    if shared.active[id] == nil { task.cancel(); continue }
                    shared.tasks[id] = task
                    shared.progress(id, written: task.countOfBytesReceived, expected: task.countOfBytesExpectedToReceive)
                }
                // Pending downloads iOS no longer has a task for: offer to try again.
                for id in shared.active.keys where shared.tasks[id] == nil && shared.active[id]?.error == nil {
                    shared.active[id]?.error = "The download stopped."
                }
            }
        }
    }
}

/// Paths and helpers the URL session's delegate uses off the main thread.
enum DownloadFiles {
    static let directory: URL = {
        var dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        return dir
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    /// AVPlayer needs a real extension to play a local file.
    static func fileExtension(response: URLResponse?, url: URL?) -> String {
        let known = ["mp3", "m4a", "mp4", "m4v", "mov", "aac", "wav", "aif", "aiff", "caf", "ogg", "opus"]
        if let ext = url?.pathExtension.lowercased(), known.contains(ext) { return ext }
        if let ext = response?.suggestedFilename.map({ ($0 as NSString).pathExtension.lowercased() }), known.contains(ext) { return ext }
        switch response?.mimeType?.lowercased() ?? "" {
        case let m where m.contains("mp4") && m.hasPrefix("video"): return "mp4"
        case let m where m.contains("quicktime"): return "mov"
        case let m where m.contains("mp4") || m.contains("m4a") || m.contains("aac"): return "m4a"
        case let m where m.contains("wav"): return "wav"
        default: return "mp3"
        }
    }

    static func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    /// Last whole percent sent to the main thread, by episode (only touched on the session's serial queue).
    private var lastPercent: [String: Int] = [:]

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription else { return }
        let percent = totalBytesExpectedToWrite > 0 ? Int(totalBytesWritten * 100 / totalBytesExpectedToWrite)
                                                    : Int(totalBytesWritten / 1_000_000)
        guard lastPercent[id] != percent else { return }
        lastPercent[id] = percent
        Task { @MainActor in Downloads.shared.progress(id, written: totalBytesWritten, expected: totalBytesExpectedToWrite) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription else { return }
        lastPercent[id] = nil
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 200
        guard (200..<300).contains(status) else {
            Task { @MainActor in Downloads.shared.failed(id, "The server answered with an error (\(status)).") }
            return
        }
        // The file must be moved before this returns.
        let ext = DownloadFiles.fileExtension(response: downloadTask.response, url: downloadTask.originalRequest?.url)
        let name = Hash.short(id, length: 32) + "." + ext
        let dest = DownloadFiles.directory.appendingPathComponent(name)
        let fm = FileManager.default
        try? fm.removeItem(at: dest)
        do {
            try fm.moveItem(at: location, to: dest)
        } catch {
            Task { @MainActor in Downloads.shared.failed(id, "There isn’t room to save it.") }
            return
        }
        let bytes = ((try? fm.attributesOfItem(atPath: dest.path))?[.size] as? NSNumber)?.int64Value ?? 0
        Task { @MainActor in Downloads.shared.finished(id, file: name, bytes: bytes) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let id = task.taskDescription else { return }
        lastPercent[id] = nil
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
        let message = ns.domain == NSURLErrorDomain && ns.code == NSURLErrorNotConnectedToInternet
            ? "You’re offline." : "The download failed."
        Task { @MainActor in Downloads.shared.failed(id, message) }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            Downloads.backgroundCompletion?()
            Downloads.backgroundCompletion = nil
        }
    }
}

/// Lets iOS wake PodCraft to finish background downloads.
final class PodCraftAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        Downloads.backgroundCompletion = completionHandler
        _ = Downloads.shared
    }
}

// MARK: - Views

/// The small button beside an episode's play button: download, progress (tap to stop), or downloaded.
struct DownloadButton: View {
    @Environment(Store.self) private var store
    @Environment(Downloads.self) private var downloads
    let episode: RemoteEpisode

    var body: some View {
        switch downloads.state(of: episode) {
        case .none:
            button("arrow.down", label: "Download") { downloads.download(episode, played: store.isPlayed(episode)) }
        case .downloading(let fraction):
            Button { downloads.cancel(episode) } label: {
                ZStack {
                    Circle().stroke(Color.secondary.opacity(0.3), lineWidth: 2.5)
                    if let fraction {
                        Circle().trim(from: 0, to: max(0.03, fraction))
                            .stroke(Color.podTeal, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .animation(.linear(duration: 0.2), value: fraction)
                    } else {
                        ProgressView().controlSize(.mini)
                    }
                    Image(systemName: "stop.fill").font(.system(size: 7, weight: .bold)).foregroundStyle(Color.podTeal)
                }
                .frame(width: 18, height: 18)
                .padding(7)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel(fraction.map { "Downloading, \(Int($0 * 100)) percent. Stop" } ?? "Downloading. Stop")
        case .failed(let message):
            button("exclamationmark.arrow.circlepath", label: "Download failed: \(message) Try again", tint: .orange) {
                downloads.download(episode, played: store.isPlayed(episode))
            }
        case .downloaded:
            Menu {
                Button("Remove Download", systemImage: "trash", role: .destructive) { downloads.remove(episode) }
            } label: {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.podTeal)
                    .frame(width: 18, height: 18).padding(7)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel("Downloaded")
        }
    }

    private func button(_ symbol: String, label: String, tint: Color = .primary, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold)).foregroundStyle(tint)
                .frame(width: 18, height: 18).padding(7)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .accessibilityLabel(label)
    }
}

/// Download items for an episode's context menu.
struct DownloadMenuItems: View {
    @Environment(Store.self) private var store
    @Environment(Downloads.self) private var downloads
    let episode: RemoteEpisode

    var body: some View {
        switch downloads.state(of: episode) {
        case .none, .failed:
            Button("Download", systemImage: "arrow.down.circle") { downloads.download(episode, played: store.isPlayed(episode)) }
        case .downloading:
            Button("Stop Download", systemImage: "stop.circle") { downloads.cancel(episode) }
        case .downloaded:
            Button("Remove Download", systemImage: "trash", role: .destructive) { downloads.remove(episode) }
        }
    }
}

/// The Downloads page (Browse › Downloads): what's downloading, then what's on the phone.
struct DownloadsList: View {
    @Environment(Store.self) private var store
    @Environment(Downloads.self) private var downloads
    @State private var confirmRemoveAll = false

    var body: some View {
        let episodes = downloads.episodes(in: store)
        VStack(alignment: .leading, spacing: 0) {
            if !downloads.inProgress.isEmpty {
                Text("Downloading").font(.title3.bold()).padding(.horizontal).padding(.top, 8)
                LazyVStack(spacing: 0) {
                    ForEach(downloads.inProgress, id: \.episode.id) { a in
                        DownloadingRow(active: a)
                        Divider().padding(.leading)
                    }
                }
            }
            if episodes.isEmpty {
                if downloads.inProgress.isEmpty {
                    ContentUnavailableView("No Downloads", systemImage: "arrow.down.circle",
                                           description: Text("Download episodes to listen without a connection. Tap \(Image(systemName: "arrow.down")) beside an episode."))
                        .padding(.top, 60)
                }
            } else {
                HStack {
                    Text(downloads.summary).font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    Button("Remove All", role: .destructive) { confirmRemoveAll = true }
                        .font(.subheadline)
                }
                .padding(.horizontal).padding(.top, 12).padding(.bottom, 4)
                EpisodeStack(episodes: episodes)
            }
        }
        .confirmationDialog("Remove all downloaded episodes?", isPresented: $confirmRemoveAll, titleVisibility: .visible) {
            Button("Remove \(downloads.records.count) Download\(downloads.records.count == 1 ? "" : "s")", role: .destructive) {
                downloads.removeAll()
            }
        } message: {
            Text("This frees \(DownloadFiles.size(downloads.totalBytes)). They stay in your library to stream.")
        }
    }
}

private struct DownloadingRow: View {
    @Environment(Store.self) private var store
    @Environment(Downloads.self) private var downloads
    let active: Downloads.Active

    var body: some View {
        let e = active.episode
        HStack(spacing: 12) {
            Artwork(url: e.artwork ?? store.show(e.showID)?.artwork, size: 48, radius: 8)
            VStack(alignment: .leading, spacing: 4) {
                Text(e.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                if let error = active.error {
                    Text(error).font(.caption).foregroundStyle(.orange)
                } else {
                    ProgressView(value: active.fraction ?? 0).tint(.podTeal)
                    Text(active.expected > 0 ? "\(DownloadFiles.size(active.written)) of \(DownloadFiles.size(active.expected))"
                                             : active.written > 0 ? DownloadFiles.size(active.written) : "Waiting…")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            if active.error != nil {
                Button("Retry", systemImage: "arrow.clockwise") { downloads.download(e, played: store.isPlayed(e)) }
                    .labelStyle(.iconOnly)
            }
            Button("Stop", systemImage: "xmark.circle.fill") { downloads.cancel(e) }
                .labelStyle(.iconOnly).foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal)
        .padding(.vertical, 10)
    }
}

/// Settings › Downloads.
struct DownloadsSettingsSection: View {
    @Environment(Downloads.self) private var downloads
    @State private var confirmRemoveAll = false

    var body: some View {
        @Bindable var d = downloads
        Section {
            LabeledContent("On This iPhone", value: downloads.records.isEmpty ? "None" : downloads.summary)
            Toggle("Delete When Played", isOn: $d.deletePlayed)
            Toggle("Use Cellular Data", isOn: $d.allowCellular)
            if !downloads.records.isEmpty {
                Button("Remove All Downloads", role: .destructive) { confirmRemoveAll = true }
            }
        } header: {
            Text("Downloads")
        } footer: {
            Text("Downloaded episodes play without a connection. Downloads keep going in the background.")
        }
        .confirmationDialog("Remove all downloaded episodes?", isPresented: $confirmRemoveAll, titleVisibility: .visible) {
            Button("Remove All Downloads", role: .destructive) { downloads.removeAll() }
        }
    }
}
