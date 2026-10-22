import Testing
import Foundation
@testable import ImageAssetManagerCore

/// GRDB hands an INTEGER column back as Int64, so `as? Int` was always nil and every count read 0.
@Suite("Spend counts")
struct SpendCountTests {

    private func database() async throws -> AppDatabase {
        let db = try AppDatabase(path: ":memory:")
        // Three rows in the window, one outside it. Expected values are counted by hand.
        for (i, provider) in ["openrouter", "openrouter", "nano_banana"].enumerated() {
            try await db.insertRefusedSpend(
                providerID: provider, modelID: "some-model-aa", estimatedCost: 0.25, actualCost: nil,
                reason: "test", timestamp: "2026-10-22T10:00:0\(i)Z")
        }
        try await db.insertRefusedSpend(
            providerID: "openrouter", modelID: "some-model-aa", estimatedCost: 9, actualCost: nil,
            reason: "test", timestamp: "2026-11-01T10:00:00Z")
        return db
    }

    @Test func theDashboardSummaryCountsEachRow() async throws {
        let s = try await database().fetchSpendSummary(since: "2026-10-22", until: "2026-10-23")
        #expect(s.generationCount == 3)
        #expect(abs(s.totalEstimated - 0.75) < 1e-9)
        #expect(abs(s.avgCostPerGeneration - 0.25) < 1e-9)
    }

    @Test func theMCPSummaryCountsEachRow() async throws {
        let s = try await database().mcpGetSpend(project: nil, dateFrom: "2026-10-22", dateTo: "2026-10-23")
        #expect(s.generationCount == 3)
        #expect(abs(s.avgCostPerGeneration - 0.25) < 1e-9)
    }

    @Test func theProviderAndProjectBreakdownsCountEachRow() async throws {
        let db = try await database()
        let byProvider = try await db.fetchSpendByProvider(since: "2026-10-22", until: "2026-10-23")
        #expect(Dictionary(uniqueKeysWithValues: byProvider.map { ($0.providerID, $0.generationCount) }) == ["openrouter": 2, "nano_banana": 1])
        let byProject = try await db.fetchSpendByProject(since: "2026-10-22", until: "2026-10-23")
        #expect(byProject.map(\.generationCount) == [3])
    }
}
