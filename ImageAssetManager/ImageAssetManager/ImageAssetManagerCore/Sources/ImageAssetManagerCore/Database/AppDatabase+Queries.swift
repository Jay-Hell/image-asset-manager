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

public enum VariantFamilyError: Error, Equatable {
    case emptyName
}

// MARK: - Variants
extension AppDatabase {
    public func findOrCreateVariant(name: String, projectID: String?) async throws -> Variant {
        try await write { db in
            var query = Variant.filter(Column("name") == name)
            if let pid = projectID {
                query = query.filter(Column("project_id") == pid)
            } else {
                query = query.filter(Column("project_id") == nil)
            }
            if let existing = try query.fetchOne(db) {
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

    /// Return distinct variant family names across every project (including orphan families).
    /// Used by the inspector's family picker so an asset can be moved into any family.
    public func fetchAllVariantFamilyNames() async throws -> [String] {
        try await read { db in
            let names = try Variant.select(Column("name"), as: String.self).fetchAll(db)
            var seen: Set<String> = []
            return names.filter { seen.insert($0).inserted }.sorted()
        }
    }

    /// Return distinct variant family names scoped to a project (or orphan families when nil).
    /// Used by the Generation panel's family-name picker.
    public func fetchVariantFamilyNames(projectID: String?) async throws -> [String] {
        try await read { db in
            var query = Variant.select(Column("name"), as: String.self)
            if let pid = projectID {
                query = query.filter(Column("project_id") == pid)
            } else {
                query = query.filter(Column("project_id") == nil)
            }
            let names = try query.fetchAll(db)
            var seen: Set<String> = []
            return names.filter { seen.insert($0).inserted }.sorted()
        }
    }

    public func insertVariantMember(_ member: VariantMember) async throws {
        try await write { db in try member.insert(db) }
    }

    /// Move an asset to a different variant family (or rename its family by using a new name).
    /// Detaches the asset from its current family, attaches it to the named family (creating it
    /// if needed), and deletes the old family if it becomes empty — preserving the invariant
    /// that every family has at least one member.
    @discardableResult
    public func moveAssetToVariantFamily(
        assetID: String,
        newFamilyName: String,
        projectID: String?
    ) async throws -> Variant {
        let trimmed = newFamilyName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            throw VariantFamilyError.emptyName
        }

        return try await write { db in
            let oldMembership = try VariantMember.filter(Column("asset_id") == assetID).fetchOne(db)
            let oldVariantID = oldMembership?.variantID

            var query = Variant.filter(Column("name") == trimmed)
            if let pid = projectID {
                query = query.filter(Column("project_id") == pid)
            } else {
                query = query.filter(Column("project_id") == nil)
            }
            let variant: Variant
            if let existing = try query.fetchOne(db) {
                variant = existing
            } else {
                let created = Variant(name: trimmed, projectID: projectID, createdAt: iso8601Now())
                try created.insert(db)
                variant = created
            }

            if oldVariantID == variant.id {
                return variant
            }

            if let member = oldMembership {
                try db.execute(sql: "DELETE FROM variant_members WHERE id = ?", arguments: [member.id])
            }

            let seq = try VariantMember.filter(Column("variant_id") == variant.id).fetchCount(db)
            let newMember = VariantMember(
                variantID: variant.id,
                assetID: assetID,
                sequence: seq + 1,
                isSelected: seq == 0
            )
            try newMember.insert(db)

            if let oldID = oldVariantID,
               try VariantMember.filter(Column("variant_id") == oldID).fetchCount(db) == 0 {
                try db.execute(sql: "DELETE FROM variants WHERE id = ?", arguments: [oldID])
            }

            return variant
        }
    }

    /// Attach an asset to a variant family. If `familyName` is nil or empty, a default name is
    /// derived from the asset's prompt (preferred) or filename. Creates a new family if needed,
    /// otherwise appends the asset to the existing family scoped to the same project.
    @discardableResult
    public func attachToVariantFamily(
        assetID: String,
        projectID: String?,
        familyName: String?,
        prompt: String?,
        filename: String
    ) async throws -> Variant {
        let trimmed = familyName?.trimmingCharacters(in: .whitespaces) ?? ""
        let resolvedName = trimmed.isEmpty
            ? defaultVariantFamilyName(prompt: prompt, filename: filename)
            : trimmed
        let variant = try await findOrCreateVariant(name: resolvedName, projectID: projectID)
        let seq = try await variantMemberCount(variantID: variant.id)
        try await insertVariantMember(
            VariantMember(variantID: variant.id, assetID: assetID, sequence: seq + 1, isSelected: seq == 0)
        )
        return variant
    }
}

// MARK: - Helpers
private func iso8601Now() -> String {
    ISO8601DateFormatter().string(from: Date())
}
