import GRDB
import Foundation

// MARK: - Projects
extension AppDatabase {
    public func fetchProjects() async throws -> [Project] {
        try await read { db in try Project.fetchAll(db) }
    }
}

// MARK: - Collections
extension AppDatabase {
    public func fetchCollections(projectID: String) async throws -> [ImageCollection] {
        try await read { db in
            try ImageCollection
                .filter(Column("project_id") == projectID)
                .fetchAll(db)
        }
    }
}

// MARK: - Assets
extension AppDatabase {
    public func fetchAsset(id: String) async throws -> Asset? {
        try await read { db in try Asset.fetchOne(db, key: id) }
    }

    public func insertAsset(_ asset: Asset) async throws {
        try await write { db in try asset.insert(db) }
    }
}

// MARK: - References
extension AppDatabase {
    public func fetchActiveReferenceEntries(projectID: String) async throws -> [ReferenceEntry] {
        try await read { db in
            guard let set = try ReferenceSet
                .filter(Column("project_id") == projectID)
                .filter(Column("is_active") == true)
                .fetchOne(db)
            else { return [] }
            return try ReferenceEntry
                .filter(Column("reference_set_id") == set.id)
                .fetchAll(db)
        }
    }

    public func insertAssetReference(_ ref: AssetReference) async throws {
        try await write { db in try ref.insert(db) }
    }
}

// MARK: - Tags
extension AppDatabase {
    @discardableResult
    public func findOrCreateTag(name: String) async throws -> Tag {
        try await write { db in
            if let existing = try Tag.filter(Column("name") == name).fetchOne(db) {
                return existing
            }
            let tag = Tag(name: name)
            try tag.insert(db)
            return tag
        }
    }

    public func attachTag(tagID: String, assetID: String) async throws {
        try await write { db in
            try db.execute(
                sql: "INSERT OR IGNORE INTO asset_tags (asset_id, tag_id) VALUES (?, ?)",
                arguments: [assetID, tagID]
            )
        }
    }
}

// MARK: - Spend
extension AppDatabase {
    public func insertSpendLog(_ log: SpendLog) async throws {
        try await write { db in try log.insert(db) }
    }
}

// MARK: - Prompts
extension AppDatabase {
    public func fetchPrompts() async throws -> [Prompt] {
        try await read { db in
            try Prompt.order(Column("usage_count").desc).fetchAll(db)
        }
    }

    public func insertPrompt(_ prompt: Prompt) async throws {
        try await write { db in try prompt.insert(db) }
    }

    public func insertPromptAsset(_ pa: PromptAsset) async throws {
        try await write { db in try pa.insert(db) }
    }
}

// MARK: - Variants
extension AppDatabase {
    public func findOrCreateVariant(name: String, projectID: String) async throws -> Variant {
        try await write { db in
            if let existing = try Variant
                .filter(Column("name") == name)
                .filter(Column("project_id") == projectID)
                .fetchOne(db) {
                return existing
            }
            let variant = Variant(name: name, projectID: projectID, createdAt: iso8601Now())
            try variant.insert(db)
            return variant
        }
    }

    public func variantMemberCount(variantID: String) async throws -> Int {
        try await read { db in
            try VariantMember.filter(Column("variant_id") == variantID).fetchCount(db)
        }
    }

    public func insertVariantMember(_ member: VariantMember) async throws {
        try await write { db in try member.insert(db) }
    }
}

// MARK: - Helpers
private func iso8601Now() -> String {
    ISO8601DateFormatter().string(from: Date())
}
