import Testing
import Foundation
import GRDB
@testable import ImageAssetManagerCore

/// Downgrade check, phase B: the 1.1.0 Core opens a library that 1.2 has migrated and written to,
/// reads it as the 1.1 app does, and writes as the 1.1 app and MCP do.
private let dir = ProcessInfo.processInfo.environment["IAM_COMPAT_DIR"]

@Suite(.serialized, .enabled(if: dir != nil)) struct CompatPhaseB {
    @Test func phaseB_oldBuildReadsAndWrites() async throws {
        let backupsBefore = (try? FileManager.default.contentsOfDirectory(atPath: dir! + "/Backups").count) ?? 0
        let db = try AppDatabase(path: dir! + "/library.db")
        let backupsAfter = (try? FileManager.default.contentsOfDirectory(atPath: dir! + "/Backups").count) ?? 0
        #expect(backupsAfter == backupsBefore, "1.1 took a backup, so it thought a migration was pending")

        // Reads the 1.1 app makes on launch and in the sidebar, grid, inspector and spend dashboard.
        let clients = try await db.fetchClients()
        let client = try #require(clients.first { $0.name == "Compat Client" })
        let projects = try await db.fetchProjects()
        let project = try #require(projects.first { $0.name == "Compat Project" })
        #expect(project.clientID == client.id)
        let filed = try await db.searchAssets(projectIDs: [project.id], showHidden: true)
        #expect(filed.count == 3)
        let all = try await db.searchAssets(showHidden: true)
        #expect(all.contains { $0.filename == "compat-import.png" })
        _ = try await db.fetchTagsWithCounts()
        _ = try await db.fetchVariantFamilies()
        _ = try await db.fetchProjectsForAsset(assetID: filed[0].id)
        _ = try await db.fetchVariantContext(assetID: filed[0].id)
        _ = try await db.fetchSpendSummary(since: "2000-01-01", until: "2100-01-01")
        _ = try await db.fetchSpendByProject(since: "2000-01-01", until: "2100-01-01")
        _ = try await db.fetchSpendByProvider(since: "2000-01-01", until: "2100-01-01")
        _ = try await db.fetchRecentSpendLog(limit: 50)
        let libraryURL = URL(fileURLWithPath: dir!)
        _ = try await db.mcpGetAssetDetail(id: filed[0].id, libraryURL: libraryURL)
        _ = try await db.findProject(idOrName: "Compat Project")

        // Writes the 1.1 app and MCP make.
        let made = Project(name: "Made in 1.1", clientName: client.name, clientID: client.id, createdAt: ISO8601DateFormatter().string(from: Date()))
        try await db.insertProject(made)
        let spare = try #require(all.first { a in !filed.contains { $0.id == a.id } && a.filename != "compat-import.png" })
        try await db.setProjectsForAsset(assetID: spare.id, projectIDs: [made.id])
        try await db.renameProject(id: project.id, newName: "Compat Project renamed by 1.1")
        try await db.bulkAddTagToAssets(assetIDs: [spare.id], tagName: "compat-tag")
        try await db.setHidden(assetIDs: [spare.id], hidden: true)
        try await db.setHidden(assetIDs: [spare.id], hidden: false)
        try await db.insertSpendLog(SpendLog(assetID: spare.id, providerID: "compat-1.1", actualCost: 0.01, timestamp: ISO8601DateFormatter().string(from: Date())))
        try await db.markAssetUsed(assetID: spare.id, usedIn: "compat check")
    }
}
