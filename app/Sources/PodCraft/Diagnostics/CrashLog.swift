import Foundation
import AppKit
import Synchronization

/// A small diagnostic log for troubleshooting crashes: ~/Library/Logs/PodCraft/PodCraft.log.
/// It records what the app was doing (window resizes, mode, cinema and panel changes) and, on the next launch,
/// copies the reason and first lines of macOS's crash report for the last crash. Kept to the last ~2 MB.
enum CrashLog {
    static let folder: URL = {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/PodCraft", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
    static var file: URL { folder.appendingPathComponent("PodCraft.log") }
    private static let queue = DispatchQueue(label: "PodCraft.CrashLog")
    private static let enabledFlag = Mutex(true)
    static var enabled: Bool {
        get { enabledFlag.withLock { $0 } }
        set { enabledFlag.withLock { $0 = newValue } }
    }

    static func note(_ message: String) {
        guard enabled else { return }
        let line = "\(Date().formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))) \(message)\n"
        queue.async {
            let url = file
            if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
            guard let h = try? FileHandle(forWritingTo: url) else { return }
            defer { try? h.close() }
            let size = (try? h.seekToEnd()) ?? 0
            if size > 2_000_000 {
                // Keep the newer half.
                try? h.close()
                if let data = try? Data(contentsOf: url) {
                    try? data.suffix(1_000_000).write(to: url, options: .atomic)
                }
                if let h2 = try? FileHandle(forWritingTo: url) { _ = try? h2.seekToEnd(); try? h2.write(contentsOf: Data(line.utf8)); try? h2.close() }
                return
            }
            try? h.write(contentsOf: Data(line.utf8))
        }
    }

    /// Call at launch: notes the start, reports an unclean previous exit with macOS's crash reason, and installs
    /// a handler that writes any uncaught exception (reason + stack) before the app stops.
    static func start() {
        let defaults = UserDefaults.standard
        let wasRunning = defaults.bool(forKey: "crashLogRunning")
        note("=== launch \(Bundle.main.bundlePath) macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        if wasRunning {
            note("previous run did not quit normally (crash or force quit)")
            reportLatestCrash()
        }
        defaults.set(true, forKey: "crashLogRunning")
        NSSetUncaughtExceptionHandler { e in
            CrashLog.note("UNCAUGHT \(e.name.rawValue): \(e.reason ?? "")\n" + e.callStackSymbols.prefix(40).joined(separator: "\n"))
            CrashLog.flush()
        }
    }

    static func cleanExit() {
        note("=== quit")
        UserDefaults.standard.set(false, forKey: "crashLogRunning")
        flush()
    }

    static func flush() { queue.sync {} }

    /// The newest PodCraft crash report from macOS: its time, reason and the top of the stack that raised it.
    private static func reportLatestCrash() {
        let reports = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: reports.path) else { return }
        let ips = names.filter { $0.hasPrefix("PodCraft") && $0.hasSuffix(".ips") }.sorted()
        guard let latest = ips.last, let text = try? String(contentsOf: reports.appendingPathComponent(latest), encoding: .utf8),
              let body = text.split(separator: "\n", maxSplits: 1).last,
              let json = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any] else { return }
        var summary = "crash report \(latest)"
        if let t = json["captureTime"] as? String { summary += " at \(t)" }
        if let ex = json["exception"] as? [String: Any] { summary += " \(ex["type"] ?? "") \(ex["signal"] ?? "")" }
        if let asi = (json["asiBacktraces"] as? [String])?.first {
            summary += "\n" + asi.split(separator: "\n").prefix(30).joined(separator: "\n")
        }
        note(summary)
    }
}
