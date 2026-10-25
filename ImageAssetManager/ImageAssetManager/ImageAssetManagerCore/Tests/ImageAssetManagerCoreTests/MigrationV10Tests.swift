import Testing
import Foundation
import GRDB
@testable import ImageAssetManagerCore

/// A library as release 1.1.0 leaves it: schema v1–v9 built by this build's own migrator stopped at
/// v9 (imported, not copied), WAL journal, and projects carrying `client_name` in every shape v10 has
/// to handle.
private struct V9LibraryFixture {
    let directory: URL
    var databasePath: String { directory.appending(path: "library.db").path(percentEncoded: false) }
    var backupsURL: URL { directory.appending(path: LibraryBackup.folderName) }

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "iam-v9-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let queue = try V7LibraryFixture.openLikeTheApp(path: databasePath)
        try AppDatabase.makeMigrator().migrate(queue, upTo: "v9_refused_spend")
        try queue.write { db in
            let at = "2026-04-18T09:00:00Z"
            try db.execute(sql: "INSERT INTO clients (id, name, created_at) VALUES ('c1', 'TfWM', ?)", arguments: [at])
            // (id, name, client_name, client_id)
            let projects: [(String, String, String?, String?)] = [
                ("p1", "Swift Go", "TfWM", "c1"),          // already linked: left alone
                ("p2", "ELEMENTS", " tfwm ", nil),         // the existing client, trimmed and in any case
                ("p3", "Labs", "Ionic", nil),              // a new client …
                ("p4", "Labs hero", "Ionic", nil),         // … made once for both
                ("p5", "Home", "   ", nil),                // blank: no client
                ("p6", "Gym", nil, nil),                   // none
                ("p7", "Mismatch", "Personal", "c1"),      // client_id wins; no 'Personal' client is made
            ]
            for (id, name, clientName, clientID) in projects {
                try db.execute(
                    sql: "INSERT INTO projects (id, name, client_name, client_id, created_at) VALUES (?, ?, ?, ?, ?)",
                    arguments: [id, name, clientName, clientID, at])
            }
            try db.execute(sql: """
                INSERT INTO assets (id, filename, file_hash, project_id, provider_id, model_id, created_at, obsidian_embedded, is_hidden, media_type)
                VALUES ('a1', 'a1.png', 'h1', 'p1', 'nano_banana', 'm', ?, 0, 0, 'image/png')
                """, arguments: [at])
            try db.execute(sql: "INSERT INTO spend_log (id, asset_id, provider_id, estimated_cost, timestamp) VALUES ('s1', 'a1', 'nano_banana', 0.03, ?)",
                           arguments: [at])
        }
        try queue.close()
    }

    func backupFiles() throws -> [String] {
        guard FileManager.default.fileExists(atPath: backupsURL.path(percentEncoded: false)) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: backupsURL.path(percentEncoded: false))
            .filter { $0.hasPrefix("library-") && $0.hasSuffix(".db") }
    }
}

@Suite("Migration v10 — client_id only, external spend")
struct MigrationV10Tests {

