import Foundation

/// Shared policy for small backend requests. Media downloads intentionally keep
/// their own long-lived session in `Processor`.
enum NetworkClient {
    enum Failure: LocalizedError {
        case badResponse
        case http(Int)
        case responseTooLarge(Int)

        var errorDescription: String? {
            switch self {
            case .badResponse: "The server returned an invalid response."
            case .http(let status): "The server returned HTTP \(status)."
            case .responseTooLarge(let limit): "The response exceeded the \(limit / 1_048_576) MB safety limit."
            }
        }
    }

    static let metadata: URLSession = session(request: 10, resource: 25)
    static let feeds: URLSession = session(request: 20, resource: 45)

    private static func session(request: TimeInterval, resource: TimeInterval) -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = request
        config.timeoutIntervalForResource = resource
        config.requestCachePolicy = .useProtocolCachePolicy
        config.waitsForConnectivity = false
        config.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: config)
    }

    static func data(
        for request: URLRequest,
        session: URLSession = metadata,
        limit: Int,
        retries: Int = 1,
        acceptedStatus: (Int) -> Bool = { (200..<300).contains($0) }
    ) async throws -> (Data, HTTPURLResponse) {
        var attempt = 0
        while true {
            do {
                let (data, response) = try await session.data(for: request)
                try Task.checkCancellation()
                guard let http = response as? HTTPURLResponse else { throw Failure.badResponse }
                guard acceptedStatus(http.statusCode) else { throw Failure.http(http.statusCode) }
                if http.expectedContentLength > Int64(limit) || data.count > limit {
                    throw Failure.responseTooLarge(limit)
                }
                return (data, http)
            } catch {
                guard attempt < retries, shouldRetry(error) else { throw error }
                attempt += 1
                try await Task.sleep(for: .milliseconds(250 * attempt))
            }
        }
    }

    static func data(
        from url: URL,
        session: URLSession = metadata,
        limit: Int,
        retries: Int = 1
    ) async throws -> (Data, HTTPURLResponse) {
        try await data(for: URLRequest(url: url), session: session, limit: limit, retries: retries)
    }

    private static func shouldRetry(_ error: Error) -> Bool {
        if case Failure.http(let status) = error { return status == 408 || status == 429 || (500...599).contains(status) }
        guard let urlError = error as? URLError else { return false }
        return [.timedOut, .networkConnectionLost, .cannotConnectToHost, .dnsLookupFailed,
                .notConnectedToInternet, .resourceUnavailable].contains(urlError.code)
    }
}

/// Coalesces identical cover downloads. Navigating between several views can ask
/// for the same artwork repeatedly; only one network transfer and decode should run.
actor ArtworkDownloadCoordinator {
    static let shared = ArtworkDownloadCoordinator()
    private var tasks: [String: Task<Bool, Never>] = [:]

    func download(_ remote: String, operation: @escaping @Sendable () async -> Bool) async -> Bool {
        if let task = tasks[remote] { return await task.value }
        let task = Task { await operation() }
        tasks[remote] = task
        let result = await task.value
        tasks.removeValue(forKey: remote)
        return result
    }
}
