import Foundation
import CoreLocation
import MapKit
import SwiftUI

/// The country for the New page's charts: from this Mac's location (asked once, kept as a two-letter code),
/// falling back to the Mac's region setting. Only the country code ever leaves the Mac.
@MainActor
@Observable
final class LocationCountry: NSObject, CLLocationManagerDelegate {
    static let shared = LocationCountry()
    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var waiters: [CheckedContinuation<String?, Never>] = []
    @ObservationIgnored private var requestID = 0
    @ObservationIgnored private var reverseGeocoder: MKReverseGeocodingRequest?
    private static let key = "discoveryCountryFromLocation"

    /// Observable so the country picker updates when geocoding finishes after the page first appears.
    private(set) var detected: String? = UserDefaults.standard.string(forKey: key)
    var cached: String? { detected }
    var fallback: String {
        let region = (Locale.current.region?.identifier ?? "US").lowercased()
        return region.count == 2 && region.allSatisfy(\.isLetter) ? region : "us"
    }
    var current: String { cached ?? fallback }

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyReduced
    }

    /// Looks up the country from the location. Returns nil when location isn't allowed or doesn't answer in time.
    func resolve(timeout: Double = 8) async -> String? {
        guard CLLocationManager.locationServicesEnabled() else { return nil }
        let status = manager.authorizationStatus
        if status == .denied || status == .restricted { return nil }
        return await withCheckedContinuation { cont in
            waiters.append(cont)
            // Share an in-flight request with other callers; older timeouts cannot finish a newer request.
            guard waiters.count == 1 else { return }
            requestID += 1
            let id = requestID
            if status == .notDetermined { manager.requestWhenInUseAuthorization() } else { manager.requestLocation() }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self, self.requestID == id else { return }
                self.finish(nil)
            }
        }
    }

    private func finish(_ code: String?) {
        if let code {
            let value = code.lowercased()
            if value.count == 2 && value.allSatisfy(\.isLetter) {
                detected = value
                UserDefaults.standard.set(value, forKey: Self.key)
            }
        }
        requestID += 1
        let w = waiters
        waiters = []
        w.forEach { $0.resume(returning: code) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            // CLLocationManagerDelegate's parameter belongs to the nonisolated callback.
            // Consult our main-actor-owned manager only after hopping to the main actor.
            switch self.manager.authorizationStatus {
            case .authorizedAlways, .authorized: self.manager.requestLocation()
            case .denied, .restricted: self.finish(nil)
            default: break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor in
            self.reverseGeocoder?.cancel()
            guard let request = MKReverseGeocodingRequest(location: loc) else {
                self.finish(nil)
                return
            }
            self.reverseGeocoder = request
            let items = try? await request.mapItems
            // A newer location can arrive while MapKit is resolving this one.
            guard self.reverseGeocoder === request else { return }
            self.reverseGeocoder = nil
            self.finish(items?.first?.addressRepresentations?.region?.identifier.lowercased())
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            self.reverseGeocoder?.cancel()
            self.reverseGeocoder = nil
            self.finish(nil)
        }
    }
}

/// The New page's shows, kept on disk so the page opens instantly and refreshed quietly in the background.
@MainActor
@Observable
final class DiscoveryStore {
    static let shared = DiscoveryStore()

    var shows: [FeedFetcher.SearchResult] = []
    var loading = false
    var message: String?
    var country: String = LocationCountry.shared.current
    /// Nil means Use Location. The manual chart choice is independent of the location used elsewhere.
    var countryOverride: String? = nil
    var detectedCountry: String { LocationCountry.shared.current }
    var effectiveCountry: String { countryOverride ?? detectedCountry }

    private struct Cache: Codable { var country: String; var date: Date; var shows: [FeedFetcher.SearchResult] }
    private static var cacheURL: URL { Library.supportFolder.appendingPathComponent("Discovery.json") }
    private static let countryOverrideKey = "discoveryChartCountryOverride"
    /// Charts change daily; a list younger than this isn't fetched again.
    private static let freshFor: TimeInterval = 6 * 3600
    private var lastFetch: Date?
    private var loadingCountry: String?
    private var requestID = 0
    private var fetchTask: Task<Void, Never>?