    @Test func everyClientNameBecomesAClientIDOnceAndClientIDsAlreadySetStand() async throws {
        let fixture = try V9LibraryFixture()
        let database = try AppDatabase(path: fixture.databasePath)

        let (clients, links, names) = try await database.read { db -> ([String: String], [String: String?], [String: String?]) in
            var clients: [String: String] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT id, name FROM clients") { clients[row["name"]] = row["id"] }
            var links: [String: String?] = [:], names: [String: String?] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT id, client_id, client_name FROM projects") {
                links[row["id"]] = .some(row["client_id"])
                names[row["id"]] = .some(row["client_name"])
            }
            return (clients, links, names)
        }
        // Worked by hand from the fixture: TfWM stays c1; Ionic is made once; nothing else.
        #expect(clients.keys.sorted() == ["Ionic", "TfWM"])
        #expect(clients["TfWM"] == "c1")
        let ionic = try #require(clients["Ionic"])
        #expect(links == ["p1": "c1", "p2": "c1", "p3": ionic, "p4": ionic, "p5": nil, "p6": nil, "p7": "c1"])
        // Copied, not moved: the old column is left as it was, for the older builds that still read it.
        #expect(names["p2"] == " tfwm ")
        #expect(names["p7"] == "Personal")
    }

    @Test func theBackupIsTakenFirstAndReadsAsTheV9Library() async throws {
        let fixture = try V9LibraryFixture()
        _ = try AppDatabase(path: fixture.databasePath)

        let files = try fixture.backupFiles()
        #expect(files.count == 1)
        let backup = try DatabaseQueue(path: fixture.backupsURL.appending(path: try #require(files.first)).path(percentEncoded: false))
        let (applied, projectColumns, spendColumns, clients, linked) = try await backup.read { db in
            (try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations"),
             try db.columns(in: "projects").map(\.name),
             try db.columns(in: "spend_log").map(\.name),
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM clients"),
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM projects WHERE client_id IS NOT NULL"))
        }
        #expect(applied.count == 9)
        #expect(!applied.contains("v10_client_ids_and_external_spend"))
        #expect(!projectColumns.contains("description"))
        #expect(!spendColumns.contains("source"))
        #expect(clients == 1)
        #expect(linked == 2)                 // p1 and p7, as the fixture wrote them
        try backup.close()
    }

    @Test func spendRowsFromBeforeAreTheAppsOwnAndTheViewCarriesTheirSource() async throws {
        let fixture = try V9LibraryFixture()
        let database = try AppDatabase(path: fixture.databasePath)
        let source = try await database.read { db in
            try Row.fetchOne(db, sql: "SELECT source FROM spend_entries")?["source"] as String?
        }
        #expect(source == nil)
        let own = try await database.fetchSpendSummary(since: "2000-01-01", until: "2100-01-01", includeExternal: false)
        #expect(own.generationCount == 1)
        #expect(abs(own.totalEstimated - 0.03) < 1e-9)
    }

    @Test func theAppNeitherReadsNorWritesClientNameAnyMore() async throws {
        let fixture = try V9LibraryFixture()
        let database = try AppDatabase(path: fixture.databasePath)
        try await database.insertProject(Project(id: "p8", name: "New", clientID: "c1", description: "A new one", createdAt: "2026-10-25T08:00:00Z"))
        let row = try await database.read { db in
            try Row.fetchOne(db, sql: "SELECT client_name, client_id, description FROM projects WHERE id = 'p8'")
                .map { ($0["client_name"] as String?, $0["client_id"] as String?, $0["description"] as String?) }
        }
        let (clientName, clientID, description) = try #require(row)
        #expect(clientName == nil)
        #expect(clientID == "c1")
        #expect(description == "A new one")
        // A project read back decodes from client_id alone.
        let p2 = try #require(try await database.findProject(idOrName: "ELEMENTS"))
        #expect(p2.clientID == "c1")
    }

    @Test func anOlderBuildStillOpensAV10LibraryAndWritesProjectsAndSpendAsBefore() async throws {
        let fixture = try V9LibraryFixture()
        do { _ = try AppDatabase(path: fixture.databasePath) }

        // As App Store 1.0.x / 1.1.0 do: their own migrator, then inserts naming client_name and no source.
        let old = try V7LibraryFixture.openLikeTheApp(path: fixture.databasePath)
        let migrator = AppDatabase.appStore1_0Migrator()
        try migrator.migrate(old)
        let complete = try await old.read { db in try migrator.hasCompletedMigrations(db) }
        #expect(complete == true)
        try await old.write { db in
            try db.execute(sql: "INSERT INTO projects (id, name, client_name, created_at) VALUES ('old', 'Old build', 'Somebody', '2026-10-25T08:00:00Z')")
            try db.execute(sql: "INSERT INTO spend_log (id, asset_id, provider_id, estimated_cost, timestamp) VALUES ('s2', 'a1', 'nano_banana', 0.03, '2026-10-25T08:00:00Z')")
        }
        try old.close()

        let database = try AppDatabase(path: fixture.databasePath)
        let summary = try await database.fetchSpendSummary(since: "2000-01-01", until: "2100-01-01", includeExternal: false)
        #expect(summary.generationCount == 2)              // the older build's charge counts as the app's own
        #expect(try await database.findProject(idOrName: "Old build")?.clientID == nil)
    }
}
