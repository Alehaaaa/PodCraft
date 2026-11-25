import Foundation
import Darwin

/// A plain TCP listener (BSD sockets) for the feed server, on every interface, IPv4 and IPv6.
///
/// Network.framework's NWListener never accepted connections arriving over Tailscale's tunnel (utun) on this
/// Mac, even when bound to the Tailscale address, while an ordinary socket server did. So the feed server
/// accepts with an ordinary socket and serves each connection through `SocketConnection`.
final class SocketListener: @unchecked Sendable {
    private let fd: Int32
    private let source: DispatchSourceRead
    private let queue = DispatchQueue(label: "PodCraft.FeedServer.accept")

    struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Starts listening on `port` on all addresses; each accepted connection is passed to `onAccept`.
    init(port: UInt16, onAccept: @escaping @Sendable (SocketConnection) -> Void) throws {
        let s = socket(AF_INET6, SOCK_STREAM, IPPROTO_TCP)
        guard s >= 0 else { throw Failure(message: String(cString: strerror(errno))) }
        var yes: Int32 = 1, no: Int32 = 0
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        // One socket for IPv6 and IPv4 (mapped) addresses.
        setsockopt(s, IPPROTO_IPV6, IPV6_V6ONLY, &no, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in6()
        addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        addr.sin6_family = sa_family_t(AF_INET6)
        addr.sin6_port = port.bigEndian
        addr.sin6_addr = in6addr_any
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
        }
        guard bound == 0, listen(s, 64) == 0 else {
            let message = String(cString: strerror(errno))
            close(s)
            throw Failure(message: message)
        }
        _ = fcntl(s, F_SETFL, fcntl(s, F_GETFL) | O_NONBLOCK)
        fd = s
        source = DispatchSource.makeReadSource(fileDescriptor: s, queue: queue)
        source.setEventHandler {
            while true {
                let client = accept(s, nil, nil)
                guard client >= 0 else { return }   // EAGAIN: nothing more waiting
                onAccept(SocketConnection(fd: client))
            }
        }
        source.setCancelHandler { close(s) }
        source.resume()
    }

    func cancel() { source.cancel() }
}

/// One accepted HTTP connection. Reads and writes happen on the connection's own serial queue; reads time out
/// after 30 seconds and writes after 60, so a stalled client can't hold the server.
final class SocketConnection: @unchecked Sendable {
    private let fd: Int32
    private let queue = DispatchQueue(label: "PodCraft.FeedServer.connection")
    private let lock = NSLock()
    private var closed = false
    private var closeHandlers: [@Sendable () -> Void] = []

    init(fd: Int32) {
        self.fd = fd
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        var readTimeout = timeval(tv_sec: 30, tv_usec: 0), writeTimeout = timeval(tv_sec: 60, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &readTimeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &writeTimeout, socklen_t(MemoryLayout<timeval>.size))
    }

    var isClosed: Bool { lock.withLock { closed } }

    /// Runs once when the connection closes (from either side).
    func onClose(_ handler: @escaping @Sendable () -> Void) {
        let runNow = lock.withLock { () -> Bool in
            if closed { return true }
            closeHandlers.append(handler)
            return false
        }
        if runNow { handler() }
    }

    /// Reads what's available (up to `maximumLength`). Empty data means the client closed; nil means an error.
    func receive(maximumLength: Int, _ completion: @escaping @Sendable (Data?) -> Void) {
        queue.async { [self] in
            guard !isClosed else { completion(nil); return }
            var buffer = [UInt8](repeating: 0, count: maximumLength)
            let n = recv(fd, &buffer, maximumLength, 0)
            if n > 0 { completion(Data(buffer[0..<n])) }
            else if n == 0 { completion(Data()) }
            else { completion(nil) }
        }
    }

    /// Writes all of `data`; the completion gets false if the client went away.
    func send(_ data: Data, _ completion: @escaping @Sendable (Bool) -> Void) {
        queue.async { [self] in
            guard !isClosed else { completion(false); return }
            var ok = true
            data.withUnsafeBytes { raw in
                guard var p = raw.baseAddress else { return }
                var left = raw.count
                while left > 0 {
                    let n = write(fd, p, left)
                    if n <= 0 {
                        if n < 0 && errno == EINTR { continue }
                        ok = false; return
                    }
                    left -= n
                    p = p.advanced(by: n)
                }
            }
            completion(ok)
        }
    }

    /// Closes the connection (any blocked read returns at once).
    func cancel() {
        let handlers = lock.withLock { () -> [@Sendable () -> Void]? in
            guard !closed else { return nil }
            closed = true
            defer { closeHandlers = [] }
            return closeHandlers
        }
        guard let handlers else { return }
        shutdown(fd, SHUT_RDWR)
        queue.async { [fd] in close(fd) }
        handlers.forEach { $0() }
    }
}
