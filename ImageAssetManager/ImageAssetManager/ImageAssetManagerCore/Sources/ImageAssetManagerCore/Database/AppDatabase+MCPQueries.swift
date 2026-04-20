import GRDB
import Foundation

// MARK: - Response types

public struct MCPAssetSummary: Codable, Sendable {
    public let id: String
    public let filename: String
    public let filePath: String
    public let projectID: String?
    public let collectionID: String?
    public let providerID: String
    public let modelID: String
    public let prompt: String?
    public let aspectRatio: String?
    public let width: Int?
    public let height: Int?
    public let estimatedCost: Double?
    public let createdAt: String
    public let tags: [String]
}

public struct MCPAssetDetail: Codable, Sendable {
    public let asset: MCPAssetSummary
    public let references: [MCPReferenceEntry]
    public let usage: [MCPUsageEntry]
}

public struct MCPReferenceEntry: Codable, Sendable {
    public let sourceAssetID: String?
    public let sourceFilePath: String?
    public let roleUsed: String?
    public let weightUsed: Double?
    public let passedToAPI: Bool
}

public struct MCPUsageEntry: Codable, Sendable {
    public let usedIn: String?
    public let usedAt: String?
}

public struct MCPLineageRecord: Codable, Sendable {
    public let assetID: String
    public let influences: [MCPReferenceEntry]
}

public struct MCPCollectionSummary: Codable, Sendable {
    public let id: String
    public let projectID: String
    public let name: String
    public let description: String?
    public let assetCount: Int
    public let obsidianNotePath: String?
}

public struct MCPCollectionDetail: Codable, Sendable {
    public let id: String
    public let projectID: String
    public let name: String
    public let description: String?
    public let obsidianNotePath: String?
    public let assets: [MCPAssetSummary]
}

public struct MCPPromptDetail: Codable, Sendable {
    public let id: String
    public let title: String
    public let body: String
    public let negativePrompt: String?
    public let sector: String?
    public let tags: [String]
    public let usageCount: Int
    public let lastUsedAt: String?
    public let obsidianNotePath: String?
    public let createdAt: String
    public let linkedAssets: [MCPAssetSummary]
}

// MARK: - Queries

extension AppDatabase {

