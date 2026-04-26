import GRDB
import Foundation

public enum IndexExporter {
    public static func export(from database: AppDatabase, to indexURL: URL, assetsBaseURL: URL) async throws {
        let records = try await database.read { db -> [IndexAssetRecord] in
            let assets = try Asset.fetchAll(db)

            var tagsByAsset: [String: [String]] = [:]
            let rows = try Row.fetchAll(db, sql: """
                SELECT at.asset_id, t.name
                FROM asset_tags at
                JOIN tags t ON t.id = at.tag_id
            """)
            for row in rows {
                let assetID: String = row["asset_id"]
                let tagName: String = row["name"]
                tagsByAsset[assetID, default: []].append(tagName)
            }

            var projectIDsByAsset: [String: [String]] = [:]
            var projectNamesByAsset: [String: [String]] = [:]
            let projRows = try Row.fetchAll(db, sql: """
                SELECT ap.asset_id, ap.project_id, p.name, ap.is_primary
                FROM asset_projects ap
                JOIN projects p ON p.id = ap.project_id
                ORDER BY ap.is_primary DESC, p.name
            """)
            for row in projRows {
                let assetID: String = row["asset_id"]
                let projectID: String = row["project_id"]
                let name: String = row["name"]
                projectIDsByAsset[assetID, default: []].append(projectID)
                projectNamesByAsset[assetID, default: []].append(name)
            }

            return assets.map { asset in
                IndexAssetRecord(
                    asset: asset,
                    tags: tagsByAsset[asset.id] ?? [],
                    projectIDs: projectIDsByAsset[asset.id] ?? [],
                    projectNames: projectNamesByAsset[asset.id] ?? [],
                    filePath: assetsBaseURL.appending(path: asset.filename).path(percentEncoded: false)
                )
            }
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(records)

        let tempURL = indexURL.deletingLastPathComponent().appending(path: ".index.json.tmp")
        try data.write(to: tempURL)
        _ = try FileManager.default.replaceItemAt(indexURL, withItemAt: tempURL)
    }
}

struct IndexAssetRecord: Codable, Sendable {
    let id: String
    let filename: String
    let filePath: String
    /// Primary project ID (legacy — preserved for pre-v6 consumers). Equal to projectIDs.first when present.
    let projectID: String?
    let projectIDs: [String]
    let projectNames: [String]
    let providerID: String
    let modelID: String
    let prompt: String?
    let aspectRatio: String?
    let width: Int?
    let height: Int?
    let estimatedCost: Double?
    let actualCost: Double?
    let createdAt: String
    let tags: [String]
    let obsidianEmbedded: Bool

    init(asset: Asset, tags: [String], projectIDs: [String], projectNames: [String], filePath: String) {
        self.id = asset.id
        self.filename = asset.filename
        self.filePath = filePath
        self.projectID = projectIDs.first ?? asset.projectID
        self.projectIDs = projectIDs
        self.projectNames = projectNames
        self.providerID = asset.providerID
        self.modelID = asset.modelID
        self.prompt = asset.prompt
        self.aspectRatio = asset.aspectRatio
        self.width = asset.width
        self.height = asset.height
        self.estimatedCost = asset.estimatedCost
        self.actualCost = asset.actualCost
        self.createdAt = asset.createdAt
        self.tags = tags
        self.obsidianEmbedded = asset.obsidianEmbedded
    }
}
