import GRDB
import Foundation

public enum ClientError: Error, Equatable {
    case nameInUse
    case hasAssignedProjects
    case notFound
}

// MARK: - Clients
extension AppDatabase {
    public func fetchClients() async throws -> [Client] {
        try await read { db in try Client.order(Column("name")).fetchAll(db) }
    }

    /// Case-insensitive find-or-create. Names are trimmed on write.
    @discardableResult
    public func findOrCreateClient(name: String) async throws -> Client {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw ClientError.nameInUse }
        return try await write { db in
            if let existing = try Client
                .filter(SQL("LOWER(name) = LOWER(\(trimmed))"))
                .fetchOne(db) {
                return existing
            }
            let client = Client(name: trimmed, createdAt: iso8601Now())
            try client.insert(db)
            return client
        }
    }

    /// Rename a client. Throws `.nameInUse` if another client already has this name
    /// (case-insensitive). No-op when the new name matches the current one.
    public func renameClient(id: String, newName: String) async throws {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw ClientError.nameInUse }
        try await write { db in
            guard let current = try Client.fetchOne(db, key: id) else {
                throw ClientError.notFound
            }
            if current.name.caseInsensitiveCompare(trimmed) == .orderedSame {
                if current.name != trimmed {
                    try db.execute(sql: "UPDATE clients SET name = ? WHERE id = ?", arguments: [trimmed, id])
                }
                return
            }
            let collision = try Client
                .filter(SQL("LOWER(name) = LOWER(\(trimmed))"))
                .filter(Column("id") != id)
                .fetchCount(db)
            if collision > 0 { throw ClientError.nameInUse }
            try db.execute(sql: "UPDATE clients SET name = ? WHERE id = ?", arguments: [trimmed, id])
        }
    }

    /// Delete a client. Rejects with `.hasAssignedProjects` when any project still
    /// references this client — caller must reassign those projects first.
    public func deleteClient(id: String) async throws {
        try await write { db in
            let count = try Project.filter(Column("client_id") == id).fetchCount(db)
            if count > 0 { throw ClientError.hasAssignedProjects }
            try db.execute(sql: "DELETE FROM clients WHERE id = ?", arguments: [id])
        }
    }
}

// MARK: - Projects
extension AppDatabase {
    public func fetchProjects() async throws -> [Project] {
        try await read { db in try Project.fetchAll(db) }
    }

    public func insertProject(_ project: Project) async throws {
        try await write { db in try project.insert(db) }
    }

    public func renameProject(id: String, newName: String) async throws {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        try await write { db in
            try db.execute(sql: "UPDATE projects SET name = ? WHERE id = ?", arguments: [trimmed, id])
        }
    }

    /// Assign or clear a project's client. Passing nil detaches the client.
    public func setProjectClient(projectID: String, clientID: String?) async throws {
        try await write { db in
            try db.execute(
                sql: "UPDATE projects SET client_id = ? WHERE id = ?",
                arguments: [clientID, projectID]
            )
        }
    }

    public func deleteProject(id: String) async throws {
        try await write { db in
            try db.execute(sql: "DELETE FROM projects WHERE id = ?", arguments: [id])
        }
    }
}

// MARK: - Asset <-> Projects
extension AppDatabase {
    /// All projects an asset belongs to, sorted by name.
    public func fetchProjectsForAsset(assetID: String) async throws -> [Project] {
        try await read { db in
            try Project.fetchAll(db, sql: """
                SELECT p.* FROM projects p
                JOIN asset_projects ap ON ap.project_id = p.id
                WHERE ap.asset_id = ?
                ORDER BY p.name
            """, arguments: [assetID])
        }
    }

    public func fetchProjectIDsForAsset(assetID: String) async throws -> [String] {
        try await read { db in
            try String.fetchAll(
                db,
                sql: "SELECT project_id FROM asset_projects WHERE asset_id = ?",
                arguments: [assetID]
            )
        }
    }

    /// Replace the asset's set of projects. The first entry in `projectIDs` is the primary
    /// (also mirrored onto `assets.project_id` for the transitional query surface).
    public func setProjectsForAsset(assetID: String, projectIDs: [String]) async throws {
        let captured = projectIDs
        try await write { db in
            try db.execute(sql: "DELETE FROM asset_projects WHERE asset_id = ?", arguments: [assetID])
            for (index, pid) in captured.enumerated() {
                try db.execute(
                    sql: "INSERT OR IGNORE INTO asset_projects (asset_id, project_id, is_primary) VALUES (?, ?, ?)",
                    arguments: [assetID, pid, index == 0]
                )
            }
            try db.execute(
                sql: "UPDATE assets SET project_id = ? WHERE id = ?",
                arguments: [captured.first, assetID]
            )
        }
    }

