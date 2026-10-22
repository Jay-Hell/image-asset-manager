import Testing
import Foundation
import GRDB
@testable import ImageAssetManagerCore

@Suite("Library backup before migrating")
struct LibraryBackupTests {

    @Test func backupIsTakenBeforeMigratingAndReadsAsTheV7Library() async throws {
        let fixture = try V7LibraryFixture()

        // One more asset written and left in the WAL by a connection that stays open, as a
        // running app would. A raw copy of library.db does not contain it …
        let holder = try V7LibraryFixture.openLikeTheApp(path: fixture.databasePath)
        try await holder.write { db in
            try V7LibraryFixture.insertAsOldBuild(db, id: "in-wal", filename: "wal.png")
        }
        let rawCopy = fixture.directory.appending(path: "raw-copy.db")
        try FileManager.default.copyItem(at: URL(filePath: fixture.databasePath), to: rawCopy)
        let raw = try DatabaseQueue(path: rawCopy.path(percentEncoded: false))
        let rawCount = try await raw.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM assets") }
        #expect(rawCount == 7)
        try raw.close()

        _ = try AppDatabase(path: fixture.databasePath)
        try holder.close()

        // … the backup does.
        let files = try fixture.backupFiles()
        #expect(files.count == 1)
        let backup = try DatabaseQueue(path: fixture.backupsURL.appending(path: try #require(files.first)).path(percentEncoded: false))
        let (assetCount, applied, columns) = try await backup.read { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM assets"),
             try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations"),
             try db.columns(in: "assets").map(\.name))
        }
        #expect(assetCount == 8)
        #expect(applied.count == 7)
        #expect(!applied.contains("v8_asset_media_type"))
        #expect(!columns.contains("media_type"))
        try backup.close()
    }

    @Test func noBackupWhenNothingIsPending() async throws {
        let fixture = try V7LibraryFixture()
        do { _ = try AppDatabase(path: fixture.databasePath) }
        #expect(try fixture.backupFiles().count == 1)

        do { _ = try AppDatabase(path: fixture.databasePath) }
        #expect(try fixture.backupFiles().count == 1)
    }

    @Test func noBackupForAFreshLibrary() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "iam-fresh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = try AppDatabase(path: dir.appending(path: "library.db").path(percentEncoded: false))
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "Backups").path(percentEncoded: false)))
    }

    @Test func keepsTheFiveNewestAndTouchesNothingElse() async throws {
        let fixture = try V7LibraryFixture()
        let fm = FileManager.default
        try fm.createDirectory(at: fixture.backupsURL, withIntermediateDirectories: true)
        let older = (1...5).map { "library-2020010\($0)T000000000Z.db" }
        for name in older {
            try Data("old".utf8).write(to: fixture.backupsURL.appending(path: name))
        }
        try Data("John's".utf8).write(to: fixture.backupsURL.appending(path: "notes.txt"))

        _ = try AppDatabase(path: fixture.databasePath)

        let files = try fixture.backupFiles()
        #expect(files.count == 5)
        #expect(!files.contains("library-20200101T000000000Z.db"))
        #expect(Array(files.prefix(4)) == Array(older.suffix(4)))
        #expect(files.last?.hasPrefix("library-2020") == false)
        #expect(fm.fileExists(atPath: fixture.backupsURL.appending(path: "notes.txt").path(percentEncoded: false)))
    }

    @Test func aFailedBackupStopsTheMigration() async throws {
        let fixture = try V7LibraryFixture()
        // A file where the Backups folder should be: the folder cannot be created.
        try Data("in the way".utf8).write(to: fixture.backupsURL)

        #expect(throws: (any Error).self) {
            _ = try AppDatabase(path: fixture.databasePath)
        }

        let queue = try DatabaseQueue(path: fixture.databasePath)
        let (applied, columns) = try await queue.read { db in
            (try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations"),
             try db.columns(in: "assets").map(\.name))
        }
        #expect(applied.count == 7)
        #expect(!columns.contains("media_type"))
        try queue.close()
    }
}