    public func mcpSearchAssets(
        query: String?,
        tags: [String]?,
        project: String?,
        projects: [String]? = nil,
        collection: String?,
        provider: String?,
        aspectRatio: String?,
        dateFrom: String?,
        dateTo: String?,
        limit: Int = 50,
        libraryURL: URL
    ) async throws -> [MCPAssetSummary] {
        var conditions: [String] = []
        var mutableArgs: StatementArguments = []

        if let q = query, !q.isEmpty {
            let pattern = "%\(q)%"
            conditions.append("(a.prompt LIKE ? OR a.filename LIKE ?)")
            mutableArgs += [pattern, pattern]
        }
        if let tagList = tags, !tagList.isEmpty {
            let ph = tagList.map { _ in "?" }.joined(separator: ", ")
            conditions.append("""
                a.id IN (
                    SELECT at.asset_id FROM asset_tags at
                    JOIN tags t ON t.id = at.tag_id
                    WHERE t.name IN (\(ph))
                )
                """)
            for t in tagList { mutableArgs += [t] }
        }
        // Merge singular `project` (shorthand) with `projects` (array). Any match counts.
        var projectFilterNames: [String] = []
        if let p = project, !p.isEmpty { projectFilterNames.append(p) }
        if let ps = projects { projectFilterNames.append(contentsOf: ps.filter { !$0.isEmpty }) }
        if !projectFilterNames.isEmpty {
            let ph = projectFilterNames.map { _ in "?" }.joined(separator: ", ")
            conditions.append("a.id IN (SELECT ap.asset_id FROM asset_projects ap JOIN projects pj ON pj.id = ap.project_id WHERE pj.name IN (\(ph)))")
            for name in projectFilterNames { mutableArgs += [name] }
        }
        if let c = collection { conditions.append("col.name = ?");       mutableArgs += [c] }
        if let pv = provider  { conditions.append("a.provider_id = ?");  mutableArgs += [pv] }
        if let ar = aspectRatio { conditions.append("a.aspect_ratio = ?"); mutableArgs += [ar] }
        if let df = dateFrom  { conditions.append("a.created_at >= ?");  mutableArgs += [df] }
        if let dt = dateTo    { conditions.append("a.created_at < ?");   mutableArgs += [dt] }

        let where_ = conditions.isEmpty ? "" : "WHERE \(conditions.joined(separator: " AND "))"
        mutableArgs += [limit]
        let capturedArgs = mutableArgs
        let assetsBase = libraryURL.appending(path: "assets")
        let sql = """
            SELECT DISTINCT a.*
            FROM assets a
            LEFT JOIN projects p ON p.id = a.project_id
            LEFT JOIN collections col ON col.id = a.collection_id
            \(where_)
            ORDER BY a.created_at DESC
            LIMIT ?
            """

        return try await read { db in
            let assets = try Row.fetchAll(db, sql: sql, arguments: capturedArgs)
                .compactMap { row -> Asset? in try? Asset(row: row) }
            let tagMap = try Self.fetchTagNames(for: assets.map(\.id), db: db)
            return assets.map { a in
                let fp = assetsBase.appending(path: a.filename).path(percentEncoded: false)
                return MCPAssetSummary(
                    id: a.id, filename: a.filename, filePath: fp,
                    projectID: a.projectID, collectionID: a.collectionID,
                    providerID: a.providerID, modelID: a.modelID,
                    prompt: a.prompt, aspectRatio: a.aspectRatio,
                    width: a.width, height: a.height,
                    estimatedCost: a.estimatedCost, createdAt: a.createdAt,
                    tags: tagMap[a.id] ?? []
                )
            }
        }
    }

    public func mcpGetAssetDetail(id: String, libraryURL: URL) async throws -> MCPAssetDetail? {
        let assetsBase = libraryURL.appending(path: "assets")
        return try await read { db in
            guard let asset = try Asset.fetchOne(db, key: id) else { return nil }
            let tagNames = try Self.fetchTagNames(for: [id], db: db)[id] ?? []
            let refs = try AssetReference.filter(Column("asset_id") == id).fetchAll(db)
            let refEntries: [MCPReferenceEntry] = try refs.map { ref in
                var srcID: String? = nil
                var srcPath: String? = nil
                if let entryID = ref.referenceEntryID,
                   let entry = try ReferenceEntry.fetchOne(db, key: entryID),
                   let src = try Asset.fetchOne(db, key: entry.assetID) {
                    srcID = src.id
                    srcPath = assetsBase.appending(path: src.filename).path(percentEncoded: false)
                }
                return MCPReferenceEntry(
                    sourceAssetID: srcID, sourceFilePath: srcPath,
                    roleUsed: ref.roleUsed, weightUsed: ref.weightUsed, passedToAPI: ref.passedToAPI
                )
            }
            let usages = try AssetUsage.filter(Column("asset_id") == id).fetchAll(db)
            let usageEntries = usages.map { MCPUsageEntry(usedIn: $0.usedIn, usedAt: $0.usedAt) }
            let fp = assetsBase.appending(path: asset.filename).path(percentEncoded: false)
            let summary = MCPAssetSummary(
                id: asset.id, filename: asset.filename, filePath: fp,
                projectID: asset.projectID, collectionID: asset.collectionID,
                providerID: asset.providerID, modelID: asset.modelID,
                prompt: asset.prompt, aspectRatio: asset.aspectRatio,
                width: asset.width, height: asset.height,
                estimatedCost: asset.estimatedCost, createdAt: asset.createdAt,
                tags: tagNames
            )
            return MCPAssetDetail(asset: summary, references: refEntries, usage: usageEntries)
        }
    }

