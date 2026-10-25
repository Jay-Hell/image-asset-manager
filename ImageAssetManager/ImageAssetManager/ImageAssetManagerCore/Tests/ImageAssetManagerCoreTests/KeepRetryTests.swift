import Testing
import Foundation
import GRDB
@testable import ImageAssetManagerCore

// Release 1.2 housekeeping: a second Keep retries the follow-up writes (projects, tags, family) that
// failed the first time, and doubles none of them.

private struct FollowUps: Equatable {
    let assets: Int
    let spend: Int
    let refused: Int
    let tags: [String]
    let families: Int
    let projectLinks: Int
}

private func followUps(_ db: AppDatabase) async throws -> FollowUps {
    try await db.read { db in
        FollowUps(
            assets: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM assets") ?? -1,
            spend: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM spend_log") ?? -1,
            refused: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM refused_spend") ?? -1,
            tags: try String.fetchAll(db, sql: "SELECT t.name FROM asset_tags at JOIN tags t ON t.id = at.tag_id ORDER BY t.name"),
            families: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM variant_members") ?? -1,
            projectLinks: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset_projects") ?? -1)
    }
}

@Suite("Keep retries failed follow-up writes")
struct KeepRetryTests {

    private func held(_ rig: ToolsRig) async throws -> (PanelGeneration, GenerationService) {
        let run = try await PanelGeneration.run(
            selection: .tier("fast"), referenceCount: 0, aspectRatio: "1:1", prompt: "a viaduct", negativePrompt: nil,
            shape: .square, width: 1024, height: 1024, references: [], providers: rig.usable(),
            database: rig.db, libraryURL: rig.dir, catalogue: { rig.store.snapshot() }, live: rig.live)
        let service = try PanelGeneration.service(
            for: run.prepared, providers: rig.usable(), database: rig.db, libraryURL: rig.dir, live: rig.live)
        return (run, service)
    }

    @Test func aSecondKeepWritesTheTagsAndFamilyTheFirstFailedToAndDoublesNothing() async throws {
        let rig = try await ToolsRig.make()
        let (project, _) = try await rig.db.createProject(name: "Labs", clientID: nil, description: nil)
        let (run, service) = try await held(rig)
        let request = run.prepared.request(
            prompt: "a viaduct", aspectRatio: .square, width: 1024, height: 1024,
            projectIDs: [project.id], tags: ["viaduct", "dawn"], variantFamilyName: "Viaducts")

        // The fault, made in the database for this test: tag links cannot be written.
        try await rig.db.write { db in
            try db.execute(sql: "CREATE TRIGGER planted_tag_failure BEFORE INSERT ON asset_tags BEGIN SELECT RAISE(ABORT, 'planted'); END")
        }
        await #expect(throws: (any Error).self) { try await service.record(run.generated, for: request) }
        let afterFailure = try await followUps(rig.db)
        // The asset and its spend are kept; the tags, and the family after them, are not.
        #expect(afterFailure == FollowUps(assets: 1, spend: 1, refused: 0, tags: [], families: 0, projectLinks: 1))

        try await rig.db.write { db in try db.execute(sql: "DROP TRIGGER planted_tag_failure") }
        _ = try await service.record(run.generated, for: request)
        let retried = try await followUps(rig.db)
        #expect(retried == FollowUps(assets: 1, spend: 1, refused: 0, tags: ["dawn", "viaduct"], families: 1, projectLinks: 1))
        let family = try await rig.db.read { db in
            try String.fetchOne(db, sql: "SELECT v.name FROM variant_members m JOIN variants v ON v.id = m.variant_id")
        }
        #expect(family == "Viaducts")

        // The pair: another Keep once everything is written changes nothing.
        _ = try await service.record(run.generated, for: request)
        #expect(try await followUps(rig.db) == retried)
    }
}
