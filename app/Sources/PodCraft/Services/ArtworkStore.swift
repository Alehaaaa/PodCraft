import Foundation
import AppKit
import CryptoKit
import CoreImage
import ImageIO

/// Show and episode cover pictures, downloaded once into Application Support/PodCraft/Artwork
/// and named by a hash of their web address (episodes sharing a picture share the file).
enum ArtworkStore {
    static let folder: URL = {
        let url = Library.supportFolder.appendingPathComponent("Artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    nonisolated(unsafe) private static let memory = NSCache<NSString, NSImage>()
    nonisolated(unsafe) private static let palette = NSCache<NSString, NSColor>()

    static func key(_ remote: String) -> String {
        SHA256.hash(data: Data(remote.utf8)).map { String(format: "%02x", $0) }.joined().prefix(24).description
    }

    static func cachedFile(for remote: String) -> URL? {
        let f = folder.appendingPathComponent(key(remote))
        return FileManager.default.fileExists(atPath: f.path) ? f : nil
    }

    static func image(for remote: String?) -> NSImage? {
        guard let remote else { return nil }
        let k = key(remote) as NSString
        if let img = memory.object(forKey: k) { return img }
        guard let f = cachedFile(for: remote), let img = NSImage(contentsOf: f) else { return nil }
        memory.setObject(img, forKey: k)
        return img
    }

    /// A picture you chose for a show, copied into the Artwork folder.
    static func localImage(_ path: String) -> NSImage? {
        let k = ("file:" + path) as NSString
        if let img = memory.object(forKey: k) { return img }
        guard let img = NSImage(contentsOfFile: path) else { return nil }
        memory.setObject(img, forKey: k)
        return img
    }

    // MARK: Small ready-to-draw copies
    //
    // Covers are often 1400–3000 px. Drawing those into a 26-pt sidebar icon makes macOS decode and shrink
    // the full picture whenever a row appears (for example on a mode switch), which shows as a flash.
    // These copies are already decoded at the size they're shown, kept for the whole session.

    /// Keep decoded artwork bounded under memory pressure, even for libraries with many shows.
    nonisolated(unsafe) private static let thumbnails: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.totalCostLimit = 96 * 1024 * 1024
        return cache
    }()

    /// The pixel size used for a given point size (on a 2× screen), from a few fixed steps.
    static func thumbnailPixels(for points: CGFloat) -> Int {
        let wanted = Int(points * 2)
        return [64, 128, 256, 512, 1024].first { $0 >= wanted } ?? 0
    }

    /// A decoded copy of a cover at about `points` size; nil for big views (they use the full picture).
    static func thumbnail(remote: String?, localPath: String? = nil, points: CGFloat) -> NSImage? {
        let px = thumbnailPixels(for: points)
        guard px > 0, let source = localPath.map({ "file:" + $0 }) ?? remote.map(key) else { return nil }
        let k = "\(source)@\(px)" as NSString
        if let cached = thumbnails.object(forKey: k) { return cached }
        // ImageIO scales during decode rather than forcing NSImage to decode a multi-megapixel
        // cover before shrinking it to a small sidebar icon.
        guard let file = localPath.map({ URL(fileURLWithPath: $0) }) ?? remote.flatMap(cachedFile),
              let imageSource = CGImageSourceCreateWithURL(file as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: px,
                  kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary),
              let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        // Fill the square (like scaledToFill), centred.
        let scale = max(CGFloat(px) / CGFloat(cg.width), CGFloat(px) / CGFloat(cg.height))
        let w = CGFloat(cg.width) * scale, h = CGFloat(cg.height) * scale
        ctx.draw(cg, in: CGRect(x: (CGFloat(px) - w) / 2, y: (CGFloat(px) - h) / 2, width: w, height: h))
        guard let small = ctx.makeImage() else { return nil }
        let thumb = NSImage(cgImage: small, size: NSSize(width: CGFloat(px) / 2, height: CGFloat(px) / 2))
        thumbnails.setObject(thumb, forKey: k, cost: px * px * 4)
        return thumb
    }

    /// Prepare the sidebar and list sizes for every show ahead of time, a few at a time, so nothing flashes.
    @MainActor
    static func warmThumbnails(for shows: [Show]) {
        let urls = shows.map { (remote: $0.artworkURL, local: $0.customArtwork) }
        Task.detached(priority: .utility) {
            for s in urls {
                guard !Task.isCancelled else { return }
                for points: CGFloat in [18, 26, 42, 48] {
                    _ = thumbnail(remote: s.remote, localPath: s.local, points: points)
                }
            }
        }
    }

    /// Forget the small copies of one picture (after a new cover was chosen or downloaded).
    static func forgetThumbnails() {
        thumbnails.removeAllObjects()
    }

    /// A stable, readable card colour sampled from the cover itself. CIAreaAverage
    /// keeps this O(1), and the result is cached alongside the decoded artwork.
    static func cardColor(remote: String?, localPath: String? = nil) -> NSColor? {
        let cacheKey = (localPath.map { "file:" + $0 } ?? remote) as NSString?
        guard let cacheKey else { return nil }
        if let color = palette.object(forKey: cacheKey) { return color }
        let file = localPath.map { URL(fileURLWithPath: $0) } ?? remote.flatMap(cachedFile)
        guard let file, let input = CIImage(contentsOf: file) else { return nil }
        let extent = input.extent
        guard let output = CIFilter(name: "CIAreaAverage", parameters: [kCIInputImageKey: input,
                                                                          kCIInputExtentKey: CIVector(cgRect: extent)])?.outputImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        colorContext.render(output, toBitmap: &pixel, rowBytes: 4,
                                                                  bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                                                                  format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        let source = NSColor(red: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255,
                             blue: CGFloat(pixel[2]) / 255, alpha: 1).usingColorSpace(.deviceRGB) ?? .darkGray
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 1
        source.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        let color = NSColor(hue: hue, saturation: min(0.58, max(0.22, saturation * 0.82)),
                            brightness: min(0.38, max(0.22, brightness * 0.48)), alpha: 1)
        palette.setObject(color, forKey: cacheKey)
        return color
    }

    static func importCustom(from url: URL, showID: UUID) -> String? {
        let dest = folder.appendingPathComponent("custom-\(showID.uuidString)-\(Int(Date().timeIntervalSince1970)).\(url.pathExtension.isEmpty ? "png" : url.pathExtension)")
        guard (try? FileManager.default.copyItem(at: url, to: dest)) != nil else { return nil }
        return dest.path
    }

    static func data(for remote: String?) -> Data? {
        guard let remote, let f = cachedFile(for: remote) else { return nil }
        return try? Data(contentsOf: f)
    }

    /// Returns true when a new picture was saved.
    static func download(_ remote: String) async -> Bool {
        await ArtworkDownloadCoordinator.shared.download(remote) {
            await downloadUncoalesced(remote)
        }
    }

    private static func downloadUncoalesced(_ remote: String) async -> Bool {
        if cachedFile(for: remote) != nil { return false }
        guard let url = URL(string: remote), url.scheme == "http" || url.scheme == "https" else { return false }
        guard let data = try? await NetworkClient.data(from: url, limit: 30 * 1_048_576).0,
              !data.isEmpty else { return false }
        return await Task.detached(priority: .utility) {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  CGImageSourceGetCount(source) > 0 else { return false }
            let target = folder.appendingPathComponent(key(remote))
            return (try? data.write(to: target, options: .atomic)) != nil
        }.value
    }

    private static let colorContext = CIContext(options: [.workingColorSpace: NSNull()])
}
