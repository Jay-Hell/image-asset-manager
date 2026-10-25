import Foundation
import CoreGraphics
import ImageIO

/// Grid thumbnails, drawn once and kept on disk per asset and file hash, in a folder of their
/// own (the app container's `Caches`), never in the library, so iCloud never syncs them.
/// A raster is thumbnailed by ImageIO; an SVG comes from the sanitised preview
/// (`AssetPreview.render`), so nothing here hands raw SVG to a renderer. The work runs off the
/// main thread because `thumbnail` is a nonisolated async function.
public struct ThumbnailCache: Sendable {
    /// Longest side in pixels: sharp at 160 pt on a 2x display and wider cells.
    public static let pixelSize = 512

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// The app's shared cache: `Caches/Thumbnails` in the app container.
    public static let shared = ThumbnailCache(
        directory: (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory).appending(path: "Thumbnails", directoryHint: .isDirectory))

    /// The cached file's name. The asset and the file hash are both in it, so a replaced file
    /// (new hash) is a new entry; anything outside letters, digits, `-` and `_` is dropped so a
    /// key can never name a path.
    public static func key(assetID: String, fileHash: String, pixelSize: Int = ThumbnailCache.pixelSize) -> String {
        "\(clean(assetID))-\(clean(fileHash))-\(pixelSize).png"
    }

    /// The file `key` is cached in.
    public func cacheURL(assetID: String, fileHash: String) -> URL {
        directory.appending(path: Self.key(assetID: assetID, fileHash: fileHash))
    }

    /// The thumbnail for an asset's file: the cached one if there is one, else drawn from
    /// `source` and cached. Nil when the file draws nothing.
    public func thumbnail(assetID: String, fileHash: String, source: URL) async -> CGImage? {
        let cached = cacheURL(assetID: assetID, fileHash: fileHash)
        if let hit = Self.read(cached) { return hit }
        guard let drawn = await AssetPreview.render(contentsOf: source, maxPixelSize: Self.pixelSize) else { return nil }
        store(drawn, assetID: assetID, at: cached)
        return drawn
    }

    private func store(_ image: CGImage, assetID: String, at url: URL) {
        guard !Self.clean(assetID).isEmpty else { return }   // nothing to key on: draw, don't cache
        let manager = FileManager.default
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        // An older hash of the same asset is dead weight: drop it.
        let prefix = "\(Self.clean(assetID))-"
        for name in (try? manager.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
        where name.hasPrefix(prefix) && name != url.lastPathComponent {
            try? manager.removeItem(at: directory.appending(path: name))
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return }
        try? (data as Data).write(to: url, options: .atomic)
    }

    private static func read(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static func clean(_ text: String) -> String {
        String(text.unicodeScalars.filter {
            ($0.value >= 48 && $0.value <= 57) || ($0.value >= 65 && $0.value <= 90)
                || ($0.value >= 97 && $0.value <= 122) || $0 == "-" || $0 == "_"
        })
    }
}
