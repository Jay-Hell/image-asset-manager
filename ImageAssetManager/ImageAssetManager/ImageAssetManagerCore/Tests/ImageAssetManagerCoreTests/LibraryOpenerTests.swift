import Testing
import Foundation
import GRDB
@testable import ImageAssetManagerCore

/// Stands in for iCloud: reports a status per file name and records each download asked for.
private final class FakeICloud: @unchecked Sendable {
    var statuses: [String: URLUbiquitousItemDownloadingStatus] = [:]
    private(set) var downloadsStarted: [String] = []
    private let lock = NSLock()

    var iCloud: LibraryOpener.ICloud {
        LibraryOpener.ICloud(
            downloadingStatus: { [self] url in lock.withLock { statuses[url.lastPathComponent] } },
            startDownloading: { [self] url in lock.withLock { downloadsStarted.append(url.lastPathComponent) } }
        )
    }
}

private func exists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
}

@Suite("Opening a library that iCloud may not have downloaded")
struct LibraryOpenerTests {

    private func emptyDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "iam-open-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// What iPadOS shows before iCloud has fetched the library: `.library.db.icloud`, not
    /// `library.db`. Opening anyway would create an empty v8 database that then conflicts
    /// with the real one.
    @Test func aPlaceholderIsNeverOpenedAsAFreshLibrary() throws {
        let dir = try emptyDirectory()
        try Data("bplist00".utf8).write(to: dir.appending(path: ".library.db.icloud"))
        try FileManager.default.createDirectory(at: dir.appending(path: "assets"), withIntermediateDirectories: true)
        try Data("bplist00".utf8).write(to: dir.appending(path: "assets/.A1.png.icloud"))
        let fake = FakeICloud()

        #expect(throws: LibraryOpenError.notDownloaded) {
            _ = try LibraryOpener.open(at: dir, iCloud: fake.iCloud)
        }
        #expect(fake.downloadsStarted == ["library.db"])
        #expect(!exists(dir.appending(path: "library.db")))
        #expect(!exists(dir.appending(path: "index.json")))
        #expect(!exists(dir.appending(path: "Backups")))
    }

    /// On macOS a not-downloaded file keeps its own name but iCloud reports it not current.
    /// The v7 library must be left exactly as it was: no backup, no migration.
    @Test func aDatabaseICloudReportsNotCurrentIsNotOpened() async throws {
        let fixture = try V7LibraryFixture()
        let fake = FakeICloud()
        fake.statuses["library.db"] = .notDownloaded

        #expect(throws: LibraryOpenError.notDownloaded) {
            _ = try LibraryOpener.open(at: fixture.directory, iCloud: fake.iCloud)
        }
        #expect(fake.downloadsStarted == ["library.db"])
        #expect(try fixture.backupFiles().isEmpty)
        let queue = try DatabaseQueue(path: fixture.databasePath)
        let applied = try await queue.read { db in try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations") }
        #expect(applied.count == 7)
        try queue.close()
    }

    /// No database and no placeholder, but the library plainly has content: not fresh either.
    @Test func aMissingDatabaseBesideExistingAssetsIsNotOpened() throws {
        let dir = try emptyDirectory()
        try FileManager.default.createDirectory(at: dir.appending(path: "assets"), withIntermediateDirectories: true)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: dir.appending(path: "assets/A1.png"))

        #expect(throws: LibraryOpenError.databaseMissing) {
            _ = try LibraryOpener.open(at: dir, iCloud: FakeICloud().iCloud)
        }
        #expect(!exists(dir.appending(path: "library.db")))
    }

    // MARK: - What must still open

    @Test func aGenuinelyFreshLibraryOpens() throws {
        let dir = try emptyDirectory()
        _ = try LibraryOpener.open(at: dir, iCloud: FakeICloud().iCloud)
        #expect(exists(dir.appending(path: "library.db")))
        #expect(exists(dir.appending(path: "index.json")))
    }

    @Test func aFreshLibraryWithAnEmptyIndexAndNoAssetsOpens() throws {
        let dir = try emptyDirectory()
        try FileManager.default.createDirectory(at: dir.appending(path: "assets"), withIntermediateDirectories: true)
        try Data("[]\n".utf8).write(to: dir.appending(path: "index.json"))
        _ = try LibraryOpener.open(at: dir, iCloud: FakeICloud().iCloud)
        #expect(exists(dir.appending(path: "library.db")))
    }

    @Test func aCurrentDatabaseOpensAndMigrates() throws {
        let fixture = try V7LibraryFixture()
        let fake = FakeICloud()
        fake.statuses["library.db"] = .current

        _ = try LibraryOpener.open(at: fixture.directory, iCloud: fake.iCloud)

        #expect(fake.downloadsStarted.isEmpty)
        #expect(try fixture.backupFiles().count == 1)
    }
}
