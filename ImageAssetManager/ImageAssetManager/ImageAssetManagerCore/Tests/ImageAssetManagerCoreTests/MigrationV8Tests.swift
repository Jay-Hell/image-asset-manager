import Testing
import Foundation
import GRDB
@testable import ImageAssetManagerCore

@Suite("Migration v8 — media_type")
struct MigrationV8Tests {

    @Test func backfillsMediaTypeFromTheExtensionOnASeededV7Library() async throws {
        let fixture = try V7LibraryFixture()
        let database = try AppDatabase(path: fixture.databasePath)

        let byID = try await database.read { db -> [String: String?] in
            var byID: [String: String?] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT id, media_type FROM assets") {
                byID[row["id"]] = .some(row["media_type"] as String?)
            }
            return byID
        }
        #expect(byID == V7LibraryFixture.expectedMediaTypes)
    }

    @Test func svgBecomesVectorAndPNGStaysRaster() async throws {
        let fixture = try V7LibraryFixture()
        let database = try AppDatabase(path: fixture.databasePath)

        let svg = try #require(try await database.read { db in try Asset.fetchOne(db, key: "a-svg") })
        let png = try #require(try await database.read { db in try Asset.fetchOne(db, key: "a-png") })
        #expect(svg.mediaType == "image/svg+xml")
        #expect(svg.mediaKind == .vector)
        #expect(png.mediaType == "image/png")
        #expect(png.mediaKind == .image)
    }

    @Test func leavesEveryOtherV7RowAsItWas() async throws {
        let fixture = try V7LibraryFixture()
        let database = try AppDatabase(path: fixture.databasePath)

        let counts = try await database.read { db in
            try ["assets", "asset_projects", "variants", "variant_members", "spend_log", "asset_tags", "projects", "clients"]
                .map { try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \($0)") ?? -1 }
        }
        #expect(counts == [7, 7, 7, 7, 7, 7, 2, 1])

        let jpg = try #require(try await database.read { db in try Asset.fetchOne(db, key: "a-jpg") })
        #expect(jpg.filename == "IMPORTED_01.JPG")
        #expect(jpg.prompt == "Prompt for a-jpg")
        #expect(jpg.width == 1024)
        #expect(jpg.height == 768)
        #expect(jpg.projectID == "p2")

        let applied = try await database.read { db in
            try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
        }
        #expect(applied.last == "v8_asset_media_type")
        #expect(applied.count == 8)
    }

    // MARK: - Older-build compatibility (App Store 1.0.x knows v1–v7 only)

    @Test func appStore1_0MigratorOpensAndReadsAV8Library() async throws {
        let fixture = try V7LibraryFixture()
        do { _ = try AppDatabase(path: fixture.databasePath) }   // migrate to v8, then release

        let old = try V7LibraryFixture.openLikeTheApp(path: fixture.databasePath)
        let migrator = AppDatabase.appStore1_0Migrator()
        try migrator.migrate(old)

        let (superseded, complete, filenames) = try await old.read { db in
            (try migrator.hasBeenSuperseded(db),
             try migrator.hasCompletedMigrations(db),
             try String.fetchAll(db, sql: "SELECT filename FROM assets ORDER BY id"))
        }
        #expect(superseded == true)      // GRDB sees v8 as unknown …
        #expect(complete == true)        // … and still treats the library as fully migrated.
        #expect(filenames == ["spinner.gif", "2026-04-18_photo.heic", "6F1C.jpeg", "IMPORTED_01.JPG",
                              "hero.png", "logo.svg", "banner.webp"])
        try old.close()
    }

    @Test func assetsAnOlderBuildWritesIntoAV8LibraryStillClassify() async throws {
        let fixture = try V7LibraryFixture()
        do { _ = try AppDatabase(path: fixture.databasePath) }

        let old = try V7LibraryFixture.openLikeTheApp(path: fixture.databasePath)
        try AppDatabase.appStore1_0Migrator().migrate(old)
        try await old.write { db in
            try V7LibraryFixture.insertAsOldBuild(db, id: "from-1.0.1", filename: "later.png")
        }
        try old.close()

        let database = try AppDatabase(path: fixture.databasePath)
        let asset = try #require(try await database.read { db in try Asset.fetchOne(db, key: "from-1.0.1") })
        #expect(asset.mediaType == nil)
        #expect(asset.effectiveMediaType == .png)
        #expect(asset.mediaKind == .image)
    }
}