    public func mcpGetAssetLineage(id: String, libraryURL: URL) async throws -> MCPLineageRecord {
        let assetsBase = libraryURL.appending(path: "assets")
        return try await read { db in
            let refs = try AssetReference.filter(Column("asset_id") == id).fetchAll(db)
            let influences: [MCPReferenceEntry] = try refs.map { ref in
                var srcID: String? = nil
                var srcPath: String? = nil
                if let entryID = ref.referenceEntryID,
                   let entry = try ReferenceEntry.fetchOne(db, key: entryID),
                   let src = try Asset.fetchOne(db, key: entry.assetID) {
                    srcID = src.id
                    srcPath = assetsBase.appending(path: src.filename).path(percentEncoded: false)
                }
                return MCPReferenceEntry(
                    sourceAssetID: srcID, sourceFilePath: srcPath,
                    roleUsed: ref.roleUsed, weightUsed: ref.weightUsed, passedToAPI: ref.passedToAPI
                )
            }
            return MCPLineageRecord(assetID: id, influences: influences)
        }
    }

    public func mcpListCollections(projectID: String?) async throws -> [MCPCollectionSummary] {
        try await read { db in
            var req = ImageCollection.order(Column("name"))
            if let pid = projectID { req = req.filter(Column("project_id") == pid) }
            let cols = try req.fetchAll(db)
            return try cols.map { col in
                let count = try Asset.filter(Column("collection_id") == col.id).fetchCount(db)
                return MCPCollectionSummary(
                    id: col.id, projectID: col.projectID, name: col.name,
                    description: col.description, assetCount: count,
                    obsidianNotePath: col.obsidianNotePath
                )
            }
        }
    }

    public func mcpGetCollection(id: String, libraryURL: URL) async throws -> MCPCollectionDetail? {
        let assetsBase = libraryURL.appending(path: "assets")
        return try await read { db in
            guard let col = try ImageCollection.fetchOne(db, key: id) else { return nil }
            let assets = try Asset.filter(Column("collection_id") == id)
                .order(Column("created_at").desc).fetchAll(db)
            let tagMap = try Self.fetchTagNames(for: assets.map(\.id), db: db)
            let summaries = assets.map { a in
                let fp = assetsBase.appending(path: a.filename).path(percentEncoded: false)
                return MCPAssetSummary(
                    id: a.id, filename: a.filename, filePath: fp,
                    projectID: a.projectID, collectionID: a.collectionID,
                    providerID: a.providerID, modelID: a.modelID,
                    prompt: a.prompt, aspectRatio: a.aspectRatio,
                    width: a.width, height: a.height,
                    estimatedCost: a.estimatedCost, createdAt: a.createdAt,
                    tags: tagMap[a.id] ?? []
                )
            }
            return MCPCollectionDetail(
                id: col.id, projectID: col.projectID, name: col.name,
                description: col.description, obsidianNotePath: col.obsidianNotePath,
                assets: summaries
            )
        }
    }

