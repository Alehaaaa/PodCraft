import ImageIO
import SwiftUI
import UIKit

/// Artwork, kept on the phone: each image is downloaded once into Caches/Artwork, then decoded at the size it's
/// shown (downsampled from the often 3000-pixel originals) and held in memory. Covers appear at once on the next
/// launch and offline, and scrolling doesn't stutter decoding huge images.
final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()

    private let memory: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.totalCostLimit = 96 * 1024 * 1024
        return c
    }()
    private let directory: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Artwork")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    private let downloads = Downloads()

    /// Sizes are rounded up to a few steps, so one decoded copy serves similar sizes.
    private static func bucket(_ pixels: CGFloat) -> Int {
        [96, 192, 384, 768, 1200].first { CGFloat($0) >= pixels } ?? 1200
    }

    private func key(_ url: URL, _ pixels: CGFloat) -> NSString { "\(Self.bucket(pixels))@\(url.absoluteString)" as NSString }

    /// Already decoded at this size: no waiting, so a cover shown before draws straight away.
    func cached(_ url: URL, pixels: CGFloat) -> UIImage? { memory.object(forKey: key(url, pixels)) }

    func image(for url: URL, pixels: CGFloat) async -> UIImage? {
        if let hit = cached(url, pixels: pixels) { return hit }
        let file = directory.appendingPathComponent(Hash.short(url.absoluteString, length: 32))
        let data: Data
        if let onDisk = try? Data(contentsOf: file) {
            data = onDisk
        } else if let fetched = await downloads.data(for: url) {
            try? fetched.write(to: file, options: .atomic)
            data = fetched
        } else {
            return nil
        }
        let size = Self.bucket(pixels)
        guard let image = await Task.detached(priority: .userInitiated, operation: { Self.decode(data, maxPixels: size) }).value
        else { return nil }
        let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        memory.setObject(image, forKey: key(url, pixels), cost: cost)
        return image
    }

    private static func decode(_ data: Data, maxPixels: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// One download per address, however many views ask at once.
    private actor Downloads {
        private var running: [URL: Task<Data?, Never>] = [:]
        private let session: URLSession = {
            let c = URLSessionConfiguration.default
            c.timeoutIntervalForRequest = 30
            c.urlCache = nil
            return URLSession(configuration: c)
        }()

        func data(for url: URL) async -> Data? {
            if let task = running[url] { return await task.value }
            let task = Task { [session] () -> Data? in
                guard let (data, response) = try? await session.data(from: url),
                      ((response as? HTTPURLResponse)?.statusCode ?? 200) < 400 else { return nil }
                return data
            }
            running[url] = task
            let result = await task.value
            running[url] = nil
            return result
        }
    }
}

/// A cover, from the cache.
struct Artwork: View {
    let url: URL?
    var size: CGFloat?
    var radius: CGFloat
    @Environment(\.displayScale) private var scale
    @State private var loaded: (url: URL, image: UIImage)?

    private var pixels: CGFloat { (size ?? 400) * scale }

    var body: some View {
        let image = (loaded?.url == url ? loaded?.image : nil) ?? url.flatMap { ImageCache.shared.cached($0, pixels: pixels) }
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Color.podTeal.opacity(0.25)
                Image(systemName: "waveform").font(.title2).foregroundStyle(Color.podTeal)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(.primary.opacity(0.08)))
        .task(id: url) {
            guard let url else { return }
            guard let image = await ImageCache.shared.image(for: url, pixels: pixels) else { return }
            withAnimation(.easeOut(duration: 0.2)) { loaded = (url, image) }
        }
    }
}
