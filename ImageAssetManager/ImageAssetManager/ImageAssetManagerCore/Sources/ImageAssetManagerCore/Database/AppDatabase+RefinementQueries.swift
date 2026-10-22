import Foundation
import GRDB

extension AppDatabase {
    public func saveRefinement(_ refinement: PromptRefinement) async throws {
        try await write { db in
            try refinement.upsert(db)
        }
    }

    public func fetchRefinement(forAsset assetID: String) async throws -> PromptRefinement? {
        let capturedAssetID = assetID
        return try await read { db in
            try PromptRefinement
                .filter(Column("asset_id") == capturedAssetID)
                .order(Column("created_at").desc)
                .fetchOne(db)
        }
    }
}