    init() {
        countryOverride = Self.normalizedCountry(UserDefaults.standard.string(forKey: Self.countryOverrideKey))
        country = effectiveCountry
        if let data = try? Data(contentsOf: Self.cacheURL), let cache = try? JSONDecoder().decode(Cache.self, from: data) {
            // Do not display one storefront's cached charts under a different selected country.
            if cache.country == effectiveCountry {
                shows = cache.shows
                country = cache.country
                lastFetch = cache.date
            }
        }
        watchDetectedCountry()
    }

    /// Also catches late geocoding updates (including ones arriving after resolve's timeout).
    private func watchDetectedCountry() {
        withObservationTracking {
            _ = LocationCountry.shared.current
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.watchDetectedCountry()
                if self.countryOverride == nil { await self.load() }
            }
        }
    }

    private static func normalizedCountry(_ code: String?) -> String? {
        guard let code else { return nil }
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.count == 2 && normalized.allSatisfy(\.isLetter) ? normalized : nil
    }

    /// Persist a storefront override. Passing nil restores automatic location-based charts.
    func selectCountry(_ code: String?) {
        let selected = Self.normalizedCountry(code)
        if countryOverride == selected {
            Task { await load(force: true) }
            return
        }
        countryOverride = selected
        if let selected { UserDefaults.standard.set(selected, forKey: Self.countryOverrideKey) }
        else { UserDefaults.standard.removeObject(forKey: Self.countryOverrideKey) }
        Task { await load(force: true) }
    }

    /// Show what's cached at once; fetch when stale, the country changed or `force` is set.
    func load(force: Bool = false) async {
        let wanted = effectiveCountry
        if loading && loadingCountry == wanted && !force { return }
        let stale = lastFetch.map { Date().timeIntervalSince($0) > Self.freshFor } ?? true
        if !force && !stale && wanted == country && !shows.isEmpty { return }
        fetchTask?.cancel()
        requestID += 1
        let id = requestID
        loadingCountry = wanted
        loading = true
        if wanted != country {
            shows = []
            message = nil
            lastFetch = nil
            country = wanted
        }
        let task = Task { await fetch(country: wanted, requestID: id) }
        fetchTask = task
        await task.value
    }

    /// Refresh detected location even while the user has selected a different chart country.
    /// An override stays in control until the user switches back to Use Location.
    func refineCountryFromLocation() async {
        _ = await LocationCountry.shared.resolve()
        guard countryOverride == nil else { return }
        await load()
    }

    private func fetch(country code: String, requestID id: Int) async {
        defer {
            if requestID == id {
                loading = false
                loadingCountry = nil
                fetchTask = nil
            }
        }
        do {
            let fresh = try await FeedFetcher.topPodcasts(country: code)
            guard requestID == id, !Task.isCancelled else { return }
            guard !fresh.isEmpty else { throw URLError(.zeroByteResource) }
            shows = fresh
            country = code
            message = nil
            lastFetch = Date()
            if let data = try? JSONEncoder().encode(Cache(country: code, date: Date(), shows: fresh)) {
                try? data.write(to: Self.cacheURL, options: .atomic)
            }
        } catch {
            guard requestID == id, !Task.isCancelled else { return }
            if shows.isEmpty {
                // Preserve the original general-search fallback for automatic discovery only.
                // An overridden storefront must not quietly show unrelated global results.
                if countryOverride == nil {
                    let fallback = (try? await FeedFetcher.search("podcast")) ?? []
                    guard requestID == id, !Task.isCancelled else { return }
                    shows = fallback
                    message = fallback.isEmpty ? "Apple’s podcast chart couldn’t be reached." : nil
                } else {
                    message = "Apple’s podcast chart for this country couldn’t be reached. Try another country."
                }
            }
        }
    }
}
