import Testing
import Foundation
import GRDB
@testable import ImageAssetManagerCore

/// Downgrade check, phases A and C (this build). Phase B is the old build's Core, run between them.
/// Runs only when IAM_COMPAT_DIR names a folder holding a copy of a library.db.
private let dir = ProcessInfo.processInfo.environment["IAM_COMPAT_DIR"]
private var dbPath: String { dir! + "/library.db" }
private func backups() -> Int {
    (try? FileManager.default.contentsOfDirectory(atPath: dir! + "/Backups").count) ?? 0
}

@Suite(.serialized, .enabled(if: dir != nil)) struct CompatPhaseA {
    @Test func phaseA_migrateAndWriteNewData() async throws {
        let db = try AppDatabase(path: dbPath)
        let applied = try await db.read { try String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations") }
        #expect(applied.contains("v10_client_ids_and_external_spend"))
        let client = try await db.createClient(name: "Compat Client").client
        let project = try await db.createProject(name: "Compat Project", clientID: client.id, description: "made by 1.2").project
        let ids = try await db.read { try String.fetchAll($0, sql: "SELECT id FROM assets WHERE is_hidden = 0 ORDER BY created_at, id LIMIT 3") }
        #expect(ids.count == 3)
        _ = try await db.fileAssets(assetIDs: ids, projectID: project.id, mode: .add, primary: true)
        let imported = Asset(filename: "compat-import.png", fileHash: "compat-hash-\(UUID().uuidString)",
                             providerID: "external", modelID: "m", createdAt: "2026-08-06T09:00:00Z")
        let spend = SpendLog(assetID: imported.id, providerID: "external", actualCost: 0.04,
                             timestamp: "2026-08-06T09:00:00Z", source: SpendLog.externalSource)
        _ = try await db.insertImportedAsset(imported, spend: spend)
    }
}

@Suite(.serialized, .enabled(if: dir != nil)) struct CompatPhaseC {
    @Test func phaseC_reopenAfterTheOldBuild() async throws {
        let backupsBefore = backups()
        let db = try AppDatabase(path: dbPath)
        #expect(backups() == backupsBefore, "1.2 found a migration to run after the old build")
        let projects = try await db.fetchProjects()
        let clients = try await db.fetchClients()
        let compatClient = try #require(clients.first { $0.name == "Compat Client" })
        // 1.2's data survived the old build: description, client, filings.
        let renamed = try #require(projects.first { $0.name == "Compat Project renamed by 1.1" })
        #expect(renamed.description == "made by 1.2")
        #expect(renamed.clientID == compatClient.id)
        // The old build's writes read correctly here.
        let old = try #require(projects.first { $0.name == "Made in 1.1" })
        #expect(old.clientID == compatClient.id)
        let counts = try await db.fetchSidebarCounts(showHidden: true)
        #expect(counts.projects[renamed.id] == 3)
        #expect(counts.projects[old.id] == 1)
        #expect(counts.clients[compatClient.id] != nil)
        let external = try await db.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM spend_log WHERE source = 'external'") ?? 0
        }
        #expect(external == 1)
        let fromOld = try await db.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM spend_log WHERE provider_id = 'compat-1.1' AND source IS NULL") ?? 0
        }
        #expect(fromOld == 1)
        let withExternal = try await db.fetchSpendSummary(since: "2000-01-01", until: "2100-01-01", includeExternal: true)
        let withoutExternal = try await db.fetchSpendSummary(since: "2000-01-01", until: "2100-01-01", includeExternal: false)
        #expect(abs(withExternal.totalActual - withoutExternal.totalActual - 0.04) < 0.0001)
        // The old build's filing gave the asset a project; 1.2's sidebar must count it as filed.
        let unfiledIDs = try await db.read { try String.fetchAll($0, sql: """
            SELECT a.id FROM assets a WHERE NOT EXISTS (SELECT 1 FROM asset_projects ap WHERE ap.asset_id = a.id)
            """) }
        #expect(counts.unfiled == unfiledIDs.count)
    }
}