    public func mcpGetPrompt(id: String, libraryURL: URL) async throws -> MCPPromptDetail? {
        let assetsBase = libraryURL.appending(path: "assets")
        return try await read { db in
            guard let prompt = try Prompt.fetchOne(db, key: id) else { return nil }
            let assetIDs = try Row.fetchAll(db,
                sql: "SELECT asset_id FROM prompt_asset WHERE prompt_id = ?",
                arguments: [id]
            ).compactMap { $0["asset_id"] as? String }
            let assets = try assetIDs.compactMap { try Asset.fetchOne(db, key: $0) }
            let tagMap = try Self.fetchTagNames(for: assets.map(\.id), db: db)
            let summaries = assets.map { a in
                let fp = assetsBase.appending(path: a.filename).path(percentEncoded: false)
                return MCPAssetSummary(
                    id: a.id, filename: a.filename, filePath: fp,
                    projectID: a.projectID, collectionID: a.collectionID,
                    providerID: a.providerID, modelID: a.modelID,
                    prompt: a.prompt, aspectRatio: a.aspectRatio,
                    width: a.width, height: a.height,
                    estimatedCost: a.estimatedCost, createdAt: a.createdAt,
                    tags: tagMap[a.id] ?? []
                )
            }
            // tags column is stored as JSON array string e.g. ["tag1","tag2"]
            let tagList: [String]
            if let raw = prompt.tags,
               let data = raw.data(using: .utf8),
               let decoded = try? JSONDecoder().decode([String].self, from: data) {
                tagList = decoded
            } else {
                tagList = (prompt.tags ?? "")
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            }
            return MCPPromptDetail(
                id: prompt.id, title: prompt.title, body: prompt.body,
                negativePrompt: prompt.negativePrompt, sector: prompt.sector,
                tags: tagList, usageCount: prompt.usageCount,
                lastUsedAt: prompt.lastUsedAt, obsidianNotePath: prompt.obsidianNotePath,
                createdAt: prompt.createdAt, linkedAssets: summaries
            )
        }
    }

    public func mcpGetSpend(
        project: String?,
        dateFrom: String?,
        dateTo: String?
    ) async throws -> SpendSummary {
        var conditions: [String] = []
        var mutableArgs: StatementArguments = []

        if let p = project {
            conditions.append("""
                sl.asset_id IN (
                    SELECT a.id FROM assets a
                    JOIN projects p ON p.id = a.project_id WHERE p.name = ?
                )
                """)
            mutableArgs += [p]
        }
        if let df = dateFrom { conditions.append("sl.timestamp >= ?"); mutableArgs += [df] }
        if let dt = dateTo   { conditions.append("sl.timestamp < ?");  mutableArgs += [dt] }

        let where_ = conditions.isEmpty ? "" : "WHERE \(conditions.joined(separator: " AND "))"
        let capturedArgs = mutableArgs
        let sql = """
            SELECT COALESCE(SUM(estimated_cost), 0) AS total_estimated,
                   COALESCE(SUM(actual_cost), 0)    AS total_actual,
                   COUNT(*)                          AS generation_count
            FROM spend_log sl \(where_)
            """

        return try await read { db in
            let row = try Row.fetchOne(db, sql: sql, arguments: capturedArgs)
            let total = (row?["total_estimated"] as? Double) ?? 0
            let count = (row?["generation_count"] as? Int) ?? 0
            return SpendSummary(
                totalEstimated: total,
                totalActual: (row?["total_actual"] as? Double) ?? 0,
                generationCount: count,
                avgCostPerGeneration: count > 0 ? total / Double(count) : 0
            )
        }
    }

    public func mcpMarkAssetUsed(assetID: String, usedIn: String) async throws {
        let usage = AssetUsage(
            assetID: assetID,
            usedIn: usedIn,
            usedAt: ISO8601DateFormatter().string(from: Date()),
            notedBy: "claude_code"
        )
        try await write { db in try usage.insert(db) }
    }

    // MARK: - Private helpers

    private static func fetchTagNames(for assetIDs: [String], db: Database) throws -> [String: [String]] {
        guard !assetIDs.isEmpty else { return [:] }
        let ph = assetIDs.map { _ in "?" }.joined(separator: ", ")
        var tagArgs: StatementArguments = []
        for id in assetIDs { tagArgs += [id] }
        let rows = try Row.fetchAll(db,
            sql: """
                SELECT at.asset_id, t.name FROM asset_tags at
                JOIN tags t ON t.id = at.tag_id
                WHERE at.asset_id IN (\(ph))
                """,
            arguments: tagArgs
        )
        var result: [String: [String]] = [:]
        for row in rows {
            guard let assetID = row["asset_id"] as? String,
                  let tagName = row["name"] as? String else { continue }
            result[assetID, default: []].append(tagName)
        }
        return result
    }
}
