import Foundation
import ImageAssetManagerCore

@Observable
final class AppEnvironment {
    let database: AppDatabase
    let libraryURL: URL

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

    private static func resolveLibraryURL() -> URL {
        let fm = FileManager.default
        if let icloud = fm.url(forUbiquityContainerIdentifier: "iCloud.Ionic.ImageAssetManager") {
            let docs = icloud.appending(path: "Documents")
            try? fm.createDirectory(at: docs, withIntermediateDirectories: true)
            return docs
        }
        // Local fallback for development / simulators without iCloud
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "ImageAssetManager")
        try? fm.createDirectory(at: appSupport, withIntermediateDirectories: true)
        return appSupport
    }
}
