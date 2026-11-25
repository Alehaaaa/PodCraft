import Foundation
import Observation
import UIKit

/// Check for Updates: reads the AltStore source the Mac hosts (<server>/altstore/source.json), or without a Mac the
/// public one on GitHub, and when it has a newer build than this one installs it through LiveContainer (or opens
/// the install page).
@MainActor
@Observable
final class Updater {
    struct Release: Equatable {
        var version: String
        var build: String
        var downloadURL: URL
    }

    enum Result: Equatable {
        case upToDate, available(Release), unreachable, noRelease
    }

    private(set) var available: Release?
    private(set) var checking = false
    var lastResult: Result?

    static var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0" }
    static var currentBuild: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0" }

    private var lastAutomaticCheck = Date.distantPast

    /// Quietly, at most every few hours (on opening the app).
    func checkAutomatically(server: String) async {
        guard Date().timeIntervalSince(lastAutomaticCheck) > 3 * 3600 else { return }
        lastAutomaticCheck = Date()
        _ = await check(server: server)
    }

    /// Published by the GitHub Actions workflow on every release.
    static let publicSource = URL(string: "https://raw.githubusercontent.com/Alehaaaa/PodCraft/main/altstore.json")!
    static let publicPage = URL(string: "https://github.com/Alehaaaa/PodCraft")!

    @discardableResult
    func check(server: String) async -> Result {
        var fromMac: Result?
        if !server.isEmpty, let url = URL(string: "\(server)/altstore/source.json") {
            fromMac = await check(url)
            if case .available? = fromMac { return fromMac! }
        }
        let fromGitHub = await check(Self.publicSource)
        if fromGitHub == .unreachable || fromGitHub == .noRelease, fromMac == .upToDate {
            lastResult = .upToDate
            return .upToDate
        }
        return fromGitHub
    }

    private func check(_ url: URL) async -> Result {
        checking = true
        defer { checking = false }
        let result: Result
        do {
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 15
            let (data, _) = try await URLSession.shared.data(for: request)
            result = Self.parse(data)
        } catch {
            result = .unreachable
        }
        if case .available(let release) = result { available = release } else if result == .upToDate { available = nil }
        lastResult = result
        return result
    }

    /// Picks this app's newest version from an AltStore source.
    static func parse(_ data: Data) -> Result {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let apps = json["apps"] as? [[String: Any]],
              let app = apps.first(where: { ($0["bundleIdentifier"] as? String) == Bundle.main.bundleIdentifier }) ?? apps.first,
              let versions = app["versions"] as? [[String: Any]], let newest = versions.first,
              let version = newest["version"] as? String,
              let link = (newest["downloadURL"] as? String).flatMap(URL.init(string:)) else { return .noRelease }
        let build = newest["buildVersion"] as? String ?? "0"
        let newer = (Int(build) ?? 0) > (Int(currentBuild) ?? 0)
            || ((Int(build) == nil) && version.compare(currentVersion, options: .numeric) == .orderedDescending)
        return newer ? .available(Release(version: version, build: build, downloadURL: link)) : .upToDate
    }

    /// Hands the new .ipa to LiveContainer; without it, opens the Mac's install page in Safari.
    func install(_ release: Release, server: String) {
        let encoded = release.downloadURL.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        let page = server.isEmpty ? Self.publicPage : URL(string: "\(server)/altstore/")
        if let lc = URL(string: "livecontainer://install?url=\(encoded)") {
            UIApplication.shared.open(lc) { opened in
                if !opened, let page { Task { @MainActor in UIApplication.shared.open(page) } }
            }
        }
    }
}