    public func addAssetToProject(assetID: String, projectID: String) async throws {
        try await write { db in
            try db.execute(
                sql: "INSERT OR IGNORE INTO asset_projects (asset_id, project_id, is_primary) VALUES (?, ?, 0)",
                arguments: [assetID, projectID]
            )
            let hasPrimary = try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM asset_projects WHERE asset_id = ? AND is_primary = 1)",
                arguments: [assetID]
            ) ?? false
            if !hasPrimary {
                try db.execute(
                    sql: "UPDATE asset_projects SET is_primary = 1 WHERE asset_id = ? AND project_id = ?",
                    arguments: [assetID, projectID]
                )
                try db.execute(
                    sql: "UPDATE assets SET project_id = ? WHERE id = ?",
                    arguments: [projectID, assetID]
                )
            }
        }
    }

    /// Bulk-add a single project to many assets in one write transaction.
    /// Uses INSERT OR IGNORE so existing memberships are preserved; promotes this project
    /// to primary only for assets that had no primary yet.
    public func bulkAddAssetsToProject(assetIDs: [String], projectID: String) async throws {
        guard !assetIDs.isEmpty else { return }
        let captured = assetIDs
        let pid = projectID
        try await write { db in
            for aid in captured {
                try db.execute(
                    sql: "INSERT OR IGNORE INTO asset_projects (asset_id, project_id, is_primary) VALUES (?, ?, 0)",
                    arguments: [aid, pid]
                )
                let hasPrimary = try Bool.fetchOne(
                    db,
                    sql: "SELECT EXISTS(SELECT 1 FROM asset_projects WHERE asset_id = ? AND is_primary = 1)",
                    arguments: [aid]
                ) ?? false
                if !hasPrimary {
                    try db.execute(
                        sql: "UPDATE asset_projects SET is_primary = 1 WHERE asset_id = ? AND project_id = ?",
                        arguments: [aid, pid]
                    )
                    try db.execute(
                        sql: "UPDATE assets SET project_id = ? WHERE id = ?",
                        arguments: [pid, aid]
                    )
                }
            }
        }
    }

    /// Bulk-attach a tag (find-or-created by name) to every asset in one write transaction.
    /// Existing tag memberships are preserved (INSERT OR IGNORE).
    public func bulkAddTagToAssets(assetIDs: [String], tagName: String) async throws {
        let trimmed = tagName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !assetIDs.isEmpty else { return }
        let captured = assetIDs
        try await write { db in
            let tag: Tag
            if let existing = try Tag.filter(Column("name") == trimmed).fetchOne(db) {
                tag = existing
            } else {
                tag = Tag(name: trimmed)
                try tag.insert(db)
            }
            for aid in captured {
                try db.execute(
                    sql: "INSERT OR IGNORE INTO asset_tags (asset_id, tag_id) VALUES (?, ?)",
                    arguments: [aid, tag.id]
                )
            }
        }
    }

    /// Bulk-remove every tag from the given assets in one write transaction.
    public func bulkClearTagsForAssets(assetIDs: [String]) async throws {
        guard !assetIDs.isEmpty else { return }
        let captured = assetIDs
        try await write { db in
            let ph = captured.map { _ in "?" }.joined(separator: ", ")
            var args: StatementArguments = []
            for id in captured { args += [id] }
            try db.execute(sql: "DELETE FROM asset_tags WHERE asset_id IN (\(ph))", arguments: args)
        }
    }

    /// Bulk-remove every project membership from the given assets in one write transaction,
    /// and null out the transitional assets.project_id mirror.
    public func bulkClearAssetProjects(assetIDs: [String]) async throws {
        guard !assetIDs.isEmpty else { return }
        let captured = assetIDs
        try await write { db in
            let ph = captured.map { _ in "?" }.joined(separator: ", ")
            var args: StatementArguments = []
            for id in captured { args += [id] }
            try db.execute(sql: "DELETE FROM asset_projects WHERE asset_id IN (\(ph))", arguments: args)
            try db.execute(sql: "UPDATE assets SET project_id = NULL WHERE id IN (\(ph))", arguments: args)
        }
    }

    public func removeAssetFromProject(assetID: String, projectID: String) async throws {
        try await write { db in
            try db.execute(
                sql: "DELETE FROM asset_projects WHERE asset_id = ? AND project_id = ?",
                arguments: [assetID, projectID]
            )
            // If we removed the primary, promote another row if any remain.
            let nextPrimary = try String.fetchOne(
                db,
                sql: "SELECT project_id FROM asset_projects WHERE asset_id = ? ORDER BY project_id LIMIT 1",
                arguments: [assetID]
            )
            if let nextPrimary {
                try db.execute(
                    sql: "UPDATE asset_projects SET is_primary = 1 WHERE asset_id = ? AND project_id = ?",
                    arguments: [assetID, nextPrimary]
                )
            }
            try db.execute(
                sql: "UPDATE assets SET project_id = ? WHERE id = ?",
                arguments: [nextPrimary, assetID]
            )
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
