import Foundation
import ImageAssetManagerCore

@Observable
final class AppEnvironment {
    var database: AppDatabase
    var libraryURL: URL

    private static let bookmarkKey = "libraryLocationBookmark"

    init(database: AppDatabase, libraryURL: URL) {
        self.database = database
        self.libraryURL = libraryURL
    }

    static func make() throws -> AppEnvironment {
        let url = resolveLibraryURL()
        try LibrarySetup.initialise(at: url)
        let dbPath = url.appending(path: "library.db").path(percentEncoded: false)
        let db = try AppDatabase(path: dbPath)
        return AppEnvironment(database: db, libraryURL: url)
    }

    // MARK: - Library location change

    func changeLibraryLocation(to destinationURL: URL, mode: MigrationMode) async throws {
        let service = LibraryMigrationService()
        try await service.migrate(from: libraryURL, to: destinationURL, mode: mode)

        AppEnvironment.persistBookmark(for: destinationURL)

        try LibrarySetup.initialise(at: destinationURL)
        let dbPath = destinationURL.appending(path: "library.db").path(percentEncoded: false)
        let newDB = try AppDatabase(path: dbPath)

        database = newDB
        libraryURL = destinationURL
    }

    // MARK: - Bookmark helpers

    static func persistBookmark(for url: URL) {
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
}
