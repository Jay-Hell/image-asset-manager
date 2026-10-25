import Foundation
import ImageAssetManagerCore

@Observable
final class AppEnvironment {
    var database: AppDatabase
    var libraryURL: URL
    private(set) var libraryRevision: Int = 0
    private static let bookmarkKey = "libraryLocationBookmark"

    init(database: AppDatabase, libraryURL: URL) {
        self.database = database
        self.libraryURL = libraryURL
    }

    /// True when XCTest launched this process as the app tests' host.
    static let isTestHost = TestHostIsolation.isTestHost()

    /// The library the last `make()` opened; the app tests assert it is a temporary one.
    private(set) static var openedLibraryURL: URL?

    static func make() throws -> AppEnvironment {
        // A test host never resolves the bookmark, UserDefaults or iCloud: it gets a fresh,
        // empty library under the temporary directory, so app tests cannot reach John's.
        #if DEBUG
        let url = isTestHost ? try TestHostIsolation.makeTemporaryLibrary() : try debugLibraryURL() ?? resolveLibraryURL()
        #else
        let url = isTestHost ? try TestHostIsolation.makeTemporaryLibrary() : resolveLibraryURL()
        #endif
        let db = try LibraryOpener.open(at: url)
        openedLibraryURL = url
        return AppEnvironment(database: db, libraryURL: url)
    }

    // MARK: - Library location change

    func changeLibraryLocation(to destinationURL: URL, mode: MigrationMode) async throws {
        #if DEBUG
        if Self.isDebugLibrary { throw DebugLibrary.Refusal.locationChangeRefused }
        #endif
        // Flush WAL into the main .db file so the copy/move is self-consistent.
        try await database.checkpoint()

        let service = LibraryMigrationService()
        try await service.migrate(from: libraryURL, to: destinationURL, mode: mode)

        AppEnvironment.persistBookmark(for: destinationURL)

        // Set up the folder structure and open the database at the new path, through the same
        // checks as launch; ARC releases the old connection.
        let newDB = try LibraryOpener.open(at: destinationURL)

        database = newDB
        libraryURL = destinationURL
    }

    // MARK: - Library clear

    func clearLibrary(deleteFiles: Bool) async throws {
        try await database.clearAllData()

        if deleteFiles {
            let fm = FileManager.default
            for folder in ["assets", "prompts"] {
                let folderURL = libraryURL.appending(path: folder)
                guard fm.fileExists(atPath: folderURL.path(percentEncoded: false)) else { continue }
                try fm.removeItem(at: folderURL)
                try fm.createDirectory(at: folderURL, withIntermediateDirectories: true)
            }
        }

        // Reset the export index to an empty library.
        let indexURL = libraryURL.appending(path: "index.json")
        try Data("[]".utf8).write(to: indexURL, options: .atomic)

        libraryRevision += 1
    }

    // MARK: - Bookmark helpers

    static func persistBookmark(for url: URL) {
        #if DEBUG
        // A debug library never becomes the saved location.
        if isDebugLibrary { return }
        #endif
        #if os(macOS)
        if let data = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            UserDefaults.standard.set(data, forKey: bookmarkKey)
            return
        }
        #endif
        // Non-sandbox fallback: store URL string
        UserDefaults.standard.set(url.absoluteString, forKey: bookmarkKey + "_url")
    }

    private static func resolveLibraryURL() -> URL {
        #if os(macOS)
        if let data = UserDefaults.standard.data(forKey: bookmarkKey) {
            var stale = false
            if let url = try? URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ), !stale, url.startAccessingSecurityScopedResource() {
                return url
            }
            // Stale or failed — remove and fall through
            UserDefaults.standard.removeObject(forKey: bookmarkKey)
        }
        #endif
        // Non-sandbox fallback
        if let str = UserDefaults.standard.string(forKey: bookmarkKey + "_url"),
           let url = URL(string: str) {
            return url
        }
        return defaultLibraryURL()
    }

    private static func defaultLibraryURL() -> URL {
        let fm = FileManager.default
        if let icloud = fm.url(forUbiquityContainerIdentifier: "iCloud.Ionic.ImageAssetManager") {
            let docs = icloud.appending(path: "Documents")
            try? fm.createDirectory(at: docs, withIntermediateDirectories: true)
            return docs
        }
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "ImageAssetManager")
        try? fm.createDirectory(at: appSupport, withIntermediateDirectories: true)
        return appSupport
    }

    #if DEBUG
    // MARK: - Debug library override (DEBUG only; see DebugLibrary in Core)

    /// True when this process opened an `IAM_LIBRARY` copy: no MCP server, no saved location.
    static var isDebugLibrary: Bool { DebugLibrary.current.library != nil }

    /// The `IAM_LIBRARY` folder, checked against every live location, or nil when none is asked
    /// for. A refusal throws, so the window says why and the live library is never opened instead.
    private static func debugLibraryURL() throws -> URL? {
        let info = ProcessInfo.processInfo
        guard let requested = try DebugLibrary.requested(environment: info.environment, arguments: info.arguments) else {
            return nil
        }
        let library = try DebugLibrary.resolve(requested, protected: liveLocations())
        DebugLibrary.current.activate(library)
        return library
    }

    /// Everywhere the live library is or could be, read without writing anything: a stale
    /// bookmark is not removed and no folder is created.
    private static func liveLocations() -> [DebugLibrary.Protected] {
        let saved = "the saved library location"
        var places: [DebugLibrary.Protected] = []
        let defaults = UserDefaults.standard
        #if os(macOS)
        if let data = defaults.data(forKey: bookmarkKey) {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI, .withoutMounting],
                                  relativeTo: nil, bookmarkDataIsStale: &stale) {
                places.append(.location(what: saved, url: url))
            } else {
                places.append(.unreadable(what: saved))
            }
        }
        #endif
        if let text = defaults.string(forKey: bookmarkKey + "_url") {
            if let url = URL(string: text), url.isFileURL {
                places.append(.location(what: saved, url: url))
            } else {
                places.append(.unreadable(what: saved))
            }
        }
        let fm = FileManager.default
        if let container = fm.url(forUbiquityContainerIdentifier: DebugLibrary.iCloudContainerID) {
            places.append(.location(what: "the live iCloud library", url: container))
        }
        // From the real home folder too, in case iCloud is signed out (a sandboxed home is the container).
        if let entry = getpwuid(getuid()), let home = entry.pointee.pw_dir {
            let url = URL(fileURLWithPath: String(cString: home), isDirectory: true)
            places.append(.location(what: "the live iCloud library", url: DebugLibrary.iCloudContainer(home: url)))
        }
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "ImageAssetManager")
        places.append(.location(what: "the fallback library and mcp-token folder", url: appSupport))
        return places
    }
    #endif
}
