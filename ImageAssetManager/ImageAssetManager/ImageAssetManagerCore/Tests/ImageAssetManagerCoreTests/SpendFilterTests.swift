import Testing
import Foundation
@testable import ImageAssetManagerCore

// Release 1.2 Q2 (R2-1 finding 5): every spend query that takes `includeExternal` must leave out
// the costs `import_asset` recorded when it is false. One test per query, each with the figure
// worked by hand for both settings, so a query that ignores the flag fails its own test.

/// What each filtered call passes as `includeExternal`. Proved red by setting it to true in this
/// file, the same as every query ignoring the flag: all six tests fail.
private let ownOnly = false

/// One imported image with a reported cost (external) and one of the app's own (source NULL):
/// - "ext": project Labs, openrouter, £0.25 estimated and actual, 2026-10-23.
/// - "own": project ELEMENTS, nano_banana, £0.03 estimated, no actual, 2026-10-24.
private func spendLibrary() async throws -> AppDatabase {
    let db = try AppDatabase(path: ":memory:")
    let labs = try await db.createProject(name: "Labs", clientID: nil, description: nil).project
    let elements = try await db.createProject(name: "ELEMENTS", clientID: nil, description: nil).project
    try await db.insertAsset(Asset(
        id: "ext", filename: "ext.png", fileHash: "hash-ext", projectID: labs.id, providerID: "openrouter",
        modelID: "imported", createdAt: "2026-10-23T18:40:12Z", importedAt: "2026-10-25T08:00:00Z"))
    try await db.insertAsset(Asset(
        id: "own", filename: "own.png", fileHash: "hash-own", projectID: elements.id, providerID: "nano_banana",
        modelID: "m", createdAt: "2026-10-24T10:00:00Z"))
    try await db.insertSpendLog(SpendLog(
        assetID: "ext", providerID: "openrouter", estimatedCost: 0.25, actualCost: 0.25,
        timestamp: "2026-10-23T18:40:12Z", source: SpendLog.externalSource))
    try await db.insertSpendLog(SpendLog(
        assetID: "own", providerID: "nano_banana", estimatedCost: 0.03, actualCost: nil,
        timestamp: "2026-10-24T10:00:00Z"))
    return db
}

private let since = "2026-10-01", until = "2026-11-01"

private func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }

@Suite("Spend: external spend can be left out of every query")
struct SpendFilterTests {

    @Test func getSpend() async throws {
        let db = try await spendLibrary()
        let own = try await db.mcpGetSpend(project: nil, dateFrom: nil, dateTo: nil, includeExternal: ownOnly)
        #expect(own.generationCount == 1)
        #expect(near(own.totalEstimated, 0.03))
        #expect(near(own.totalActual, 0))
        // The pair: with external spend, 0.25 + 0.03 = 0.28 over two, 0.25 actual.
        let all = try await db.mcpGetSpend(project: nil, dateFrom: nil, dateTo: nil, includeExternal: true)
        #expect(all.generationCount == 2)
        #expect(near(all.totalEstimated, 0.28))
        #expect(near(all.totalActual, 0.25))
    }

    @Test func dashboardSummary() async throws {
        let db = try await spendLibrary()
        let own = try await db.fetchSpendSummary(since: since, until: until, includeExternal: ownOnly)
        #expect(own.generationCount == 1)
        #expect(near(own.totalEstimated, 0.03))
        #expect(near(own.totalActual, 0))
        let all = try await db.fetchSpendSummary(since: since, until: until, includeExternal: true)
        #expect(all.generationCount == 2)
        #expect(near(all.totalEstimated, 0.28))
    }

    @Test func dailySpend() async throws {
        let db = try await spendLibrary()
        let own = try await db.fetchDailySpend(since: since, until: until, granularity: .day, includeExternal: ownOnly)
        #expect(own.map(\.bucket) == ["2026-10-24"])
        #expect(near(own.first?.estimated ?? -1, 0.03))
        let all = try await db.fetchDailySpend(since: since, until: until, granularity: .day, includeExternal: true)
        #expect(all.map(\.bucket) == ["2026-10-23", "2026-10-24"])
        #expect(near(all.first?.estimated ?? -1, 0.25))
    }

    @Test func spendByProvider() async throws {
        let db = try await spendLibrary()
        let own = try await db.fetchSpendByProvider(since: since, until: until, includeExternal: ownOnly)
        #expect(own.map(\.providerID) == ["nano_banana"])
        #expect(own.map(\.generationCount) == [1])
        let all = try await db.fetchSpendByProvider(since: since, until: until, includeExternal: true)
        #expect(all.map(\.providerID) == ["openrouter", "nano_banana"])
    }

    @Test func spendByProject() async throws {
        let db = try await spendLibrary()
        let own = try await db.fetchSpendByProject(since: since, until: until, includeExternal: ownOnly)
        #expect(own.map(\.projectName) == ["ELEMENTS"])
        #expect(near(own.first?.totalEstimated ?? -1, 0.03))
        let all = try await db.fetchSpendByProject(since: since, until: until, includeExternal: true)
        #expect(all.map(\.projectName) == ["Labs", "ELEMENTS"])
    }

    @Test func topAssetsBySpend() async throws {
        let db = try await spendLibrary()
        let own = try await db.fetchTopAssetsBySpend(limit: 10, since: since, until: until, includeExternal: ownOnly)
        #expect(own.map(\.0.id) == ["own"])
        #expect(near(own.first?.1 ?? -1, 0.03))
        let all = try await db.fetchTopAssetsBySpend(limit: 10, since: since, until: until, includeExternal: true)
        #expect(all.map(\.0.id) == ["ext", "own"])
        #expect(near(all.first?.1 ?? -1, 0.25))
    }
}
