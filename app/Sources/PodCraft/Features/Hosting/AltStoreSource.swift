import Foundation

/// The PodCraft iPhone app, hosted by this Mac as an AltStore-format source, so it installs (and updates) with
/// LiveContainer, SideStore or AltStore, over your Tailscale network or Wi-Fi:
///
///   GET /altstore/              an install page for the iPhone's Safari (Install with LiveContainer, add the source…)
///   GET /altstore/source.json   the source: PodCraft with its latest version, build number and download link
///   GET /altstore/PodCraft.ipa  the app itself
///   GET /altstore/icon.png      its icon
///
/// The .ipa comes from `sh iOS/build-ios.sh ipa`, bundled into the Mac app when it's packaged.
enum IPhoneRelease {
    struct Info: Decodable {
        var version: String
        var build: String
        var date: String
        var size: Int
        var minOSVersion: String
        var signed: Bool?
        var bundleIdentifier: String?
    }

    static var folder: URL? { Bundle.main.resourceURL?.appendingPathComponent("iPhone", isDirectory: true) }
    static var ipa: URL? {
        guard let url = folder?.appendingPathComponent("PodCraft.ipa"), FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }
    static var icon: URL? { Bundle.main.resourceURL?.appendingPathComponent("logo.png") }

    static var info: Info? {
        guard let url = folder?.appendingPathComponent("PodCraft-release.json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Info.self, from: data)
    }

    static let tint = "00A99D"
    static let summary = "Listen to the shows on your Mac, cleaned of sponsors, with chapters and transcripts."

    static func sourceURL(base: String) -> String { "\(base)/altstore/source.json" }
    static func ipaURL(base: String) -> String { "\(base)/altstore/PodCraft.ipa" }
    static func pageURL(base: String) -> String { "\(base)/altstore/" }

    /// LiveContainer installs straight from the .ipa link.
    static func liveContainerURL(base: String) -> String {
        "livecontainer://install?url=" + (ipaURL(base: base).addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")
    }
    static func addSourceURL(app: String, base: String) -> String {
        "\(app)://source?url=" + (sourceURL(base: base).addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")
    }

    static func source(base: String) -> Data {
        var app: [String: Any] = [
            "name": "PodCraft",
            "bundleIdentifier": info?.bundleIdentifier ?? "app.podcraft.ios",
            "developerName": "PodCraft",
            "subtitle": "Your Mac’s podcasts, on your iPhone",
            "localizedDescription": summary + " Plays from PodCraft on your Mac over Tailscale or your Wi-Fi.",
            "iconURL": "\(base)/altstore/icon.png",
            "tintColor": tint,
            "category": "entertainment",
            "screenshots": [String](),
            "appPermissions": [
                "entitlements": [String](),
                "privacy": ["NSLocalNetworkUsageDescription": "PodCraft plays the shows from PodCraft on your Mac over your network."],
            ] as [String: Any],
        ]
        if let info {
            let version: [String: Any] = [
                "version": info.version,
                "buildVersion": info.build,
                "date": info.date,
                "localizedDescription": "PodCraft \(info.version) (\(info.build)).",
                "downloadURL": ipaURL(base: base),
                "size": info.size,
                "minOSVersion": info.minOSVersion,
            ]
            app["versions"] = [version]
            // Older AltStore and LiveContainer read these single-version fields.
            app["version"] = info.version
            app["versionDate"] = info.date
            app["versionDescription"] = version["localizedDescription"]
            app["downloadURL"] = ipaURL(base: base)
            app["size"] = info.size
        } else {
            app["versions"] = [[String: Any]]()
        }
        let body: [String: Any] = [
            "name": "PodCraft",
            "identifier": "app.podcraft.source",
            "subtitle": "Hosted by PodCraft on your Mac",
            "description": summary,
            "iconURL": "\(base)/altstore/icon.png",
            "website": pageURL(base: base),
            "tintColor": tint,
            "apps": [app],
            "news": [[String: Any]](),
        ]
        return (try? JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .withoutEscapingSlashes])) ?? Data("{}".utf8)
    }

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// The page to open on the iPhone (scan its QR code in the Mac's Settings → iPhone).
    static func page(base: String) -> Data {
        let detail = info.map { "Version \(esc($0.version)) (\(esc($0.build))) · \(ByteCountFormatter.string(fromByteCount: Int64($0.size), countStyle: .file))" }
            ?? "No iPhone build yet: run <code>sh iOS/build-ios.sh ipa</code>, then rebuild the Mac app."
        let buttons = info == nil ? "" : """
        <a class="b primary" href="\(esc(liveContainerURL(base: base)))">Install with LiveContainer</a>
        <a class="b" href="\(esc(addSourceURL(app: "sidestore", base: base)))">Add Source to SideStore</a>
        <a class="b" href="\(esc(addSourceURL(app: "altstore", base: base)))">Add Source to AltStore</a>
        <a class="b" href="\(esc(ipaURL(base: base)))">Download .ipa</a>
        """
        let html = """
        <!doctype html><html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>PodCraft for iPhone</title>
        <style>
        :root { color-scheme: light dark; --tint: #\(tint); }
        body { font: -apple-system-body; font-family: -apple-system, system-ui; margin: 0; padding: 32px 22px; text-align: center; }
        img { width: 112px; height: 112px; border-radius: 26px; box-shadow: 0 10px 30px rgba(0,0,0,.2); }
        h1 { font-size: 30px; margin: 18px 0 6px; } p { color: #888; margin: 6px 0 22px; }
        .b { display: block; max-width: 380px; margin: 10px auto; padding: 14px; border-radius: 14px; text-decoration: none;
             font-weight: 600; color: var(--tint); background: rgba(0,169,157,.12); }
        .b.primary { color: white; background: var(--tint); }
        code, .src { font-family: ui-monospace, monospace; font-size: 13px; word-break: break-all; }
        .src { color: #888; margin-top: 26px; }
        </style></head><body>
        <img src="icon.png" alt="">
        <h1>PodCraft for iPhone</h1>
        <p>\(esc(summary))<br>\(detail)</p>
        \(buttons)
        <div class="src">Source: \(esc(sourceURL(base: base)))</div>
        </body></html>
        """
        return Data(html.utf8)
    }
}

/// Tailscale Serve: puts the feed server behind https://<this-mac>.<tailnet>.ts.net (a real certificate,
/// only reachable on your tailnet). Needs HTTPS Certificates turned on in Tailscale's admin console (DNS).
enum TailscaleServe {
    static var tool: String? {
        ["/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    struct Status: Equatable {
        var certificatesOn: Bool
        var serving: Bool
        var httpsHost: String?
    }

    private static func run(_ args: [String], timeout: TimeInterval = 15) -> (Int32, Data)? {
        guard let tool else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        do { try p.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if p.isRunning { p.terminate(); return nil }
        return (p.terminationStatus, out.fileHandleForReading.readDataToEndOfFile())
    }

    /// Whether certificates are on, and whether this Mac already serves the feed server's port over HTTPS.
    static func status(port: Int) -> Status? {
        guard let (_, data) = run(["status", "--json", "--peers=false"]),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let certs = (json["CertDomains"] as? [String]) ?? []
        var serving = false
        if let (_, serve) = run(["serve", "status", "--json"]), let text = String(data: serve, encoding: .utf8) {
            serving = text.contains("127.0.0.1:\(port)") || text.contains("localhost:\(port)")
        }
        return Status(certificatesOn: !certs.isEmpty, serving: serving, httpsHost: certs.first)
    }

    /// `tailscale serve --bg <port>`: https://<name>.ts.net forwards to this Mac's feed server.
    static func enable(port: Int) -> String? {
        guard let (code, data) = run(["serve", "--bg", "--yes", "\(port)"], timeout: 30) else { return "Tailscale isn’t installed." }
        return code == 0 ? nil : (String(data: data, encoding: .utf8) ?? "Tailscale refused.").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func disable() -> String? {
        // Only PodCraft's HTTPS entry; any other Serve settings stay.
        guard let (code, data) = run(["serve", "--https=443", "off"], timeout: 30) else { return "Tailscale isn’t installed." }
        return code == 0 ? nil : String(data: data, encoding: .utf8)
    }
}
