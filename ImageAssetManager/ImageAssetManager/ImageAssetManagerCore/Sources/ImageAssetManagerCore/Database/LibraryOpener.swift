import Foundation

public enum LibraryOpenError: Error, Equatable, LocalizedError {
    /// iCloud has `library.db` but this device does not have the current copy yet.
    case notDownloaded
    /// No `library.db`, but the library has assets or an index: not a fresh library.
    case databaseMissing

    public var errorDescription: String? {
        switch self {
        case .notDownloaded:
            return "The library database is still downloading from iCloud. It will open once it is on this device."
        case .databaseMissing:
            return "The library has images but no library.db. It may still be downloading from iCloud; nothing has been changed."
        }
    }
}

/// The one way the app opens a library. A library is only treated as fresh — set up and given
/// a new empty database — when it really is empty. A `library.db` iCloud has not downloaded
/// (a placeholder on iPadOS, a not-current file on macOS) would otherwise look fresh: SQLite
/// would create an empty v8 database that then conflicts with the real one in iCloud.
public enum LibraryOpener {
    /// iCloud as the opener sees it; injected so tests can stand in for it.
    public struct ICloud: Sendable {
        public var downloadingStatus: @Sendable (URL) -> URLUbiquitousItemDownloadingStatus?
        public var startDownloading: @Sendable (URL) throws -> Void

        public init(downloadingStatus: @escaping @Sendable (URL) -> URLUbiquitousItemDownloadingStatus?,
                    startDownloading: @escaping @Sendable (URL) throws -> Void) {
            self.downloadingStatus = downloadingStatus
            self.startDownloading = startDownloading
        }

        public static let system = ICloud(
            downloadingStatus: { url in
                try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus
            },
            startDownloading: { url in try FileManager.default.startDownloadingUbiquitousItem(at: url) }
        )
    }

    /// Throws `LibraryOpenError` without writing anything when the database is not local and
    /// current; otherwise sets the library up and opens it (backing up before any migration).
    public static func open(at libraryURL: URL, iCloud: ICloud = .system) throws -> AppDatabase {
        try checkAvailable(libraryURL, iCloud: iCloud)
        try LibrarySetup.initialise(at: libraryURL)
        return try AppDatabase(path: libraryURL.appending(path: "library.db").path(percentEncoded: false))
    }

    static func checkAvailable(_ libraryURL: URL, iCloud: ICloud) throws {
        let fm = FileManager.default
        func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path(percentEncoded: false)) }

        let database = libraryURL.appending(path: "library.db")
        let placeholder = libraryURL.appending(path: ".library.db.icloud")
        let hasDatabase = exists(database)
        // Nil for a file iCloud does not manage; only a managed file can be not current.
        let notCurrent = hasDatabase && iCloud.downloadingStatus(database).map { $0 != .current } == true
        if exists(placeholder) || notCurrent {
            try? iCloud.startDownloading(database)   // best effort; the refusal stands either way
            throw LibraryOpenError.notDownloaded
        }
        if !hasDatabase && hasContent(libraryURL) {
            throw LibraryOpenError.databaseMissing
        }
    }

    /// Anything in `assets/` (placeholders included), or an index that lists something.
    static func hasContent(_ libraryURL: URL) -> Bool {
        let fm = FileManager.default
        let assets = (try? fm.contentsOfDirectory(atPath: libraryURL.appending(path: "assets").path(percentEncoded: false))) ?? []
        if assets.contains(where: { $0 != ".DS_Store" }) { return true }
        if fm.fileExists(atPath: libraryURL.appending(path: ".index.json.icloud").path(percentEncoded: false)) { return true }
        guard let index = try? Data(contentsOf: libraryURL.appending(path: "index.json")) else { return false }
        let text = String(decoding: index, as: UTF8.self).filter { !$0.isWhitespace }
        return !text.isEmpty && text != "[]"
    }
}
