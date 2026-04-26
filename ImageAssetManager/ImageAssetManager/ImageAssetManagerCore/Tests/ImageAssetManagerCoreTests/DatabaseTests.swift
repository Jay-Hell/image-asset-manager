import Testing
import Foundation
@testable import ImageAssetManagerCore

@Suite("AppDatabase")
struct DatabaseTests {
    func makeDatabase() throws -> AppDatabase {
        try AppDatabase(path: ":memory:")
    }

    func iso8601Now() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    @Test func schemaCreatesAllTables() async throws {
        let db = try makeDatabase()
        let tableNames = try await db.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
        }
        let expected = [
            "asset_projects", "asset_references", "asset_tags", "asset_usage", "assets",
            "clients", "grdb_migrations", "prompt_asset", "prompt_refinements",
            "prompts", "providers", "projects", "reference_entries",
            "reference_sets", "spend_log", "tags", "variant_members", "variants"
        ]
        for table in expected {
            #expect(tableNames.contains(table), "Missing table: \(table)")
        }
    }

    @Test func insertAndFetchProject() async throws {
        let db = try makeDatabase()
        let project = Project(name: "Test Project", createdAt: iso8601Now())
        try await db.write { db in try project.insert(db) }
        let fetched = try await db.read { db in try Project.fetchOne(db) }
        #expect(fetched?.name == "Test Project")
    }

    @Test func insertAndFetchAsset() async throws {
        let db = try makeDatabase()
        let asset = Asset(
            filename: "test.png",
            fileHash: "abc123",
            providerID: "nano_banana",
            modelID: "v1",
            createdAt: iso8601Now()
        )
        try await db.write { db in try asset.insert(db) }
        let fetched = try await db.read { db in try Asset.fetchOne(db) }
        #expect(fetched?.filename == "test.png")
        #expect(fetched?.obsidianEmbedded == false)
    }

    @Test func tagRelationship() async throws {
        let db = try makeDatabase()
        let now = iso8601Now()
        let asset = Asset(filename: "a.png", fileHash: "h1", providerID: "p", modelID: "m", createdAt: now)
        let tag = Tag(name: "hero")
        let assetTag = AssetTag(assetID: asset.id, tagID: tag.id)

        try await db.write { db in
            try asset.insert(db)
            try tag.insert(db)
            try assetTag.insert(db)
        }

        let count = try await db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset_tags") ?? 0
        }
        #expect(count == 1)
    }
}
