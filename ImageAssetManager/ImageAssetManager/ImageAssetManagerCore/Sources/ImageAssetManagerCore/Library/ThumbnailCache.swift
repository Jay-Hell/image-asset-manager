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

    /// The app's shared cache: `Caches/Thumbnails` in the app container (inside the override
    /// library when a debug build has one).
    public static let shared = ThumbnailCache(directory: sharedDirectory())

    static func sharedDirectory() -> URL {
        #if DEBUG
        return sharedDirectory(debug: DebugLibrary.current)
        #else
        return containerDirectory()
        #endif
    }

    #if DEBUG
    static func sharedDirectory(debug: DebugLibrary.Session) -> URL {
        if let library = debug.library { return DebugLibrary.thumbnailDirectory(in: library) }
        return containerDirectory()
    }
    #endif

    private static func containerDirectory() -> URL {
        (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory).appending(path: "Thumbnails", directoryHint: .isDirectory)
    }

    /// The cached file's name. The asset and the file hash are both in it, so a replaced file
    /// (new hash) is a new entry; anything outside letters, digits, `-` and `_` is dropped so a
    /// key can never name a path.
    public static func key(assetID: String, fileHash: String, pixelSize: Int = ThumbnailCache.pixelSize) -> String {
        "\(clean(assetID))-\(clean(fileHash))-\(pixelSize).png"
    }

    /// The file `key` is cached in: one folder per asset, so a store lists only that asset's files.
    public func cacheURL(assetID: String, fileHash: String) -> URL {
        directory.appending(path: Self.clean(assetID), directoryHint: .isDirectory)
            .appending(path: Self.key(assetID: assetID, fileHash: fileHash))
    }

    /// The sweep runs at most this often.
    public static let sweepInterval: TimeInterval = 24 * 60 * 60

    private var sweepMarker: URL { directory.appending(path: ".last-sweep") }

    /// Removes every cached file no live asset needs (a deleted asset's folder, an older hash or
    /// pixel size, the flat files of the first layout), at most once per `sweepInterval`, timed
    /// by a marker in the folder. Returns whether it swept. Nonisolated async, so it runs off
    /// the main thread; the app also calls it from a detached task.
    @discardableResult
    public func sweepIfDue(liveAssets: [(id: String, fileHash: String)], now: Date = Date()) async -> Bool {
        let manager = FileManager.default
        if let text = try? String(contentsOf: sweepMarker, encoding: .utf8),
           let last = ISO8601DateFormatter().date(from: text),
           now >= last, now.timeIntervalSince(last) < Self.sweepInterval {
            return false
        }
        var wanted: [String: String] = [:]
        for asset in liveAssets { wanted[Self.clean(asset.id)] = Self.key(assetID: asset.id, fileHash: asset.fileHash) }
        for name in (try? manager.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
        where name != sweepMarker.lastPathComponent {
            let entry = directory.appending(path: name)
            var isFolder: ObjCBool = false
            manager.fileExists(atPath: entry.path(percentEncoded: false), isDirectory: &isFolder)
            // Only the cache's own shapes are ever removed: a key-named folder or a .png.
            guard isFolder.boolValue ? Self.clean(name) == name : name.hasSuffix(".png") else { continue }
            guard let keep = wanted[name] else {
                try? manager.removeItem(at: entry)
                continue
            }
            for file in (try? manager.contentsOfDirectory(atPath: entry.path(percentEncoded: false))) ?? []
            where file != keep && file.hasSuffix(".png") {
                try? manager.removeItem(at: entry.appending(path: file))
            }
        }
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Data(ISO8601DateFormatter().string(from: now).utf8).write(to: sweepMarker, options: .atomic)
        return true
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
        let folder = url.deletingLastPathComponent()
        try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
        // An older hash of the same asset is dead weight: drop it. Only this asset's own folder
        // is listed, never the whole cache.
        for name in (try? manager.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []
        where name != url.lastPathComponent {
            try? manager.removeItem(at: folder.appending(path: name))
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
