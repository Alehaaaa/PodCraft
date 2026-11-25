import Foundation
import Network
import Observation

/// This Mac's address on your Tailscale network (tailnet), so podcast apps on your phone or other computers can
/// reach PodCraft's feeds from anywhere, not just on the same Wi-Fi.
///
/// Tailscale gives each device an address in 100.64.0.0/10 on a utun interface, and with MagicDNS a name such as
/// `my-mac.tailnet-name.ts.net`. The feed server already listens on every interface, so it answers on that
/// address as is; this finds the address so the links PodCraft hands out use it. Nothing is sent to Tailscale.
@MainActor
@Observable
final class TailscaleInfo {
    static let shared = TailscaleInfo()

    /// The Tailscale IPv4 address (100.x.y.z), when Tailscale is connected on this Mac.
    private(set) var address: String?
    /// The MagicDNS name (without the trailing dot), when Tailscale reports one.
    private(set) var dnsName: String?

    /// The best host for links: the MagicDNS name, else the address.
    var host: String? { dnsName ?? address }

    /// Tailscale Serve for the feed server: whether HTTPS certificates are on and PodCraft is served over HTTPS.
    private(set) var serve: TailscaleServe.Status?

    /// https://<name>.ts.net when Tailscale Serve forwards to the feed server.
    var httpsBase: String? {
        guard let serve, serve.serving, let host = serve.httpsHost else { return nil }
        return "https://\(host)"
    }

    func refreshServe(port: Int) {
        Task.detached(priority: .utility) {
            let status = TailscaleServe.status(port: port)
            await MainActor.run { TailscaleInfo.shared.serve = status }
        }
    }

    /// Turns HTTPS on or off; returns what Tailscale said when it refused.
    func setServe(_ on: Bool, port: Int) async -> String? {
        let error = await Task.detached(priority: .userInitiated) {
            on ? TailscaleServe.enable(port: port) : TailscaleServe.disable()
        }.value
        refreshServe(port: port)
        return error
    }
    var isConnected: Bool { address != nil }

    private var monitor: NWPathMonitor?
    private var refreshing = false

    private init() {}

    /// Look now, and again whenever the network changes (Tailscale connecting or disconnecting).
    func start() {
        guard monitor == nil else { return }
        let m = NWPathMonitor()
        m.pathUpdateHandler = { _ in Task { @MainActor in TailscaleInfo.shared.refresh() } }
        m.start(queue: .global(qos: .utility))
        monitor = m
        refresh()
    }

    func refresh() {
        let ip = Self.interfaceAddress()
        address = ip
        guard let ip else { dnsName = nil; return }
        guard !refreshing else { return }
        refreshing = true
        Task.detached(priority: .utility) {
            let name = Self.magicDNSNameFromCLI() ?? Self.reverseLookup(ip)
            await MainActor.run {
                TailscaleInfo.shared.dnsName = name
                TailscaleInfo.shared.refreshing = false
            }
        }
    }

    /// True for 100.64.0.0/10, Tailscale's (carrier-grade NAT) address range.
    nonisolated static func isTailscaleIPv4(_ text: String) -> Bool {
        let parts = text.split(separator: ".").compactMap { Int($0) }
        return parts.count == 4 && parts[0] == 100 && (64...127).contains(parts[1])
    }

    /// The first 100.64/10 IPv4 address on a running interface (Tailscale's utun).
    nonisolated static func interfaceAddress() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var found: String?
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  (ifa.ifa_flags & UInt32(IFF_UP)) != 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if isTailscaleIPv4(text) {
                let name = String(cString: ifa.ifa_name)
                // Prefer Tailscale's tunnel; keep any 100.64/10 address as a fallback.
                if name.hasPrefix("utun") { return text }
                found = found ?? text
            }
        }
        return found
    }

    /// `tailscale status --json` → Self.DNSName, from the Tailscale app's own command line (no network use).
    nonisolated static func magicDNSNameFromCLI() -> String? {
        let candidates = ["/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/usr/local/bin/tailscale",
                          "/opt/homebrew/bin/tailscale"]
        guard let tool = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = ["status", "--json", "--self=true", "--peers=false"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        // Never wait long: a stuck CLI just means no name.
        let deadline = Date().addingTimeInterval(4)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning { process.terminate(); return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let me = json["Self"] as? [String: Any],
              let name = me["DNSName"] as? String else { return nil }
        let trimmed = name.hasSuffix(".") ? String(name.dropLast()) : name
        return trimmed.isEmpty ? nil : trimmed
    }

    /// With MagicDNS on, the system resolver names Tailscale addresses (`*.ts.net`).
    nonisolated static func reverseLookup(_ ip: String) -> String? {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        guard inet_pton(AF_INET, ip, &addr.sin_addr) == 1 else { return nil }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, socklen_t(MemoryLayout<sockaddr_in>.size), &host, socklen_t(host.count), nil, 0, NI_NAMEREQD)
            }
        }
        guard result == 0 else { return nil }
        let name = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let trimmed = name.hasSuffix(".") ? String(name.dropLast()) : name
        return trimmed.hasSuffix(".ts.net") ? trimmed : nil
    }
}
